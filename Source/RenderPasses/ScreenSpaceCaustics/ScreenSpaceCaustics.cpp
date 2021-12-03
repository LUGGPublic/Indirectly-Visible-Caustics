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
#include "ScreenSpaceCaustics.h"
#include "RenderGraph/RenderPassHelpers.h"
#include "Experimental/Scene/Material/TexLODTypes.slang"

namespace
{
    void regScreenSpaceCausticsPass(pybind11::module& m)
    {
        // Register our parameters struct.
        ScriptBindings::SerializableStruct<ScreenSpaceCausticsParams> params(m, "ScreenSpaceCausticsParams");
#define field(f_) field(#f_, &ScreenSpaceCausticsParams::f_)
        // General
        params.field(lightPathCount);

        params.field(ignoreProjectionVolume);
        params.field(usePhotonsForAll);
        params.field(useCache);
#undef field

        pybind11::enum_<SurfaceAreaMethod> areaMethod(m, "SurfaceAreaMethod");
        areaMethod.value("PixelCornerProjection", SurfaceAreaMethod::PixelCornerProjection);
        areaMethod.value("Kim2019", SurfaceAreaMethod::Kim2019);
    }
}

 // Don't remove this. it's required for hot-reload to function properly
extern "C" __declspec(dllexport) const char* getProjDir()
{
    return PROJECT_DIR;
}

extern "C" __declspec(dllexport) void getPasses(Falcor::RenderPassLibrary & lib)
{
    lib.registerClass("ScreenSpaceCaustics", ScreenSpaceCaustics::sDesc, ScreenSpaceCaustics::create);
    ScriptBindings::registerBinding(regScreenSpaceCausticsPass);
}

namespace
{
    const char kPathTracingShaderFile[] = "RenderPasses/ScreenSpaceCaustics/PathTracing.rt.slang";
    const char kGenerateAABBsShaderFile[] = "RenderPasses/ScreenSpaceCaustics/GenerateAABBs.rt.slang";
    const char kCollectionPointReuseShaderFile[] = "RenderPasses/ScreenSpaceCaustics/CollectionPointReuse.rt.slang";
    const char kShaderFile[] = "RenderPasses/ScreenSpaceCaustics/ScreenSpaceCaustics.rt.slang";
    const char kApplyBSDFShaderFile[] = "RenderPasses/ScreenSpaceCaustics/ApplyBSDF.rt.slang";
    const char kCopyShaderFile[] = "RenderPasses/ScreenSpaceCaustics/BufferToTextureCopy.cs.slang";
    const char kDownloadDebugShaderFile[] = "RenderPasses/ScreenSpaceCaustics/DownloadDebugData.cs.slang";
    const char kDebugVisualiserShaderFile[] = "RenderPasses/ScreenSpaceCaustics/DebugVisualiser.cs.slang";
    const char kRestrictEmissiveTrianglesShaderFile[] = "RenderPasses/ScreenSpaceCaustics/RestrictActiveEmissiveTriangles.cs.slang";
    const char kPTCommonDataBlockName[] = "gCommonData";
    const char kPTCachingDataBlockName[] = "gCachingData";
    const char kParameterBlockName[] = "gData";

    // Ray tracing settings that affect the traversal stack size.
    // These should be set as small as possible.
    // The payload for the scatter rays is 8B.
    // The payload for the shadow rays is 4B.
    const uint32_t kMaxPayloadSizeBytes = HitInfo::kMaxPackedSizeInBytes;
    const uint32_t kMaxAttributesSizeBytes = 8;
    const uint32_t kMaxRecursionDepth = 1;

    // Render pass output channels.
    const std::string kColorOutput = "color";
    const std::string kAlbedoOutput = "albedo";
    const std::string kCountOutput = "count";
    const std::string kTraversedAABBCount = "traversedAABBCount";
    const std::string kSearchRadiusOutput = "searchRadius";
    const std::string kTimeOutput = "time";
    const std::string kPathDebugOutput = "paths";
    const std::string kInternalDebugOutput = "debug_visualisation";

    const ChannelList kOutputTextures =
    {
        { kColorOutput,         "gOutputColor",         "Output color (linear)",                     true /* optional */                           },
        { kAlbedoOutput,        "gOutputAlbedo",        "Output albedo (linear)",                    true /* optional */                           },
        { kCountOutput,         "gOutputCount",         "Amount of photons accumulated per pixel",   true /* optional */, ResourceFormat::R32Uint  },
        { kTimeOutput,          "gOutputTime",          "Per-pixel execution time",                  true /* optional */, ResourceFormat::R32Uint  },
        { kTraversedAABBCount,  "gTraversedAABBCount",  "Amount of AABBs traversed per pixel",       true /* optional */, ResourceFormat::R32Uint  },
        { kSearchRadiusOutput,  "gOutputSearchRadius",  "Computed search radius per pixel",          true /* optional */, ResourceFormat::R32Float },
        { kInternalDebugOutput, "gInternalsDebugColor", "Visualisation for debugging the internals", true /* optional */                           },
        { kPathDebugOutput,     "gPathDebugColor",      "Visualisation of the traced light paths",   true /* optional */                           }
    };

    static Gui::DropdownList sSurfaceAreaDropdownList = {
        {SURFACE_AREA_METHOD_PIXEL_CORNER_PROJECTION, "Pixel-corner projection"},
        {SURFACE_AREA_METHOD_KIM_2019, "Kim 2019"}
    };
}

static_assert(has_vtable<ScreenSpaceCausticsParams>::value == false, "ScreenSpaceCausticsParams must be non-virtual");
static_assert(sizeof(ScreenSpaceCausticsParams) % 16 == 0, "ScreenSpaceCausticsParams size should be a multiple of 16");

static_assert(has_vtable<CachingPointData>::value == false, "CachingPointData must be non-virtual");
static_assert(sizeof(CachingPointData) % 16 == 0, "CachingPointData size should be a multiple of 16");

static_assert(has_vtable<PathToCachingPointData>::value == false, "PathToCachingPointData must be non-virtual");
static_assert(sizeof(PathToCachingPointData) % 16 == 0, "PathToCachingPointData size should be a multiple of 16");

static_assert(has_vtable<CachingDebugData>::value == false, "CachingDebugData must be non-virtual");
static_assert(sizeof(CachingDebugData) % 16 == 0, "CachingDebugData size should be a multiple of 16");

const char* ScreenSpaceCaustics::sDesc = "Render caustics in screen-space";

ScreenSpaceCaustics::SharedPtr ScreenSpaceCaustics::create(RenderContext* pRenderContext, const Dictionary& dict)
{
    SharedPtr pPass = SharedPtr(new ScreenSpaceCaustics(dict));
    return pPass;
}

