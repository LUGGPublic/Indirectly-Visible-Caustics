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
#pragma once
#include "Falcor.h"
#include "PathDebugData.slang"
#include "RenderGraph/RenderPassHelpers.h"

using namespace Falcor;

struct PathDebugSegmentID
{
    uint32_t pathIndex{ 0u };
    uint32_t segmentIndex{ 0u };
};

/** Visualise traced paths both graphically (with the rays being rendered on top of the current buffer), and the data associated to each of them via the GUI
*/
class dlldecl PathDebug
{
public:
    using SharedPtr = std::shared_ptr<PathDebug>;

    /** Create debug object.
        \param[in] logSize Number of shader print() and assert() statements per frame.
        \return New object, or throws an exception on error.
    */
    static SharedPtr create(const Dictionary& dict = {});

    Dictionary getScriptingDictionary();
    void setPrefix(const std::string& resourcePrefix);
    void setScene(RenderContext* pRenderContext, const Scene::SharedPtr& pScene);
    void useVBuffer(bool value);

    void beginFrame(RenderContext* pRenderContext, const PathDebugSegmentID& segmentIDLimits, const Texture::SharedPtr& pGeometryAttachment, const Texture::SharedPtr& pColorAttachment);
    void endFrame(RenderContext* pRenderContext, const PathDebugSegmentID& selectedSegmentID);

    bool prepareProgram(const Program::SharedPtr& pProgram);
    void setShaderData(const ShaderVar& var);

    bool renderUI(Gui::Widgets& widget);

protected:
    PathDebug(const Dictionary& dict);
    void updateVAO();
    uint32_t fillInstanceData();
    void copyDataToCPU();

    // Internal state
    Scene::SharedPtr                    mpScene;
    Buffer::SharedPtr                   mpPathDescription;
    Buffer::SharedPtr                   mpPathDescriptionStaging;
    GpuFence::SharedPtr                 mpReadFence;                    ///< GPU fence for sychronizing readback.
    GpuFence::SharedPtr                 mpWriteFence;                   ///< GPU fence for sychronizing writeback.

    // Configuration
    bool                                mEnabled = false;               ///< Enables debugging features.
    bool                                mAutomaticUpdates = true;
    bool                                mUpdateInstanceData = true;
    bool                                mVisualizePaths = true;
    bool                                mHideLastSegment = false;
    bool                                mNormaliseSegments = true;
    bool                                mDisableLengthScaling = false;
    PathDebugSegmentID                  mSelectedSegmentID;
    float                               mThicknessScale = 0.0003f;
    float                               mLengthScale = 0.1f;
    float3                              mSelectedPathColor = float3(0.8f, 0.8f, 0.2f);
    float3                              mSelectedSegmentColor = float3(0.8f, 0.2f, 0.2f);
    float3                              mUnselectedColor = float3(0.3f, 0.3f, 0.3f);

    // Runtime data
    std::string                         mResourcePrefix = "PathDebug";
    PathDebugSegmentID                  mSegmentIDLimits;

    bool                                mRunning = false;               ///< True when data collection is running (in between begin()/end() calls).
    bool                                mWaitingForData = false;        ///< True if we are waiting for data to become available on the GPU.
    bool                                mDataValid = false;             ///< True if data has been read back and is valid.
    bool                                mUseVBuffer = false;
    bool                                mHasDepthBuffer = false;
    bool                                mHasColorOutput = false;

    float3                              mSelectedSegmentOrigin = float3(0.0f);
    uint32_t                            mSelectedPathLength = 0u;
    float3                              mSelectedSegmentHit = float3(0.0f);
    bool                                mSelectedSegmentHasHit = false;
    float3                              mSelectedSegmentDirection = float3(0.0f);

    // Shader programs.
    struct
    {
        ComputeProgram::SharedPtr pProgram;
        ComputeState::SharedPtr pState;
        ComputeVars::SharedPtr pVars;
    } mDescriptionClearing;
    struct
    {
        GraphicsProgram::SharedPtr       pProgram;
        ParameterBlock::SharedPtr        pBlock;
        GraphicsVars::SharedPtr          pVars;
        Buffer::SharedPtr                pVertexBuffer;
        Buffer::SharedPtr                pRayCoordsBuffer;
        Buffer::SharedPtr                pRayCoordsStagingBuffer;
        Buffer::SharedPtr                pIndexBuffer;
        Buffer::SharedPtr                pMatrixBuffer;
        Buffer::SharedPtr                pMatrixStagingBuffer;
        VertexLayout::SharedPtr          pVertexLayout;
        Vao::SharedPtr                   pVao;
        Fbo::SharedPtr                   pFbo;
        GraphicsState::SharedPtr         pDepthTestingState;
        GraphicsState::SharedPtr         pWithoutDepthState;
        uint32_t                         indexCount = 0u;
        uint32_t                         instanceCount = 0u;
    } mRasteriser;

    // Scripting
#define serialize(var) \
    if constexpr (!loadFromDict) dict[#var] = var; \
    else if (dict.keyExists(#var)) { if constexpr (std::is_same<decltype(var), std::string>::value) var = (const std::string &)dict[#var]; else var = dict[#var]; vars.emplace(#var); }

    template<bool loadFromDict, typename DictType>
    void serializePass(DictType& dict)
    {
        std::unordered_set<std::string> vars;

        // Add variables here that should be serialized to/from the dictionary.
        serialize(mEnabled);
        serialize(mVisualizePaths);
        serialize(mHideLastSegment);
        serialize(mNormaliseSegments);
        serialize(mDisableLengthScaling);
        serialize(mThicknessScale);
        serialize(mLengthScale);
        serialize(mSelectedPathColor);
        serialize(mSelectedSegmentColor);
        serialize(mUnselectedColor);

        if constexpr (loadFromDict)
        {
            for (const auto& [key, value] : dict)
            {
                if (vars.find(key) == vars.end()) logWarning("Unknown field `" + key + "` in a TracedPathsVisualiser dictionary");
            }
        }
    }
#undef serialize
};
