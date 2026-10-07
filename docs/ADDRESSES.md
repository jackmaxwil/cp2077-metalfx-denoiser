# NRD Address Discovery

> **Research notes only.** These offsets were found for game 2.21, are not in RED4ext's verified address DB, and are
> not used by the plugin. The NRD CPU entry points do not execute on macOS (`PIPELINE_TRACE_FINDINGS.md`).

## Discovered Addresses (macOS ARM64)

### NRD Memory Functions (Exported Symbols)
| Function | Address | Offset |
|----------|---------|--------|
| RayTracingCustomData::NrdAllocate | 0x100FA7B7C | 0xFA7B7C |
| RayTracingCustomData::NrdReallocate | 0x100FA7BCC | 0xFA7BCC |
| RayTracingCustomData::NrdFree | 0x100FA7C40 | 0xFA7C40 |

### REBLUR Denoiser Passes
| Function | Address | Offset |
|----------|---------|--------|
| REBLUR_Diffuse - Temporal accumulation | 0x100F5A408 | 0xF5A408 |
| REBLUR_DiffuseSpecular - Temporal accumulation | 0x100F6AFA0 | 0xF6AFA0 |

### Render Nodes
| Function | Address | Offset |
|----------|---------|--------|
| CRenderNode_RayTracingFilterOutput | 0x100FEDE44 | 0xFEDE44 |
| CRenderNode_FilterRayTracedLocalShadow | 0x100FEDE44 | 0xFEDE44 |

### Configuration
| Function | Address | Offset |
|----------|---------|--------|
| NrdInputs configuration | 0x100FEF864 | 0xFEF864 |

### RTXDI Denoiser
| Buffer | Address | Offset |
|--------|---------|--------|
| rtxdiDenoiserDiffuseAccumulation | 0x100FA3C84 | 0xFA3C84 |
| rtxdiSpecularOutputDenoised | 0x100FA3D6C | 0xFA3D6C |

### Shadow Filtering
| Function | Address | Offset |
|----------|---------|--------|
| SIGMA_Shadow filter | 0x100F7975C | 0xF7975C |

## Discovery Method

Addresses were discovered using string reference tracing:
1. Find debug string in binary (e.g., "REBLUR_Diffuse - Temporal accumulation")
2. Locate ADRP+ADD instruction sequence referencing the string
3. Walk backwards to function prologue (STP X29, X30)

## Verification

All addresses should be verified after game updates by re-running address discovery scripts.
