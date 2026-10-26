#include "video_transcoder.h"

#include <windows.h>
#include <codecapi.h>
#include <mfapi.h>
#include <mferror.h>
#include <mfidl.h>
#include <mfreadwrite.h>
#include <oleauto.h>
#include <wrl/client.h>

#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <filesystem>
#include <string>
#include <system_error>
#include <vector>

#include "image_wic.h"

using Microsoft::WRL::ComPtr;

namespace xue_hua_media_compression {
namespace {

// The SDK name is MF_E_UNSUPPORTED_BYTESTREAM_TYPE (0xC00D36C4).
#ifndef MF_E_UNSUPPORTED_BYTESTREAM_TYPE
#define MF_E_UNSUPPORTED_BYTESTREAM_TYPE static_cast<HRESULT>(-1072875836)
#endif

constexpr LONGLONG kHundredNs = 10000000;

struct Fail {
  std::string code;
  std::string message;
};

std::string HrMessage(const char* context, HRESULT hr) {
  wchar_t* buffer = nullptr;
  const DWORD flags = FORMAT_MESSAGE_ALLOCATE_BUFFER | FORMAT_MESSAGE_FROM_SYSTEM |
                      FORMAT_MESSAGE_IGNORE_INSERTS;
  const DWORD written = FormatMessageW(
      flags, nullptr, static_cast<DWORD>(hr), 0,
      reinterpret_cast<wchar_t*>(&buffer), 0, nullptr);
  std::string message = context;
  char hex[16] = {};
  sprintf_s(hex, "%08lX", static_cast<unsigned long>(hr));
  message += " (0x";
  message += hex;
  message += ")";
  if (written > 0 && buffer != nullptr) {
    std::wstring wide(buffer, written);
    while (!wide.empty() && (wide.back() == L'\r' || wide.back() == L'\n')) {
      wide.pop_back();
    }
    message += " ";
    message += WideToUtf8(wide);
  }
  if (buffer != nullptr) {
    LocalFree(buffer);
  }
  return message;
}

bool EnsureMf(std::string* error) {
  static const HRESULT hr = MFStartup(MF_VERSION, MFSTARTUP_NOSOCKET);
  if (FAILED(hr)) {
    if (error != nullptr) {
      *error = HrMessage("Media Foundation startup failed", hr);
    }
    return false;
  }
  return true;
}

void ReleaseActivates(IMFActivate** items, UINT32 count) {
  if (items == nullptr) {
    return;
  }
  for (UINT32 i = 0; i < count; ++i) {
    if (items[i] != nullptr) {
      items[i]->Release();
    }
  }
  CoTaskMemFree(items);
}

bool HasTransform(const GUID& category, const GUID& major, const GUID& subtype,
                  bool hardware_only) {
  MFT_REGISTER_TYPE_INFO output_type = {};
  output_type.guidMajorType = major;
  output_type.guidSubtype = subtype;
  UINT32 flags = MFT_ENUM_FLAG_SORTANDFILTER | MFT_ENUM_FLAG_LOCALMFT |
                 MFT_ENUM_FLAG_SYNCMFT | MFT_ENUM_FLAG_ASYNCMFT |
                 MFT_ENUM_FLAG_TRANSCODE_ONLY;
  if (hardware_only) {
    flags = MFT_ENUM_FLAG_SORTANDFILTER | MFT_ENUM_FLAG_HARDWARE |
            MFT_ENUM_FLAG_SYNCMFT | MFT_ENUM_FLAG_ASYNCMFT |
            MFT_ENUM_FLAG_TRANSCODE_ONLY;
  }
  IMFActivate** items = nullptr;
  UINT32 count = 0;
  const HRESULT hr =
      MFTEnumEx(category, flags, nullptr, &output_type, &items, &count);
  ReleaseActivates(items, count);
  return SUCCEEDED(hr) && count > 0;
}

bool RegularFile(const std::wstring& path) {
  const DWORD attrs = GetFileAttributesW(path.c_str());
  if (attrs == INVALID_FILE_ATTRIBUTES) {
    return false;
  }
  return (attrs & FILE_ATTRIBUTE_DIRECTORY) == 0;
}

void DeletePath(const std::wstring& path) {
  if (!path.empty()) {
    DeleteFileW(path.c_str());
  }
}

uint32_t EvenDim(uint32_t value) {
  if (value < 2) {
    return 2;
  }
  return value & ~1u;
}

BYTE ClampByte(int value) {
  if (value < 0) {
    return 0;
  }
  if (value > 255) {
    return 255;
  }
  return static_cast<BYTE>(value);
}

bool CopyRgb32(const BYTE* data, LONG stride, UINT width, UINT height,
               std::vector<BYTE>* packed) {
  if (data == nullptr || width == 0 || height == 0 || packed == nullptr) {
    return false;
  }
  const LONG abs_stride = stride >= 0 ? stride : -stride;
  if (abs_stride < static_cast<LONG>(width * 4)) {
    return false;
  }
  const BYTE* row = data;
  LONG step = stride;
  if (stride < 0) {
    row = data + static_cast<size_t>(abs_stride) * (height - 1);
    step = -abs_stride;
  }
  packed->resize(static_cast<size_t>(width) * height * 4);
  for (UINT y = 0; y < height; ++y) {
    memcpy(packed->data() + static_cast<size_t>(y) * width * 4, row,
           static_cast<size_t>(width) * 4);
    row += step;
  }
  return true;
}

bool CopyNv12(const BYTE* data, LONG stride, UINT width, UINT height,
              std::vector<BYTE>* packed) {
  if (data == nullptr || stride <= 0 || width == 0 || height == 0 ||
      (width % 2u) != 0 || (height % 2u) != 0 || packed == nullptr) {
    return false;
  }
  if (stride < static_cast<LONG>(width)) {
    return false;
  }
  const size_t y_bytes = static_cast<size_t>(width) * height;
  packed->resize(y_bytes + y_bytes / 2);
  for (UINT y = 0; y < height; ++y) {
    memcpy(packed->data() + static_cast<size_t>(y) * width,
           data + static_cast<size_t>(y) * static_cast<size_t>(stride), width);
  }
  const BYTE* uv = data + static_cast<size_t>(stride) * height;
  BYTE* dst_uv = packed->data() + y_bytes;
  for (UINT y = 0; y < height / 2; ++y) {
    memcpy(dst_uv + static_cast<size_t>(y) * width,
           uv + static_cast<size_t>(y) * static_cast<size_t>(stride), width);
  }
  return true;
}

void ScaleRgb32(const std::vector<BYTE>& src, UINT src_w, UINT src_h,
                std::vector<BYTE>* dst, UINT dst_w, UINT dst_h) {
  dst->resize(static_cast<size_t>(dst_w) * dst_h * 4);
  if (src_w == dst_w && src_h == dst_h) {
    memcpy(dst->data(), src.data(), dst->size());
    return;
  }
  for (UINT y = 0; y < dst_h; ++y) {
    UINT sy = static_cast<UINT>(static_cast<uint64_t>(y) * src_h / dst_h);
    if (sy >= src_h) {
      sy = src_h - 1;
    }
    const BYTE* row = src.data() + static_cast<size_t>(sy) * src_w * 4;
    BYTE* out = dst->data() + static_cast<size_t>(y) * dst_w * 4;
    for (UINT x = 0; x < dst_w; ++x) {
      UINT sx = static_cast<UINT>(static_cast<uint64_t>(x) * src_w / dst_w);
      if (sx >= src_w) {
        sx = src_w - 1;
      }
      const BYTE* pixel = row + static_cast<size_t>(sx) * 4;
      out[0] = pixel[0];
      out[1] = pixel[1];
      out[2] = pixel[2];
      out[3] = pixel[3];
      out += 4;
    }
  }
}

void ScaleNv12(const std::vector<BYTE>& src, UINT src_w, UINT src_h,
               std::vector<BYTE>* dst, UINT dst_w, UINT dst_h) {
  const size_t dst_y = static_cast<size_t>(dst_w) * dst_h;
  dst->resize(dst_y + dst_y / 2);
  if (src_w == dst_w && src_h == dst_h) {
    memcpy(dst->data(), src.data(), dst->size());
    return;
  }
  const BYTE* src_y = src.data();
  const BYTE* src_uv = src.data() + static_cast<size_t>(src_w) * src_h;
  BYTE* dst_y_plane = dst->data();
  BYTE* dst_uv = dst->data() + dst_y;
  for (UINT y = 0; y < dst_h; ++y) {
    UINT sy = static_cast<UINT>(static_cast<uint64_t>(y) * src_h / dst_h);
    if (sy >= src_h) {
      sy = src_h - 1;
    }
    for (UINT x = 0; x < dst_w; ++x) {
      UINT sx = static_cast<UINT>(static_cast<uint64_t>(x) * src_w / dst_w);
      if (sx >= src_w) {
        sx = src_w - 1;
      }
      dst_y_plane[static_cast<size_t>(y) * dst_w + x] =
          src_y[static_cast<size_t>(sy) * src_w + sx];
    }
  }
  for (UINT y = 0; y < dst_h; y += 2) {
    UINT sy = static_cast<UINT>(static_cast<uint64_t>(y) * src_h / dst_h) & ~1u;
    if (sy >= src_h) {
      sy = src_h - 2;
    }
    for (UINT x = 0; x < dst_w; x += 2) {
      UINT sx = static_cast<UINT>(static_cast<uint64_t>(x) * src_w / dst_w) & ~1u;
      if (sx >= src_w) {
        sx = src_w - 2;
      }
      const BYTE* s = src_uv + static_cast<size_t>(sy / 2) * src_w + sx;
      BYTE* d = dst_uv + static_cast<size_t>(y / 2) * dst_w + x;
      d[0] = s[0];
      d[1] = s[1];
    }
  }
}

bool CopyRgb24(const BYTE* data, LONG stride, UINT width, UINT height,
               std::vector<BYTE>* packed) {
  if (data == nullptr || width == 0 || height == 0 || packed == nullptr) {
    return false;
  }
  const LONG abs_stride = stride >= 0 ? stride : -stride;
  if (abs_stride < static_cast<LONG>(width * 3)) {
    return false;
  }
  const BYTE* row = data;
  LONG step = stride;
  if (stride < 0) {
    row = data + static_cast<size_t>(abs_stride) * (height - 1);
    step = -abs_stride;
  }
  packed->resize(static_cast<size_t>(width) * height * 3);
  for (UINT y = 0; y < height; ++y) {
    memcpy(packed->data() + static_cast<size_t>(y) * width * 3, row,
           static_cast<size_t>(width) * 3);
    row += step;
  }
  return true;
}

void ScaleRgb24(const std::vector<BYTE>& src, UINT src_w, UINT src_h,
                std::vector<BYTE>* dst, UINT dst_w, UINT dst_h) {
  dst->resize(static_cast<size_t>(dst_w) * dst_h * 3);
  if (src_w == dst_w && src_h == dst_h) {
    memcpy(dst->data(), src.data(), dst->size());
    return;
  }
  for (UINT y = 0; y < dst_h; ++y) {
    UINT sy = static_cast<UINT>(static_cast<uint64_t>(y) * src_h / dst_h);
    if (sy >= src_h) {
      sy = src_h - 1;
    }
    const BYTE* row = src.data() + static_cast<size_t>(sy) * src_w * 3;
    BYTE* out = dst->data() + static_cast<size_t>(y) * dst_w * 3;
    for (UINT x = 0; x < dst_w; ++x) {
      UINT sx = static_cast<UINT>(static_cast<uint64_t>(x) * src_w / dst_w);
      if (sx >= src_w) {
        sx = src_w - 1;
      }
      const BYTE* pixel = row + static_cast<size_t>(sx) * 3;
      out[0] = pixel[0];
      out[1] = pixel[1];
      out[2] = pixel[2];
      out += 3;
    }
  }
}

void Rgb24ToNv12(const std::vector<BYTE>& rgb, UINT width, UINT height,
                 std::vector<BYTE>* nv12) {
  const size_t y_bytes = static_cast<size_t>(width) * height;
  nv12->resize(y_bytes + y_bytes / 2);
  BYTE* y_plane = nv12->data();
  BYTE* uv_plane = nv12->data() + y_bytes;
  for (UINT y = 0; y < height; ++y) {
    for (UINT x = 0; x < width; ++x) {
      const BYTE* pixel =
          rgb.data() + (static_cast<size_t>(y) * width + x) * 3;
      const int b = pixel[0];
      const int g = pixel[1];
      const int r = pixel[2];
      const int luma = ((66 * r + 129 * g + 25 * b + 128) >> 8) + 16;
      y_plane[static_cast<size_t>(y) * width + x] = ClampByte(luma);
      if ((y % 2u) == 0 && (x % 2u) == 0) {
        const int u = ((-38 * r - 74 * g + 112 * b + 128) >> 8) + 128;
        const int v = ((112 * r - 94 * g - 18 * b + 128) >> 8) + 128;
        BYTE* uv = uv_plane + static_cast<size_t>(y / 2) * width + x;
        uv[0] = ClampByte(u);
        uv[1] = ClampByte(v);
      }
    }
  }
}

void Rgb32ToNv12(const std::vector<BYTE>& rgb, UINT width, UINT height,
                 std::vector<BYTE>* nv12) {
  const size_t y_bytes = static_cast<size_t>(width) * height;
  nv12->resize(y_bytes + y_bytes / 2);
  BYTE* y_plane = nv12->data();
  BYTE* uv_plane = nv12->data() + y_bytes;
  for (UINT y = 0; y < height; ++y) {
    for (UINT x = 0; x < width; ++x) {
      const BYTE* pixel =
          rgb.data() + (static_cast<size_t>(y) * width + x) * 4;
      const int b = pixel[0];
      const int g = pixel[1];
      const int r = pixel[2];
      const int luma = ((66 * r + 129 * g + 25 * b + 128) >> 8) + 16;
      y_plane[static_cast<size_t>(y) * width + x] = ClampByte(luma);
      if ((y % 2u) == 0 && (x % 2u) == 0) {
        const int u = ((-38 * r - 74 * g + 112 * b + 128) >> 8) + 128;
        const int v = ((112 * r - 94 * g - 18 * b + 128) >> 8) + 128;
        BYTE* uv = uv_plane + static_cast<size_t>(y / 2) * width + x;
        uv[0] = ClampByte(u);
        uv[1] = ClampByte(v);
      }
    }
  }
}

HRESULT CreateSample(const std::vector<BYTE>& bytes, LONGLONG time,
                     LONGLONG duration, IMFSample** sample_out) {
  ComPtr<IMFMediaBuffer> buffer;
  HRESULT hr = MFCreateMemoryBuffer(static_cast<DWORD>(bytes.size()),
                                     buffer.GetAddressOf());
  if (FAILED(hr)) {
    return hr;
  }
  BYTE* data = nullptr;
  hr = buffer->Lock(&data, nullptr, nullptr);
  if (FAILED(hr)) {
    return hr;
  }
  memcpy(data, bytes.data(), bytes.size());
  buffer->Unlock();
  hr = buffer->SetCurrentLength(static_cast<DWORD>(bytes.size()));
  if (FAILED(hr)) {
    return hr;
  }
  ComPtr<IMFSample> sample;
  hr = MFCreateSample(sample.GetAddressOf());
  if (FAILED(hr)) {
    return hr;
  }
  hr = sample->AddBuffer(buffer.Get());
  if (FAILED(hr)) {
    return hr;
  }
  hr = sample->SetSampleTime(time);
  if (FAILED(hr)) {
    return hr;
  }
  hr = sample->SetSampleDuration(duration);
  if (FAILED(hr)) {
    return hr;
  }
  *sample_out = sample.Detach();
  return S_OK;
}

enum class PixelLayout { kRgb32, kRgb24, kNv12 };

struct FrameInfo {
  UINT width = 0;
  UINT height = 0;
  UINT fps_num = 30;
  UINT fps_den = 1;
  LONGLONG duration = 0;
  PixelLayout layout = PixelLayout::kRgb32;
  LONG stride = 0;
};

bool SetVideoSubtype(IMFSourceReader* reader, const GUID& subtype) {
  ComPtr<IMFMediaType> type;
  if (FAILED(MFCreateMediaType(type.GetAddressOf()))) {
    return false;
  }
  type->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
  type->SetGUID(MF_MT_SUBTYPE, subtype);
  return SUCCEEDED(reader->SetCurrentMediaType(
      static_cast<DWORD>(MF_SOURCE_READER_FIRST_VIDEO_STREAM), nullptr,
      type.Get()));
}

LONG SignedStride(UINT32 bits) {
  INT32 signed_stride = 0;
  memcpy(&signed_stride, &bits, sizeof(signed_stride));
  return signed_stride;
}

HRESULT ConfigureVideoType(IMFSourceReader* reader, FrameInfo* info) {
  ComPtr<IMFMediaType> native;
  HRESULT hr = reader->GetNativeMediaType(
      static_cast<DWORD>(MF_SOURCE_READER_FIRST_VIDEO_STREAM), 0,
      native.GetAddressOf());
  if (FAILED(hr)) {
    return hr;
  }
  MFGetAttributeSize(native.Get(), MF_MT_FRAME_SIZE, &info->width, &info->height);
  UINT32 num = 0;
  UINT32 den = 0;
  if (SUCCEEDED(MFGetAttributeRatio(native.Get(), MF_MT_FRAME_RATE, &num, &den)) &&
      num > 0 && den > 0) {
    info->fps_num = num;
    info->fps_den = den;
  }
  GUID native_subtype = GUID_NULL;
  native->GetGUID(MF_MT_SUBTYPE, &native_subtype);

  const bool uncompressed = native_subtype == MFVideoFormat_RGB32 ||
                            native_subtype == MFVideoFormat_RGB24 ||
                            native_subtype == MFVideoFormat_NV12;
  if (uncompressed && SetVideoSubtype(reader, native_subtype)) {
    if (native_subtype == MFVideoFormat_NV12) {
      info->layout = PixelLayout::kNv12;
    } else if (native_subtype == MFVideoFormat_RGB24) {
      info->layout = PixelLayout::kRgb24;
    } else {
      info->layout = PixelLayout::kRgb32;
    }
  } else if (SetVideoSubtype(reader, MFVideoFormat_RGB32)) {
    info->layout = PixelLayout::kRgb32;
  } else if (SetVideoSubtype(reader, MFVideoFormat_NV12)) {
    info->layout = PixelLayout::kNv12;
  } else {
    return E_FAIL;
  }

  ComPtr<IMFMediaType> current;
  hr = reader->GetCurrentMediaType(
      static_cast<DWORD>(MF_SOURCE_READER_FIRST_VIDEO_STREAM),
      current.GetAddressOf());
  if (FAILED(hr)) {
    return hr;
  }
  MFGetAttributeSize(current.Get(), MF_MT_FRAME_SIZE, &info->width, &info->height);
  UINT32 stride_bits = 0;
  if (SUCCEEDED(current->GetUINT32(MF_MT_DEFAULT_STRIDE, &stride_bits)) &&
      stride_bits != 0) {
    info->stride = SignedStride(stride_bits);
  } else if (info->layout == PixelLayout::kNv12) {
    info->stride = static_cast<LONG>(info->width);
  } else if (info->layout == PixelLayout::kRgb24) {
    info->stride = static_cast<LONG>((info->width * 3u + 3u) & ~3u);
  } else {
    info->stride = static_cast<LONG>(info->width * 4u);
  }
  if (info->stride == 0) {
    return E_FAIL;
  }
  return S_OK;
}

struct AudioInfo {
  bool present = false;
  UINT32 rate = 48000;
  UINT32 channels = 2;
  UINT32 bits = 16;
};

HRESULT ConfigureAudio(IMFSourceReader* reader, AudioInfo* audio) {
  ComPtr<IMFMediaType> native;
  HRESULT hr = reader->GetNativeMediaType(
      static_cast<DWORD>(MF_SOURCE_READER_FIRST_AUDIO_STREAM), 0,
      native.GetAddressOf());
  if (FAILED(hr)) {
    audio->present = false;
    return S_OK;
  }
  audio->present = true;
  UINT32 rate = 0;
  UINT32 channels = 0;
  if (SUCCEEDED(native->GetUINT32(MF_MT_AUDIO_SAMPLES_PER_SECOND, &rate)) &&
      rate > 0) {
    audio->rate = rate;
  }
  if (SUCCEEDED(native->GetUINT32(MF_MT_AUDIO_NUM_CHANNELS, &channels)) &&
      channels > 0) {
    audio->channels = channels;
  }
  ComPtr<IMFMediaType> pcm;
  MFCreateMediaType(pcm.GetAddressOf());
  pcm->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Audio);
  pcm->SetGUID(MF_MT_SUBTYPE, MFAudioFormat_PCM);
  pcm->SetUINT32(MF_MT_AUDIO_BITS_PER_SAMPLE, 16);
  pcm->SetUINT32(MF_MT_AUDIO_SAMPLES_PER_SECOND, audio->rate);
  pcm->SetUINT32(MF_MT_AUDIO_NUM_CHANNELS, audio->channels);
  pcm->SetUINT32(MF_MT_AUDIO_BLOCK_ALIGNMENT, audio->channels * 2);
  pcm->SetUINT32(MF_MT_AUDIO_AVG_BYTES_PER_SECOND, audio->rate * audio->channels * 2);
  hr = reader->SetCurrentMediaType(
      static_cast<DWORD>(MF_SOURCE_READER_FIRST_AUDIO_STREAM), nullptr, pcm.Get());
  if (FAILED(hr)) {
    return hr;
  }
  ComPtr<IMFMediaType> current;
  hr = reader->GetCurrentMediaType(
      static_cast<DWORD>(MF_SOURCE_READER_FIRST_AUDIO_STREAM),
      current.GetAddressOf());
  if (FAILED(hr)) {
    return hr;
  }
  UINT32 bits = 16;
  current->GetUINT32(MF_MT_AUDIO_BITS_PER_SAMPLE, &bits);
  current->GetUINT32(MF_MT_AUDIO_SAMPLES_PER_SECOND, &audio->rate);
  current->GetUINT32(MF_MT_AUDIO_NUM_CHANNELS, &audio->channels);
  audio->bits = bits;
  if (audio->bits != 16 || audio->rate == 0 || audio->channels == 0) {
    return MF_E_INVALIDMEDIATYPE;
  }
  return S_OK;
}

HRESULT AddVideoStreams(IMFSinkWriter* writer, const GUID& subtype, UINT width,
                        UINT height, UINT fps, uint32_t bitrate,
                        const int64_t* gop, DWORD* stream_index) {
  ComPtr<IMFMediaType> out_type;
  HRESULT hr = MFCreateMediaType(out_type.GetAddressOf());
  if (FAILED(hr)) {
    return hr;
  }
  out_type->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
  out_type->SetGUID(MF_MT_SUBTYPE, subtype);
  out_type->SetUINT32(MF_MT_AVG_BITRATE, bitrate);
  hr = MFSetAttributeSize(out_type.Get(), MF_MT_FRAME_SIZE, width, height);
  if (FAILED(hr)) {
    return hr;
  }
  hr = MFSetAttributeRatio(out_type.Get(), MF_MT_FRAME_RATE, fps, 1);
  if (FAILED(hr)) {
    return hr;
  }
  hr = MFSetAttributeRatio(out_type.Get(), MF_MT_PIXEL_ASPECT_RATIO, 1, 1);
  if (FAILED(hr)) {
    return hr;
  }
  out_type->SetUINT32(MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive);
  if (subtype == MFVideoFormat_H264) {
    out_type->SetUINT32(MF_MT_MPEG2_PROFILE,
                        static_cast<UINT32>(eAVEncH264VProfile_Base));
  }
  if (gop != nullptr && *gop > 0 && fps > 0) {
    const UINT64 spacing =
        static_cast<UINT64>(*gop) * static_cast<UINT64>(kHundredNs) / fps;
    out_type->SetUINT64(MF_MT_MAX_KEYFRAME_SPACING, spacing == 0 ? 1 : spacing);
  }
  hr = writer->AddStream(out_type.Get(), stream_index);
  if (FAILED(hr)) {
    return hr;
  }
  ComPtr<IMFMediaType> in_type;
  hr = MFCreateMediaType(in_type.GetAddressOf());
  if (FAILED(hr)) {
    return hr;
  }
  in_type->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
  in_type->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_NV12);
  hr = MFSetAttributeSize(in_type.Get(), MF_MT_FRAME_SIZE, width, height);
  if (FAILED(hr)) {
    return hr;
  }
  hr = MFSetAttributeRatio(in_type.Get(), MF_MT_FRAME_RATE, fps, 1);
  if (FAILED(hr)) {
    return hr;
  }
  hr = MFSetAttributeRatio(in_type.Get(), MF_MT_PIXEL_ASPECT_RATIO, 1, 1);
  if (FAILED(hr)) {
    return hr;
  }
  in_type->SetUINT32(MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive);
  in_type->SetUINT32(MF_MT_DEFAULT_STRIDE, width);
  ComPtr<IMFAttributes> encode_params;
  if (gop != nullptr && *gop > 0) {
    if (SUCCEEDED(MFCreateAttributes(encode_params.GetAddressOf(), 2)) &&
        encode_params) {
      const uint32_t gop_frames =
          *gop > static_cast<int64_t>(UINT32_MAX)
              ? UINT32_MAX
              : static_cast<uint32_t>(*gop);
      encode_params->SetUINT32(CODECAPI_AVEncMPVGOPSize, gop_frames);
      encode_params->SetUINT32(CODECAPI_AVEncMPVDefaultBPictureCount, 0);
    }
  }
  return writer->SetInputMediaType(*stream_index, in_type.Get(),
                                   encode_params.Get());
}

