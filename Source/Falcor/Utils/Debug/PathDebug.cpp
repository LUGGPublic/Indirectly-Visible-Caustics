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
#include "stdafx.h"
#include "PathDebug.h"

#include <glm/gtx/io.hpp>

#include <sstream>

// TODO(pmoreau): Add custom data support.
// TODO(pmoreau): Compute the matrices on the GPU.

namespace
{
    const std::string kProgramFile = "Utils/Debug/PathDebug.3d.slang";
    const std::string kClearingDescriptionsFile = "Utils/Debug/PathDebugClearing.cs.slang";
    const std::string kCamera = "camera";
    const std::string kParameterBlockName = "params";

    const uint32_t kRayVertexCount = 8 + 5;
    const uint32_t kRayIndexCount = (12 + 6) * 3;
    void appendRay(float3 origin, float3 direction, float thicknessScale, float lengthScale, std::uint32_t vertexOffset, std::uint32_t indexOffset, float4* pVertices, std::uint32_t* pIndices);
};

PathDebug::SharedPtr PathDebug::create(const Dictionary& dict)
{
    return SharedPtr(new PathDebug(dict));
}

Dictionary PathDebug::getScriptingDictionary()
{
    Dictionary dict;
    serializePass<false>(dict);
    return dict;
}

void PathDebug::setPrefix(const std::string& resourcePrefix)
{
    mResourcePrefix = resourcePrefix;

    if (mRasteriser.pVertexBuffer) mRasteriser.pVertexBuffer->setName(mResourcePrefix + ".VertexBuffer");
    if (mRasteriser.pIndexBuffer) mRasteriser.pIndexBuffer->setName(mResourcePrefix + ".IndexBuffer");
    if (mRasteriser.pRayCoordsBuffer) mRasteriser.pRayCoordsBuffer->setName(mResourcePrefix + ".RayCoordsBuffer");
    if (mRasteriser.pMatrixBuffer) mRasteriser.pMatrixBuffer->setName(mResourcePrefix + ".MatricesBuffer");
    if (mpPathDescription) mpPathDescription->setName(mResourcePrefix + ".pathDescription");
    if (mpPathDescriptionStaging) mpPathDescriptionStaging->setName(mResourcePrefix + ".pathDescriptionStaging");
}

void PathDebug::setScene(RenderContext* pRenderContext, const Scene::SharedPtr& pScene)
{
    mpScene = pScene;
}

void PathDebug::useVBuffer(bool value)
{
    if (mUseVBuffer != value) mRasteriser.pProgram->addDefine("USE_VBUFFER", value ? "1" : "0");
    mUseVBuffer = value;
}

bool PathDebug::renderUI(Gui::Widgets& widget)
{
    if (mRunning)
    {
        logError("PathDebug::renderUI() - Processing is running, call end() before renderUI(). Ignoring call.");
        return false;
    }

    bool dirty = false;

    widget.checkbox("Enable path debugging", mEnabled);
    if (mEnabled)
    {
        widget.checkbox("Live updates", mAutomaticUpdates);
        widget.checkbox("Update instance data", mUpdateInstanceData);
        widget.checkbox("Visualize paths", mVisualizePaths);
        if (mVisualizePaths)
        {
            widget.text("Rendering " + std::to_string(mRasteriser.instanceCount) + " rays.");

            dirty |= widget.checkbox("Hide rays which missed", mHideLastSegment);
            dirty |= widget.checkbox("Normalise segments", mNormaliseSegments);
            dirty |= widget.checkbox("Disable length scaling", mDisableLengthScaling);
            dirty |= widget.var("Length scale", mLengthScale, 1e-4f, 1000.0f);
            dirty |= widget.var("Thickness scale", mThicknessScale, 1e-4f, 100.0f);

            dirty |= widget.rgbColor("Selected path color", mSelectedPathColor);
            dirty |= widget.rgbColor("Selected path color", mSelectedSegmentColor);
            dirty |= widget.rgbColor("Unselected color", mUnselectedColor);
        }

        // Fetch data and show it if available.
        copyDataToCPU();
        if (mDataValid)
        {
            std::ostringstream pathOSS;
            pathOSS << "Path length:\t" << mSelectedPathLength << "\n";
            widget.text(pathOSS.str());

            std::ostringstream segmentOSS;
            segmentOSS << "Origin:\t" << mSelectedSegmentOrigin << "\n";
            if (mSelectedSegmentHasHit)
            {
                segmentOSS << "Hit point:\t" << mSelectedSegmentHit << "\n";
            }
            segmentOSS << "Direction:\t" << mSelectedSegmentDirection << "\n";
            widget.text(segmentOSS.str());
        }
        else
        {
            std::ostringstream oss;
            oss << "No valid data to be shown for the given (path, segment) ("
                << mSelectedSegmentID.pathIndex << ", " << mSelectedSegmentID.segmentIndex << "); check your selection indices.";
            widget.text(oss.str());
        }
    }

    return dirty;
}

