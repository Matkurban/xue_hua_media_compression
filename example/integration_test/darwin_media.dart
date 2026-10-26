import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

/// Pixel layout of a generated QuickTime file. AVFoundation reads both;
/// neither path uses FFmpeg.
enum DarwinVideoPixel { uyvy, jpeg }

/// Writes a self-contained QuickTime movie.
///
/// UYVY frames are raw 4:2:2 and need even dimensions. JPEG frames may be
/// odd. The same frame bytes are repeated, so generation stays cheap.
Future<void> writeDarwinVideo(
  String path, {
  required int width,
  required int height,
  required int fps,
  required int frames,
  bool audio = false,
  DarwinVideoPixel pixel = DarwinVideoPixel.uyvy,
  int jpegQuality = 70,
}) {
  return File(path).writeAsBytes(
    encodeDarwinVideo(
      width: width,
      height: height,
      fps: fps,
      frames: frames,
      audio: audio,
      pixel: pixel,
      jpegQuality: jpegQuality,
    ),
  );
}

Uint8List encodeDarwinVideo({
  required int width,
  required int height,
  required int fps,
  required int frames,
  bool audio = false,
  DarwinVideoPixel pixel = DarwinVideoPixel.uyvy,
  int jpegQuality = 70,
}) {
  if (width <= 0 || height <= 0 || fps <= 0 || frames <= 0) {
    throw ArgumentError('Invalid video geometry');
  }
  if ((600 * frames) % fps != 0) {
    throw ArgumentError('fps must divide 600 * frames');
  }
  final Uint8List frame;
  final String codec;
  final String codecName;
  switch (pixel) {
    case DarwinVideoPixel.uyvy:
      if (width.isOdd || height.isOdd) {
        throw ArgumentError('UYVY requires even dimensions');
      }
      frame = _uyvyFrame(width, height);
      codec = '2vuy';
      codecName = '2vuy';
    case DarwinVideoPixel.jpeg:
      frame = encodeBaselineJpeg(
        width,
        height,
        _rgbGradient(width, height),
        quality: jpegQuality,
      );
      codec = 'jpeg';
      codecName = 'jpeg';
  }
  final video = BytesBuilder(copy: false);
  final sizes = <int>[];
  for (var i = 0; i < frames; i++) {
    video.add(frame);
    sizes.add(frame.length);
  }
  final videoBytes = video.toBytes();
  const rate = 48000;
  const channels = 2;
  final audioSamples = audio ? rate * frames ~/ fps : 0;
  final audioBytes = audio ? _pcm(audioSamples, channels, rate) : Uint8List(0);
  const movieScale = 600;
  final movieDuration = movieScale * frames ~/ fps;
  final ftyp = _ftyp();
  final wide = _atom('wide', const <int>[]);
  final videoOffset = ftyp.length + wide.length + 8;
  final audioOffset = videoOffset + videoBytes.length;
  final videoStbl = BytesBuilder(copy: false)
    ..add(_stsdVideo(codec, width, height, codecName))
    ..add(_stts(frames, 1))
    ..add(_stss(frames))
    ..add(_stsc(frames))
    ..add(_stsz(sizes))
    ..add(_stco(videoOffset));
  final tracks = BytesBuilder(copy: false)
    ..add(
      _trak(
        trackId: 1,
        movieDuration: movieDuration,
        width: width,
        height: height,
        volume: 0,
        mediaScale: fps,
        mediaDuration: frames,
        handler: 'vide',
        minf: _minfVideo(videoStbl.toBytes()),
      ),
    );
  var nextTrack = 2;
  if (audio) {
    final audioStbl = BytesBuilder(copy: false)
      ..add(_stsdAudio(channels, rate, 16))
      ..add(_stts(audioSamples, 1))
      ..add(_stsc(audioSamples))
      ..add(_stsz(List<int>.filled(audioSamples, channels * 2)))
      ..add(_stco(audioOffset));
    tracks.add(
      _trak(
        trackId: 2,
        movieDuration: movieDuration,
        width: 0,
        height: 0,
        volume: 0x0100,
        mediaScale: rate,
        mediaDuration: audioSamples,
        handler: 'soun',
        minf: _minfAudio(audioStbl.toBytes()),
      ),
    );
    nextTrack = 3;
  }
  final mdatPayload = BytesBuilder(copy: false)
    ..add(videoBytes)
    ..add(audioBytes);
  final payload = mdatPayload.toBytes();
  final file = BytesBuilder(copy: false)
    ..add(ftyp)
    ..add(wide)
    ..add(_atom('mdat', payload))
    ..add(_atom('moov', _mvhd(movieScale, movieDuration, nextTrack) + tracks.toBytes()));
  return file.toBytes();
}

