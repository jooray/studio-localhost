import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:studio_localhost/core/audio/envelope.dart';
import 'package:studio_localhost/core/audio/flac_decoder.dart';

const _vocalise = '/Users/juraj/tmp/yue2/outputs/vocalise_1/audio.flac';
final _home = Platform.environment['HOME'] ?? '/Users/juraj';

class _DigestSink implements Sink<Digest> {
  Digest? value;
  @override
  void add(Digest data) => value = data;
  @override
  void close() {}
}

String _hex(List<int> b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

/// Fully decodes [path]; returns hex MD5 of the PCM in FLAC's MD5 layout
/// (interleaved, little endian, ceil(bps/8) bytes per sample) and frame count.
(String, int) _flacMd5(String path) {
  final dec = FlacDecoder(File(path).readAsBytesSync());
  final sink = _DigestSink();
  final md5in = md5.startChunkedConversion(sink);
  var buf = Uint8List(0);
  final n = dec.decode((ch, n, bps) {
    final bytes = (bps + 7) >> 3;
    final need = n * ch.length * bytes;
    if (buf.length < need) buf = Uint8List(need);
    var o = 0;
    for (var i = 0; i < n; i++) {
      for (var c = 0; c < ch.length; c++) {
        var v = ch[c][i];
        for (var k = 0; k < bytes; k++) {
          buf[o++] = v & 0xff;
          v >>= 8;
        }
      }
    }
    md5in.add(Uint8List.sublistView(buf, 0, need));
  });
  md5in.close();
  return (sink.value.toString(), n);
}

Future<String> _writeWav(String path, List<Float64List> ch, int sampleRate,
    {required int bits, required bool float, bool extensible = false}) async {
  final nch = ch.length, frames = ch[0].length, bps = bits >> 3;
  final dataLen = frames * nch * bps;
  final fmtLen = extensible ? 40 : 16;
  final bd = ByteData(12 + 8 + fmtLen + 8 + dataLen);
  var o = 0;
  void str(String s) {
    for (final c in s.codeUnits) {
      bd.setUint8(o++, c);
    }
  }

  void u16(int v) {
    bd.setUint16(o, v, Endian.little);
    o += 2;
  }

  void u32(int v) {
    bd.setUint32(o, v, Endian.little);
    o += 4;
  }

  str('RIFF');
  u32(bd.lengthInBytes - 8);
  str('WAVE');
  str('fmt ');
  u32(fmtLen);
  final tag = float ? 3 : 1;
  u16(extensible ? 0xfffe : tag);
  u16(nch);
  u32(sampleRate);
  u32(sampleRate * nch * bps);
  u16(nch * bps);
  u16(bits);
  if (extensible) {
    u16(22);
    u16(bits);
    u32(3);
    u16(tag);
    for (final b in [0, 0, 0, 0, 0x10, 0, 0x80, 0, 0, 0xaa, 0, 0x38, 0x9b, 0x71]) {
      bd.setUint8(o++, b);
    }
  }
  str('data');
  u32(dataLen);
  for (var i = 0; i < frames; i++) {
    for (var c = 0; c < nch; c++) {
      final x = ch[c][i];
      if (float) {
        bits == 32
            ? bd.setFloat32(o, x, Endian.little)
            : bd.setFloat64(o, x, Endian.little);
      } else if (bits == 8) {
        bd.setUint8(o, (x * 127).round() + 128);
      } else if (bits == 16) {
        bd.setInt16(o, (x * 32767).round(), Endian.little);
      } else if (bits == 24) {
        final v = (x * 8388607).round();
        bd.setUint8(o, v & 0xff);
        bd.setUint8(o + 1, (v >> 8) & 0xff);
        bd.setUint8(o + 2, (v >> 16) & 0xff);
      } else {
        bd.setInt32(o, (x * 2147483647).round(), Endian.little);
      }
      o += bps;
    }
  }
  await File(path).writeAsBytes(bd.buffer.asUint8List());
  return path;
}

List<String> _allFlacs() {
  final out = <String>[];
  for (final root in [
    '/Users/juraj/tmp/yue2/outputs',
    p.join(_home, 'Library/Application Support/YuE2 Studio/library'),
  ]) {
    final d = Directory(root);
    if (!d.existsSync()) continue;
    for (final sub in d.listSync().whereType<Directory>()) {
      final f = File(p.join(sub.path, 'audio.flac'));
      if (f.existsSync()) out.add(f.path);
    }
  }
  out.sort();
  return out;
}

void main() {
  late Directory tmp;
  setUpAll(() async {
    tmp = await Directory.systemTemp.createTemp('envelope_test');
  });
  tearDownAll(() async {
    await tmp.delete(recursive: true);
  });

  group('synthetic WAV', () {
    const sr = 48000, frames = 96000, bins = 20;
    // Stereo 1 kHz sine with linear amplitude ramp 0.1 -> 0.9; right = 0.5*left.
    final left = Float64List(frames), right = Float64List(frames);
    for (var i = 0; i < frames; i++) {
      final amp = 0.1 + 0.8 * i / frames;
      left[i] = amp * math.sin(2 * math.pi * 1000 * i / sr);
      right[i] = 0.5 * left[i];
    }
    // Exact expected envelope from the double signal with the same binning.
    final expPeak = Float64List(bins), expSs = Float64List(bins);
    final expCnt = Int64List(bins);
    for (var i = 0; i < frames; i++) {
      final b = i * bins ~/ frames;
      expPeak[b] = math.max(expPeak[b], left[i].abs());
      expSs[b] += left[i] * left[i] + right[i] * right[i];
      expCnt[b] += 2;
    }
    final top = expPeak.reduce(math.max);

    for (final (bits, float, ext, tol) in [
      (16, false, false, 1e-4),
      (32, true, false, 1e-6),
      (24, false, true, 1e-5),
      (8, false, false, 2e-2),
      (32, false, false, 1e-6),
      (64, true, true, 1e-9),
    ]) {
      test('${float ? 'float' : 'int'}$bits${ext ? ' extensible' : ''}',
          () async {
        final path = await _writeWav(
            p.join(tmp.path, 'sine_${bits}_$float$ext.wav'), [left, right], sr,
            bits: bits, float: float, extensible: ext);
        final env = await computeEnvelope(path, bins: bins);
        expect(env, isNotNull);
        expect(env!.bins, bins);
        expect(env.seconds, closeTo(2.0, 1e-9));
        expect(env.peak.reduce(math.max), 1.0);
        for (var b = 0; b < bins; b++) {
          expect(env.peak[b], closeTo(expPeak[b] / top, tol), reason: 'peak $b');
          final r = math.sqrt(expSs[b] / expCnt[b]) / top;
          expect(env.rms[b], closeTo(r, tol), reason: 'rms $b');
          expect(env.rms[b], lessThanOrEqualTo(env.peak[b]));
          // Analytic sanity: peak ~ ramp amplitude at the bin end.
          final ampEnd = 0.1 + 0.8 * (b + 1) / bins;
          expect(env.peak[b], closeTo(ampEnd / 0.9, 0.02));
        }
      });
    }
  });

  group('Envelope API', () {
    final env = Envelope(
      peak: [for (var i = 0; i < 8; i++) (i + 1) / 8],
      rms: [for (var i = 0; i < 8; i++) (i + 1) / 16],
      seconds: 12.5,
    );

    test('json round trip', () {
      final j = jsonDecode(jsonEncode(env.toJson())) as Map<String, dynamic>;
      expect(j['format'], 'studio-localhost/envelope');
      expect(j['version'], 1);
      expect(j['bins'], 8);
      final back = Envelope.fromJson(j)!;
      expect(back.seconds, 12.5);
      expect(back.peak, env.peak);
      expect(back.rms, [for (final v in env.rms) (v * 1e4).round() / 1e4]);
      expect(Envelope.fromJson({'format': 'x'}), isNull);
      expect(Envelope.fromJson({...j, 'peak': [1.0]}), isNull);
    });

    test('resample', () {
      final r = env.resample(4);
      expect(r.bins, 4);
      expect(r.peak, [0.25, 0.5, 0.75, 1.0]);
      expect(r.rms[0], closeTo((1 / 16 + 2 / 16) / 2, 1e-12));
      expect(r.seconds, 12.5);
      final u = env.resample(16);
      expect(u.bins, 16);
      expect(u.peak.reduce(math.max), 1.0);
      final odd = env.resample(3);
      expect(odd.peak, [3 / 8, 6 / 8, 1.0]);
    });

    test('unsupported formats return null', () async {
      final mp3 = File(p.join(tmp.path, 'x.mp3'));
      await mp3.writeAsBytes([0x49, 0x44, 0x33, 3, 0, 0, 0, 0, 0, 0, 0xff, 0xfb, 0x90, 0x44, ...List.filled(500, 0)]);
      expect(await computeEnvelope(mp3.path), isNull);
      expect(await computeEnvelope(p.join(tmp.path, 'missing.flac')), isNull);
      final broken = File(p.join(tmp.path, 'broken.flac'));
      await broken.writeAsBytes([0x66, 0x4c, 0x61, 0x43, 0x80, 0, 0, 34, ...List.filled(10, 0)]);
      expect(await computeEnvelope(broken.path), isNull);
    });

    test('loadOrComputeEnvelope caches and invalidates', () async {
      final sig = Float64List(4800);
      for (var i = 0; i < sig.length; i++) {
        sig[i] = 0.5 * math.sin(i / 10) * i / sig.length;
      }
      final wav = await _writeWav(p.join(tmp.path, 'c.wav'), [sig], 48000,
          bits: 16, float: false);
      final cache = p.join(tmp.path, 'cache', 'c.envelope.json');
      final a = await loadOrComputeEnvelope(wav, cache, bins: 50);
      expect(a, isNotNull);
      expect(File(cache).existsSync(), isTrue);
      // Tamper with the cache: a valid cache is returned as is.
      final j = jsonDecode(File(cache).readAsStringSync()) as Map<String, dynamic>;
      j['seconds'] = 99.0;
      File(cache).writeAsStringSync(jsonEncode(j));
      expect((await loadOrComputeEnvelope(wav, cache, bins: 50))!.seconds, 99.0);
      // Different bin count -> recompute.
      final c = await loadOrComputeEnvelope(wav, cache, bins: 25);
      expect(c!.bins, 25);
      expect(c.seconds, closeTo(0.1, 1e-9));
      // Garbage cache -> recompute.
      File(cache).writeAsStringSync('{not json');
      expect((await loadOrComputeEnvelope(wav, cache, bins: 25))!.bins, 25);
      // Cache older than audio -> recompute.
      j['bins'] = 25;
      j['peak'] = List.filled(25, 1.0);
      j['rms'] = List.filled(25, 0.5);
      File(cache).writeAsStringSync(jsonEncode(j));
      File(cache).setLastModifiedSync(DateTime.now().subtract(const Duration(hours: 1)));
      final d = await loadOrComputeEnvelope(wav, cache, bins: 25);
      expect(d!.seconds, closeTo(0.1, 1e-9));
    });
  });

  group('real FLAC', () {
    final haveVocalise = File(_vocalise).existsSync();

    test('vocalise_1 envelope matches soundfile reference', () async {
      final ref = jsonDecode(File('test/audio/fixtures/vocalise_1_envelope_ref.json')
          .readAsStringSync()) as Map<String, dynamic>;
      final sw = Stopwatch()..start();
      final env = await computeEnvelope(_vocalise, bins: 720);
      sw.stop();
      // ignore: avoid_print
      print('vocalise_1 envelope (JIT, isolate): ${sw.elapsedMilliseconds} ms');
      expect(env, isNotNull);
      expect(env!.bins, 720);
      expect(env.seconds, closeTo((ref['seconds'] as num).toDouble(), 1e-9));
      final rp = (ref['peak'] as List).cast<num>();
      final rr = (ref['rms'] as List).cast<num>();
      var dp = 0.0, dr = 0.0;
      for (var b = 0; b < 720; b++) {
        dp = math.max(dp, (env.peak[b] - rp[b]).abs());
        dr = math.max(dr, (env.rms[b] - rr[b]).abs());
      }
      // ignore: avoid_print
      print('max |diff| peak=$dp rms=$dr');
      expect(dp, lessThan(1e-3));
      expect(dr, lessThan(1e-3));
    }, skip: haveVocalise ? false : 'missing $_vocalise');

    test('vocalise_1 first 100k frames bit exact vs soundfile', () {
      final ref = jsonDecode(File('test/audio/fixtures/vocalise_1_envelope_ref.json')
          .readAsStringSync()) as Map<String, dynamic>;
      final dec = FlacDecoder(File(_vocalise).readAsBytesSync());
      const want = 100000;
      final pcm = Int32List(want * 2);
      var got = 0;
      dec.decode((ch, n, bps) {
        for (var i = 0; i < n && got < want; i++, got++) {
          pcm[got * 2] = ch[0][i];
          pcm[got * 2 + 1] = ch[1][i];
        }
      });
      expect(got, want);
      final bytes = pcm.buffer.asUint8List();
      expect(sha256.convert(bytes).toString(), ref['first100kSha256']);
      final sums = [0, 0];
      for (var i = 0; i < want; i++) {
        sums[0] += pcm[i * 2];
        sums[1] += pcm[i * 2 + 1];
      }
      expect(sums, ref['first100kSum']);
      expect([pcm[100000], pcm[100001]], ref['samples_at_50000']);
    }, skip: haveVocalise ? false : 'missing $_vocalise');

    final flacs = _allFlacs();
    for (final f in flacs) {
      test('decode ${p.basename(p.dirname(f))}: no throw, MD5 matches STREAMINFO',
          () {
        final sw = Stopwatch()..start();
        final env = computeEnvelopeSync(f);
        final t1 = sw.elapsedMilliseconds;
        expect(env, isNotNull);
        final info = FlacDecoder(File(f).readAsBytesSync()).info;
        final (md5hex, frames) = _flacMd5(f);
        expect(frames, info.totalSamples);
        if (info.md5.any((b) => b != 0)) expect(md5hex, _hex(info.md5));
        // ignore: avoid_print
        print('${p.basename(p.dirname(f))}: ${env!.seconds.toStringAsFixed(2)} s, '
            '${info.sampleRate} Hz ${info.channels} ch ${info.bitsPerSample} bit, '
            'envelope $t1 ms (JIT), md5 ok');
      });
    }
  });
}
