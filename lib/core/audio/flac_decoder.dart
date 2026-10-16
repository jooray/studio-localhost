// Pure-Dart FLAC decoder (no native code), tuned for streaming analysis.
//
// Supports bit depths 4..32, 1..8 channels, CONSTANT / VERBATIM / FIXED / LPC
// subframes, wasted bits, independent + left/side + side/right + mid/side
// stereo, fixed and variable block sizes, Rice / Rice2 partitioned residuals
// including escaped (raw) partitions. Frame header CRC-8 is checked; the
// per-frame CRC-16 is not (the decoder is used for envelopes, not playback).
//
// Decoded samples are delivered one frame at a time through a callback, in
// reused per-channel [Int64List] buffers (64-bit so a 32-bit stream's 33-bit
// side channel and LPC accumulators never overflow).

import 'dart:typed_data';

/// Contents of the FLAC STREAMINFO block.
class FlacStreamInfo {
  const FlacStreamInfo({
    required this.minBlockSize,
    required this.maxBlockSize,
    required this.sampleRate,
    required this.channels,
    required this.bitsPerSample,
    required this.totalSamples,
    required this.md5,
  });

  final int minBlockSize;
  final int maxBlockSize;
  final int sampleRate;
  final int channels;
  final int bitsPerSample;

  /// Samples per channel; 0 when the encoder did not know it.
  final int totalSamples;

  /// MD5 of the unencoded audio (all zero when not computed by the encoder).
  final Uint8List md5;
}

/// Called once per decoded frame. [channels] holds [blockSize] valid samples
/// per channel (the lists themselves may be longer and are reused, so copy
/// anything you want to keep). [bitsPerSample] is the frame's sample size.
typedef FlacFrameCallback = void Function(
    List<Int64List> channels, int blockSize, int bitsPerSample);

class FlacFormatException extends FormatException {
  const FlacFormatException(super.message, [super.source, super.offset]);
}

/// Returns true when [bytes] look like a FLAC stream (optionally behind ID3v2).
bool looksLikeFlac(Uint8List bytes) => _flacStart(bytes) >= 0;

/// Offset of the "fLaC" marker, skipping a leading ID3v2 tag; -1 if absent.
int _flacStart(Uint8List b) {
  var p = 0;
  if (b.length >= 10 && b[0] == 0x49 && b[1] == 0x44 && b[2] == 0x33) {
    // ID3v2: 10 byte header, syncsafe size, optional 10 byte footer.
    final size = (b[6] & 0x7f) << 21 |
        (b[7] & 0x7f) << 14 |
        (b[8] & 0x7f) << 7 |
        (b[9] & 0x7f);
    p = 10 + size + ((b[5] & 0x10) != 0 ? 10 : 0);
  }
  if (p + 4 <= b.length &&
      b[p] == 0x66 &&
      b[p + 1] == 0x4c &&
      b[p + 2] == 0x61 &&
      b[p + 3] == 0x43) {
    return p;
  }
  return -1;
}

class FlacDecoder {
  FlacDecoder(this._data) {
    final start = _flacStart(_data);
    if (start < 0) throw const FlacFormatException('not a FLAC stream');
    var p = start + 4;
    FlacStreamInfo? si;
    while (true) {
      if (p + 4 > _data.length) {
        throw const FlacFormatException('truncated metadata');
      }
      final last = (_data[p] & 0x80) != 0;
      final type = _data[p] & 0x7f;
      final len = _data[p + 1] << 16 | _data[p + 2] << 8 | _data[p + 3];
      p += 4;
      if (p + len > _data.length) {
        throw const FlacFormatException('truncated metadata block');
      }
      if (type == 0) si = _parseStreamInfo(p, len);
      p += len;
      if (last) break;
    }
    if (si == null) throw const FlacFormatException('missing STREAMINFO');
    info = si;
    _audioStart = p;
  }

  final Uint8List _data;
  late final FlacStreamInfo info;
  late final int _audioStart;

