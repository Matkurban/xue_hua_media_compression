#include "image_wic.h"

#include <windows.h>
#include <wincodec.h>
#include <wrl/client.h>

#include <algorithm>
#include <cstdint>
#include <filesystem>
#include <stdexcept>
#include <stdio.h>
#include <system_error>
#include <vector>

#include "messages.g.h"

using Microsoft::WRL::ComPtr;

namespace xue_hua_media_compression {
namespace {

class WicError : public std::runtime_error {
 public:
  WicError(std::string code, const std::string& message)
      : std::runtime_error(message), code_(std::move(code)) {}
  const std::string& code() const { return code_; }

 private:
  std::string code_;
};

std::wstring Utf8ToWideImpl(const std::string& utf8) {
  if (utf8.empty()) return {};
  const int length = MultiByteToWideChar(CP_UTF8, 0, utf8.data(),
                                         static_cast<int>(utf8.size()),
                                         nullptr, 0);
  std::wstring wide(length, L'\0');
  MultiByteToWideChar(CP_UTF8, 0, utf8.data(), static_cast<int>(utf8.size()),
                      wide.data(), length);
  return wide;
}

bool ComponentInstalled(IWICImagingFactory* factory, DWORD kinds, REFGUID format) {
  ComPtr<IEnumUnknown> enumerator;
  if (FAILED(factory->CreateComponentEnumerator(kinds, WICComponentEnumerateDefault,
                                                enumerator.GetAddressOf()))) {
    return false;
  }
  ComPtr<IUnknown> unknown;
  ULONG fetched = 0;
  while (enumerator->Next(1, unknown.GetAddressOf(), &fetched) == S_OK && fetched) {
    ComPtr<IWICBitmapCodecInfo> info;
    if (SUCCEEDED(unknown.As(&info))) {
      GUID container = {};
      if (SUCCEEDED(info->GetContainerFormat(&container)) &&
          container == format) {
        return true;
      }
    }
    unknown.Reset();
  }
  return false;
}

GUID FormatGuid(const std::string& format) {
  if (format == "jpeg") return GUID_ContainerFormatJpeg;
  if (format == "png") return GUID_ContainerFormatPng;
  if (format == "webp") return GUID_ContainerFormatWebp;
  if (format == "heic") return GUID_ContainerFormatHeif;
  throw WicError("unsupported", "Unknown image format " + format);
}

ComPtr<IWICBitmapSource> ScaleIfNeeded(IWICImagingFactory* factory,
                                       IWICBitmapSource* source,
                                       const int64_t* max_dimension) {
  UINT width = 0;
  UINT height = 0;
  source->GetSize(&width, &height);
  if (max_dimension == nullptr || *max_dimension <= 0) {
    return source;
  }
  const UINT longest = (std::max)(width, height);
  if (longest <= static_cast<UINT>(*max_dimension)) {
    return source;
  }
  const double scale = static_cast<double>(*max_dimension) / longest;
  const UINT out_w = (std::max)(1u, static_cast<UINT>(width * scale));
  const UINT out_h = (std::max)(1u, static_cast<UINT>(height * scale));
  ComPtr<IWICBitmapScaler> scaler;
  if (FAILED(factory->CreateBitmapScaler(scaler.GetAddressOf()))) {
    throw WicError("encode", "CreateBitmapScaler failed");
  }
  if (FAILED(scaler->Initialize(source, out_w, out_h,
                                WICBitmapInterpolationModeFant))) {
    throw WicError("encode", "IWICBitmapScaler::Initialize failed");
  }
  return scaler;
}

void EncodeToStream(IWICImagingFactory* factory, IWICBitmapSource* source,
                    IWICStream* stream, const GUID& format, int quality) {
  ComPtr<IWICBitmapEncoder> encoder;
  if (FAILED(factory->CreateEncoder(format, nullptr, encoder.GetAddressOf()))) {
    throw WicError("unsupported", "No WIC encoder for requested format");
  }
  if (FAILED(encoder->Initialize(stream, WICBitmapEncoderNoCache))) {
    throw WicError("encode", "Encoder Initialize failed");
  }
  ComPtr<IWICBitmapFrameEncode> frame;
  ComPtr<IPropertyBag2> props;
  if (FAILED(encoder->CreateNewFrame(frame.GetAddressOf(), props.GetAddressOf()))) {
    throw WicError("encode", "CreateNewFrame failed");
  }
  if (props && format != GUID_ContainerFormatPng) {
    PROPBAG2 option = {};
    option.pstrName = const_cast<LPOLESTR>(L"ImageQuality");
    VARIANT value;
    VariantInit(&value);
    value.vt = VT_R4;
    value.fltVal = quality / 100.0f;
    props->Write(1, &option, &value);
    VariantClear(&value);
  }
  if (FAILED(frame->Initialize(props.Get()))) {
    throw WicError("encode", "Frame Initialize failed");
  }
  UINT width = 0;
  UINT height = 0;
  source->GetSize(&width, &height);
  frame->SetSize(width, height);
  WICPixelFormatGUID pixel_format = GUID_WICPixelFormat24bppBGR;
  frame->SetPixelFormat(&pixel_format);
  if (FAILED(frame->WriteSource(source, nullptr))) {
    throw WicError("encode", "WriteSource failed");
  }
  if (FAILED(frame->Commit()) || FAILED(encoder->Commit())) {
    throw WicError("encode", "Commit failed");
  }
}

}  // namespace

std::wstring Utf8ToWide(const std::string& utf8) { return Utf8ToWideImpl(utf8); }

std::string WideToUtf8(const std::wstring& wide) {
  if (wide.empty()) return {};
  const int length = WideCharToMultiByte(CP_UTF8, 0, wide.data(),
                                         static_cast<int>(wide.size()), nullptr,
                                         0, nullptr, nullptr);
  std::string utf8(length, '\0');
  WideCharToMultiByte(CP_UTF8, 0, wide.data(), static_cast<int>(wide.size()),
                      utf8.data(), length, nullptr, nullptr);
  return utf8;
}

ImageCapabilitiesMsg QueryImageCapabilitiesWic() {
  ComPtr<IWICImagingFactory> factory;
  if (FAILED(CoCreateInstance(CLSID_WICImagingFactory, nullptr, CLSCTX_INPROC_SERVER,
                              IID_PPV_ARGS(factory.GetAddressOf())))) {
    throw FlutterError("encode", "WIC factory unavailable");
  }
  flutter::EncodableList inputs;
  const struct {
    const char* name;
    GUID format;
  } decoded[] = {
      {"jpeg", GUID_ContainerFormatJpeg},
      {"png", GUID_ContainerFormatPng},
      {"gif", GUID_ContainerFormatGif},
      {"webp", GUID_ContainerFormatWebp},
      {"heic", GUID_ContainerFormatHeif},
  };
  for (const auto& item : decoded) {
    if (ComponentInstalled(factory.Get(), WICDecoder, item.format)) {
      inputs.push_back(flutter::EncodableValue(item.name));
    }
  }
  flutter::EncodableList outputs;
  const struct {
    const char* name;
    GUID format;
  } encoded[] = {
      {"jpeg", GUID_ContainerFormatJpeg},
      {"png", GUID_ContainerFormatPng},
      {"webp", GUID_ContainerFormatWebp},
      {"heic", GUID_ContainerFormatHeif},
  };
  for (const auto& item : encoded) {
    if (ComponentInstalled(factory.Get(), WICEncoder, item.format)) {
      outputs.push_back(flutter::EncodableValue(item.name));
    }
  }
  return ImageCapabilitiesMsg(inputs, outputs);
}

flutter::EncodableMap CompressImageWic(const SourceMsg& source,
                                       const DestinationMsg& destination,
                                       const ImageOptionsMsg& options) {
  if (options.format() == "gif" || options.format() == "avif") {
    throw FlutterError("unsupported",
                       "Windows cannot encode " + options.format());
  }
  if (source.path() && source.path()->rfind("content://", 0) == 0) {
    throw FlutterError("unsupported", "content:// is Android-only");
  }
  ComPtr<IWICImagingFactory> factory;
  if (FAILED(CoCreateInstance(CLSID_WICImagingFactory, nullptr, CLSCTX_INPROC_SERVER,
                              IID_PPV_ARGS(factory.GetAddressOf())))) {
    throw FlutterError("decode", "WIC factory unavailable");
  }
  ComPtr<IWICBitmapDecoder> decoder;
  if (source.kind() == 0) {
    const auto* bytes = source.bytes();
    if (bytes == nullptr || bytes->empty()) {
      throw FlutterError("decode", "Empty image bytes");
    }
    ComPtr<IWICStream> stream;
    factory->CreateStream(stream.GetAddressOf());
    stream->InitializeFromMemory(const_cast<BYTE*>(bytes->data()),
                                 static_cast<DWORD>(bytes->size()));
    if (FAILED(factory->CreateDecoderFromStream(
            stream.Get(), nullptr, WICDecodeMetadataCacheOnDemand,
            decoder.GetAddressOf()))) {
      throw FlutterError("decode", "CreateDecoderFromStream failed");
    }
  } else {
    if (source.path() == nullptr) {
      throw FlutterError("notFound", "Missing source path");
    }
    const std::wstring path = Utf8ToWideImpl(*source.path());
    const DWORD attrs = GetFileAttributesW(path.c_str());
    if (attrs == INVALID_FILE_ATTRIBUTES) {
      throw FlutterError("notFound", "Image not found");
    }
    if ((attrs & FILE_ATTRIBUTE_DIRECTORY) != 0) {
      throw FlutterError("io", "Image path is a directory");
    }
    const HRESULT opened = factory->CreateDecoderFromFilename(
        path.c_str(), nullptr, GENERIC_READ, WICDecodeMetadataCacheOnDemand,
        decoder.GetAddressOf());
    if (FAILED(opened)) {
      throw FlutterError("decode", "CreateDecoderFromFilename failed");
    }
  }
  ComPtr<IWICBitmapFrameDecode> frame;
  if (FAILED(decoder->GetFrame(0, frame.GetAddressOf()))) {
    throw FlutterError("decode", "GetFrame failed");
  }
  ComPtr<IWICBitmapSource> converted;
  if (FAILED(WICConvertBitmapSource(GUID_WICPixelFormat24bppBGR, frame.Get(),
                                    converted.GetAddressOf()))) {
    throw FlutterError("decode", "Pixel format convert failed");
  }
  auto scaled = ScaleIfNeeded(factory.Get(), converted.Get(), options.max_dimension());
  UINT width = 0;
  UINT height = 0;
  scaled->GetSize(&width, &height);

  GUID format = {};
  try {
    format = FormatGuid(options.format());
  } catch (const WicError& error) {
    throw FlutterError(error.code(), error.what());
  }

  ComPtr<IWICStream> out_stream;
  factory->CreateStream(out_stream.GetAddressOf());
  std::vector<uint8_t> memory;
  std::string output_path;
  if (destination.kind() == 0) {
    // Encode via a temp file then read back; WIC memory streams are awkward.
    wchar_t temp_path[MAX_PATH];
    GetTempPathW(MAX_PATH, temp_path);
    wchar_t temp_file[MAX_PATH];
    GetTempFileNameW(temp_path, L"xh", 0, temp_file);
    if (FAILED(out_stream->InitializeFromFilename(temp_file, GENERIC_WRITE))) {
      DeleteFileW(temp_file);
      throw FlutterError("io", "Unable to open a temporary image file");
    }
    try {
      EncodeToStream(factory.Get(), scaled.Get(), out_stream.Get(), format,
                     static_cast<int>(options.quality()));
    } catch (const WicError& error) {
      out_stream.Reset();
      DeleteFileW(temp_file);
      throw FlutterError(error.code(), error.what());
    }
    out_stream.Reset();
    FILE* file = nullptr;
    if (_wfopen_s(&file, temp_file, L"rb") != 0 || file == nullptr) {
      DeleteFileW(temp_file);
      throw FlutterError("io", "Unable to read the encoded image");
    }
    if (_fseeki64(file, 0, SEEK_END) != 0) {
      fclose(file);
      DeleteFileW(temp_file);
      throw FlutterError("io", "Unable to read the encoded image");
    }
    const __int64 length = _ftelli64(file);
    if (length < 0 || _fseeki64(file, 0, SEEK_SET) != 0) {
      fclose(file);
      DeleteFileW(temp_file);
      throw FlutterError("io", "Unable to read the encoded image");
    }
    memory.resize(static_cast<size_t>(length));
    if (length > 0 &&
        fread(memory.data(), 1, static_cast<size_t>(length), file) !=
            static_cast<size_t>(length)) {
      fclose(file);
      DeleteFileW(temp_file);
      throw FlutterError("io", "Unable to read the encoded image");
    }
    fclose(file);
    DeleteFileW(temp_file);
    return flutter::EncodableMap{
        {flutter::EncodableValue("bytes"), flutter::EncodableValue(memory)},
        {flutter::EncodableValue("sizeBytes"),
         flutter::EncodableValue(static_cast<int64_t>(memory.size()))},
        {flutter::EncodableValue("format"),
         flutter::EncodableValue(options.format())},
        {flutter::EncodableValue("width"),
         flutter::EncodableValue(static_cast<int64_t>(width))},
        {flutter::EncodableValue("height"),
         flutter::EncodableValue(static_cast<int64_t>(height))},
    };
  }
  if (destination.path() == nullptr) {
    throw FlutterError("io", "Missing destination path");
  }
  output_path = *destination.path();
  const std::wstring wide = Utf8ToWideImpl(output_path);
  const std::filesystem::path parent = std::filesystem::path(wide).parent_path();
  if (!parent.empty()) {
    std::error_code mkdir_error;
    const bool created = std::filesystem::create_directories(parent, mkdir_error);
    (void)created;
    if (mkdir_error) {
      throw FlutterError("io", "Unable to create destination directory");
    }
  }
  if (FAILED(out_stream->InitializeFromFilename(wide.c_str(), GENERIC_WRITE))) {
    DeleteFileW(wide.c_str());
    throw FlutterError("io", "Unable to open destination");
  }
  try {
    EncodeToStream(factory.Get(), scaled.Get(), out_stream.Get(), format,
                   static_cast<int>(options.quality()));
  } catch (const WicError& error) {
    out_stream.Reset();
    DeleteFileW(wide.c_str());
    throw FlutterError(error.code(), error.what());
  }
  WIN32_FILE_ATTRIBUTE_DATA attrs = {};
  int64_t size = 0;
  if (GetFileAttributesExW(wide.c_str(), GetFileExInfoStandard, &attrs)) {
    LARGE_INTEGER li;
    li.LowPart = attrs.nFileSizeLow;
    li.HighPart = static_cast<LONG>(attrs.nFileSizeHigh);
    size = li.QuadPart;
  }
  return flutter::EncodableMap{
      {flutter::EncodableValue("outputPath"), flutter::EncodableValue(output_path)},
      {flutter::EncodableValue("sizeBytes"), flutter::EncodableValue(size)},
      {flutter::EncodableValue("format"), flutter::EncodableValue(options.format())},
      {flutter::EncodableValue("width"),
       flutter::EncodableValue(static_cast<int64_t>(width))},
      {flutter::EncodableValue("height"),
       flutter::EncodableValue(static_cast<int64_t>(height))},
  };
}

}  // namespace xue_hua_media_compression