ScreenSpaceCaustics::ScreenSpaceCaustics(const Dictionary& dict) : PathTracer(dict, kOutputTextures)
{
    // Deserialize pass from dictionary.
    serializeThisPass<true>(dict);

    // Force parameters that are not revelant for this use case.
    mSharedParams.disableCaustics = true;
    mSharedParams.rayFootprintMode = static_cast<uint32_t>(TexLODMode::RayCones);
    mSharedParams.rayConeMode = static_cast<uint32_t>(RayConeMode::Unified);
    mSharedParams.rayFootprintUseRoughness = 1;

    mSharedLightTracingParams = mSharedParams;

    mSharedLightTracingParams.samplesPerPixel = 1u;
    mSharedLightTracingParams.lightSamplesPerVertex = 0u;
    mSharedLightTracingParams.maxBounces = mSharedLightTracingParams.maxNonSpecularBounces = mSharedParams.maxBounces;
    mSharedLightTracingParams.useBRDFSampling = true; // Nothing happens otherwise.
    mSharedLightTracingParams.useNEE = false;
    mSharedLightTracingParams.useMIS = false;
    mSharedLightTracingParams.useLightsInDielectricVolumes = true;
    mSharedLightTracingParams.disableCaustics = false;
    mSharedLightTracingParams.rayFootprintMode = static_cast<uint32_t>(TexLODMode::Mip0);

    const RtProgram::DefineList commonDefines = {
        {"USE_CACHE", mSharedCustomParams.useCache ? "1" : "0"},
        {"CACHING_USE_TILING", "0"},
        {"CACHING_BIG_TILE_X", "0"},
        {"CACHING_BIG_TILE_Y", "0"},
        {"CACHING_FILL_TILE_X", "0"},
        {"CACHING_FILL_TILE_Y", "0"},
        {"CACHING_AABB_PER_GEOMETRY", "0"}
    };

    // Create programs.
    mpRestricter = ComputePass::create(kRestrictEmissiveTrianglesShaderFile, "main", {}, false);

    {
        RtProgram::Desc progDesc;
        progDesc.addShaderLibrary(kPathTracingShaderFile).setRayGen("rayGen");
        progDesc.addMiss(kRayTypeScatter, "scatterMiss");
        progDesc.addHitGroup(kRayTypeScatter, "scatterClosestHit", "scatterAnyHit");
        progDesc.addMiss(kRayTypeShadow, "shadowMiss");
        progDesc.addHitGroup(kRayTypeShadow, "", "shadowAnyHit");
        progDesc.addIntersection(0, "unusedIsect");
        progDesc.addAABBHitGroup(kRayTypeScatter, "unusedChit", "");
        progDesc.addAABBHitGroup(kRayTypeShadow, "unusedChit", "");
        progDesc.addDefine("MAX_BOUNCES", std::to_string(mSharedParams.maxBounces));
        progDesc.addDefine("SAMPLES_PER_PIXEL", std::to_string(mSharedParams.samplesPerPixel));
        progDesc.addDefines(commonDefines);
        progDesc.setShaderModel("6_5");
        progDesc.setMaxTraceRecursionDepth(kMaxRecursionDepth);
        mPathTracing.pProgram = RtProgram::create(progDesc, kMaxPayloadSizeBytes + 4, kMaxAttributesSizeBytes);
    }

    {
        RtProgram::Desc progDesc;
        progDesc.addShaderLibrary(kGenerateAABBsShaderFile).setRayGen("rayGen");
        progDesc.addMiss(0, "unusedMiss");
        progDesc.addIntersection(0, "unusedIsect");
        progDesc.addAABBHitGroup(kRayTypeScatter, "unusedChit", "");
        progDesc.addDefines(commonDefines);
        progDesc.setMaxTraceRecursionDepth(0u);
        mGenerateAABBs.pProgram = RtProgram::create(progDesc, 4u, 4u);
    }

    {
        RtProgram::Desc progDesc;
        progDesc.addShaderLibrary(kCollectionPointReuseShaderFile).setRayGen("rayGen");
        progDesc.addMiss(0, "aabbMiss");
        progDesc.addHitGroup(kRayTypeScatter, "unusedChit", "");
        progDesc.addIntersection(0, "aabbIntersection");
        progDesc.addAABBHitGroup(kRayTypeScatter, "", "aabbAnyHit");
        progDesc.addDefines(commonDefines);
        progDesc.setShaderModel("6_5");
        progDesc.setMaxTraceRecursionDepth(kMaxRecursionDepth);
        mCollectionPointReuse.pProgram = RtProgram::create(progDesc, 12u * (uint32_t)sizeof(float), (uint32_t)sizeof(float));
    }

    {
        RtProgram::Desc progDesc;
        progDesc.addShaderLibrary(kShaderFile).setRayGen("rayGen");
        progDesc.addMiss(kRayTypeScatter, "miss");
        progDesc.addHitGroup(kRayTypeScatter, "closestHit", "anyHit");
        progDesc.addMiss(1, "aabbMiss");
        progDesc.addIntersection(0, "aabbIntersection");
        progDesc.addAABBHitGroup(kRayTypeScatter, "", "aabbAnyHit");
        progDesc.addDefine("MAX_BOUNCES", std::to_string(mSharedLightTracingParams.maxBounces));
        progDesc.addDefine("SAMPLES_PER_PIXEL", std::to_string(mSharedLightTracingParams.samplesPerPixel));
        progDesc.addDefine("SURFACE_AREA_METHOD", std::to_string(static_cast<uint32_t>(mSelectedSurfaceAreaMethod)));
        progDesc.addDefines(commonDefines);
        progDesc.setShaderModel("6_5");
        progDesc.setMaxTraceRecursionDepth(kMaxRecursionDepth);
        mTracer.pProgram = RtProgram::create(progDesc, std::max(kMaxPayloadSizeBytes, (uint32_t)sizeof(float4)),
                                             std::max(kMaxAttributesSizeBytes, (uint32_t)sizeof(uint3)));
    }

    {
        RtProgram::Desc progDesc;
        progDesc.addShaderLibrary(kApplyBSDFShaderFile).setRayGen("rayGen");
        progDesc.addMiss(0, "unusedMiss");
        progDesc.addIntersection(0, "unusedIsect");
        progDesc.addAABBHitGroup(kRayTypeScatter, "unusedChit", "");
        progDesc.addDefines(commonDefines);
        progDesc.setMaxTraceRecursionDepth(0u);
        mApplyBSDF.pProgram = RtProgram::create(progDesc, 4u, 4u);
    }

    {
        ComputeProgram::Desc progDesc;
        progDesc.addShaderLibrary(kCopyShaderFile).csEntry("main");
        mCopy.pProgram = ComputeProgram::create(progDesc, commonDefines);

        mCopy.pState = ComputeState::create();
        mCopy.pState->setProgram(mCopy.pProgram);
    }

    {
        ComputeProgram::Desc progDesc;
        progDesc.addShaderLibrary(kDownloadDebugShaderFile).csEntry("main");
        mDownloadDebug.pProgram = ComputeProgram::create(progDesc, commonDefines);

        mDownloadDebug.pState = ComputeState::create();
        mDownloadDebug.pState->setProgram(mDownloadDebug.pProgram);
    }

    {
        ComputeProgram::Desc progDesc;
        progDesc.addShaderLibrary(kDebugVisualiserShaderFile).csEntry("main");
        mDebugVisualiser.pProgram = ComputeProgram::create(progDesc, commonDefines);

        mDebugVisualiser.pState = ComputeState::create();
        mDebugVisualiser.pState->setProgram(mDebugVisualiser.pProgram);

        mDebugVisualiser.pVars = ComputeVars::create(mDebugVisualiser.pProgram.get());
    }

    mpDeviceDebugData = Buffer::createStructured(sizeof(CachingDebugData), 1u, ResourceBindFlags::UnorderedAccess);
    mpHostDebugData = Buffer::createStructured(sizeof(CachingDebugData), 1u, ResourceBindFlags::None, Buffer::CpuAccess::Read);
    mpDebugDataReadFence = GpuFence::create();

    mpPathDebug = PathDebug::create(dict);
}

Dictionary ScreenSpaceCaustics::getScriptingDictionary()
{
    // Get the latest options for the cache, if present.
    if (mpCache) mCachingOptions = mpCache->getOptions();

    Dictionary dict;
    serializeThisPass<false>(dict);
    return dict;
}

RenderPassReflection ScreenSpaceCaustics::reflect(const CompileData& compileData)
{
    auto reflection = PathTracer::reflect(compileData);

    const auto& pathDebugDesc = kOutputTextures.back();
    assert(pathDebugDesc.name == kPathDebugOutput);
    auto& pathDebugOutput = reflection.addOutput(pathDebugDesc.name, pathDebugDesc.desc);
    pathDebugOutput.bindFlags(pathDebugOutput.getBindFlags() | ResourceBindFlags::RenderTarget);

    return reflection;
}

void ScreenSpaceCaustics::compile(RenderContext* pRenderContext, const CompileData& compileData)
{
    PathTracer::compile(pRenderContext, compileData);

    const auto outputDesc = compileData.connectedResources.getField(kColorOutput);
    auto pixelCount = outputDesc ? outputDesc->getWidth() * outputDesc->getHeight() : 0u;
    if (pixelCount == 0u) pixelCount = compileData.defaultTexDims.x * compileData.defaultTexDims.y;
    if (mPixelCount == pixelCount) return;

    const uint32_t byteSize = pixelCount * sizeof(uint4);
    uint32_t i = 0;
    for (auto& perFrameData : mPerFrameCachingData)
    {
        const std::string indexing = std::string("[") + std::to_string(i) + "]";

        perFrameData.pAccumulatedStats = Buffer::create(byteSize, ResourceBindFlags::UnorderedAccess | ResourceBindFlags::ShaderResource);
        assert(perFrameData.pAccumulatedStats);
        perFrameData.pAccumulatedStats->setName(mName + ".AccumulatedStats" + indexing);
        pRenderContext->clearUAV(perFrameData.pAccumulatedStats->getUAV().get(), float4(0.0f));

        ++i;
    }

    mpPreviousAccumulatedStats = Buffer::create(byteSize, ResourceBindFlags::UnorderedAccess | ResourceBindFlags::ShaderResource);
    assert(mpPreviousAccumulatedStats);
    mpPreviousAccumulatedStats->setName(mName + ".PreviousAccumulatedStats");
    pRenderContext->clearUAV(mpPreviousAccumulatedStats->getUAV().get(), float4(0.0f));

    mpPreviousAccumulatedPhotonCount = Buffer::createTyped<uint32_t>(pixelCount);
    assert(mpPreviousAccumulatedPhotonCount);
    mpPreviousAccumulatedPhotonCount->setName(mName + ".PreviousAccumulatedPhotonCount");
    pRenderContext->clearUAV(mpPreviousAccumulatedPhotonCount->getUAV().get(), uint4(0u));

    mPixelCount = pixelCount;
    mResetTemporalReuse = true;

    if (mSharedCustomParams.useCache) recreateCachingData(pRenderContext);
}

