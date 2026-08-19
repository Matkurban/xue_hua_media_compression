#include "image_vips.h"

#include <vips/vips.h>
#include <glib/gstdio.h>

#include <algorithm>
#include <cstring>
#include <string>
#include <vector>

namespace {

bool HasOp(const char* name) { return vips_type_find("VipsOperation", name) != 0; }

void SetError(char** code, char** message, const char* c, const char* m) {
  if (code) *code = g_strdup(c);
  if (message) *message = g_strdup(m);
}

VipsImage* LoadSource(XhMcSourceMsg* source, char** code, char** message) {
  const int64_t kind = xh_mc_source_msg_get_kind(source);
  if (kind == 0) {
    size_t length = 0;
    const uint8_t* bytes = xh_mc_source_msg_get_bytes(source, &length);
    if (bytes == nullptr || length == 0) {
      SetError(code, message, "decode", "Empty image bytes");
      return nullptr;
    }
    VipsImage* image = vips_image_new_from_buffer(bytes, length, "", nullptr);
    if (image == nullptr) {
      SetError(code, message, "decode", vips_error_buffer());
      vips_error_clear();
      return nullptr;
    }
    return image;
  }
  const char* path = xh_mc_source_msg_get_path(source);
  if (path == nullptr || path[0] == '\0') {
    SetError(code, message, "notFound", "Missing source path");
    return nullptr;
  }
  if (g_str_has_prefix(path, "content://")) {
    SetError(code, message, "unsupported", "content:// is Android-only");
    return nullptr;
  }
  VipsImage* image = vips_image_new_from_file(path, nullptr);
  if (image == nullptr) {
    SetError(code, message, "notFound", vips_error_buffer());
    vips_error_clear();
  }
  return image;
}

VipsImage* ScaleIfNeeded(VipsImage* image, int64_t* max_dimension) {
  if (max_dimension == nullptr || *max_dimension <= 0) {
    return image;
  }
  const int longest = std::max(image->Xsize, image->Ysize);
  if (longest <= *max_dimension) {
    return image;
  }
  VipsImage* thumb = nullptr;
  if (vips_thumbnail_image(image, &thumb, static_cast<int>(*max_dimension),
                           nullptr)) {
    return image;
  }
  g_object_unref(image);
  return thumb;
}

int SaveImage(VipsImage* image, const std::string& format, int quality,
              const std::string& path, void** buffer, size_t* length) {
  if (format == "jpeg") {
    if (path.empty()) {
      return vips_jpegsave_buffer(image, buffer, length, "Q", quality, nullptr);
    }
    return vips_jpegsave(image, path.c_str(), "Q", quality, nullptr);
  }
  if (format == "png") {
    if (path.empty()) {
      return vips_pngsave_buffer(image, buffer, length, nullptr);
    }
    return vips_pngsave(image, path.c_str(), nullptr);
  }
  if (format == "webp") {
    if (!HasOp("webpsave")) return -2;
    if (path.empty()) {
      return vips_webpsave_buffer(image, buffer, length, "Q", quality, nullptr);
    }
    return vips_webpsave(image, path.c_str(), "Q", quality, nullptr);
  }
  return -2;
}

}  // namespace

XhMcImageCapabilitiesMsg* query_image_capabilities_vips() {
  g_autoptr(FlValue) inputs = fl_value_new_list();
  fl_value_append_take(inputs, fl_value_new_string("jpeg"));
  fl_value_append_take(inputs, fl_value_new_string("png"));
  fl_value_append_take(inputs, fl_value_new_string("gif"));
  if (HasOp("webpload")) {
    fl_value_append_take(inputs, fl_value_new_string("webp"));
  }
  if (HasOp("heifload")) {
    fl_value_append_take(inputs, fl_value_new_string("heic"));
  }
  g_autoptr(FlValue) outputs = fl_value_new_list();
  fl_value_append_take(outputs, fl_value_new_string("jpeg"));
  fl_value_append_take(outputs, fl_value_new_string("png"));
  if (HasOp("webpsave")) {
    fl_value_append_take(outputs, fl_value_new_string("webp"));
  }
  return xh_mc_image_capabilities_msg_new(inputs, outputs);
}

FlValue* compress_image_vips(XhMcSourceMsg* source,
                             XhMcDestinationMsg* destination,
                             XhMcImageOptionsMsg* options, char** code,
                             char** message) {
  const char* format = xh_mc_image_options_msg_get_format(options);
  if (g_strcmp0(format, "gif") == 0 || g_strcmp0(format, "avif") == 0 ||
      g_strcmp0(format, "heic") == 0) {
    SetError(code, message, "unsupported", "Linux cannot encode this format");
    return nullptr;
  }
  VipsImage* image = LoadSource(source, code, message);
  if (image == nullptr) {
    return nullptr;
  }
  image = ScaleIfNeeded(image, xh_mc_image_options_msg_get_max_dimension(options));
  const int quality =
      static_cast<int>(xh_mc_image_options_msg_get_quality(options));
  const int64_t kind = xh_mc_destination_msg_get_kind(destination);
  void* buffer = nullptr;
  size_t length = 0;
  std::string path;
  if (kind == 1) {
    const char* dest_path = xh_mc_destination_msg_get_path(destination);
    if (dest_path == nullptr || dest_path[0] == '\0') {
      g_object_unref(image);
      SetError(code, message, "io", "Missing destination path");
      return nullptr;
    }
    path = dest_path;
    gchar* dir = g_path_get_dirname(dest_path);
    g_mkdir_with_parents(dir, 0755);
    g_free(dir);
  }
  const int rc = SaveImage(image, format, quality, path, &buffer, &length);
  const int width = image->Xsize;
  const int height = image->Ysize;
  g_object_unref(image);
  if (rc == -2) {
    SetError(code, message, "unsupported", "Encoder not available");
    return nullptr;
  }
  if (rc != 0) {
    SetError(code, message, "encode", vips_error_buffer());
    vips_error_clear();
    return nullptr;
  }
  FlValue* map = fl_value_new_map();
  fl_value_set_string_take(map, "format", fl_value_new_string(format));
  fl_value_set_string_take(map, "width", fl_value_new_int(width));
  fl_value_set_string_take(map, "height", fl_value_new_int(height));
  if (kind == 0) {
    FlValue* bytes = fl_value_new_uint8_list(static_cast<uint8_t*>(buffer), length);
    fl_value_set_string_take(map, "bytes", bytes);
    fl_value_set_string_take(map, "sizeBytes",
                             fl_value_new_int(static_cast<int64_t>(length)));
    g_free(buffer);
  } else {
    GStatBuf st = {};
    int64_t size = 0;
    if (g_stat(path.c_str(), &st) == 0) {
      size = st.st_size;
    }
    fl_value_set_string_take(map, "outputPath", fl_value_new_string(path.c_str()));
    fl_value_set_string_take(map, "sizeBytes", fl_value_new_int(size));
  }
  return map;
}
