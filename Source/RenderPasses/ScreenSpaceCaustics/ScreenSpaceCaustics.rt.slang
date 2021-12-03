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
#include "Experimental/Scene/Lights/EmissiveLightSamplerType.slangh"
#include "Utils/Math/MathConstants.slangh"
#include "LightSampling.slang"
#include "ProjectionLightSampling.slang"

#define SURFACE_AREA_METHOD_PIXEL_CORNER_PROJECTION             0
#define SURFACE_AREA_METHOD_KIM_2019                            1

import ScreenSpaceCausticsHelper;
import ScreenSpaceCausticsParams;

import RenderPasses.Shared.PathTracer.InteriorListHelpers;
import RenderPasses.Shared.PathTracer.LoadShadingData;
import RenderPasses.Shared.PathTracer.PathTracerHelpers;
import RenderPasses.Shared.PathTracer.PixelStats;
import RenderPasses.Shared.PathTracer.RayFootprint;
import Scene.HitInfo;
import Scene.Raytracing;
import Utils.AccelerationStructures.CachingViaBVH;
import Utils.Debug.PathDebug;
import Utils.Debug.PixelDebug;
import Utils.Math.AABB;
//import Utils.Timing.GpuTimer;

/** Shared caustic renderer data.
    The ray tracing program instantiates this and passes it to all functions.
*/
struct ScreenSpaceCausticsData
{
    ScreenSpaceCausticsParams customParams; ///< ScreenSpaceCaustics parameters.
    PathTracerParams          params;             ///< PathTracer shared parameters.
    EnvMapSampler             envMapSampler;      ///< Environment map sampler.
    EmissiveLightSampler      emissiveSampler;    ///< Emissive light sampler.

    ActiveTriangleData                       activeTriangleData;
    RaytracingAccelerationStructure          aabbBVH;
    Buffer<uint>                             pixelCoords;
    StructuredBuffer<CachingPointData>       cachingPointData;
    StructuredBuffer<PathToCachingPointData> pathToCachingPointData;
    uint maxContributedToCollectingPoints;

    RWByteAddressBuffer                      statsOutput;
};

struct Payload
{
    PackedHitInfo packedHitInfo;        ///< Packed HitInfo data, or kInvalidIndex in the first component if ray missed.
};

struct AABBPayload
{
    float3 thp;
    uint materialIDAndDepthAndHitCollectingPoints; // High 16 bits: material ID, low high 8 bits: depth of current light ray, low 8 bits: amount of contributed to collecting points.
};

struct AABBAttributes
{
    uint aabbIndex;
};

ParameterBlock<ScreenSpaceCausticsData> gData;

// Outputs (optional)
RWTexture2D<uint> gOutputTime;

// Static configuration based on which buffers are bound.
#define isValid(name) (is_valid_##name != 0)

static const bool kForceOpaque = !kUseAlphaTest;
static const bool kUseCache = USE_CACHE != 0 ? true : false;
static const uint kInvalidAabbIndex = 0xFFFFFFFF;
static const bool kCapContributedToCollectingPoints = CAP_COLLECTING_POINTS;
static const bool kApplyBSDFLate = LATE_BSDF_APPLICATION != 0 ? true : false;


/** ********************* Ray index 0: Scatter ray ************************ */

[shader("miss")]
void miss(inout Payload rayData : SV_RayPayload)
{
}

[shader("anyhit")]
void anyHit(
    uniform HitShaderParams hitParams,
    inout Payload rayData : SV_RayPayload, BuiltInTriangleIntersectionAttributes attribs : SV_IntersectionAttributes)
{
#if USE_ALPHA_TEST
    // Alpha test for non-opaque geometry.
    VertexData v = getVertexData(hitParams, PrimitiveIndex(), attribs);
    const uint materialID = gScene.getMaterialID(hitParams.getGlobalHitID());
    if (alphaTest(v, gScene.materials[materialID], gScene.materialResources[materialID], 0.f)) IgnoreHit();
#endif
}

