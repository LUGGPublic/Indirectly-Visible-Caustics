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
import Scene.Camera.CameraData;
import Utils.Math.MathHelpers;

#include "Utils/Math/MathConstants.slangh"

struct CameraRay
{
    float3 origin;
    float tMin;
    float3 dir;
    float tMax;

    RayDesc toRayDesc()
    {
        return { origin, tMin, dir, tMax };
    }

    float3 eval(float t)
    {
        return origin + t * dir;
    }
};

struct Camera
{
    CameraData data;

    float3 getPosition() { return data.posW; }
    float4x4 getViewProj() { return data.viewProjMat; }

    /** Computes a camera ray for a given pixel assuming a pinhole camera model.
        The camera jitter is taken into account to compute the sample position on the image plane.
        \param[in] pixel Pixel coordinates with origin in top-left.
        \param[in] frameDim Image plane dimensions in pixels.
        \return Returns the camera ray.
    */
    CameraRay computeRayPinhole(uint2 pixel, uint2 frameDim)
    {
        CameraRay ray;

        // Compute the normalized ray direction assuming a pinhole camera.
        ray.origin = data.posW;
        ray.dir = normalize(computeNonNormalizedRayDirPinhole(pixel, frameDim));

        float invCos = 1.f / dot(normalize(data.cameraW), ray.dir);
        ray.tMin = data.nearZ * invCos;
        ray.tMax = data.farZ * invCos;

        return ray;
    }

    /** Computes the primary ray's direction, non-normalized assuming pinhole camera model.
        \param[in] pixel Pixel coordinates with origin in top-left.
        \param[in] frameDim Image plane dimensions in pixels.
        \param[in] offset Offset in screen space in [0,1] with origin at the top left corner.
        \param[in] useJitter Whether the camera jitter is taken into account to compute the sample position on the image plane.
        \return Returns the non-normalized ray direction
    */
    float3 computeNonNormalizedRayDirPinhole(uint2 pixel, uint2 frameDim, float2 offset, bool useJitter)
    {
        // Compute sample position in screen space in [0,1] with origin at the top-left corner.
        float2 p = (pixel + offset) / frameDim;
        if (useJitter)
        {
            // The camera jitter offsets the sample by +-0.5 pixels from the pixel center.
            p += float2(-data.jitterX, data.jitterY);
        }
        float2 ndc = float2(2, -2) * p + float2(-1, 1);

        // Compute the non-normalized ray direction assuming a pinhole camera.
        return ndc.x * data.cameraU + ndc.y * data.cameraV + data.cameraW;
    }

    /** Computes the primary ray's direction, non-normalized assuming pinhole camera model.
        The camera jitter is taken into account to compute the sample position on the image plane.
        \param[in] pixel Pixel coordinates with origin in top-left.
        \param[in] frameDim Image plane dimensions in pixels.
        \return Returns the non-normalized ray direction
    */
    float3 computeNonNormalizedRayDirPinhole(uint2 pixel, uint2 frameDim)
    {
        return computeNonNormalizedRayDirPinhole(pixel, frameDim, float2(0.5f, 0.5f), true);
    }


    /** Computes a camera ray for a given pixel assuming a thin-lens camera model.
        The camera jitter is taken into account to compute the sample position on the image plane.
        \param[in] pixel Pixel coordinates with origin in top-left.
        \param[in] frameDim Image plane dimensions in pixels.
        \param[in] u Uniform 2D sample.
        \return Returns the camera ray.
    */
    CameraRay computeRayThinlens(uint2 pixel, uint2 frameDim, float2 u)
    {
        CameraRay ray;

        // Sample position in screen space in [0,1] with origin at the top-left corner.
        // The camera jitter offsets the sample by +-0.5 pixels from the pixel center.
        float2 p = (pixel + float2(0.5f, 0.5f)) / frameDim + float2(-data.jitterX, data.jitterY);
        float2 ndc = float2(2, -2) * p + float2(-1, 1);

        // Compute the normalized ray direction assuming a thin-lens camera.
        ray.origin = data.posW;
        ray.dir = ndc.x * data.cameraU + ndc.y * data.cameraV + data.cameraW;
        float2 apertureSample = sample_disk(u); // Sample lies in the unit disk [-1,1]^2
        float3 rayTarget = ray.origin + ray.dir;
        ray.origin += data.apertureRadius * (apertureSample.x * normalize(data.cameraU) + apertureSample.y * normalize(data.cameraV));
        ray.dir = normalize(rayTarget - ray.origin);

        float invCos = 1.f / dot(normalize(data.cameraW), ray.dir);
        ray.tMin = data.nearZ * invCos;
        ray.tMax = data.farZ * invCos;

        return ray;
    }

    /** Estimates the area of the surfaces, in world space, found under a pixel.
        \param[in] viewSamplePosW Position in world space for the considered view sample.
        \param[in] viewSampleNormW Normal in world space for the considered view sample.
        \param[in] pixel Pixel coordinates with origin in top-left.
        \param[in] frameDim Image plane dimensions in pixels.
        \param[out] isValid True if the estimation was successful, false otherwise.
        \return Returns the area under the given pixel.
    */
    float estimateAreaUnderPixel(const float3 viewSamplePosW, const float3 viewSampleNormW,
                                 const uint2 pixel, const uint2 frameDim, out bool isValid)
    {
        isValid = false;

        const float3 dirTL = computeNonNormalizedRayDirPinhole(pixel, frameDim, float2(0.0f, 0.0f), false);
        const float3 dirTR = computeNonNormalizedRayDirPinhole(pixel, frameDim, float2(1.0f, 0.0f), false);
        const float3 dirBL = computeNonNormalizedRayDirPinhole(pixel, frameDim, float2(0.0f, 1.0f), false);
        const float3 dirBR = computeNonNormalizedRayDirPinhole(pixel, frameDim, float2(1.0f, 1.0f), false);

        const float cosThetaTL = -dot(viewSampleNormW, dirTL);
        const float cosThetaTR = -dot(viewSampleNormW, dirTR);
        const float cosThetaBL = -dot(viewSampleNormW, dirBL);
        const float cosThetaBR = -dot(viewSampleNormW, dirBR);
        if (cosThetaTL <= FLT_MIN || cosThetaTR <= FLT_MIN ||
            cosThetaBL <= FLT_MIN || cosThetaBR <= FLT_MIN) return 0.0f;

        isValid = true;
        const float nom = dot(viewSampleNormW, viewSamplePosW) - dot(viewSampleNormW, data.posW);

        // Projected point: data.posW + t * dir
        // Area: 0.5 * length(cross(proj0 - proj1, proj0 - proj2))
        // |-> 0.5 * length(cross(t0 * dir0 - t1 * dir1, t0 * dir0 - t2 * dir2))

        const float tTL = 1.0f / cosThetaTL;
        const float tTR = 1.0f / cosThetaTR;
        const float tBL = 1.0f / cosThetaBL;
        const float tBR = 1.0f / cosThetaBR;

        const float3 projTL = tTL * dirTL;
        const float3 projTR = tTR * dirTR;
        const float3 projBL = tBL * dirBL;
        const float3 projBR = tBR * dirBR;

        const float areaTriangle1 = 0.5f * nom * nom * length(cross(projTL - projBL, projTL - projTR));
        const float areaTriangle2 = 0.5f * nom * nom * length(cross(projBR - projTR, projBR - projBL));

        return areaTriangle1 + areaTriangle2;
    }
};
