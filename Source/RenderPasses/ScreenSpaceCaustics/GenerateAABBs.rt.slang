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

import Scene.HitInfo;
import Scene.Raytracing;
import Utils.AccelerationStructures.CachingViaBVH;

cbuffer Params
{
    uint2 frameDim;
};

StructuredBuffer<PathToCachingPointData> pathToCachingPointData;
RWBuffer<uint>                           pixelCoords;
RWByteAddressBuffer                      aabbs;


/** ************************** Custom primitives *************************** */

[shader("intersection")]
void unusedIsect()
{
}

struct UselessStruct
{
    bool uselessAttribute;
};

[shader("closesthit")]
void unusedChit(inout UselessStruct rayData : SV_RayPayload, UselessStruct attribs : SV_IntersectionAttributes)
{
}

[shader("miss")]
void unusedMiss(inout UselessStruct rayData : SV_RayPayload)
{
}


[shader("raygeneration")]
void rayGen()
{
    const uint2 launchIndex = DispatchRaysIndex().xy;
    if (any(launchIndex >= frameDim)) return;
    const uint launchLinearIndex = linearisePixelCoords(launchIndex, frameDim);

    uint2 pixel = launchIndex;
    uint packedPixelCoords = packPixelCoords(pixel);

    const uint pixelLinearIndex = linearisePixelCoords(pixel, frameDim);
    PathToCachingPointData pathData = pathToCachingPointData[pixelLinearIndex];
    bool hasCacheEntry = pathData.searchRadius > 0.0f;

    const uint aabbOffset = computeAabbOffset(pixel, frameDim);
    AABB aabb = {float3(FLT_MAX), float3(-FLT_MAX)};
    if (hasCacheEntry)
    {
        const HitInfo hitInfo = getHitInfo(pathData);
        const uint materialID = pathData.materialIDAndHitInfoType >> 16u;
        StaticVertexData triangleVertices[3];
        const VertexData v = gScene.getVertexData(hitInfo, triangleVertices);
        const ShadingData sd = prepareShadingData(v, materialID, gScene.materials[materialID], gScene.materialResources[materialID], pathData.incomingCameraDir, 0.f);

        //const float3 upVector = 0.1f * pathData.searchRadius * sd.N;
        //const float3 frontVector = pathData.searchRadius * sd.T;
        //const float3 rightVector = pathData.searchRadius * sd.B;
        const float3 upVector = pathData.searchRadius * float3(0.0f, 1.0f, 0.0f);
        const float3 frontVector = pathData.searchRadius * float3(1.0f, 0.0f, 0.0f);
        const float3 rightVector = pathData.searchRadius * float3(0.0f, 0.0f, 1.0f);

        aabb.minPoint = aabb.maxPoint = sd.posW - frontVector - rightVector - upVector;
        aabb.include(sd.posW - frontVector + rightVector - upVector);
        aabb.include(sd.posW + frontVector - rightVector - upVector);
        aabb.include(sd.posW + frontVector + rightVector - upVector);
        aabb.include(sd.posW - frontVector - rightVector + upVector);
        aabb.include(sd.posW - frontVector + rightVector + upVector);
        aabb.include(sd.posW + frontVector - rightVector + upVector);
        aabb.include(sd.posW + frontVector + rightVector + upVector);
    }
    else
    {
        // Mark the AABB as inactive
        aabb = {float3(kQNaN), float3(kQNaN)};
    }

    storeAabb(aabbs, aabbOffset, aabb);

    pixelCoords[aabbOffset] = hasCacheEntry ? packedPixelCoords : kInvalidPixelEntry;
}
