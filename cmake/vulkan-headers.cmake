# Fallback Vulkan headers fetched via FetchContent when system Vulkan is not found.
include(FetchContent)
FetchContent_Declare(vulkan_headers
    URL https://github.com/KhronosGroup/Vulkan-Headers/archive/refs/tags/v1.3.275.tar.gz
    URL_HASH SHA256=7161da645dbd33fd4ea61eec08e0d77389a640010acbf4afc00234f84df9b314
    DOWNLOAD_EXTRACT_TIMESTAMP TRUE)
FetchContent_MakeAvailable(vulkan_headers)
set(vulkan_include "${vulkan_headers_SOURCE_DIR}/include")

if(NOT TARGET Vulkan::Vulkan)
    add_library(Vulkan::Vulkan INTERFACE IMPORTED)
    target_include_directories(Vulkan::Vulkan INTERFACE "${vulkan_include}")
    set(Vulkan_FOUND TRUE)
    set(Vulkan_LIBRARY "headers only (FetchContent)")
    set(Vulkan_INCLUDE_DIRS "${vulkan_include}")
endif()
