#include "MetalTrace.hpp"
#include "Logger.hpp"

#import <Metal/Metal.h>
#import <objc/runtime.h>

#include <cstdio>
#include <mutex>
#include <string>
#include <unordered_set>

namespace {

using SetPSOFn = void (*)(id, SEL, id<MTLComputePipelineState>);

Method s_method = nullptr;
SetPSOFn s_original = nullptr;

std::mutex s_mutex;
std::unordered_set<const void*> s_seen;
constexpr size_t kMaxLogged = 512;

void SwizzledSetComputePipelineState(id self, SEL cmd, id<MTLComputePipelineState> pso)
{
    if (pso) {
        // ponytail: global lock on every bind; fine for opt-in tracing, use a lock-free set before any hot-path use.
        std::lock_guard<std::mutex> lock(s_mutex);
        if (s_seen.size() < kMaxLogged && s_seen.insert((__bridge const void*)pso).second) {
            char buf[256];
            std::snprintf(buf, sizeof(buf), "compute PSO #%zu %p label=%s threadExecutionWidth=%lu", s_seen.size(),
                          (__bridge const void*)pso, pso.label ? pso.label.UTF8String : "(none)",
                          (unsigned long)pso.threadExecutionWidth);
            Logger::Info(buf);
        }
    }
    s_original(self, cmd, pso);
}

} // namespace

namespace MetalTrace {

bool Install()
{
    if (s_method) {
        return true;
    }

    // The encoder class is private to the driver (AGX...ComputeContext), so find it by making one.
    Class cls = nil;
    @autoreleasepool {
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        id<MTLCommandQueue> queue = [device newCommandQueue];
        id<MTLCommandBuffer> commandBuffer = [queue commandBuffer];
        id<MTLComputeCommandEncoder> encoder = [commandBuffer computeCommandEncoder];
        cls = [encoder class];
        [encoder endEncoding];
    }
    if (!cls) {
        Logger::Warn("Metal trace: could not create a compute encoder");
        return false;
    }

    SEL sel = @selector(setComputePipelineState:);
    Method inherited = class_getInstanceMethod(cls, sel);
    if (!inherited) {
        Logger::Warn("Metal trace: encoder class has no setComputePipelineState:");
        return false;
    }

    // Add the method on the concrete class when it is inherited, so a superclass is never modified.
    IMP original = method_getImplementation(inherited);
    if (class_addMethod(cls, sel, original, method_getTypeEncoding(inherited))) {
        inherited = class_getInstanceMethod(cls, sel);
    }
    s_original = reinterpret_cast<SetPSOFn>(original);
    method_setImplementation(inherited, reinterpret_cast<IMP>(&SwizzledSetComputePipelineState));
    s_method = inherited;

    Logger::Info(std::string("Metal trace: swizzled -[") + class_getName(cls) + " setComputePipelineState:]");
    return true;
}

void Uninstall()
{
    if (!s_method) {
        return;
    }
    method_setImplementation(s_method, reinterpret_cast<IMP>(s_original));
    s_method = nullptr;
}

} // namespace MetalTrace