  FlacStreamInfo _parseStreamInfo(int p, int len) {
    if (len < 34) throw const FlacFormatException('short STREAMINFO');
    final d = _data;
    final minBs = d[p] << 8 | d[p + 1];
    final maxBs = d[p + 2] << 8 | d[p + 3];
    final sr = d[p + 10] << 12 | d[p + 11] << 4 | d[p + 12] >> 4;
    final ch = ((d[p + 12] >> 1) & 7) + 1;
    final bps = ((d[p + 12] & 1) << 4 | d[p + 13] >> 4) + 1;
    final total = (d[p + 13] & 0x0f) << 32 |
        d[p + 14] << 24 |
        d[p + 15] << 16 |
        d[p + 16] << 8 |
        d[p + 17];
    return FlacStreamInfo(
      minBlockSize: minBs,
      maxBlockSize: maxBs,
      sampleRate: sr,
      channels: ch,
      bitsPerSample: bps,
      totalSamples: total,
      md5: Uint8List.fromList(d.sublist(p + 18, p + 34)),
    );
  }

  // ---------------------------------------------------------------- bit reader
  // [_cache] holds the next [_bits] unread bits in its low end (higher bits
  // are garbage and always masked away). Refilled byte-wise to >= 56 bits.
  int _pos = 0; // next byte to load into the cache
  int _cache = 0;
  int _bits = 0;
  int _overrun = 0; // zero bytes fed past the end of data

  void _seek(int bytePos) {
    _pos = bytePos;
    _cache = 0;
    _bits = 0;
    _overrun = 0;
  }

  /// Byte offset of the next unread bit (bit reader must be byte aligned).
  int get _bytePos => _pos + _overrun - (_bits >> 3);

  void _refill() {
    final d = _data;
    final n = d.length;
    var c = _cache, b = _bits, p = _pos;
    if (p + 8 <= n) {
      while (b < 56) {
        c = (c << 8) | d[p++];
        b += 8;
      }
    } else {
      while (b < 56) {
        if (p < n) {
          c = (c << 8) | d[p++];
        } else {
          c <<= 8;
          _overrun++;
        }
        b += 8;
      }
    }
    _cache = c;
    _bits = b;
    _pos = p;
  }

  /// Unsigned read of 0..56 bits.
  int _read(int n) {
    if (n == 0) return 0;
    if (_bits < n) _refill();
    _bits -= n;
    return (_cache >> _bits) & ((1 << n) - 1);
  }

  /// Two's complement signed read of 1..56 bits.
  int _readSigned(int n) {
    if (n == 0) return 0;
    final v = _read(n);
    final s = 64 - n;
    return (v << s) >> s;
  }

  /// Number of 0 bits before the next 1 bit (the 1 is consumed).
  int _readUnary() {
    var zeros = 0;
    while (true) {
      if (_bits == 0) {
        _refill();
        if (_overrun > 16) throw const FlacFormatException('unexpected EOF');
      }
      final v = _cache & ((1 << _bits) - 1);
      if (v == 0) {
        zeros += _bits;
        _bits = 0;
        continue;
      }
      final top = v.bitLength - 1;
      zeros += _bits - 1 - top;
      _bits = top;
      return zeros;
    }
  }

  void _alignToByte() {
    _bits -= _bits & 7;
  }

  // ------------------------------------------------------------------ decoding
  List<Int64List> _buf = const [];

