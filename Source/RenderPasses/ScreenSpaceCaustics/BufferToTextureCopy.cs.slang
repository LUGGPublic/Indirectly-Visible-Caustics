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
    uint disableTemporalReuse;
    float reuseAlpha;
};

ByteAddressBuffer                        currentFrameStatsOutput;
StructuredBuffer<PathToCachingPointData> pathToCachingPointData;

RWByteAddressBuffer                      previousFrameStatsOutput;
RWTexture2D<float4>                      gOutputColor;
RWTexture2D<uint>                        gOutputCount;
RWTexture2D<float>                       gOutputSearchRadius;

// Static configuration based on which buffers are bound.
#define isValid(name) (is_valid_##name != 0)

static const bool kUseCache = USE_CACHE != 0 ? true : false;
static const bool kApplyBSDFLate = LATE_BSDF_APPLICATION != 0 ? true : false;

[numthreads(16, 16, 1)]
void main(uint3 dispatchIndex : SV_DispatchThreadID)
{
    const uint2 pixel = dispatchIndex.xy;
    if (any(pixel >= frameDim)) return;
    const uint pixelLinearIndex = linearisePixelCoords(pixel, frameDim);

    const uint4 currentStats = currentFrameStatsOutput.Load4(pixelLinearIndex * 16U/* sizeof(uint4) */);
    //const float3 currentAccumulatedReflectedRadiance = asfloat(currentStats.rgb);
    const float3 currentAccumulatedReflectedRadiance = float3(fromFixed(currentStats.r), fromFixed(currentStats.g), fromFixed(currentStats.b));
    const uint currentPhotonCount = currentStats.a;

    float3 color = float3(0.0f);
    uint photonCount = currentPhotonCount;
    float searchRadius = 0.0f;
    if (kUseCache)
    {
        const PathToCachingPointData pathData = pathToCachingPointData[pixelLinearIndex];
        const bool hasCacheEntry = pathData.searchRadius > 0.0f;
        float3 accumulatedReflectedRadiance = currentAccumulatedReflectedRadiance;

        if (!disableTemporalReuse && hasCacheEntry)
        {
            const uint4 previousStats = previousFrameStatsOutput.Load4(pixelLinearIndex * 16U/* sizeof(uint4) */);
            const float3 previousAccumulatedReflectedRadiance = asfloat(previousStats.rgb);
            const uint hasPreviousDataMask = previousStats.a & (1 << 31);
            const uint previousPhotonCount = previousStats.a & ~hasPreviousDataMask;

            if (hasPreviousDataMask)
            {
                accumulatedReflectedRadiance = reuseAlpha * previousAccumulatedReflectedRadiance + (1.0f - reuseAlpha) * accumulatedReflectedRadiance;
                photonCount = reuseAlpha * previousPhotonCount + (1.0f - reuseAlpha) * currentPhotonCount;
            }

            previousFrameStatsOutput.Store4(pixelLinearIndex * 16U/* sizeof(uint4) */, uint4(asuint(accumulatedReflectedRadiance), photonCount));
        }

        if (hasCacheEntry)
        {
            color = pathData.pathThroughput
                  * accumulatedReflectedRadiance;
            searchRadius = pathData.searchRadius > 0.0f ? pathData.searchRadius : 0.0f;
        }
    }
    else
    {
        color = currentAccumulatedReflectedRadiance;
        photonCount = currentPhotonCount;
    }

    if (isValid(gOutputColor)) gOutputColor[pixel] += float4(color, 1.0f);
    if (isValid(gOutputCount)) gOutputCount[pixel] = photonCount;
    if (isValid(gOutputSearchRadius)) gOutputSearchRadius[pixel] = searchRadius;
}
