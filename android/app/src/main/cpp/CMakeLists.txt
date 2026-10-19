cmake_minimum_required(VERSION 3.22.1)
project(yue2jni LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

set(YUE2_DIR ${CMAKE_CURRENT_SOURCE_DIR}/yue2.cpp)
set(YUE2_PATCH ${CMAKE_CURRENT_SOURCE_DIR}/../../../../patches/yue2-android-hooks.patch)

option(YUE2_VULKAN "Build the ggml Vulkan backend (experimental, off by default)" OFF)
set(YUE2_CPU_ARCH "armv8.6-a+dotprod+i8mm+fp16" CACHE STRING "-march for the ggml CPU backend")

# Apply the progress-hook / thread-override / preview / refine patch to the engine
# submodule once; a tree that carries this version is left alone, an older one is
# reset to the submodule commit first.
set(YUE2_PATCH_MARK "yue2-android patch v2")
set(YUE2_PATCHED FALSE)
if(EXISTS ${YUE2_DIR}/src/hooks.h)
    file(READ ${YUE2_DIR}/src/hooks.h YUE2_HOOKS)
    string(FIND "${YUE2_HOOKS}" "${YUE2_PATCH_MARK}" YUE2_MARK_AT)
    if(NOT YUE2_MARK_AT EQUAL -1)
        set(YUE2_PATCHED TRUE)
    endif()
endif()
if(NOT YUE2_PATCHED)
    find_package(Git REQUIRED)
    if(EXISTS ${YUE2_DIR}/src/hooks.h)
        execute_process(COMMAND ${GIT_EXECUTABLE} checkout -- src WORKING_DIRECTORY ${YUE2_DIR})
        file(REMOVE ${YUE2_DIR}/src/hooks.h)
    endif()
    execute_process(COMMAND ${GIT_EXECUTABLE} apply ${YUE2_PATCH}
                    WORKING_DIRECTORY ${YUE2_DIR} RESULT_VARIABLE PATCH_RESULT)
    if(NOT PATCH_RESULT EQUAL 0)
        message(FATAL_ERROR "Could not apply ${YUE2_PATCH} to ${YUE2_DIR}")
    endif()
endif()

# Tensor names in the YuE2 GGUFs exceed the default GGML_MAX_NAME of 64
add_compile_definitions(GGML_MAX_NAME=128)

# ggml: static, CPU backend tuned for Armv9 phone cores (Tensor G5: Cortex-X4,
# A725, A520 all have dotprod, i8mm and fp16). No OpenMP: ggml's own
# pthread pool inherits the affinity of the calling thread.
set(BUILD_SHARED_LIBS OFF CACHE BOOL "" FORCE)
set(GGML_NATIVE OFF CACHE BOOL "" FORCE)
set(GGML_CPU_ARM_ARCH ${YUE2_CPU_ARCH} CACHE STRING "" FORCE)
set(GGML_OPENMP OFF CACHE BOOL "" FORCE)
set(GGML_BACKEND_DL OFF CACHE BOOL "" FORCE)
set(GGML_BUILD_TESTS OFF CACHE BOOL "" FORCE)
set(GGML_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
set(GGML_VULKAN ${YUE2_VULKAN} CACHE BOOL "" FORCE)
add_subdirectory(${YUE2_DIR}/ggml ggml)

add_library(yyjson STATIC ${YUE2_DIR}/vendor/yyjson/yyjson.c)
target_include_directories(yyjson PUBLIC ${YUE2_DIR}/vendor/yyjson)
target_compile_options(yyjson PRIVATE -w)

# version.h the engine sources include
file(WRITE ${CMAKE_CURRENT_BINARY_DIR}/version.h "#pragma once\n#define YUE2_VERSION \"android\"\n")

add_library(yue2jni SHARED
    yue2_jni.cpp
    ${YUE2_DIR}/src/request.cpp
    ${YUE2_DIR}/src/model-store.cpp)
target_include_directories(yue2jni PRIVATE
    ${YUE2_DIR}/src
    ${YUE2_DIR}
    ${CMAKE_CURRENT_BINARY_DIR})
target_include_directories(yue2jni SYSTEM PRIVATE ${YUE2_DIR}/ggml/include)
target_compile_options(yue2jni PRIVATE -march=${YUE2_CPU_ARCH} -O3 -Wno-unused-function -Wno-unused-parameter)
if(YUE2_VULKAN)
    target_compile_definitions(yue2jni PRIVATE YUE2_WITH_VULKAN)
endif()
target_link_libraries(yue2jni PRIVATE ggml ggml-base ggml-cpu yyjson android log)
if(TARGET ggml-vulkan)
    target_link_libraries(yue2jni PRIVATE ggml-vulkan)
endif()
target_link_options(yue2jni PRIVATE -Wl,--gc-sections -Wl,-z,max-page-size=16384)
