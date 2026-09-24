cmake_minimum_required(VERSION 3.22.1)
project(yespower LANGUAGES C)

set(CMAKE_C_STANDARD 11)

# The C sources live once, in the repo's native/yespower/ — the same files the
# desktop test harness compiles. This CMakeLists just points at them so there is
# only ever one copy of the hashing code.
set(YP_DIR ${CMAKE_CURRENT_SOURCE_DIR}/../../../../../native/yespower)

if(NOT EXISTS ${YP_DIR}/yp_bridge.c)
    message(FATAL_ERROR "yespower sources not found at ${YP_DIR}")
endif()

add_library(yespower SHARED
        ${YP_DIR}/yp_bridge.c
        ${YP_DIR}/yespower-opt.c
        ${YP_DIR}/sha256.c)

target_include_directories(yespower PRIVATE ${YP_DIR})

# yespower is compute-bound; this is the whole reason the app has a C core.
target_compile_options(yespower PRIVATE -O3 -funroll-loops)

# Do NOT add -fvisibility=hidden here: Dart resolves yp_hash / yp_scan /
# yp_version by name through dlsym, so they must stay exported. (The default
# visibility does that.)

if(ANDROID_ABI STREQUAL "x86")
    target_compile_options(yespower PRIVATE -msse2)
elseif(ANDROID_ABI STREQUAL "armeabi-v7a")
    target_compile_options(yespower PRIVATE -mfpu=neon)
endif()

# keep the optimizer from turning the pwxform core into something slower
target_compile_options(yespower PRIVATE -fno-strict-aliasing)
