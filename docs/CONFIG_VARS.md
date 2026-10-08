# Ray tracing and denoising settings in the macOS binary

**Changing them at runtime works** (2026-10-08). RED4ext.SDK's `scripts/config_var_dump.py` extracts every config
variable from the binary (1397; object address, group, name, type, default) and adds the ray tracing ones to the
address DB as verified entries (`RED4ext.SDK/docs/CONFIG_VAR_AUDIT.md`). This plugin reads and writes them by name
(`src/plugin/ConfigVars.cpp`, tracer request `cvar <group>/<name>[=<value>]`), after checking the object's name, group
and type in memory. Note that the groups below come from string adjacency and are partly wrong (for example the Apple
denoiser variables are in group `RayTracing`); the DB and `CONFIG_VAR_AUDIT.md` have the exact groups.

First measurements (`RED4ext tools/autotest/scenarios/cvartest.reds`, `scripts/cvartest_report.py`), GPU time per
frame against baselines right before and after each change, MetalFX, 779x487 render:

| Change | RT Ultra | Path tracing |
| --- | ---: | ---: |
| `RayTracing/Diffuse/EnableHalfResolutionTracing` 1 to 0 (full resolution) | +1.2 ms (+10%) | +0.7 ms (+4%) |
| `RayTracing/Reflection/EnableHalfResolutionTracing` 1 to 0 | +1.5 ms (+12%) | no change |
| `RayTracing/Debug/SkipStaticMeshes`, `RayTracing/EnableNRD` | no change (read at load time?) | no change |
| `RayTracing/Reference/RayNumber`, `BounceNumber` (default 0xDEADBEEF: preset decides) | no change | no change |

Batch experiments (`experiments/*.txt`, plugin `cvarbatch`, `scripts/cvar_report.py`, runs
`RED4ext/runs/20261008-105*-cvarbatch`, `-110*-cvarbatch`):

- **`RayTracing/DenoisingShaderPreferenceAAPL` 1 to 0 switches NRD off, and with it the denoised lighting.** Every
  REBLUR, RELAX and SIGMA dispatch and the unnamed passes around them disappear (frame traces `cvar0-exp` /
  `cvar0-base`) and nothing replaces them: the lighting NRD would output is simply missing. In motion, path tracing at
  Megabuilding H10 goes almost black except emissives (rtbench `pt-nonrd`, 2026-10-08). Not a player setting. What it
  measures: NRD and its surrounding passes cost 1.0-3.0 ms in RT Ultra and 1.7-3.7 ms in path tracing (rtbench, 5
  spots, steady windows), against ~1 ms for the verified-name NRD passes alone.
- **Valid values only.** Writing 2 to the same variable crashed the game (null dereference in render code) in both
  modes. Only write values known to be valid (the default, 0/1 for flags) until a variable's readers are checked.
- `RayTracing/EnableReferenceAAPLOptim`: the default 2 is the fastest path tracing option (0: +1.7 ms, 1: +1.0 ms,
  image changes a lot).
- No measurable effect: SHaRC bounces and downscale, multilayer resolution scale, ReSTIR GI permutation sampling, SSR
  fallback, AO ray number, `DenoisingConcurrentDispatch`.

Half resolution tracing is already the default for diffuse and reflections; the live toggles prove that writes reach
the renderer. Path tracing's cost is elsewhere (candidates: `Editor/SHARC/Bounces` 4, `Editor/SHARC/DownscaleFactor` 5,
`RayTracing/Multilayer/ResolutionScale` 1.0, the ReSTIR GI sample counts).

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

**Ini files do not change these settings** at runtime (tested 2026-10-08 with RED4ext's `CP_INI`, measured with passcost):
`[RayTracing/Reference] RayNumber = 8` in `engine/config/platform/mac/zz_cp_autotest.ini` (path tracing),
`[RayTracing/Diffuse] EnableHalfResolutionTracing` and `[Editor/Denoising/NRD] DebugSplitScreen` in
`engine/config/platform/mac/user.ini`, and `[RayTracing/Debug] SkipStaticMeshes` plus
`[RayTracing/NRD] UseReblurFor*Radiance` added to the game's own `engine/config/platform/mac/rendering.ini`
(which it does read). None changed the ray generation cost, the NRD passes or the image. Changing them needs the
engine's config variable registry at runtime (a RED4ext hook on a verified address), not a file.

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
