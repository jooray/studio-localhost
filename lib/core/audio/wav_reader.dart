// Minimal pure-Dart WAV (RIFF/WAVE) reader for analysis.
//
// Supports PCM integer 8 (unsigned) / 16 / 24 / 32-bit, IEEE float 32 / 64-bit,
// and WAVE_FORMAT_EXTENSIBLE wrapping either. Samples are delivered in blocks
// as per-channel [Float64List]s normalised to [-1, 1] (floats as stored).

import 'dart:typed_data';

class WavFormatException extends FormatException {
  const WavFormatException(super.message);
}

/// True when [b] starts with a RIFF/WAVE header.
bool looksLikeWav(Uint8List b) =>
    b.length >= 12 &&
    b[0] == 0x52 && // R
    b[1] == 0x49 && // I
    b[2] == 0x46 && // F
    b[3] == 0x46 && // F
    b[8] == 0x57 && // W
    b[9] == 0x41 && // A
    b[10] == 0x56 && // V
    b[11] == 0x45; // E

/// Called per block; [channels] hold [frames] valid samples each (buffers are
/// reused between calls).
typedef WavBlockCallback = void Function(List<Float64List> channels, int frames);

class WavReader {
  WavReader(this._data) {
    if (!looksLikeWav(_data)) throw const WavFormatException('not a WAV file');
    final bd = ByteData.sublistView(_data);
    var p = 12;
    int? fmtTag;
    while (p + 8 <= _data.length) {
      final id = String.fromCharCodes(_data, p, p + 4);
      var size = bd.getUint32(p + 4, Endian.little);
      final body = p + 8;
      if (id == 'fmt ') {
        if (size < 16 || body + size > _data.length) {
          throw const WavFormatException('bad fmt chunk');
        }
        fmtTag = bd.getUint16(body, Endian.little);
        channels = bd.getUint16(body + 2, Endian.little);
        sampleRate = bd.getUint32(body + 4, Endian.little);
        blockAlign = bd.getUint16(body + 12, Endian.little);
        bitsPerSample = bd.getUint16(body + 14, Endian.little);
        if (fmtTag == 0xfffe) {
          if (size < 40) throw const WavFormatException('bad extensible fmt');
          // SubFormat GUID: first two bytes are the actual format tag.
          fmtTag = bd.getUint16(body + 24, Endian.little);
          final valid = bd.getUint16(body + 18, Endian.little);
          if (valid != 0) validBits = valid;
        }
      } else if (id == 'data') {
        _dataStart = body;
        // Streamed/unfinished files may carry 0 or 0xFFFFFFFF: use what's there.
        if (size == 0 || size == 0xffffffff || body + size > _data.length) {
          size = _data.length - body;
        }
        _dataLength = size;
        break;
      }
      p = body + size + (size & 1);
    }
    if (fmtTag == null) throw const WavFormatException('missing fmt chunk');
    if (_dataStart < 0) throw const WavFormatException('missing data chunk');
    if (channels <= 0 || sampleRate <= 0) {
      throw const WavFormatException('bad channel count or sample rate');
    }
    if (fmtTag == 1) {
      isFloat = false;
      if (![8, 16, 24, 32].contains(bitsPerSample)) {
        throw WavFormatException('unsupported PCM bit depth $bitsPerSample');
      }
    } else if (fmtTag == 3) {
      isFloat = true;
      if (bitsPerSample != 32 && bitsPerSample != 64) {
        throw WavFormatException('unsupported float bit depth $bitsPerSample');
      }
    } else {
      throw UnsupportedError('unsupported WAV format tag $fmtTag');
    }
    final bytesPerSample = bitsPerSample >> 3;
    if (blockAlign < bytesPerSample * channels) {
      blockAlign = bytesPerSample * channels;
    }
    totalFrames = _dataLength ~/ blockAlign;
  }

  final Uint8List _data;
  int channels = 0;
  int sampleRate = 0;
  int bitsPerSample = 0;
  int? validBits;
  int blockAlign = 0;
  bool isFloat = false;
  int totalFrames = 0;
  int _dataStart = -1;
  int _dataLength = 0;

  /// Streams all frames in blocks of [blockFrames]; returns frames read.
  int read(WavBlockCallback onBlock, {int blockFrames = 8192}) {
    final nch = channels;
    final bufs = List.generate(nch, (_) => Float64List(blockFrames));
    final bd = ByteData.sublistView(_data);
    final bps = bitsPerSample >> 3;
    final align = blockAlign;
    var frame = 0;
    while (frame < totalFrames) {
      final n =
          totalFrames - frame < blockFrames ? totalFrames - frame : blockFrames;
      final base = _dataStart + frame * align;
      for (var c = 0; c < nch; c++) {
        final out = bufs[c];
        var p = base + c * bps;
        if (isFloat) {
          if (bps == 4) {
            for (var i = 0; i < n; i++, p += align) {
              out[i] = bd.getFloat32(p, Endian.little);
            }
          } else {
            for (var i = 0; i < n; i++, p += align) {
              out[i] = bd.getFloat64(p, Endian.little);
            }
          }
        } else {
          switch (bps) {
            case 1:
              for (var i = 0; i < n; i++, p += align) {
                out[i] = (_data[p] - 128) / 128.0;
              }
            case 2:
              for (var i = 0; i < n; i++, p += align) {
                out[i] = bd.getInt16(p, Endian.little) / 32768.0;
              }
            case 3:
              final d = _data;
              for (var i = 0; i < n; i++, p += align) {
                var v = d[p] | d[p + 1] << 8 | d[p + 2] << 16;
                if (v >= 0x800000) v -= 0x1000000;
                out[i] = v / 8388608.0;
              }
            default:
              for (var i = 0; i < n; i++, p += align) {
                out[i] = bd.getInt32(p, Endian.little) / 2147483648.0;
              }
          }
        }
      }
      onBlock(bufs, n);
      frame += n;
    }
    return frame;
  }
}