void PathDebug::beginFrame(RenderContext* pRenderContext, const PathDebugSegmentID& segmentIDLimits, const Texture::SharedPtr& pGeometryAttachment, const Texture::SharedPtr& pColorAttachment)
{
    if (mRunning)
    {
        logError("PathDebug::beginFrame() - Processing is already running, did you forget to call endFrame()? Ignoring call.");
        return;
    }
    mRunning = true;

    mDataValid = false;
    mWaitingForData = false;

    mSegmentIDLimits = segmentIDLimits;
    if (mSegmentIDLimits.pathIndex == 0u || mSegmentIDLimits.segmentIndex == 0u) return;

    mHasDepthBuffer = static_cast<bool>(pGeometryAttachment);
    if (mHasDepthBuffer)
    {
        if (mUseVBuffer) mRasteriser.pFbo->attachDepthStencilTarget(pGeometryAttachment);
        else mRasteriser.pFbo->attachDepthStencilTarget(pGeometryAttachment);
    }
    mRasteriser.pFbo->attachColorTarget(pColorAttachment, 0u);
    mHasColorOutput = static_cast<bool>(pColorAttachment);

    const auto maxSegmentCount = mSegmentIDLimits.pathIndex * mSegmentIDLimits.segmentIndex;
    const auto maxVertexCount = maxSegmentCount + mSegmentIDLimits.pathIndex;

    if (!mpPathDescription || mpPathDescription->getElementCount() < maxVertexCount)
    {
        mpPathDescription = Buffer::createStructured(sizeof(PathDebugDescription), maxVertexCount);
        mpPathDescription->setName(mResourcePrefix + ".pathDescription");
        mDescriptionClearing.pVars["pathDescriptions"] = mpPathDescription;
    }

    if (!mpPathDescriptionStaging || mpPathDescriptionStaging->getElementCount() < maxVertexCount)
    {
        mpPathDescriptionStaging = Buffer::createStructured(sizeof(PathDebugDescription), maxVertexCount, ResourceBindFlags::None, Buffer::CpuAccess::Read);
        mpPathDescriptionStaging->setName(mResourcePrefix + ".pathDescriptionStaging");
    }

    if (!mRasteriser.pMatrixBuffer || mRasteriser.pMatrixBuffer->getElementCount() < maxSegmentCount)
    {
        mRasteriser.pMatrixBuffer = Buffer::createStructured(sizeof(glm::mat4x3), maxSegmentCount);
        mRasteriser.pMatrixBuffer->setName(mResourcePrefix + ".MatrixBuffer");
    }

    if (!mRasteriser.pMatrixStagingBuffer || mRasteriser.pMatrixStagingBuffer->getElementCount() < maxSegmentCount)
    {
        mRasteriser.pMatrixStagingBuffer = Buffer::createStructured(sizeof(glm::mat4x3), maxSegmentCount, Resource::BindFlags::None, Buffer::CpuAccess::Write);
        mRasteriser.pMatrixStagingBuffer->setName(mResourcePrefix + ".MatrixStragingBuffer");
    }

    if (!mRasteriser.pRayCoordsBuffer || mRasteriser.pRayCoordsBuffer->getElementCount() < maxSegmentCount)
    {
        mRasteriser.pRayCoordsBuffer = Buffer::createTyped<uint2>(maxSegmentCount);
        mRasteriser.pRayCoordsBuffer->setName(mResourcePrefix + ".RayCoordsBuffer");
    }

    if (!mRasteriser.pRayCoordsStagingBuffer || mRasteriser.pRayCoordsStagingBuffer->getElementCount() < maxSegmentCount)
    {
        mRasteriser.pRayCoordsStagingBuffer = Buffer::createTyped<uint2>(maxSegmentCount, Resource::BindFlags::None, Buffer::CpuAccess::Write);
        mRasteriser.pRayCoordsStagingBuffer->setName(mResourcePrefix + ".RayCoordsStagingBuffer");
    }

    // Create fence first time we need it.
    if (!mpReadFence) mpReadFence = GpuFence::create();
    if (!mpWriteFence) mpWriteFence = GpuFence::create();

    uint3 gridSize = uint3(mSegmentIDLimits.pathIndex, 1u, 1u);
    if (gridSize.x > D3D12_CS_DISPATCH_MAX_THREAD_GROUPS_PER_DIMENSION)
    {
        const double chunk = std::cbrt(static_cast<double>(gridSize.x) / static_cast<double>(3u * 3u * 2u));
        gridSize.x = static_cast<uint32_t>(3.0 * chunk);
        gridSize.y = static_cast<uint32_t>(3.0 * chunk);
        gridSize.z = mSegmentIDLimits.pathIndex / (gridSize.x * gridSize.y);
    }
    mDescriptionClearing.pVars["CB"]["gridSize"] = gridSize;

    {
        PROFILE("PathDebug::beginFrame()_clearDescriptions()");
        const uint3 dispatchSize = div_round_up(gridSize,
                                                mDescriptionClearing.pProgram->getReflector()->getThreadGroupSize());
        pRenderContext->dispatch(mDescriptionClearing.pState.get(), mDescriptionClearing.pVars.get(), dispatchSize);
    }
}

