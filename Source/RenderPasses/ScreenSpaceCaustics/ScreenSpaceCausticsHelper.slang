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
import ScreenSpaceCausticsParams;

import Scene.HitInfo;

#define PACKED_HIT_INFO 0

static const uint kInvalidPixelEntry = 0xFFFFFFFF;
static const uint kFixedBitCount = 28;

uint2 unpackPixelCoords(uint packedPixelCoords)
{
   if (packedPixelCoords == kInvalidPixelEntry) return uint2(kInvalidPixelEntry);

   const uint2 pixelCoords = uint2(packedPixelCoords & 0x0000FFFF,
                                   packedPixelCoords >> 16);
   return pixelCoords;
}

uint packPixelCoords(uint2 pixelCoords)
{
   if (all(pixelCoords == uint2(kInvalidPixelEntry))) return kInvalidPixelEntry;

   const uint packedPixelCoords = (pixelCoords.y << 16) | (pixelCoords.x & 0x0000FFFF);
   return packedPixelCoords;
}

uint linearisePixelCoords(uint2 pixelCoords, uint2 frameDim)
{
   const uint pixelLinearIndex = pixelCoords.y * frameDim.x + pixelCoords.x;
   return pixelLinearIndex;
}

uint toFixed(float value)
{
    const uint maxIntegerValue = (1u << (32 - kFixedBitCount)) - 1u;
    value = clamp(value, 0.0f, (float)maxIntegerValue);
    const float scaled = value * (1 << kFixedBitCount);
    const uint fixed = (uint)(scaled + 0.5f);
    return fixed;
}

float fromFixed(uint value)
{
    const float floating = ((float)value) / (1 << kFixedBitCount);
    return floating;
}

HitInfo getHitInfo(const PathToCachingPointData pathData)
{
    HitInfo hitInfo;

#if PACKED_HIT_INFO
    PackedHitInfo packedHitInfo;
    packedHitInfo.xy = pathData.packedHitInfo.xy;
#if ((HIT_INSTANCE_TYPE_BITS) + (HIT_INSTANCE_INDEX_BITS) + (HIT_PRIMITIVE_INDEX_BITS)) <= 32
#elif ((HIT_INSTANCE_TYPE_BITS) + (HIT_INSTANCE_INDEX_BITS)) <= 32 && (HIT_PRIMITIVE_INDEX_BITS) <= 32
    packedHitInfo.z = pathData.packedHitInfo.z;
#endif
    hitInfo.decode(packedHitInfo);
#else
    hitInfo.type = InstanceType(pathData.materialIDAndHitInfoType & 0xFFFF);
    hitInfo.instanceID = pathData.hitInfoInstanceID;
    hitInfo.primitiveIndex = pathData.hitInfoPrimitiveIndex;
    hitInfo.barycentrics = pathData.hitInfoBarycentrics;
#endif

    return hitInfo;
}

void setHitInfo(const HitInfo hitInfo, inout PathToCachingPointData pathData)
{
#if PACKED_HIT_INFO
    PackedHitInfo packedHitInfo = hitInfo.encode();
    pathData.packedHitInfo.xy = packedHitInfo.xy;
#if ((HIT_INSTANCE_TYPE_BITS) + (HIT_INSTANCE_INDEX_BITS) + (HIT_PRIMITIVE_INDEX_BITS)) <= 32
#elif ((HIT_INSTANCE_TYPE_BITS) + (HIT_INSTANCE_INDEX_BITS)) <= 32 && (HIT_PRIMITIVE_INDEX_BITS) <= 32
    pathData.packedHitInfo.z = packedHitInfo.z;
#endif
#else
    pathData.materialIDAndHitInfoType = uint(hitInfo.type);
    pathData.hitInfoInstanceID = hitInfo.instanceID;
    pathData.hitInfoPrimitiveIndex = hitInfo.primitiveIndex;
    pathData.hitInfoBarycentrics = hitInfo.barycentrics;
#endif
}