  /// Decodes every audio frame, calling [onFrame] for each. Returns the number
  /// of samples per channel decoded. Stops at end of data (trailing junk such
  /// as an ID3v1 tag is ignored). Throws [FlacFormatException] when the very
  /// first frame cannot be decoded.
  int decode(FlacFrameCallback onFrame) {
    final maxBs = info.maxBlockSize > 0 ? info.maxBlockSize : 4096;
    _buf = List.generate(info.channels, (_) => Int64List(maxBs));
    var decoded = 0;
    var p = _audioStart;
    var frames = 0;
    final total = info.totalSamples;
    while (p + 2 <= _data.length) {
      if (total > 0 && decoded >= total) break;
      final sync = _findSync(p);
      if (sync < 0) break;
      int? n;
      try {
        n = _decodeFrame(sync);
      } on FlacFormatException {
        if (frames == 0 && sync == _audioStart) rethrow;
        n = null;
      } on RangeError {
        n = null;
      }
      if (n == null) {
        p = sync + 1; // false sync or corrupt frame: resync
        continue;
      }
      frames++;
      var bs = n;
      if (total > 0 && decoded + bs > total) bs = total - decoded;
      onFrame(_buf, bs, _frameBps);
      decoded += bs;
      p = _bytePos;
    }
    if (frames == 0) throw const FlacFormatException('no decodable frames');
    return decoded;
  }

  int _findSync(int p) {
    final d = _data;
    final end = d.length - 1;
    for (var i = p; i < end; i++) {
      if (d[i] == 0xff && (d[i + 1] & 0xfe) == 0xf8) return i;
    }
    return -1;
  }

  int _frameBps = 16;

  static final Uint8List _crc8Table = () {
    final t = Uint8List(256);
    for (var i = 0; i < 256; i++) {
      var c = i;
      for (var j = 0; j < 8; j++) {
        c = (c & 0x80) != 0 ? ((c << 1) ^ 0x07) & 0xff : (c << 1) & 0xff;
      }
      t[i] = c;
    }
    return t;
  }();

  /// Decodes the frame at byte [start]; returns its block size, or null when
  /// the header is invalid (false sync).
  int? _decodeFrame(int start) {
    _seek(start);
    _read(15); // sync + reserved
    _read(1); // blocking strategy (fixed/variable): not needed for decoding
    final bsCode = _read(4);
    final srCode = _read(4);
    final chCode = _read(4);
    final ssCode = _read(3);
    if (_read(1) != 0) return null;
    if (bsCode == 0 || srCode == 15 || chCode > 10 || ssCode == 3) return null;
    // UTF-8 style coded frame/sample number.
    final first = _read(8);
    var extra = 0;
    if (first >= 0x80) {
      if (first == 0xff) return null;
      if (first < 0xc0) return null;
      var m = 0x40;
      while ((first & m) != 0) {
        extra++;
        m >>= 1;
      }
    }
    for (var i = 0; i < extra; i++) {
      if ((_read(8) & 0xc0) != 0x80) return null;
    }
    int blockSize;
    if (bsCode == 1) {
      blockSize = 192;
    } else if (bsCode <= 5) {
      blockSize = 576 << (bsCode - 2);
    } else if (bsCode == 6) {
      blockSize = _read(8) + 1;
    } else if (bsCode == 7) {
      blockSize = _read(16) + 1;
    } else {
      blockSize = 256 << (bsCode - 8);
    }
    if (srCode == 12) {
      _read(8);
    } else if (srCode == 13 || srCode == 14) {
      _read(16);
    }
    // Header CRC-8 covers everything from the sync code up to here.
    final headerEnd = _bytePos;
    var crc = 0;
    final t = _crc8Table;
    for (var i = start; i < headerEnd; i++) {
      crc = t[crc ^ _data[i]];
    }
    if (_read(8) != crc) return null;

    final bps = switch (ssCode) {
      0 => info.bitsPerSample,
      1 => 8,
      2 => 12,
      4 => 16,
      5 => 20,
      6 => 24,
      _ => 32,
    };
    _frameBps = bps;
    final nch = chCode < 8 ? chCode + 1 : 2;
    if (nch != info.channels) return null;
    if (blockSize > _buf[0].length) {
      _buf = List.generate(info.channels, (_) => Int64List(blockSize));
    }
    for (var c = 0; c < nch; c++) {
      var sbps = bps;
      if ((chCode == 8 && c == 1) ||
          (chCode == 9 && c == 0) ||
          (chCode == 10 && c == 1)) {
        sbps++; // side channel carries one extra bit
      }
      _decodeSubframe(_buf[c], blockSize, sbps);
    }
    _alignToByte();
    _read(16); // CRC-16 (not verified)
    if (_bytePos > _data.length) {
      throw const FlacFormatException('truncated frame');
    }

    if (chCode >= 8) {
      final a = _buf[0], b = _buf[1];
      if (chCode == 8) {
        for (var i = 0; i < blockSize; i++) {
          b[i] = a[i] - b[i]; // right = left - side
        }
      } else if (chCode == 9) {
        for (var i = 0; i < blockSize; i++) {
          a[i] = a[i] + b[i]; // left = side + right
        }
      } else {
        for (var i = 0; i < blockSize; i++) {
          final side = b[i];
          final mid = (a[i] << 1) | (side & 1);
          a[i] = (mid + side) >> 1;
          b[i] = (mid - side) >> 1;
        }
      }
    }
    return blockSize;
  }

