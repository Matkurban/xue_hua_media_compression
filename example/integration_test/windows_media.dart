import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

/// Builds a truecolor PNG without FFmpeg. WIC decodes the result.
Uint8List encodePng(int width, int height, Uint8List rgb) {
  if (rgb.length != width * height * 3) {
    throw ArgumentError('RGB byte length does not match $width x $height');
  }
  final raw = BytesBuilder(copy: false);
  for (var y = 0; y < height; y++) {
    raw.addByte(0);
    final start = y * width * 3;
    raw.add(rgb.sublist(start, start + width * 3));
  }
  final compressed = ZLibEncoder(level: 1).convert(raw.takeBytes());
  final out = BytesBuilder(copy: false);
  out.add(const <int>[137, 80, 78, 71, 13, 10, 26, 10]);
  _pngChunk(out, 'IHDR', _pngHeader(width, height));
  _pngChunk(out, 'IDAT', compressed);
  _pngChunk(out, 'IEND', const <int>[]);
  return out.toBytes();
}

/// Noisy RGB image so JPEG quality changes the file size.
Uint8List noisyRgb(int width, int height) {
  final rgb = Uint8List(width * height * 3);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final i = (y * width + x) * 3;
      rgb[i] = (x * 13 + y * 7) & 255;
      rgb[i + 1] = (x * 3 + y * 17) & 255;
      rgb[i + 2] = ((x * y) + x * 9 + y) & 255;
    }
  }
  return rgb;
}

