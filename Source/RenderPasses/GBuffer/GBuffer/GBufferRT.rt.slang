/***************************************************************************
 # Copyright (c) 2020, NVIDIA CORPORATION. All rights reserved.
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
import Scene.Raytracing;
import Scene.HitInfo;
import Scene.Intersection;
import Utils.Helpers;
import Utils.Timing.GpuTimer;
import Utils.Sampling.SampleGenerator;
import Experimental.Scene.Material.TexLODHelpers;
import GBufferHelpers;

// GBuffer channels
RWTexture2D<float4> gPosW;
RWTexture2D<float4> gNormW;
RWTexture2D<float4> gTangentW;
RWTexture2D<float4> gTexC;
RWTexture2D<float4> gDiffuseOpacity;
RWTexture2D<float4> gSpecRough;
RWTexture2D<float4> gEmissive;
RWTexture2D<float4> gMatlExtra;

// GBufferRT channels
RWTexture2D<PackedHitInfo> gVBuffer;
RWTexture2D<float2> gLinearZ;
RWTexture2D<float>  gDeviceZ;
RWTexture2D<float2> gMotionVectors;
RWTexture2D<float4> gFaceNormalW;
RWTexture2D<float4> gViewW;
RWTexture2D<uint> gTime;

#define isValid(name) (is_valid_##name != 0)

/** ***************************** Ray index 0 ****************************** */

/** Payload passed along with primary rays.
    We write the G-buffer from the hit shader, so this struct is very lightweight.
*/
struct RayData
{
    int dummy; // TODO: Passing in an empty payload struct doesn't work. Declare a dummy variable so that the compiler doesn't remove the declaration.
};

[shader("miss")]
void miss(inout RayData rayData)
{
    uint2 launchIndex = DispatchRaysIndex().xy;
    gVBuffer[launchIndex] = { HitInfo::kInvalidIndex };
}

[shader("anyhit")]
void anyHit(
    uniform HitShaderParams hitParams,
    inout RayData rayData : SV_RayPayload, BuiltInTriangleIntersectionAttributes attribs : SV_IntersectionAttributes)
{
#if !DISABLE_ALPHA_TEST
    // Alpha test for non-opaque geometry.
    VertexData v = getVertexData(hitParams, PrimitiveIndex(), attribs);
    const uint materialID = gScene.getMaterialID(hitParams.getGlobalHitID());
    if (alphaTest(v, gScene.materials[materialID], gScene.materialResources[materialID], 0.f)) IgnoreHit();
#endif
}

/** Ray differentials for primary hit. Code from RayTracingGems, Chapter 20.
*/
void computeRayDifferentials(uint meshInstanceID, uint triangleIndex, float3 ray_dir, float ray_t, out float2 ddx, out float2 ddy, const Camera camera)
{
    // TODO: Is this code correct for instance transforms that flip the handedness of the coordinate system?

    // Ray differentials
    float3 P[3];
    gScene.getVertexPositionsW(meshInstanceID, triangleIndex, P);
    float3 e1 = P[1] - P[0];
    float3 e2 = P[2] - P[0];
    float3 d = ray_dir;
    float k = dot(cross(e1, e2), d);
    k = abs(k) > 0.0001f ? rcp(k) : 0.0f;
    float3 cu = cross(e2, d);
    float3 cv = cross(d, e1);
    // Assumes a normalized ray direction
    float3 dx = camera.data.cameraU * 2.0 * gParams.invFrameSize.x / camera.data.focalDistance; // dDdx in ray gen
    float3 dy = camera.data.cameraV * 2.0 * gParams.invFrameSize.y / camera.data.focalDistance; // dDdy in ray gen
    float3 q = dx * ray_t; // Transfer to primary hit
    float3 r = dy * ray_t;
    float dudx = k * dot(cu, q);
    float dudy = k * dot(cu, r);
    float dvdx = k * dot(cv, q);
    float dvdy = k * dot(cv, r);
    float2 T[3];
    gScene.getVertexTexCoords(meshInstanceID, triangleIndex, T);
    float2 g1 = T[1] - T[0];
    float2 g2 = T[2] - T[0];
    float dsdx = (dudx * g1.x + dvdx * g2.x);
    float dsdy = (dudy * g1.x + dvdy * g2.x);
    float dtdx = (dudx * g1.y + dvdx * g2.y);
    float dtdy = (dudy * g1.y + dvdy * g2.y);
    ddx = float2(dsdx, dtdx);
    ddy = float2(dsdy, dtdy);
}

