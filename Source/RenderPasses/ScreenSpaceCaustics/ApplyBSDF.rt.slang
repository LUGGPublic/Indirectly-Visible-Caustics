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

import Experimental.Scene.Material.MaterialShading;
import Scene.HitInfo;
import Scene.Raytracing;

cbuffer Params
{
    uint2 frameDim;
};

StructuredBuffer<PathToCachingPointData> pathToCachingPointData;
RWByteAddressBuffer                      statsOutput;


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
    const uint2 pixel = DispatchRaysIndex().xy;
    if (any(pixel >= frameDim)) return;
    const uint pixelLinearIndex = linearisePixelCoords(pixel, frameDim);

    const PathToCachingPointData pathData = pathToCachingPointData[pixelLinearIndex];
    const bool hasCacheEntry = pathData.searchRadius > 0.0f;
    if (!hasCacheEntry) return;

    const uint4 stats = statsOutput.Load4(pixelLinearIndex * 16U/* sizeof(uint4) */);
    //const float3 accumulatedReflectedRadiance = asfloat(stats.rgb);
    float3 accumulatedReflectedRadiance = float3(fromFixed(stats.r), fromFixed(stats.g), fromFixed(stats.b));
    const uint photonCount = stats.a;

    const float inverseArea = pathData.searchRadius > 0.0f ? 1.0f / (M_PI * pathData.searchRadius * pathData.searchRadius)
                                                           : 1.0f;
    accumulatedReflectedRadiance *= inverseArea;

    const HitInfo hitInfo = getHitInfo(pathData);
    const uint materialID = pathData.materialIDAndHitInfoType >> 16u;
    StaticVertexData triangleVertices[3];
    const VertexData v = gScene.getVertexData(hitInfo, triangleVertices);
    const ShadingData sd = prepareShadingData(v, materialID, gScene.materials[materialID], gScene.materialResources[materialID], v.normalW, 0.f);

    accumulatedReflectedRadiance *= evalBSDF(sd, pathData.incomingCameraDir);

    statsOutput.Store4(pixelLinearIndex * 16U/* sizeof(uint4) */, uint4(toFixed(accumulatedReflectedRadiance.r), toFixed(accumulatedReflectedRadiance.g), toFixed(accumulatedReflectedRadiance.b), photonCount));
}