  final Int64List _coefs = Int64List(32);

  void _decodeSubframe(Int64List out, int n, int bps) {
    if (_read(1) != 0) throw const FlacFormatException('bad subframe pad');
    final type = _read(6);
    var wasted = 0;
    if (_read(1) == 1) wasted = _readUnary() + 1;
    final sbps = bps - wasted;
    if (sbps <= 0) throw const FlacFormatException('bad wasted bits');

    if (type == 0) {
      final v = _readSigned(sbps);
      for (var i = 0; i < n; i++) {
        out[i] = v;
      }
    } else if (type == 1) {
      for (var i = 0; i < n; i++) {
        out[i] = _readSigned(sbps);
      }
    } else if (type >= 8 && type <= 12) {
      final order = type & 7;
      if (order > n) throw const FlacFormatException('order > block size');
      for (var i = 0; i < order; i++) {
        out[i] = _readSigned(sbps);
      }
      _decodeResidual(out, n, order);
      _restoreFixed(out, n, order);
    } else if (type >= 32) {
      final order = (type & 31) + 1;
      if (order > n) throw const FlacFormatException('order > block size');
      for (var i = 0; i < order; i++) {
        out[i] = _readSigned(sbps);
      }
      final precision = _read(4) + 1;
      if (precision == 16) throw const FlacFormatException('bad precision');
      final shift = _readSigned(5);
      if (shift < 0) throw const FlacFormatException('negative LPC shift');
      final coefs = _coefs;
      for (var i = 0; i < order; i++) {
        coefs[i] = _readSigned(precision);
      }
      _decodeResidual(out, n, order);
      _restoreLpc(out, n, order, shift);
    } else {
      throw FlacFormatException('reserved subframe type $type');
    }

    if (wasted > 0) {
      for (var i = 0; i < n; i++) {
        out[i] <<= wasted;
      }
    }
  }

