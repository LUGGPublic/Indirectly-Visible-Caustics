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

float3 projectPoint(const float3 planePoint, const float3 planeNormal, const float3 pointToProject)
{
    const float3 vector = pointToProject - planePoint;
    const float distance = dot(planeNormal, vector);
    return pointToProject - distance * planeNormal;
}

float2 toPlaneCoordinates(const float3 tangent, const float3 binormal, const float3 projectedPoint)
{
    const float u = dot(tangent, projectedPoint);
    const float v = dot(binormal, projectedPoint);
    return float2(u, v);
}

float2 projectToPlaneCoords(const float3 planePoint, const float3 planeNormal, const float3 planeTangent, const float3 planeBinormal, const float3 pointToProject, out float3 projectedPoint)
{
    projectedPoint = projectPoint(planePoint, planeNormal, pointToProject);
    return toPlaneCoordinates(planeTangent, planeBinormal, projectedPoint);
}

/** Samples an emissive triangle uniformly by area and evaluates the probability density function.
    Note that the triangle is only emitting on the front-facing side.
    \param[in] projectionVolume AABB towards which light paths should be guided.
    \param[in] triangleIndex Triangle index of sampled triangle.
    \param[in] u Uniform random number (2D).
    \param[in] v Uniform random number (2D).
    \param[out] ls Light sample. Only valid if true is returned.
    \return True if a sample was generated, false otherwise.
*/
bool sampleTriangle(const AABB projectionVolume, uint triangleIndex, float2 u, float2 v, out TriangleLightSample ls)
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
    const float3 tangent = normalize(tri.posW[1] - tri.posW[0]);
    const float3 bitangent = normalize(cross(ls.normalW, tangent));

    float3 coneDir;
    float saCosTheta, saSinTheta;
    //boundBoxSubtendedConeAngleAverage(ls.posW, projectionVolume.minPoint, projectionVolume.maxPoint, coneDir, saSinTheta, saCosTheta);
    boundBoxSubtendedConeAngleCenter(ls.posW, projectionVolume.minPoint, projectionVolume.maxPoint, coneDir, saSinTheta, saCosTheta);
    float dirPdf = 1.0f;
    // Check that we are not inside the projection volume, otherwise fall back to hemisphere sampling.
    if (any(coneDir != float3(0.0f)))
    {
        const float3 localDir = sample_cone(v, saCosTheta);
        const float3 coneNormal = coneDir;
        const float3 coneTangent = normalize(perp_stark(coneNormal));
        const float3 coneBitangent = cross(coneNormal, coneTangent);
        ls.dir = coneNormal * localDir.z
            + coneTangent * localDir.x
            + coneBitangent * localDir.y;
        dirPdf = 1.0f / (M_2PI * (1.0f - saCosTheta));
        if (dot(ls.normalW, ls.dir) <= 0.0f) return false;
    }
    else
    {
        const float3 localDir = sample_cosine_hemisphere_concentric(v, dirPdf);
        ls.dir = tri.normal * localDir.z
            + tangent * localDir.x
            + bitangent * localDir.y;
    }

    // Evaluate emitted radiance.
    float2 uv = tri.getTexCoord(barycentrics);
    ls.Le = gScene.getEmissive(tri.materialID, uv, gScene.materialResources[tri.materialID]);

    // Compute probability density.
    // Note: Guard against div-by-zero here by clamping.
    float denom = max(FLT_MIN, tri.area);
    ls.pdf = dirPdf / denom;
    return true;
}