[shader("closesthit")]
void closestHit(
    uniform HitShaderParams hitParams,
    inout Payload rayData : SV_RayPayload, BuiltInTriangleIntersectionAttributes attribs : SV_IntersectionAttributes)
{
    // Store hit information. Note we don't access the materials here.
    HitInfo hit;
    hit.type = InstanceType::TriangleMesh;
    hit.instanceID = hitParams.getGlobalHitID();
    hit.primitiveIndex = PrimitiveIndex();
    hit.barycentrics = attribs.barycentrics;
    rayData.packedHitInfo = hit.encode();
}


/** ********************* AABB intersection ************************ */

[shader("miss")]
void aabbMiss(inout AABBPayload rayData : SV_RayPayload)
{
}

[shader("anyhit")]
void aabbAnyHit(
    inout AABBPayload rayData : SV_RayPayload, AABBAttributes attribs : SV_IntersectionAttributes)
{
    if (kCapContributedToCollectingPoints && (rayData.materialIDAndDepthAndHitCollectingPoints & 0xFF) >= gData.maxContributedToCollectingPoints)
        AcceptHitAndEndSearch();

    const uint packedPixelCoords = gData.pixelCoords[attribs.aabbIndex];
    if (packedPixelCoords == kInvalidPixelEntry) IgnoreHit();

    const uint2 pixelCoords = unpackPixelCoords(packedPixelCoords);
    const uint pixelLinearIndex = linearisePixelCoords(pixelCoords, gData.params.frameDim);
    const CachingPointData cachingData = gData.cachingPointData[pixelLinearIndex];

    const uint depthAndMaterialID = cachingData.depthAndMaterialID;
    const float3 photonToCollectionPoint = cachingData.position - WorldRayOrigin();
    const float dist2 = dot(photonToCollectionPoint, photonToCollectionPoint);
    const float t = sqrt(dist2);
    if (t > cachingData.searchRadius ||
        abs(dot(photonToCollectionPoint, cachingData.normal)) > 1e-2f) IgnoreHit();

    const uint collectionPointCurrentDepth = depthAndMaterialID >> 16;
    const uint hitCurrentDepth = (rayData.materialIDAndDepthAndHitCollectingPoints >> 8) & 0xFF;
    if ((hitCurrentDepth + collectionPointCurrentDepth) >= kMaxBounces + 1) IgnoreHit();

    const PathToCachingPointData cameraPathData = gData.pathToCachingPointData[pixelLinearIndex];
    const uint hitMaterialID = rayData.materialIDAndDepthAndHitCollectingPoints >> 16u;
    const uint collectionPointMaterialID = cameraPathData.materialIDAndHitInfoType >> 16u;
    if (hitMaterialID != collectionPointMaterialID) IgnoreHit();

    float3 reflectedFlux = rayData.thp;
    if (!kApplyBSDFLate)
    {
        const HitInfo hitInfo = getHitInfo(cameraPathData);
        StaticVertexData triangleVertices2[3];
        const VertexData v2 = gScene.getVertexData(hitInfo, triangleVertices2);
        const ShadingData sd = prepareShadingData(v2, collectionPointMaterialID, gScene.materials[collectionPointMaterialID], gScene.materialResources[collectionPointMaterialID], WorldRayDirection(), 0.f);

        reflectedFlux *= evalBSDF(sd, cameraPathData.incomingCameraDir);
        if (cachingData.searchRadius > 0.0f)
        {
            reflectedFlux *= 1.0f / (M_PI * cachingData.searchRadius * cachingData.searchRadius);
        }
    }

    if (all(reflectedFlux <= float3(0.0f))) IgnoreHit();

    const uint address = pixelLinearIndex * 16U/* sizeof(uint4) */;
    //interlockedAddFloat3(gData.statsOutput, address, reflectedFlux);
    uint foo;
    gData.statsOutput.InterlockedAdd(address + 0 * 4, toFixed(reflectedFlux.r), foo);
    gData.statsOutput.InterlockedAdd(address + 1 * 4, toFixed(reflectedFlux.g), foo);
    gData.statsOutput.InterlockedAdd(address + 2 * 4, toFixed(reflectedFlux.b), foo);
    gData.statsOutput.InterlockedAdd(address + 3 * 4, 1u, foo);

    // TODO: Could become a problem if we contribute to more than 256 collecting points, but if that happens we have bigger issues.
    if (rayData.materialIDAndDepthAndHitCollectingPoints >= 255)
    {
        rayData.materialIDAndDepthAndHitCollectingPoints &= 0xFFFFFF00;
    }
    ++rayData.materialIDAndDepthAndHitCollectingPoints;

    // XXX: Is it really needed?
    // Ignore the hit to ensure all AABBs within the distance gets processed,
    // even if they are further away.
    IgnoreHit();
}

