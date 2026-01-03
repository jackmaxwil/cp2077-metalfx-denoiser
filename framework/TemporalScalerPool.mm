/**
 * @file TemporalScalerPool.mm
 * @brief Temporal scaler pool implementation
 */

#import "TemporalScalerPool.h"
#import "MetalFXDenoiser.h"
#import <os/log.h>

static os_log_t sLog = nil;

@implementation TemporalScalerPool {
    NSMutableDictionary<NSNumber*, MetalFXDenoiser*>* _scalers;
    NSMutableDictionary<NSNumber*, NSValue*>* _configurations;
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
    
    // Check if existing scaler matches configuration
    MetalFXDenoiser* existing = _scalers[key];
    if (existing && existing.inputWidth == width && existing.inputHeight == height) {
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
    MetalFXDenoiser* scaler = [self scalerForFeature:feature];
    
    if (!scaler) {
        // Auto-configure from input texture dimensions
        NSUInteger width = colorTexture.width;
        NSUInteger height = colorTexture.height;
        
        if (![self configureScalerForFeature:feature
                                       width:width
                                      height:height
                                     quality:MetalFXQuality_Quality]) {
            return NO;
        }
        
        scaler = [self scalerForFeature:feature];
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
