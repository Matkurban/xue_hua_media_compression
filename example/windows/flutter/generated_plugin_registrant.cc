//
//  Generated file. Do not edit.
//

// clang-format off

#include "generated_plugin_registrant.h"

#include <file_selector_windows/file_selector_windows.h>
#include <xue_hua_media_compression_windows/xue_hua_media_compression_windows_plugin.h>

void RegisterPlugins(flutter::PluginRegistry* registry) {
  FileSelectorWindowsRegisterWithRegistrar(
      registry->GetRegistrarForPlugin("FileSelectorWindows"));
  XueHuaMediaCompressionWindowsPluginRegisterWithRegistrar(
      registry->GetRegistrarForPlugin("XueHuaMediaCompressionWindowsPlugin"));
}