/** Samples a directional light source.
    \param[in] light Light data.
    \param[in] projectionVolume AABB around all caustics-generating objects in the scene.
    \param[in,out] sg Sample generator.
    \param[out] ls Light sample struct.
    \return True if a sample was generated, false otherwise.
*/
bool sampleDirectionalLight<S : ISampleGenerator>(const LightData light, const AABB projectionVolume, inout S sg, out AnalyticLightSample ls)
{
    const bool showProjectedPoints = false;

    // For a directional light, the normal is always along its light direction.
    const float3 normal = light.dirW;
    const float3 tangent = normalize(perp_stark(normal));
    const float3 binormal = cross(normal, tangent);

    // Place a point belonging to the plane of the directional light, as far as possible while not too far.
    const float3 pointOnPlane = -normal * 2.3f;

    const float3 pvMin = projectionVolume.minPoint;
    const float3 pvMax = projectionVolume.maxPoint;

    float3 pp0, pp1, pp2, pp3, pp4, pp5, pp6, pp7;
    const float2 pc0 = projectToPlaneCoords(pointOnPlane, normal, tangent, binormal, float3(pvMin.x, pvMin.y, pvMin.z), pp0);
    const float2 pc1 = projectToPlaneCoords(pointOnPlane, normal, tangent, binormal, float3(pvMax.x, pvMin.y, pvMin.z), pp1);
    const float2 pc2 = projectToPlaneCoords(pointOnPlane, normal, tangent, binormal, float3(pvMin.x, pvMin.y, pvMax.z), pp2);
    const float2 pc3 = projectToPlaneCoords(pointOnPlane, normal, tangent, binormal, float3(pvMax.x, pvMin.y, pvMax.z), pp3);
    const float2 pc4 = projectToPlaneCoords(pointOnPlane, normal, tangent, binormal, float3(pvMin.x, pvMax.y, pvMin.z), pp4);
    const float2 pc5 = projectToPlaneCoords(pointOnPlane, normal, tangent, binormal, float3(pvMax.x, pvMax.y, pvMin.z), pp5);
    const float2 pc6 = projectToPlaneCoords(pointOnPlane, normal, tangent, binormal, float3(pvMin.x, pvMax.y, pvMax.z), pp6);
    const float2 pc7 = projectToPlaneCoords(pointOnPlane, normal, tangent, binormal, float3(pvMax.x, pvMax.y, pvMax.z), pp7);

    const float2 projectedAABBMin = min(min(min(pc0, pc1), min(pc2, pc3)), min(min(pc4, pc5), min(pc6, pc7)));
    const float2 projectedAABBMax = max(max(max(pc0, pc1), max(pc2, pc3)), max(max(pc4, pc5), max(pc6, pc7)));
    const float2 projectedAABBSize = projectedAABBMax - projectedAABBMin;
    const float projectedAABBArea = projectedAABBSize.x * projectedAABBSize.y;

    const float3 projectedMin = pp0
                              + (projectedAABBMin.x - pc0.x) * tangent
                              + (projectedAABBMin.y - pc0.y) * binormal;

    const float2 u = sampleNext2D(sg);
    ls.posW = projectedMin
            + (projectedAABBSize.x * u.x) * tangent
            + (projectedAABBSize.y * u.y) * binormal;

    if (showProjectedPoints)
    {
        if (u.x < 0.2) ls.posW = pp0;
        else if (u.x < 0.4) ls.posW = pp1;
        else if (u.x < 0.6) ls.posW = pp2;
        else if (u.x < 0.8) ls.posW = pp3;
        else if (u.y < 0.25) ls.posW = pp4;
        else if (u.y < 0.5) ls.posW = pp5;
        else if (u.y < 0.75) ls.posW = pp6;
        else ls.posW = pp7;
    }

    // Setup direction to light.
    ls.dir = light.dirW;

    // Setup incident radiance. For directional lights there is no falloff or cosine term.
    ls.Li = light.intensity * projectedAABBArea;
    ls.pdf = 1.0f / projectedAABBArea;

    return true;
}

/** Samples a point light source.
    \param[in] light Light data.
    \param[in] projectionVolume AABB around all caustics-generating objects in the scene.
    \param[in,out] sg Sample generator.
    \param[out] ls Light sample struct.
    \return True if a sample was generated, false otherwise.
*/
bool samplePointLight<S : ISampleGenerator>(const LightData light, const AABB projectionVolume, inout S sg, out AnalyticLightSample ls)
{
    ls = {};
    ls.posW = light.posW;

    const float2 u = sampleNext2D(sg);

    float3 coneDir;
    float saCosTheta, saSinTheta;
    boundBoxSubtendedConeAngleAverage(ls.posW, projectionVolume.minPoint, projectionVolume.maxPoint, coneDir, saSinTheta, saCosTheta);
    const float3 localDir = sample_cone(u, saCosTheta);

    ls.normalW = coneDir;
    const float3 tangent = normalize(perp_stark(ls.normalW));
    const float3 bitangent = cross(ls.normalW, tangent);
    ls.dir = ls.normalW * localDir.z + tangent * localDir.x + bitangent * localDir.y;

    const float coneSamplingInvPDF = M_2PI * (1.0f - saCosTheta);

    // Setup incident radiance.
    ls.Li = light.intensity * coneSamplingInvPDF;
    ls.pdf = 1.0f / coneSamplingInvPDF;

    return true;
}

