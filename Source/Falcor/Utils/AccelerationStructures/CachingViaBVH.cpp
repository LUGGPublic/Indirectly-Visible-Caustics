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
#include "stdafx.h"
#include "CachingViaBVH.h"
#include "dear_imgui/imgui.h"

namespace Falcor
{
    CachingViaBVH::SharedPtr CachingViaBVH::create(const Options& options)
    {
        return SharedPtr(new CachingViaBVH(options));
    }

    void CachingViaBVH::allocate(uint2 aabbCount)
    {
        mAabbCount = aabbCount;
        mCanUseTiling = mAabbCount.y > 1u;

        const uint32_t totalAabbCount = mAabbCount.x * mAabbCount.y;
        if (!mpAABBBuffer || mpAABBBuffer->getElementCount() < totalAabbCount)
        {
            mpAABBBuffer = Buffer::createStructured(sizeof(D3D12_RAYTRACING_AABB), totalAabbCount);
            mpAABBBuffer->setName(mPrefix + ".CachingViaBVH::Aabbs");
        }

        setupBlas();
    }

    bool CachingViaBVH::prepareProgram(const Program::SharedPtr& pProgram)
    {
        return pProgram->addDefines({
            {"CACHING_USE_TILING",        mOptions.useTiling && mCanUseTiling ? "1" : "0"},
            {"CACHING_BIG_TILE_X",        std::to_string(mBigTileSize.x)},
            {"CACHING_BIG_TILE_Y",        std::to_string(mBigTileSize.y)},
            {"CACHING_FILL_TILE_X",       std::to_string(mFillTileSize.x)},
            {"CACHING_FILL_TILE_Y",       std::to_string(mFillTileSize.y)},
            {"CACHING_AABB_PER_GEOMETRY", std::to_string(mAabbPerGeometry)},
        });
    }

    bool CachingViaBVH::renderUI(Gui::Widgets& widget)
    {
        bool dirty = false;

        dirty = widget.checkbox("Allow refit", mOptions.allowRefit) || dirty;
        widget.checkbox("Rebuild on schedule", mOptions.rebuildOnSchedule);
        widget.tooltip("If refitting is allowed, enabling this will trigger a rebuild after X refit, where X is given by the field \"Allowed consecutive refits\".");
        widget.var("Allowed consecutive refits", mOptions.consecutiveRefitCount, 0u, 50u);
        dirty = (widget.checkbox("Use tiling", mOptions.useTiling) && mCanUseTiling) || dirty;
        if (mOptions.useTiling && !mCanUseTiling)
        {
            ImGui::SameLine();
            ImGui::TextDisabled("W");
            if (ImGui::IsItemHovered())
            {
                ImGui::BeginTooltip();
                ImGui::PushTextWrapPos(450.0f);
                ImGui::TextUnformatted("Setting ignored; forcing linear as a 1D amount of AABBs was specified.");
                ImGui::PopTextWrapPos();
                ImGui::EndTooltip();
            }
        }
        widget.tooltip("When forming geometries to build the BVH, group together all AABBs within a tile instead of taking linear groups.");
        dirty = widget.var("AABBs per geometry", mAabbPerGeometry) || dirty;

        if (dirty)
        {
            setupBlas();
            mRequireRebuild = true;
        }

        return dirty;
    }

    void CachingViaBVH::update(RenderContext* pContext, RtProgramVars* pVars, bool forceRebuild)
    {
        PROFILE("CachingViaBVH::update");

        if (forceRebuild)
        {
            mRequireRebuild = true;
        }

        const bool scheduleRebuild = mOptions.allowRefit && (mOptions.rebuildOnSchedule && ((mUpdateCounter + 1u) % (mOptions.consecutiveRefitCount + 1u) == 0u));
        if (scheduleRebuild)
        {
            mRequireRebuild = true;
        }
        const bool willRebuild = mRequireRebuild;

        // The SBT is built based on the scene description, no matter what,
        // with the triangle-based hit groups located first in the hit table.
        // So to get the proper hit group when tracing against our custom BVH,
        // we need to offset the hit group index by all the triangle-based hit
        // groups.
        const uint32_t triangleHitGroupCount = pVars->getTotalHitVarsCount();
        mTlasData.instanceDesc.InstanceContributionToHitGroupIndex = triangleHitGroupCount;

        buildBlas(pContext);
        buildTlas(pContext);

        if (willRebuild)
        {
            mUpdateCounter = 0u;
        }
        else
        {
            ++mUpdateCounter;
        }
    }

