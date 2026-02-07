/**
 * @file MetalFXDenoiser.mm
 * @brief MetalFX Temporal Scaler wrapper implementation
 */

#import "MetalFXDenoiser.h"
#import "MetalBridge.h"
#import <os/log.h>

#include <chrono>

#import <objc/message.h>
#import <objc/runtime.h>

static os_log_t sLog = nil;

@implementation MetalFXDenoiser {
    BOOL _needsReset;
}

+ (void)initialize {
    if (self == [MetalFXDenoiser class]) {
        sLog = os_log_create("com.metalfx.denoiser", "MetalFXDenoiser");
    }
}

- (nullable instancetype)initWithDevice:(id<MTLDevice>)device
                             inputWidth:(NSUInteger)inputWidth
                            inputHeight:(NSUInteger)inputHeight
                            outputWidth:(NSUInteger)outputWidth
                           outputHeight:(NSUInteger)outputHeight
{
    return [self initWithDevice:device
                     inputWidth:inputWidth
                    inputHeight:inputHeight
                    outputWidth:outputWidth
                   outputHeight:outputHeight
               colorPixelFormat:MTLPixelFormatRGBA16Float
              motionPixelFormat:MTLPixelFormatRG16Float
               depthPixelFormat:MTLPixelFormatDepth32Float
              outputPixelFormat:MTLPixelFormatRGBA16Float];
}

- (nullable instancetype)initWithDevice:(id<MTLDevice>)device
                             inputWidth:(NSUInteger)inputWidth
                            inputHeight:(NSUInteger)inputHeight
                            outputWidth:(NSUInteger)outputWidth
                           outputHeight:(NSUInteger)outputHeight
                       colorPixelFormat:(MTLPixelFormat)colorPixelFormat
                      motionPixelFormat:(MTLPixelFormat)motionPixelFormat
                       depthPixelFormat:(MTLPixelFormat)depthPixelFormat
                      outputPixelFormat:(MTLPixelFormat)outputPixelFormat
{
    self = [super init];
    if (self) {
        _device = device;
        _inputWidth = inputWidth;
        _inputHeight = inputHeight;
        _outputWidth = outputWidth;
        _outputHeight = outputHeight;
        _needsReset = YES;

        MTLFXTemporalScalerDescriptor* desc = [[MTLFXTemporalScalerDescriptor alloc] init];
        desc.inputWidth = inputWidth;
        desc.inputHeight = inputHeight;
        desc.outputWidth = outputWidth;
        desc.outputHeight = outputHeight;

        desc.colorTextureFormat = colorPixelFormat;
        desc.depthTextureFormat = depthPixelFormat;
        desc.motionTextureFormat = motionPixelFormat;
        desc.outputTextureFormat = outputPixelFormat;

        _scaler = [desc newTemporalScalerWithDevice:device];

        if (!_scaler) {
            os_log_error(sLog, "Failed to create MTLFXTemporalScaler for %lux%lu -> %lux%lu",
                        inputWidth, inputHeight, outputWidth, outputHeight);
            return nil;
        }

        os_log_info(sLog, "Created MetalFXDenoiser: %lux%lu -> %lux%lu (formats c=%u m=%u d=%u o=%u)",
                   inputWidth, inputHeight, outputWidth, outputHeight,
                   (unsigned)colorPixelFormat, (unsigned)motionPixelFormat,
                   (unsigned)depthPixelFormat, (unsigned)outputPixelFormat);
    }
    return self;
}

- (nullable instancetype)initWithDevice:(id<MTLDevice>)device
                                  width:(NSUInteger)width
                                 height:(NSUInteger)height
{
    return [self initWithDevice:device
                     inputWidth:width
                    inputHeight:height
                    outputWidth:width
                   outputHeight:height];
}

- (void)encodeToCommandBuffer:(id<MTLCommandBuffer>)commandBuffer
                 colorTexture:(id<MTLTexture>)colorTexture
                motionTexture:(id<MTLTexture>)motionTexture
                 depthTexture:(id<MTLTexture>)depthTexture
                outputTexture:(id<MTLTexture>)outputTexture
                      jitterX:(float)jitterX
                      jitterY:(float)jitterY
                        reset:(BOOL)reset
{
    if (!_scaler) {
        os_log_error(sLog, "Cannot encode: scaler is nil");
        return;
    }
    
    // Configure inputs
    _scaler.colorTexture = colorTexture;
    _scaler.motionTexture = motionTexture;
    _scaler.depthTexture = depthTexture;
    _scaler.outputTexture = outputTexture;
    
    // Set jitter offsets (for TAA)
    _scaler.jitterOffsetX = jitterX;
    _scaler.jitterOffsetY = jitterY;
    
    // Reset temporal history if needed
    _scaler.reset = reset || _needsReset;
    _needsReset = NO;
    
    // Encode to command buffer
    [_scaler encodeToCommandBuffer:commandBuffer];
}