/** Samples an analytic light source.
    This function calls the correct sampling function depending on the type of light.
    \param[in] light Light data.
    \param[in] projectionVolume AABB around all caustics-generating objects in the scene.
    \param[in,out] sg Sample generator.
    \param[out] ls Sampled point on the light and associated sample data, only valid if true is returned.
    \return True if a sample was generated, false otherwise.
*/
bool sampleLight<S : ISampleGenerator>(const LightData light, const AABB projectionVolume, inout S sg, out AnalyticLightSample ls)
{
    // Sample the light based on its type: point, directional, or area.
    switch (light.type)
    {
        case LightType::Directional:
            return sampleDirectionalLight(light, projectionVolume, sg, ls);
        case LightType::Point:
            return samplePointLight(light, projectionVolume, sg, ls);
        default:
            return false; // Should not happen
    }
}

/** Draw a single light sample.
    \param[in] projectionVolume Volume towards which direction should be generated.
    \param[in] onSurface True if only upper hemisphere should be considered.
    \param[in,out] sg Sample generator.
    \param[out] ls Light sample. Only valid if true is returned.
    \return True if a sample was generated, false otherwise.
*/
bool sampleLight<S : ISampleGenerator>(const EmissiveLightSampler sampler, const ActiveTriangleData activeTriangleData, const AABB projectionVolume, const bool onSurface, inout S sg, out TriangleLightSample ls)
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
    if (!sampleTriangle(projectionVolume, triangleIndex, u, v, ls)) return false;

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

    if (!sampleTriangle(projectionVolume, triangleIndex, u, v, ls)) return false;

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
    \param[in] projectionVolume AABB around all caustics-generating objects in the scene.
    \param[in] emissiveSampler Emissive light sampler.
    \param[in,out] sg SampleGenerator object.
    \param[out] ls Generated light sample. Only valid if true is returned.
    \return True if a sample was generated, false otherwise.
*/
bool sampleSceneLights<S : ISampleGenerator>(const AABB projectionVolume, const EmissiveLightSampler emissiveSampler, const ActiveTriangleData activeTriangleData, inout S sg, out LightSample ls)
{
    // Set relative probabilities of the different sampling techniques.
    // TODO: These should use estimated irradiance from each light type. Using equal probabilities for now.
    // TODO: Refactor the selection pdf code the helpers above for evaluating the individual probabilities.
    float p[2];
    p[0] = kUseAnalyticLights ? 1.f : 0.f;
    p[1] = kUseEmissiveLights ? 1.f : 0.f;

    // Normalize probabilities. Early out if zero.
    float sum = p[0] + p[1];
    if (sum == 0.f) return false;

    float invSum = 1.f / sum;
    p[0] *= invSum;
    p[1] *= invSum;

    // Sample based on uniform random number. Rescale u to [0,1) afterwards.
    float invPdf = 0.f;
    float u = sampleNext1D(sg);

    if (kUseAnalyticLights)
    {
        if (u < p[0])
        {
            // Sample analytic light source selected uniformly from the light list.
            // TODO: Sample based on estimated contributions as pdf.
            uint lightCount = gScene.getLightCount();
            uint lightIndex = min(uint(u * lightCount), lightCount - 1);
            float selectionPdf = p[0] / lightCount; // TODO: Precompute 1.f/lightCount in cbuffer

            // Sample local light source.
            AnalyticLightSample lightSample;
            bool valid = sampleLight(gScene.getLight(lightIndex), projectionVolume, sg, lightSample);
            if (!valid) return false;

            // Setup returned sample.
            ls.pos = computeRayOrigin(lightSample.posW, lightSample.normalW);
            ls.dir = lightSample.dir;
            ls.pdf = selectionPdf * lightSample.pdf;
            ls.Le = lightSample.Li / selectionPdf;

            return true;
        }
        u -= p[0];
    }

    if (kUseEmissiveLights)
    {
        // if (u < p[1]) // Always true
        {
            // Sample emissive lights.
            TriangleLightSample lightSample;
            bool valid = sampleLight(emissiveSampler, activeTriangleData, projectionVolume, true, sg, lightSample);
            if (!valid) return false;

            // Setup returned sample.
            const float pdf = p[1] * lightSample.pdf;
            ls.pos = computeRayOrigin(lightSample.posW, lightSample.normalW);
            ls.dir = lightSample.dir;
            ls.pdf = pdf;
            ls.Le = pdf > 0.0f ? lightSample.Le * clamp(dot(lightSample.normalW, lightSample.dir), 0.0f, 1.0f) / pdf : float3(0.0f);

            return true;
        }
    }

    return false;
}
