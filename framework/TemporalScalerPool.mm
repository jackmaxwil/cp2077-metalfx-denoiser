/**
 * @file TemporalScalerPool.mm
 * @brief Temporal scaler pool implementation
 */

#import "TemporalScalerPool.h"
#import "MetalFXDenoiser.h"
#import <os/log.h>

#include <cstring>

static os_log_t sLog = nil;

@implementation TemporalScalerPool {
    NSMutableDictionary<NSNumber*, MetalFXDenoiser*>* _scalers;
    NSMutableDictionary<NSNumber*, NSValue*>* _configurations;
}

typedef struct {
    NSUInteger width;
    NSUInteger height;
    MetalFXQuality quality;
    MTLPixelFormat colorFormat;
    MTLPixelFormat motionFormat;
    MTLPixelFormat depthFormat;
    MTLPixelFormat outputFormat;
} FeatureScalerConfig;

static float SharpnessForQuality(MetalFXQuality quality) {
    switch (quality) {
        case MetalFXQuality_Performance: return 0.0f;
        case MetalFXQuality_Balanced: return 0.25f;
        case MetalFXQuality_Quality: return 0.5f;
        default: return 0.5f;
    }
}

+ (void)initialize {
    if (self == [TemporalScalerPool class]) {
        sLog = os_log_create("com.metalfx.denoiser", "TemporalScalerPool");
    }
}

- (instancetype)initWithDevice:(id<MTLDevice>)device {
    self = [super init];
    if (self) {
        _device = device;
        _scalers = [NSMutableDictionary new];
        _configurations = [NSMutableDictionary new];
    }
    return self;
}

- (BOOL)configureScalerForFeature:(MetalFXFeature)feature
                            width:(NSUInteger)width
                           height:(NSUInteger)height
                          quality:(MetalFXQuality)quality
{
    NSNumber* key = @(feature);

    FeatureScalerConfig wanted = {width, height, quality, MTLPixelFormatInvalid, MTLPixelFormatInvalid, MTLPixelFormatInvalid, MTLPixelFormatInvalid};
    NSValue* existingCfgValue = _configurations[key];
    FeatureScalerConfig existingCfg = {0};
    if (existingCfgValue && strcmp(existingCfgValue.objCType, @encode(FeatureScalerConfig)) == 0) {
        [existingCfgValue getValue:&existingCfg];
    }
    
    // Check if existing scaler matches configuration
    MetalFXDenoiser* existing = _scalers[key];
    if (existing && existing.inputWidth == width && existing.inputHeight == height &&
        existingCfgValue && existingCfg.quality == quality) {
        os_log_debug(sLog, "Reusing existing scaler for %s",
                    [TemporalScalerPool nameForFeature:feature].UTF8String);
        return YES;
    }
    
    // Create new scaler
    MetalFXDenoiser* scaler = [[MetalFXDenoiser alloc] initWithDevice:_device
                                                               width:width
                                                              height:height];
    
    if (!scaler || ![scaler isValid]) {
        os_log_error(sLog, "Failed to create scaler for %s at %lux%lu",
                    [TemporalScalerPool nameForFeature:feature].UTF8String,
                    width, height);
        return NO;
    }
    
    _scalers[key] = scaler;
    _configurations[key] = [NSValue valueWithBytes:&wanted objCType:@encode(FeatureScalerConfig)];

    // Apply a simple quality knob via sharpness (best-effort; depends on MetalFX implementation).
    [scaler setSharpness:SharpnessForQuality(quality)];
    
    os_log_info(sLog, "Configured scaler for %s: %lux%lu, quality=%d",
               [TemporalScalerPool nameForFeature:feature].UTF8String,
               width, height, (int)quality);
    
    return YES;
}

- (nullable MetalFXDenoiser*)scalerForFeature:(MetalFXFeature)feature {
    return _scalers[@(feature)];
}