[shader("intersection")]
void aabbIntersection()
{
    AABBAttributes attribs;
    const uint aabbIndex = getAabbIndex(GeometryIndex(), PrimitiveIndex(), gData.params.frameDim);
    attribs.aabbIndex = aabbIndex;

    ReportHit(0.0f, 0/*hitKind*/, attribs);
}

/** Traces a scatter ray.
    \param[in] origin Ray origin for the shadow ray.
    \param[in] dir Direction from ray origin towards the light source (normalized).
    \param[in,out] interiorList Interior list for handling nested dielectrics.
    \param[out] hit Hit information. The 'instanceID' field is set to HitInfo::kInvalidIndex upon miss.
    \return True if scatter ray hit something, false otherwise.
*/
bool traceScatterRay(float3 origin, float3 dir, inout InteriorList interiorList, out HitInfo hit)
{
    hit = {};
    hit.instanceID = HitInfo::kInvalidIndex;

    // Setup ray based on params passed via payload.
    RayDesc ray;
    ray.Origin = origin;
    ray.Direction = dir;
    ray.TMin = 0.f;
    ray.TMax = kRayTMax;

    Payload rayData;
    uint rejectedHits = 0;

    // For nested dielectrics, we potentially have to trace additional rays after false intersections.
    while (true)
    {
        rayData.packedHitInfo = { HitInfo::kInvalidIndex }; // Set the first component to kInvalidIndex

        uint rayFlags = RAY_FLAG_NONE; // TODO: Set cull mode from the app
        if (kForceOpaque) rayFlags |= RAY_FLAG_FORCE_OPAQUE;
        TraceRay(gRtScene, rayFlags, 0xff /* instanceInclusionMask */, kRayTypeScatter /* hitIdx */, hitProgramCount, kRayTypeScatter /* missIdx */, ray, rayData);

        logTraceRay(PixelStatsRayType::ClosestHit);

        // Check for false intersections.
        if (kUseNestedDielectrics && rayData.packedHitInfo.x != HitInfo::kInvalidIndex)
        {
            HitInfo tmpHit;
            tmpHit.decode(rayData.packedHitInfo);
            uint materialID = gScene.getMaterialID(tmpHit.instanceID);
            uint nestedPriority = gScene.materials[materialID].getNestedPriority();
            if (!interiorList.isTrueIntersection(nestedPriority))
            {
                if (rejectedHits < kMaxRejectedHits)
                {
                    rejectedHits++;
                    VertexData v = gScene.getVertexData(tmpHit);
                    bool frontFacing = dot(-ray.Direction, v.faceNormalW) >= 0.f;
                    interiorList.handleIntersection(materialID, nestedPriority, frontFacing);
                    ray.Origin = computeRayOrigin(v.posW, frontFacing ? -v.faceNormalW : v.faceNormalW);
                    continue;
                }
                else
                {
                    // Terminate path.
                    return false;
                }
            }
        }

        break;
    }

    if (rayData.packedHitInfo.x != HitInfo::kInvalidIndex)
    {
        hit.decode(rayData.packedHitInfo);
    }

    return true;
}

