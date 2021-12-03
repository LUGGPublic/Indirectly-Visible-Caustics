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
#include "Utils/Math/MathConstants.slangh"

import ScreenSpaceCausticsHelper;
import ScreenSpaceCausticsParams;

import Experimental.Scene.Lights.EmissiveLightSampler;
import Experimental.Scene.Material.MaterialShading;
import Experimental.Scene.Material.TexLODHelpers;
import RenderPasses.Shared.PathTracer.InteriorListHelpers;
import RenderPasses.Shared.PathTracer.LoadShadingData;
import RenderPasses.Shared.PathTracer.PathTracerHelpers;
import RenderPasses.Shared.PathTracer.RayFootprint;
import RenderPasses.Shared.PathTracer.StaticParams;
import Scene.HitInfo;
import Scene.Raytracing;
import Utils.AccelerationStructures.CachingViaBVH;
import Utils.Math.FormatConversion;
import Utils.Sampling.SampleGenerator;

static const bool kUseCache = USE_CACHE;
static const bool kUsePhotonsForAll = USE_PHOTONS_FOR_ALL;
static const bool kUseFixedSearchRadius = USE_FIXED_SEARCH_RADIUS;
static const bool kCapSearchRadius = CAP_SEARCH_RADIUS;
static const bool kSeparateAABBStorage = SEPARATE_AABB_STORAGE;

static const bool kForceOpaque = !kUseAlphaTest;
static const uint kInvalidAabbIndex = 0xFFFFFFFF;

// Static configuration based on which buffers are bound.
#define isValid(name) (is_valid_##name != 0)

#define MINIMISE_LIVE_STATE 1


struct CommonData
{
    PathTracerParams       params;
    EnvMapSampler          envMapSampler;
    EmissiveLightSampler   emissiveSampler;
};

struct CacheRelatedData
{
    float3                                     sceneMin;
    float                                      fixedSearchRadius;

    float3                                     sceneMax;
    float                                      maxSearchRadius;

    RWByteAddressBuffer                        aabbs;
    RWBuffer<uint>                             currentFramePixelCoords;
    RWStructuredBuffer<CachingPointData>       currentFrameCachingPointData;
    RWStructuredBuffer<PathToCachingPointData> pathToCachingPointData;
};


ParameterBlock<CommonData>       gCommonData;
ParameterBlock<CacheRelatedData> gCachingData;

// Outputs (optional)
RWTexture2D<float4>              gOutputColor;
RWTexture2D<float4>              gOutputAlbedo;


/** ****************** Scene: Ray index 0: Scatter ray ******************** */

/** Payload for scatter ray.
*/
struct ScatterRayData
{
    PackedHitInfo packedHitInfo;        ///< Packed HitInfo data, or kInvalidIndex in the first component if ray missed.
    float hitT;
};

[shader("miss")]
void scatterMiss(inout ScatterRayData rayData : SV_RayPayload)
{
}

[shader("anyhit")]
void scatterAnyHit(
    uniform HitShaderParams hitParams,
    inout ScatterRayData rayData : SV_RayPayload, BuiltInTriangleIntersectionAttributes attribs : SV_IntersectionAttributes)
{
#if USE_ALPHA_TEST
    // Alpha test for non-opaque geometry.
    VertexData v = getVertexData(hitParams, PrimitiveIndex(), attribs);
    const uint materialID = gScene.getMaterialID(hitParams.getGlobalHitID());
    if (alphaTest(v, gScene.materials[materialID], gScene.materialResources[materialID], 0.f)) IgnoreHit();
#endif
}

[shader("closesthit")]
void scatterClosestHit(
    uniform HitShaderParams hitParams,
    inout ScatterRayData rayData : SV_RayPayload, BuiltInTriangleIntersectionAttributes attribs : SV_IntersectionAttributes)
{
    // Store hit information. Note we don't access the materials here.
    HitInfo hit;
    hit.type = InstanceType::TriangleMesh;
    hit.instanceID = hitParams.getGlobalHitID();
    hit.primitiveIndex = PrimitiveIndex();
    hit.barycentrics = attribs.barycentrics;
    rayData.packedHitInfo = hit.encode();
    rayData.hitT = RayTCurrent();
}


