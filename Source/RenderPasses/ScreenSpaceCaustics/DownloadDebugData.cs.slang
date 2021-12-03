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

cbuffer Params
{
    uint2 frameDim;
    uint2 selectedPixel;
};

Buffer<uint>                             previousFramePixelCoords;
ByteAddressBuffer                        previousFrameStatsOutput;
StructuredBuffer<CachingPointData>       previousFrameCachingPointData;

Buffer<uint>                             currentFramePixelCoords;
ByteAddressBuffer                        currentFrameStatsOutput;
StructuredBuffer<CachingPointData>       currentFrameCachingPointData;

StructuredBuffer<PathToCachingPointData> pathToCachingPointData;

ByteAddressBuffer                        interpolatedStatsOutput;
Texture2D<float4>                        colorOutput;

RWStructuredBuffer<CachingDebugData>     debugDataBuffer;

[numthreads(32, 1, 1)]
void main(uint3 dispatchIndex : SV_DispatchThreadID)
{
    if (dispatchIndex.x > 0) return;
    if (any(selectedPixel >= frameDim)) return;

    const uint pixelLinearIndex = linearisePixelCoords(selectedPixel, frameDim);
    CachingDebugData debugData = {};

    debugData.pathData = pathToCachingPointData[pixelLinearIndex];

    const uint4 previousStats = previousFrameStatsOutput.Load4(pixelLinearIndex * 16U/* sizeof(uint4) */);
    debugData.previousAccumulatedRadiance = asfloat(previousStats.rgb);

    debugData.previousCachingData = previousFrameCachingPointData[pixelLinearIndex];

    const uint4 currentStats = currentFrameStatsOutput.Load4(pixelLinearIndex * 16U/* sizeof(uint4) */);
    const float currentInverseArea = debugData.pathData.searchRadius > 0.0f ? 1.0f / (M_PI * debugData.pathData.searchRadius * debugData.pathData.searchRadius)
                                                                            : 1.0f;
    //debugData.currentAccumulatedRadiance = asfloat(currentStats.rgb) * currentInverseArea;
    debugData.currentAccumulatedRadiance = float3(fromFixed(currentStats.r), fromFixed(currentStats.g), fromFixed(currentStats.b)) * currentInverseArea;

    const uint expectedAabbIndex = computeAabbOffset(selectedPixel, frameDim);
    debugData.previousIndexToPixelCoords = expectedAabbIndex != kInvalidPixelEntry ? previousFramePixelCoords[expectedAabbIndex] : kInvalidPixelEntry;
    debugData.previousPhotonCount = previousStats.a;
    debugData.currentIndexToPixelCoords = kInvalidPixelEntry;
    debugData.currentPhotonCount = currentStats.a;

    debugData.currentCachingData = currentFrameCachingPointData[pixelLinearIndex];

    const uint4 interpolatedStats = interpolatedStatsOutput.Load4(pixelLinearIndex * 16U/* sizeof(uint4) */);
    debugData.interpolatedAccumulatedRadiance = asfloat(interpolatedStats.rgb);

    debugData.outputColor = colorOutput[selectedPixel].rgb;
    debugData.interpolatedPhotonCount = interpolatedStats.a;

    debugDataBuffer[0] = debugData;
}
