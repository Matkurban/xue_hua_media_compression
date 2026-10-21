#ifndef XUE_HUA_MEDIA_COMPRESSION_WINDOWS_IMAGE_WIC_H_
#define XUE_HUA_MEDIA_COMPRESSION_WINDOWS_IMAGE_WIC_H_

#include <flutter/encodable_value.h>

#include <string>
#include <vector>

#include "messages.g.h"

namespace xue_hua_media_compression {

ImageCapabilitiesMsg QueryImageCapabilitiesWic();

flutter::EncodableMap CompressImageWic(const SourceMsg& source,
                                       const DestinationMsg& destination,
                                       const ImageOptionsMsg& options);

std::wstring Utf8ToWide(const std::string& utf8);
std::string WideToUtf8(const std::wstring& wide);

}  // namespace xue_hua_media_compression

#endif  // XUE_HUA_MEDIA_COMPRESSION_WINDOWS_IMAGE_WIC_H_
