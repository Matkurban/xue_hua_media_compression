#ifndef FLUTTER_PLUGIN_XUE_HUA_MEDIA_COMPRESSION_LINUX_PLUGIN_H_
#define FLUTTER_PLUGIN_XUE_HUA_MEDIA_COMPRESSION_LINUX_PLUGIN_H_

#include <flutter_linux/flutter_linux.h>

G_BEGIN_DECLS

#ifdef FLUTTER_PLUGIN_IMPL
#define FLUTTER_PLUGIN_EXPORT __attribute__((visibility("default")))
#else
#define FLUTTER_PLUGIN_EXPORT
#endif

typedef struct _XueHuaMediaCompressionLinuxPlugin
    XueHuaMediaCompressionLinuxPlugin;
typedef struct {
  GObjectClass parent_class;
} XueHuaMediaCompressionLinuxPluginClass;

FLUTTER_PLUGIN_EXPORT GType xue_hua_media_compression_linux_plugin_get_type();

FLUTTER_PLUGIN_EXPORT void
xue_hua_media_compression_linux_plugin_register_with_registrar(
    FlPluginRegistrar* registrar);

G_END_DECLS

#endif  // FLUTTER_PLUGIN_XUE_HUA_MEDIA_COMPRESSION_LINUX_PLUGIN_H_
