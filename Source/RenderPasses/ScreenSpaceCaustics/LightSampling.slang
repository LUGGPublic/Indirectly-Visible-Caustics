/***************************************************************************
 # Copyright (c) 2021, NVIDIA CORPORATION. All rights reserved.
 #
 # Redistribution and use in source and binary forms, with or without
 # modification, are permitted provided that the following conditions
 # are met:
 #  * Redistributions of source code must retain the above copyright
 #    notice, this list of conditions and the following disclaimer.
 #  * Redistributions in binary form must reproduce the above copyright
 #    notice, this list of conditions and the following disclaimer in the
 #    documentation and/or other materials provided with the distribution.
 #  * Neither the name of NVIDIA CORPORATION nor the names of its
 #    contributors may be used to endorse or promote products derived
 #    from this software without specific prior written permission.
 #
 # THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS "AS IS" AND ANY
 # EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 # IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 # PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL THE COPYRIGHT OWNER OR
 # CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
 # EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
 # PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
 # PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY
 # OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 # (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
 # OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 **************************************************************************/
__exported import SharedSampling;
__exported import Experimental.Scene.Lights.EmissiveLightSampler;
__exported import Experimental.Scene.Lights.LightCollection;
__exported import Utils.Math.AABB;

/** Samples an emissive triangle uniformly by area and evaluates the probability density function.
    Note that the triangle is only emitting on the front-facing side.
    \param[in] triangleIndex Triangle index of sampled triangle.
    \param[in] u Uniform random number (2D).
    \param[in] v Uniform random number (2D).
    \param[out] ls Light sample. Only valid if true is returned.
    \return True if a sample was generated, false otherwise.
*/
bool sampleTriangle(uint triangleIndex, float2 u, float2 v, out TriangleLightSample ls)
{
    ls = {};
    ls.triangleIndex = triangleIndex;

    const EmissiveTriangle tri = gScene.lightCollection.getTriangle(triangleIndex);

    // Sample the triangle uniformly.
    const float3 barycentrics = sample_triangle(u);
    ls.posW = tri.getPosition(barycentrics);

    // Get triangle normal and associated quantities.
    ls.normalW = tri.normal;

    // Compute light vector.
    float dirPdf = 0.0f;
    const float3 localDir = sample_cosine_hemisphere_concentric(v, dirPdf);
    const float3 tangent = normalize(tri.posW[1] - tri.posW[0]);
    const float3 bitangent = normalize(cross(tri.normal, tangent));
    ls.dir = tri.normal * localDir.z
        + tangent * localDir.x
        + bitangent * localDir.y;

    // Evaluate emitted radiance.
    float2 uv = tri.getTexCoord(barycentrics);
    ls.Le = gScene.getEmissive(tri.materialID, uv, gScene.materialResources[tri.materialID]);

    // Compute probability density.
    // Note: Guard against div-by-zero here by clamping.
    float denom = max(FLT_MIN, tri.area);
    ls.pdf = dirPdf / denom;
    return true;
}

/** Internal helper function to finalize the shared computations for area light samples.
    The input sample must already have posW and normalW computed.
    \return True if the sample is valid, false otherwise.
*/
bool finalizeAreaLightSample(const float2 u, const LightData light, inout AnalyticLightSample ls)
{
    float dirPdf = 0.0f;
    const float3 localDir = sample_cosine_hemisphere_concentric(u, dirPdf);
    ls.dir = mul(float4(localDir, 0.f), light.transMat).xyz;
    ls.Li = light.intensity * (light.surfaceArea / dirPdf);

    // Compute the PDF. Note this may be +inf.
    ls.pdf = 1.0f / (light.surfaceArea) * dirPdf;
    return true;
}

/** Samples a rectangular area light source.
    \param[in] light Light data.
    \param[in,out] sg Sample generator.
    \param[out] ls Light sample struct.
    \return True if a sample was generated, false otherwise.
*/
bool sampleRectAreaLight<S : ISampleGenerator>(const LightData light, inout S sg, out AnalyticLightSample ls)
{
    // Pick a random sample on the quad.
    // The quad is from (-1,-1,0) to (1,1,0) in object space, but may be scaled by its transform matrix.
    float2 u = sampleNext2D(sg);
    float3 pos = float3(u.x * 2.f - 1.f, u.y * 2.f - 1.f, 0.f);

    // Apply model to world transformation matrix.
    ls.posW = mul(float4(pos, 1.f), light.transMat).xyz;

    // Setup world space normal.
    // TODO: Should use light.dirW.
    float3 tangentW = mul(float4(1.f, 0.f, 0.f, 0.f), light.transMat).xyz;
    float3 bitangentW = mul(float4(0.f, 1.f, 0.f, 0.f), light.transMat).xyz;
    // TODO: normalW is not correctly oriented for mesh instances that have flipped triangle winding.
    ls.normalW = normalize(cross(tangentW, bitangentW));

    return finalizeAreaLightSample(sampleNext2D(sg), light, ls);
}