/*********************** Scene: Ray index 1: Shadow ray ******************** */

/** Payload for shadow ray.
*/
struct ShadowRayData
{
    bool visible;
};

[shader("miss")]
void shadowMiss(inout ShadowRayData rayData : SV_RayPayload)
{
    // The miss shader is executed if the ray misses all geometry. Mark as visible.
    rayData.visible = true;
}

[shader("anyhit")]
void shadowAnyHit(
    uniform HitShaderParams hitParams,
    inout ShadowRayData rayData : SV_RayPayload, BuiltInTriangleIntersectionAttributes attribs : SV_IntersectionAttributes)
{
#if USE_ALPHA_TEST
    // Alpha test for non-opaque geometry.
    VertexData v = getVertexData(hitParams, PrimitiveIndex(), attribs);
    const uint materialID = gScene.getMaterialID(hitParams.getGlobalHitID());
    if (alphaTest(v, gScene.materials[materialID], gScene.materialResources[materialID], 0.f)) IgnoreHit();
#endif
}


/** ************************** Custom primitives *************************** */

[shader("intersection")]
void unusedIsect()
{
}

[shader("closesthit")]
void unusedChit(inout ScatterRayData rayData : SV_RayPayload, BuiltInTriangleIntersectionAttributes attribs : SV_IntersectionAttributes)
{
}


/** *************************** Helper functions ************************** */

#if defined(MINIMISE_LIVE_STATE) && MINIMISE_LIVE_STATE != 0
typedef float CacheData;
#else
struct CacheData
{
    PathToCachingPointData pathData;
    CachingPointData cachingData;
    float3 tangent;
    bool hasCachingEntry;
    float3 bitangent;
    float searchRadius;
};
#endif

float estimateRadiusUnderPixel(const Camera camera, const float3 viewSamplePosW, const float3 viewSampleNormW,
                               const uint2 pixel, const uint2 frameDim, out bool isValid)
{
    isValid = false;

    const float3 dirTL = camera.computeNonNormalizedRayDirPinhole(pixel, frameDim, float2(0.0f, 0.0f), false);
    const float3 dirTR = camera.computeNonNormalizedRayDirPinhole(pixel, frameDim, float2(1.0f, 0.0f), false);
    const float3 dirBL = camera.computeNonNormalizedRayDirPinhole(pixel, frameDim, float2(0.0f, 1.0f), false);
    const float3 dirBR = camera.computeNonNormalizedRayDirPinhole(pixel, frameDim, float2(1.0f, 1.0f), false);

    const float cosThetaTL = dot(viewSampleNormW, dirTL);
    const float cosThetaTR = dot(viewSampleNormW, dirTR);
    const float cosThetaBL = dot(viewSampleNormW, dirBL);
    const float cosThetaBR = dot(viewSampleNormW, dirBR);
    if (abs(cosThetaTL) <= FLT_MIN || abs(cosThetaTR) <= FLT_MIN ||
        abs(cosThetaBL) <= FLT_MIN || abs(cosThetaBR) <= FLT_MIN) return 0.0f;

    isValid = true;
    const float3 fromViewSample = camera.data.posW - viewSamplePosW;
    const float nom = dot(viewSampleNormW, -fromViewSample);

    const float tTL = nom / cosThetaTL;
    const float tTR = nom / cosThetaTR;
    const float tBL = nom / cosThetaBL;
    const float tBR = nom / cosThetaBR;

    // Projected point: data.posW + t * dir
    // Distance to projected point: || (data.posW + t * dir) - viewSamplePosW ||
    // |-> || (data.posW - viewSamplePosW) + t * dir ||
    const float3 projTL = fromViewSample + tTL * dirTL;
    const float3 projTR = fromViewSample + tTR * dirTR;
    const float3 projBL = fromViewSample + tBL * dirBL;
    const float3 projBR = fromViewSample + tBR * dirBR;

    const float distSqrTL = dot(projTL, projTL);
    const float distSqrTR = dot(projTR, projTR);
    const float distSqrBL = dot(projBL, projBL);
    const float distSqrBR = dot(projBR, projBR);

    return sqrt(max(max(distSqrTL, distSqrTR), max(distSqrBL, distSqrBR)));
}

