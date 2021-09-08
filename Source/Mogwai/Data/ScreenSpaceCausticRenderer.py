import enum

loadRenderPassLibrary("AccumulatePass.dll")
loadRenderPassLibrary("DebugPasses.dll")
loadRenderPassLibrary("ErrorMeasurePass.dll")
loadRenderPassLibrary("GBuffer.dll")
loadRenderPassLibrary("MegakernelPathTracer.dll")
loadRenderPassLibrary("OptixDenoiser.dll")
loadRenderPassLibrary("PixelInspectorPass.dll")
loadRenderPassLibrary("ScreenSpaceCaustics.dll")
loadRenderPassLibrary("SVGFPass.dll")
loadRenderPassLibrary("ToneMapper.dll")
loadRenderPassLibrary("Utils.dll")

class MyFilter(enum.Enum):
    Accumulation = 1
    SVGF         = 2
    OptiX        = 3

maxPathLength = 6
maxBounceCount = maxPathLength - 1
maxPTBounceCount = maxBounceCount - 1 # The initial bounce is handled by the G-buffer.
assert maxPTBounceCount >= 0, "maxPTBounceCount should be positive."

commonPTConfig = PathTracerParams(useVBuffer=0, maxBounces = maxPTBounceCount, maxNonSpecularBounces = maxPTBounceCount)
ssctConfig = ScreenSpaceCausticsParams(ignoreProjectionVolume = True, usePhotonsForAll = False,
                                        lightPathCount = 1024 * 1024, useCache = True)
cachingConfig = CachingViaBVHOptions(allowRefit = False, useTiling = True)
screenSpaceCTConfig = {
    'mSharedParams': commonPTConfig,
    'mSharedCustomParams': ssctConfig,
    'mSearchRadius': 0.001,
    'mDisableTemporalReuse': False,
    'mCachingOptions': cachingConfig,
    'mSeparateAABBStorage': True,
    'mLateBSDFApplication': False
}
gbufferConfig = {
    'forceCullMode': True,
    'cull': CullMode.CullNone,
    'samplePattern': SamplePattern.Center,
    'sampleCount': 16
}
megakernelPTConfig = {
    'mSharedParams': commonPTConfig,
    'mMatchKim19': False
}
splitScreenConfig = {
    'showTextLabels': True,
    'leftLabel': 'Kim19',
    'rightLabel': 'Path tracer'
}

errorMeasureConfig = {
    'kSelectedOutputId': 0
}

sscrCompositionConfig = {
    'mode': CompositeMode.Add,
    'scaleA': 1.0,
    'scaleB': 1.0
}
svgfConfig = {
    'Iterations': 4,
    'FeedbackTap': 2,
    'PhiColor': 1.0,
    'PhiNormal': 128.0,
    'Alpha': 0.3,
    'MomentsAlpha': 0.2
}
optixConfig = {
    'enabled': True
}