/** Samples a spherical area light source.
    \param[in] light Light data.
    \param[in,out] sg Sample generator.
    \param[out] ls Light sample struct.
    \return True if a sample was generated, false otherwise.
*/
bool sampleSphereAreaLight<S : ISampleGenerator>(const LightData light, inout S sg, out AnalyticLightSample ls)
{
    // Sample a random point on the sphere.
    // TODO: We should pick a random point on the hemisphere facing the shading point.
    float2 u = sampleNext2D(sg);
    float3 pos = sample_sphere(u);

    // Apply model to world transformation matrix.
    ls.posW = mul(float4(pos, 1.f), light.transMat).xyz;

    // Setup world space normal.
    ls.normalW = normalize(mul(float4(pos, 0.f), light.transMatIT).xyz);

    return finalizeAreaLightSample(sampleNext2D(sg), light, ls);
}

/** Samples disc area light source.
    \param[in] light Light data.
    \param[in,out] sg Sample generator.
    \param[out] ls Light sample struct.
    \return True if a sample was generated, false otherwise.
*/
bool sampleDiscAreaLight<S : ISampleGenerator>(const LightData light, inout S sg, out AnalyticLightSample ls)
{
    // Sample a random point on the disk.
    // TODO: Fix spelling disagreement between disc vs disk.
    float2 u = sampleNext2D(sg);
    float3 pos = float3(sample_disk(u), 0.f);

    // Transform to world space.
    ls.posW = mul(float4(pos, 1.f), light.transMat).xyz;

    // Setup world space normal.
    ls.normalW = normalize(mul(float4(0.f, 0.f, 1.f, 0.f), light.transMatIT).xyz);

    return finalizeAreaLightSample(sampleNext2D(sg), light, ls);
}

/** Samples a distant light source.
    \param[in] light Light data.
    \param[in,out] sg Sample generator.
    \param[out] ls Light sample struct.
    \return True if a sample was generated, false otherwise.
*/
bool sampleDistantLight<S : ISampleGenerator>(const LightData light, inout S sg, out AnalyticLightSample ls)
{
    // TODO: Implement
    // A distant light doesn't have a position. Just clear to zero.
    ls.posW = float3(0.f, 0.f, 0.f);

    float2 u = sampleNext2D(sg);
    float3 dir = sample_cone(u, light.cosSubtendedAngle);

    // Transform sampled direction to world space
    ls.dir = normalize(mul(dir, (float3x3)light.transMat));
    ls.normalW = -ls.dir;
    ls.distance = kMaxLightDistance;

    // Compute incident radiance at shading point.
    // A DistantLight's angle defines the solid angle it subtends.
    // But because the angle is intended to affect penumbra size, but not
    // perceived brigthness, we treat intensity as radiance.
    float solidAngle = (float)M_2PI * (1.f - light.cosSubtendedAngle);
    ls.Li = light.intensity;
    ls.pdf = 1.f / solidAngle;
    return false;
}

/** Samples a directional light source.
    \param[in] light Light data.
    \param[out] ls Light sample struct.
    \return True if a sample was generated, false otherwise.
*/
bool sampleDirectionalLight(const LightData light, out AnalyticLightSample ls)
{
    // A directional light doesn't have a position. Just clear to zero.
    ls.posW = float3(0, 0, 0);

    // For a directional light, the normal is always along its light direction.
    ls.normalW = light.dirW;

    // Setup direction to light.
    ls.dir = -light.dirW;

    // Setup incident radiance. For directional lights there is no falloff or cosine term.
    ls.Li = light.intensity;
    ls.pdf = 1.f;

    return true;
}

/** Samples a point (spot) light.
    \param[in] light Light data.
    \param[in,out] sg Sample generator.
    \param[out] ls Light sample struct.
    \return True if a sample was generated, false otherwise.
*/
bool samplePointLight<S : ISampleGenerator>(const LightData light, inout S sg, out AnalyticLightSample ls)
{
    // Get the position and normal.
    ls.posW = light.posW;
    ls.normalW = light.dirW;

    // Compute direction to light.
    ls.dir = sample_sphere(sampleNext2D(sg));

    // Compute incident radiance at shading point.
    // TODO: Support spot lights. We assume uniform emission for now.
    ls.Li = light.intensity * (4.f * M_PI);
    ls.pdf = 1.f / (4.f * M_PI);

    return true;
}