void computeSearchRadius(ShadingData sd, RayFootprint rayFootprint, uint depth, uint2 launchIndex, inout float searchRadius)
{
    float rayConeHalfWidth;
    if (kRayFootprintMode == TexLODMode::RayCones) rayConeHalfWidth = (0.5f * abs(rayFootprint.rayCone.getWidth()));

    if (!kUseFixedSearchRadius || !(kRayFootprintMode == TexLODMode::RayCones))
    {
#define RADIUS_MTHD 2
#if RADIUS_MTHD == 2
        if (depth != 0)
        {
            searchRadius = rayConeHalfWidth / max(1e-3f, abs(dot(sd.faceN, sd.V)));
        }
        else
        {
            bool isValid;
            searchRadius = estimateRadiusUnderPixel(gScene.camera, sd.posW, sd.N,
                                                    launchIndex, gCommonData.params.frameDim, isValid);
            if (!isValid) searchRadius = rayConeHalfWidth / max(1e-3f, abs(dot(sd.faceN, sd.V)));
        }
#elif RADIUS_MTHD == 1
        searchRadius = rayConeHalfWidth / max(1e-3f, abs(dot(sd.faceN, sd.V)));
#else
        if (depth == 0)
        {
            bool isValid;
            searchRadius = estimateRadiusUnderPixel(gScene.camera, sd.posW, sd.N,
                                                    launchIndex, gCommonData.params.frameDim, isValid);
            if (!isValid) searchRadius = gCachingData.fixedSearchRadius;
        }
#endif
#undef RADIUS_MTHD
    }
    else
    {
        searchRadius = gCachingData.fixedSearchRadius;
    }
}

// Taken from https://fgiesen.wordpress.com/2009/12/13/decoding-morton-codes/
uint interleave10b(uint v)
{
    v &= 0x0000ffff;                  // x = ---- ---- ---- ---- fedc ba98 7654 3210
    v = (v ^ (v << 8)) & 0x00ff00ff; // x = ---- ---- fedc ba98 ---- ---- 7654 3210
    v = (v ^ (v << 4)) & 0x0f0f0f0f; // x = ---- fedc ---- ba98 ---- 7654 ---- 3210
    v = (v ^ (v << 2)) & 0x33333333; // x = --fe --dc --ba --98 --76 --54 --32 --10
    v = (v ^ (v << 1)) & 0x55555555; // x = -f-e -d-c -b-a -9-8 -7-6 -5-4 -3-2 -1-0
    return v;
}

uint computeMortonCode(float3 aabbCentre)
{
    const float3 posRelativeToSceneAabb = (aabbCentre + gCachingData.sceneMin) / gCachingData.sceneMax;
    const uint3 quantifiedPos = uint3(posRelativeToSceneAabb * float3(float(1 << 10)));

    uint mortonCode = (interleave10b(quantifiedPos.z) << 2) | (interleave10b(quantifiedPos.y) << 1) | interleave10b(quantifiedPos.x);
    return mortonCode;
}

