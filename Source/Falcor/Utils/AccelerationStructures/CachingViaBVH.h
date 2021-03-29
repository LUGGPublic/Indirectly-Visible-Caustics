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
#pragma once
#include "Scene/Scene.h"

namespace Falcor
{
    class dlldecl CachingViaBVH : public std::enable_shared_from_this<CachingViaBVH>
    {
    public:
        using SharedPtr = std::shared_ptr<CachingViaBVH>;
        using SharedConstPtr = std::shared_ptr<const CachingViaBVH>;

        /** CachingViaBVH configuration.
            Note if you change options, please update SCRIPT_BINDING in CachingViaBVH.cpp
        */
        struct Options
        {
            uint32_t consecutiveRefitCount = 3u; // If |rebuildOnSechule| is true, how many consecutive updates can use refitting before a rebuild occurs. 
            bool allowRefit = true;
            bool rebuildOnSchedule = false;
            bool useTiling = true;
        };

        virtual ~CachingViaBVH() = default;

        static SharedPtr create(const Options& options = Options{});

        void allocate(uint2 aabbCount);
        Buffer::SharedPtr getAabbBuffer() const { return mpAABBBuffer; }
        ShaderResourceView::SharedPtr getAccelerationStructure() const { return mTlasData.pSrv; }
        const Options& getOptions() const { return mOptions; }
        bool prepareProgram(const Program::SharedPtr& pProgram);
        bool renderUI(Gui::Widgets& widget);
        void setPrefix(std::string prefix) { mPrefix = std::move(prefix); }
        void update(RenderContext* pContext, RtProgramVars* pVars, bool forceRebuild);

    private:
        CachingViaBVH(const Options& options);
        void buildBlas(RenderContext* pContext);
        void buildTlas(RenderContext* pContext);
        void setupBlas();

        struct TlasData
        {
            D3D12_RAYTRACING_ACCELERATION_STRUCTURE_PREBUILD_INFO prebuildInfo;
            D3D12_BUILD_RAYTRACING_ACCELERATION_STRUCTURE_INPUTS buildInputs;
            D3D12_RAYTRACING_INSTANCE_DESC instanceDesc;

            Buffer::SharedPtr pTlas;
            ShaderResourceView::SharedPtr pSrv;             ///< Shader Resource View for binding the TLAS.
            Buffer::SharedPtr pInstanceDescs;               ///< Buffer holding instance descs for the TLAS.
        };

        /** Describes one BLAS.
        */
        struct BlasData
        {
            D3D12_RAYTRACING_ACCELERATION_STRUCTURE_PREBUILD_INFO prebuildInfo;
            D3D12_BUILD_RAYTRACING_ACCELERATION_STRUCTURE_INPUTS buildInputs;
            std::vector<D3D12_RAYTRACING_GEOMETRY_DESC> geomDescs;

            Buffer::SharedPtr pBlas;                        ///< Buffer containing the final BLAS.

            uint64_t resultByteSize = 0;                    ///< Maximum result data size for the BLAS build, including padding.
            uint64_t scratchByteSize = 0;                   ///< Maximum scratch data size for the BLAS build, including padding.
            uint64_t blasByteSize = 0;                      ///< Size of the final BLAS post-compaction, including padding.
        };

        // Runtime data
        Buffer::SharedPtr mpAABBBuffer;                     ///< Buffer containing the AABBs of all caching points.
        std::string mPrefix = "CachingViaBVH";
        uint2 mAabbCount = uint2(0u);
        uint2 mBigTileSize = uint2(64, 32);
        uint2 mFillTileSize = uint2(64, 24);
        uint32_t mAabbPerGeometry = 1024;
        uint32_t mUpdateCounter = 0;
        bool mRequireRebuild = false;
        bool mCanUseTiling = false;

        // TLAS data
        TlasData mTlasData;                                 ///< All data related to the scene's TLAS.
        Buffer::SharedPtr mpTlasScratch;                    ///< Scratch buffer used for TLAS builds. Can be shared as long as instance desc count is the same, which for now it is.

        // BLAS data
        BlasData mBlasData;                                 ///< All data related to the scene's BLASes.
        Buffer::SharedPtr mpBlasScratch;                    ///< Scratch buffer used for BLAS builds.

        // Configuration
        Options mOptions;
    };
}