/** Samples an analytic light source.
    This function calls the correct sampling function depending on the type of light.
    \param[in] light Light data.
    \param[in,out] sg Sample generator.
    \param[out] ls Sampled point on the light and associated sample data, only valid if true is returned.
    \return True if a sample was generated, false otherwise.
*/
bool sampleLight<S : ISampleGenerator>(const LightData light, inout S sg, out AnalyticLightSample ls)
{
    // Sample the light based on its type: point, directional, or area.
    switch (light.type)
    {
    case LightType::Point:
        return samplePointLight(light, sg, ls);
    case LightType::Directional:
        return sampleDirectionalLight(light, ls);
    case LightType::Rect:
        return sampleRectAreaLight(light, sg, ls);
    case LightType::Sphere:
        return sampleSphereAreaLight(light, sg, ls);
    case LightType::Disc:
        return sampleDiscAreaLight(light, sg, ls);
    case LightType::Distant:
        return sampleDistantLight(light, sg, ls);
    default:
        ls = {};
        return false; // Should not happen
    }
}

/** Draw a single light sample.
    \param[in] onSurface True if only upper hemisphere should be considered.
    \param[in,out] sg Sample generator.
    \param[out] ls Light sample. Only valid if true is returned.
    \return True if a sample was generated, false otherwise.
*/
bool sampleLight<S : ISampleGenerator>(const EmissiveLightSampler sampler, const ActiveTriangleData activeTriangleData, const bool onSurface, inout S sg, out TriangleLightSample ls)
{
#if _EMISSIVE_LIGHT_SAMPLER_TYPE == EMISSIVE_LIGHT_SAMPLER_UNIFORM
    const uint triangleCount = !activeTriangleData.restrictEmissiveTriangles ? gScene.lightCollection.getActiveTriangleCount() : activeTriangleData.count[0];
    if (triangleCount == 0) return false;

    // Randomly pick a triangle out of the global list with uniform probability.
    const float uLight = sampleNext1D(sg);
    const uint idx = min((uint)(uLight * triangleCount), triangleCount - 1); // Safety precaution as the result of the multiplication may be rounded to triangleCount even if uLight < 1.0 when triangleCount is large.
    const uint triangleIndex = !activeTriangleData.restrictEmissiveTriangles ? gScene.lightCollection.activeTriangles[idx] : activeTriangleData.list[idx];
    const float triangleSelectionPdf = 1.0f / ((float)triangleCount);

    // Sample the triangle uniformly.
    const float2 u = sampleNext2D(sg);
    const float2 v = sampleNext2D(sg);
    if (!sampleTriangle(triangleIndex, u, v, ls)) return false;

    // The final probability density is the product of the sampling probabilities.
    ls.pdf *= triangleSelectionPdf;
    return true;

#elif _EMISSIVE_LIGHT_SAMPLER_TYPE == EMISSIVE_LIGHT_SAMPLER_LIGHT_BVH
    // TODO: Implement
    return false;

#elif _EMISSIVE_LIGHT_SAMPLER_TYPE == EMISSIVE_LIGHT_SAMPLER_POWER
    if (gScene.lightCollection.isEmpty()) return false;

    // Randomly pick a triangle out of the global list with uniform probability.
    const float uLight = sampleNext1D(sg);
    const uint triangleCount = gScene.lightCollection.triangleCount;
    // Safety precaution as the result of the multiplication may be rounded to triangleCount even if uLight < 1.0 when triangleCount is large.
    uint triangleIndex = min((uint)(uLight * triangleCount), triangleCount - 1);

    const uint2 packed = _emissivePower.triangleAliasTable[triangleIndex];
    const float threshold = f16tof32(packed.x >> 16u);
    const uint  selectAbove = ((packed.x & 0xFFFFu) << 8u) | ((packed.y >> 24u) & 0xFFu);
    const uint  selectBelow = packed.y & 0xFFFFFFu;

    // Test the threshold in the current table entry; pick one of the two options
    triangleIndex = (sampleNext1D(sg) >= threshold) ? selectAbove : selectBelow;

    const float triangleSelectionPdf = gScene.lightCollection.fluxData[triangleIndex].flux * _emissivePower.invWeightsSum;

    // Sample the triangle uniformly.
    const float2 u = sampleNext2D(sg);
    const float2 v = sampleNext2D(sg);

    if (!sampleTriangle(triangleIndex, u, v, ls)) return false;

    // The final probability density is the product of the sampling probabilities.
    ls.pdf *= triangleSelectionPdf;
    return true;

#elif _EMISSIVE_LIGHT_SAMPLER_TYPE == EMISSIVE_LIGHT_SAMPLER_NULL
    return false;
#endif
}