- (BOOL)denoiseFeature:(MetalFXFeature)feature
         commandBuffer:(id<MTLCommandBuffer>)commandBuffer
          colorTexture:(id<MTLTexture>)colorTexture
         motionTexture:(id<MTLTexture>)motionTexture
          depthTexture:(id<MTLTexture>)depthTexture
         outputTexture:(id<MTLTexture>)outputTexture
               jitterX:(float)jitterX
               jitterY:(float)jitterY
                 reset:(BOOL)reset
{
    if (!commandBuffer || !colorTexture || !motionTexture || !depthTexture || !outputTexture) {
        return NO;
    }

    if (motionTexture.width != colorTexture.width || motionTexture.height != colorTexture.height ||
        depthTexture.width != colorTexture.width || depthTexture.height != colorTexture.height ||
        outputTexture.width != colorTexture.width || outputTexture.height != colorTexture.height) {
        static uint64_t sMismatchLogs = 0;
        sMismatchLogs++;
        if (sMismatchLogs % 300 == 1) {
            os_log_error(sLog,
                         "Texture size mismatch for %s: color=%lux%lu motion=%lux%lu depth=%lux%lu output=%lux%lu",
                         [TemporalScalerPool nameForFeature:feature].UTF8String,
                         colorTexture.width, colorTexture.height,
                         motionTexture.width, motionTexture.height,
                         depthTexture.width, depthTexture.height,
                         outputTexture.width, outputTexture.height);
        }
        return NO;
    }

    NSNumber* key = @(feature);
    MetalFXDenoiser* scaler = [self scalerForFeature:feature];

    FeatureScalerConfig wanted = {
        colorTexture.width,
        colorTexture.height,
        MetalFXQuality_Quality,
        colorTexture.pixelFormat,
        motionTexture.pixelFormat,
        depthTexture.pixelFormat,
        outputTexture.pixelFormat,
    };

    NSValue* existingCfgValue = _configurations[key];
    FeatureScalerConfig existingCfg = {0};
    if (existingCfgValue && strcmp(existingCfgValue.objCType, @encode(FeatureScalerConfig)) == 0) {
        [existingCfgValue getValue:&existingCfg];
        wanted.quality = existingCfg.quality;
    }

    const bool needsNewScaler =
        (!scaler) ||
        (!existingCfgValue) ||
        (existingCfg.width != wanted.width) ||
        (existingCfg.height != wanted.height) ||
        (existingCfg.colorFormat != wanted.colorFormat) ||
        (existingCfg.motionFormat != wanted.motionFormat) ||
        (existingCfg.depthFormat != wanted.depthFormat) ||
        (existingCfg.outputFormat != wanted.outputFormat);

    if (needsNewScaler) {
        MetalFXDenoiser* newScaler = [[MetalFXDenoiser alloc] initWithDevice:_device
                                                                  inputWidth:wanted.width
                                                                 inputHeight:wanted.height
                                                                 outputWidth:wanted.width
                                                                outputHeight:wanted.height
                                                            colorPixelFormat:wanted.colorFormat
                                                           motionPixelFormat:wanted.motionFormat
                                                            depthPixelFormat:wanted.depthFormat
                                                           outputPixelFormat:wanted.outputFormat];
        if (!newScaler || ![newScaler isValid]) {
            os_log_error(sLog, "Failed to create scaler for %s at %lux%lu (formats c=%u m=%u d=%u o=%u)",
                        [TemporalScalerPool nameForFeature:feature].UTF8String,
                        wanted.width, wanted.height,
                        (unsigned)wanted.colorFormat, (unsigned)wanted.motionFormat,
                        (unsigned)wanted.depthFormat, (unsigned)wanted.outputFormat);
            return NO;
        }

        [newScaler setSharpness:SharpnessForQuality(wanted.quality)];
        _scalers[key] = newScaler;
        _configurations[key] = [NSValue valueWithBytes:&wanted objCType:@encode(FeatureScalerConfig)];
        scaler = newScaler;
    }
    
    if (!scaler) {
        os_log_error(sLog, "No scaler available for %s",
                    [TemporalScalerPool nameForFeature:feature].UTF8String);
        return NO;
    }
    
    [scaler encodeToCommandBuffer:commandBuffer
                     colorTexture:colorTexture
                    motionTexture:motionTexture
                     depthTexture:depthTexture
                    outputTexture:outputTexture
                          jitterX:jitterX
                          jitterY:jitterY
                            reset:reset];
    
    return YES;
}

- (void)resetAllHistories {
    for (MetalFXDenoiser* scaler in _scalers.allValues) {
        [scaler resetHistory];
    }
}

+ (NSString*)nameForFeature:(MetalFXFeature)feature {
    switch (feature) {
        case MetalFXFeature_Shadows: return @"Shadows";
        case MetalFXFeature_RTXDIDiffuse: return @"RTXDIDiffuse";
        case MetalFXFeature_RTXDISpecular: return @"RTXDISpecular";
        case MetalFXFeature_ReSTIRGI: return @"ReSTIRGI";
        case MetalFXFeature_Reflections: return @"Reflections";
        case MetalFXFeature_AO: return @"AO";
        default: return @"Unknown";
    }
}

@end