- (BOOL)isValid {
    return _scaler != nil;
}

- (void)resetHistory {
    _needsReset = YES;
}

- (void)setSharpness:(float)sharpness {
    if (!_scaler) {
        return;
    }
    if ([_scaler respondsToSelector:@selector(setSharpness:)]) {
        [(id)_scaler setSharpness:sharpness];
    }
}

@end

// =============================================================================
// C Bridge Implementation
// =============================================================================

#import "TemporalScalerPool.h"

extern "C" {
typedef struct BufferConverterContext BufferConverterContext;
BufferConverterContext* BufferConverter_Create(void* device);
void BufferConverter_Destroy(BufferConverterContext* ctx);
void BufferConverter_ConvertMotionVectorsEx(
    BufferConverterContext* ctx,
    void* input,
    void* output,
    float width,
    float height,
    bool flipY,
    void* commandBuffer);
}

struct MetalFXContext {
    id<MTLDevice> device;
    TemporalScalerPool* pool;
    bool featureEnabled[MetalFXFeature_Count];
    MetalFXMetrics metrics[MetalFXFeature_Count];

    BufferConverterContext* motionConverter;
    id<MTLTexture> convertedMotion;
    uint32_t convertedMotionW;
    uint32_t convertedMotionH;
    MetalFXMotionVectorMode motionMode;
    bool motionFlipY;
};

MetalFXContext* MetalFX_CreateContext(MTLDeviceRef deviceRef) {
    @autoreleasepool {
        id<MTLDevice> device = (__bridge id<MTLDevice>)deviceRef;
        
        if (!device) {
            device = MTLCreateSystemDefaultDevice();
        }
        
        if (!device) {
            os_log_error(sLog, "Failed to get Metal device");
            return nullptr;
        }
        
        // Check MetalFX support
        if (![MTLFXTemporalScalerDescriptor supportsDevice:device]) {
            os_log_error(sLog, "MetalFX Temporal Scaler not supported on this device");
            return nullptr;
        }
        
        MetalFXContext* ctx = new MetalFXContext();
        ctx->device = device;
        ctx->pool = [[TemporalScalerPool alloc] initWithDevice:device];
        ctx->motionConverter = nullptr;
        ctx->convertedMotion = nil;
        ctx->convertedMotionW = 0;
        ctx->convertedMotionH = 0;
        ctx->motionMode = MetalFXMotionVectors_Passthrough;
        ctx->motionFlipY = false;
        
        // Enable all features by default
        for (int i = 0; i < MetalFXFeature_Count; i++) {
            ctx->featureEnabled[i] = true;
            ctx->metrics[i] = {0, 0};
        }
        
        os_log_info(sLog, "Created MetalFX context with device: %s",
                   device.name.UTF8String);
        
        return ctx;
    }
}

void MetalFX_DestroyContext(MetalFXContext* ctx) {
    if (ctx) {
        @autoreleasepool {
            if (ctx->motionConverter) {
                BufferConverter_Destroy(ctx->motionConverter);
                ctx->motionConverter = nullptr;
            }
            ctx->convertedMotion = nil;
            ctx->pool = nil;
            ctx->device = nil;
        }
        delete ctx;
    }
}

bool MetalFX_IsSupported(void) {
    @autoreleasepool {
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        if (!device) return false;
        return [MTLFXTemporalScalerDescriptor supportsDevice:device];
    }
}

bool MetalFX_ConfigureScaler(
    MetalFXContext* ctx,
    MetalFXFeature feature,
    uint32_t width,
    uint32_t height,
    MetalFXQuality quality)
{
    if (!ctx || !ctx->pool) return false;
    
    @autoreleasepool {
        return [ctx->pool configureScalerForFeature:feature
                                              width:width
                                             height:height
                                            quality:quality];
    }
}

void MetalFX_SetFeatureEnabled(MetalFXContext* ctx, MetalFXFeature feature, bool enabled) {
    if (!ctx || feature >= MetalFXFeature_Count) return;
    ctx->featureEnabled[feature] = enabled;
}

bool MetalFX_IsFeatureEnabled(MetalFXContext* ctx, MetalFXFeature feature) {
    if (!ctx || feature >= MetalFXFeature_Count) return false;
    return ctx->featureEnabled[feature];
}

