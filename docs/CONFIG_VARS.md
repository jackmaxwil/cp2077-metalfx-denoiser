# Ray tracing and denoising settings in the macOS binary

Config variables of Cyberpunk 2077 2.3.1 (macOS) in the ray tracing, denoising, RTXDI, ReGIR, SHaRC and path tracing
groups. Recovered from the binary: each registration function loads a group name string and then the names of its
variables, so every variable is listed under the last group string loaded before it in the same function.
Types and defaults are not recovered yet. A few entries are not variables (strings loaded by the same code, such
as `RayTracing` or `PathTracing` inside a group); treat each name as a candidate until it is read or set at runtime.

Apple-specific variables:

- `[Editor/Denoising/NRD]`: `DenoisingShaderPreferenceAAPL`, `DenoisingRayTracingShaderMaskAAPL`,
  `DenoisingPathTracingShaderMaskAAPL`, `DenoisingRtxdiShaderMaskAAPL`, `DenoisingConcurrentDispatch`.
- `[Editor/RTXDI]`: `UseAAPLOptimPass`, `UseFusedApproach`, `UseCSReusePasses`, `UseCustomDenoiser`.
- `[RayTracing]`: `EnableReferenceAAPLOptim`, `EnableReferenceSER`, `EnableNRD`, `EnableReferenceAccumulation`.

Path tracing sample budget: `[RayTracing/Reference]` `RayNumber`, `BounceNumber` (and the `...Screenshot` variants used
by photo mode).

Regenerate with `scripts/config_vars.py`.

## All groups