void computeAnisotropicAxesRayCones(uint meshInstanceID, uint triangleIndex, VertexData v, out float2 ddx, out float2 ddy)
{
    float3 positions[3];
    float2 txcoords[3];
    gScene.getVertexPositionsW(meshInstanceID, triangleIndex, positions);
    gScene.getVertexTexCoords(meshInstanceID, triangleIndex, txcoords);

    float pixelAngle = gParams.screenSpacePixelSpreadAngle;
    float coneRadiusAtHitPoint = RayTCurrent() * tan(pixelAngle);
    // Using faceNormal, since it is needed for the barycentric computations inside computeAnisotropicEllipseAxes().
    computeAnisotropicEllipseAxes(v.posW, v.faceNormalW, WorldRayDirection(), coneRadiusAtHitPoint, positions, txcoords, v.texC, ddx, ddy);
}

float3 computeDdxPosW(float3 posW, float3 normW)
{
    float3 projRight = normalize(cross(normW, cross(normW, gScene.camera.data.cameraV)));
    float distanceToHit = length(posW - gScene.camera.data.posW);
    float2 ddNdc = float2(2.f, -2.f) * (1.f / DispatchRaysDimensions().xy);
    float distRight = distanceToHit * ddNdc.x / dot(normalize(gScene.camera.data.cameraV), projRight);
    return distRight * projRight;
}

float3 computeDdyPosW(float3 posW, float3 normW)
{
    float3 projUp = normalize(cross(normW, cross(normW, gScene.camera.data.cameraU)));
    float distanceToHit = length(posW - gScene.camera.data.posW);
    float2 ddNdc = float2(2.f, -2.f) * (1.f / DispatchRaysDimensions().xy);
    float distUp = distanceToHit * ddNdc.y / dot(normalize(gScene.camera.data.cameraU), projUp);
    return distUp * projUp;
}