def getSSCRGraph(myFilter, lateFiltering, enableDebugTools):
    if myFilter == MyFilter.SVGF:
        filterStr = 'SVGF'
    elif myFilter == MyFilter.OptiX:
        filterStr = 'OptiX'
    else:
        filterStr = 'Accum'
    g = RenderGraph("Screen-space caustic rendering [{}{}]{}".format('Late ' if lateFiltering else '', filterStr,
                                                                   " [Debug]" if enableDebugTools else ""))

    ###########################################################################
    # Passes
    ###########################################################################

    # Common passes
    g.addPass(createPass("GBufferRaster", gbufferConfig), "GBuffer")
    #g.addPass(createPass("GBufferRT", gbufferConfig), "GBuffer")

    # SSCR passes
    g.addPass(createPass("ScreenSpaceCaustics", screenSpaceCTConfig), "ScreenSpaceCaustics")
    if myFilter == MyFilter.SVGF:
        g.addPass(createPass("SVGFPass", svgfConfig), "SSCR_SVGFPass")
    elif myFilter == MyFilter.OptiX:
        g.addPass(createPass("OptixDenoiser", optixConfig), "SSCR_OptixPass")
    else:
        g.addPass(createPass("AccumulatePass"), "SSCR_Accumulation")
    g.addPass(createPass("ToneMapper"), "SSCR_ToneMapping")

    # Reference passes
    if enableDebugTools:
        g.addPass(createPass("MegakernelPathTracer", megakernelPTConfig), "MPT_MegakernelPathTracer")
        g.addPass(createPass("AccumulatePass"), "MPT_Accumulation")
        g.addPass(createPass("ToneMapper"), "MPT_ToneMapping")

    # Debug passes
    if enableDebugTools:
        g.addPass(createPass("ColorMapPass"), "SSCR_PhotonAccumulationMap")
        g.addPass(createPass("ColorMapPass"), "SSCR_TraversedAABBCountVis")
        g.addPass(createPass("ColorMapPass"), "SSCR_SearchRadius")
        g.addPass(createPass("InvalidPixelDetectionPass"), "SSCR_InvalidPixelDetection")
        g.addPass(createPass("PixelInspectorPass"), "SSCR_PixelInspector")

        g.addPass(createPass("PixelInspectorPass"), "MPT_PixelInspector")

        g.addPass(createPass("ErrorMeasurePass", errorMeasureConfig), "ErrorMeasure")
        g.addPass(createPass("SplitScreenPass", splitScreenConfig), "SplitScreen")
        g.addPass(createPass("ToneMapper"), "ToneMapping")

    ###########################################################################
    # Edges
    ###########################################################################

    g.addEdge("GBuffer.vbuffer", "ScreenSpaceCaustics.vbuffer")
    g.addEdge("GBuffer.posW", "ScreenSpaceCaustics.posW")
    g.addEdge("GBuffer.normW", "ScreenSpaceCaustics.normalW")
    g.addEdge("GBuffer.tangentW", "ScreenSpaceCaustics.tangentW")
    g.addEdge("GBuffer.faceNormalW", "ScreenSpaceCaustics.faceNormalW")
    g.addEdge("GBuffer.viewW", "ScreenSpaceCaustics.viewW")
    g.addEdge("GBuffer.diffuseOpacity", "ScreenSpaceCaustics.mtlDiffOpacity")
    g.addEdge("GBuffer.specRough", "ScreenSpaceCaustics.mtlSpecRough")
    g.addEdge("GBuffer.emissive", "ScreenSpaceCaustics.mtlEmissive")
    g.addEdge("GBuffer.matlExtra", "ScreenSpaceCaustics.mtlParams")
    if myFilter == MyFilter.SVGF:
        g.addEdge("ScreenSpaceCaustics.albedo", "SSCR_SVGFPass.Albedo")
        g.addEdge("GBuffer.emissive", "SSCR_SVGFPass.Emission")
        g.addEdge("GBuffer.posW", "SSCR_SVGFPass.WorldPosition")
        g.addEdge("GBuffer.normW", "SSCR_SVGFPass.WorldNormal")
        g.addEdge("GBuffer.pnFwidth", "SSCR_SVGFPass.PositionNormalFwidth")
        g.addEdge("GBuffer.linearZ", "SSCR_SVGFPass.LinearZ")
        g.addEdge("GBuffer.mvec", "SSCR_SVGFPass.MotionVec")
        if lateFiltering:
            g.addEdge("ScreenSpaceCaustics.color", "SSCR_ToneMapping.src")
            g.addEdge("SSCR_ToneMapping.dst", "SSCR_SVGFPass.Color")
        else:
            g.addEdge("ScreenSpaceCaustics.color", "SSCR_SVGFPass.Color")
            g.addEdge("SSCR_SVGFPass.Filtered image", "SSCR_ToneMapping.src")
    elif myFilter == MyFilter.OptiX:
        g.addEdge("GBuffer.diffuseOpacity", "SSCR_OptixPass.albedo")
        g.addEdge("GBuffer.normW", "SSCR_OptixPass.normal")
        g.addEdge("GBuffer.mvec", "SSCR_OptixPass.mvec")
        if lateFiltering:
            g.addEdge("ScreenSpaceCaustics.color", "SSCR_ToneMapping.src")
            g.addEdge("SSCR_ToneMapping.dst", "SSCR_OptixPass.color")
        else:
            g.addEdge("ScreenSpaceCaustics.color", "SSCR_OptixPass.color")
            g.addEdge("SSCR_OptixPass.output", "SSCR_ToneMapping.src")
    else:
        if lateFiltering:
            g.addEdge("ScreenSpaceCaustics.color", "SSCR_ToneMapping.src")
            g.addEdge("SSCR_ToneMapping.dst", "SSCR_Accumulation.input")
        else:
            g.addEdge("ScreenSpaceCaustics.color", "SSCR_Accumulation.input")
            g.addEdge("SSCR_Accumulation.output", "SSCR_ToneMapping.src")

    if enableDebugTools:
        g.addEdge("GBuffer.vbuffer", "MPT_MegakernelPathTracer.vbuffer")
        g.addEdge("GBuffer.posW", "MPT_MegakernelPathTracer.posW")
        g.addEdge("GBuffer.normW", "MPT_MegakernelPathTracer.normalW")
        g.addEdge("GBuffer.tangentW", "MPT_MegakernelPathTracer.tangentW")
        g.addEdge("GBuffer.faceNormalW", "MPT_MegakernelPathTracer.faceNormalW")
        g.addEdge("GBuffer.viewW", "MPT_MegakernelPathTracer.viewW")
        g.addEdge("GBuffer.diffuseOpacity", "MPT_MegakernelPathTracer.mtlDiffOpacity")
        g.addEdge("GBuffer.specRough", "MPT_MegakernelPathTracer.mtlSpecRough")
        g.addEdge("GBuffer.emissive", "MPT_MegakernelPathTracer.mtlEmissive")
        g.addEdge("GBuffer.matlExtra", "MPT_MegakernelPathTracer.mtlParams")
        g.addEdge("MPT_MegakernelPathTracer.color", "MPT_Accumulation.input")
        g.addEdge("MPT_Accumulation.output", "MPT_ToneMapping.src")

        if myFilter == MyFilter.SVGF:
            g.addEdge("SSCR_SVGFPass.Filtered image", "ErrorMeasure.Source")
        elif myFilter == MyFilter.OptiX:
            g.addEdge("SSCR_OptixPass.output", "ErrorMeasure.Source")
        else:
            g.addEdge("SSCR_Accumulation.output", "ErrorMeasure.Source")
        g.addEdge("MPT_Accumulation.output", "ErrorMeasure.Reference")
        g.addEdge("GBuffer.posW", "ErrorMeasure.WorldPosition")
        g.addEdge("ErrorMeasure.Output", "ToneMapping.src")

        g.addEdge("SSCR_ToneMapping.dst", "SplitScreen.leftInput")
        g.addEdge("MPT_ToneMapping.dst", "SplitScreen.rightInput")

        g.addEdge("ScreenSpaceCaustics.color", "SSCR_InvalidPixelDetection.src")
        g.addEdge("ScreenSpaceCaustics", "SSCR_PixelInspector")
        g.addEdge("GBuffer.posW", "SSCR_PixelInspector.posW")
        g.addEdge("GBuffer.normW", "SSCR_PixelInspector.normW")
        g.addEdge("GBuffer.faceNormalW", "SSCR_PixelInspector.faceNormalW")
        g.addEdge("GBuffer.texC", "SSCR_PixelInspector.texC")
        g.addEdge("GBuffer.diffuseOpacity", "SSCR_PixelInspector.diffuseOpacity")
        g.addEdge("GBuffer.specRough", "SSCR_PixelInspector.specRough")
        g.addEdge("GBuffer.emissive", "SSCR_PixelInspector.emissive")
        g.addEdge("GBuffer.matlExtra", "SSCR_PixelInspector.matlExtra")
        g.addEdge("GBuffer.vbuffer", "SSCR_PixelInspector.visBuffer")
        if myFilter != MyFilter.SVGF: # SVGF uses RGBA16Float whereas PixelInspector expects RGBA32Float
            g.addEdge("SSCR_Accumulation.output", "SSCR_PixelInspector.linColor")
        g.addEdge("SSCR_ToneMapping.dst", "SSCR_PixelInspector.outColor")
        g.addEdge("ScreenSpaceCaustics", "SSCR_PhotonAccumulationMap")
        g.addEdge("ScreenSpaceCaustics.count", "SSCR_PhotonAccumulationMap.input")
        g.addEdge("ScreenSpaceCaustics", "SSCR_TraversedAABBCountVis")
        g.addEdge("ScreenSpaceCaustics.traversedAABBCount", "SSCR_TraversedAABBCountVis.input")
        g.addEdge("ScreenSpaceCaustics", "SSCR_SearchRadius")
        g.addEdge("ScreenSpaceCaustics.searchRadius", "SSCR_SearchRadius.input")

        g.addEdge("MPT_MegakernelPathTracer", "MPT_PixelInspector")
        g.addEdge("GBuffer.posW", "MPT_PixelInspector.posW")
        g.addEdge("GBuffer.normW", "MPT_PixelInspector.normW")
        g.addEdge("GBuffer.faceNormalW", "MPT_PixelInspector.faceNormalW")
        g.addEdge("GBuffer.texC", "MPT_PixelInspector.texC")
        g.addEdge("GBuffer.diffuseOpacity", "MPT_PixelInspector.diffuseOpacity")
        g.addEdge("GBuffer.specRough", "MPT_PixelInspector.specRough")
        g.addEdge("GBuffer.emissive", "MPT_PixelInspector.emissive")
        g.addEdge("GBuffer.matlExtra", "MPT_PixelInspector.matlExtra")
        g.addEdge("MPT_Accumulation.output", "MPT_PixelInspector.linColor")
        g.addEdge("MPT_ToneMapping.dst", "MPT_PixelInspector.outColor")

    ###########################################################################
    # Outputs
    ###########################################################################

    if enableDebugTools:
        g.markOutput("ToneMapping.dst")
    if not lateFiltering:
        g.markOutput("SSCR_ToneMapping.dst")
    else:
        if myFilter == MyFilter.SVGF:
            g.markOutput("SSCR_SVGFPass.Filtered image")
        elif myFilter == MyFilter.OptiX:
            g.markOutput("SSCR_OptixPass.output")
        else:
            g.markOutput("SSCR_Accumulation.output")
    if enableDebugTools:
        g.markOutput("SplitScreen.output")
    g.markOutput("ScreenSpaceCaustics.color")
    if not lateFiltering:
        if myFilter == MyFilter.SVGF:
            g.markOutput("SSCR_SVGFPass.Filtered image")
        elif myFilter == MyFilter.OptiX:
            g.markOutput("SSCR_OptixPass.output")
        else:
            g.markOutput("SSCR_Accumulation.output")
    else:
        g.markOutput("SSCR_ToneMapping.dst")
    if enableDebugTools:
        g.markOutput("ScreenSpaceCaustics.debug_visualisation")
        g.markOutput("ScreenSpaceCaustics.paths")
        g.markOutput("SSCR_PhotonAccumulationMap.output")
        g.markOutput("SSCR_TraversedAABBCountVis.output")
        g.markOutput("SSCR_SearchRadius.output")

    return g