HRESULT AddAudioStream(IMFSinkWriter* writer, const AudioInfo& audio,
                       DWORD* stream_index) {
  ComPtr<IMFMediaType> out_type;
  HRESULT hr = MFCreateMediaType(out_type.GetAddressOf());
  if (FAILED(hr)) {
    return hr;
  }
  out_type->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Audio);
  out_type->SetGUID(MF_MT_SUBTYPE, MFAudioFormat_AAC);
  out_type->SetUINT32(MF_MT_AUDIO_BITS_PER_SAMPLE, 16);
  out_type->SetUINT32(MF_MT_AUDIO_SAMPLES_PER_SECOND, audio.rate);
  out_type->SetUINT32(MF_MT_AUDIO_NUM_CHANNELS, audio.channels);
  out_type->SetUINT32(MF_MT_AUDIO_AVG_BYTES_PER_SECOND, 16000);
  out_type->SetUINT32(MF_MT_AUDIO_BLOCK_ALIGNMENT, 1);
  out_type->SetUINT32(MF_MT_AAC_PAYLOAD_TYPE, 0);
  out_type->SetUINT32(MF_MT_AAC_AUDIO_PROFILE_LEVEL_INDICATION, 0x29);
  hr = writer->AddStream(out_type.Get(), stream_index);
  if (FAILED(hr)) {
    return hr;
  }
  ComPtr<IMFMediaType> in_type;
  hr = MFCreateMediaType(in_type.GetAddressOf());
  if (FAILED(hr)) {
    return hr;
  }
  const UINT32 block = audio.channels * 2;
  in_type->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Audio);
  in_type->SetGUID(MF_MT_SUBTYPE, MFAudioFormat_PCM);
  in_type->SetUINT32(MF_MT_AUDIO_BITS_PER_SAMPLE, 16);
  in_type->SetUINT32(MF_MT_AUDIO_SAMPLES_PER_SECOND, audio.rate);
  in_type->SetUINT32(MF_MT_AUDIO_NUM_CHANNELS, audio.channels);
  in_type->SetUINT32(MF_MT_AUDIO_BLOCK_ALIGNMENT, block);
  in_type->SetUINT32(MF_MT_AUDIO_AVG_BYTES_PER_SECOND, audio.rate * block);
  return writer->SetInputMediaType(*stream_index, in_type.Get(), nullptr);
}

