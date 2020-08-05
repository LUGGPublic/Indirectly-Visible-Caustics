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
 **************************************************************************/
import Scene.Camera.Camera;

struct Params
{
    Camera camera;

    float3 selectedPathColor;
    uint   selectedPathIndex;

    float3 selectedSegmentColor;
    uint   selectedSegmentIndex;

    float3 unselectedColor;
    float  _pad;
};

ParameterBlock<Params> params;
Buffer<uint2> segmentCoords;
StructuredBuffer<float4x3> worldMatrices;

struct VSOut
{
    float4 posH : SV_POSITION;
    nointerpolation float3 color : COLOR;
    nointerpolation uint doDiscard : DISCARD;
};

VSOut vsMain(float4 pos : POSITION, uint instanceID : SV_InstanceID)
{
    VSOut vsOut;
    vsOut.posH = mul(float4(mul(pos, worldMatrices[instanceID]), 1.0f), params.camera.getViewProj());

    const uint2 coords = segmentCoords[instanceID];
    if (coords.x != params.selectedPathIndex)
    {
        vsOut.color = params.unselectedColor;
    }
    else
    {
        vsOut.color = coords.y != params.selectedSegmentIndex ? params.selectedPathColor : params.selectedSegmentColor;
    }

    vsOut.color *= min((coords.y + 1u) * 0.2f, 1.0f);
    vsOut.doDiscard = 0u;

    return vsOut;
}

[earlydepthstencil]
float4 psMain(VSOut vsOut) : SV_TARGET0
{
    if (vsOut.doDiscard != 0u) discard;
    return float4(vsOut.color, 1.0f);
}