// Need to be kept alive until next scatter event for ray footprint to be updated after the ray bounces.
static StaticVertexData triangleVertices[3];
static VertexData v;

bool getWorldPosition(uint2 pixel, uint2 frameDim, out float3 posW)
{
#if USE_VBUFFER
    HitInfo hit;
    if (hit.decode(gVBuffer[pixel]))
    {
        VertexData vd = gScene.getVertexData(hit);
        posW = vd.posW;
        return true;
    }
    return false;
#else
    float4 worldPos = gWorldPosition[pixel];
    posW = worldPos.xyz;
    return worldPos.w != 0.f; // Using w to indicate valid geometry for now.
#endif
}

bool isPositionVisible(const float3 positionToTest, uint2 frameDim, const Camera camera, out uint2 pixel)
{
    const float4 clipPos = mul(float4(positionToTest, 1.0f), camera.getViewProj());
    const float3 ndcPos = clipPos.xyz / clipPos.w;
    if (any(ndcPos < float3(-1.0f)) || any(ndcPos > float3(1.0f))) return false;
    // Need to invert the y. For Vulkan, the clip-space is inverted, so no need to do anything
#ifdef FALCOR_D3D
    ndcPos.y = -ndcPos.y;
#endif
    const float3 normScreenPos = (ndcPos + 1.0f) * 0.5f;
    pixel = normScreenPos.xy * frameDim;

    float3 primaryWorldPosition;
    const bool hasValidPosition = getWorldPosition(pixel, frameDim, primaryWorldPosition);
    if (!hasValidPosition) return false;

    const float3 view = camera.getPosition() - primaryWorldPosition;

    const float4 primaryClipPos = mul(float4(primaryWorldPosition, 1.0f), camera.getViewProj());
    const float3 primaryNdcPos = primaryClipPos.xyz / primaryClipPos.w;
    // Need to invert the y. For Vulkan, the clip-space is inverted, so no need to do anything
#ifdef FALCOR_D3D
    primaryNdcPos.y = -primaryNdcPos.y;
#endif
    const float3 primaryNormScreenPos = (primaryNdcPos + 1.0f) * 0.5f;
    return normScreenPos.z <= (primaryNormScreenPos.z + 1e-3f);
}

void storePhotonKim19(const ScreenSpaceCausticsData ssc, const Camera camera, const ShadingData sd, const PathData path)
{
    // Test if hit point is visible.
    uint2 pixel;
    const bool isPointVisible = isPositionVisible(sd.posW, ssc.params.frameDim, camera, pixel);
    if (isPointVisible)
    {
        const float3 toViewSample = camera.data.posW - sd.posW;
        const float distanceToViewSample = length(toViewSample);

#if defined(SURFACE_AREA_METHOD) && SURFACE_AREA_METHOD == SURFACE_AREA_METHOD_KIM_2019 // From Kim 2019
        const float fdRatio = camera.data.focalLength / distanceToViewSample;
        const float invPixelArea = fdRatio * (((float) ssc.params.frameDim.x) / camera.data.frameWidth)
                                 * fdRatio * (((float) ssc.params.frameDim.y) / camera.data.frameHeight);
#else // SURFACE_AREA_METHOD_PIXEL_CORNER_PROJECTION
        bool isComputationValid = false;
        const float area = camera.estimateAreaUnderPixel(sd.posW, sd.N, pixel, ssc.params.frameDim, isComputationValid);
        const float invPixelArea = isComputationValid ? 1.0f / max(FLT_MIN, area) : 0.0f;
#endif

        const float3 Le = invPixelArea * path.thp * evalBSDF(sd, toViewSample / distanceToViewSample);

        const uint linearPixelIndex = pixel.y * ssc.params.frameDim.x + pixel.x;
        const uint address = linearPixelIndex * 16U /* 4 * sizeof(float) */;
        //interlockedAddFloat3(gData.statsOutput, address, Le);
        uint foo;
        gData.statsOutput.InterlockedAdd(address + 0 * 4, toFixed(Le.r), foo);
        gData.statsOutput.InterlockedAdd(address + 1 * 4, toFixed(Le.g), foo);
        gData.statsOutput.InterlockedAdd(address + 2 * 4, toFixed(Le.b), foo);
        gData.statsOutput.InterlockedAdd(address + 3 * 4, 1u, foo);
    }
}