void ScreenSpaceCaustics::execute(RenderContext* pRenderContext, const RenderData& renderData)
{
    if (mOptionsChanged) mResetTemporalReuse = true;

    // Call shared pre-render code.
    if (!beginFrame(pRenderContext, renderData)) return;

    {
        auto pathDebugOutput = renderData.getResource(kPathDebugOutput);
        mpPathDebug->beginFrame(pRenderContext, PathDebugSegmentID{ mSharedCustomParams.lightPathCount, mSharedParams.maxBounces + 1u }, nullptr, pathDebugOutput ? pathDebugOutput->asTexture() : nullptr);
        if (pathDebugOutput) pRenderContext->clearTexture(pathDebugOutput->asTexture().get());
    }

    // Create emissive light sampler if it doesn't already exist.
    if (!mpLightTracingEmissiveSampler)
    {
        mpLightTracingEmissiveSampler = EmissiveUniformSampler::create(pRenderContext, mpScene, mUniformSamplerOptions);
        if (!mpLightTracingEmissiveSampler) throw std::exception("Failed to create emissive light sampler for light tracing");

        recreateVars(); // Trigger recreation of the program vars.
    }

    const uint32_t activeTriangleCount = mpScene->getLightCollection(pRenderContext)->getActiveLightCount();
    if (activeTriangleCount == 0u) mRecomputeEmissiveTriangleList = false;
    if (mRecomputeEmissiveTriangleList)
    {
        if (!mpEmissiveTriangles || mpEmissiveTriangles->getElementCount() < activeTriangleCount)
        {
            mpEmissiveTriangles = Buffer::createTyped<uint32_t>(activeTriangleCount);
            mpEmissiveTriangles->setName(mName + ".EmissiveTriangles");
            mRecomputeEmissiveTriangleList = true;
        }

        if (!mpEmissiveTriangleCount)
        {
            mpEmissiveTriangleCount = Buffer::createTyped<uint32_t>(1u);
            mpEmissiveTriangleCount->setName(mName + ".EmissiveTriangleCount");
            mRecomputeEmissiveTriangleList = true;
        }

        auto countUAV = mpEmissiveTriangleCount->getUAV();
        pRenderContext->clearUAV(countUAV.get(), uint4(0));
    }

    mSharedParams.maxNonSpecularBounces = mSharedParams.maxBounces;
    mSharedLightTracingParams.maxBounces = mSharedParams.maxBounces;
    mSharedLightTracingParams.maxNonSpecularBounces = mSharedCustomParams.usePhotonsForAll ? mSharedLightTracingParams.maxBounces :
                                                                                             (mAllowSingleDiffuseBounce && mSharedCustomParams.useCache == 0 ? 1u : 0u);
    mSharedLightTracingParams.frameDim = mSharedParams.frameDim;
    mSharedLightTracingParams.frameCount = mSharedParams.frameCount;

    // Update the emissive sampler to the current frame.
    assert(mpLightTracingEmissiveSampler);
    mpLightTracingEmissiveSampler->update(pRenderContext);

    if (mSharedCustomParams.useCache && !mpCache) recreateCachingData(pRenderContext);

    auto& pPreviousFrameCachingData = mPerFrameCachingData[1 - mSelectedFrameCachingData];
    auto& pCurrentFrameCachingData = mPerFrameCachingData[mSelectedFrameCachingData];

    // Set compile-time constants.
    RtProgram::SharedPtr pPathTracingProgram = mPathTracing.pProgram;
    setStaticParams(pPathTracingProgram.get());
    pPathTracingProgram->addDefine("USE_CACHE", mSharedCustomParams.useCache ? "1" : "0");
    pPathTracingProgram->addDefine("USE_PHOTONS_FOR_ALL", mSharedCustomParams.usePhotonsForAll ? "1" : "0");
    pPathTracingProgram->addDefine("USE_FIXED_SEARCH_RADIUS", mUseFixedSearchRadius ? "1" : "0");
    pPathTracingProgram->addDefine("CAP_SEARCH_RADIUS", mCapSearchRadius ? "1" : "0");
    pPathTracingProgram->addDefine("SEPARATE_AABB_STORAGE", mSeparateAABBStorage ? "1" : "0");
    mCollectionPointReuse.pProgram->addDefine("CAP_COLLECTING_POINTS", mCapReuseCollectingPoints ? "1" : "0");
    mCollectionPointReuse.pProgram->addDefine("INTERPOLATE_AABB_DATA", mInterpolatePreviousContributions ? "1" : "0");
    RtProgram::SharedPtr pProgram = mTracer.pProgram;
    setLTStaticParams(pProgram.get());
    pProgram->addDefine("USE_CACHE", mSharedCustomParams.useCache ? "1" : "0");
    pProgram->addDefine("CAP_COLLECTING_POINTS", mCapContributiongCollectingPoints ? "1" : "0");
    pProgram->addDefine("LATE_BSDF_APPLICATION", mLateBSDFApplication ? "1" : "0");
    mCopy.pProgram->addDefine("USE_CACHE", mSharedCustomParams.useCache ? "1" : "0");
    mCopy.pProgram->addDefine("LATE_BSDF_APPLICATION", mLateBSDFApplication ? "1" : "0");
    if (mSharedCustomParams.useCache && mpCache)
    {
        mpCache->prepareProgram(pPathTracingProgram);
        mpCache->prepareProgram(mGenerateAABBs.pProgram);
        mpCache->prepareProgram(mCollectionPointReuse.pProgram);
        mpCache->prepareProgram(pProgram);
        mpCache->prepareProgram(mDownloadDebug.pProgram);
    }

    // Add HitInfo defines.
    auto const hitInfoDefines = mpScene->getHitInfo().getDefines();
    mCollectionPointReuse.pProgram->addDefines(hitInfoDefines);
    pProgram->addDefines(hitInfoDefines);
    mCopy.pProgram->addDefines(hitInfoDefines);
    mDownloadDebug.pProgram->addDefines(hitInfoDefines);
    mDebugVisualiser.pProgram->addDefines(hitInfoDefines);

    // For optional I/O resources, set 'is_valid_<name>' defines to inform the program of which ones it can access.
    // TODO: This should be moved to a more general mechanism using Slang.
    pPathTracingProgram->addDefines(getValidResourceDefines(mInputChannels, renderData));
    pPathTracingProgram->addDefines(getValidResourceDefines(mOutputChannels, renderData));
    mCollectionPointReuse.pProgram->addDefines(getValidResourceDefines(mOutputChannels, renderData));
    pProgram->addDefines(getValidResourceDefines(mInputChannels, renderData));
    pProgram->addDefines(getValidResourceDefines(mOutputChannels, renderData));
    mCopy.pProgram->addDefines(getValidResourceDefines(mOutputChannels, renderData));

    if (mUseEmissiveSampler)
    {
        // Specialize program for the current emissive light sampler options.
        assert(mpEmissiveSampler);
        const auto lightSamplerDefines = mpEmissiveSampler->getDefines();
        if (pPathTracingProgram->addDefines(lightSamplerDefines)) mPathTracing.pVars = nullptr;
    }
    {
        const auto lightSamplerDefines = mpLightTracingEmissiveSampler->getDefines();
        if (pProgram->addDefines(lightSamplerDefines)) mTracer.pVars = nullptr;

        if (mRecomputeEmissiveTriangleList)
        {
            for (auto [key, value] : lightSamplerDefines)
                mpRestricter->addDefine(key, value);
            mpRestricter->setVars(nullptr);
        }
    }

    // Prepare program vars. This may trigger shader compilation.
    // The program should have all necessary defines set at this point.
    if (!mPathTracing.pVars || !mGenerateAABBs.pVars || !mCollectionPointReuse.pVars || !mTracer.pVars || !mApplyBSDF.pVars || !mCopy.pVars || !mDownloadDebug.pVars) prepareVars();
    assert(mPathTracing.pVars);
    assert(mGenerateAABBs.pVars);
    assert(mCollectionPointReuse.pVars);
    assert(mTracer.pVars);
    assert(mApplyBSDF.pVars);
    assert(mCopy.pVars);
    assert(mDownloadDebug.pVars);

    // Set shared data into parameter block.
    setTracerData(renderData);

    // Bind I/O buffers. These needs to be done per-frame as the buffers may change anytime.
    auto bindDeepInit = [pGlobalVars = mPathTracing.pVars->getRootVar(), &renderData](const ChannelDesc& desc)
    {
        pGlobalVars[desc.texname] = renderData[desc.name]->asTexture();
    };
    auto bindIn = [pGlobalVars = mTracer.pVars->getRootVar(), &renderData](const ChannelDesc& desc)
    {
        pGlobalVars[desc.texname] = renderData[desc.name]->asTexture();
    };
    auto bindOut = [pGlobalVars = mTracer.pVars->getRootVar(), &renderData](const ChannelDesc& desc)
    {
        if (desc.name == kTimeOutput) pGlobalVars[desc.texname] = renderData[desc.name]->asTexture();
    };
    for (auto channel : mInputChannels) {
        bindDeepInit(channel);
        bindIn(channel);
    }
    for (auto channel : mOutputChannels) bindOut(channel);

    if (mRecomputeEmissiveTriangleList)
    {
        PROFILE("ScreenSpaceCaustics::execute()_restrictEmissiveTriangles");
        mpRestricter["Params"]["restrictedMaterialID"] = mSelectedEmissiveMaterialIndex;
        mpRestricter["gActiveTriangles"] = mpEmissiveTriangles;
        mpRestricter["gActiveTriangleCount"] = mpEmissiveTriangleCount;
        mpRestricter["gScene"] = mpScene->getParameterBlock();
        mpRestricter->execute(pRenderContext, activeTriangleCount, 1u, 1u);

        //mRecomputeEmissiveTriangleList = false;
    }

    // Get dimensions of ray dispatch.
    const uint2 targetDim = renderData.getDefaultTextureDims();
    assert(targetDim.x > 0 && targetDim.y > 0);
    auto colorResource = renderData.getResource(kColorOutput);
    auto albedoResource = renderData.getResource(kAlbedoOutput);
    auto colorTexture = colorResource ? colorResource->asTexture() : Texture::SharedPtr();

    mpPixelDebug->prepareProgram(pProgram, mTracer.pVars->getRootVar());
    mpPixelStats->prepareProgram(pProgram, mTracer.pVars->getRootVar());
    mpPathDebug->prepareProgram(pProgram);
    mpPathDebug->setShaderData(mTracer.pVars->getRootVar());

    mPathTracing.pCommonDataBlock["params"].setBlob(mSharedParams);

    auto pPathTracingGlobalVars = mPathTracing.pVars->getRootVar();
    pPathTracingGlobalVars["gScene"] = mpScene->getParameterBlock();
    pPathTracingGlobalVars["gOutputColor"] = colorTexture;
    pPathTracingGlobalVars["gOutputAlbedo"] = albedoResource ? albedoResource->asTexture() : Texture::SharedPtr();

    if (mSharedCustomParams.useCache)
    {
        assert(mpCache);

        auto const& sceneBounds = mpScene->getSceneBounds();
        mPathTracing.pCacheRelatedBlock["sceneMin"] = sceneBounds.minPoint;
        mPathTracing.pCacheRelatedBlock["fixedSearchRadius"] = mSearchRadius;
        mPathTracing.pCacheRelatedBlock["sceneMax"] = sceneBounds.maxPoint;
        mPathTracing.pCacheRelatedBlock["maxSearchRadius"] = mMaxSearchRadius;

        if (!mSeparateAABBStorage) mPathTracing.pCacheRelatedBlock["aabbs"] = mpCache->getAabbBuffer();

        mPathTracing.pCacheRelatedBlock["currentFramePixelCoords"] = pCurrentFrameCachingData.pIndexToPixelMap;
        mPathTracing.pCacheRelatedBlock["currentFrameCachingPointData"] = pCurrentFrameCachingData.pCachingPointData;
        mPathTracing.pCacheRelatedBlock["pathToCachingPointData"] = mpPathToCachingPointData;
    }

    if (!mSharedCustomParams.usePhotonsForAll || mSharedCustomParams.useCache)
    {
        PROFILE("ScreenSpaceCaustics::execute()_pathTracing");
        mpScene->raytrace(pRenderContext, mPathTracing.pProgram.get(), mPathTracing.pVars, uint3(targetDim, 1));
    }

    if (mSharedCustomParams.useCache && mSeparateAABBStorage)
    {
        auto pGlobalVars = mGenerateAABBs.pVars->getRootVar();
        pGlobalVars["Params"]["frameDim"] = targetDim;

        pGlobalVars["pathToCachingPointData"] = mpPathToCachingPointData;
        pGlobalVars["pixelCoords"] = pCurrentFrameCachingData.pIndexToPixelMap;
        pGlobalVars["aabbs"] = mpCache->getAabbBuffer();

        pRenderContext->uavBarrier(mpPathToCachingPointData.get());

        PROFILE("ScreenSpaceCaustics::execute()_generateAABBs");
        mpScene->raytrace(pRenderContext, mGenerateAABBs.pProgram.get(), mGenerateAABBs.pVars, uint3(mSharedParams.frameDim, 1));
    }

    if (mSharedCustomParams.useCache && (!mResetTemporalReuse && !mDisableTemporalReuse))
    {
        mCollectionPointReuse.pVars->getRootVar()["gTraversedAABBCount"] = renderData[kTraversedAABBCount] ? renderData[kTraversedAABBCount]->asTexture() : Texture::SharedPtr();

        mCollectionPointReuse.pBlock["frameDim"] = mSharedParams.frameDim;
        mCollectionPointReuse.pBlock["maxUsedCollectingPoints"] = mMaxReuseCollectingPoints;

        mCollectionPointReuse.pBlock["aabbBVH"].setSrv(mpCache->getAccelerationStructure());

        mCollectionPointReuse.pBlock["previousFramePixelCoords"] = pPreviousFrameCachingData.pIndexToPixelMap;
        mCollectionPointReuse.pBlock["previousFrameCachingPointData"] = pPreviousFrameCachingData.pCachingPointData;
        mCollectionPointReuse.pBlock["previousFrameStatsOutput"] = pCurrentFrameCachingData.pAccumulatedStats;
        mCollectionPointReuse.pBlock["currentFramePixelCoords"] = pCurrentFrameCachingData.pIndexToPixelMap;
        mCollectionPointReuse.pBlock["currentFrameCachingPointData"] = pCurrentFrameCachingData.pCachingPointData;
        mCollectionPointReuse.pBlock["interpolatedStatsOutput"] = pPreviousFrameCachingData.pAccumulatedStats;

        {
            PROFILE("ScreenSpaceCaustics::execute()_collectionPointReuse");
            pRenderContext->raytrace(mCollectionPointReuse.pProgram.get(), mCollectionPointReuse.pVars.get(), targetDim.x, targetDim.y, 1);
        }
    }

    if (mSharedCustomParams.useCache)
    {
        mpCache->update(pRenderContext, mTracer.pVars.get(), false);
    }

    pRenderContext->clearUAV(pCurrentFrameCachingData.pAccumulatedStats->getUAV().get(), float4(0.0f));

    if (mEnableDebug)
    {
        pRenderContext->copyResource(mpPreviousAccumulatedStats.get(), pPreviousFrameCachingData.pAccumulatedStats.get());
    }

    // Spawn the rays.
    {
        mTracer.pParameterBlock["activeTriangleData"]["list"] = mpEmissiveTriangles;
        mTracer.pParameterBlock["activeTriangleData"]["count"] = mpEmissiveTriangleCount;
        mTracer.pParameterBlock["activeTriangleData"]["restrictEmissiveTriangles"] = mRestrictEmissionByMaterials;

        PROFILE("ScreenSpaceCaustics::execute()_lightTracing");
        mpScene->raytrace(pRenderContext, mTracer.pProgram.get(), mTracer.pVars, uint3(mSharedCustomParams.lightPathCount, 1, 1));
    }

    if (colorResource)
    {
        auto countResource = renderData.getResource(kCountOutput);
        auto searchRadiusResource = renderData.getResource(kSearchRadiusOutput);

        if (mSharedCustomParams.useCache && mLateBSDFApplication)
        {
            auto pGlobalVars = mApplyBSDF.pVars->getRootVar();
            pGlobalVars["Params"]["frameDim"] = targetDim;

            pGlobalVars["pathToCachingPointData"] = mpPathToCachingPointData;
            pGlobalVars["statsOutput"] = pCurrentFrameCachingData.pAccumulatedStats;

            PROFILE("ScreenSpaceCaustics::execute()_applyBSDF");
            mpScene->raytrace(pRenderContext, mApplyBSDF.pProgram.get(), mApplyBSDF.pVars, uint3(mSharedParams.frameDim, 1));
        }

        auto pGlobalVars = mCopy.pVars->getRootVar();
        pGlobalVars["Params"]["frameDim"] = targetDim;
        pGlobalVars["Params"]["disableTemporalReuse"] = mDisableTemporalReuse ? 1 : 0;
        pGlobalVars["Params"]["reuseAlpha"] = mResetTemporalReuse ? 0.0f : mReuseAlpha;

        pGlobalVars["currentFrameStatsOutput"] = pCurrentFrameCachingData.pAccumulatedStats;
        pGlobalVars["pathToCachingPointData"] = mpPathToCachingPointData;

        pGlobalVars["previousFrameStatsOutput"] = pPreviousFrameCachingData.pAccumulatedStats;
        pGlobalVars["gOutputColor"] = colorTexture;
        pGlobalVars["gOutputCount"] = countResource ? countResource->asTexture() : Texture::SharedPtr();
        pGlobalVars["gOutputSearchRadius"] = searchRadiusResource ? searchRadiusResource->asTexture() : Texture::SharedPtr();

        auto const dispatchSize = div_round_up(uint3(targetDim, 1u),
                                               mCopy.pProgram->getReflector()->getThreadGroupSize());

        {
            PROFILE("ScreenSpaceCaustics::execute()_copyToTexture()");
            pRenderContext->dispatch(mCopy.pState.get(), mCopy.pVars.get(), dispatchSize);
        }
    }

    if (mEnableDebug)
    {
        auto pGlobalVars = mDownloadDebug.pVars->getRootVar();
        pGlobalVars["Params"]["frameDim"] = targetDim;
        pGlobalVars["Params"]["selectedPixel"] = mDebugSelectedPixel;

        pGlobalVars["previousFramePixelCoords"] = pPreviousFrameCachingData.pIndexToPixelMap;
        pGlobalVars["previousFrameStatsOutput"] = mpPreviousAccumulatedStats;
        pGlobalVars["previousFrameCachingPointData"] = pPreviousFrameCachingData.pCachingPointData;

        pGlobalVars["currentFramePixelCoords"] = pCurrentFrameCachingData.pIndexToPixelMap;
        pGlobalVars["currentFrameStatsOutput"] = pCurrentFrameCachingData.pAccumulatedStats;
        pGlobalVars["currentFrameCachingPointData"] = pCurrentFrameCachingData.pCachingPointData;

        pGlobalVars["pathToCachingPointData"] = mpPathToCachingPointData;

        pGlobalVars["interpolatedStatsOutput"] = pPreviousFrameCachingData.pAccumulatedStats;
        pGlobalVars["colorOutput"] = colorResource ? colorResource->asTexture() : Texture::SharedPtr();

        pGlobalVars["debugDataBuffer"] = mpDeviceDebugData;

        {
            PROFILE("ScreenSpaceCaustics::execute()_downloadDebugData()");
            pRenderContext->dispatch(mDownloadDebug.pState.get(), mDownloadDebug.pVars.get(), uint3(1u));
        }

        pRenderContext->copyBufferRegion(mpHostDebugData.get(), 0llu, mpDeviceDebugData.get(), 0llu, mpHostDebugData->getSize());
        pRenderContext->flush(false);
        mpDebugDataReadFence->gpuSignal(pRenderContext->getLowLevelData()->getCommandQueue());
    }

    if (auto debugResource = renderData.getResource(kInternalDebugOutput); mEnableDebug && debugResource)
    {
        auto pGlobalVars = mDebugVisualiser.pVars->getRootVar();
        pGlobalVars["Params"]["frameDim"] = targetDim;

        pGlobalVars["previousFramePixelCoords"] = pPreviousFrameCachingData.pIndexToPixelMap;
        pGlobalVars["previousFrameStatsOutput"] = mpPreviousAccumulatedStats;
        pGlobalVars["previousFrameCachingPointData"] = pPreviousFrameCachingData.pCachingPointData;

        pGlobalVars["currentFramePixelCoords"] = pCurrentFrameCachingData.pIndexToPixelMap;
        pGlobalVars["currentFrameStatsOutput"] = pCurrentFrameCachingData.pAccumulatedStats;
        pGlobalVars["currentFrameCachingPointData"] = pCurrentFrameCachingData.pCachingPointData;

        pGlobalVars["pathToCachingPointData"] = mpPathToCachingPointData;

        pGlobalVars["interpolatedStatsOutput"] = pPreviousFrameCachingData.pAccumulatedStats;
        pGlobalVars["colorOutput"] = colorTexture;

        pGlobalVars["debugOutput"] = debugResource->asTexture();

        auto const dispatchSize = div_round_up(uint3(targetDim, 1u),
                                               mDebugVisualiser.pProgram->getReflector()->getThreadGroupSize());

        {
            PROFILE("ScreenSpaceCaustics::execute()_visualiseDebugData()");
            pRenderContext->dispatch(mDebugVisualiser.pState.get(), mDebugVisualiser.pVars.get(), dispatchSize);
        }
    }
    else if (debugResource)
    {
        pRenderContext->clearTexture(debugResource->asTexture().get());
    }

    mpPathDebug->endFrame(pRenderContext, mSelectedSegmentID);

    // Call shared post-render code.
    endFrame(pRenderContext, renderData);

    mResetTemporalReuse = false;
    mSelectedFrameCachingData = 1u - mSelectedFrameCachingData;
}

