cmake_minimum_required(VERSION 3.10)
set(PROJECT_NAME "xue_hua_media_compression_linux")
project(${PROJECT_NAME} LANGUAGES CXX)

set(PLUGIN_NAME "xue_hua_media_compression_linux_plugin")

list(APPEND PLUGIN_SOURCES
  "image_vips.cc"
  "image_vips.h"
  "messages.g.cc"
  "messages.g.h"
  "video_vaapi.cc"
  "video_vaapi.h"
  "xue_hua_media_compression_linux_plugin.cc"
)

find_package(PkgConfig REQUIRED)
pkg_check_modules(VIPS REQUIRED IMPORTED_TARGET vips)
pkg_check_modules(LIBAV REQUIRED IMPORTED_TARGET
  libavcodec libavformat libavutil libavfilter)
pkg_check_modules(LIBVA REQUIRED IMPORTED_TARGET libva libva-drm)

add_library(${PLUGIN_NAME} SHARED
  ${PLUGIN_SOURCES}
)

apply_standard_settings(${PLUGIN_NAME})
set_target_properties(${PLUGIN_NAME} PROPERTIES
  CXX_VISIBILITY_PRESET hidden
  CXX_STANDARD 17)
target_compile_definitions(${PLUGIN_NAME} PRIVATE FLUTTER_PLUGIN_IMPL)
target_include_directories(${PLUGIN_NAME} INTERFACE
  "${CMAKE_CURRENT_SOURCE_DIR}/include")
target_link_libraries(${PLUGIN_NAME} PRIVATE flutter)
target_link_libraries(${PLUGIN_NAME} PRIVATE PkgConfig::GTK)
target_link_libraries(${PLUGIN_NAME} PRIVATE PkgConfig::VIPS)
target_link_libraries(${PLUGIN_NAME} PRIVATE PkgConfig::LIBAV)
target_link_libraries(${PLUGIN_NAME} PRIVATE PkgConfig::LIBVA)

set(xue_hua_media_compression_linux_bundled_libraries
  ""
  PARENT_SCOPE
)