/// Baseline 4:2:0 JPEG. Tables are the ITU-T T.81 standard tables.
Uint8List encodeBaselineJpeg(
  int width,
  int height,
  Uint8List rgb, {
  int quality = 75,
}) {
  if (rgb.length != width * height * 3) {
    throw ArgumentError('RGB byte length does not match $width x $height');
  }
  final yq = _scaleQuant(_lumQuant, quality);
  final cq = _scaleQuant(_chrQuant, quality);
  final dcL = _huff(_dcLumBits, _dcLumVal);
  final dcC = _huff(_dcChrBits, _dcChrVal);
  final acL = _huff(_acLumBits, _acLumVal);
  final acC = _huff(_acChrBits, _acChrVal);
  final mcusX = (width + 15) >> 4;
  final mcusY = (height + 15) >> 4;
  final bits = _BitWriter();
  var dcY = 0;
  var dcCb = 0;
  var dcCr = 0;

  double yOf(int r, int g, int b) => 0.299 * r + 0.587 * g + 0.114 * b - 128;
  double cbOf(int r, int g, int b) => -0.168736 * r - 0.331264 * g + 0.5 * b;
  double crOf(int r, int g, int b) => 0.5 * r - 0.418688 * g - 0.081312 * b;

  (int, int, int) sample(int x, int y) {
    final px = x < 0 ? 0 : (x >= width ? width - 1 : x);
    final py = y < 0 ? 0 : (y >= height ? height - 1 : y);
    final i = (py * width + px) * 3;
    return (rgb[i], rgb[i + 1], rgb[i + 2]);
  }

  for (var my = 0; my < mcusY; my++) {
    for (var mx = 0; mx < mcusX; mx++) {
      final blocks = <Float64List>[
        Float64List(64),
        Float64List(64),
        Float64List(64),
        Float64List(64),
      ];
      final cb = Float64List(64);
      final cr = Float64List(64);
      for (var by = 0; by < 2; by++) {
        for (var bx = 0; bx < 2; bx++) {
          final block = blocks[by * 2 + bx];
          for (var y = 0; y < 8; y++) {
            for (var x = 0; x < 8; x++) {
              final pixel = sample(mx * 16 + bx * 8 + x, my * 16 + by * 8 + y);
              block[y * 8 + x] = yOf(pixel.$1, pixel.$2, pixel.$3);
            }
          }
        }
      }
      for (var y = 0; y < 16; y++) {
        for (var x = 0; x < 16; x++) {
          final pixel = sample(mx * 16 + x, my * 16 + y);
          final index = (y >> 1) * 8 + (x >> 1);
          cb[index] += cbOf(pixel.$1, pixel.$2, pixel.$3);
          cr[index] += crOf(pixel.$1, pixel.$2, pixel.$3);
        }
      }
      for (var i = 0; i < 64; i++) {
        cb[i] /= 4;
        cr[i] /= 4;
      }
      for (final block in blocks) {
        dcY = _encodeBlock(bits, block, yq, dcL, acL, dcY);
      }
      dcCb = _encodeBlock(bits, cb, cq, dcC, acC, dcCb);
      dcCr = _encodeBlock(bits, cr, cq, dcC, acC, dcCr);
    }
  }
  bits.flush();

  final out = BytesBuilder(copy: false)
    ..add(const <int>[0xff, 0xd8])
    ..add(const <int>[0xff, 0xe0])
    ..add(_be16(16))
    ..add(const <int>[
      0x4a, 0x46, 0x49, 0x46, 0x00, 0x01, 0x01, 0x00, 0x00, 0x01, 0x00, 0x01,
      0x00, 0x00,
    ])
    ..add(_dqt(yq, 0))
    ..add(_dqt(cq, 1));
  final sof = BytesBuilder(copy: false)
    ..addByte(8)
    ..add(_be16(height))
    ..add(_be16(width))
    ..add(const <int>[3, 1, 0x22, 0, 2, 0x11, 1, 3, 0x11, 1]);
  final sofBytes = sof.toBytes();
  out
    ..add(const <int>[0xff, 0xc0])
    ..add(_be16(2 + sofBytes.length))
    ..add(sofBytes)
    ..add(_dht(_dcLumBits, _dcLumVal, 0, 0))
    ..add(_dht(_acLumBits, _acLumVal, 1, 0))
    ..add(_dht(_dcChrBits, _dcChrVal, 0, 1))
    ..add(_dht(_acChrBits, _acChrVal, 1, 1));
  const sos = <int>[3, 1, 0x00, 2, 0x11, 3, 0x11, 0, 63, 0];
  out
    ..add(const <int>[0xff, 0xda])
    ..add(_be16(2 + sos.length))
    ..add(sos)
    ..add(bits.bytes)
    ..add(const <int>[0xff, 0xd9]);
  return out.toBytes();
}