#if defined(MINIMISE_LIVE_STATE) && MINIMISE_LIVE_STATE != 0
bool processHit(const ShadingData sd, const PathData path, const float3 thp, uint depth, const HitInfo hitInfo, float searchRadius)
{
    if ((!path.isDelta() && !path.isTransmission() &&
         (!path.isSpecular() || sd.linearRoughness > gCommonData.params.specularRoughnessThreshold)))
    {
        const uint2 launchIndex = DispatchRaysIndex().xy;
        const uint pixelLinearIndex = linearisePixelCoords(launchIndex, gCommonData.params.frameDim);
        if (kCapSearchRadius) searchRadius = min(searchRadius, gCachingData.maxSearchRadius);

        // Store AABB
        if (!kSeparateAABBStorage)
        {
            const uint aabbOffset = computeAabbOffset(launchIndex, gCommonData.params.frameDim);

            //const float3 upVector = 0.1f * searchRadius * sd.N;
            //const float3 frontVector = searchRadius * sd.T;
            //const float3 rightVector = searchRadius * sd.B;
            const float3 upVector = searchRadius * float3(0.0f, 1.0f, 0.0f);
            const float3 frontVector = searchRadius * float3(1.0f, 0.0f, 0.0f);
            const float3 rightVector = searchRadius * float3(0.0f, 0.0f, 1.0f);

            AABB aabb = {float3(FLT_MAX), float3(-FLT_MAX)};
            aabb.include(sd.posW - frontVector - rightVector - upVector);
            aabb.include(sd.posW - frontVector + rightVector - upVector);
            aabb.include(sd.posW + frontVector - rightVector - upVector);
            aabb.include(sd.posW + frontVector + rightVector - upVector);
            aabb.include(sd.posW - frontVector - rightVector + upVector);
            aabb.include(sd.posW - frontVector + rightVector + upVector);
            aabb.include(sd.posW + frontVector - rightVector + upVector);
            aabb.include(sd.posW + frontVector + rightVector + upVector);

            storeAabb(gCachingData.aabbs, aabbOffset, aabb);
        }

        // Store CachingPointData
        {
            CachingPointData cachingData = {};
            cachingData.position = sd.posW;
            cachingData.searchRadius = searchRadius;
            cachingData.normal = sd.N;
            cachingData.depthAndMaterialID = (depth << 16) | (sd.materialID & 0xFFFF);
            gCachingData.currentFrameCachingPointData[pixelLinearIndex] = cachingData;
        }

        // Store PathToCachingPointData
        {
            PathToCachingPointData pathData = {};
            pathData.incomingCameraDir = sd.V;
            pathData.searchRadius = searchRadius;
            pathData.pathThroughput = thp;
            setHitInfo(hitInfo, pathData);
            pathData.materialIDAndHitInfoType |= sd.materialID << 16u;
            gCachingData.pathToCachingPointData[pixelLinearIndex] = pathData;
        }

        return true;
    }

    return false;
}

void storeInformationForCaching(uint2 launchIndex, bool hasCachingEntry)
{
    const uint aabbOffset = computeAabbOffset(launchIndex, gCommonData.params.frameDim);
    gCachingData.currentFramePixelCoords[aabbOffset] = hasCachingEntry ? packPixelCoords(launchIndex) : kInvalidPixelEntry;

    if (!hasCachingEntry)
    {
        const uint pixelLinearIndex = linearisePixelCoords(launchIndex, gCommonData.params.frameDim);

        if (!kSeparateAABBStorage)
        {
            // Mark the AABB as inactive
            AABB aabb = {float3(kQNaN), float3(kQNaN)};
            storeAabb(gCachingData.aabbs, aabbOffset, aabb);
        }

        PathToCachingPointData pathData = {};
        pathData.searchRadius = -1.0f;
        gCachingData.pathToCachingPointData[pixelLinearIndex] = pathData;
    }
}
#else
bool processHit(ShadingData sd, PathData path, float3 thp, uint depth, PackedHitInfo packedHitInfo, inout CacheData cacheData)
{
    if ((!path.isDelta() && !path.isTransmission() &&
         (!path.isSpecular() || sd.linearRoughness > gCommonData.params.specularRoughnessThreshold)))
    {
        cacheData.cachingData.position = sd.posW;
        cacheData.cachingData.normal = sd.N;
        cacheData.cachingData.depthAndMaterialID = (depth << 16) | (sd.materialID & 0xFFFF);
        cacheData.tangent = sd.T;
        cacheData.bitangent = sd.B;

        cacheData.pathData.incomingCameraDir = sd.V;
        cacheData.pathData.pathThroughput = thp;
        cacheData.pathData.packedHitInfo.xy = packedHitInfo.xy;
#if ((HIT_INSTANCE_TYPE_BITS) + (HIT_INSTANCE_INDEX_BITS) + (HIT_PRIMITIVE_INDEX_BITS)) <= 32
#elif ((HIT_INSTANCE_TYPE_BITS) + (HIT_INSTANCE_INDEX_BITS)) <= 32 && (HIT_PRIMITIVE_INDEX_BITS) <= 32
        cacheData.pathData.packedHitInfo.z = packedHitInfo.z;
#endif
        cacheData.pathData.materialID = sd.materialID;

        cacheData.hasCachingEntry = true;
        return true;
    }

    return false;
}

