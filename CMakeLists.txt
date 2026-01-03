cmake_minimum_required(VERSION 3.20)
project(MetalFXDenoiser VERSION 1.0.0 LANGUAGES CXX OBJCXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_OBJCXX_STANDARD 20)
set(CMAKE_OBJCXX_STANDARD_REQUIRED ON)

# macOS specific settings
set(CMAKE_OSX_ARCHITECTURES "arm64")
set(CMAKE_OSX_DEPLOYMENT_TARGET "13.0")

# Output directory
set(CMAKE_RUNTIME_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR})
set(CMAKE_LIBRARY_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR})

# RED4ext SDK (header-only usage for macOS)
set(RED4EXT_SDK_DIR "${CMAKE_SOURCE_DIR}/vendor/RED4ext.SDK")
# Don't build the SDK - it has D3D12 dependencies
# We only need the headers

# Metal Framework Library (Objective-C++)
add_library(MetalFXDenoiserCore SHARED
    framework/MetalFXDenoiser.mm
    framework/TemporalScalerPool.mm
    framework/BufferConverter.mm
)

target_compile_options(MetalFXDenoiserCore PRIVATE
    -fobjc-arc
    -fmodules
)

target_link_libraries(MetalFXDenoiserCore PRIVATE
    "-framework Metal"
    "-framework MetalFX"
    "-framework Foundation"
    "-framework CoreGraphics"
)

target_include_directories(MetalFXDenoiserCore PUBLIC
    ${CMAKE_SOURCE_DIR}/framework
)

set_target_properties(MetalFXDenoiserCore PROPERTIES
    OUTPUT_NAME "MetalFXDenoiserCore"
    SUFFIX ".dylib"
)

# RED4ext Plugin (C++)
add_library(MetalFXDenoiser SHARED
    src/plugin/main.cpp
    src/plugin/NRDHooks.cpp
    src/plugin/BufferInterceptor.cpp
    src/plugin/Config.cpp
)

target_include_directories(MetalFXDenoiser PRIVATE
    ${CMAKE_SOURCE_DIR}/src/plugin
    ${CMAKE_SOURCE_DIR}/lib
    ${CMAKE_SOURCE_DIR}/framework
)

# Header-only SDK
target_include_directories(MetalFXDenoiser PRIVATE
    ${RED4EXT_SDK_DIR}/include
)

target_link_libraries(MetalFXDenoiser PRIVATE
    MetalFXDenoiserCore
)

set_target_properties(MetalFXDenoiser PROPERTIES
    OUTPUT_NAME "MetalFXDenoiser"
    SUFFIX ".dylib"
)

# Install target
install(TARGETS MetalFXDenoiser MetalFXDenoiserCore
    LIBRARY DESTINATION red4ext/plugins/MetalFXDenoiser
)

# Copy config template
install(FILES ${CMAKE_SOURCE_DIR}/config/config.toml.template
    DESTINATION red4ext/plugins/MetalFXDenoiser
    RENAME config.toml
    OPTIONAL
)
