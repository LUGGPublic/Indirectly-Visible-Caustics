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

cbuffer Params
{
    uint2 frameDim;
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

RWTexture2D<float4>                      debugOutput;

enum class DebugMode
{
    PixelCoords,
    Indices,
    PreviousFlux,
    CurrentFlux,
    InterpolatedFlux,
    PreviousCount,
    CurrentCount,
    NoPhoton
};

[numthreads(16, 16, 1)]
void main(uint3 dispatchIndex : SV_DispatchThreadID)
{
    const uint2 pixel = dispatchIndex.xy;
    if (any(pixel >= frameDim)) return;
    const uint pixelLinearIndex = linearisePixelCoords(pixel, frameDim);
    const PathToCachingPointData pathData = pathToCachingPointData[pixelLinearIndex];

    const uint previousCoords = previousFramePixelCoords[pixelLinearIndex];
    const uint2 previousPixel = unpackPixelCoords(previousCoords);
    const uint currentCoords = currentFramePixelCoords[pixelLinearIndex];
    const uint2 currentPixel = unpackPixelCoords(currentCoords);

    const uint4 previousStats = previousFrameStatsOutput.Load4(pixelLinearIndex * 16U/* sizeof(uint4) */);
    const float3 previousAccumulatedRadiance = asfloat(previousStats.rgb);
    const uint4 currentStats = currentFrameStatsOutput.Load4(pixelLinearIndex * 16U/* sizeof(uint4) */);
    //const float3 currentAccumulatedFlux = asfloat(currentStats.rgb);
    const float3 currentAccumulatedFlux = float3(fromFixed(currentStats.r), fromFixed(currentStats.g), fromFixed(currentStats.b));
    const float currentInverseArea = pathData.searchRadius > 0.0f ? 1.0f / (M_PI * pathData.searchRadius * pathData.searchRadius)
                                                                  : 0.0f;
    const uint4 interpolatedStats = interpolatedStatsOutput.Load4(pixelLinearIndex * 16U/* sizeof(uint4) */);
    const float3 interpolatedAccumulatedRadiance = asfloat(interpolatedStats.rgb);

    const uint previousPhotonCount = previousStats.a;
    const uint currentPhotonCount = currentStats.a;

    float3 color = float3(0.0f);

    const DebugMode debugMode = DebugMode::InterpolatedFlux;
    switch (debugMode)
    {
    case DebugMode::PixelCoords:
        color = float3(previousCoords == kInvalidPixelEntry ? 0.8f : 0.2f,
                       currentCoords == kInvalidPixelEntry ? 0.8f : 0.2f,
                       any(previousCoords != currentCoords) ? 0.8f : 0.2f);
        break;
    case DebugMode::Indices:
        color = float3(previousCoords == kInvalidPixelEntry ? 0.8f : 0.2f,
                       currentCoords == kInvalidPixelEntry ? 0.8f : 0.2f,
                       pathData.searchRadius > 0.0f ? 0.8f : 0.2f);
        break;
    case DebugMode::PreviousFlux:
        color = previousAccumulatedRadiance;
        break;
    case DebugMode::CurrentFlux:
        color = currentAccumulatedFlux * currentInverseArea;
        break;
    case DebugMode::InterpolatedFlux:
        color = interpolatedAccumulatedRadiance;
        break;
    case DebugMode::PreviousCount:
        color = float3(previousPhotonCount / 10.0f);
        break;
    case DebugMode::CurrentCount:
        color = float3(currentPhotonCount / 10.0f);
        break;
    case DebugMode::NoPhoton:
        color = (previousPhotonCount + currentPhotonCount) == 0u ? float3(0.8f, 0.2f, 0.2f) : float3(0.2f);
        break;
    }

    debugOutput[pixel] = float4(color, 1.0f);
}