    CachingViaBVH::CachingViaBVH(const Options& options) : mOptions(options)
    {
        // Setup instance description
        D3D12_RAYTRACING_INSTANCE_DESC& instanceDesc = mTlasData.instanceDesc;
        instanceDesc.InstanceMask = 0xFF;
        instanceDesc.InstanceID = 0;
        instanceDesc.Flags = D3D12_RAYTRACING_INSTANCE_FLAG_NONE;
        const glm::mat4 identityMat = glm::identity<glm::mat4>();
        std::memcpy(instanceDesc.Transform, &identityMat, sizeof(instanceDesc.Transform));

        // Setup build parameters.
        D3D12_BUILD_RAYTRACING_ACCELERATION_STRUCTURE_INPUTS& tlasInputs = mTlasData.buildInputs;
        tlasInputs.Type = D3D12_RAYTRACING_ACCELERATION_STRUCTURE_TYPE_TOP_LEVEL;
        tlasInputs.DescsLayout = D3D12_ELEMENTS_LAYOUT_ARRAY;
        tlasInputs.NumDescs = 1;
        tlasInputs.Flags = D3D12_RAYTRACING_ACCELERATION_STRUCTURE_BUILD_FLAG_PREFER_FAST_TRACE;

        // Get prebuild info.
        GET_COM_INTERFACE(gpDevice->getApiHandle(), ID3D12Device5, pDevice5);
        pDevice5->GetRaytracingAccelerationStructurePrebuildInfo(&tlasInputs, &mTlasData.prebuildInfo);

        // Allocate scratch space for the TLAS.
        mpTlasScratch = Buffer::create(mTlasData.prebuildInfo.ScratchDataSizeInBytes, Buffer::BindFlags::UnorderedAccess, Buffer::CpuAccess::None);
        mpTlasScratch->setName(mPrefix + ".CachingViaBVH::mpTlasScratch");
    }