bool KeepFrame(LONGLONG timestamp, int written, LONGLONG out_duration,
               LONGLONG* next_pts) {
  if (written == 0) {
    *next_pts = out_duration;
    return true;
  }
  if (timestamp + out_duration / 4 < *next_pts) {
    return false;
  }
  *next_pts += out_duration;
  return true;
}

HRESULT ReadVideo(IMFSourceReader* reader, IMFSinkWriter* writer, DWORD stream,
                  const FrameInfo& info, UINT out_w, UINT out_h, UINT target_fps,
                  const std::atomic<bool>& cancelled,
                  const std::function<void(double)>& on_progress,
                  int* written_out) {
  const LONGLONG src_duration =
      info.fps_num == 0
          ? kHundredNs / target_fps
          : kHundredNs * static_cast<LONGLONG>(info.fps_den) / info.fps_num;
  const LONGLONG out_duration = kHundredNs / target_fps;
  LONGLONG next_pts = 0;
  LONGLONG last_ts = -1;
  int frame_index = 0;
  int written = 0;
  for (;;) {
    if (cancelled.load()) {
      return HRESULT_FROM_WIN32(ERROR_CANCELLED);
    }
    DWORD flags = 0;
    LONGLONG timestamp = 0;
    ComPtr<IMFSample> sample;
    const HRESULT hr = reader->ReadSample(
        static_cast<DWORD>(MF_SOURCE_READER_FIRST_VIDEO_STREAM), 0, nullptr,
        &flags, &timestamp, sample.GetAddressOf());
    if (FAILED(hr)) {
      return hr;
    }
    if ((flags & MF_SOURCE_READERF_ENDOFSTREAM) != 0) {
      break;
    }
    if ((flags & MF_SOURCE_READERF_ERROR) != 0) {
      return E_FAIL;
    }
    if (sample == nullptr) {
      continue;
    }
    LONGLONG effective = timestamp;
    if (frame_index > 0 && effective <= last_ts) {
      effective = static_cast<LONGLONG>(frame_index) * src_duration;
    }
    if (effective < 0) {
      effective = static_cast<LONGLONG>(frame_index) * src_duration;
    }
    last_ts = effective;
    const int current_index = frame_index;
    ++frame_index;
    if (!KeepFrame(effective, written, out_duration, &next_pts)) {
      continue;
    }
    ComPtr<IMFMediaBuffer> buffer;
    HRESULT lock_hr = sample->ConvertToContiguousBuffer(buffer.GetAddressOf());
    if (FAILED(lock_hr)) {
      return lock_hr;
    }
    BYTE* data = nullptr;
    DWORD length = 0;
    lock_hr = buffer->Lock(&data, nullptr, &length);
    if (FAILED(lock_hr)) {
      return lock_hr;
    }
    std::vector<BYTE> packed;
    bool copied = false;
    if (info.layout == PixelLayout::kNv12) {
      copied = CopyNv12(data, info.stride, info.width, info.height, &packed);
    } else if (info.layout == PixelLayout::kRgb24) {
      copied = CopyRgb24(data, info.stride, info.width, info.height, &packed);
    } else {
      copied = CopyRgb32(data, info.stride, info.width, info.height, &packed);
    }
    buffer->Unlock();
    if (!copied) {
      return MF_E_INVALIDMEDIATYPE;
    }
    std::vector<BYTE> scaled;
    std::vector<BYTE> nv12;
    const std::vector<BYTE>* encoded = nullptr;
    if (info.layout == PixelLayout::kNv12) {
      ScaleNv12(packed, info.width, info.height, &scaled, out_w, out_h);
      encoded = &scaled;
    } else if (info.layout == PixelLayout::kRgb24) {
      ScaleRgb24(packed, info.width, info.height, &scaled, out_w, out_h);
      Rgb24ToNv12(scaled, out_w, out_h, &nv12);
      encoded = &nv12;
    } else {
      ScaleRgb32(packed, info.width, info.height, &scaled, out_w, out_h);
      Rgb32ToNv12(scaled, out_w, out_h, &nv12);
      encoded = &nv12;
    }
    ComPtr<IMFSample> out_sample;
    const LONGLONG time = static_cast<LONGLONG>(written) * out_duration;
    lock_hr = CreateSample(*encoded, time, out_duration, out_sample.GetAddressOf());
    if (FAILED(lock_hr)) {
      return lock_hr;
    }
    lock_hr = writer->WriteSample(stream, out_sample.Get());
    if (FAILED(lock_hr)) {
      return lock_hr;
    }
    ++written;
    double progress = 0;
    if (info.duration > 0) {
      progress = static_cast<double>(effective) / static_cast<double>(info.duration);
    } else if (frame_index > 0) {
      progress = static_cast<double>(current_index + 1) /
                 static_cast<double>(frame_index + 8);
    }
    if (progress < 0) {
      progress = 0;
    }
    if (progress > 0.99) {
      progress = 0.99;
    }
    on_progress(progress);
  }
  if (written == 0) {
    return MF_E_INVALID_STREAM_DATA;
  }
  *written_out = written;
  return S_OK;
}