Uint8List _rgbGradient(int width, int height) {
  final rgb = Uint8List(width * height * 3);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final i = (y * width + x) * 3;
      rgb[i] = (x * 9 + y) & 255;
      rgb[i + 1] = (y * 4 + x * 3) & 255;
      rgb[i + 2] = (x + y * 5) & 255;
    }
  }
  return rgb;
}

Uint8List _uyvyFrame(int width, int height) {
  final frame = Uint8List(width * height * 2);
  for (var i = 0; i < frame.length; i += 4) {
    frame[i] = 128;
    frame[i + 1] = i & 255;
    frame[i + 2] = 128;
    frame[i + 3] = (i * 3) & 255;
  }
  return frame;
}

Uint8List _pcm(int samples, int channels, int rate) {
  final out = Uint8List(samples * channels * 2);
  final view = ByteData.sublistView(out);
  for (var i = 0; i < samples; i++) {
    final sample = (math.sin(i / rate * 440 * 2 * math.pi) * 8000).round();
    final clamped = sample < -32767
        ? -32767
        : sample > 32767
        ? 32767
        : sample;
    for (var channel = 0; channel < channels; channel++) {
      view.setInt16((i * channels + channel) * 2, clamped, Endian.little);
    }
  }
  return out;
}

final List<List<double>> _cos = List<List<double>>.generate(
  8,
  (int u) => List<double>.generate(
    8,
    (int x) => math.cos((2 * x + 1) * u * math.pi / 16),
  ),
  growable: false,
);