```
[Editor/Denoising/NRD]
  Debug, DebugSplitScreen, EnableScalingCompensation, EnableReferenceCaptureParameters, DisocclusionThreshold, MotionVectorScale, IsMotionVectorInWorldSpace, DenoisingShaderPreferenceAAPL, RayTracing, DenoisingRayTracingShaderMaskAAPL, DenoisingPathTracingShaderMaskAAPL, DenoisingRtxdiShaderMaskAAPL, DenoisingConcurrentDispatch
[Editor/Denoising/ReBLUR]
  MaxHitDistance, HitDistanceViewZScale, HitDistanceRoughnessScale, HitDistanceRoughnessExpScale
[Editor/Denoising/ReBLUR/AmbientOcclusion]
  AntiLag, MaxAccumulatedFrameNum, DenoisingRadius, AntiFirefly, ReferenceAccumulation
[Editor/Denoising/ReBLUR/Direct]
  AntilagIntensity, SensitivityToDarkness, AntilagHitDist, MaxAccumulatedFrameNum, MaxFastAccumulatedFrameNum, HistoryFixFrameNum, DiffusePrepassBlurRadius, SpecularPrepassBlurRadius, DenoisingRadius, HistoryFixStrideBetweenSamples, LobeAngleFraction, RoughnessFraction, ResponsiveAccumulationRoughnessThreshold, StabilizationStrength, HistoryFixStrength, PlaneDistanceSensitivity, HitDistanceReconstruction, AntiFirefly, ReferenceAccumulation, EnableMaterialTestForDiffuse, EnableMaterialTestForSpecular
[Editor/Denoising/ReBLUR/Indirect]
  AntilagIntensity, SensitivityToDarkness, AntilagHitDist, MaxAccumulatedFrameNum, MaxFastAccumulatedFrameNum, HistoryFixFrameNum, DiffusePrepassBlurRadius, SpecularPrepassBlurRadius, DenoisingRadius, HistoryFixStrideBetweenSamples, LobeAngleFraction, RoughnessFraction, ResponsiveAccumulationRoughnessThreshold, StabilizationStrength, HistoryFixStrength, PlaneDistanceSensitivity, HitDistanceReconstruction, AntiFirefly, ReferenceAccumulation, EnableMaterialTestForDiffuse, EnableMaterialTestForSpecular
[Editor/Denoising/ReLAX/Direct/Common]
  HistoryFixStrideBetweenSamples, HistoryFixEdgeStoppingNormalPower, HistoryFixFrameNum, HistoryClampingColorBoxSigmaScale, SpatialVarianceEstimationHistoryThreshold, AtrousIterationNum, DepthThreshold, HitDistanceReconstruction, AntiFirefly, ReprojectionTestSkippingWithoutMotion
[Editor/Denoising/ReLAX/Direct/Diffuse]
  PrepassBlurRadius, MaxAccumulatedFrameNum, MaxFastAccumulatedFrameNum, PhiLuminance, LobeAngleFraction, MinLuminanceWeight, MaterialTest
[Editor/Denoising/ReLAX/Direct/Specular]
  PrepassBlurRadius, MaxFastAccumulatedFrameNum, PhiLuminance, LobeAngleFraction, RoughnessFraction, VarianceBoost, LobeAngleSlack, MinLuminanceWeight, LuminanceEdgeStoppingRelaxation, NormalEdgeStoppingRelaxation, RoughnessEdgeStoppingRelaxation, VirtualHistoryClamping, RoughnessEdgeStopping, MaterialTest
[Editor/Denoising/ReLAX/Indirect/Common]
  HistoryFixStrideBetweenSamples, HistoryFixEdgeStoppingNormalPower, HistoryFixFrameNum, HistoryClampingColorBoxSigmaScale, SpatialVarianceEstimationHistoryThreshold, AtrousIterationNum, DepthThreshold, HitDistanceReconstruction, AntiFirefly, ReprojectionTestSkippingWithoutMotion
[Editor/Denoising/ReLAX/Indirect/Diffuse]
  PrepassBlurRadius, MaxAccumulatedFrameNum, MaxFastAccumulatedFrameNum, PhiLuminance, LobeAngleFraction, MinLuminanceWeight, MaterialTest
[Editor/Denoising/ReLAX/Indirect/Specular]
  PrepassBlurRadius, MaxAccumulatedFrameNum, MaxFastAccumulatedFrameNum, LobeAngleFraction, RoughnessFraction, VarianceBoost, LobeAngleSlack, MinLuminanceWeight, LuminanceEdgeStoppingRelaxation, NormalEdgeStoppingRelaxIation, RoughnessEdgeStoppingRelaxation, VirtualHistoryClamping, RoughnessEdgeStopping, MaterialTest
[Editor/PathTracing]
  UseScreenSpaceData, UseSSRFallback
[Editor/RTXDI]
  PTEnableDirectEmissives, PTEnableDirectSkylight, PathTracing, OverrideEnable, KeyBindingsEnable, ShadowFadeFraction, ForcedShadowLightSourceRadius, BiasCorrectionMode, EnableEmissiveTriangleLights, EnableAnalyticalLights, EnableEnvironmentLights, EnableRTXDIDenoising, EnableSeparateDenoising, EnableGlobalLight, UseCustomDenoiser, EnableGradients, EmissiveEVBias, EmissiveHeroEVBias, EmissiveAttenuationScale, EmissiveProxyLightRejectionDistance, EnableEmissiveProxyLightRejection, Debug_UpdateLightHits, Debug_DrawLightHits, Debug_DrawAllTriangleLightBBoxes, UseFusedApproach, InitialCandidatesInTemporal, UseCSReusePasses, UseAAPLOptimPass, Debug_EnableSingleEmissive, EmissiveLOD, MaxIntensity, EnableAllEmissives, EmissiveLightCount, RTXDI, AnalyticLightCount, EmissiveShadowRayOffset, NumInitialSamples, EnableLocalLightImportanceSampling, EnableApproximateTargetPDF, EmissiveDistanceThreshold, NumEnvMapSamples, SpatialSamplingRadius, SpatialNumSamples, SpatialNumDisocclusionBoostSamples, MaxHistoryLength, BoilingFilterStrength, EnableFallbackLight, PermutationSamplingMode
[Editor/ReGIR]
  Enable, UseForDI, LightSlotsCount, BuildCandidatesCount, ShadingCandidatesCount
[Editor/ReSTIRGI]
  EnableFused, EnableDeferredTracing, BiasCorrectionMode, MaxHistoryLength, MaxReservoirAge, PermutationSamplingMode, EnableFallbackSampling, SpatialSamplingRadius, SpatialNumSamples, SpatialNumDisocclusionBoostSamples, EnableBoilingFilter, BoilingFilterStrength, TargetHistoryLength, UseTemporalRGS, UseSpatialRGS
[Editor/SHARC]
  Enable, SceneScale, DownscaleFactor, Debug, Update, Resolve, Clear, IntensityScale, Step, Bounces, SerUpdate, UseRTXDI, UseRTXDIAtPrimary, UseRTXDIWithAlbedo, UsePrevFrame, UsePrevFrameBiasAllowance, HistoryReset
[RayTracing/BlasCache]
  Budget, Reserve, EvictTimeout, WorkingSetTimeout, SpeedTreeLodDistanceMultiplier
[RayTracing/Collector]
  VisibilityFrustumOffset, VisibilityCullingRadius, EnableGlobalShadowCulling, LocalShadowCullingRadius, LocalShadowCameraCutRange, LocalShadowCameraCutInflate, UseLightBoundaries, Occlusion, DepthBufferDimScale, MinNearPlane, MaxFarPlane
[RayTracing/Debug]
  NrdInputs, GlobalShadow, LocalShadow, AmbientOcclusion, DiffuseIllumination, Reflection, TransparentReflection, ReSTIRGI, HitDistance, ObjectMotion, PrimaryRays, ShaderClock, ImportanceSampling, DisableShaderOpacityMicromapSupport, RTXDILocalLightPdf, RTXDIRIS, RTXDIEnvMap, RTXDIEnvMapPdf, RayTracing, TracingRadius, TracingRadiusReflections, RayNormalOffset, RayViewOffset, SkyRadianceScale, EnableVisibilityCheck, SkipStaticMeshes, SkipDynamicMeshes, SkipClusteredProxies, SkipTransparentMeshes, SkipProxiesWithDismembermentData, ForcedLod, ForceUpdate, ClipRadius, RenderObjectType, RenderProxyType
[RayTracing/Diffuse]
  EnableHalfResolutionTracing, AdaptiveSamplingRatio
[RayTracing/DynamicInstance]
  UpdateProxyNumMax, UpdateVertexNumMax, RefitNumMax, UpdateUseHalfFloat, UpdateUseBatching, UpdateDistanceThreshold, UpdateDistanceBias, UpdateDistanceFactor, EnableSkinning, RayTracing, EnableGlobalIllumination, EmissiveClipRadius, EmissiveRangeScale, HideFPPAvatar
[RayTracing/LocalLight]
  Capacity, GridSize, BatchSize, ClipRadius, TraceLightVolumes, AmbientOcclusionRadiusNear, AmbientOcclusionRadiusFar, AmbientOcclusionTransitionNear, AmbientOcclusionTransitionFar, SkyRadianceExposureScaling, SkyRadianceExposureRatio
[RayTracing/LocalShadow]
  LightSize, ContactShadowRange
[RayTracing/Multilayer]
  ResolutionScaleEnable, ResolutionScale, ResolutionScaleNormalFactor, ResolutionScaleMicroblendFactor
[RayTracing/NRD]
  UseReblurForDirectRadiance, UseReblurForIndirectRadiance
[RayTracing/Reference]
  GIOnlyLightScale, AlbedoModulation, DiffuseGlobalScale, DiffuseSunScale, DiffuseSkyScale, DiffuseLocalLightsScale, DiffuseEmissiveScale, SpecularGlobalScale, SpecularSunScale, SpecularSkyScale, SpecularLocalLightsScale, SpecularEmissiveScale, MaxIntensity, RayNumber, BounceNumber, RayNumberScreenshot, BounceNumberScreenshot, EnableFixed, EnableRIS, EnableProbabilisticSampling, EnableScreenshotCapture
[RayTracing/ReferenceScreenshot]
  TileSize, SimpleLightSampling, AdaptiveSampling, SampleNumber
[RayTracing/Reflection]
  RoughnessOverride, RoughnessThreshold, SunAngularSize, RayTracing, SunScatteringScale, SunVisibility, EmittanceScale, EnableImportanceSampling, ImportanceSamplingTransitionMin, ImportanceSamplingTransitionMax, EnableLocalLights
[RayTracing/TLAS]
  Rotation, EnableAutomaticRotation, RotationClipRadius, EnablePriorityFeedback, RayTracing, EnableShadowOptimizations, AllowOpacityMicroMaps, InstanceFlagForceOMM2StateOnLODXAndAbove, InstanceFlagDisableOMMS, AllowInstanceFlagDisableOMMS, ForceShadowLODBiasUsage, ForceShadowLODBiasUseMax, ForceShadowLODBiasValue
```
