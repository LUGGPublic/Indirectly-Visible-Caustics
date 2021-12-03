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

import Utils.AccelerationStructures.CachingViaBVH;

static const bool kInterpolateAabbData = INTERPOLATE_AABB_DATA;
static const bool kCapConsideredCollectingPoints = CAP_COLLECTING_POINTS;

// Static configuration based on which buffers are bound.
#define isValid(name) (is_valid_##name != 0)


struct PassData
{
    uint2                                      frameDim;
    uint                                       maxUsedCollectingPoints;

    RaytracingAccelerationStructure            aabbBVH;

    Buffer<uint>                               previousFramePixelCoords;
    StructuredBuffer<CachingPointData>         previousFrameCachingPointData;
    ByteAddressBuffer                          previousFrameStatsOutput;

    RWBuffer<uint>                             currentFramePixelCoords;
    RWStructuredBuffer<CachingPointData>       currentFrameCachingPointData;
    RWByteAddressBuffer                        interpolatedStatsOutput;
};


ParameterBlock<PassData> gData;

// Outputs (optional)
RWTexture2D<uint>                gTraversedAABBCount;


/** *********************** Ray index 0: AABB ray ************************* */

/** Payload for AABB ray.
*/
struct AABBRayData
{
    float3 normal;              ///< Any-hit input
    float searchRadius;         ///< Any-hit input

    float3 accumulatedRadiance; ///< Any-hit output
    float weightSum;            ///< Any-hit output

    uint materialID;            ///< Any-hit input
    float photonCount;          ///< Any-hit output
    uint traversedAabbCount;    ///< Any-hit output
    float minT;                 ///< Any-hit internal
};

struct AABBAttributes
{
    uint pixelLinearIndex;
};

[shader("closesthit")]
void unusedChit(inout AABBRayData rayData : SV_RayPayload, AABBAttributes attribs : SV_IntersectionAttributes)
{
}

[shader("miss")]
void aabbMiss(inout AABBRayData rayData : SV_RayPayload)
{
}

[shader("anyhit")]
void aabbAnyHit(
    inout AABBRayData rayData : SV_RayPayload, AABBAttributes attribs : SV_IntersectionAttributes)
{
    if (kCapConsideredCollectingPoints && rayData.traversedAabbCount >= gData.maxUsedCollectingPoints)
        AcceptHitAndEndSearch();

    const CachingPointData previousCachingData = gData.previousFrameCachingPointData[attribs.pixelLinearIndex];
    const uint previousMaterialID = previousCachingData.depthAndMaterialID & 0xFFFF;
    const float3 queryToCollectionPoint = previousCachingData.position - WorldRayOrigin();
    const float dist2 = dot(queryToCollectionPoint, queryToCollectionPoint);
    const float t = sqrt(dist2);
    if (t > rayData.searchRadius || dot(previousCachingData.normal, rayData.normal) <= 0.9f ||
        abs(dot(queryToCollectionPoint, rayData.normal)) > 1e-2f || previousMaterialID != rayData.materialID) IgnoreHit();

    ++rayData.traversedAabbCount;

    const bool isClosest = kInterpolateAabbData ? true : t < rayData.minT;
    if (!isClosest) IgnoreHit();

    const uint4 previousStats = gData.previousFrameStatsOutput.Load4(attribs.pixelLinearIndex * 16U/* sizeof(uint4) */);
    const float3 previousAccumulatedRadiance = asfloat(previousStats.rgb);
    const uint previousPhotonCount = previousStats.a;

    if (kInterpolateAabbData)
    {
        const float sigma = 0.75f * rayData.searchRadius;
        const float weight = exp(-dist2 / (2 * sigma * sigma));

        rayData.accumulatedRadiance += weight * previousAccumulatedRadiance;
        rayData.photonCount += weight * (float)previousPhotonCount;
        rayData.weightSum += weight;
    }
    else if (isClosest)
    {
        rayData.accumulatedRadiance = previousAccumulatedRadiance;
        rayData.photonCount = previousPhotonCount;
        rayData.weightSum = 1.0f;
    }

    rayData.minT = min(t, rayData.minT);

    // XXX: Is it really needed?
    // Ignore the hit to ensure all AABBs within the distance gets processed,
    // even if they are further away.
    IgnoreHit();
}

[shader("intersection")]
void aabbIntersection()
{
    AABBAttributes attribs;
    const uint aabbIndex = getAabbIndex(GeometryIndex(), PrimitiveIndex(), gData.frameDim);
    const uint packedPixelCoords = gData.previousFramePixelCoords[aabbIndex];
    if (packedPixelCoords == kInvalidPixelEntry) return;

    const uint2 pixelCoords = unpackPixelCoords(packedPixelCoords);
    attribs.pixelLinearIndex = linearisePixelCoords(pixelCoords, gData.frameDim);

    ReportHit(0.0f, 0/*hitKind*/, attribs);
}


/** ******************************** RayGen ******************************* */

[shader("raygeneration")]
void rayGen()
{
    uint2 launchIndex = DispatchRaysIndex().xy;
    uint2 launchDim = DispatchRaysDimensions().xy;

    const uint aabbOffset = computeAabbOffset(launchIndex, gData.frameDim);
    const bool hasCachingEntry = gData.currentFramePixelCoords[aabbOffset] != kInvalidPixelEntry;

    const uint pixelLinearIndex = linearisePixelCoords(launchIndex, gData.frameDim);
    CachingPointData cacheData = gData.currentFrameCachingPointData[pixelLinearIndex];
    RayDesc ray;
    ray.Origin = cacheData.position;
    ray.Direction = float3(FLT_EPSILON);
    ray.TMin = 0.f;
    ray.TMax = hasCachingEntry ? FLT_EPSILON : 0.f;
    AABBRayData cachingPayload = {};
    cachingPayload.normal = cacheData.normal;
    cachingPayload.searchRadius = cacheData.searchRadius;
    cachingPayload.materialID = cacheData.depthAndMaterialID & 0xFFFF;
    cachingPayload.traversedAabbCount = 0u;
    cachingPayload.minT = FLT_MAX;
    TraceRay(gData.aabbBVH, RAY_FLAG_SKIP_CLOSEST_HIT_SHADER, 0xff /* instanceInclusionMask */, 0 /* hitIdx */, 0 /* hitIdx multiplier */, 0 /* missIdx */, ray, cachingPayload);
    
    float3 cachedAccumulatedRadiance = float3(0.0f);
    uint cachedPhotonCount = 0u;
    if (hasCachingEntry && cachingPayload.weightSum > 0.0f)
    {
        cachedAccumulatedRadiance = cachingPayload.accumulatedRadiance / cachingPayload.weightSum;
        cachedPhotonCount = (uint)(cachingPayload.photonCount / cachingPayload.weightSum);
    }
    const uint traversedAABBCount = cachingPayload.traversedAabbCount;

    if (isValid(gTraversedAABBCount)) gTraversedAABBCount[launchIndex] = traversedAABBCount;
    const uint hasPreviousDataMask = traversedAABBCount != 0u ? 1 << 31 : 0;
    gData.interpolatedStatsOutput.Store4(pixelLinearIndex * 16U/* sizeof(uint4) */,
                                         uint4(asuint(cachedAccumulatedRadiance), hasPreviousDataMask | cachedPhotonCount));
}