/** Closest hit shader for primary rays.
*/
[shader("closesthit")]
void closestHit(
    uniform HitShaderParams hitParams,
    inout RayData rayData,
    BuiltInTriangleIntersectionAttributes attribs)
{
    uint2 launchIndex = DispatchRaysIndex().xy;

    const uint meshInstanceID = hitParams.getGlobalHitID();
    const uint materialID = gScene.getMaterialID(meshInstanceID);
    const uint triangleIndex = PrimitiveIndex();
    VertexData v = getVertexData(hitParams, triangleIndex, attribs);

#if USE_RAY_DIFFERENTIALS
    float2 ddx, ddy;
    computeRayDifferentials(meshInstanceID, triangleIndex, WorldRayDirection(), RayTCurrent(), ddx, ddy, gScene.camera);
    ShadingData sd = prepareShadingData(v, materialID, gScene.materials[materialID], gScene.materialResources[materialID], -WorldRayDirection(), ddx, ddy);
#elif USE_RAY_CONES
    float2 ddx, ddy;
    computeAnisotropicAxesRayCones(meshInstanceID, triangleIndex, v, ddx, ddy);
    ShadingData sd = prepareShadingData(v, materialID, gScene.materials[materialID], gScene.materialResources[materialID], -WorldRayDirection(), ddx, ddy);
#else
    ShadingData sd = prepareShadingData(v, materialID, gScene.materials[materialID], gScene.materialResources[materialID], -WorldRayDirection(), 0.f);
#endif

#if ADJUST_SHADING_NORMALS
    adjustShadingNormal(sd, v);
#endif

    // Write the outputs.
    GBuffer gbuf = storeGBufferOutput(sd, v);

    gPosW[launchIndex]              = gbuf.posW;
    gNormW[launchIndex]             = gbuf.normW;
    gTangentW[launchIndex]          = gbuf.tangentW;
    gTexC[launchIndex]              = gbuf.texC;
    gDiffuseOpacity[launchIndex]    = gbuf.diffuseOpacity;
    gSpecRough[launchIndex]         = gbuf.specRough;
    gEmissive[launchIndex]          = gbuf.emissive;
    gMatlExtra[launchIndex]         = gbuf.matlExtra;

    if (isValid(gFaceNormalW))
    {
        gFaceNormalW[launchIndex] = float4(v.faceNormalW, 0.f);
    }

    if (isValid(gLinearZ))
    {
        float4 curPosH = mul(float4(sd.posW, 1.f), gScene.camera.data.viewProjMatNoJitter);
        float curLinearZ = curPosH.w;

        // TODO: Improve computation of derivatives:
        float3 ddxPosW = computeDdxPosW(sd.posW, sd.faceN);
        float3 ddyPosW = computeDdyPosW(sd.posW, sd.faceN);
        float4 curPosH_dx = mul(float4(sd.posW + ddxPosW, 1.f), gScene.camera.data.viewProjMatNoJitter);
        float4 curPosH_dy = mul(float4(sd.posW + ddxPosW, 1.f), gScene.camera.data.viewProjMatNoJitter);
        float ddxLinearZ = abs(curPosH_dx.w - curLinearZ);
        float ddyLinearZ = abs(curPosH_dy.w - curLinearZ);
        float dLinearZ = max(ddxLinearZ, ddyLinearZ);
        gLinearZ[launchIndex] = float2(curLinearZ, dLinearZ);
    }

    // Output a device Z-buffer similar to raster
    if (isValid(gDeviceZ))
    {
        float4 curPosH = mul(float4(sd.posW, 1.f), gScene.camera.data.viewProjMatNoJitter);
        gDeviceZ[launchIndex] = curPosH.z / curPosH.w;
    }

    // Compute motion vectors.
    if (isValid(gMotionVectors))
    {
        float2 pixelPos = launchIndex + float2(0.5f, 0.5f);
        float3 prevPosW = getPrevPosW(hitParams, triangleIndex, attribs);
        float4 prevPosH = mul(float4(prevPosW, 1.f), gScene.camera.data.prevViewProjMatNoJitter);
        float2 motionVec = calcMotionVector(pixelPos, prevPosH, gParams.frameSize) + float2(gScene.camera.data.jitterX, -gScene.camera.data.jitterY); // Remove camera jitter from motion vector
        gMotionVectors[launchIndex] = motionVec;
    }

    // Encode hit information.
    if (isValid(gVBuffer))
    {
        HitInfo hit;
        hit.type = InstanceType::TriangleMesh;
        hit.instanceID = hitParams.getGlobalHitID();
        hit.primitiveIndex = PrimitiveIndex();
        hit.barycentrics = attribs.barycentrics;
        gVBuffer[launchIndex] = hit.encode();
    }
}


/** ************************** Custom primitives *************************** */

[shader("intersection")]
void unusedIsect()
{
}

[shader("closesthit")]
void unusedChit(inout RayData rayData : SV_RayPayload, BuiltInTriangleIntersectionAttributes attribs : SV_IntersectionAttributes)
{
}


/** ******************************** RayGen ******************************** */

[shader("raygeneration")]
void rayGen()
{
    uint2 launchIndex = DispatchRaysIndex().xy;
    uint2 launchDim = DispatchRaysDimensions().xy;

    GpuTimer timer;
    if (isValid(gTime)) timer.start();

    // Sample ray
#if USE_DEPTH_OF_FIELD
    SampleGenerator sg = SampleGenerator.create(launchIndex, gParams.frameCount);
    RayDesc ray = gScene.camera.computeRayThinlens(launchIndex, launchDim, sampleNext2D(sg)).toRayDesc();
#else
    RayDesc ray = gScene.camera.computeRayPinhole(launchIndex, launchDim).toRayDesc();
#endif

    // Trace ray
    RayData rayData;
    TraceRay(gRtScene, gParams.rayFlags, 0xff /* instanceInclusionMask */, 0 /* hitIdx */, hitProgramCount, 0 /* missIdx */, ray, rayData);

    // Write view direction.
    if (isValid(gViewW))
    {
        gViewW[launchIndex] = float4(-ray.Direction, 0.f);
    }

    // Write time.
    if (isValid(gTime)) gTime[launchIndex] = timer.getElapsed();
}


#ifdef USE_CURVES
/** ******************************** Curve intersection ******************************** */

[shader("intersection")]
void trivialIntersection(uniform HitShaderParams hitParams)
{
    BuiltInTriangleIntersectionAttributes attribs;
    ReportHit(RayTCurrent(), 0, attribs);
}

