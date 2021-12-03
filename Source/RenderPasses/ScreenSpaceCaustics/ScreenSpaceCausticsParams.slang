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
#pragma once
#include "Utils/HostDeviceShared.slangh"

BEGIN_NAMESPACE_FALCOR

/** Screen-space caustics parameters. Shared between host and device.

    Note that if you add configuration parameters, do not forget to register
    them with the scripting system in SCRIPT_BINDING() in ScreenSpaceCaustics.cpp.
*/
struct ScreenSpaceCausticsParams
{
    // Make sure struct layout follows the HLSL packing rules as it is uploaded as a memory blob.
    // Do not use bool's as they are 1 byte in Visual Studio, 4 bytes in HLSL.
    // https://msdn.microsoft.com/en-us/library/windows/desktop/bb509632(v=vs.85).aspx
    // Note that the default initializers are ignored by Slang but used on the host.

    // General
    float3 projectionVolumeMin;        ///< Min point of the projection volume bounding box.
    uint lightPathCount = 1024 * 1024; ///< Number of light paths to be shot per frame.

    float3 projectionVolumeMax;        ///< Max point of the projection volume bounding box.
    int _pad0;

    int ignoreProjectionVolume = false;
    int usePhotonsForAll = false;
    int useCache = false;
    int _pad1;
};

enum class SurfaceAreaMethod
    // TODO: Remove the ifdefs and the include when Slang supports enum type specifiers.
#ifdef HOST_CODE
    : uint32_t
#endif
{
    PixelCornerProjection = 0,
    Kim2019 = 1
};

// For shader specialization in ScreenSpaceCaustics.rt.slang we can't use the enums.
// TODO: Find a way to remove this workaround.
#define SURFACE_AREA_METHOD_PIXEL_CORNER_PROJECTION             0
#define SURFACE_AREA_METHOD_KIM_2019                            1

#ifdef HOST_CODE
static_assert((uint32_t)SurfaceAreaMethod::PixelCornerProjection == SURFACE_AREA_METHOD_PIXEL_CORNER_PROJECTION);
static_assert((uint32_t)SurfaceAreaMethod::Kim2019 == SURFACE_AREA_METHOD_KIM_2019);
#endif

#if !defined(HOST_CODE) || !HOST_CODE
import Scene.HitInfo;
#endif

struct CachingPointData
{
    float3 position;
    float searchRadius;

    float3 normal;
    uint depthAndMaterialID; // High 16 bits: depth, low 16 bits: material ID.
};

struct PathToCachingPointData
{
    float3 incomingCameraDir;
    float searchRadius;

    float3 pathThroughput;
    uint materialIDAndHitInfoType; // High 16 bits: material ID, low 16 bits: HitInfo.type

    uint hitInfoInstanceID;
    uint hitInfoPrimitiveIndex;
    float2 hitInfoBarycentrics;
};

struct CachingDebugData
{
    PathToCachingPointData pathData;

    CachingPointData previousCachingData;
    CachingPointData currentCachingData;

    float3 previousAccumulatedRadiance;
    uint previousPhotonCount;

    float3 currentAccumulatedRadiance;
    uint currentPhotonCount;

    float3 interpolatedAccumulatedRadiance;
    uint interpolatedPhotonCount;

    float3 outputColor;
    uint previousIndexToPixelCoords;

    float3 _pad;
    uint currentIndexToPixelCoords;
};

END_NAMESPACE_FALCOR
