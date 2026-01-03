/**
 * @file BufferConverter.mm
 * @brief Buffer format conversion utilities
 * 
 * Handles conversion between game buffer formats and MetalFX-compatible formats.
 */

#import <Metal/Metal.h>
#import <os/log.h>

static os_log_t sLog = nil;

// =============================================================================
// Format Conversion Utilities
// =============================================================================

/**
 * Check if texture format is compatible with MetalFX
 */
BOOL IsFormatCompatible(MTLPixelFormat format) {
    switch (format) {
        case MTLPixelFormatRGBA16Float:
        case MTLPixelFormatRGBA32Float:
        case MTLPixelFormatBGRA8Unorm:
        case MTLPixelFormatBGRA8Unorm_sRGB:
            return YES;
        default:
            return NO;
    }
}

/**
 * Get recommended MetalFX format for a given input format
 */
MTLPixelFormat GetMetalFXCompatibleFormat(MTLPixelFormat inputFormat) {
    switch (inputFormat) {
        case MTLPixelFormatRGBA16Float:
        case MTLPixelFormatRGBA32Float:
            return MTLPixelFormatRGBA16Float;
            
        case MTLPixelFormatBGRA8Unorm:
        case MTLPixelFormatBGRA8Unorm_sRGB:
        case MTLPixelFormatRGBA8Unorm:
        case MTLPixelFormatRGBA8Unorm_sRGB:
            return MTLPixelFormatRGBA16Float;
            
        case MTLPixelFormatR16Float:
        case MTLPixelFormatR32Float:
            return MTLPixelFormatRGBA16Float;
            
        default:
            return MTLPixelFormatRGBA16Float;
    }
}

// =============================================================================
// Motion Vector Conversion
// =============================================================================

/**
 * Motion vector format expected by MetalFX:
 * - RG16Float or RG32Float
 * - Values in pixels (not normalized)
 * - X = horizontal motion (positive = right)
 * - Y = vertical motion (positive = down)
 * 
 * Game may use different conventions:
 * - NDC space (-1 to 1)
 * - Velocity (per-frame vs per-second)
 * - Inverted Y axis
 */

@interface MotionVectorConverter : NSObject

@property (nonatomic, readonly) id<MTLDevice> device;
@property (nonatomic, readonly) id<MTLComputePipelineState> convertPipeline;

- (instancetype)initWithDevice:(id<MTLDevice>)device;

- (void)convertMotionVectors:(id<MTLTexture>)input
                      output:(id<MTLTexture>)output
                       width:(float)width
                      height:(float)height
               commandBuffer:(id<MTLCommandBuffer>)commandBuffer;

@end

@implementation MotionVectorConverter

+ (void)initialize {
    if (self == [MotionVectorConverter class]) {
        sLog = os_log_create("com.metalfx.denoiser", "BufferConverter");
    }
}

- (instancetype)initWithDevice:(id<MTLDevice>)device {
    self = [super init];
    if (self) {
        _device = device;
        
        // Create compute shader for motion vector conversion
        NSString* shaderSource = @R"(
            #include <metal_stdlib>
            using namespace metal;
            
            kernel void convertMotionVectors(
                texture2d<float, access::read> input [[texture(0)]],
                texture2d<float, access::write> output [[texture(1)]],
                constant float2& resolution [[buffer(0)]],
                uint2 gid [[thread_position_in_grid]])
            {
                if (gid.x >= output.get_width() || gid.y >= output.get_height()) {
                    return;
                }
                
                float4 motion = input.read(gid);
                
                // Convert from NDC to pixels if needed
                // Assuming input is in NDC (-1 to 1) range
                float2 pixelMotion = motion.xy * resolution * 0.5;
                
                // MetalFX expects Y to point down (screen space)
                // Flip Y if game uses OpenGL convention
                // pixelMotion.y = -pixelMotion.y;  // Uncomment if needed
                
                output.write(float4(pixelMotion, 0, 0), gid);
            }
        )";
        
        NSError* error = nil;
        id<MTLLibrary> library = [device newLibraryWithSource:shaderSource
                                                      options:nil
                                                        error:&error];
        if (!library) {
            os_log_error(sLog, "Failed to create motion vector shader library: %s",
                        error.localizedDescription.UTF8String);
            return nil;
        }
        
        id<MTLFunction> function = [library newFunctionWithName:@"convertMotionVectors"];
        if (!function) {
            os_log_error(sLog, "Failed to find convertMotionVectors function");
            return nil;
        }
        
        _convertPipeline = [device newComputePipelineStateWithFunction:function
                                                                 error:&error];
        if (!_convertPipeline) {
            os_log_error(sLog, "Failed to create motion vector pipeline: %s",
                        error.localizedDescription.UTF8String);
            return nil;
        }
    }
    return self;
}

- (void)convertMotionVectors:(id<MTLTexture>)input
                      output:(id<MTLTexture>)output
                       width:(float)width
                      height:(float)height
               commandBuffer:(id<MTLCommandBuffer>)commandBuffer
{
    id<MTLComputeCommandEncoder> encoder = [commandBuffer computeCommandEncoder];
    [encoder setComputePipelineState:_convertPipeline];
    [encoder setTexture:input atIndex:0];
    [encoder setTexture:output atIndex:1];
    
    float resolution[2] = {width, height};
    [encoder setBytes:resolution length:sizeof(resolution) atIndex:0];
    
    MTLSize threadGroupSize = MTLSizeMake(16, 16, 1);
    MTLSize threadGroups = MTLSizeMake(
        (output.width + 15) / 16,
        (output.height + 15) / 16,
        1
    );
    
    [encoder dispatchThreadgroups:threadGroups
            threadsPerThreadgroup:threadGroupSize];
    [encoder endEncoding];
}

@end

// =============================================================================
// C Interface
// =============================================================================

extern "C" {

typedef struct {
    MotionVectorConverter* converter;
} BufferConverterContext;

BufferConverterContext* BufferConverter_Create(void* device) {
    @autoreleasepool {
        id<MTLDevice> mtlDevice = (__bridge id<MTLDevice>)device;
        MotionVectorConverter* converter = [[MotionVectorConverter alloc] initWithDevice:mtlDevice];
        if (!converter) return nullptr;
        
        BufferConverterContext* ctx = new BufferConverterContext();
        ctx->converter = converter;
        return ctx;
    }
}

void BufferConverter_Destroy(BufferConverterContext* ctx) {
    if (ctx) {
        ctx->converter = nil;
        delete ctx;
    }
}

void BufferConverter_ConvertMotionVectors(
    BufferConverterContext* ctx,
    void* input,
    void* output,
    float width,
    float height,
    void* commandBuffer)
{
    if (!ctx || !ctx->converter) return;
    
    @autoreleasepool {
        [ctx->converter convertMotionVectors:(__bridge id<MTLTexture>)input
                                      output:(__bridge id<MTLTexture>)output
                                       width:width
                                      height:height
                               commandBuffer:(__bridge id<MTLCommandBuffer>)commandBuffer];
    }
}

} // extern "C"
