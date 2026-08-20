#ifndef XUE_HUA_MEDIA_COMPRESSION_LINUX_IMAGE_VIPS_H_
#define XUE_HUA_MEDIA_COMPRESSION_LINUX_IMAGE_VIPS_H_

#include <flutter_linux/flutter_linux.h>

#include "messages.g.h"

XhMcImageCapabilitiesMsg* query_image_capabilities_vips();

// Returns a result map (transfer full) or sets code/message and returns null.
FlValue* compress_image_vips(XhMcSourceMsg* source,
                             XhMcDestinationMsg* destination,
                             XhMcImageOptionsMsg* options, char** code,
                             char** message);

#endif  // XUE_HUA_MEDIA_COMPRESSION_LINUX_IMAGE_VIPS_H_