void ScreenSpaceCaustics::renderUI(Gui::Widgets& widget)
{

    bool dirty = false;

    dirty |= widget.var("Light path count", mSharedCustomParams.lightPathCount);

    dirty |= widget.var("Samples/pixel", mSharedParams.samplesPerPixel, 1u, 1u << 16, 1);
    if ((dirty |= widget.var("Light samples/vertex", mSharedParams.lightSamplesPerVertex, 1u, kMaxLightSamplesPerVertex))) recreateVars();  // Trigger recreation of the program vars.
    widget.tooltip("The number of shadow rays that will be traced at each path vertex.\n"
        "The supported range is [1," + std::to_string(kMaxLightSamplesPerVertex) + "].", true);

    uint maxPathLength = mSharedParams.maxBounces + 2u;
    if (widget.var("Max path length", maxPathLength, 2u, kMaxPathLength + 2u))
    {
        mSharedParams.maxBounces = maxPathLength - 2u; // -1 for segments to bounces conversion, -1 as first handled by the G-buffer.
        dirty = true;
    }
    widget.tooltip("Maximum path length in terms of segments.\n2 = direct only\n3 = one indirect bounce etc.", true);

    uint maxPTRaysPerPixel = 0u;
    if (mSharedCustomParams.usePhotonsForAll == 0 || mSharedCustomParams.useCache != 0)
    {
        widget.text("PT max bounces: " + std::to_string(mSharedParams.maxBounces));
        widget.text("PT max non-spec bounces: " + std::to_string(mSharedParams.maxNonSpecularBounces));

        maxPTRaysPerPixel = maxRaysPerPixel();
    }
    widget.text("LT max bounces: " + std::to_string(mSharedLightTracingParams.maxBounces));
    widget.text("LT max non-spec bounces: " + std::to_string(mSharedLightTracingParams.maxNonSpecularBounces));
    uint maxLTRaysPerPath = (mSharedCustomParams.usePhotonsForAll == 0u) ? mSharedLightTracingParams.maxBounces : std::max(1u, mSharedLightTracingParams.maxBounces);

    widget.text("Max rays/pixel: " + std::to_string(maxPTRaysPerPixel + static_cast<uint32_t>(0.5f + (static_cast<uint64_t>(maxLTRaysPerPath) * mSharedCustomParams.lightPathCount) / static_cast<float>(mPixelCount))));
    widget.tooltip("This is the maximum number of rays that will be traced per pixel.\n"
        "The number depends on the scene's available light types and the current configuration.", true);
    widget.text("Max PT rays/pixel: " + std::to_string(maxPTRaysPerPixel));
    widget.text("Max LT rays/path: " + std::to_string(maxLTRaysPerPath));

    // Surface area computation selection.
    widget.text("Surface area method:");
    uint32_t selectedSurfaceAreaMethod = static_cast<uint32_t>(mSelectedSurfaceAreaMethod);
    if (widget.dropdown("##SurfaceAreaMethod", sSurfaceAreaDropdownList, selectedSurfaceAreaMethod, true))
    {
        mTracer.pProgram->addDefine("SURFACE_AREA_METHOD", std::to_string(selectedSurfaceAreaMethod));
        mSelectedSurfaceAreaMethod = static_cast<SurfaceAreaMethod>(selectedSurfaceAreaMethod);
        dirty = true;
    }

    dirty |= widget.checkbox("Ignore projection volume", mSharedCustomParams.ignoreProjectionVolume);
    dirty |= widget.checkbox("Accumulate non-specular photons too", mSharedCustomParams.usePhotonsForAll);
    dirty |= widget.checkbox("Allow single diffuse bounce on caustic paths", mAllowSingleDiffuseBounce);
    widget.tooltip("Only when caching is disabled");
    dirty |= widget.checkbox("Late application of BSDF to caustics", mLateBSDFApplication);
    widget.tooltip("Instead of applying the BSDF on each light ray--cache area intersection, it is done once per cache area in a separate pass using the flipped surface normal as incoming vector rather than the light ray.");
    dirty |= widget.checkbox("Store AABBs in separate pass", mSeparateAABBStorage);
    widget.tooltip("Instead of storing them while path tracing, leave it to a separate pass. This is required if sorting the AABBs is desired.");

    dirty |= widget.checkbox("Restrict emission", mRestrictEmissionByMaterials);
    widget.tooltip("Only emit photons from emissive triangles using a specific material.");
    if (widget.textbox("Material name", mEmissiveMaterialName))
    {
        computerEmissionMaterialIndex();

        dirty = true;
    }
    if (mpScene && widget.var("Material ID", mSelectedEmissiveMaterialIndex, 0u, mpScene->getMaterialCount()))
    {
        mRecomputeEmissiveTriangleList = true;
        dirty = true;
    }

    // Draw sub-group for caching options.
    auto cachingGroup = widget.group("##Caching", mSharedCustomParams.useCache);
    dirty = widget.checkbox("Caching", mSharedCustomParams.useCache, true) || dirty;
    if (cachingGroup.open() && mpCache)
    {
        dirty = mpCache->renderUI(widget) || dirty;

        dirty = widget.checkbox("Use fixed search radius", mUseFixedSearchRadius) || dirty;
        widget.tooltip("When a dynamic search radius is selected, the radius will for example be larger the further away a collection point is from the camera.");
        dirty = widget.var("Search radius", mSearchRadius, 1e-5f) || dirty;
        widget.tooltip("Radius in which each collection point will gather incoming photons, if using a fixed search radius.");

        dirty = widget.checkbox("Cap search radius", mCapSearchRadius) || dirty;
        dirty = widget.var("Max search radius", mMaxSearchRadius, 1e-5f) || dirty;
        widget.tooltip("Maximum radius in which each collection point will gather incoming photons, when using a dynamic search radius.");

        dirty = widget.checkbox("Cap collecting points during reuse", mCapReuseCollectingPoints) || dirty;
        dirty = widget.var("Max collecting points intersected for reuse", mMaxReuseCollectingPoints) || dirty;

        dirty = widget.checkbox("Cap collecting points during contrib", mCapContributiongCollectingPoints) || dirty;
        dirty = widget.var("Max collecting points intersected during contrib", mMaxContributionToCollectingPoints) || dirty;

        dirty = widget.checkbox("Disable temporal reuse", mDisableTemporalReuse) || dirty;
        if (widget.button("Reset temporal reuse")) dirty = mResetTemporalReuse = true;
        dirty = widget.var("Reuse alpha", mReuseAlpha, 0.0f, 1.0f) || dirty;
        widget.tooltip("A reuse of 0 will only use new data while 1 will only use old data.");

        dirty = widget.checkbox("Interpolate previous contributions", mInterpolatePreviousContributions) || dirty;
    }
    cachingGroup.release();

    dirty |= widget.checkbox("Alpha test", mSharedParams.useAlphaTest);
    widget.tooltip("Use alpha testing on non-opaque triangles.");

    // Clamping for basic firefly removal.
    dirty |= widget.checkbox("Clamp samples", mSharedParams.clampSamples);
    widget.tooltip("Basic firefly removal.\n\n"
        "This option enables clamping the per-sample contribution before accumulating. "
        "Note that energy is lost and the images will be darker when clamping is enabled.", true);
    if (mSharedParams.clampSamples)
    {
        dirty |= widget.var("Threshold", mSharedParams.clampThreshold, 0.f, std::numeric_limits<float>::max(), mSharedParams.clampThreshold * 0.01f);
    }

    dirty |= widget.checkbox("Force alpha to 1.0", mSharedParams.forceAlphaOne);
    widget.tooltip("Forces the output alpha channel to 1.0.\n"
        "Otherwise the background will be 0.0 and the foreground 1.0 to allow separate compositing.", true);

    dirty |= widget.checkbox("Use nested dielectrics", mSharedParams.useNestedDielectrics);

    dirty |= widget.checkbox("Use legacy BSDF code", mSharedParams.useLegacyBSDF);

    // Draw sub-groups for various options.
    if (auto samplingGroup = widget.group("Sampling", true))
    {
        // Importance sampling controls.
        dirty |= samplingGroup.checkbox("BRDF importance sampling", mSharedParams.useBRDFSampling);
        samplingGroup.tooltip("BRDF importance sampling should normally be enabled.\n\n"
            "If disabled, cosine-weighted hemisphere sampling is used.\n"
            "That can be useful for debugging but expect slow convergence.", true);

        dirty |= samplingGroup.checkbox("Next-event estimation (NEE)", mSharedParams.useNEE);
        widget.tooltip("Use next-event estimation.\n"
            "This option enables direct illumination sampling at each path vertex.\n"
            "This does not apply to delta reflection/transmission lobes, which need to trace an extra scatter ray.");

        if (mpEmissiveSampler)
        {
            if (auto emissiveGroup = widget.group("PT emissive sampler options"))
            {
                if (mpEmissiveSampler->renderUI(emissiveGroup))
                {
                    // Get the latest options for the current sampler. We need these to re-create the sampler at scene changes and for pass serialization.
                    switch (mSelectedEmissiveSampler)
                    {
                    case EmissiveLightSamplerType::Uniform:
                        mUniformSamplerOptions = std::static_pointer_cast<EmissiveUniformSampler>(mpEmissiveSampler)->getOptions();
                        break;
                    case EmissiveLightSamplerType::LightBVH:
                        mLightBVHSamplerOptions = std::static_pointer_cast<LightBVHSampler>(mpEmissiveSampler)->getOptions();
                        break;
                    default:
                        should_not_get_here();
                        break;
                    }
                    dirty = true;
                }
            }
        }

        if (auto emissiveGroup = widget.group("LT emissive sampler options"))
        {
            if (mpLightTracingEmissiveSampler->renderUI(emissiveGroup))
            {
                mLightTracingUniformSamplerOptions = std::static_pointer_cast<EmissiveUniformSampler>(mpLightTracingEmissiveSampler)->getOptions();
                dirty = true;
            }
        }

        dirty |= samplingGroup.var("Specular roughness threshold", mSharedParams.specularRoughnessThreshold, 0.f, 1.f);
        samplingGroup.tooltip("Specular reflection events are only classified as specular if the material's roughness value is equal or smaller than this threshold.", true);

        // Russian roulette.
        dirty |= samplingGroup.checkbox("Russian roulette", mSharedParams.useRussianRoulette);
        if (mSharedParams.useRussianRoulette)
        {
            dirty |= samplingGroup.var("Absorption probability ", mSharedParams.probabilityAbsorption, 0.0f, 0.999f);
            samplingGroup.tooltip("Russian roulette probability of absorption at each bounce (p).\n"
                "Disable via the checkbox if not used (setting p = 0.0 still incurs a runtime cost).", true);
        }

        // Sample generator selection.
        samplingGroup.text("Sample generator:");
        if (samplingGroup.dropdown("##SampleGenerator", SampleGenerator::getGuiDropdownList(), mSelectedSampleGenerator, true))
        {
            mpSampleGenerator = SampleGenerator::create(mSelectedSampleGenerator);
            recreateVars(); // Trigger recreation of the program vars.
            dirty = true;
        }

        samplingGroup.checkbox("Use fixed seed", mSharedParams.useFixedSeed);
        samplingGroup.tooltip("Forces a fixed random seed for each frame.\n\n"
            "This should produce exactly the same image each frame, which can be useful for debugging using print() and otherwise.", true);

        samplingGroup.var("Fixed seed", mSharedParams.fixedSeed);
    }

    const float3& pvMin = mSharedCustomParams.projectionVolumeMin;
    const float3& pvMax = mSharedCustomParams.projectionVolumeMax;
    widget.text("Projection volume:\n"\
                "\tmin=( " + std::to_string(pvMin.x) + " " + std::to_string(pvMin.y) + " " + std::to_string(pvMin.z) + " )\n"\
                "\tmax=( " + std::to_string(pvMax.x) + " " + std::to_string(pvMax.y) + " " + std::to_string(pvMax.z) + " )");

    renderLoggingUI(widget);

    renderDebugUI(widget);

    // If rendering options that modify the output have changed, set flag to indicate that.
    // In execute() we will pass the flag to other passes for reset of temporal data etc.
    if (dirty)
    {
        mOptionsChanged = true;
    }
}