void PathDebug::endFrame(RenderContext* pRenderContext, const PathDebugSegmentID& selectedSegmentID)
{
    if (!mRunning)
    {
        logError("PathDebug::endFrame() - Processing is not running, did you forget to call beginFrame()? Ignoring call.");
        return;
    }
    mRunning = false;

    if (!mEnabled) return;

    mSelectedSegmentID = selectedSegmentID;

    const auto copyBuffer = [pRenderContext](Buffer* pDst, Buffer* pSrc)
    {
        const auto copySrcSize = pSrc->getSize();
        const auto copyDstSize = pDst->getSize();
        assert(copySrcSize == copyDstSize);
        pRenderContext->copyBufferRegion(pDst, 0u, pSrc, 0u,
                                         copyDstSize);
    };

    if (mAutomaticUpdates)
    {
        copyBuffer(mpPathDescriptionStaging.get(), mpPathDescription.get());
        pRenderContext->flush(false);
        mpReadFence->gpuSignal(pRenderContext->getLowLevelData()->getCommandQueue());
        mWaitingForData = true;
    }

    const bool shouldRenderPaths = mHasColorOutput && mVisualizePaths;
    if (!shouldRenderPaths) return;

    if (!mAutomaticUpdates) pRenderContext->flush(false);
    if (mUpdateInstanceData) mRasteriser.instanceCount = fillInstanceData();
    copyBuffer(mRasteriser.pRayCoordsBuffer.get(), mRasteriser.pRayCoordsStagingBuffer.get());
    copyBuffer(mRasteriser.pMatrixBuffer.get(), mRasteriser.pMatrixStagingBuffer.get());
    pRenderContext->flush(true);
    if (mRasteriser.indexCount != 0u)
    {
        PROFILE("PathDebug::drawIndexed()");

        mpScene->getCamera()->setShaderData(mRasteriser.pBlock[kCamera]);
        mRasteriser.pBlock["selectedPathColor"] = mSelectedPathColor;
        mRasteriser.pBlock["selectedPathIndex"] = mSelectedSegmentID.pathIndex;
        mRasteriser.pBlock["selectedSegmentColor"] = mSelectedSegmentColor;
        mRasteriser.pBlock["selectedSegmentIndex"] = mSelectedSegmentID.segmentIndex;
        mRasteriser.pBlock["unselectedColor"] = mUnselectedColor;
        mRasteriser.pVars[kParameterBlockName] = mRasteriser.pBlock;
        mRasteriser.pVars["segmentCoords"] = mRasteriser.pRayCoordsBuffer;
        mRasteriser.pVars["worldMatrices"] = mRasteriser.pMatrixBuffer;
        mRasteriser.pDepthTestingState->setFbo(mRasteriser.pFbo); // Sets the viewport
        mRasteriser.pWithoutDepthState->setFbo(mRasteriser.pFbo); // Sets the viewport

        pRenderContext->drawIndexedInstanced(mHasDepthBuffer ? mRasteriser.pDepthTestingState.get() : mRasteriser.pWithoutDepthState.get(),
                                                mRasteriser.pVars.get(), mRasteriser.indexCount, mRasteriser.instanceCount, 0u, 0, 0u);
    }
}