  /// Reads the partitioned Rice residual into out[order..n).
  void _decodeResidual(Int64List out, int n, int order) {
    final method = _read(2);
    if (method > 1) throw const FlacFormatException('reserved residual coding');
    final paramBits = method == 0 ? 4 : 5;
    final escape = method == 0 ? 15 : 31;
    final partOrder = _read(4);
    final parts = 1 << partOrder;
    final partLen = n >> partOrder;
    if ((partLen << partOrder) != n || partLen < order) {
      throw const FlacFormatException('bad partition order');
    }
    final d = _data;
    final dlen = d.length;
    var i = order;
    for (var part = 0; part < parts; part++) {
      final end = (part + 1) * partLen;
      final k = _read(paramBits);
      if (k == escape) {
        final rawBits = _read(5);
        for (; i < end; i++) {
          out[i] = _readSigned(rawBits);
        }
        continue;
      }
      // Hot loop: local copies of the bit reader state.
      var cache = _cache, bits = _bits, pos = _pos;
      final mask = (1 << k) - 1;
      for (; i < end; i++) {
        // Unary quotient.
        var q = 0;
        while (true) {
          if (bits == 0 || (cache & ((1 << bits) - 1)) == 0) {
            q += bits;
            bits = 0;
            if (pos + 8 <= dlen) {
              while (bits < 56) {
                cache = (cache << 8) | d[pos++];
                bits += 8;
              }
            } else {
              _cache = cache;
              _bits = bits;
              _pos = pos;
              _refill();
              if (_overrun > 16) {
                throw const FlacFormatException('unexpected EOF');
              }
              cache = _cache;
              bits = _bits;
              pos = _pos;
            }
            continue;
          }
          final top = (cache & ((1 << bits) - 1)).bitLength - 1;
          q += bits - 1 - top;
          bits = top;
          break;
        }
        // k-bit remainder.
        if (bits < k) {
          if (pos + 8 <= dlen) {
            while (bits < 56) {
              cache = (cache << 8) | d[pos++];
              bits += 8;
            }
          } else {
            _cache = cache;
            _bits = bits;
            _pos = pos;
            _refill();
            cache = _cache;
            bits = _bits;
            pos = _pos;
          }
        }
        bits -= k;
        final u = (q << k) | ((cache >> bits) & mask);
        out[i] = (u >> 1) ^ -(u & 1);
      }
      _cache = cache;
      _bits = bits;
      _pos = pos;
    }
  }

  static void _restoreFixed(Int64List s, int n, int order) {
    switch (order) {
      case 0:
        break;
      case 1:
        for (var i = 1; i < n; i++) {
          s[i] += s[i - 1];
        }
      case 2:
        for (var i = 2; i < n; i++) {
          s[i] += 2 * s[i - 1] - s[i - 2];
        }
      case 3:
        for (var i = 3; i < n; i++) {
          s[i] += 3 * s[i - 1] - 3 * s[i - 2] + s[i - 3];
        }
      case 4:
        for (var i = 4; i < n; i++) {
          s[i] += 4 * s[i - 1] - 6 * s[i - 2] + 4 * s[i - 3] - s[i - 4];
        }
    }
  }

  void _restoreLpc(Int64List s, int n, int order, int shift) {
    final c = _coefs;
    // Unrolled common orders; generic fallback otherwise.
    if (order == 8) {
      final c0 = c[0], c1 = c[1], c2 = c[2], c3 = c[3];
      final c4 = c[4], c5 = c[5], c6 = c[6], c7 = c[7];
      for (var i = 8; i < n; i++) {
        final sum = c0 * s[i - 1] +
            c1 * s[i - 2] +
            c2 * s[i - 3] +
            c3 * s[i - 4] +
            c4 * s[i - 5] +
            c5 * s[i - 6] +
            c6 * s[i - 7] +
            c7 * s[i - 8];
        s[i] += sum >> shift;
      }
      return;
    }
    if (order == 12) {
      final c0 = c[0], c1 = c[1], c2 = c[2], c3 = c[3];
      final c4 = c[4], c5 = c[5], c6 = c[6], c7 = c[7];
      final c8 = c[8], c9 = c[9], c10 = c[10], c11 = c[11];
      for (var i = 12; i < n; i++) {
        final sum = c0 * s[i - 1] +
            c1 * s[i - 2] +
            c2 * s[i - 3] +
            c3 * s[i - 4] +
            c4 * s[i - 5] +
            c5 * s[i - 6] +
            c6 * s[i - 7] +
            c7 * s[i - 8] +
            c8 * s[i - 9] +
            c9 * s[i - 10] +
            c10 * s[i - 11] +
            c11 * s[i - 12];
        s[i] += sum >> shift;
      }
      return;
    }
    for (var i = order; i < n; i++) {
      var sum = 0;
      for (var j = 0; j < order; j++) {
        sum += c[j] * s[i - 1 - j];
      }
      s[i] += sum >> shift;
    }
  }
}
