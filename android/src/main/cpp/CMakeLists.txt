cmake_minimum_required(VERSION 3.22.1)
project(yespower LANGUAGES C)

set(CMAKE_C_STANDARD 11)

# One copy of the hashing code, in the package's native/yespower/ — the very same
# sources tools/selftest.py compiles on a desktop to check the genesis vector.
set(YP_DIR ${CMAKE_CURRENT_SOURCE_DIR}/../../../../../native/yespower)

if(NOT EXISTS ${YP_DIR}/yp_bridge.c)
    message(FATAL_ERROR "yespower sources not found at ${YP_DIR}")
endif()

add_library(yespower SHARED
        ${YP_DIR}/yp_bridge.c
        ${YP_DIR}/yespower-opt.c
        ${YP_DIR}/sha256.c)

target_include_directories(yespower PRIVATE ${YP_DIR})

target_compile_options(yespower PRIVATE -O3 -funroll-loops -fno-strict-aliasing)

# No -fvisibility=hidden: Dart resolves yp_hash / yp_scan / yp_version / yp_free_local
# by name through dlsym, so they must stay exported.

if(ANDROID_ABI STREQUAL "x86")
    target_compile_options(yespower PRIVATE -msse2)
elseif(ANDROID_ABI STREQUAL "armeabi-v7a")
    target_compile_options(yespower PRIVATE -mfpu=neon)
endif()
