// Amplitude envelope of a song for the circular "polar pulse plot".
//
// Pure Dart: decodes FLAC and WAV itself (see flac_decoder.dart and
// wav_reader.dart), streaming samples into per-bin accumulators so the whole
// PCM never sits in memory. Decoding runs in a background isolate.

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'flac_decoder.dart';
import 'wav_reader.dart';

/// Amplitude envelope of a song: [bins] equal time slices over the whole file.
class Envelope {
  const Envelope({required this.peak, required this.rms, required this.seconds});

  /// Per bin max |sample| over all channels, normalised so the loudest bin = 1.0.
  final List<double> peak;

  /// Per bin RMS, normalised by the same factor as [peak] (so rms <= peak).
  final List<double> rms;

  /// Duration of the audio.
  final double seconds;

  int get bins => peak.length;

  static const String format = 'studio-localhost/envelope';
  static const int version = 1;

  Map<String, dynamic> toJson() => {
        'format': format,
        'version': version,
        'seconds': seconds,
        'bins': bins,
        'peak': [for (final v in peak) _round4(v)],
        'rms': [for (final v in rms) _round4(v)],
      };

  static double _round4(double v) => (v * 10000).round() / 10000;

  static Envelope? fromJson(Map<String, dynamic> j) {
    try {
      if (j['format'] != format || j['version'] != version) return null;
      final seconds = (j['seconds'] as num).toDouble();
      final peak = [for (final v in j['peak'] as List) (v as num).toDouble()];
      final rms = [for (final v in j['rms'] as List) (v as num).toDouble()];
      if (peak.isEmpty || peak.length != rms.length) return null;
      final bins = j['bins'];
      if (bins is num && bins.toInt() != peak.length) return null;
      if (!seconds.isFinite || seconds < 0) return null;
      return Envelope(
        peak: List.unmodifiable(peak),
        rms: List.unmodifiable(rms),
        seconds: seconds,
      );
    } catch (_) {
      return null;
    }
  }

  /// A shorter envelope (max-pool peak, mean rms) for small plots.
  /// Also works for a larger [bins] (values are repeated).
  Envelope resample(int bins) {
    if (bins <= 0) throw ArgumentError.value(bins, 'bins', 'must be > 0');
    final src = this.bins;
    if (src == 0) {
      return Envelope(
        peak: List.filled(bins, 0.0),
        rms: List.filled(bins, 0.0),
        seconds: seconds,
      );
    }
    final p = Float64List(bins), r = Float64List(bins);
    for (var j = 0; j < bins; j++) {
      final start = j * src ~/ bins;
      var end = ((j + 1) * src + bins - 1) ~/ bins;
      if (end <= start) end = start + 1;
      if (end > src) end = src;
      var mx = 0.0, sum = 0.0;
      for (var i = start; i < end; i++) {
        if (peak[i] > mx) mx = peak[i];
        sum += rms[i];
      }
      p[j] = mx;
      r[j] = sum / (end - start);
    }
    return Envelope(
      peak: List.unmodifiable(p),
      rms: List.unmodifiable(r),
      seconds: seconds,
    );
  }
}

/// Compute from an audio file (FLAC or WAV, detected by content). Returns null
/// for unsupported formats (e.g. mp3) or unreadable/corrupt files instead of
/// throwing. Decoding runs in a background isolate.
Future<Envelope?> computeEnvelope(String audioPath, {int bins = 720}) async {
  try {
    return await Isolate.run(() => computeEnvelopeSync(audioPath, bins: bins));
  } catch (_) {
    return null;
  }
}

/// Cached envelope: reads/writes JSON at [cachePath]; recomputes when the
/// cache is missing, unreadable, has a different bin count, or is older than
/// the audio file (mtime).
Future<Envelope?> loadOrComputeEnvelope(String audioPath, String cachePath,
    {int bins = 720}) async {
  try {
    final audio = File(audioPath);
    final cache = File(cachePath);
    if (await cache.exists()) {
      final audioTime = (await audio.stat()).modified;
      final cacheTime = (await cache.stat()).modified;
      if (!cacheTime.isBefore(audioTime)) {
        final j = jsonDecode(await cache.readAsString());
        if (j is Map<String, dynamic>) {
          final e = Envelope.fromJson(j);
          if (e != null && e.bins == bins) return e;
        }
      }
    }
  } catch (_) {
    // Unreadable cache: fall through and recompute.
  }
  final env = await computeEnvelope(audioPath, bins: bins);
  if (env != null) {
    try {
      final cache = File(cachePath);
      await cache.parent.create(recursive: true);
      final tmp = File('$cachePath.tmp$pid');
      await tmp.writeAsString(jsonEncode(env.toJson()), flush: true);
      await tmp.rename(cachePath);
    } catch (_) {
      // Cache is best effort.
    }
  }
  return env;
}

