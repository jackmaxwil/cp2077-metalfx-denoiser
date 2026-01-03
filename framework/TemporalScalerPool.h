#pragma once

/**
 * @file TemporalScalerPool.h
 * @brief Manages multiple MetalFX temporal scalers for different RT features
 */

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import "MetalBridge.h"

@class MetalFXDenoiser;

NS_ASSUME_NONNULL_BEGIN

/**
 * Pool of temporal scalers, one for each RT feature
 * Manages scaler lifecycle and configuration
 */
@interface TemporalScalerPool : NSObject

@property (nonatomic, readonly) id<MTLDevice> device;

/**
 * Initialize pool with Metal device
 */
- (instancetype)initWithDevice:(id<MTLDevice>)device;

/**
 * Configure scaler for a specific feature
 */
- (BOOL)configureScalerForFeature:(MetalFXFeature)feature
                            width:(NSUInteger)width
                           height:(NSUInteger)height
                          quality:(MetalFXQuality)quality;

/**
 * Get scaler for a feature
 */
- (nullable MetalFXDenoiser*)scalerForFeature:(MetalFXFeature)feature;

/**
 * Perform denoising for a feature
 */
- (BOOL)denoiseFeature:(MetalFXFeature)feature
         commandBuffer:(id<MTLCommandBuffer>)commandBuffer
          colorTexture:(id<MTLTexture>)colorTexture
         motionTexture:(id<MTLTexture>)motionTexture
          depthTexture:(id<MTLTexture>)depthTexture
         outputTexture:(id<MTLTexture>)outputTexture
               jitterX:(float)jitterX
               jitterY:(float)jitterY
                 reset:(BOOL)reset;

/**
 * Reset all temporal histories
 */
- (void)resetAllHistories;

/**
 * Get feature name for logging
 */
+ (NSString*)nameForFeature:(MetalFXFeature)feature;

@end

NS_ASSUME_NONNULL_END
