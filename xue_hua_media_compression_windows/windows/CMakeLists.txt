cmake_minimum_required(VERSION 3.14)
set(PROJECT_NAME "xue_hua_media_compression_windows")
project(${PROJECT_NAME} LANGUAGES CXX)

cmake_policy(VERSION 3.14...3.25)

set(PLUGIN_NAME "xue_hua_media_compression_windows_plugin")

list(APPEND PLUGIN_SOURCES
  "event_stream.h"
  "image_wic.cpp"
  "image_wic.h"
  "main_thread_dispatcher.h"
  "messages.g.cpp"
  "messages.g.h"
  "video_transcoder.cpp"
  "video_transcoder.h"
  "xue_hua_media_compression_windows_plugin.cpp"
  "xue_hua_media_compression_windows_plugin.h"
)

add_library(${PLUGIN_NAME} SHARED
  "include/xue_hua_media_compression_windows/xue_hua_media_compression_windows_plugin_c_api.h"
  "xue_hua_media_compression_windows_plugin_c_api.cpp"
  ${PLUGIN_SOURCES}
)

apply_standard_settings(${PLUGIN_NAME})

if(MSVC)
  target_compile_options(${PLUGIN_NAME} PRIVATE "/utf-8")
  target_compile_options(${PLUGIN_NAME} PRIVATE "/await")
endif()

set_target_properties(${PLUGIN_NAME} PROPERTIES
  CXX_VISIBILITY_PRESET hidden
  CXX_STANDARD 17)
target_compile_definitions(${PLUGIN_NAME} PRIVATE FLUTTER_PLUGIN_IMPL)
target_include_directories(${PLUGIN_NAME} INTERFACE
  "${CMAKE_CURRENT_SOURCE_DIR}/include")
target_link_libraries(${PLUGIN_NAME} PRIVATE flutter flutter_wrapper_plugin)
target_link_libraries(${PLUGIN_NAME} PRIVATE
  windowscodecs ole32 oleaut32 runtimeobject windowsapp)

set(xue_hua_media_compression_windows_bundled_libraries
  ""
  PARENT_SCOPE
)