void storeInformationForCaching(CacheData cacheData, uint2 launchIndex)
{
    if (kCapSearchRadius) cacheData.searchRadius = min(cacheData.searchRadius, gCachingData.maxSearchRadius);

    if (cacheData.hasCachingEntry)
    {
        cacheData.cachingData.searchRadius = cacheData.searchRadius;
    }

    const uint aabbOffset = computeAabbOffset(launchIndex, gCommonData.params.frameDim);
    gCachingData.currentFramePixelCoords[aabbOffset] = cacheData.hasCachingEntry ? packPixelCoords(launchIndex) : kInvalidPixelEntry;

    if (!kSeparateAABBStorage)
    {
        AABB aabb = {float3(FLT_MAX), float3(-FLT_MAX)};
        if (cacheData.hasCachingEntry)
        {
            const float3 upVector = 0.1f * cacheData.searchRadius * cacheData.cachingData.normal;
            const float3 frontVector = cacheData.searchRadius * cacheData.bitangent;
            const float3 rightVector = cacheData.searchRadius * cacheData.tangent;

            aabb.include(cacheData.cachingData.position - frontVector - rightVector - upVector);
            aabb.include(cacheData.cachingData.position - frontVector + rightVector - upVector);
            aabb.include(cacheData.cachingData.position + frontVector - rightVector - upVector);
            aabb.include(cacheData.cachingData.position + frontVector + rightVector - upVector);
            aabb.include(cacheData.cachingData.position - frontVector - rightVector + upVector);
            aabb.include(cacheData.cachingData.position - frontVector + rightVector + upVector);
            aabb.include(cacheData.cachingData.position + frontVector - rightVector + upVector);
            aabb.include(cacheData.cachingData.position + frontVector + rightVector + upVector);
        }
        else
        {
            // Mark the AABB as inactive
            aabb.minPoint = float3(kQNaN);
            aabb.maxPoint = float3(kQNaN);
        }
        storeAabb(gCachingData.aabbs, aabbOffset, aabb);
    }

    const uint pixelLinearIndex = linearisePixelCoords(launchIndex, gCommonData.params.frameDim);
    gCachingData.currentFrameCachingPointData[pixelLinearIndex] = cacheData.cachingData;

    cacheData.pathData.aabbIndex = cacheData.hasCachingEntry ? aabbOffset : kInvalidAabbIndex;
    cacheData.pathData.searchRadius = cacheData.hasCachingEntry ? cacheData.searchRadius : 0.0f;
    gCachingData.pathToCachingPointData[pixelLinearIndex] = cacheData.pathData;
}
#endif