/// Uncompressed RGB AVI, optionally with PCM audio. Media Foundation reads it;
/// the plugin itself does not link a media generator.
Uint8List encodeAvi({
  required int width,
  required int height,
  required int fps,
  required int frames,
  bool audio = false,
  int sampleRate = 48000,
}) {
  if (width <= 0 || height <= 0 || fps <= 0 || frames <= 0) {
    throw ArgumentError('Invalid AVI geometry');
  }
  final stride = (width * 3 + 3) & ~3;
  final frameBytes = stride * height;
  final chunks = <({String id, Uint8List data, bool keyframe})>[];

  void addChunk(String id, Uint8List data, {required bool keyframe}) {
    chunks.add((id: id, data: data, keyframe: keyframe));
  }

  final samplesPerFrame = audio ? sampleRate ~/ fps : 0;
  if (audio && samplesPerFrame <= 0) {
    throw ArgumentError('sampleRate must be at least fps');
  }
  final audioSamples = samplesPerFrame * frames;
  final pcm = audio ? Uint8List(audioSamples * 2) : null;
  if (pcm != null) {
    final bytes = ByteData.sublistView(pcm);
    for (var i = 0; i < audioSamples; i++) {
      final sample = (math.sin(i / sampleRate * 440 * 2 * math.pi) * 8000)
          .round();
      bytes.setInt16(i * 2, sample.clamp(-32767, 32767), Endian.little);
    }
  }

  for (var frame = 0; frame < frames; frame++) {
    final pixels = Uint8List(frameBytes);
    for (var y = 0; y < height; y++) {
      final srcY = height - 1 - y;
      for (var x = 0; x < width; x++) {
        final i = y * stride + x * 3;
        pixels[i] = (x * 5 + frame * 17) & 255;
        pixels[i + 1] = (srcY * 9 + frame * 3) & 255;
        pixels[i + 2] = (x + srcY + frame * 13) & 255;
      }
    }
    addChunk('00db', pixels, keyframe: true);
    if (pcm != null) {
      final start = frame * samplesPerFrame * 2;
      addChunk(
        '01wb',
        Uint8List.sublistView(pcm, start, start + samplesPerFrame * 2),
        keyframe: false,
      );
    }
  }

  final hdrl = BytesBuilder(copy: false);
  hdrl.add('avih'.codeUnits);
  final avih = ByteData(56);
  avih.setUint32(0, 1000000 ~/ fps, Endian.little);
  avih.setUint32(4, frameBytes * fps, Endian.little);
  avih.setUint32(12, 0x10, Endian.little);
  avih.setUint32(16, frames, Endian.little);
  avih.setUint32(24, audio ? 2 : 1, Endian.little);
  avih.setUint32(28, frameBytes, Endian.little);
  avih.setUint32(32, width, Endian.little);
  avih.setUint32(36, height, Endian.little);
  hdrl.add(_le32(avih.lengthInBytes));
  hdrl.add(avih.buffer.asUint8List());
  hdrl.add(
    _streamList(
      type: 'vids',
      handler: 'DIB ',
      scale: 1,
      rate: fps,
      length: frames,
      buffer: frameBytes,
      sampleSize: 0,
      width: width,
      height: height,
      format: _bitmapInfo(width, height, stride),
    ),
  );
  if (audio) {
    hdrl.add(
      _streamList(
        type: 'auds',
        handler: '\x00\x00\x00\x00',
        scale: 1,
        rate: sampleRate,
        length: audioSamples,
        buffer: 4096,
        sampleSize: 2,
        width: 0,
        height: 0,
        format: _waveFormat(sampleRate),
      ),
    );
  }

  final movi = BytesBuilder(copy: false);
  final relatives = <int>[];
  for (final chunk in chunks) {
    relatives.add(4 + movi.length);
    movi.add(chunk.id.codeUnits);
    movi.add(_le32(chunk.data.length));
    movi.add(chunk.data);
    if (chunk.data.length.isOdd) {
      movi.addByte(0);
    }
  }
  final moviBytes = movi.toBytes();
  final hdrlBytes = hdrl.toBytes();
  if (hdrlBytes.length.isOdd || moviBytes.length.isOdd) {
    throw StateError('AVI list is not word-aligned');
  }
  if (chunks.isEmpty) {
    throw StateError('AVI index is empty');
  }
  // AVIOLDINDEX offsets are relative to the 'movi' fourcc. HASINDEX is set
  // without MUSTUSEINDEX so a reader can still scan the movi list.
  final index = BytesBuilder(copy: false);
  for (var i = 0; i < chunks.length; i++) {
    index.add(chunks[i].id.codeUnits);
    index.add(_le32(chunks[i].keyframe ? 0x10 : 0));
    index.add(_le32(relatives[i]));
    index.add(_le32(chunks[i].data.length));
  }
  final indexBytes = index.toBytes();
  final file = BytesBuilder(copy: false);
  file.add('RIFF'.codeUnits);
  final riffSize =
      4 + 12 + hdrlBytes.length + 12 + moviBytes.length + 8 + indexBytes.length;
  file.add(_le32(riffSize));
  file.add('AVI '.codeUnits);
  file.add('LIST'.codeUnits);
  file.add(_le32(4 + hdrlBytes.length));
  file.add('hdrl'.codeUnits);
  file.add(hdrlBytes);
  file.add('LIST'.codeUnits);
  file.add(_le32(4 + moviBytes.length));
  file.add('movi'.codeUnits);
  file.add(moviBytes);
  file.add('idx1'.codeUnits);
  file.add(_le32(indexBytes.length));
  file.add(indexBytes);
  return file.toBytes();
}

Future<void> writeAvi(
  String path, {
  required int width,
  required int height,
  required int fps,
  required int frames,
  bool audio = false,
}) {
  return File(path).writeAsBytes(
    encodeAvi(
      width: width,
      height: height,
      fps: fps,
      frames: frames,
      audio: audio,
    ),
  );
}

final class Mp4Probe {
  Mp4Probe._({
    required this.hasVideo,
    required this.hasAudio,
    required this.width,
    required this.height,
    required this.videoSamples,
    required this.syncSamples,
    required this.bytes,
  });

  final bool hasVideo;
  final bool hasAudio;
  final int width;
  final int height;
  final int videoSamples;
  final int syncSamples;
  final Uint8List bytes;

  bool containsTag(String tag) {
    final needle = tag.codeUnits;
    if (needle.length != 4) {
      return false;
    }
    for (var i = 0; i + 4 <= bytes.length; i++) {
      if (bytes[i] == needle[0] &&
          bytes[i + 1] == needle[1] &&
          bytes[i + 2] == needle[2] &&
          bytes[i + 3] == needle[3]) {
        return true;
      }
    }
    return false;
  }

