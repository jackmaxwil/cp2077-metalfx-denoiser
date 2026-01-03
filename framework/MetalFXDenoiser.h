#pragma once

/**
 * @file MetalFXDenoiser.h
 * @brief Objective-C interface for MetalFX temporal denoiser
 */

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <MetalFX/MetalFX.h>

NS_ASSUME_NONNULL_BEGIN

/**
 * MetalFX Temporal Denoiser wrapper
 * Manages a single MTLFXTemporalScaler instance
 */
@interface MetalFXDenoiser : NSObject

@property (nonatomic, readonly) id<MTLDevice> device;
@property (nonatomic, readonly) id<MTLFXTemporalScaler> scaler;
@property (nonatomic, readonly) NSUInteger inputWidth;
@property (nonatomic, readonly) NSUInteger inputHeight;
@property (nonatomic, readonly) NSUInteger outputWidth;
@property (nonatomic, readonly) NSUInteger outputHeight;

/**
 * Initialize with device and resolution
 * @param device Metal device
 * @param inputWidth Input texture width
 * @param inputHeight Input texture height
 * @param outputWidth Output texture width (can differ for upscaling)
 * @param outputHeight Output texture height
 * @return Initialized denoiser, or nil on failure
 */
- (nullable instancetype)initWithDevice:(id<MTLDevice>)device
                             inputWidth:(NSUInteger)inputWidth
                            inputHeight:(NSUInteger)inputHeight
                            outputWidth:(NSUInteger)outputWidth
                           outputHeight:(NSUInteger)outputHeight;

/**
 * Initialize for denoising only (same input/output resolution)
 */
- (nullable instancetype)initWithDevice:(id<MTLDevice>)device
                                  width:(NSUInteger)width
                                 height:(NSUInteger)height;

/**
 * Encode denoising operation to command buffer
 * @param commandBuffer Command buffer to encode into
 * @param colorTexture Noisy input texture
 * @param motionTexture Motion vectors texture
 * @param depthTexture Depth buffer texture
 * @param outputTexture Output texture for denoised result
 * @param jitterX TAA jitter X offset
 * @param jitterY TAA jitter Y offset
 * @param reset Reset temporal history
 */
- (void)encodeToCommandBuffer:(id<MTLCommandBuffer>)commandBuffer
                 colorTexture:(id<MTLTexture>)colorTexture
                motionTexture:(id<MTLTexture>)motionTexture
                 depthTexture:(id<MTLTexture>)depthTexture
                outputTexture:(id<MTLTexture>)outputTexture
                      jitterX:(float)jitterX
                      jitterY:(float)jitterY
                        reset:(BOOL)reset;

/**
 * Check if this resolution configuration is valid
 */
- (BOOL)isValid;

/**
 * Reset temporal history (call after camera cut)
 */
- (void)resetHistory;

@end

NS_ASSUME_NONNULL_END