bool traceShadowRay(float3 origin, float3 dir, float distance, bool valid = true)
{
    // Setup ray descriptor.
    RayDesc ray;
    ray.Origin = origin;
    ray.Direction = dir;
    ray.TMin = 0.f;
    ray.TMax = valid ? distance : 0.f; // Set tmax = 0.0 for dummy rays.

    ShadowRayData rayData = { false }; // Set to true by miss shader if ray is not terminated before
    uint rayFlags = RAY_FLAG_SKIP_CLOSEST_HIT_SHADER | RAY_FLAG_ACCEPT_FIRST_HIT_AND_END_SEARCH;
    if (kForceOpaque) rayFlags |= RAY_FLAG_FORCE_OPAQUE;
    TraceRay(gRtScene, rayFlags, 0xff /* instanceInclusionMask */, kRayTypeShadow /* hitIdx */, hitProgramCount, kRayTypeShadow /* missIdx */, ray, rayData);

    // We let TraceRay() execute even when !valid in order to run the miss shader.
    // This is faster on current drivers thanks to reduced divergence.
    if (!valid) return false;

    return rayData.visible;
}

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

    ScatterRayData rayData;
    uint rejectedHits = 0;

    // For nested dielectrics, we potentially have to trace additional rays after false intersections.
    while (true)
    {
        rayData.packedHitInfo = { HitInfo::kInvalidIndex }; // Set the first component to kInvalidIndex

        uint rayFlags = RAY_FLAG_NONE; // TODO: Set cull mode from the app
        if (kForceOpaque) rayFlags |= RAY_FLAG_FORCE_OPAQUE;
        TraceRay(gRtScene, rayFlags, 0xff /* instanceInclusionMask */, kRayTypeScatter /* hitIdx */, hitProgramCount, kRayTypeScatter /* missIdx */, ray, rayData);

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

void handleHit(inout ShadingData sd, inout PathData path)
{
    // Get vertex data for current hit point. VertexData and triangleVertices kept alive out of handleHit() to be used by rayFootprint.bounceOnSurface() if needed.
    v = gScene.getVertexData(path.hit, triangleVertices);

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

    // Disable specular lobes if caustics are disabled and path already contains non-specular vertex.
    if (kDisableCaustics && path.nonSpecularBounces > 0 && sd.linearRoughness <= gCommonData.params.specularRoughnessThreshold)
    {
        sd.setActiveLobes((uint)LobeType::Diffuse);
    }

    // Check if the scatter event is samplable by the light sampling technique.
    const bool isLightSamplable = path.isLightSamplable();

    // Determine if we need to compute the emissive based on the current configuration.
    // It's only needed if emissive is enabled, and its full contribution hasn't been sampled elsewhere.
    const bool computeEmissive = kUseEmissiveLights && (kUseLightsInDielectricVolumes || !path.isInsideVolume()) && (!kUseNEE || kUseMIS || !isLightSamplable);

    if (computeEmissive && any(sd.emissive > 0.f))
    {
        float misWeight = 1.f;
        if (kUseNEE && kUseMIS && isLightSamplable)
        {
            // If emissive light sampling and MIS is enabled, we've already sampled emissive lights using NEE.
            // We need to evaluate the MIS weight here to account for the remaining contribution.

            // Prepare hit point struct with data needed for emissive light PDF evaluation.
            TriangleHit hit;
            hit.triangleIndex = gScene.lightCollection.getTriangleIndex(path.hit.instanceID, path.hit.primitiveIndex);
            hit.posW = sd.posW;
            hit.normalW = sd.frontFacing ? sd.faceN : -sd.faceN;

            // Evaluate PDF at the hit, had it been generated with light sampling.
            float lightPdf = gCommonData.emissiveSampler.evalPdf(path.origin, path.normal, true, hit) * getEmissiveLightSelectionPdf();

            // Compute MIS weight by combining this with BRDF sampling.
            // Note we can assume path.pdf > 0.f since we shouldn't have got here otherwise.
            misWeight = evalMIS(gCommonData.params, 1, path.pdf, kLightSamplesPerVertex, lightPdf);
        }

        // Accumulate emitted radiance weighted by path throughput and MIS weight.
        path.L += path.thp * sd.emissive * misWeight;
    }

    path.length++;

    // Compute the ray origin for the next path segment.
    // The origin is offset slightly from the hit to avoid self-intersections.
    path.origin = sd.computeNewRayOrigin();
}

void handleMiss(inout PathData path)
{
    // Check if the scatter event is samplable by the light sampling technique.
    const bool isLightSamplable = path.isLightSamplable();

    // If we have an environment, add it's weighted contribution here.
    if (kUseEnvLight && (kUseLightsInDielectricVolumes || !path.isInsideVolume()) && (!kUseNEE || kUseMIS || !isLightSamplable))
    {
        float misWeight = 1.f;
        if (kUseNEE && kUseMIS && isLightSamplable)
        {
            // We came here through BRDF sampling. The other sampling strategy is
            // env map sampling. Evaluate it's probability for the current ray dir.
            float lightPdf = gCommonData.envMapSampler.evalPdf(path.dir) * getEnvLightSelectionPdf();

            // Compute MIS weighted contribution from the environment map.
            misWeight = evalMIS(gCommonData.params, 1, path.pdf, kLightSamplesPerVertex, lightPdf);
        }

        float3 Le = gCommonData.envMapSampler.eval(path.dir);

        // Accumulate emitted radiance weighted by path throughput.
        path.L += path.thp * Le * misWeight;
    }
}

void evalDirect(ShadingData sd, inout PathData path)
{
    for (uint i = 0; i < kLightSamplesPerVertex; ++i)
    {
        ShadowRay shadowRay = {};
        bool valid = generateShadowRay(gCommonData.params, gCommonData.envMapSampler, gCommonData.emissiveSampler, sd, i, path, path.sg, shadowRay);
        bool visible = traceShadowRay(path.origin, shadowRay.rayParams.xyz, shadowRay.rayParams.w, valid);
        path.L += visible ? shadowRay.Lr : float3(0.f);
    }
}

void tracePath(ShadingData sd, inout PathData path, inout CacheData cacheData)
{
    // Always output directly emitted light from the primary hit.
    // This is independent of whether emissive materials are treated as light sources or not.
    path.L += sd.emissive;

    // Compute iteration count.
    // We always add one bounce for handling surfaces that cannot be handled using light sampling.
    const uint kIterationCount = kMaxBounces + 1;

    // Note: Do not unroll loop even though iteration count is statically known,
    // as the shader gets very large and runs slower on current generation GPUs.
    [loop]
    for (uint depth = 0; depth < kIterationCount; depth++)
    {
        // Determine if BSDF supports sampling with next-event estimation.
        // The following line generates bad code:
        // bool supportsNEE = (getBSDFLobes(sd) & (uint)LobeType::NonDeltaReflection) != 0;
        uint lobes = getBSDFLobes(sd);
        bool supportsNEE = (lobes & (uint)LobeType::DiffuseReflection) != 0 || (lobes & (uint)LobeType::SpecularReflection) != 0;

#if defined(MINIMISE_LIVE_STATE) && MINIMISE_LIVE_STATE != 0
        const bool stillGenerateAABBs = cacheData >= 0.0f && depth <= kMaxBounces;
#else
        const bool stillGenerateAABBs = !cacheData.hasCachingEntry && depth <= kMaxBounces;
#endif

        // Compute direct illumination.
        if (kUseNEE && supportsNEE && (kUseLightsInDielectricVolumes || !path.isInsideVolume()) && !kUsePhotonsForAll)
        {
            evalDirect(sd, path);
        }

        // Russian roulette to stochastically terminate the path.
        // We use a fixed absorption probability for now.
        // TODO: Better strategy, e.g., 1-P(absorption) = hemispherical reflectance of BRDF.
        if (kUseRussianRoulette)
        {
            float u = sampleNext1D(path.sg);
            if (u < gCommonData.params.probabilityAbsorption) break;
            path.thp /= (1.f - gCommonData.params.probabilityAbsorption);
        }

        // Save incoming ray direction for ray footprint.
        const float3 rayDirIn = path.dir;

        if (kUseCache && stillGenerateAABBs)
        {
#if defined(MINIMISE_LIVE_STATE) && MINIMISE_LIVE_STATE != 0
            computeSearchRadius(sd, path.rayFootprint, depth, DispatchRaysIndex().xy, cacheData);
#else
            computeSearchRadius(sd, path.rayFootprint, depth, DispatchRaysIndex().xy, cacheData.searchRadius);
#endif
        }

        // Save current througput for caching.
        const float3 thp = path.thp;

        // Generate next path segment.
        if (!generateScatterRay(gCommonData.params, sd, path, path.sg)) return;

        // Scatter the ray footprint out of the surface.\
        path.rayFootprint.bounceOnSurface(v, triangleVertices, path.hit, sd, v.normalW, rayDirIn, path.dir, path.isSpecular(), path.isTransmission());

        if (kUseCache && stillGenerateAABBs)
        {
#if defined(MINIMISE_LIVE_STATE) && MINIMISE_LIVE_STATE != 0
            const bool didProcessHit = processHit(sd, path, thp, depth, path.hit, cacheData);
            if (didProcessHit) cacheData = -cacheData;
#else
            const bool didProcessHit = processHit(sd, path, thp, depth, path.hit.encode(), cacheData);
#endif
            if (didProcessHit && kUsePhotonsForAll) return;
        }

        // Update ray origin on transmissive events.
        if (path.isTransmission()) path.origin = path.transmissionOrigin;

        // Check if this is the last path vertex.
        const bool isLastVertex = path.length == kMaxBounces || path.nonSpecularBounces > kMaxNonSpecularBounces;

        // Terminate if this is the last path vertex and light sampling already completely sampled incident radiance.
        if (isLastVertex && (kUseNEE && !kUseMIS && path.isLightSamplable())) return;

        // Terminate caustics paths.
        if (kDisableCaustics && path.isSpecular() && path.nonSpecularBounces > 0) return;

        // Trace scatter ray.
        // The path will either be directly terminated or a hit/miss is reported.
        if (!traceScatterRay(path.origin, path.dir, path.interiorList, path.hit)) return;

        // Handle scatter ray hit/miss.
        if (path.hit.instanceID != HitInfo::kInvalidIndex)
        {
            handleHit(sd, path);
        }
        else
        {
            handleMiss(path);
            break;
        }

        // Terminate after handling the last path vertex.
        if (isLastVertex) return;
    }
}


/** ******************************** RayGen ******************************* */

[shader("raygeneration")]
void rayGen()
{
    uint2 launchIndex = DispatchRaysIndex().xy;
    uint2 launchDim = DispatchRaysDimensions().xy;

    CacheData cacheData = {};
#if defined(MINIMISE_LIVE_STATE) && MINIMISE_LIVE_STATE != 0
#else
    cacheData.hasCachingEntry = false;
#endif
    float3 outColor = float3(0, 0, 0);
    float3 outAlbedo = float3(0, 0, 0);
    float outAlpha = 0.f;

    HitInfo hit;
    ShadingData sd;
    if (loadShadingData(launchIndex, launchDim, gScene.camera, sd, hit))
    {
        // Pixel represents a primary hit. Compute its contribution.

        // Compute ray origin for new rays spawned from the G-buffer.
        const float3 rayOrigin = sd.computeNewRayOrigin();

        // Loop over samples in pixel.
        [loop]
        for (uint sampleIdx = 0; sampleIdx < kSamplesPerPixel; sampleIdx++)
        {
            // Setup path data.
            PathData path = {};
            path.origin = rayOrigin;
            path.thp = float3(1.f);
            path.hit = hit;

            // Create sample generator.
            uint frameSeed = gCommonData.params.useFixedSeed ? gCommonData.params.fixedSeed : gCommonData.params.frameCount;
            path.sg = SampleGenerator.create(launchIndex, frameSeed * kSamplesPerPixel + sampleIdx);

            // Advance the generator to the first available dimension.
            // TODO: This is potentially expensive. We may want to store/restore the state from memory if it becomes a problem.
            for (uint i = 0; i < gCommonData.params.prngDimension; i++) sampleNext1D(path.sg);

            // TODO: Use (kRayFootprintMode != TexLODMode::Mip0) when slang is fixed.
            if (!(kRayFootprintMode == TexLODMode::Mip0))
            {
                // Create the ray footprint data for TexLOD.
                path.rayFootprint = RayFootprint.create(hit, launchIndex, launchDim, rayOrigin, gScene.camera.getPosition(), sd.faceN, sd.N, gCommonData.params.screenSpacePixelSpreadAngle, sd.linearRoughness, path.isSpecular());
            }

            // Trace the path.
            tracePath(sd, path, cacheData);

            // Accumulate after clamping.
            // Note the comparison is written so that NaNs propagate (unless the compiler rewrites it).
            // TODO: Check the generated code that this is the case.
            outColor += gCommonData.params.clampSamples && path.L > gCommonData.params.clampThreshold ? gCommonData.params.clampThreshold : path.L;
        }

        // We're done accumulating over all samples.
        const float invSpp = 1.f / kSamplesPerPixel;
        outColor *= invSpp;
        outAlbedo = sd.diffuse + sd.specular;
        outAlpha = 1.f;
    }
    else
    {
        // Background pixel.
        outColor = evalBackground(-sd.V);
        outAlbedo = outColor.rgb;
        outAlpha = kForceAlphaOne ? 1.f : 0.f;
    }

    // Write outputs.
    // These are all optional so using compile-time checks to decide which ones to write.
    if (isValid(gOutputColor)) gOutputColor[launchIndex] = float4(outColor, outAlpha);
    if (isValid(gOutputAlbedo)) gOutputAlbedo[launchIndex] = float4(outAlbedo, 1);

    if (kUseCache)
    {
#if defined(MINIMISE_LIVE_STATE) && MINIMISE_LIVE_STATE != 0
        storeInformationForCaching(launchIndex, cacheData < 0.0f);
#else
        storeInformationForCaching(cacheData, launchIndex);
#endif
    }
}