void storePhotonCached(const ScreenSpaceCausticsData ssc, const Camera camera, const uint depth, const ShadingData sd, const PathData path)
{
    RayDesc ray;
    ray.Origin = sd.posW;
    ray.Direction = -path.dir;
    ray.TMin = 0.f;
    ray.TMax = FLT_EPSILON;

    AABBPayload rayData;
    rayData.thp = path.thp;
    rayData.materialIDAndDepthAndHitCollectingPoints = (sd.materialID << 16) | (depth << 8);
    TraceRay(ssc.aabbBVH, RAY_FLAG_SKIP_CLOSEST_HIT_SHADER, 0xff /* instanceInclusionMask */, 0 /* hitIdx */, 0 /* hitIdx multiplier */, 1 /* missIdx */, ray, rayData);
}

/** Handle scatter ray hit.
    \param[in] sd Shading data.
    \param[in,out] path Path data.
*/
void handleHit(const ScreenSpaceCausticsData ssc, const Camera camera, const uint seed, const uint depth, const bool storePhoton, inout ShadingData sd, inout PathData path)
{
    logPathVertex();

    // Get vertex data for current hit point. VertexData and triangleVertices kept alive out of handleHit() to be used by rayFootprint.bounceOnSurface() if needed.
    v = gScene.getVertexData(path.hit, triangleVertices);
    pathDebugSetRayHit(v.posW);

    // Update the ray footprint with current hit surface.
    path.rayFootprint.hitSurface(v, triangleVertices, path.hit, path.origin, path.dir);

    // Evaluate Falcor's material parameters at the hit point using the current ray footprint mode and doing texLOD.
    sd = prepareShadingData(v, path.rayFootprint, triangleVertices, path.hit, path.origin, path.dir);

    if (kAdjustShadingNormals) adjustShadingNormal(sd, v);

    if (kUseNestedDielectrics)
    {
        // Compute relative index of refraction at interface.
        sd.eta = computeRelativeIoR(path.interiorList, sd.materialID, sd.frontFacing);

        // Handle volume absorption.
        if (!path.interiorList.isEmpty())
        {
            const uint interiorMaterialID = path.interiorList.getTopMaterialID();
            float3 sigmaA = gScene.materials[interiorMaterialID].volumeAbsorption;
            float distance = length(path.origin - v.posW);
            path.thp *= exp(-sigmaA * distance);
        }
    }

    if (storePhoton)
    {
        if (kUseCache)
        {
            storePhotonCached(ssc, camera, depth, sd, path);
        }
        else
        {
            storePhotonKim19(ssc, camera, sd, path);
        }
    }

    path.length++;

    // Compute the ray origin for the next path segment.
    // The origin is offset slightly from the hit to avoid self-intersections.
    path.origin = sd.computeNewRayOrigin();
}