bool PathDebug::prepareProgram(const Program::SharedPtr& pProgram)
{
    assert(mRunning);

    if (mEnabled)
    {
        return pProgram->addDefine("_PATH_DEBUG_ENABLED");
    }
    else
    {
        return pProgram->removeDefine("_PATH_DEBUG_ENABLED");
    }
}

void PathDebug::setShaderData(const ShaderVar& var)
{
    assert(mRunning);

    if (mEnabled)
    {
        var["gPathDescription"] = mpPathDescription;
        var["PathDebugCB"]["gPathCount"] = mSegmentIDLimits.pathIndex;
        var["PathDebugCB"]["gMaxVertexCount"] = mSegmentIDLimits.segmentIndex + 1u;
    }
}

PathDebug::PathDebug(const Dictionary& dict)
{
    // Deserialize pass from dictionary.
    serializePass<true>(dict);

    VertexBufferLayout::SharedPtr pVertexLayout = VertexBufferLayout::create();
    pVertexLayout->addElement("POSITION", 0, ResourceFormat::RGBA32Float, 1, 0);

    mRasteriser.pVertexLayout = VertexLayout::create();
    mRasteriser.pVertexLayout->addBufferLayout(0u, pVertexLayout);

    Program::Desc d;
    d.addShaderLibrary(kProgramFile).vsEntry("vsMain").psEntry("psMain");
    mRasteriser.pProgram = GraphicsProgram::create(d);

    RasterizerState::Desc rsDesc;
    rsDesc.setCullMode(RasterizerState::CullMode::None);
    rsDesc.setFillMode(RasterizerState::FillMode::Solid);

    DepthStencilState::Desc dssWithDepthDesc;
    dssWithDepthDesc.setDepthEnabled(true);
    dssWithDepthDesc.setStencilEnabled(false);

    DepthStencilState::Desc dssWithoutDepthDesc;
    dssWithoutDepthDesc.setDepthEnabled(false);
    dssWithoutDepthDesc.setStencilEnabled(false);

    mRasteriser.pFbo = Fbo::create();

    mRasteriser.pDepthTestingState = GraphicsState::create();
    mRasteriser.pDepthTestingState->setProgram(mRasteriser.pProgram);
    mRasteriser.pDepthTestingState->setRasterizerState(RasterizerState::create(rsDesc));
    mRasteriser.pDepthTestingState->setDepthStencilState(DepthStencilState::create(dssWithDepthDesc));

    mRasteriser.pWithoutDepthState = GraphicsState::create();
    mRasteriser.pWithoutDepthState->setProgram(mRasteriser.pProgram);
    mRasteriser.pWithoutDepthState->setRasterizerState(RasterizerState::create(rsDesc));
    mRasteriser.pWithoutDepthState->setDepthStencilState(DepthStencilState::create(dssWithoutDepthDesc));

    ParameterBlockReflection::SharedConstPtr pReflection = mRasteriser.pProgram->getReflector()->getParameterBlock(kParameterBlockName);
    assert(pReflection);
    mRasteriser.pBlock = ParameterBlock::create(pReflection);
    mRasteriser.pVars = GraphicsVars::create(mRasteriser.pProgram.get());

    ComputeProgram::Desc progDesc;
    progDesc.addShaderLibrary(kClearingDescriptionsFile).csEntry("main");
    mDescriptionClearing.pProgram = ComputeProgram::create(progDesc);

    mDescriptionClearing.pState = ComputeState::create();
    mDescriptionClearing.pState->setProgram(mDescriptionClearing.pProgram);

    mDescriptionClearing.pVars = ComputeVars::create(mDescriptionClearing.pProgram.get());
    assert(mDescriptionClearing.pVars);

    updateVAO();
}