int _encodeBlock(
  _BitWriter writer,
  List<double> spatial,
  List<int> quant,
  Map<int, (int, int)> dcTable,
  Map<int, (int, int)> acTable,
  int prevDc,
) {
  final coeffs = Float64List(64);
  for (var v = 0; v < 8; v++) {
    final cv = v == 0 ? 1 / math.sqrt2 : 1.0;
    for (var u = 0; u < 8; u++) {
      final cu = u == 0 ? 1 / math.sqrt2 : 1.0;
      var total = 0.0;
      for (var y = 0; y < 8; y++) {
        final cosY = _cos[v][y];
        for (var x = 0; x < 8; x++) {
          total += spatial[y * 8 + x] * _cos[u][x] * cosY;
        }
      }
      coeffs[v * 8 + u] = 0.25 * cu * cv * total;
    }
  }
  final zz = List<int>.filled(64, 0);
  for (var i = 0; i < 64; i++) {
    zz[_zigzag[i]] = (coeffs[i] / quant[i]).round();
  }
  final dc = zz[0];
  final diff = dc - prevDc;
  if (diff == 0) {
    final symbol = dcTable[0]!;
    writer.write(symbol.$1, symbol.$2);
  } else {
    final mag = diff.abs();
    final cat = mag.bitLength;
    final symbol = dcTable[cat]!;
    writer.write(symbol.$1, symbol.$2);
    writer.write(diff < 0 ? (1 << cat) + diff - 1 : mag, cat);
  }
  var zeros = 0;
  for (var i = 1; i < 64; i++) {
    if (zz[i] == 0) {
      zeros++;
      continue;
    }
    while (zeros >= 16) {
      final zrl = acTable[0xf0]!;
      writer.write(zrl.$1, zrl.$2);
      zeros -= 16;
    }
    final mag = zz[i].abs();
    final cat = mag.bitLength;
    final symbol = acTable[(zeros << 4) | cat]!;
    writer.write(symbol.$1, symbol.$2);
    writer.write(zz[i] < 0 ? (1 << cat) + zz[i] - 1 : mag, cat);
    zeros = 0;
  }
  if (zeros > 0) {
    final eob = acTable[0]!;
    writer.write(eob.$1, eob.$2);
  }
  return dc;
}

class _BitWriter {
  final BytesBuilder _data = BytesBuilder(copy: false);
  int _acc = 0;
  int _n = 0;

  Uint8List get bytes => _data.toBytes();

  void write(int value, int length) {
    if (length <= 0) {
      return;
    }
    _acc = (_acc << length) | (value & ((1 << length) - 1));
    _n += length;
    while (_n >= 8) {
      _n -= 8;
      final byte = (_acc >> _n) & 0xff;
      _data.addByte(byte);
      if (byte == 0xff) {
        _data.addByte(0);
      }
    }
  }

  void flush() {
    if (_n > 0) {
      write(0, 8 - _n);
    }
  }
}

Map<int, (int, int)> _huff(List<int> bits, List<int> values) {
  final sizes = <int>[];
  for (var length = 0; length < 16; length++) {
    for (var i = 0; i < bits[length]; i++) {
      sizes.add(length + 1);
    }
  }
  final table = <int, (int, int)>{};
  var code = 0;
  var prev = 0;
  for (var i = 0; i < sizes.length; i++) {
    final size = sizes[i];
    if (prev == 0) {
      prev = size;
    }
    while (prev < size) {
      code <<= 1;
      prev++;
    }
    table[values[i]] = (code, size);
    code++;
  }
  return table;
}

List<int> _scaleQuant(List<int> base, int quality) {
  final q = _clampInt(quality, 1, 100);
  final scale = q < 50 ? 5000 ~/ q : 200 - q * 2;
  return <int>[
    for (final value in base)
      _clampInt((value * scale + 50) ~/ 100, 1, 255),
  ];
}

Uint8List _dqt(List<int> table, int id) {
  final payload = Uint8List(65);
  payload[0] = id;
  payload.setRange(1, 65, table);
  return Uint8List.fromList(<int>[0xff, 0xdb, ..._be16(2 + payload.length), ...payload]);
}

Uint8List _dht(List<int> bits, List<int> values, int tableClass, int id) {
  final header = <int>[0xff, 0xc4, ..._be16(2 + 1 + 16 + values.length), (tableClass << 4) | id];
  return Uint8List.fromList(<int>[...header, ...bits, ...values]);
}

int _clampInt(int value, int min, int max) {
  if (value < min) {
    return min;
  }
  if (value > max) {
    return max;
  }
  return value;
}

Uint8List _be16(int value) {
  final data = ByteData(2)..setUint16(0, value);
  return data.buffer.asUint8List();
}