HRESULT ReadAudio(IMFSourceReader* reader, IMFSinkWriter* writer, DWORD stream,
                  const AudioInfo& audio, const std::atomic<bool>& cancelled) {
  LONGLONG cursor = 0;
  const UINT32 block = audio.channels * 2;
  for (;;) {
    if (cancelled.load()) {
      return HRESULT_FROM_WIN32(ERROR_CANCELLED);
    }
    DWORD flags = 0;
    ComPtr<IMFSample> sample;
    const HRESULT hr = reader->ReadSample(
        static_cast<DWORD>(MF_SOURCE_READER_FIRST_AUDIO_STREAM), 0, nullptr,
        &flags, nullptr, sample.GetAddressOf());
    if (FAILED(hr)) {
      return hr;
    }
    if ((flags & MF_SOURCE_READERF_ENDOFSTREAM) != 0) {
      break;
    }
    if (sample == nullptr) {
      continue;
    }
    LONGLONG time = 0;
    if (FAILED(sample->GetSampleTime(&time))) {
      sample->SetSampleTime(cursor);
      time = cursor;
    }
    LONGLONG duration = 0;
    if (FAILED(sample->GetSampleDuration(&duration)) || duration <= 0) {
      DWORD length = 0;
      sample->GetTotalLength(&length);
      if (block > 0 && audio.rate > 0 && length > 0) {
        duration = static_cast<LONGLONG>(length / block) * kHundredNs /
                   static_cast<LONGLONG>(audio.rate);
      }
      if (duration <= 0) {
        duration = 1;
      }
      sample->SetSampleDuration(duration);
    }
    cursor = time + duration;
    const HRESULT write_hr = writer->WriteSample(stream, sample.Get());
    if (FAILED(write_hr)) {
      return write_hr;
    }
  }
  return S_OK;
}

