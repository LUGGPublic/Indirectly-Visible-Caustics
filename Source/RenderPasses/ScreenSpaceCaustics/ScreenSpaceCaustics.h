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
#include "Falcor.h"
#include "FalcorExperimental.h"
#include "ScreenSpaceCausticsParams.slang"
#include "RenderPasses/Shared/PathTracer/PathTracer.h"
#include "Utils/AccelerationStructures/CachingViaBVH.h"
#include "Utils/Debug/PathDebug.h"

using namespace Falcor;

class ScreenSpaceCaustics : public PathTracer
{
public:
    using SharedPtr = std::shared_ptr<ScreenSpaceCaustics>;

    /** Create a new render pass object.
        \param[in] pRenderContext The render context.
        \param[in] dict Dictionary of serialized parameters.
        \return A new object, or an exception is thrown if creation failed.
    */
    static SharedPtr create(RenderContext* pRenderContext = nullptr, const Dictionary& dict = {});

    virtual std::string getDesc() override { return sDesc; }
    virtual Dictionary getScriptingDictionary() override;
    virtual RenderPassReflection reflect(const CompileData& compileData) override;
    virtual void compile(RenderContext* pRenderContext, const CompileData& compileData) override;
    virtual void execute(RenderContext* pRenderContext, const RenderData& renderData) override;
    virtual void renderUI(Gui::Widgets& widget) override;
    virtual void setScene(RenderContext* pRenderContext, const Scene::SharedPtr& pScene) override;
    virtual bool onKeyEvent(const KeyboardEvent& event) override;
    virtual bool onMouseEvent(const MouseEvent& event) override;
    virtual void onHotReload(HotReloadFlags reloaded) override;

    static const char* sDesc;

private:
    ScreenSpaceCaustics(const Dictionary& dict);

    void computeListOfSpecularMaterials();
    void computerEmissionMaterialIndex();
    void computeProjectionVolume();
    void prepareVars();
    void recreateVars() { mTracer.pVars = nullptr; }
    void recreateCachingData(RenderContext* pRenderContext);
    void renderDebugUI(Gui::Widgets& widget);
    void setLTStaticParams(Program* pProgram) const;
    void setTracerData(const RenderData& renderData);

    struct PerFrameCachingData
    {
        Buffer::SharedPtr pAccumulatedStats;                        ///< Indexed by pixel coordinates. Format: float4, with .rgb = accumulated radiance, .a (uint) = photon count.
        Buffer::SharedPtr pIndexToPixelMap;                         ///< Indexed by the AABB's geometry global index, gives its corresponding pixel coordinates or 0xFFFFFFFF if invalid. Format is: 16 MSB = pixel.y, 16 LSB = pixel.x.
        Buffer::SharedPtr pCachingPointData;                        ///< Indexed by pixel coordinates. For the format, see struct CachingPointData.
    };

    // Internal state
    EmissiveLightSampler::SharedPtr mpLightTracingEmissiveSampler;
    CachingViaBVH::SharedPtr        mpCache;
    PathDebug::SharedPtr            mpPathDebug;
    PathDebugSegmentID              mSelectedSegmentID;
    std::array<PerFrameCachingData, 2> mPerFrameCachingData;
    Buffer::SharedPtr               mpPathToCachingPointData;       ///< Indexed by pixel coordinates. For the format, see struct PathToCachingPointData.
    Buffer::SharedPtr               mpEmissiveTriangles;
    Buffer::SharedPtr               mpEmissiveTriangleCount;

    // Configuration
    PathTracerParams                mSharedLightTracingParams;
    EmissiveUniformSampler::Options mLightTracingUniformSamplerOptions;
    ScreenSpaceCausticsParams       mSharedCustomParams;            ///< Host/device shared rendering parameters.
    CachingViaBVH::Options          mCachingOptions;
    std::string                     mEmissiveMaterialName;          ///< Restrict emission of photons from triangles using that material.
    float                           mSearchRadius = 1e-3f;
    float                           mMaxSearchRadius = 5e-3f;
    float                           mReuseAlpha = 0.8f;
    uint32_t                        mMaxReuseCollectingPoints = 80;
    uint32_t                        mMaxContributionToCollectingPoints = 80;
    bool                            mUseFixedSearchRadius = false;
    bool                            mCapSearchRadius = true;
    bool                            mDisableTemporalReuse = false;
    bool                            mInterpolatePreviousContributions = true;
    bool                            mCapReuseCollectingPoints = false;
    bool                            mCapContributiongCollectingPoints = false;
    bool                            mLateBSDFApplication = true;
    bool                            mSeparateAABBStorage = true;
    bool                            mAllowSingleDiffuseBounce = false;
    bool                            mRestrictEmissionByMaterials = false;