Uint8List _be32(int value) {
  final data = ByteData(4)..setUint32(0, value);
  return data.buffer.asUint8List();
}

Uint8List _atom(String type, List<int> payload) {
  final out = BytesBuilder(copy: false)
    ..add(_be32(8 + payload.length))
    ..add(type.codeUnits)
    ..add(payload);
  return out.toBytes();
}

Uint8List _ftyp() {
  return _atom('ftyp', <int>[
    ..._fourcc('qt  '),
    ..._be32(0),
    ..._fourcc('qt  '),
  ]);
}

Uint8List _fourcc(String value) {
  final bytes = value.codeUnits;
  if (bytes.length != 4) {
    throw ArgumentError('Fourcc must be 4 bytes');
  }
  return Uint8List.fromList(bytes);
}

Uint8List _vmhd() => _atom('vmhd', <int>[..._be32(1), 0, 0, 0, 0, 0, 0, 0, 0]);

Uint8List _smhd() => _atom('smhd', <int>[..._be32(0), 0, 0, 0, 0]);

Uint8List _dinf() {
  final url = _atom('url ', _be32(1));
  final dref = _atom('dref', <int>[..._be32(0), ..._be32(1), ...url]);
  return _atom('dinf', dref);
}

/// QuickTime handler. Component type is `mhlr` or `dhlr`; the name is a Pascal string.
Uint8List _hdlr(String componentType, String subtype, String name) {
  final nameBytes = name.codeUnits;
  if (nameBytes.length > 255) {
    throw ArgumentError('handler name is too long');
  }
  final body = BytesBuilder(copy: false)
    ..add(_be32(0))
    ..add(_fourcc(componentType))
    ..add(_fourcc(subtype))
    ..add(_be32(0))
    ..add(_be32(0))
    ..add(_be32(0))
    ..addByte(nameBytes.length)
    ..add(nameBytes);
  return _atom('hdlr', body.toBytes());
}

Uint8List _mdhd(int timescale, int duration) {
  final body = BytesBuilder(copy: false)
    ..add(_be32(0))
    ..add(_be32(0))
    ..add(_be32(0))
    ..add(_be32(timescale))
    ..add(_be32(duration))
    ..add(_be16(0x55c4))
    ..add(_be16(0));
  return _atom('mdhd', body.toBytes());
}

Uint8List _tkhd({
  required int trackId,
  required int duration,
  required int width,
  required int height,
  required int volume,
}) {
  final body = BytesBuilder(copy: false)
    ..add(_be32(0x7))
    ..add(_be32(0))
    ..add(_be32(0))
    ..add(_be32(trackId))
    ..add(_be32(0))
    ..add(_be32(duration))
    ..add(_be32(0))
    ..add(_be32(0))
    ..add(_be16(0))
    ..add(_be16(0))
    ..add(_be16(volume))
    ..add(_be16(0));
  const matrix = <int>[
    0x00010000, 0, 0,
    0, 0x00010000, 0,
    0, 0, 0x40000000,
  ];
  for (final value in matrix) {
    body.add(_be32(value));
  }
  body
    ..add(_be32(width << 16))
    ..add(_be32(height << 16));
  return _atom('tkhd', body.toBytes());
}

Uint8List _mvhd(int timescale, int duration, int nextTrack) {
  final body = BytesBuilder(copy: false)
    ..add(_be32(0))
    ..add(_be32(0))
    ..add(_be32(0))
    ..add(_be32(timescale))
    ..add(_be32(duration))
    ..add(_be32(0x00010000))
    ..add(_be16(0x0100))
    ..add(_be16(0))
    ..add(_be32(0))
    ..add(_be32(0));
  const matrix = <int>[
    0x00010000, 0, 0,
    0, 0x00010000, 0,
    0, 0, 0x40000000,
  ];
  for (final value in matrix) {
    body.add(_be32(value));
  }
  for (var i = 0; i < 6; i++) {
    body.add(_be32(0));
  }
  body.add(_be32(nextTrack));
  return _atom('mvhd', body.toBytes());
}