Fail MapReadError(HRESULT hr, bool audio) {
  if (hr == HRESULT_FROM_WIN32(ERROR_CANCELLED)) {
    return Fail{"cancelled", "Cancelled"};
  }
  if (hr == MF_E_INVALIDMEDIATYPE || hr == MF_E_INVALID_STREAM_DATA ||
      hr == MF_E_UNSUPPORTED_BYTESTREAM_TYPE || hr == MF_E_INVALID_FILE_FORMAT) {
    return Fail{audio ? "decode" : "decode",
                HrMessage(audio ? "Unable to decode audio" : "Unable to decode video",
                          hr)};
  }
  return Fail{"encode", HrMessage("Video encode failed", hr)};
}

}  // namespace

VideoCapabilitiesMsg QueryVideoCapabilitiesWin() {
  flutter::EncodableList codecs;
  std::string startup_error;
  if (!EnsureMf(&startup_error)) {
    return VideoCapabilitiesMsg(codecs, false);
  }
  const bool h264 =
      HasTransform(MFT_CATEGORY_VIDEO_ENCODER, MFMediaType_Video, MFVideoFormat_H264,
                   false);
  const bool h265 =
      HasTransform(MFT_CATEGORY_VIDEO_ENCODER, MFMediaType_Video, MFVideoFormat_HEVC,
                   false);
  const bool h264_hw =
      HasTransform(MFT_CATEGORY_VIDEO_ENCODER, MFMediaType_Video, MFVideoFormat_H264,
                   true);
  const bool h265_hw =
      HasTransform(MFT_CATEGORY_VIDEO_ENCODER, MFMediaType_Video, MFVideoFormat_HEVC,
                   true);
  if (h264) {
    codecs.push_back(flutter::EncodableValue("h264"));
  }
  if (h265) {
    codecs.push_back(flutter::EncodableValue("h265"));
  }
  if ((h264_hw || h265_hw) && !codecs.empty()) {
    const std::string name = "MediaFoundationHW";
    return VideoCapabilitiesMsg(&name, codecs, false);
  }
  return VideoCapabilitiesMsg(codecs, false);
}