def getPTGraph(myFilter, lateFiltering):
    if myFilter == MyFilter.SVGF:
        filterStr = 'SVGF'
    elif myFilter == MyFilter.OptiX:
        filterStr = 'OptiX'
    else:
        filterStr = 'Accum'
    g = RenderGraph("Path tracing [{}{}]".format('Late ' if lateFiltering else '', filterStr))

    ###########################################################################
    # Passes
    ###########################################################################
    # Common passes
    g.addPass(createPass("GBufferRaster", gbufferConfig), "GBuffer")
    #g.addPass(createPass("GBufferRT", gbufferConfig), "GBuffer")

    # SSCR passes
    g.addPass(createPass("MegakernelPathTracer", megakernelPTConfig), "PathTracer")
    if myFilter == MyFilter.SVGF:
        g.addPass(createPass("SVGFPass", svgfConfig), "SVGFPass")
    elif myFilter == MyFilter.OptiX:
        g.addPass(createPass("OptixDenoiser", optixConfig), "OptixPass")
    else:
        g.addPass(createPass("AccumulatePass"), "Accumulation")
    g.addPass(createPass("ToneMapper"), "ToneMapping")

    ###########################################################################
    # Edges
    ###########################################################################
    g.addEdge("GBuffer.vbuffer", "PathTracer.vbuffer")
    g.addEdge("GBuffer.posW", "PathTracer.posW")
    g.addEdge("GBuffer.normW", "PathTracer.normalW")
    g.addEdge("GBuffer.tangentW", "PathTracer.tangentW")
    g.addEdge("GBuffer.faceNormalW", "PathTracer.faceNormalW")
    g.addEdge("GBuffer.viewW", "PathTracer.viewW")
    g.addEdge("GBuffer.diffuseOpacity", "PathTracer.mtlDiffOpacity")
    g.addEdge("GBuffer.specRough", "PathTracer.mtlSpecRough")
    g.addEdge("GBuffer.emissive", "PathTracer.mtlEmissive")
    g.addEdge("GBuffer.matlExtra", "PathTracer.mtlParams")
    if myFilter == MyFilter.SVGF:
        g.addEdge("PathTracer.albedo", "SVGFPass.Albedo")
        g.addEdge("GBuffer.emissive", "SVGFPass.Emission")
        g.addEdge("GBuffer.posW", "SVGFPass.WorldPosition")
        g.addEdge("GBuffer.normW", "SVGFPass.WorldNormal")
        g.addEdge("GBuffer.pnFwidth", "SVGFPass.PositionNormalFwidth")
        g.addEdge("GBuffer.linearZ", "SVGFPass.LinearZ")
        g.addEdge("GBuffer.mvec", "SVGFPass.MotionVec")
        if lateFiltering:
            g.addEdge("PathTracer.color", "ToneMapping.src")
            g.addEdge("ToneMapping.dst", "SVGFPass.Color")
        else:
            g.addEdge("PathTracer.color", "SVGFPass.Color")
            g.addEdge("SVGFPass.Filtered image", "ToneMapping.src")
    elif myFilter == MyFilter.OptiX:
        g.addEdge("GBuffer.diffuseOpacity", "OptixPass.albedo")
        g.addEdge("GBuffer.normW", "OptixPass.normal")
        g.addEdge("GBuffer.mvec", "OptixPass.mvec")
        if lateFiltering:
            g.addEdge("PathTracer.color", "ToneMapping.src")
            g.addEdge("ToneMapping.dst", "OptixPass.color")
        else:
            g.addEdge("PathTracer.color", "OptixPass.color")
            g.addEdge("OptixPass.output", "ToneMapping.src")
    else:
        if lateFiltering:
            g.addEdge("PathTracer.color", "ToneMapping.src")
            g.addEdge("ToneMapping.dst", "Accumulation.input")
        else:
            g.addEdge("PathTracer.color", "Accumulation.input")
            g.addEdge("Accumulation.output", "ToneMapping.src")

    ###########################################################################
    # Outputs
    ###########################################################################
    if not lateFiltering:
        g.markOutput("ToneMapping.dst")
    else:
        if myFilter == MyFilter.SVGF:
            g.markOutput("SVGFPass.Filtered image")
        elif myFilter == MyFilter.OptiX:
            g.markOutput("OptixPass.output")
        else:
            g.markOutput("Accumulation.output")

    g.markOutput("PathTracer.color")

    if not lateFiltering:
        if myFilter == MyFilter.SVGF:
            g.markOutput("SVGFPass.Filtered image")
        elif myFilter == MyFilter.OptiX:
            g.markOutput("OptixPass.output")
        else:
            g.markOutput("Accumulation.output")
    else:
        g.markOutput("ToneMapping.dst")

    return g


# Using Late SVGF
try: m.addGraph(getSSCRGraph(MyFilter.SVGF, True, False))
except NameError: None
# Using accumulation
try: m.addGraph(getSSCRGraph(MyFilter.Accumulation, False, False))
except NameError: None
# Using PT
try: m.addGraph(getPTGraph(MyFilter.Accumulation, False))
except NameError: None
# Debug
try: m.addGraph(getSSCRGraph(MyFilter.Accumulation, False, True))
except NameError: None
## Using Late OptiX
#try: m.addGraph(getSSCRGraph(MyFilter.OptiX, True, False))
#except NameError: None
## Using Early SVGF
#try: m.addGraph(getSSCRGraph(MyFilter.SVGF, False, False))
#except NameError: None
## Using Early OptiX
#try: m.addGraph(getSSCRGraph(MyFilter.OptiX, False, False))
#except NameError: None

m.clock.stop()