bool MetalFX_Denoise(
    MetalFXContext* ctx,
    MetalFXFeature feature,
    MTLCommandBufferRef cmdBufferRef,
    const MetalFXDenoiseParams* params)
{
    if (!ctx || !ctx->pool || !params) return false;
    if (feature >= MetalFXFeature_Count) return false;
    if (!ctx->featureEnabled[feature]) return false;
    
    @autoreleasepool {
        auto start = std::chrono::high_resolution_clock::now();

        id<MTLCommandBuffer> cmdBuffer = (__bridge id<MTLCommandBuffer>)cmdBufferRef;
        id<MTLTexture> color = (__bridge id<MTLTexture>)params->colorTexture;
        id<MTLTexture> motion = (__bridge id<MTLTexture>)params->motionVectors;
        id<MTLTexture> depth = (__bridge id<MTLTexture>)params->depthTexture;
        id<MTLTexture> output = (__bridge id<MTLTexture>)params->outputTexture;

        if (ctx->motionMode == MetalFXMotionVectors_NDCToPixels && motion) {
            if (!ctx->motionConverter) {
                ctx->motionConverter = BufferConverter_Create((__bridge void*)ctx->device);
            }

            if (ctx->motionConverter) {
                const uint32_t w = (uint32_t)motion.width;
                const uint32_t h = (uint32_t)motion.height;
                if (!ctx->convertedMotion || ctx->convertedMotionW != w || ctx->convertedMotionH != h) {
                    MTLTextureDescriptor* td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRG16Float
                                                                                                  width:w
                                                                                                 height:h
                                                                                              mipmapped:NO];
                    td.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
                    td.storageMode = MTLStorageModePrivate;
                    ctx->convertedMotion = [ctx->device newTextureWithDescriptor:td];
                    ctx->convertedMotionW = w;
                    ctx->convertedMotionH = h;
                }

                if (ctx->convertedMotion) {
                    BufferConverter_ConvertMotionVectorsEx(
                        ctx->motionConverter,
                        (__bridge void*)motion,
                        (__bridge void*)ctx->convertedMotion,
                        (float)w,
                        (float)h,
                        ctx->motionFlipY,
                        (__bridge void*)cmdBuffer);
                    motion = ctx->convertedMotion;
                }
            }
        }

        const bool ok = [ctx->pool denoiseFeature:feature
                           commandBuffer:cmdBuffer
                            colorTexture:color
                           motionTexture:motion
                            depthTexture:depth
                           outputTexture:output
                                 jitterX:params->jitterX
                                 jitterY:params->jitterY
                                   reset:params->reset];

        // Prefer GPU timestamps if available (captured on completion).
        if ([cmdBuffer respondsToSelector:@selector(addCompletedHandler:)]) {
            MetalFXContext* ctxRaw = ctx;

            [cmdBuffer addCompletedHandler:^(id<MTLCommandBuffer> _Nonnull cb) {
                if (!ctxRaw) return;

                auto getDoubleIfExists = ^double(SEL sel, bool* ok) {
                    if (ok) *ok = false;
                    if (![cb respondsToSelector:sel]) return 0.0;
                    double (*msg)(id, SEL) = (double (*)(id, SEL))objc_msgSend;
                    const double v = msg((id)cb, sel);
                    if (ok) *ok = true;
                    return v;
                };

                bool okStart = false;
                bool okEnd = false;

                // Try common selector spellings across SDKs.
                const double startT = getDoubleIfExists(sel_registerName("gpuStartTime"), &okStart);
                const double endT = getDoubleIfExists(sel_registerName("gpuEndTime"), &okEnd);

                double s2 = startT;
                double e2 = endT;

                if (!okStart) s2 = getDoubleIfExists(sel_registerName("GPUStartTime"), &okStart);
                if (!okEnd) e2 = getDoubleIfExists(sel_registerName("GPUEndTime"), &okEnd);

                if (okStart && okEnd && e2 > s2) {
                    ctxRaw->metrics[feature].gpuTimeMs = (e2 - s2) * 1000.0;
                }
            }];
        }

        // CPU-side encode cost (fallback if GPU timestamps aren't available yet).
        auto end = std::chrono::high_resolution_clock::now();
        double ms = std::chrono::duration<double, std::milli>(end - start).count();
        if (ctx->metrics[feature].gpuTimeMs == 0.0) {
            ctx->metrics[feature].gpuTimeMs = ms;
        }
        ctx->metrics[feature].frameIndex++;

        return ok;
    }
}

void MetalFX_SetMotionVectorMode(MetalFXContext* ctx, MetalFXMotionVectorMode mode, bool flipY) {
    if (!ctx) return;
    ctx->motionMode = mode;
    ctx->motionFlipY = flipY;
}

MTLDeviceRef MetalFX_GetDevice(MetalFXContext* ctx) {
    if (!ctx) return nullptr;
    return (__bridge MTLDeviceRef)ctx->device;
}

void MetalFX_GetMetrics(MetalFXContext* ctx, MetalFXFeature feature, MetalFXMetrics* metrics) {
    if (!ctx || !metrics || feature >= MetalFXFeature_Count) return;
    *metrics = ctx->metrics[feature];
}

void MetalFX_ResetMetrics(MetalFXContext* ctx) {
    if (!ctx) return;
    for (int i = 0; i < MetalFXFeature_Count; i++) {
        ctx->metrics[i] = {0, 0};
    }
}
