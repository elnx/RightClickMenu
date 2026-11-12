cmake_minimum_required(VERSION 3.5.0)
project(tukurw)

set(NATIVERENDER_ROOT_PATH ${CMAKE_CURRENT_SOURCE_DIR})

if(DEFINED PACKAGE_FIND_DIR)
    include(${PACKAGE_FIND_DIR}/ohos.toolchain.cmake)
elseif(DEFINED OHOS_SDK_NATIVE)
    include(${OHOS_SDK_NATIVE}/build/cmake/ohos.toolchain.cmake)
elseif(DEFINED OHOS_NDK_HOME)
    include(${OHOS_NDK_HOME}/build/cmake/ohos.toolchain.cmake)
elseif(DEFINED ENV{OHOS_NDK_HOME})
    include($ENV{OHOS_NDK_HOME}/build/cmake/ohos.toolchain.cmake)
else()
    message(FATAL_ERROR "OHOS_NDK_HOME is not set (point it at <sdk>/default/openharmony/native)")
endif()

add_library(entry SHARED napi_init.cpp)
target_link_libraries(entry PUBLIC libace_napi.z.so)