Uint8List _stts(int count, int duration) {
  return _atom('stts', <int>[
    ..._be32(0),
    ..._be32(1),
    ..._be32(count),
    ..._be32(duration),
  ]);
}

Uint8List _stsc(int samplesPerChunk) {
  return _atom('stsc', <int>[
    ..._be32(0),
    ..._be32(1),
    ..._be32(1),
    ..._be32(samplesPerChunk),
    ..._be32(1),
  ]);
}

Uint8List _stsz(List<int> sizes) {
  if (sizes.isNotEmpty && sizes.every((int size) => size == sizes.first)) {
    return _atom('stsz', <int>[
      ..._be32(0),
      ..._be32(sizes.first),
      ..._be32(sizes.length),
    ]);
  }
  final body = BytesBuilder(copy: false)
    ..add(_be32(0))
    ..add(_be32(0))
    ..add(_be32(sizes.length));
  for (final size in sizes) {
    body.add(_be32(size));
  }
  return _atom('stsz', body.toBytes());
}

Uint8List _stco(int offset) => _atom('stco', <int>[..._be32(0), ..._be32(1), ..._be32(offset)]);

Uint8List _stss(int count) {
  final body = BytesBuilder(copy: false)
    ..add(_be32(0))
    ..add(_be32(count));
  for (var i = 1; i <= count; i++) {
    body.add(_be32(i));
  }
  return _atom('stss', body.toBytes());
}

Uint8List _stsdVideo(String codec, int width, int height, String name) {
  final compressor = Uint8List(32);
  final raw = name.codeUnits;
  final length = raw.length > 31 ? 31 : raw.length;
  compressor[0] = length;
  compressor.setRange(1, 1 + length, raw);
  final desc = BytesBuilder(copy: false)
    ..add(_fourcc(codec))
    ..add(Uint8List(6))
    ..add(_be16(1))
    ..add(_be16(0))
    ..add(_be16(0))
    ..add(_be32(0))
    ..add(_be32(0))
    ..add(_be32(512))
    ..add(_be16(width))
    ..add(_be16(height))
    ..add(_be32(72 << 16))
    ..add(_be32(72 << 16))
    ..add(_be32(0))
    ..add(_be16(1))
    ..add(compressor)
    ..add(_be16(24))
    ..add(_be16(0xffff));
  final description = desc.toBytes();
  if (description.length != 82) {
    throw StateError('video sample description is ${description.length}');
  }
  final fiel = _atom('fiel', const <int>[1, 0]);
  final sample = BytesBuilder(copy: false)
    ..add(_be32(4 + description.length + fiel.length))
    ..add(description)
    ..add(fiel);
  return _atom('stsd', <int>[..._be32(0), ..._be32(1), ...sample.toBytes()]);
}

Uint8List _stsdAudio(int channels, int sampleRate, int sampleSize) {
  final desc = BytesBuilder(copy: false)
    ..add(_fourcc('sowt'))
    ..add(Uint8List(6))
    ..add(_be16(1))
    ..add(_be16(0))
    ..add(_be16(0))
    ..add(_be32(0))
    ..add(_be16(channels))
    ..add(_be16(sampleSize))
    ..add(_be16(0))
    ..add(_be16(0))
    ..add(_be32(sampleRate << 16));
  final description = desc.toBytes();
  if (description.length != 32) {
    throw StateError('audio sample description is ${description.length}');
  }
  final tag = channels == 1 ? 0x00640001 : 0x00650002;
  final chan = _atom('chan', <int>[
    ..._be32(0),
    ..._be32(tag),
    ..._be32(0),
    ..._be32(0),
  ]);
  final sample = BytesBuilder(copy: false)
    ..add(_be32(4 + description.length + chan.length))
    ..add(description)
    ..add(chan);
  return _atom('stsd', <int>[..._be32(0), ..._be32(1), ...sample.toBytes()]);
}

