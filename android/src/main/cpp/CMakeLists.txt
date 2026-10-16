cmake_minimum_required(VERSION 3.22.1)
project(patcher_boot LANGUAGES CXX)
add_library(patcher_boot SHARED bridge.cpp)
target_compile_features(patcher_boot PRIVATE cxx_std_17)
target_compile_options(patcher_boot PRIVATE -Wall -Wextra -Werror -fvisibility=hidden)
# Debug info, and the build-id the linker derives from it, would otherwise
# record this build's source and build directories; a rebuild of the same
# sources must produce the same library.
target_compile_options(patcher_boot PRIVATE
  "-ffile-prefix-map=${CMAKE_CURRENT_SOURCE_DIR}=src"
  "-ffile-prefix-map=${CMAKE_BINARY_DIR}=build")
