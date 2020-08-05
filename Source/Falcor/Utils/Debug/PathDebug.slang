/***************************************************************************
# Copyright (c) 2020, NVIDIA CORPORATION. All rights reserved.
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
# THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS ``AS IS'' AND ANY
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
***************************************************************************/
/** GPU side implementation of path debugging utils.

    Call the function pathDebugSetPathIndex() in the shader program to set the
    current path index before the first pathDebugAppendSegment() calls.

    The host sets the following defines:

    _PATH_DEBUG_ENABLED     Nonzero when path debugging is enabled.

*/

import Utils.Debug.PathDebugData;

cbuffer PathDebugCB
{
    uint gPathCount;
    uint gMaxVertexCount;
};

RWStructuredBuffer<PathDebugDescription> gPathDescription;

#ifdef _PATH_DEBUG_ENABLED
static uint gPathDebugPathIndex;
static uint gPathDebugVertexIndex;
#endif

uint getVertexIndex(const uint pathIndex, const uint vertexIndex)
{
    return vertexIndex * gPathCount + pathIndex;
}

void pathDebugSetPathIndex(uint pathIndex)
{
#ifdef _PATH_DEBUG_ENABLED
    gPathDebugPathIndex = pathIndex;
    gPathDebugVertexIndex = 0u;

    const uint linearIndex = getVertexIndex(gPathDebugPathIndex, gPathDebugVertexIndex);
    PathDebugDescription segmentDescription = {};
    gPathDescription[linearIndex] = segmentDescription;
#endif
}

void pathDebugAppendRay(const float3 origin, const float3 direction)
{
#ifdef _PATH_DEBUG_ENABLED
    if (gPathDebugVertexIndex + 1u >= gMaxVertexCount) return;

    PathDebugDescription originDescription = {};
    originDescription.rayExtremity = origin;
    if (gPathDebugVertexIndex > 0) ++gPathDescription[gPathDebugPathIndex].pathLength;
    else originDescription.pathLength = 1u;

    const uint originLinearIndex = getVertexIndex(gPathDebugPathIndex, gPathDebugVertexIndex);
    gPathDescription[originLinearIndex] = originDescription;
    ++gPathDebugVertexIndex;

    PathDebugDescription directionDescription = {};
    directionDescription.rayExtremity = direction;
    directionDescription.pathLength = 0x80000000u;

    const uint directionLinearIndex = getVertexIndex(gPathDebugPathIndex, gPathDebugVertexIndex);
    gPathDescription[directionLinearIndex] = directionDescription;
#endif
}

void pathDebugSetRayHit(const float3 hit)
{
#ifdef _PATH_DEBUG_ENABLED
    if (gPathDebugVertexIndex == 0u) return;

    PathDebugDescription endDescription = {};
    endDescription.rayExtremity = hit;

    const uint endLinearIndex = getVertexIndex(gPathDebugPathIndex, gPathDebugVertexIndex);
    gPathDescription[endLinearIndex] = endDescription;
#endif
}