void ScreenSpaceCaustics::setScene(RenderContext* pRenderContext, const Scene::SharedPtr& pScene)
{
    PathTracer::setScene(pRenderContext, pScene);
    mpPathDebug->setScene(pRenderContext, pScene);

    if (pScene)
    {
        const auto sceneDefines = pScene->getSceneDefines();
        mPathTracing.pProgram->addDefines(sceneDefines);
        mGenerateAABBs.pProgram->addDefines(sceneDefines);
        mTracer.pProgram->addDefines(sceneDefines);
        mApplyBSDF.pProgram->addDefines(sceneDefines);
        for (auto [key, value] : sceneDefines)
            mpRestricter->addDefine(key, value);

        computeListOfSpecularMaterials();
        computeProjectionVolume();

        computerEmissionMaterialIndex();
        mRecomputeEmissiveTriangleList = true;
    }

    mResetTemporalReuse = true;
}

bool ScreenSpaceCaustics::onKeyEvent(const KeyboardEvent& event)
{
    bool processed = false;

    if (event.type == KeyboardEvent::Type::KeyReleased)
    {
        if (KeyboardEvent::Key::M == event.key)
        {
            mDebugSelectedPixel = mCurrentCursorPosition;
            processed = true;
        }
        else if (KeyboardEvent::Key::R == event.key)
        {
            mResetTemporalReuse = true;
            mOptionsChanged = true;
            processed = true;
        }
        else if (KeyboardEvent::Key::T == event.key)
        {
            mDisableTemporalReuse = !mDisableTemporalReuse;
            mOptionsChanged = true;
            processed = true;
        }
        else if (KeyboardEvent::Key::C == event.key)
        {
            mSharedCustomParams.useCache = !mSharedCustomParams.useCache;
            mOptionsChanged = true;
            processed = true;
        }
    }

    return processed;
}