Uint8List _minfVideo(Uint8List stbl) {
  final body = BytesBuilder(copy: false)
    ..add(_vmhd())
    ..add(_hdlr('dhlr', 'url ', 'DataHandler'))
    ..add(_dinf())
    ..add(_atom('stbl', stbl));
  return _atom('minf', body.toBytes());
}

Uint8List _minfAudio(Uint8List stbl) {
  final body = BytesBuilder(copy: false)
    ..add(_smhd())
    ..add(_hdlr('dhlr', 'url ', 'DataHandler'))
    ..add(_dinf())
    ..add(_atom('stbl', stbl));
  return _atom('minf', body.toBytes());
}

Uint8List _trak({
  required int trackId,
  required int movieDuration,
  required int width,
  required int height,
  required int volume,
  required int mediaScale,
  required int mediaDuration,
  required String handler,
  required Uint8List minf,
}) {
  final mdia = _atom(
    'mdia',
    <int>[
      ..._mdhd(mediaScale, mediaDuration),
      ..._hdlr(
        'mhlr',
        handler,
        handler == 'soun' ? 'SoundHandler' : 'VideoHandler',
      ),
      ...minf,
    ],
  );
  final header = _tkhd(
    trackId: trackId,
    duration: movieDuration,
    width: width,
    height: height,
    volume: volume,
  );
  return _atom('trak', <int>[...header, ...mdia]);
}

const List<int> _lumQuant = <int>[
  16, 11, 10, 16, 24, 40, 51, 61,
  12, 12, 14, 19, 26, 58, 60, 55,
  14, 13, 16, 24, 40, 57, 69, 56,
  14, 17, 22, 29, 51, 87, 80, 62,
  18, 22, 37, 56, 68, 109, 103, 77,
  24, 35, 55, 64, 81, 104, 113, 92,
  49, 64, 78, 87, 103, 121, 120, 101,
  72, 92, 95, 98, 112, 100, 103, 99,
];

const List<int> _chrQuant = <int>[
  17, 18, 24, 47, 99, 99, 99, 99,
  18, 21, 26, 66, 99, 99, 99, 99,
  24, 26, 56, 99, 99, 99, 99, 99,
  47, 66, 99, 99, 99, 99, 99, 99,
  99, 99, 99, 99, 99, 99, 99, 99,
  99, 99, 99, 99, 99, 99, 99, 99,
  99, 99, 99, 99, 99, 99, 99, 99,
  99, 99, 99, 99, 99, 99, 99, 99,
];

const List<int> _zigzag = <int>[
  0, 1, 5, 6, 14, 15, 27, 28,
  2, 4, 7, 13, 16, 26, 29, 42,
  3, 8, 12, 17, 25, 30, 41, 43,
  9, 11, 18, 24, 31, 40, 44, 53,
  10, 19, 23, 32, 39, 45, 52, 54,
  20, 22, 33, 38, 46, 51, 55, 60,
  21, 34, 37, 47, 50, 56, 59, 61,
  35, 36, 48, 49, 57, 58, 62, 63,
];

