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
 #include "Experimental/Scene/Lights/EmissiveLightSamplerType.slangh"

import Experimental.Scene.Lights.LightCollection;
import Scene.Raytracing;

cbuffer Params
{
    uint restrictedMaterialID;
};

RWBuffer<uint> gActiveTriangles;
RWBuffer<uint> gActiveTriangleCount;

[numthreads(256, 1, 1)]
void main(uint3 dispatchIndex : SV_DispatchThreadID)
{
#if _EMISSIVE_LIGHT_SAMPLER_TYPE == EMISSIVE_LIGHT_SAMPLER_UNIFORM
    const uint activeTriangleIndex = dispatchIndex.x;
    const uint triangleCount = gScene.lightCollection.getActiveTriangleCount();
    if (activeTriangleIndex >= triangleCount) return;

    const uint triangleIndex = gScene.lightCollection.activeTriangles[activeTriangleIndex];
    const EmissiveTriangle tri = gScene.lightCollection.getTriangle(triangleIndex);
    if (tri.materialID == restrictedMaterialID)
    {
        uint i = 0u;
        InterlockedAdd(gActiveTriangleCount[0u], 1u, i);
        gActiveTriangles[i] = triangleIndex;
    }

#elif _EMISSIVE_LIGHT_SAMPLER_TYPE == EMISSIVE_LIGHT_SAMPLER_LIGHT_BVH
    // TODO: Implement
    return;

#elif _EMISSIVE_LIGHT_SAMPLER_TYPE == EMISSIVE_LIGHT_SAMPLER_POWER
    // TODO: Implement
    return;

#elif _EMISSIVE_LIGHT_SAMPLER_TYPE == EMISSIVE_LIGHT_SAMPLER_NULL
    return;
#endif
}
