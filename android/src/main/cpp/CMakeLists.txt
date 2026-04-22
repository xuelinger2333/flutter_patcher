cmake_minimum_required(VERSION 3.22.1)
project(flutter_patcher_bsdiff LANGUAGES C)

set(CMAKE_C_STANDARD 99)

# ============================================================
# 本 CMakeLists.txt 通过 file(GLOB ...) 收集第三方源，允许你
# 按 README 的「bsdiff 集成指南」把官方源码「落地」即可编译：
#
#   third_party/bsdiff/bspatch.c    <- Colin Percival's bsdiff-4.3
#   third_party/bzip2/*.c           <- bzip2-1.0.x 的 blocksort/bzlib/...
#
# 若这两个目录为空（默认就是空），构建会退回到仅编译 bsdiff_stub.c，
# JNI 函数返回 ERR_NOT_BUILT。Kotlin 侧会降级为「仅 full 模式」。
# ============================================================

file(GLOB BSDIFF_SRC third_party/bsdiff/*.c)
file(GLOB BZIP2_SRC  third_party/bzip2/*.c)

set(NATIVE_SRC
    bsdiff_jni.c
)

if (BSDIFF_SRC AND BZIP2_SRC)
    message(STATUS "flutter_patcher: building with upstream bsdiff + bzip2")
    list(APPEND NATIVE_SRC ${BSDIFF_SRC} ${BZIP2_SRC} third_party/flutter_patcher_probe.c)
    add_definitions(-DFLUTTER_PATCHER_HAS_BSDIFF=1)
    include_directories(third_party/bzip2)
else()
    message(WARNING
        "flutter_patcher: third_party/bsdiff and/or third_party/bzip2 is empty; "
        "bsdiff JNI will return ERR_NOT_BUILT. "
        "Drop in upstream sources and rebuild to enable diff-mode patches.")
    list(APPEND NATIVE_SRC bsdiff_stub.c)
endif()

add_library(flutter_patcher_bsdiff SHARED ${NATIVE_SRC})

# Android log + libc
find_library(log-lib log)
target_link_libraries(flutter_patcher_bsdiff ${log-lib})

# 警告级别
target_compile_options(flutter_patcher_bsdiff PRIVATE
    -Wall -Wno-unused-function -Wno-unused-variable -Wno-sign-compare)