bool ScreenSpaceCaustics::onMouseEvent(const MouseEvent& event)
{
    if (event.type == MouseEvent::Type::Move) mCurrentCursorPosition = event.screenPos;
    return false;
}

void ScreenSpaceCaustics::onHotReload(HotReloadFlags reloaded)
{
    mResetTemporalReuse = true;
}

void ScreenSpaceCaustics::computeListOfSpecularMaterials()
{
    assert(mpScene);

    mIsMaterialSpecular.clear();

    const auto materialCount = mpScene->getMaterialCount();
    mIsMaterialSpecular.resize(materialCount, false);

    for (uint32_t materialID = 0; materialID < materialCount; ++materialID)
    {
        const auto& material = mpScene->getMaterial(materialID);
        const auto& materialName = material->getName();
        if (materialName == "Glass") mIsMaterialSpecular[materialID] = true;
        else if (materialName == "Clear glass") mIsMaterialSpecular[materialID] = true;
        else if (materialName == "TransparentGlass") mIsMaterialSpecular[materialID] = true;
        else if (materialName == "Gold") mIsMaterialSpecular[materialID] = true;
        else if (materialName == "Mirror") mIsMaterialSpecular[materialID] = true;
        else if (materialName == "Rough mirror") mIsMaterialSpecular[materialID] = true;
    }
}

void ScreenSpaceCaustics::computerEmissionMaterialIndex()
{
    if (!mpScene || mEmissiveMaterialName.empty())
    {
        mRestrictEmissionByMaterials = false;
        return;
    }

    constexpr uint32_t invalidIndex = std::numeric_limits<uint32_t>::max();
    uint32_t materialIndex = invalidIndex;
    uint32_t currentMaterialIndex = 0u;
    for (auto const& material : mpScene->getMaterials())
    {
        if (mEmissiveMaterialName == material->getName() && material->isEmissive())
        {
            if (materialIndex == invalidIndex) materialIndex = currentMaterialIndex;
            else logWarning("Multiple emissive materials with the same name; only selecting the first one.");
        }
        ++currentMaterialIndex;
    }

    if (materialIndex == invalidIndex)
    {
        logWarning("No material of that name were found.");
        mRestrictEmissionByMaterials = false;
        return;
    }

    mRecomputeEmissiveTriangleList = (mSelectedEmissiveMaterialIndex == materialIndex) || mRecomputeEmissiveTriangleList;
    mSelectedEmissiveMaterialIndex = materialIndex;
}