void PathDebug::updateVAO()
{
    mRasteriser.pVertexBuffer = Buffer::createTyped<float4>(kRayVertexCount, Resource::BindFlags::Vertex, Buffer::CpuAccess::Write);
    mRasteriser.pVertexBuffer->setName(mResourcePrefix + ".VertexBuffer");

    mRasteriser.pIndexBuffer = Buffer::createTyped<std::uint32_t>(kRayIndexCount, Resource::BindFlags::Index, Buffer::CpuAccess::Write);
    mRasteriser.pIndexBuffer->setName(mResourcePrefix + ".IndexBuffer");

    mRasteriser.pVao = Vao::create(Vao::Topology::TriangleList, mRasteriser.pVertexLayout, { mRasteriser.pVertexBuffer }, mRasteriser.pIndexBuffer, ResourceFormat::R32Uint);
    mRasteriser.pDepthTestingState->setVao(mRasteriser.pVao);
    mRasteriser.pWithoutDepthState->setVao(mRasteriser.pVao);

    auto pVertices = reinterpret_cast<float4*>(mRasteriser.pVertexBuffer->map(Buffer::MapType::WriteDiscard));
    auto pIndices = reinterpret_cast<uint32_t*>(mRasteriser.pIndexBuffer->map(Buffer::MapType::WriteDiscard));

    appendRay(float3(0.0f), float3(0.0f, 0.0f, -1.0f), 1.0f, 1.0f, 0u, 0u, pVertices, pIndices);

    mRasteriser.pIndexBuffer->unmap();
    mRasteriser.pVertexBuffer->unmap();

    mRasteriser.indexCount = kRayIndexCount;
}