    void CachingViaBVH::buildBlas(RenderContext* pContext)
    {
        PROFILE("CachingViaBVH::buildBlas");

        // Add barriers for the AABB buffer which will be accessed by the build.
        pContext->resourceBarrier(mpAABBBuffer.get(), Resource::State::NonPixelShader);

        assert(mBlasData.resultByteSize > 0 && mBlasData.scratchByteSize > 0);

        // Allocate result and scratch buffers.
        // The scratch buffer we'll retain because it's needed for subsequent rebuilds and updates.
        if (!mpBlasScratch || mpBlasScratch->getSize() < mBlasData.scratchByteSize)
        {
            // If we need to reallocate, just insert a barrier so it's safe to use.
            if (mpBlasScratch) pContext->uavBarrier(mpBlasScratch.get());

            mpBlasScratch = Buffer::create(mBlasData.scratchByteSize, Buffer::BindFlags::UnorderedAccess, Buffer::CpuAccess::None);
            mpBlasScratch->setName(mPrefix + ".CachingViaBVH::BlasScratch");
        }
        else
        {
            // If we didn't need to reallocate, just insert a barrier so it's safe to use.
            pContext->uavBarrier(mpBlasScratch.get());
        }

        // Allocate BLAS buffer.
        bool canUpdate = mOptions.allowRefit && !mRequireRebuild &&
                         (mBlasData.buildInputs.Flags & D3D12_RAYTRACING_ACCELERATION_STRUCTURE_BUILD_FLAG_ALLOW_UPDATE) != 0;
        if (!mBlasData.pBlas || mBlasData.pBlas->getSize() < mBlasData.resultByteSize)
        {
            // If we need to reallocate, just insert a barrier so it's safe to use.
            if (mBlasData.pBlas) pContext->uavBarrier(mBlasData.pBlas.get());

            mBlasData.pBlas = Buffer::create(mBlasData.resultByteSize, Buffer::BindFlags::AccelerationStructure, Buffer::CpuAccess::None);
            mBlasData.pBlas->setName(mPrefix + ".CachingViaBVH::Blas");
            canUpdate = false;
        }
        else
        {
            // If we didn't need to reallocate, just insert a barrier so it's safe to use.
            pContext->uavBarrier(mBlasData.pBlas.get());
        }

        // Build the BLAS.
        D3D12_BUILD_RAYTRACING_ACCELERATION_STRUCTURE_DESC asDesc = {};
        asDesc.Inputs = mBlasData.buildInputs;
        asDesc.ScratchAccelerationStructureData = mpBlasScratch->getGpuAddress();
        asDesc.DestAccelerationStructureData = mBlasData.pBlas->getGpuAddress();
        if (canUpdate)
        {
            asDesc.SourceAccelerationStructureData = asDesc.DestAccelerationStructureData;
            asDesc.Inputs.Flags |= D3D12_RAYTRACING_ACCELERATION_STRUCTURE_BUILD_FLAG_PERFORM_UPDATE;
        }

        GET_COM_INTERFACE(pContext->getLowLevelData()->getCommandList(), ID3D12GraphicsCommandList4, pList4);
        pList4->BuildRaytracingAccelerationStructure(&asDesc, 0, nullptr);

        // Insert barrier. The BLAS buffer is now ready for use.
        pContext->uavBarrier(mBlasData.pBlas.get());

        mTlasData.instanceDesc.AccelerationStructure = mBlasData.pBlas->getGpuAddress();
        mRequireRebuild = false;
    }

    void CachingViaBVH::buildTlas(RenderContext* pContext)
    {
        PROFILE("CachingViaBVH::buildTlas");

        // Setup GPU buffers
        D3D12_BUILD_RAYTRACING_ACCELERATION_STRUCTURE_DESC asDesc = {};
        asDesc.Inputs = mTlasData.buildInputs;

        // If first time building this TLAS
        if (mTlasData.pTlas == nullptr)
        {
            assert(mTlasData.pInstanceDescs == nullptr); // Instance desc should also be null if no TLAS

            mTlasData.pTlas = Buffer::create(mTlasData.prebuildInfo.ResultDataMaxSizeInBytes, Buffer::BindFlags::AccelerationStructure, Buffer::CpuAccess::None);
            mTlasData.pTlas->setName(mPrefix + "CachingViaBVH::Tlas");

            mTlasData.pInstanceDescs = Buffer::create(sizeof(D3D12_RAYTRACING_INSTANCE_DESC), Buffer::BindFlags::None, Buffer::CpuAccess::Write, &mTlasData.instanceDesc);
            mTlasData.pInstanceDescs->setName(mPrefix + "CachingViaBVH::InstanceDesc");
        }
        // Else update instance descs and barrier TLAS buffers
        else
        {
            pContext->uavBarrier(mTlasData.pTlas.get());
            pContext->uavBarrier(mpTlasScratch.get());
            mTlasData.pInstanceDescs->setBlob(&mTlasData.instanceDesc, 0, sizeof(D3D12_RAYTRACING_INSTANCE_DESC));
        }

        assert(mTlasData.pInstanceDescs->getApiHandle() && mTlasData.pTlas->getApiHandle() && mpTlasScratch->getApiHandle());

        asDesc.Inputs.InstanceDescs = mTlasData.pInstanceDescs->getGpuAddress();
        asDesc.ScratchAccelerationStructureData = mpTlasScratch->getGpuAddress();
        asDesc.DestAccelerationStructureData = mTlasData.pTlas->getGpuAddress();

        // Create TLAS
        GET_COM_INTERFACE(pContext->getLowLevelData()->getCommandList(), ID3D12GraphicsCommandList4, pList4);
        pContext->resourceBarrier(mTlasData.pInstanceDescs.get(), Resource::State::NonPixelShader);
        pList4->BuildRaytracingAccelerationStructure(&asDesc, 0, nullptr);
        pContext->uavBarrier(mTlasData.pTlas.get());

        // Create TLAS SRV
        if (mTlasData.pSrv == nullptr)
        {
            mTlasData.pSrv = ShaderResourceView::createViewForAccelerationStructure(mTlasData.pTlas);
        }
    }