  static Mp4Probe parse(Uint8List bytes) {
    final data = ByteData.sublistView(bytes);
    var hasVideo = false;
    var hasAudio = false;
    var width = 0;
    var height = 0;
    var samples = 0;
    var sync = 0;
    void walk(int start, int end) {
      var offset = start;
      while (offset + 8 <= end) {
        final header = _box(data, offset, end);
        if (header == null) {
          return;
        }
        final body = offset + header.headerSize;
        final boxEnd = offset + header.size;
        switch (header.type) {
          case 'moov':
          case 'mdia':
          case 'minf':
          case 'stbl':
            walk(body, boxEnd);
          case 'trak':
            final handler = _handler(data, body, boxEnd);
            if (handler == 'vide') {
              hasVideo = true;
              final size = _trackSize(data, body, boxEnd);
              if (size != null && (width == 0 || height == 0)) {
                width = size.$1;
                height = size.$2;
              }
              samples += _sampleCount(data, body, boxEnd);
              sync += _syncCount(data, body, boxEnd);
            } else if (handler == 'soun') {
              hasAudio = true;
            }
          default:
            break;
        }
        offset = boxEnd;
      }
    }

    walk(0, bytes.length);
    return Mp4Probe._(
      hasVideo: hasVideo,
      hasAudio: hasAudio,
      width: width,
      height: height,
      videoSamples: samples,
      syncSamples: sync,
      bytes: bytes,
    );
  }
}

Uint8List _pngHeader(int width, int height) {
  final header = ByteData(13);
  header.setUint32(0, width);
  header.setUint32(4, height);
  header.setUint8(8, 8);
  header.setUint8(9, 2);
  return header.buffer.asUint8List();
}

void _pngChunk(BytesBuilder out, String type, List<int> data) {
  final length = ByteData(4)..setUint32(0, data.length);
  out.add(length.buffer.asUint8List());
  final typeBytes = type.codeUnits;
  out.add(typeBytes);
  out.add(data);
  final crcInput = Uint8List(typeBytes.length + data.length);
  crcInput.setRange(0, typeBytes.length, typeBytes);
  crcInput.setRange(typeBytes.length, crcInput.length, data);
  final crc = ByteData(4)..setUint32(0, _crc32(crcInput));
  out.add(crc.buffer.asUint8List());
}

int _crc32(Uint8List data) {
  var crc = 0xffffffff;
  for (final byte in data) {
    crc ^= byte;
    for (var i = 0; i < 8; i++) {
      if ((crc & 1) == 1) {
        crc = (crc >> 1) ^ 0xedb88320;
      } else {
        crc = crc >> 1;
      }
    }
  }
  return (crc ^ 0xffffffff) & 0xffffffff;
}

Uint8List _le32(int value) {
  final data = ByteData(4)..setUint32(0, value, Endian.little);
  return data.buffer.asUint8List();
}

Uint8List _bitmapInfo(int width, int height, int stride) {
  final info = ByteData(40);
  info.setUint32(0, 40, Endian.little);
  info.setInt32(4, width, Endian.little);
  info.setInt32(8, height, Endian.little);
  info.setUint16(12, 1, Endian.little);
  info.setUint16(14, 24, Endian.little);
  info.setUint32(20, stride * height, Endian.little);
  return info.buffer.asUint8List();
}

Uint8List _waveFormat(int sampleRate) {
  final info = ByteData(18);
  info.setUint16(0, 1, Endian.little);
  info.setUint16(2, 1, Endian.little);
  info.setUint32(4, sampleRate, Endian.little);
  info.setUint32(8, sampleRate * 2, Endian.little);
  info.setUint16(12, 2, Endian.little);
  info.setUint16(14, 16, Endian.little);
  return info.buffer.asUint8List();
}

Uint8List _streamList({
  required String type,
  required String handler,
  required int scale,
  required int rate,
  required int length,
  required int buffer,
  required int sampleSize,
  required int width,
  required int height,
  required Uint8List format,
}) {
  final strh = ByteData(56);
  final typeBytes = type.codeUnits;
  final handlerBytes = handler.codeUnits;
  for (var i = 0; i < 4; i++) {
    strh.setUint8(i, typeBytes[i]);
    strh.setUint8(4 + i, handlerBytes[i]);
  }
  strh.setUint32(20, scale, Endian.little);
  strh.setUint32(24, rate, Endian.little);
  strh.setUint32(32, length, Endian.little);
  strh.setUint32(36, buffer, Endian.little);
  strh.setUint32(40, 0xffffffff, Endian.little);
  strh.setUint32(44, sampleSize, Endian.little);
  strh.setInt16(52, width, Endian.little);
  strh.setInt16(54, height, Endian.little);

  final body = BytesBuilder(copy: false);
  body.add('strh'.codeUnits);
  body.add(_le32(strh.lengthInBytes));
  body.add(strh.buffer.asUint8List());
  body.add('strf'.codeUnits);
  body.add(_le32(format.length));
  body.add(format);
  final payload = body.toBytes();
  final list = BytesBuilder(copy: false);
  list.add('LIST'.codeUnits);
  list.add(_le32(4 + payload.length));
  list.add('strl'.codeUnits);
  list.add(payload);
  return list.toBytes();
}