uint32_t PathDebug::fillInstanceData()
{
    assert(!mRunning);
    if (mWaitingForData)
    {
        // Wait for signal.
        mpReadFence->syncCpu();
        mWaitingForData = false;
    }

    PROFILE("PathDebug::fillInstanceData()");

    const auto pPathDescription = reinterpret_cast<const PathDebugDescription*>(mpPathDescriptionStaging->map(Buffer::MapType::Read));
    auto pRayCoords = reinterpret_cast<uint2*>(mRasteriser.pRayCoordsStagingBuffer->map(Buffer::MapType::WriteDiscard));
    auto pMatrices = reinterpret_cast<glm::mat4x3*>(mRasteriser.pMatrixStagingBuffer->map(Buffer::MapType::WriteDiscard));

    uint32_t instanceIndex = 0u;
    const auto processSegment = [pRayCoords, pMatrices, this](uint32_t pathIndex, uint32_t segmentIndex, uint32_t instanceIndex, const PathDebugDescription* pOrigin, const PathDebugDescription* pEnd)
    {
        auto const hasHit = (pEnd->pathLength & 0x80000000u) == 0u;
        if (!hasHit && mHideLastSegment) return false;
        auto const direction = hasHit ? pEnd->rayExtremity - pOrigin->rayExtremity : pEnd->rayExtremity;
        auto const distanceToNextSegment = glm::length(direction);
        auto const lookAt = glm::mat3(glm::lookAt(float3(0.0f), glm::normalize(direction), float3(0.0f, 1.0f, 0.0f)));
        auto const rotationMatrix = glm::transpose(lookAt);
        glm::mat3 scalingMatrix(1.0f);
        auto const lengthScaling = mNormaliseSegments ? 1.0f : distanceToNextSegment;
        scalingMatrix[0][0] = mThicknessScale;
        scalingMatrix[1][1] = mThicknessScale;
        scalingMatrix[2][2] = (mDisableLengthScaling ? 1.0f : mLengthScale) * lengthScaling;

        glm::mat4x3 compactMatrix = rotationMatrix * scalingMatrix;
        compactMatrix[3] = pOrigin->rayExtremity;
        pRayCoords[instanceIndex] = uint2(pathIndex, segmentIndex);
        pMatrices[instanceIndex] = compactMatrix;

        return true;
    };

    for (uint32_t pathIndex = 0; pathIndex < mSegmentIDLimits.pathIndex; ++pathIndex)
    {
        const PathDebugDescription* const pPathOrigin = pPathDescription + pathIndex;
        const bool isPathValid = pPathOrigin->pathLength > 0u;
        if (!isPathValid) continue;

        const uint32_t segmentCount = std::min(pPathOrigin->pathLength, mSegmentIDLimits.segmentIndex);
        for (uint32_t segmentIndex = 0u; segmentIndex < segmentCount; ++segmentIndex)
        {
            const PathDebugDescription* const pOrigin = pPathOrigin + segmentIndex * static_cast<std::size_t>(mSegmentIDLimits.pathIndex);
            const PathDebugDescription* const pEnd = pOrigin + mSegmentIDLimits.pathIndex;
            const bool wasProcessed = processSegment(pathIndex, segmentIndex, instanceIndex, pOrigin, pEnd);
            assert(wasProcessed || (!wasProcessed && (segmentIndex + 1u == segmentCount)));
            if (!wasProcessed) continue;

            ++instanceIndex;
        }
    }

    mRasteriser.pMatrixStagingBuffer->unmap();
    mRasteriser.pRayCoordsStagingBuffer->unmap();
    mpPathDescriptionStaging->unmap();

    return instanceIndex;
}

void PathDebug::copyDataToCPU()
{
    assert(!mRunning);
    if (mSelectedSegmentID.pathIndex >= mSegmentIDLimits.pathIndex ||
        mSelectedSegmentID.segmentIndex >= mSegmentIDLimits.segmentIndex)
    {
        mDataValid = false;
        return;
    }

    if (mWaitingForData)
    {
        // Wait for signal.
        mpReadFence->syncCpu();
        mWaitingForData = false;
    }

    if (mEnabled)
    {
        const auto pPathDescription = reinterpret_cast<PathDebugDescription const*>(mpPathDescriptionStaging->map(Buffer::MapType::Read));

        auto pSegmentDescription = pPathDescription + mSelectedSegmentID.pathIndex;
        const auto selectedPathLength = std::min(pSegmentDescription->pathLength, mSegmentIDLimits.segmentIndex);

        mSelectedSegmentID.segmentIndex = std::min(mSelectedSegmentID.segmentIndex, selectedPathLength - 1u);
        const auto linearIndex = mSelectedSegmentID.pathIndex + mSelectedSegmentID.segmentIndex * static_cast<std::size_t>(mSegmentIDLimits.pathIndex);
        const PathDebugDescription origin = *(pPathDescription + linearIndex);
        const PathDebugDescription endPoint = *(pPathDescription + linearIndex + mSegmentIDLimits.pathIndex);
        mSelectedPathLength = selectedPathLength;

        mSelectedSegmentOrigin = origin.rayExtremity;
        mSelectedSegmentHasHit = (endPoint.pathLength & 0x80000000u) == 0u;
        mSelectedSegmentHit = mSelectedSegmentHasHit ? endPoint.rayExtremity : float3(0.0f);
        mSelectedSegmentDirection = mSelectedSegmentHasHit ? glm::normalize(mSelectedSegmentHit - mSelectedSegmentOrigin)
                                                            : endPoint.rayExtremity;

        mpPathDescriptionStaging->unmap();
        mDataValid = true;
    }
}

