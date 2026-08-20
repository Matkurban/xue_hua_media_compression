//
//  Generated file. Do not edit.
//

// clang-format off

#include "generated_plugin_registrant.h"

#include <xue_hua_file_operations/xue_hua_file_operations_plugin.h>
#include <xue_hua_media_compression_linux/xue_hua_media_compression_linux_plugin.h>

void fl_register_plugins(FlPluginRegistry* registry) {
  g_autoptr(FlPluginRegistrar) xue_hua_file_operations_registrar =
      fl_plugin_registry_get_registrar_for_plugin(registry, "XueHuaFileOperationsPlugin");
  xue_hua_file_operations_plugin_register_with_registrar(xue_hua_file_operations_registrar);
  g_autoptr(FlPluginRegistrar) xue_hua_media_compression_linux_registrar =
      fl_plugin_registry_get_registrar_for_plugin(registry, "XueHuaMediaCompressionLinuxPlugin");
  xue_hua_media_compression_linux_plugin_register_with_registrar(xue_hua_media_compression_linux_registrar);
}
