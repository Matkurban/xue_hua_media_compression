//
//  Generated file. Do not edit.
//

// clang-format off

#include "generated_plugin_registrant.h"

#include <xue_hua_file_operations/xue_hua_file_operations_plugin_c_api.h>
#include <xue_hua_media_compression_windows/xue_hua_media_compression_windows_plugin.h>

void RegisterPlugins(flutter::PluginRegistry* registry) {
  XueHuaFileOperationsPluginCApiRegisterWithRegistrar(
      registry->GetRegistrarForPlugin("XueHuaFileOperationsPluginCApi"));
  XueHuaMediaCompressionWindowsPluginRegisterWithRegistrar(
      registry->GetRegistrarForPlugin("XueHuaMediaCompressionWindowsPlugin"));
}
