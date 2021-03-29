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
 /** Translation of defines set by the host to compile-time constants used to
    configure the caching without overhead from dynamic control flow.
    This will eventually be replaced by specialization constants in Slang.

    The host sets the following defines (booleans are 1=true, 0=false):

    CACHING_USE_TILING              True if AABBs should be grouped by tiles when forming geometries, instead of linearly.
    CACHING_BIG_TILE_X              The size in x of the main tile when grouping AABBs; only used if CACHING_USE_TILING is true.
    CACHING_BIG_TILE_Y              The size in y of the main tile when grouping AABBs; only used if CACHING_USE_TILING is true.
    CACHING_FILL_TILE_X             The size in x of the filling tile when grouping AABBs; only used if CACHING_USE_TILING is true.
    CACHING_FILL_TILE_Y             The size in y of the filling tile when grouping AABBs; only used if CACHING_USE_TILING is true.
    CACHING_AABB_PER_GEOMETRY       How many AABBs are found within one geometry description; only used if CACHING_USE_TILING is false.
*/

#ifndef CACHING_USE_TILING
#error CachingViaBVH.slang is missing defines.
#endif

import Utils.Math.AABB;

static const bool kUseTiledAabbGrouping = CACHING_USE_TILING;
static const uint2 kBigTileSize = uint2(CACHING_BIG_TILE_X, CACHING_BIG_TILE_Y);
static const uint2 kFillTileSize = uint2(CACHING_FILL_TILE_X, CACHING_FILL_TILE_Y);
static const uint kAabbPerGeometry = CACHING_AABB_PER_GEOMETRY;
static const float kQNaN = asfloat(0x7FC00001);

void storeAabb(RWByteAddressBuffer aabbs, uint aabbIndex, AABB aabb)
{
    const uint floatSize = 4;
    const uint float2Size = 2 * floatSize;
    const uint structSize = 3 * float2Size;

    aabbs.Store2((aabbIndex * structSize) + 0 * float2Size, asuint(float2(aabb.minPoint.x, aabb.minPoint.y)));
    aabbs.Store2((aabbIndex * structSize) + 1 * float2Size, asuint(float2(aabb.minPoint.z, aabb.maxPoint.x)));
    aabbs.Store2((aabbIndex * structSize) + 2 * float2Size, asuint(float2(aabb.maxPoint.y, aabb.maxPoint.z)));
}

uint computeLinearAabbOffset(uint2 pixel, uint2 frameDim)
{
    const uint linearOffset = pixel.y * frameDim.x + pixel.x;
    return linearOffset;
}

uint computeTiledAabbOffset(uint2 pixel, uint2 frameDim)
{
    const uint bigTileXCount = frameDim.x / kBigTileSize.x;
    const uint bigTileYCount = frameDim.y / kBigTileSize.y;
    const uint bigTileCount = bigTileXCount * bigTileYCount;
    const uint bigToFillSwitch = bigTileYCount * kBigTileSize.y;
    const bool isFillTile = pixel.y >= bigToFillSwitch;

    const uint tileX = pixel.x / kBigTileSize.x;
    const uint inTileX = pixel.x % kBigTileSize.x;

    const uint tileY = pixel.y / kBigTileSize.y;
    const uint inTileY = !isFillTile ? pixel.y % kBigTileSize.y
                                     : (pixel.y - bigToFillSwitch) % kFillTileSize.y;

    uint tiledOffset;
    if (!isFillTile)
    {
        tiledOffset = ((tileY * bigTileXCount + tileX) * kBigTileSize.y + inTileY) * kBigTileSize.x + inTileX;
    }
    else
    {
        const uint fillStartOffset = bigTileCount * (kBigTileSize.x * kBigTileSize.y);
        tiledOffset = fillStartOffset + (tileX * kFillTileSize.y + inTileY) * kFillTileSize.x + inTileX;
    }

    return tiledOffset;
}

uint computeAabbOffset(uint2 pixelCoords, uint2 frameDim)
{
    uint aabbOffset;
    if (kUseTiledAabbGrouping)
    {
        aabbOffset = computeTiledAabbOffset(pixelCoords, frameDim);
    }
    else
    {
        aabbOffset = computeLinearAabbOffset(pixelCoords, frameDim);
    }

    return aabbOffset;
}

uint getLinearAabbIndex(uint geometryIndex, uint primitiveIndex)
{
    const uint linearAabbIndex = geometryIndex * kAabbPerGeometry + primitiveIndex;
    return linearAabbIndex;
}

uint getTiledAabbIndex(uint geometryIndex, uint primitiveIndex, uint2 frameDim)
{
    const uint bigTileXCount = frameDim.x / kBigTileSize.x;
    const uint bigTileYCount = frameDim.y / kBigTileSize.y;
    const uint bigTileCount = bigTileXCount * bigTileYCount;
    const bool isFillTile = geometryIndex >= bigTileCount;

    const uint bigTileElementCount = kBigTileSize.x * kBigTileSize.y;
    const uint fillTileElementCount = kFillTileSize.x * kFillTileSize.y;

    uint tiledAabbIndex;
    if (!isFillTile)
    {
        tiledAabbIndex = geometryIndex * bigTileElementCount + primitiveIndex;
    }
    else
    {
        tiledAabbIndex = bigTileCount * bigTileElementCount
                       + (geometryIndex - bigTileCount) * fillTileElementCount + primitiveIndex;
    }

    return tiledAabbIndex;
}

uint getAabbIndex(uint geometryIndex, uint primitiveIndex, uint2 frameDim)
{
    uint aabbIndex;
    if (kUseTiledAabbGrouping)
    {
        aabbIndex = getTiledAabbIndex(geometryIndex, primitiveIndex, frameDim);
    }
    else
    {
        aabbIndex = getLinearAabbIndex(geometryIndex, primitiveIndex);
    }

    return aabbIndex;
}