/// Synchronous computation (what [computeEnvelope] runs in its isolate).
/// Returns null for unsupported formats; throws [FormatException] for files
/// that claim to be FLAC/WAV but cannot be decoded.
Envelope? computeEnvelopeSync(String audioPath, {int bins = 720}) {
  if (bins <= 0) throw ArgumentError.value(bins, 'bins', 'must be > 0');
  final bytes = File(audioPath).readAsBytesSync();
  if (looksLikeFlac(bytes)) {
    final dec = FlacDecoder(bytes);
    final info = dec.info;
    final acc = _Accumulator(bins, info.totalSamples, info.channels);
    final decoded = dec.decode((ch, n, bps) {
      acc.addInt(ch, n, 1.0 / (1 << (bps - 1)));
    });
    if (info.sampleRate <= 0) return null;
    return acc.finish(decoded / info.sampleRate);
  }
  if (looksLikeWav(bytes)) {
    final WavReader wav;
    try {
      wav = WavReader(bytes);
    } on UnsupportedError {
      return null;
    }
    final acc = _Accumulator(bins, wav.totalFrames, wav.channels);
    final n = wav.read(acc.addFloat);
    return acc.finish(n / wav.sampleRate);
  }
  return null;
}

/// Streams samples into [bins] bins. With a known total, bin b holds samples
/// [ceil(b*total/bins), ceil((b+1)*total/bins)) exactly. With an unknown
/// total (0), samples go into fixed chunks that are pooled into bins at the end.
class _Accumulator {
  _Accumulator(this.bins, this.total, this.nch)
      : _known = total > 0,
        _peak = Float64List(total > 0 ? bins : 1024),
        _sumSq = Float64List(total > 0 ? bins : 1024),
        _count = Int64List(total > 0 ? bins : 1024) {
    _next = _boundary(1);
    _skipEmpty();
  }

  static const int _chunk = 256; // frames per chunk in unknown-length mode

  final int bins;
  final int total;
  final int nch;
  final bool _known;
  Float64List _peak, _sumSq;
  Int64List _count;
  int _pos = 0; // frames consumed
  int _bin = 0;
  int _next = 0; // first frame index of the next bin

  int _boundary(int b) {
    if (!_known) return b * _chunk;
    if (b >= bins) return 1 << 62; // overflow samples stay in the last bin
    return (b * total + bins - 1) ~/ bins;
  }

  void _skipEmpty() {
    while (_next <= _pos) {
      _bin++;
      _next = _boundary(_bin + 1);
    }
    if (!_known && _bin >= _peak.length) {
      final size = _peak.length * 2;
      _peak = Float64List(size)..setAll(0, _peak);
      _sumSq = Float64List(size)..setAll(0, _sumSq);
      _count = Int64List(size)..setAll(0, _count);
    }
  }

  void addInt(List<Int64List> ch, int n, double scale) {
    var i = 0;
    while (i < n) {
      final room = _next - _pos;
      final end = room < n - i ? i + room : n;
      var mx = 0;
      var ss = 0.0;
      for (var c = 0; c < nch; c++) {
        final s = ch[c];
        for (var j = i; j < end; j++) {
          final v = s[j];
          final a = v < 0 ? -v : v;
          if (a > mx) mx = a;
          final d = v.toDouble();
          ss += d * d;
        }
      }
      final b = _bin;
      final pk = mx * scale;
      if (pk > _peak[b]) _peak[b] = pk;
      _sumSq[b] += ss * scale * scale;
      _count[b] += end - i;
      _pos += end - i;
      i = end;
      if (_pos >= _next) _skipEmpty();
    }
  }

  void addFloat(List<Float64List> ch, int n) {
    var i = 0;
    while (i < n) {
      final room = _next - _pos;
      final end = room < n - i ? i + room : n;
      var mx = 0.0;
      var ss = 0.0;
      for (var c = 0; c < nch; c++) {
        final s = ch[c];
        for (var j = i; j < end; j++) {
          final v = s[j];
          final a = v.abs();
          if (a > mx) mx = a; // NaN never wins this comparison
          ss += v * v;
        }
      }
      final b = _bin;
      if (mx > _peak[b]) _peak[b] = mx;
      if (ss.isFinite) _sumSq[b] += ss;
      _count[b] += end - i;
      _pos += end - i;
      i = end;
      if (_pos >= _next) _skipEmpty();
    }
  }

  Envelope finish(double seconds) {
    final peak = Float64List(bins), rms = Float64List(bins);
    if (_known) {
      for (var b = 0; b < bins; b++) {
        peak[b] = _peak[b];
        final c = _count[b];
        rms[b] = c > 0 ? math.sqrt(_sumSq[b] / (c * nch)) : 0.0;
      }
    } else {
      // Pool fixed-size chunks into bins by chunk start position.
      final frames = _pos;
      final chunks = (frames + _chunk - 1) ~/ _chunk;
      final ss = Float64List(bins);
      final cnt = Int64List(bins);
      for (var k = 0; k < chunks; k++) {
        final b = frames > 0 ? (k * _chunk * bins) ~/ frames : 0;
        if (_peak[k] > peak[b]) peak[b] = _peak[k];
        ss[b] += _sumSq[k];
        cnt[b] += _count[k];
      }
      for (var b = 0; b < bins; b++) {
        rms[b] = cnt[b] > 0 ? math.sqrt(ss[b] / (cnt[b] * nch)) : 0.0;
      }
    }
    var top = 0.0;
    for (var b = 0; b < bins; b++) {
      if (peak[b] > top) top = peak[b];
    }
    if (top > 0) {
      final inv = 1.0 / top;
      for (var b = 0; b < bins; b++) {
        peak[b] *= inv;
        rms[b] = math.min(rms[b] * inv, peak[b]);
      }
    }
    return Envelope(
      peak: List.unmodifiable(peak),
      rms: List.unmodifiable(rms),
      seconds: seconds,
    );
  }
}