void CompressVideoWindows(
    const std::string& input_path, const std::string& output_path,
    const VideoOptionsMsg& options, const std::atomic<bool>& cancelled,
    std::atomic<bool>* output_opened,
    const std::function<void(double)>& on_progress,
    const std::function<void(const flutter::EncodableMap&)>& on_completed,
    const std::function<void(const std::string&, const std::string&)>& on_error) {
  auto fail = [&](const std::string& code, const std::string& message) {
    if (output_opened != nullptr && output_opened->exchange(false)) {
      DeletePath(Utf8ToWide(output_path));
    }
    if (cancelled.load() || code == "cancelled") {
      on_error("cancelled", "Cancelled");
      return;
    }
    on_error(code, message);
  };

  if (input_path.rfind("content://", 0) == 0) {
    fail("unsupported", "content:// is Android-only");
    return;
  }
  const bool hevc = options.codec() == "h265";
  if (options.codec() != "h264" && !hevc) {
    fail("unsupported", "Unsupported video codec " + options.codec());
    return;
  }
  const std::wstring input_wide = Utf8ToWide(input_path);
  const std::wstring output_wide = Utf8ToWide(output_path);
  if (input_wide.empty() || !RegularFile(input_wide)) {
    fail("notFound", "Video not found");
    return;
  }
  std::string startup_error;
  if (!EnsureMf(&startup_error)) {
    fail("encode", startup_error);
    return;
  }
  const GUID subtype = hevc ? MFVideoFormat_HEVC : MFVideoFormat_H264;
  if (!HasTransform(MFT_CATEGORY_VIDEO_ENCODER, MFMediaType_Video, subtype, false)) {
    fail("hardwareUnavailable",
         hevc ? "No H.265 encoder is installed" : "No H.264 encoder is installed");
    return;
  }
  if (cancelled.load()) {
    fail("cancelled", "Cancelled");
    return;
  }

  const bool want_hardware =
      HasTransform(MFT_CATEGORY_VIDEO_ENCODER, MFMediaType_Video, subtype, true);
  std::string last_error = "Video encode failed";
  bool used_hardware = false;
  UINT out_w = 0;
  UINT out_h = 0;
  const int attempts = want_hardware ? 2 : 1;
  for (int attempt = 0; attempt < attempts; ++attempt) {
    const bool hardware = want_hardware && attempt == 0;
    if (output_opened != nullptr && output_opened->exchange(false)) {
      DeletePath(output_wide);
    }
    ComPtr<IMFAttributes> reader_attrs;
    MFCreateAttributes(reader_attrs.GetAddressOf(), 2);
    if (reader_attrs) {
      reader_attrs->SetUINT32(MF_SOURCE_READER_ENABLE_VIDEO_PROCESSING, TRUE);
    }
    ComPtr<IMFSourceReader> reader;
    HRESULT hr = MFCreateSourceReaderFromURL(input_wide.c_str(), reader_attrs.Get(),
                                              reader.GetAddressOf());
    if (FAILED(hr)) {
      last_error = HrMessage("Unable to open video", hr);
      fail("decode", last_error);
      return;
    }
    reader->SetStreamSelection(static_cast<DWORD>(MF_SOURCE_READER_ALL_STREAMS),
                               FALSE);
    reader->SetStreamSelection(
        static_cast<DWORD>(MF_SOURCE_READER_FIRST_VIDEO_STREAM), TRUE);
    reader->SetStreamSelection(
        static_cast<DWORD>(MF_SOURCE_READER_FIRST_AUDIO_STREAM), TRUE);
    FrameInfo frame;
    hr = ConfigureVideoType(reader.Get(), &frame);
    if (FAILED(hr) || frame.width == 0 || frame.height == 0 || frame.width > 16384 ||
        frame.height > 16384) {
      fail("decode", HrMessage("Unable to decode video", FAILED(hr) ? hr : E_FAIL));
      return;
    }
    PROPVARIANT duration_var;
    PropVariantInit(&duration_var);
    if (SUCCEEDED(reader->GetPresentationAttribute(
            static_cast<DWORD>(MF_SOURCE_READER_MEDIASOURCE), MF_PD_DURATION,
            &duration_var)) &&
        duration_var.vt == VT_UI8) {
      frame.duration = static_cast<LONGLONG>(duration_var.uhVal.QuadPart);
    }
    PropVariantClear(&duration_var);

    AudioInfo audio;
    const bool keep_audio = options.keep_audio();
    hr = ConfigureAudio(reader.Get(), &audio);
    if (FAILED(hr)) {
      fail("decode", HrMessage("Unable to decode audio", hr));
      return;
    }
    if (keep_audio && audio.present &&
        !HasTransform(MFT_CATEGORY_AUDIO_ENCODER, MFMediaType_Audio,
                      MFAudioFormat_AAC, false)) {
      fail("unsupported", "keepAudio requires an AAC encoder");
      return;
    }
    const bool with_audio = keep_audio && audio.present;
    if (!with_audio) {
      reader->SetStreamSelection(
          static_cast<DWORD>(MF_SOURCE_READER_FIRST_AUDIO_STREAM), FALSE);
      hr = ConfigureVideoType(reader.Get(), &frame);
      if (FAILED(hr) || frame.width == 0 || frame.height == 0) {
        fail("decode", HrMessage("Unable to decode video", FAILED(hr) ? hr : E_FAIL));
        return;
      }
    }

    out_w = frame.width;
    out_h = frame.height;
    if (options.max_dimension() != nullptr && *options.max_dimension() > 0 &&
        *options.max_dimension() <= static_cast<int64_t>(UINT32_MAX)) {
      const uint32_t longest = (std::max)(out_w, out_h);
      const uint32_t limit = static_cast<uint32_t>(*options.max_dimension());
      if (longest > limit) {
        const double scale = static_cast<double>(limit) / static_cast<double>(longest);
        out_w = static_cast<UINT>(static_cast<double>(out_w) * scale);
        out_h = static_cast<UINT>(static_cast<double>(out_h) * scale);
      }
    }
    out_w = EvenDim(out_w);
    out_h = EvenDim(out_h);

    UINT target_fps = 30;
    if (frame.fps_den > 0 && frame.fps_num > 0) {
      target_fps = (std::max)(1u, (frame.fps_num + frame.fps_den / 2) / frame.fps_den);
    }
    if (options.fps() != nullptr && *options.fps() > 0) {
      const int64_t requested = *options.fps();
      target_fps = requested > 240 ? 240u : static_cast<UINT>(requested);
    }
    if (target_fps == 0) {
      target_fps = 1;
    }

    std::error_code mkdir_error;
    const std::filesystem::path parent =
        std::filesystem::path(output_wide).parent_path();
    if (!parent.empty()) {
      const bool created =
          std::filesystem::create_directories(parent, mkdir_error);
      (void)created;
      if (mkdir_error) {
        fail("io", "Unable to create destination directory");
        return;
      }
    }

    ComPtr<IMFAttributes> writer_attrs;
    MFCreateAttributes(writer_attrs.GetAddressOf(), 3);
    if (writer_attrs) {
      writer_attrs->SetUINT32(MF_READWRITE_ENABLE_HARDWARE_TRANSFORMS,
                              hardware ? TRUE : FALSE);
      writer_attrs->SetUINT32(MF_SINK_WRITER_DISABLE_THROTTLING, TRUE);
    }
    if (output_opened != nullptr) {
      output_opened->store(true);
    }
    ComPtr<IMFSinkWriter> writer;
    hr = MFCreateSinkWriterFromURL(output_wide.c_str(), nullptr, writer_attrs.Get(),
                                   writer.GetAddressOf());
    if (FAILED(hr)) {
      last_error = HrMessage("Unable to create MP4", hr);
      if (hardware) {
        continue;
      }
      fail("encode", last_error);
      return;
    }
    DWORD video_stream = 0;
    uint32_t bitrate = 2000000;
    if (options.bitrate() > 0 &&
        options.bitrate() <= static_cast<int64_t>(UINT32_MAX)) {
      bitrate = static_cast<uint32_t>(options.bitrate());
    }
    hr = AddVideoStreams(writer.Get(), subtype, out_w, out_h, target_fps, bitrate,
                         options.keyframe_interval(), &video_stream);
    if (FAILED(hr)) {
      last_error = HrMessage("Video encoder rejected the profile", hr);
      if (hardware) {
        continue;
      }
      fail("encode", last_error);
      return;
    }
    DWORD audio_stream = 0;
    if (with_audio) {
      hr = AddAudioStream(writer.Get(), audio, &audio_stream);
      if (FAILED(hr)) {
        last_error = HrMessage("keepAudio requires an AAC encoder", hr);
        if (hardware) {
          continue;
        }
        fail("unsupported", last_error);
        return;
      }
    }
    hr = writer->BeginWriting();
    if (FAILED(hr)) {
      last_error = HrMessage("BeginWriting failed", hr);
      if (hardware) {
        continue;
      }
      fail("encode", last_error);
      return;
    }
    int written = 0;
    hr = ReadVideo(reader.Get(), writer.Get(), video_stream, frame, out_w, out_h,
                   target_fps, cancelled, on_progress, &written);
    if (hr == HRESULT_FROM_WIN32(ERROR_CANCELLED)) {
      fail("cancelled", "Cancelled");
      return;
    }
    if (FAILED(hr)) {
      const Fail mapped = MapReadError(hr, false);
      last_error = mapped.message;
      if (hardware && mapped.code == "encode") {
        continue;
      }
      fail(mapped.code, mapped.message);
      return;
    }
    if (with_audio) {
      hr = ReadAudio(reader.Get(), writer.Get(), audio_stream, audio, cancelled);
      if (hr == HRESULT_FROM_WIN32(ERROR_CANCELLED)) {
        fail("cancelled", "Cancelled");
        return;
      }
      if (FAILED(hr)) {
        const Fail mapped = MapReadError(hr, true);
        if (hardware && mapped.code == "encode") {
          last_error = mapped.message;
          continue;
        }
        fail(mapped.code, mapped.message);
        return;
      }
    }
    if (cancelled.load()) {
      fail("cancelled", "Cancelled");
      return;
    }
    hr = writer->Finalize();
    if (FAILED(hr)) {
      last_error = HrMessage("MP4 finalize failed", hr);
      if (hardware) {
        continue;
      }
      fail("encode", last_error);
      return;
    }
    used_hardware = hardware;
    last_error.clear();
    break;
  }
  if (!last_error.empty()) {
    fail("encode", last_error);
    return;
  }
  if (cancelled.load()) {
    fail("cancelled", "Cancelled");
    return;
  }

  WIN32_FILE_ATTRIBUTE_DATA attrs = {};
  int64_t size = 0;
  if (GetFileAttributesExW(output_wide.c_str(), GetFileExInfoStandard, &attrs)) {
    LARGE_INTEGER li;
    li.LowPart = attrs.nFileSizeLow;
    li.HighPart = static_cast<LONG>(attrs.nFileSizeHigh);
    size = li.QuadPart;
  }
  on_progress(1.0);
  const std::string encoder =
      std::string(used_hardware ? "MediaFoundationHW:" : "MediaFoundation:") +
      (hevc ? "H265" : "H264");
  on_completed(flutter::EncodableMap{
      {flutter::EncodableValue("outputPath"), flutter::EncodableValue(output_path)},
      {flutter::EncodableValue("sizeBytes"), flutter::EncodableValue(size)},
      {flutter::EncodableValue("encoderName"), flutter::EncodableValue(encoder)},
      {flutter::EncodableValue("codec"),
       flutter::EncodableValue(hevc ? "h265" : "h264")},
      {flutter::EncodableValue("width"),
       flutter::EncodableValue(static_cast<int64_t>(out_w))},
      {flutter::EncodableValue("height"),
       flutter::EncodableValue(static_cast<int64_t>(out_h))},
  });
}

}  // namespace xue_hua_media_compression