void tracePath(const ScreenSpaceCausticsData ssc, const uint2 launchIndex, const uint2 launchDim, const uint seed, inout PathData path)
{
    ShadingData sd;

    pathDebugAppendRay(path.origin, path.dir);

    // If the light sub-path length is 1 and the photon will not even be stored, there is no need to trace that ray even.
    if (ssc.customParams.usePhotonsForAll == 0 && kMaxBounces == 0u) return;

    // The path will either be directly terminated or a hit/miss is reported.
    if (!traceScatterRay(path.origin, path.dir, path.interiorList, path.hit)) return;

    // Handle scatter ray hit/miss.
    if (path.hit.instanceID != HitInfo::kInvalidIndex)
    {
        handleHit(ssc, gScene.camera, seed, 0u, ssc.customParams.usePhotonsForAll != 0, sd, path);
    }
    else
    {
        return;
    }

    if (kMaxBounces == 0u)
    {
        pathDebugSetRayHit(sd.posW);
        return;
    }

    bool hadOneSpecularBounce = false;

    // Note: Do not unroll loop even though iteration count is statically known,
    // as the shader gets very large and runs slower on current generation GPUs.
    [loop]
    for (uint depth = 0; depth < kMaxBounces; depth++)
    {
        // Russian roulette to stochastically terminate the path.
        // We use a fixed absorption probability for now.
        // TODO: Better strategy, e.g., 1-P(absorption) = hemispherical reflectance of BRDF.
        if (kUseRussianRoulette)
        {
            float u = sampleNext1D(path.sg);
            if (u < ssc.params.probabilityAbsorption) break;
            path.thp /= (1.f - ssc.params.probabilityAbsorption);
        }

        // Generate next path segment.
        if (!generateScatterRay(ssc.params, sd, path, path.sg))
        {
            pathDebugSetRayHit(sd.posW);
            return;
        }

        // Only store the photons if we had at least one specular bounce.
        hadOneSpecularBounce = path.isSpecular() || hadOneSpecularBounce;

        // Update ray origin on transmissive events.
        if (path.isTransmission()) path.origin = path.transmissionOrigin;

        pathDebugAppendRay(path.origin, path.dir);

        // The path will either be directly terminated or a hit/miss is reported.
        if (!traceScatterRay(path.origin, path.dir, path.interiorList, path.hit)) return;

        // Handle scatter ray hit/miss.
        if (path.hit.instanceID != HitInfo::kInvalidIndex)
        {
            handleHit(ssc, gScene.camera, seed, depth + 1u, hadOneSpecularBounce, sd, path);
        }
        else
        {
            break;
        }
    }
}

[shader("raygeneration")]
void rayGen()
{
    AABB projectionVolume;
    projectionVolume.set(gData.customParams.projectionVolumeMin, gData.customParams.projectionVolumeMax);

    const uint2 launchIndex = DispatchRaysIndex().xy;
    const uint2 launchDim = DispatchRaysDimensions().xy;

    logSetPixel(launchIndex);
    printSetPixel(launchIndex);
    pathDebugSetPathIndex(launchIndex.x);

    //GpuTimer timer;
    //if (isValid(gOutputTime)) timer.start();

    // Setup path data.
    PathData path = {};

    const uint frameSeed = gData.params.useFixedSeed ? gData.params.fixedSeed : gData.params.frameCount;
    //path.sg = SampleGenerator.create(launchIndex, frameSeed);
    path.sg = SampleGenerator.create(uint2(launchIndex.x % 1024, launchIndex.x / 1024), frameSeed);

    // Advance the generator to the first available dimension.
    // TODO: This is potentially expensive. We may want to store/restore the state from memory if it becomes a problem.
    for (uint i = 0; i < gData.params.prngDimension; i++) sampleNext1D(path.sg);

    LightSample ls;
    if (gData.customParams.ignoreProjectionVolume == 0)
    {
        const bool lightSampled = sampleSceneLights(projectionVolume, gData.emissiveSampler, gData.activeTriangleData, path.sg, ls);
        if (!lightSampled) return;
    }
    else
    {
        const bool lightSampled = sampleSceneLights(gData.envMapSampler, gData.emissiveSampler, gData.activeTriangleData, path.sg, ls);
        if (!lightSampled) return;
    }

    path.origin = ls.pos;
    path.dir = ls.dir;
    path.pdf = ls.pdf;
    path.thp = ls.Le / ((float) launchDim.x);

    // Trace the path
    tracePath(gData, launchIndex, launchDim, frameSeed, path);

    logPathLength(path.length);

    // Write time.
    //if (isValid(gOutputTime)) gOutputTime[launchIndex] = timer.getElapsed();
}