final class _Box {
  const _Box(this.type, this.size, this.headerSize);

  final String type;
  final int size;
  final int headerSize;
}

_Box? _box(ByteData data, int offset, int end) {
  if (offset + 8 > end) {
    return null;
  }
  var size = data.getUint32(offset);
  var header = 8;
  final type = String.fromCharCodes(<int>[
    data.getUint8(offset + 4),
    data.getUint8(offset + 5),
    data.getUint8(offset + 6),
    data.getUint8(offset + 7),
  ]);
  if (size == 1) {
    if (offset + 16 > end) {
      return null;
    }
    size = data.getUint64(offset + 8);
    header = 16;
  } else if (size == 0) {
    size = end - offset;
  }
  if (size < header || offset + size > end) {
    return null;
  }
  return _Box(type, size, header);
}

String? _handler(ByteData data, int start, int end) {
  var offset = start;
  while (offset + 8 <= end) {
    final box = _box(data, offset, end);
    if (box == null) {
      return null;
    }
    final body = offset + box.headerSize;
    if (box.type == 'hdlr' && box.size >= box.headerSize + 12) {
      return String.fromCharCodes(<int>[
        data.getUint8(body + 8),
        data.getUint8(body + 9),
        data.getUint8(body + 10),
        data.getUint8(body + 11),
      ]);
    }
    if (box.type == 'mdia' || box.type == 'minf') {
      final nested = _handler(data, body, offset + box.size);
      if (nested != null) {
        return nested;
      }
    }
    offset += box.size;
  }
  return null;
}

(int, int)? _trackSize(ByteData data, int start, int end) {
  var offset = start;
  while (offset + 8 <= end) {
    final box = _box(data, offset, end);
    if (box == null) {
      return null;
    }
    if (box.type == 'tkhd' && box.size >= box.headerSize + 8) {
      final version = data.getUint8(offset + box.headerSize);
      final widthOffset = offset + (version == 0 ? 84 : 96);
      if (widthOffset + 8 <= offset + box.size) {
        final width = data.getUint32(widthOffset) >> 16;
        final height = data.getUint32(widthOffset + 4) >> 16;
        return (width, height);
      }
    }
    offset += box.size;
  }
  return null;
}

int _sampleCount(ByteData data, int start, int end) {
  var total = 0;
  var offset = start;
  while (offset + 8 <= end) {
    final box = _box(data, offset, end);
    if (box == null) {
      return total;
    }
    final body = offset + box.headerSize;
    if (box.type == 'stts' && box.size >= box.headerSize + 8) {
      final entries = data.getUint32(body + 4);
      var cursor = body + 8;
      for (var i = 0; i < entries; i++) {
        if (cursor + 8 > offset + box.size) {
          break;
        }
        total += data.getUint32(cursor);
        cursor += 8;
      }
    } else if (box.type == 'mdia' || box.type == 'minf' || box.type == 'stbl') {
      total += _sampleCount(data, body, offset + box.size);
    }
    offset += box.size;
  }
  return total;
}

int _syncCount(ByteData data, int start, int end) {
  var offset = start;
  while (offset + 8 <= end) {
    final box = _box(data, offset, end);
    if (box == null) {
      return 0;
    }
    final body = offset + box.headerSize;
    if (box.type == 'stss' && box.size >= box.headerSize + 8) {
      return data.getUint32(body + 4);
    }
    if (box.type == 'mdia' || box.type == 'minf' || box.type == 'stbl') {
      final nested = _syncCount(data, body, offset + box.size);
      if (nested > 0) {
        return nested;
      }
    }
    offset += box.size;
  }
  return 0;
}