void ScreenSpaceCaustics::computeProjectionVolume()
{
    AABB projectionVolume;
    const auto& globalMatrices = mpScene->getAnimationController()->getGlobalMatrices();
    const auto meshInstanceCount = mpScene->getMeshInstanceCount();
    for (uint32_t meshInstanceID = 0; meshInstanceID < meshInstanceCount; ++meshInstanceID)
    {
        const auto& meshInstance = mpScene->getMeshInstance(meshInstanceID);
        if (!mIsMaterialSpecular[meshInstance.materialID]) continue;

        const auto& meshBound = mpScene->getMeshBounds(meshInstance.meshID);
        const auto& instanceTransform = globalMatrices[meshInstance.globalMatrixID];

        projectionVolume.include(meshBound.transform(instanceTransform));
    }

    mSharedCustomParams.projectionVolumeMin = projectionVolume.minPoint;
    mSharedCustomParams.projectionVolumeMax = projectionVolume.maxPoint;
}

void ScreenSpaceCaustics::recreateCachingData(RenderContext* pRenderContext)
{
    uint32_t i = 0;
    for (auto& perFrameData : mPerFrameCachingData)
    {
        const std::string indexing = std::string("[") + std::to_string(i) + "]";

        perFrameData.pIndexToPixelMap = Buffer::createTyped<uint32_t>(mPixelCount);
        assert(perFrameData.pIndexToPixelMap);
        perFrameData.pIndexToPixelMap->setName(mName + ".IndexToPixelMap" + indexing);
        pRenderContext->clearUAV(perFrameData.pIndexToPixelMap->getUAV().get(), uint4(std::numeric_limits<uint32_t>::max()));

        perFrameData.pCachingPointData = Buffer::createStructured(sizeof(CachingPointData), mPixelCount);
        assert(perFrameData.pCachingPointData);
        perFrameData.pCachingPointData->setName(mName + ".CacheCustomData" + indexing);

        ++i;
    }

    if (!mpCache) mpCache = CachingViaBVH::create(mCachingOptions);
    assert(mPixelCount == mSharedParams.frameDim.x * mSharedParams.frameDim.y);
    mpCache->allocate(mSharedParams.frameDim);

    mpPathToCachingPointData = Buffer::createStructured(sizeof(PathToCachingPointData), mPixelCount);
    assert(mpPathToCachingPointData);
    mpPathToCachingPointData->setName(mName + ".PathToCachingPointData");
}

void ScreenSpaceCaustics::prepareVars()
{
    assert(mpScene);
    assert(mPathTracing.pProgram);
    assert(mGenerateAABBs.pProgram);
    assert(mCollectionPointReuse.pProgram);
    assert(mTracer.pProgram);
    assert(mApplyBSDF.pProgram);

    // Configure program.
    mPathTracing.pProgram->addDefines(mpSampleGenerator->getDefines());
    mTracer.pProgram->addDefines(mpSampleGenerator->getDefines());

    // Create program variables for the current program/scene.
    // This may trigger shader compilation. If it fails, throw an exception to abort rendering.
    mPathTracing.pVars = RtProgramVars::create(mPathTracing.pProgram, mpScene);
    mGenerateAABBs.pVars = RtProgramVars::create(mGenerateAABBs.pProgram, mpScene);
    mCollectionPointReuse.pVars = RtProgramVars::create(mCollectionPointReuse.pProgram, mpScene);
    mTracer.pVars = RtProgramVars::create(mTracer.pProgram, mpScene);
    mApplyBSDF.pVars = RtProgramVars::create(mApplyBSDF.pProgram, mpScene);
    mCopy.pVars = ComputeVars::create(mCopy.pProgram.get());
    mDownloadDebug.pVars = ComputeVars::create(mDownloadDebug.pProgram.get());

    // Bind utility classes into shared data.
    auto pPathTracingGlobalVars = mPathTracing.pVars->getRootVar();
    bool success = mpSampleGenerator->setShaderData(pPathTracingGlobalVars);
    if (!success) throw std::exception("Failed to bind sample generator");
    auto pGlobalVars = mTracer.pVars->getRootVar();
    success = mpSampleGenerator->setShaderData(pGlobalVars);
    if (!success) throw std::exception("Failed to bind sample generator");

    // Create parameter block for shared data.
    {
        ProgramReflection::SharedConstPtr pReflection = mPathTracing.pProgram->getReflector();

        ParameterBlockReflection::SharedConstPtr pCommonBlockReflection = pReflection->getParameterBlock(kPTCommonDataBlockName);
        assert(pCommonBlockReflection);
        mPathTracing.pCommonDataBlock = ParameterBlock::create(pCommonBlockReflection);
        assert(mPathTracing.pCommonDataBlock);

        ParameterBlockReflection::SharedConstPtr pCachingBlockReflection = pReflection->getParameterBlock(kPTCachingDataBlockName);
        assert(pCachingBlockReflection);
        mPathTracing.pCacheRelatedBlock = ParameterBlock::create(pCachingBlockReflection);
        assert(mPathTracing.pCacheRelatedBlock);
    }
    {
        ProgramReflection::SharedConstPtr pReflection = mCollectionPointReuse.pProgram->getReflector();
        ParameterBlockReflection::SharedConstPtr pBlockReflection = pReflection->getParameterBlock(kParameterBlockName);
        assert(pBlockReflection);
        mCollectionPointReuse.pBlock = ParameterBlock::create(pBlockReflection);
        assert(mCollectionPointReuse.pBlock);
    }
    {
        ProgramReflection::SharedConstPtr pReflection = mTracer.pProgram->getReflector();
        ParameterBlockReflection::SharedConstPtr pBlockReflection = pReflection->getParameterBlock(kParameterBlockName);
        assert(pBlockReflection);
        mTracer.pParameterBlock = ParameterBlock::create(pBlockReflection);
        assert(mTracer.pParameterBlock);
    }

    // Bind static resources to the parameter block here. No need to rebind them every frame if they don't change.
    // Bind the light probe if one is loaded.
    if (mpEnvMapSampler)
    {
        mpEnvMapSampler->setShaderData(mPathTracing.pCommonDataBlock["envMapSampler"]);
        mpEnvMapSampler->setShaderData(mTracer.pParameterBlock["envMapSampler"]);
    }

    // Bind the parameter block to the global program variables.
    mPathTracing.pVars->setParameterBlock(kPTCommonDataBlockName, mPathTracing.pCommonDataBlock);
    mPathTracing.pVars->setParameterBlock(kPTCachingDataBlockName, mPathTracing.pCacheRelatedBlock);
    mCollectionPointReuse.pVars->setParameterBlock(kParameterBlockName, mCollectionPointReuse.pBlock);
    mTracer.pVars->setParameterBlock(kParameterBlockName, mTracer.pParameterBlock);
}