const List<int> _dcLumBits = <int>[0, 1, 5, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0];
const List<int> _dcLumVal = <int>[0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11];
const List<int> _dcChrBits = <int>[0, 3, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0];
const List<int> _dcChrVal = <int>[0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11];
const List<int> _acLumBits = <int>[0, 2, 1, 3, 3, 2, 4, 3, 5, 5, 4, 4, 0, 0, 1, 125];
const List<int> _acLumVal = <int>[
  0x01, 0x02, 0x03, 0x00, 0x04, 0x11, 0x05, 0x12, 0x21, 0x31, 0x41, 0x06,
  0x13, 0x51, 0x61, 0x07, 0x22, 0x71, 0x14, 0x32, 0x81, 0x91, 0xa1, 0x08,
  0x23, 0x42, 0xb1, 0xc1, 0x15, 0x52, 0xd1, 0xf0, 0x24, 0x33, 0x62, 0x72,
  0x82, 0x09, 0x0a, 0x16, 0x17, 0x18, 0x19, 0x1a, 0x25, 0x26, 0x27, 0x28,
  0x29, 0x2a, 0x34, 0x35, 0x36, 0x37, 0x38, 0x39, 0x3a, 0x43, 0x44, 0x45,
  0x46, 0x47, 0x48, 0x49, 0x4a, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59,
  0x5a, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68, 0x69, 0x6a, 0x73, 0x74, 0x75,
  0x76, 0x77, 0x78, 0x79, 0x7a, 0x83, 0x84, 0x85, 0x86, 0x87, 0x88, 0x89,
  0x8a, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97, 0x98, 0x99, 0x9a, 0xa2, 0xa3,
  0xa4, 0xa5, 0xa6, 0xa7, 0xa8, 0xa9, 0xaa, 0xb2, 0xb3, 0xb4, 0xb5, 0xb6,
  0xb7, 0xb8, 0xb9, 0xba, 0xc2, 0xc3, 0xc4, 0xc5, 0xc6, 0xc7, 0xc8, 0xc9,
  0xca, 0xd2, 0xd3, 0xd4, 0xd5, 0xd6, 0xd7, 0xd8, 0xd9, 0xda, 0xe1, 0xe2,
  0xe3, 0xe4, 0xe5, 0xe6, 0xe7, 0xe8, 0xe9, 0xea, 0xf1, 0xf2, 0xf3, 0xf4,
  0xf5, 0xf6, 0xf7, 0xf8, 0xf9, 0xfa,
];
const List<int> _acChrBits = <int>[0, 2, 1, 2, 4, 4, 3, 4, 7, 5, 4, 4, 0, 1, 2, 119];
const List<int> _acChrVal = <int>[
  0x00, 0x01, 0x02, 0x03, 0x11, 0x04, 0x05, 0x21, 0x31, 0x06, 0x12, 0x41,
  0x51, 0x07, 0x61, 0x71, 0x13, 0x22, 0x32, 0x81, 0x08, 0x14, 0x42, 0x91,
  0xa1, 0xb1, 0xc1, 0x09, 0x23, 0x33, 0x52, 0xf0, 0x15, 0x62, 0x72, 0xd1,
  0x0a, 0x16, 0x24, 0x34, 0xe1, 0x25, 0xf1, 0x17, 0x18, 0x19, 0x1a, 0x26,
  0x27, 0x28, 0x29, 0x2a, 0x35, 0x36, 0x37, 0x38, 0x39, 0x3a, 0x43, 0x44,
  0x45, 0x46, 0x47, 0x48, 0x49, 0x4a, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58,
  0x59, 0x5a, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68, 0x69, 0x6a, 0x73, 0x74,
  0x75, 0x76, 0x77, 0x78, 0x79, 0x7a, 0x82, 0x83, 0x84, 0x85, 0x86, 0x87,
  0x88, 0x89, 0x8a, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97, 0x98, 0x99, 0x9a,
  0xa2, 0xa3, 0xa4, 0xa5, 0xa6, 0xa7, 0xa8, 0xa9, 0xaa, 0xb2, 0xb3, 0xb4,
  0xb5, 0xb6, 0xb7, 0xb8, 0xb9, 0xba, 0xc2, 0xc3, 0xc4, 0xc5, 0xc6, 0xc7,
  0xc8, 0xc9, 0xca, 0xd2, 0xd3, 0xd4, 0xd5, 0xd6, 0xd7, 0xd8, 0xd9, 0xda,
  0xe2, 0xe3, 0xe4, 0xe5, 0xe6, 0xe7, 0xe8, 0xe9, 0xea, 0xf2, 0xf3, 0xf4,
  0xf5, 0xf6, 0xf7, 0xf8, 0xf9, 0xfa,
];