[shader("intersection")]
void linearSweptSphereIntersection(uniform HitShaderParams hitParams)
{
    BuiltInTriangleIntersectionAttributes attribs;

    float3 rayDir = WorldRayDirection();
    const float rayLength = length(rayDir);
    const float invRayLength = 1.f / rayLength;
    rayDir *= invRayLength;

    const float tmax = RayTCurrent();

    uint curveInstanceID = gScene.getCurveInstanceID(InstanceID(), hitParams.geometryIndex);
    uint v0Index = gScene.getFirstCurveVertexIndex(curveInstanceID, PrimitiveIndex());
    StaticCurveVertexData v0 = gScene.getCurveVertex(v0Index);
    StaticCurveVertexData v1 = gScene.getCurveVertex(v0Index + 1);

    float2 result;
    bool isect = intersectLinearSweptSphere(WorldRayOrigin(), rayDir, float4(v0.position, v0.radius), float4(v1.position, v1.radius), result);
    result.x *= invRayLength;

    if (isect && result.x < RayTCurrent())
    {
        attribs.barycentrics = float2(result.y, 0.f);
        ReportHit(result.x, 0, attribs);
    }
}

// Functions mostly identical to primaryClosestHit()
[shader("closesthit")]
void curveClosestHit(uniform HitShaderParams hitParams, inout RayData hitData, in BuiltInTriangleIntersectionAttributes attribs)
{
    uint2 launchIndex = DispatchRaysIndex().xy;

    const float3 posW = WorldRayOrigin() + RayTCurrent() * WorldRayDirection();
    const uint curveInstanceID = gScene.getCurveInstanceID(InstanceID(), hitParams.geometryIndex);
    const uint curveSegIndex = PrimitiveIndex();
    const uint materialID = gScene.getCurveMaterialID(curveInstanceID);

    float radius;
    VertexData v = gScene.getVertexDataFromCurve(curveInstanceID, curveSegIndex, attribs.barycentrics.x, posW, radius);

    ShadingData sd = prepareShadingData(v, materialID, gScene.materials[materialID], gScene.materialResources[materialID], -WorldRayDirection(), 0.f);

    GBuffer gbuf = storeGBufferOutput(sd, v);

    gPosW[launchIndex] = float4(gbuf.posW.xyz, radius);
    gNormW[launchIndex] = gbuf.normW;
    gTangentW[launchIndex] = gbuf.tangentW;
    gTexC[launchIndex] = gbuf.texC;
    gDiffuseOpacity[launchIndex] = gbuf.diffuseOpacity;
    gSpecRough[launchIndex] = gbuf.specRough;
    gEmissive[launchIndex] = gbuf.emissive;
    gMatlExtra[launchIndex] = gbuf.matlExtra;

    if (isValid(gFaceNormalW))
    {
        gFaceNormalW[launchIndex] = float4(v.faceNormalW, 0.f);
    }

    if (isValid(gLinearZ))
    {
        float4 curPosH = mul(float4(sd.posW, 1.f), gScene.camera.data.viewProjMatNoJitter);
        float curLinearZ = curPosH.w;

        // TODO: Improve computation of derivatives:
        float3 ddxPosW = computeDdxPosW(sd.posW, sd.faceN);
        float3 ddyPosW = computeDdyPosW(sd.posW, sd.faceN);
        float4 curPosH_dx = mul(float4(sd.posW + ddxPosW, 1.f), gScene.camera.data.viewProjMatNoJitter);
        float4 curPosH_dy = mul(float4(sd.posW + ddxPosW, 1.f), gScene.camera.data.viewProjMatNoJitter);
        float ddxLinearZ = abs(curPosH_dx.w - curLinearZ);
        float ddyLinearZ = abs(curPosH_dy.w - curLinearZ);
        float dLinearZ = max(ddxLinearZ, ddyLinearZ);
        gLinearZ[launchIndex] = float2(curLinearZ, dLinearZ);
    }

    // TODO: Compute motion vectors for curves.
    if (isValid(gMotionVectors))
    {
        gMotionVectors[launchIndex] = float2(0.f);
    }

    // Encode hit information.
    if (isValid(gVBuffer))
    {
        HitInfo hit;
        hit.type = InstanceType::Curve;
        hit.instanceID = curveInstanceID;
        hit.primitiveIndex = PrimitiveIndex();
        hit.barycentrics = attribs.barycentrics;
        gVBuffer[launchIndex] = hit.encode();
    }
}
#endif