void ScreenSpaceCaustics::renderDebugUI(Gui::Widgets& widget)
{
    bool dirty = false;

    auto const addFieldWithButtons = [&widget](const char label[], uint32_t& value, uint32_t minVal, uint32_t maxVal)
    {
        bool dirty = widget.var(label, value, minVal, maxVal);
        if (widget.button("-", true) && value > 0u)
        {
            --value;
            dirty = true;
        }
        if (widget.button("+", true) && value < maxVal)
        {
            ++value;
            dirty = true;
        }
        return dirty;
    };
    if (auto pathDebuggingGroup = Gui::Group(widget, "Path debugging"))
    {
        if (mSharedCustomParams.lightPathCount != 0u)
        {
            dirty |= addFieldWithButtons("Selected path index", mSelectedSegmentID.pathIndex, 0u, mSharedCustomParams.lightPathCount - 1u);
        }
        else
        {
            widget.text("Selected path index: No path can be selected at the moment");
        }

        const uint32_t maxSegmentCount = mSharedParams.maxBounces + 1u;
        dirty |= addFieldWithButtons("Selected segment index", mSelectedSegmentID.segmentIndex, 0u, maxSegmentCount - 1u);

        dirty = mpPathDebug->renderUI(pathDebuggingGroup) || dirty;
    }

    if (auto cachingDebuggingGroup = Gui::Group(widget, "Caching debugging"))
    {
        cachingDebuggingGroup.checkbox("Enable", mEnableDebug);
        if (mEnableDebug)
        {
            mpDebugDataReadFence->syncCpu();
            std::memcpy(&mCachingDebugData, mpHostDebugData->map(Buffer::MapType::Read), sizeof(CachingDebugData));
            mpHostDebugData->unmap();
        }

        cachingDebuggingGroup.var("Selected pixel", mDebugSelectedPixel);

        if (auto previousFrameGroup = Gui::Group(cachingDebuggingGroup, "Previous frame", true))
        {
            uint depth = mCachingDebugData.previousCachingData.depthAndMaterialID >> 16;
            uint materialID = mCachingDebugData.previousCachingData.depthAndMaterialID & 0xFFFF;

            previousFrameGroup.var("Radiance", mCachingDebugData.previousAccumulatedRadiance);
            previousFrameGroup.var("Photon count", mCachingDebugData.previousPhotonCount);
            uint2 previousPixelCoords = uint2(mCachingDebugData.previousIndexToPixelCoords & 0x0000FFFF,
                                              mCachingDebugData.previousIndexToPixelCoords >> 16);
            previousFrameGroup.var("Pixel coords", previousPixelCoords);
            previousFrameGroup.tooltip(mCachingDebugData.previousIndexToPixelCoords != 0xFFFFFFFF ? "Valid" : "Invalid", true);
            previousFrameGroup.var("Position", mCachingDebugData.previousCachingData.position);
            previousFrameGroup.var("Search radius", mCachingDebugData.previousCachingData.searchRadius);
            previousFrameGroup.var("Normal", mCachingDebugData.previousCachingData.normal);
            previousFrameGroup.var("Depth", depth);
            previousFrameGroup.var("Material ID", materialID);
        }

        auto currentFrameGroup = Gui::Group(cachingDebuggingGroup, "Current frame", true);
        if (auto currentFrameGroup = Gui::Group(cachingDebuggingGroup, "Current frame", true))
        {
            uint depth = mCachingDebugData.currentCachingData.depthAndMaterialID >> 16;
            uint materialID = mCachingDebugData.currentCachingData.depthAndMaterialID & 0xFFFF;

            currentFrameGroup.text("Current frame:");
            currentFrameGroup.var("Radiance", mCachingDebugData.currentAccumulatedRadiance);
            currentFrameGroup.var("Photon count", mCachingDebugData.currentPhotonCount);
            uint2 currentPixelCoords = uint2(mCachingDebugData.currentIndexToPixelCoords & 0x0000FFFF,
                                             mCachingDebugData.currentIndexToPixelCoords >> 16);
            currentFrameGroup.var("Pixel coords", currentPixelCoords);
            currentFrameGroup.tooltip(mCachingDebugData.currentIndexToPixelCoords != 0xFFFFFFFF ? "Valid" : "Invalid", true);
            currentFrameGroup.var("Position", mCachingDebugData.currentCachingData.position);
            currentFrameGroup.var("Search radius", mCachingDebugData.currentCachingData.searchRadius);
            currentFrameGroup.var("Normal", mCachingDebugData.currentCachingData.normal);
            currentFrameGroup.var("Depth", depth);
            currentFrameGroup.var("Material ID", materialID);

            currentFrameGroup.var("Camera dir", mCachingDebugData.pathData.incomingCameraDir);
            currentFrameGroup.var("Throughput", mCachingDebugData.pathData.pathThroughput);
        }

        if (auto outputGroup = Gui::Group(cachingDebuggingGroup, "Output", true))
        {
            outputGroup.text("Output");
            outputGroup.var("Radiance", mCachingDebugData.interpolatedAccumulatedRadiance);
            outputGroup.var("Photon count", mCachingDebugData.interpolatedPhotonCount);
            outputGroup.var("Color", mCachingDebugData.outputColor);
        }

        std::ostringstream str;
        const auto printVec3 = [&str](const float3& vec) {
            str << "( " << vec.x << " " << vec.y << " " << vec.z << " )";
        };
        str << std::setw(12) << std::setprecision(9) << std::fixed;
        str << "Radiance:\n"
            << "\tPrev  : ";
        printVec3(mCachingDebugData.previousAccumulatedRadiance);
        str << "\n"
            << "\tCurr  : ";
        printVec3(mCachingDebugData.currentAccumulatedRadiance);
        str << "\n"
            << "\tInterp: ";
        printVec3(mCachingDebugData.interpolatedAccumulatedRadiance);
        str << "\n";
        cachingDebuggingGroup.text(str.str());
    }

    if (dirty) mOptionsChanged = true;
}

void ScreenSpaceCaustics::setLTStaticParams(Program* pProgram) const
{
    // Set compile-time constants on the given program.
    // TODO: It's unnecessary to set these every frame. It should be done lazily, but the book-keeping is complicated.
    Program::DefineList defines;
    defines.add("SAMPLES_PER_PIXEL", std::to_string(mSharedLightTracingParams.samplesPerPixel));
    defines.add("LIGHT_SAMPLES_PER_VERTEX", std::to_string(mSharedLightTracingParams.lightSamplesPerVertex));
    defines.add("MAX_BOUNCES", std::to_string(mSharedLightTracingParams.maxBounces));
    defines.add("MAX_NON_SPECULAR_BOUNCES", std::to_string(mSharedLightTracingParams.maxNonSpecularBounces));
    defines.add("USE_ALPHA_TEST", mSharedLightTracingParams.useAlphaTest ? "1" : "0");
    defines.add("ADJUST_SHADING_NORMALS", mSharedLightTracingParams.adjustShadingNormals ? "1" : "0");
    defines.add("FORCE_ALPHA_ONE", mSharedLightTracingParams.forceAlphaOne ? "1" : "0");
    defines.add("USE_ANALYTIC_LIGHTS", mUseAnalyticLights ? "1" : "0");
    defines.add("USE_EMISSIVE_LIGHTS", mUseEmissiveLights ? "1" : "0");
    defines.add("USE_ENV_LIGHT", mUseEnvLight ? "1" : "0");
    defines.add("USE_ENV_BACKGROUND", mpScene->useEnvBackground() ? "1" : "0");
    defines.add("USE_BRDF_SAMPLING", mSharedLightTracingParams.useBRDFSampling ? "1" : "0");
    defines.add("USE_NEE", mSharedLightTracingParams.useNEE ? "1" : "0");
    defines.add("USE_MIS", mSharedLightTracingParams.useMIS ? "1" : "0");
    defines.add("MIS_HEURISTIC", std::to_string(mSharedLightTracingParams.misHeuristic));
    defines.add("USE_RUSSIAN_ROULETTE", mSharedLightTracingParams.useRussianRoulette ? "1" : "0");
    defines.add("USE_VBUFFER", mSharedLightTracingParams.useVBuffer ? "1" : "0");
    defines.add("USE_NESTED_DIELECTRICS", mSharedLightTracingParams.useNestedDielectrics ? "1" : "0");
    defines.add("USE_LIGHTS_IN_DIELECTRIC_VOLUMES", mSharedLightTracingParams.useLightsInDielectricVolumes ? "1" : "0");
    defines.add("DISABLE_CAUSTICS", mSharedLightTracingParams.disableCaustics ? "1" : "0");

    // Defines in MaterialShading.slang.
    defines.add("_USE_LEGACY_SHADING_CODE", mSharedLightTracingParams.useLegacyBSDF ? "1" : "0");

    defines.add("GBUFFER_ADJUST_SHADING_NORMALS", mGBufferAdjustShadingNormals ? "1" : "0");

    // Defines for ray footprint.
    defines.add("RAY_FOOTPRINT_MODE", std::to_string(mSharedLightTracingParams.rayFootprintMode));
    defines.add("RAY_CONE_MODE", std::to_string(mSharedLightTracingParams.rayConeMode));
    defines.add("RAY_FOOTPRINT_USE_MATERIAL_ROUGHNESS", std::to_string(mSharedLightTracingParams.rayFootprintUseRoughness));

    defines.add("MATCH_KIM19", mMatchKim19 ? "1" : "0");
    defines.add("MAX_CAMERA_BOUNCES", std::to_string(mMaxCameraBounces));
    defines.add("MAX_LIGHT_BOUNCES", std::to_string(mMaxLightBounces));

    pProgram->addDefines(defines);
}

void ScreenSpaceCaustics::setTracerData(const RenderData& renderData)
{
    auto pBlock = mTracer.pParameterBlock;
    assert(pBlock);

    if (mpScene)
    {
        auto const materialsChanged = is_set(mpScene->getUpdates(), Scene::UpdateFlags::MaterialsChanged);
        if (materialsChanged) computeListOfSpecularMaterials();
        if (materialsChanged || is_set(mpScene->getUpdates(), Scene::UpdateFlags::MeshesMoved)) computeProjectionVolume();
    }

    // Upload parameters struct.
    pBlock["customParams"].setBlob(mSharedCustomParams);
    pBlock["params"].setBlob(mSharedParams);

    if (mSharedCustomParams.useCache) assert(mpCache);

    auto& pCurrentFrameCachingData = mPerFrameCachingData[mSelectedFrameCachingData];

    pBlock["aabbBVH"].setSrv(mSharedCustomParams.useCache ? mpCache->getAccelerationStructure() : ShaderResourceView::SharedPtr());
    pBlock["maxContributedToCollectingPoints"] = mMaxContributionToCollectingPoints;

    pBlock["pixelCoords"] = pCurrentFrameCachingData.pIndexToPixelMap;
    pBlock["cachingPointData"] = pCurrentFrameCachingData.pCachingPointData;
    pBlock["pathToCachingPointData"] = mpPathToCachingPointData;

    pBlock["statsOutput"] = pCurrentFrameCachingData.pAccumulatedStats;

    // Bind emissive light sampler.
    if (mUseEmissiveSampler)
    {
        assert(mpEmissiveSampler);
        bool success = mpEmissiveSampler->setShaderData(mPathTracing.pCommonDataBlock["emissiveSampler"]);
        if (!success) throw std::exception("Failed to bind emissive light sampler");
    }

    bool success = mpLightTracingEmissiveSampler->setShaderData(pBlock["emissiveSampler"]);
    if (!success) throw std::exception("Failed to bind emissive light sampler");
}