    // Runtime
    std::vector<bool>               mIsMaterialSpecular;
    SurfaceAreaMethod               mSelectedSurfaceAreaMethod = SurfaceAreaMethod::PixelCornerProjection;
    uint32_t                        mSelectedFrameCachingData = 0;
    uint32_t                        mPixelCount = 0u;
    uint2                           mDebugSelectedPixel = uint2(0u);
    float2                          mCurrentCursorPosition = uint2(0u);
    uint32_t                        mSelectedEmissiveMaterialIndex = 0u;
    bool                            mResetTemporalReuse = true;
    bool                            mEnableDebug = false;
    bool                            mRecomputeEmissiveTriangleList = false;

    // Shader program.
    ComputePass::SharedPtr mpRestricter;

    struct
    {
        RtProgram::SharedPtr pProgram;
        RtProgramVars::SharedPtr pVars;
        ParameterBlock::SharedPtr pCommonDataBlock;                     ///< ParameterBlock for data used by caching and non-caching variants.
        ParameterBlock::SharedPtr pCacheRelatedBlock;                   ///< ParameterBlock for caching-related data.
    } mPathTracing;

    struct
    {
        RtProgram::SharedPtr pProgram;
        RtProgramVars::SharedPtr pVars;
    } mGenerateAABBs;

    struct
    {
        RtProgram::SharedPtr pProgram;
        RtProgramVars::SharedPtr pVars;
        ParameterBlock::SharedPtr pBlock;                              ///< ParameterBlock for all data.
    } mCollectionPointReuse;

    struct
    {
        RtProgram::SharedPtr pProgram;
        RtProgramVars::SharedPtr pVars;
        ParameterBlock::SharedPtr pParameterBlock;                      ///< ParameterBlock for all data.
    } mTracer;

    struct
    {
        RtProgram::SharedPtr pProgram;
        RtProgramVars::SharedPtr pVars;
    } mApplyBSDF;

    struct
    {
        ComputeProgram::SharedPtr pProgram;
        ComputeState::SharedPtr pState;
        ComputeVars::SharedPtr pVars;
    } mCopy;

    // Debug
    Buffer::SharedPtr               mpPreviousAccumulatedStats;
    Buffer::SharedPtr               mpPreviousAccumulatedPhotonCount;
    Buffer::SharedPtr               mpDeviceDebugData;
    Buffer::SharedPtr               mpHostDebugData;
    GpuFence::SharedPtr             mpDebugDataReadFence;
    CachingDebugData                mCachingDebugData;

    struct
    {
        ComputeProgram::SharedPtr pProgram;
        ComputeState::SharedPtr pState;
        ComputeVars::SharedPtr pVars;
    } mDownloadDebug;

    struct
    {
        ComputeProgram::SharedPtr pProgram;
        ComputeState::SharedPtr pState;
        ComputeVars::SharedPtr pVars;
    } mDebugVisualiser;

    // Scripting
#define serialize(var) \
        if constexpr (!loadFromDict) dict[#var] = var; \
        else if (dict.keyExists(#var)) { if constexpr (std::is_same<decltype(var), std::string>::value) var = (const std::string &)dict[#var]; else var = dict[#var]; vars.emplace(#var); }

    template<bool loadFromDict, typename DictType>
    void serializeThisPass(DictType& dict)
    {
        PathTracer::serializePass<loadFromDict, DictType>(dict);

        std::unordered_set<std::string> vars;

        // Add variables here that should be serialized to/from the dictionary.
        serialize(mLightTracingUniformSamplerOptions);
        serialize(mSharedCustomParams);
        serialize(mCachingOptions);
        serialize(mSelectedSurfaceAreaMethod);
        serialize(mEmissiveMaterialName);
        serialize(mSearchRadius);
        serialize(mMaxSearchRadius);
        serialize(mReuseAlpha);
        serialize(mMaxReuseCollectingPoints);
        serialize(mMaxContributionToCollectingPoints);
        serialize(mUseFixedSearchRadius);
        serialize(mCapSearchRadius);
        serialize(mDisableTemporalReuse);
        serialize(mInterpolatePreviousContributions);
        serialize(mCapReuseCollectingPoints);
        serialize(mCapContributiongCollectingPoints);
        serialize(mLateBSDFApplication);
        serialize(mSeparateAABBStorage);
        serialize(mRestrictEmissionByMaterials);

        if constexpr (loadFromDict)
        {
            for (const auto& [key, value] : dict)
            {
                if (vars.find(key) == vars.end()) logWarning("Unknown field '" + key + "' in a ScreenSpaceCaustics dictionary");
            }
        }
    }
#undef serialize
};