namespace
{
    float3 getNormal(float3 direction)
    {
        if (direction.x == 0.0f)      return float3(0.0f, -direction.z, direction.y);
        else if (direction.y == 0.0f) return float3(direction.z, 0.0f, -direction.x);
        else                          return float3(direction.y, -direction.x, 0.0f);
    }

    void appendRay(float3 origin, float3 direction, float thicknessScale, float lengthScale, std::uint32_t vertexOffset, std::uint32_t indexOffset, float4* pVertices, std::uint32_t* pIndices)
    {
        const float3 tangent = glm::normalize(getNormal(direction));
        const float3 bitangent = glm::normalize(glm::cross(direction, tangent));

        const float3 endPoint = origin + lengthScale * direction;

        //////////////
        // Ray body //
        //////////////

        // Vertices
        pVertices[vertexOffset + 0u] = float4(origin + 0.5f * thicknessScale * (-tangent - bitangent), 1.0f);
        pVertices[vertexOffset + 1u] = float4(origin + 0.5f * thicknessScale * (-tangent + bitangent), 1.0f);
        pVertices[vertexOffset + 2u] = float4(origin + 0.5f * thicknessScale * ( tangent - bitangent), 1.0f);
        pVertices[vertexOffset + 3u] = float4(origin + 0.5f * thicknessScale * ( tangent + bitangent), 1.0f);

        pVertices[vertexOffset + 4u] = float4(endPoint + 0.5f * thicknessScale * (-tangent - bitangent), 1.0f);
        pVertices[vertexOffset + 5u] = float4(endPoint + 0.5f * thicknessScale * (-tangent + bitangent), 1.0f);
        pVertices[vertexOffset + 6u] = float4(endPoint + 0.5f * thicknessScale * ( tangent - bitangent), 1.0f);
        pVertices[vertexOffset + 7u] = float4(endPoint + 0.5f * thicknessScale * ( tangent + bitangent), 1.0f);

        // "Back"-faces
        pIndices[indexOffset +  0u] = vertexOffset + 0u;
        pIndices[indexOffset +  1u] = vertexOffset + 1u;
        pIndices[indexOffset +  2u] = vertexOffset + 3u;

        pIndices[indexOffset +  3u] = vertexOffset + 0u;
        pIndices[indexOffset +  4u] = vertexOffset + 3u;
        pIndices[indexOffset +  5u] = vertexOffset + 2u;

        // "Front"-faces
        pIndices[indexOffset +  6u] = vertexOffset + 4u;
        pIndices[indexOffset +  7u] = vertexOffset + 6u;
        pIndices[indexOffset +  8u] = vertexOffset + 7u;

        pIndices[indexOffset +  9u] = vertexOffset + 4u;
        pIndices[indexOffset + 10u] = vertexOffset + 7u;
        pIndices[indexOffset + 11u] = vertexOffset + 5u;

        // "Left"-faces
        pIndices[indexOffset + 12u] = vertexOffset + 0u;
        pIndices[indexOffset + 13u] = vertexOffset + 4u;
        pIndices[indexOffset + 14u] = vertexOffset + 5u;

        pIndices[indexOffset + 15u] = vertexOffset + 0u;
        pIndices[indexOffset + 16u] = vertexOffset + 5u;
        pIndices[indexOffset + 17u] = vertexOffset + 1u;

        // "Right"-faces
        pIndices[indexOffset + 18u] = vertexOffset + 6u;
        pIndices[indexOffset + 19u] = vertexOffset + 2u;
        pIndices[indexOffset + 20u] = vertexOffset + 3u;

        pIndices[indexOffset + 21u] = vertexOffset + 6u;
        pIndices[indexOffset + 22u] = vertexOffset + 3u;
        pIndices[indexOffset + 23u] = vertexOffset + 7u;

        // "Top"-faces
        pIndices[indexOffset + 24u] = vertexOffset + 1u;
        pIndices[indexOffset + 25u] = vertexOffset + 5u;
        pIndices[indexOffset + 26u] = vertexOffset + 7u;

        pIndices[indexOffset + 27u] = vertexOffset + 1u;
        pIndices[indexOffset + 28u] = vertexOffset + 7u;
        pIndices[indexOffset + 29u] = vertexOffset + 3u;

        // "Bottom"-faces
        pIndices[indexOffset + 30u] = vertexOffset + 2u;
        pIndices[indexOffset + 31u] = vertexOffset + 6u;
        pIndices[indexOffset + 32u] = vertexOffset + 4u;

        pIndices[indexOffset + 33u] = vertexOffset + 2u;
        pIndices[indexOffset + 34u] = vertexOffset + 4u;
        pIndices[indexOffset + 35u] = vertexOffset + 0u;


        /////////////
        // Ray tip //
        /////////////

        // Vertices
        pVertices[vertexOffset +  8u] = float4(endPoint + 1.5f * thicknessScale * -tangent,   1.0f);
        pVertices[vertexOffset +  9u] = float4(endPoint + 1.5f * thicknessScale * -bitangent, 1.0f);
        pVertices[vertexOffset + 10u] = float4(endPoint + 1.5f * thicknessScale *  tangent,   1.0f);
        pVertices[vertexOffset + 11u] = float4(endPoint + 1.5f * thicknessScale *  bitangent, 1.0f);

        pVertices[vertexOffset + 12u] = float4(endPoint + 0.3f * lengthScale * direction, 1.0f);

        // "Back"-faces
        pIndices[indexOffset + 36u] = vertexOffset + 10u;
        pIndices[indexOffset + 37u] = vertexOffset +  9u;
        pIndices[indexOffset + 38u] = vertexOffset +  8u;

        pIndices[indexOffset + 39u] = vertexOffset + 10u;
        pIndices[indexOffset + 40u] = vertexOffset +  8u;
        pIndices[indexOffset + 41u] = vertexOffset + 11u;

        // "Left"-face
        pIndices[indexOffset + 42u] = vertexOffset +  9u;
        pIndices[indexOffset + 43u] = vertexOffset + 12u;
        pIndices[indexOffset + 44u] = vertexOffset +  8u;

        // "Right"-face
        pIndices[indexOffset + 45u] = vertexOffset + 12u;
        pIndices[indexOffset + 46u] = vertexOffset + 10u;
        pIndices[indexOffset + 47u] = vertexOffset + 11u;

        // "Top"-face
        pIndices[indexOffset + 48u] = vertexOffset +  8u;
        pIndices[indexOffset + 49u] = vertexOffset + 12u;
        pIndices[indexOffset + 50u] = vertexOffset + 11u;

        // "Bottom"-face
        pIndices[indexOffset + 51u] = vertexOffset + 10u;
        pIndices[indexOffset + 52u] = vertexOffset + 12u;
        pIndices[indexOffset + 53u] = vertexOffset +  9u;
    }
}
