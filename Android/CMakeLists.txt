cmake_minimum_required(VERSION 3.10)
project(RoAndroidShade LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -Wall -Wextra -fPIC -fvisibility=hidden")

include_directories(
    ${CMAKE_CURRENT_SOURCE_DIR}/include
    ${CMAKE_CURRENT_SOURCE_DIR}/layer
    ${CMAKE_CURRENT_SOURCE_DIR}/layer/shaders
    ${CMAKE_CURRENT_SOURCE_DIR}/../ThirdParty/ReShadeFX/source
    ${CMAKE_CURRENT_SOURCE_DIR}/../ThirdParty/SPIRV-Cross
)

# ReShadeFX core compiler sources
file(GLOB RESHADE_SOURCES
    "${CMAKE_CURRENT_SOURCE_DIR}/../ThirdParty/ReShadeFX/source/*.cpp"
)

# Vulkan layer sources
set(LAYER_SOURCES
    layer/RoShadeLayer.cpp
    layer/DepthCapture.cpp
    layer/FXVulkanRuntime.cpp
)

add_library(VkLayer_RoShade SHARED
    ${LAYER_SOURCES}
    ${RESHADE_SOURCES}
)

set_target_properties(VkLayer_RoShade PROPERTIES
    OUTPUT_NAME "VkLayer_RoShade"
    PREFIX "lib"
)

if(ANDROID)
    find_library(log-lib log)
    target_link_libraries(VkLayer_RoShade ${log-lib})
endif()

