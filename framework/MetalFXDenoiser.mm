/**
 * @file MetalFXDenoiser.mm
 * @brief MetalFX Temporal Scaler wrapper implementation
 */

#import "MetalFXDenoiser.h"
#import "MetalBridge.h"
#import <os/log.h>

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
    self = [super init];
    if (self) {
        _device = device;
        _inputWidth = inputWidth;
        _inputHeight = inputHeight;
        _outputWidth = outputWidth;
        _outputHeight = outputHeight;
        _needsReset = YES;
        
        // Create temporal scaler descriptor
        MTLFXTemporalScalerDescriptor* desc = [[MTLFXTemporalScalerDescriptor alloc] init];
        desc.inputWidth = inputWidth;
        desc.inputHeight = inputHeight;
        desc.outputWidth = outputWidth;
        desc.outputHeight = outputHeight;
        
        // Configure texture formats
        // These match typical RT buffer formats
        desc.colorTextureFormat = MTLPixelFormatRGBA16Float;
        desc.depthTextureFormat = MTLPixelFormatDepth32Float;
        desc.motionTextureFormat = MTLPixelFormatRG16Float;
        desc.outputTextureFormat = MTLPixelFormatRGBA16Float;
        
        // Auto-generate reactive mask if needed
        // desc.isAutoExposureEnabled = NO; // Not available on all macOS versions
        
        // Create the scaler
        _scaler = [desc newTemporalScalerWithDevice:device];
        
        if (!_scaler) {
            os_log_error(sLog, "Failed to create MTLFXTemporalScaler for %lux%lu -> %lux%lu",
                        inputWidth, inputHeight, outputWidth, outputHeight);
            return nil;
        }
        
        os_log_info(sLog, "Created MetalFXDenoiser: %lux%lu -> %lux%lu",
                   inputWidth, inputHeight, outputWidth, outputHeight);
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

@end

// =============================================================================
// C Bridge Implementation
// =============================================================================

#import "TemporalScalerPool.h"

struct MetalFXContext {
    id<MTLDevice> device;
    TemporalScalerPool* pool;
    bool featureEnabled[MetalFXFeature_Count];
    MetalFXMetrics metrics[MetalFXFeature_Count];
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
        id<MTLCommandBuffer> cmdBuffer = (__bridge id<MTLCommandBuffer>)cmdBufferRef;
        id<MTLTexture> color = (__bridge id<MTLTexture>)params->colorTexture;
        id<MTLTexture> motion = (__bridge id<MTLTexture>)params->motionVectors;
        id<MTLTexture> depth = (__bridge id<MTLTexture>)params->depthTexture;
        id<MTLTexture> output = (__bridge id<MTLTexture>)params->outputTexture;
        
        return [ctx->pool denoiseFeature:feature
                           commandBuffer:cmdBuffer
                            colorTexture:color
                           motionTexture:motion
                            depthTexture:depth
                           outputTexture:output
                                 jitterX:params->jitterX
                                 jitterY:params->jitterY
                                   reset:params->reset];
    }
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