    void CachingViaBVH::setupBlas()
    {
        // Setup geometry descriptions
        if (mOptions.useTiling && mCanUseTiling)
        {
            const uint bigTileXCount = mAabbCount.x / mBigTileSize.x;
            const uint bigTileYCount = mAabbCount.y / mBigTileSize.y;
            const uint bigTileCount = bigTileXCount * bigTileYCount;
            const uint fillTileCount = bigTileXCount;
            const uint tileCount = bigTileCount + fillTileCount;
            mBlasData.geomDescs.resize(tileCount);

            const uint bigTileElementCount = mBigTileSize.x * mBigTileSize.y;
            const uint bigTileByteSize = bigTileElementCount * sizeof(D3D12_RAYTRACING_AABB);
            const uint fillTileElementCount = mFillTileSize.x * mFillTileSize.y;
            const uint fillTileByteSize = fillTileElementCount * sizeof(D3D12_RAYTRACING_AABB);
            const uint fillTileStartOffset = bigTileCount * bigTileByteSize;

            for (uint32_t bigTileGeometryIndex = 0; bigTileGeometryIndex < bigTileCount; ++bigTileGeometryIndex)
            {
                D3D12_RAYTRACING_GEOMETRY_DESC& geomDesc = mBlasData.geomDescs[bigTileGeometryIndex];
                geomDesc.Type = D3D12_RAYTRACING_GEOMETRY_TYPE_PROCEDURAL_PRIMITIVE_AABBS;
                geomDesc.Flags = D3D12_RAYTRACING_GEOMETRY_FLAG_NO_DUPLICATE_ANYHIT_INVOCATION;
                geomDesc.AABBs.AABBCount = bigTileElementCount;
                geomDesc.AABBs.AABBs.StartAddress = mpAABBBuffer->getGpuAddress() + bigTileGeometryIndex * bigTileByteSize;
                geomDesc.AABBs.AABBs.StrideInBytes = sizeof(D3D12_RAYTRACING_AABB);
            }
            for (uint32_t fillTileGeometryIndex = 0; fillTileGeometryIndex < fillTileCount; ++fillTileGeometryIndex)
            {
                D3D12_RAYTRACING_GEOMETRY_DESC& geomDesc = mBlasData.geomDescs[bigTileCount + fillTileGeometryIndex];
                geomDesc.Type = D3D12_RAYTRACING_GEOMETRY_TYPE_PROCEDURAL_PRIMITIVE_AABBS;
                geomDesc.Flags = D3D12_RAYTRACING_GEOMETRY_FLAG_NO_DUPLICATE_ANYHIT_INVOCATION;
                geomDesc.AABBs.AABBCount = fillTileElementCount;
                geomDesc.AABBs.AABBs.StartAddress = mpAABBBuffer->getGpuAddress() + fillTileStartOffset
                                                  + fillTileGeometryIndex * fillTileByteSize;
                geomDesc.AABBs.AABBs.StrideInBytes = sizeof(D3D12_RAYTRACING_AABB);
            }
        }
        else
        {
            const uint32_t aabbCount = mAabbCount.x * mAabbCount.y;
            const uint32_t geometryDescriptionCount = (aabbCount + (mAabbPerGeometry - 1)) / mAabbPerGeometry;
            const uint32_t geometryStrideInBytes = mAabbPerGeometry * sizeof(D3D12_RAYTRACING_AABB);
            mBlasData.geomDescs.resize(geometryDescriptionCount);
            uint32_t geometryIndex = 0;
            for (D3D12_RAYTRACING_GEOMETRY_DESC& geomDesc : mBlasData.geomDescs)
            {
                geomDesc.Type = D3D12_RAYTRACING_GEOMETRY_TYPE_PROCEDURAL_PRIMITIVE_AABBS;
                geomDesc.Flags = D3D12_RAYTRACING_GEOMETRY_FLAG_NO_DUPLICATE_ANYHIT_INVOCATION;
                geomDesc.AABBs.AABBCount = mAabbPerGeometry;
                geomDesc.AABBs.AABBs.StartAddress = mpAABBBuffer->getGpuAddress() + geometryIndex * geometryStrideInBytes;
                geomDesc.AABBs.AABBs.StrideInBytes = sizeof(D3D12_RAYTRACING_AABB);
                ++geometryIndex;
            }
            const uint32_t fullGeometryDescriptionCount = aabbCount / mAabbPerGeometry;
            const uint32_t aabbRemainder = aabbCount - fullGeometryDescriptionCount * mAabbPerGeometry;
            const uint32_t lastGeometryAabbCount = aabbRemainder != 0 ? aabbRemainder : mAabbPerGeometry;
            mBlasData.geomDescs.back().AABBs.AABBCount = lastGeometryAabbCount;
        }

        // Setup build parameters.
        D3D12_BUILD_RAYTRACING_ACCELERATION_STRUCTURE_INPUTS& blasInputs = mBlasData.buildInputs;
        blasInputs.Type = D3D12_RAYTRACING_ACCELERATION_STRUCTURE_TYPE_BOTTOM_LEVEL;
        blasInputs.DescsLayout = D3D12_ELEMENTS_LAYOUT_ARRAY;
        blasInputs.NumDescs = static_cast<uint32_t>(mBlasData.geomDescs.size());
        blasInputs.pGeometryDescs = mBlasData.geomDescs.data();
        blasInputs.Flags = D3D12_RAYTRACING_ACCELERATION_STRUCTURE_BUILD_FLAG_PREFER_FAST_TRACE;
        if (mOptions.allowRefit)
        {
            blasInputs.Flags |= D3D12_RAYTRACING_ACCELERATION_STRUCTURE_BUILD_FLAG_ALLOW_UPDATE;
        }

        // Get prebuild info.
        GET_COM_INTERFACE(gpDevice->getApiHandle(), ID3D12Device5, pDevice5);
        pDevice5->GetRaytracingAccelerationStructurePrebuildInfo(&blasInputs, &mBlasData.prebuildInfo);

        // Figure out the padded allocation sizes to have proper alignment.
        assert(mBlasData.prebuildInfo.ResultDataMaxSizeInBytes > 0);
        mBlasData.resultByteSize = align_to(D3D12_RAYTRACING_ACCELERATION_STRUCTURE_BYTE_ALIGNMENT,
                                            mBlasData.prebuildInfo.ResultDataMaxSizeInBytes);

        mBlasData.scratchByteSize = align_to(D3D12_RAYTRACING_ACCELERATION_STRUCTURE_BYTE_ALIGNMENT,
                                             mBlasData.prebuildInfo.ScratchDataSizeInBytes);
    }

    SCRIPT_BINDING(CachingViaBVH)
    {
        // TODO use a nested class in the bindings when supported.
        ScriptBindings::SerializableStruct<CachingViaBVH::Options> options(m, "CachingViaBVHOptions");
#define field(f_) field(#f_, &CachingViaBVH::Options::f_)
        options.field(allowRefit);
        options.field(useTiling);
#undef field
    }
}