/** Samples a light source in the scene.
    This function first stochastically selects a type of light source to sample,
    and then calls that the sampling function for the chosen light type.
    \param[in] envMapSampler Environment map sampler.
    \param[in] emissiveSampler Emissive light sampler.
    \param[in,out] sg SampleGenerator object.
    \param[out] ls Generated light sample. Only valid if true is returned.
    \return True if a sample was generated, false otherwise.
*/
bool sampleSceneLights<S : ISampleGenerator>(const EnvMapSampler envMapSampler, const EmissiveLightSampler emissiveSampler, const ActiveTriangleData activeTriangleData, inout S sg, out LightSample ls)
{
    // Set relative probabilities of the different sampling techniques.
    // TODO: These should use estimated irradiance from each light type. Using equal probabilities for now.
    // TODO: Refactor the selection pdf code the helpers above for evaluating the individual probabilities.
    float p[3];
    p[0] = kUseEnvLight ? 1.f : 0.f;
    p[1] = kUseAnalyticLights ? 1.f : 0.f;
    p[2] = kUseEmissiveLights ? 1.f : 0.f;

    // Normalize probabilities. Early out if zero.
    float sum = p[0] + p[1] + p[2];
    if (sum == 0.f) return false;

    float invSum = 1.f / sum;
    p[0] *= invSum;
    p[1] *= invSum;
    p[2] *= invSum;

    // Sample based on uniform random number. Rescale u to [0,1) afterwards.
    float invPdf = 0.f;
    float u = sampleNext1D(sg);

    // We use explicit checks for which light types are enabled so that the compiler
    // can remove the unused code. It won't otherwise since u is unknown at compile time.
    if (kUseEnvLight)
    {
        if (u < p[0])
        {
            float selectionPdf = p[0];

            // Sample environment map.
            EnvMapSample lightSample;
            envMapSampler.sample(sampleNext2D(sg), lightSample);

            float pdf = selectionPdf * lightSample.pdf;

            // Setup returned sample.
            ls.pos = -1e7f * lightSample.dir; // Put it as far away as possible.
            ls.dir = lightSample.dir;
            ls.pdf = pdf;
            ls.Le = pdf > 0.f ? lightSample.Le / pdf : float3(0);

            return true;
        }
        u -= p[0];
    }

    if (kUseAnalyticLights)
    {
        if (u < p[1])
        {
            // Sample analytic light source selected uniformly from the light list.
            // TODO: Sample based on estimated contributions as pdf.
            u /= p[1]; // Rescale to [0,1)
            uint lightCount = gScene.getLightCount();
            uint lightIndex = min(uint(u * lightCount), lightCount - 1);
            float selectionPdf = p[1] / lightCount; // TODO: Precompute 1.f/lightCount in cbuffer

            // Sample local light source.
            AnalyticLightSample lightSample;
            bool valid = sampleLight(gScene.getLight(lightIndex), sg, lightSample);
            if (!valid) return false;

            // Setup returned sample.
            ls.pos = computeRayOrigin(lightSample.posW, lightSample.normalW);
            ls.dir = lightSample.dir;
            ls.pdf = selectionPdf * lightSample.pdf;
            ls.Le = lightSample.Li / selectionPdf;

            return true;
        }
        u -= p[1];
    }

    if (kUseEmissiveLights)
    {
        //if (u < p[2]) // Always true
        {
            float selectionPdf = p[2];

            // Sample emissive lights.
            TriangleLightSample lightSample;
            bool valid = sampleLight(emissiveSampler, activeTriangleData, true, sg, lightSample);
            if (!valid) return false;

            float pdf = selectionPdf * lightSample.pdf;

            // Setup returned sample.
            ls.pos = computeRayOrigin(lightSample.posW, lightSample.normalW);
            ls.dir = lightSample.dir;
            ls.pdf = pdf;
            ls.Le = pdf > 0.f ? lightSample.Le * clamp(dot(lightSample.normalW, lightSample.dir), 0.0f, 1.0f) / pdf : float3(0);

            return true;
        }
    }

    return false;
}
