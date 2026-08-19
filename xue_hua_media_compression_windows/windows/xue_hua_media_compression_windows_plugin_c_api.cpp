#include "include/xue_hua_media_compression_windows/xue_hua_media_compression_windows_plugin_c_api.h"

#include <flutter/plugin_registrar_windows.h>

#include "xue_hua_media_compression_windows_plugin.h"

void XueHuaMediaCompressionWindowsPluginCApiRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar) {
  xue_hua_media_compression::XueHuaMediaCompressionWindowsPlugin::
      RegisterWithRegistrar(
          flutter::PluginRegistrarManager::GetInstance()
              ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar));
}
