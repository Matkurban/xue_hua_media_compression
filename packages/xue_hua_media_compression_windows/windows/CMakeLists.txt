cmake_minimum_required(VERSION 3.14)
set(PROJECT_NAME "xue_hua_media_compression_windows")
project(${PROJECT_NAME} LANGUAGES CXX)

cmake_policy(VERSION 3.14...3.25)

# Flutter generated_plugins.cmake links ${plugin}_plugin. Keep that name as an
# ALIAS so MSBuild IntDir / .tlog paths can use a short real target (MAX_PATH).
set(PLUGIN_NAME "xue_hua_media_compression_windows_plugin")
set(PLUGIN_TARGET "xhmc_win")

# Keep object-file paths under Win32 MAX_PATH (260) on deep checkouts.
set(CMAKE_OBJECT_PATH_MAX 200)

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

add_library(${PLUGIN_TARGET} SHARED
  "include/xue_hua_media_compression_windows/xue_hua_media_compression_windows_plugin_c_api.h"
  "xue_hua_media_compression_windows_plugin_c_api.cpp"
  ${PLUGIN_SOURCES}
)

apply_standard_settings(${PLUGIN_TARGET})

if(MSVC)
  target_compile_options(${PLUGIN_TARGET} PRIVATE "/utf-8")
  target_compile_options(${PLUGIN_TARGET} PRIVATE "/await")
  # VS 18 / MSVC 14.51 treats /await + <experimental/coroutine> as an error.
  target_compile_definitions(${PLUGIN_TARGET} PRIVATE
    _SILENCE_EXPERIMENTAL_COROUTINE_DEPRECATION_WARNINGS)
endif()

# Resolve the plugin-symlink to the real package path so /I stays under MAX_PATH.
get_filename_component(PLUGIN_SRC_DIR "${CMAKE_CURRENT_SOURCE_DIR}" REALPATH)

set_target_properties(${PLUGIN_TARGET} PROPERTIES
  CXX_VISIBILITY_PRESET hidden
  CXX_STANDARD 17
  OUTPUT_NAME ${PLUGIN_NAME})
target_compile_definitions(${PLUGIN_TARGET} PRIVATE FLUTTER_PLUGIN_IMPL)
target_include_directories(${PLUGIN_TARGET} PRIVATE
  "${PLUGIN_SRC_DIR}"
  "${PLUGIN_SRC_DIR}/include")
target_include_directories(${PLUGIN_TARGET} INTERFACE
  "${PLUGIN_SRC_DIR}/include")
target_link_libraries(${PLUGIN_TARGET} PRIVATE flutter flutter_wrapper_plugin)
target_link_libraries(${PLUGIN_TARGET} PRIVATE
  windowscodecs ole32 oleaut32 runtimeobject windowsapp)

add_library(${PLUGIN_NAME} ALIAS ${PLUGIN_TARGET})

set(xue_hua_media_compression_windows_bundled_libraries
  ""
  PARENT_SCOPE
)
