// FLAC decoder coverage beyond the app's own (24-bit stereo, fixed block)
// files: bit depths, channel counts, block sizes, wasted bits, every stereo
// mode, LPC orders, Rice2, escaped partitions, variable block sizes and
// unknown stream length.
//
// Part 1 encodes synthetic WAVs with the reference `flac` CLI and ffmpeg (when
// on PATH) and checks our decode against the STREAMINFO MD5.
// Part 2 builds a stream by hand (variable blocksize, escapes, ...) whose
// exact samples are known, and validates it with `flac -t` when available.

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:studio_localhost/core/audio/envelope.dart';
import 'package:studio_localhost/core/audio/flac_decoder.dart';

bool _has(String tool) {
  try {
    return Process.runSync('which', [tool]).exitCode == 0;
  } catch (_) {
    return false;
  }
}

String _hex(List<int> b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

/// MD5 over int samples in FLAC layout (interleaved LE, ceil(bps/8) bytes).
String _md5Of(List<Int64List> ch, int frames, int bps) {
  final bytes = (bps + 7) >> 3;
  final out = Uint8List(frames * ch.length * bytes);
  var o = 0;
  for (var i = 0; i < frames; i++) {
    for (final c in ch) {
      var v = c[i];
      for (var k = 0; k < bytes; k++) {
        out[o++] = v & 0xff;
        v >>= 8;
      }
    }
  }
  return md5.convert(out).toString();
}

/// Decodes a whole FLAC file into memory (test helper only).
(FlacStreamInfo, List<Int64List>, int) _decodeAll(String path) {
  final dec = FlacDecoder(File(path).readAsBytesSync());
  final nch = dec.info.channels;
  var cap = dec.info.totalSamples > 0 ? dec.info.totalSamples : 1 << 16;
  var out = List.generate(nch, (_) => Int64List(cap));
  var n = 0;
  dec.decode((ch, bs, bps) {
    if (n + bs > cap) {
      cap = (n + bs) * 2;
      out = [for (final o in out) Int64List(cap)..setAll(0, o.sublist(0, n))];
    }
    for (var c = 0; c < nch; c++) {
      out[c].setRange(n, n + bs, ch[c]);
    }
    n += bs;
  });
  return (dec.info, out, n);
}

/// Deterministic test signal: sine + noise + silent and coarse sections.
List<Int64List> _signal(int nch, int frames, int bits, int seed,
    {int wastedBits = 0}) {
  final rnd = math.Random(seed);
  final full = (1 << (bits - 1)) - 1;
  return List.generate(nch, (c) {
    final s = Int64List(frames);
    for (var i = 0; i < frames; i++) {
      final t = i / 44100;
      double x;
      final seg = (i * 8 ~/ frames);
      if (seg == 2) {
        x = 0; // silence -> CONSTANT subframes
      } else if (seg == 5) {
        x = rnd.nextDouble() * 2 - 1; // full-scale noise -> VERBATIM / escapes
      } else {
        x = 0.6 * math.sin(2 * math.pi * (220 + 110 * c) * t) +
            0.25 * math.sin(2 * math.pi * 3150 * t + c) +
            0.05 * (rnd.nextDouble() * 2 - 1);
      }
      var v = (x * full).round().clamp(-full - 1, full);
      if (wastedBits > 0) v = (v >> wastedBits) << wastedBits;
      s[i] = v;
    }
    return s;
  });
}

/// Writes PCM WAV; [container] bits per sample in file, [valid] real bits.
void _writeWav(String path, List<Int64List> ch, int frames, int sampleRate,
    int valid) {
  final container = ((valid + 7) >> 3) * 8;
  final bps = container >> 3, nch = ch.length;
  final shift = container - valid;
  final ext = shift != 0 || nch > 2;
  final fmtLen = ext ? 40 : 16;
  final dataLen = frames * nch * bps;
  final bd = ByteData(20 + fmtLen + 8 + dataLen);
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
  u16(ext ? 0xfffe : 1);
  u16(nch);
  u32(sampleRate);
  u32(sampleRate * nch * bps);
  u16(nch * bps);
  u16(container);
  if (ext) {
    u16(22);
    u16(valid);
    u32(0); // no channel mask
    u16(1);
    for (final b in [0, 0, 0, 0, 0x10, 0, 0x80, 0, 0, 0xaa, 0, 0x38, 0x9b, 0x71]) {
      bd.setUint8(o++, b);
    }
  }
  str('data');
  u32(dataLen);
  for (var i = 0; i < frames; i++) {
    for (var c = 0; c < nch; c++) {
      var v = ch[c][i] << shift;
      if (bps == 1) {
        bd.setUint8(o, v + 128);
      } else {
        for (var k = 0; k < bps; k++) {
          bd.setUint8(o + k, v & 0xff);
          v >>= 8;
        }
      }
      o += bps;
    }
  }
  File(path).writeAsBytesSync(bd.buffer.asUint8List());
}

// ------------------------------------------------------- hand-made encoder

class _BitWriter {
  final _bytes = BytesBuilder(copy: false);
  final _cur = <int>[];
  int _acc = 0, _n = 0;

  void bits(int value, int n) {
    for (var i = n - 1; i >= 0; i--) {
      _acc = (_acc << 1) | ((value >> i) & 1);
      if (++_n == 8) {
        _cur.add(_acc);
        _acc = 0;
        _n = 0;
      }
    }
  }

  void signed(int v, int n) => bits(v & ((1 << n) - 1), n);

  void unary(int zeros) {
    for (var i = 0; i < zeros; i++) {
      bits(0, 1);
    }
    bits(1, 1);
  }

  void align() {
    while (_n != 0) {
      bits(0, 1);
    }
  }

  List<int> takeBytes() {
    align();
    final out = List<int>.of(_cur);
    _cur.clear();
    return out;
  }

  void flushTo(BytesBuilder b) => b.add(takeBytes());
  Uint8List done() {
    _bytes.add(takeBytes());
    return _bytes.takeBytes();
  }
}

int _crc8(List<int> d) {
  var c = 0;
  for (final b in d) {
    c ^= b;
    for (var j = 0; j < 8; j++) {
      c = (c & 0x80) != 0 ? ((c << 1) ^ 0x07) & 0xff : (c << 1) & 0xff;
    }
  }
  return c;
}

int _crc16(List<int> d) {
  var c = 0;
  for (final b in d) {
    c ^= b << 8;
    for (var j = 0; j < 8; j++) {
      c = (c & 0x8000) != 0 ? ((c << 1) ^ 0x8005) & 0xffff : (c << 1) & 0xffff;
    }
  }
  return c;
}

List<int> _utf8Num(int x) {
  if (x < 0x80) return [x];
  var n = 2;
  while (x >= (1 << (5 * n + 1)) && n < 7) {
    n++;
  }
  final out = <int>[];
  for (var i = n - 1; i >= 1; i--) {
    out.insert(0, 0x80 | ((x >> (6 * (n - 1 - i))) & 0x3f));
  }
  final lead = (0xff << (8 - n)) & 0xff;
  out.insert(0, lead | (x >> (6 * (n - 1))));
  return out;
}

int _signedBits(int v) => (v >= 0 ? v.bitLength : (~v).bitLength) + 1;

/// Writes a residual for r[order..n) with a mix of Rice params and escapes.
void _writeResidual(_BitWriter w, List<int> r, int n, int order, int variant) {
  // Pick the largest partition order <= 4 that is legal.
  var po = 4;
  while (po > 0 && ((n % (1 << po)) != 0 || (n >> po) < order)) {
    po--;
  }
  // Rice2 needed when a partition wants k > 14.
  var method = variant & 1;
  final parts = 1 << po, plen = n >> po;
  final ks = <int>[];
  for (var p = 0; p < parts; p++) {
    final s = p == 0 ? order : p * plen, e = (p + 1) * plen;
    var sum = 0;
    for (var i = s; i < e; i++) {
      sum += r[i] >= 0 ? 2 * r[i] : -2 * r[i] - 1;
    }
    final mean = e > s ? sum ~/ (e - s) : 0;
    final k = mean > 0 ? mean.bitLength - 1 : 0;
    if (k > 14) method = 1;
    ks.add(math.min(k, 30));
  }
  final escape = method == 0 ? 15 : 31;
  w.bits(method, 2);
  w.bits(po, 4);
  for (var p = 0; p < parts; p++) {
    final s = p == 0 ? order : p * plen, e = (p + 1) * plen;
    if ((variant + p) % 3 == 0) {
      var raw = 0;
      for (var i = s; i < e; i++) {
        if (r[i] != 0) raw = math.max(raw, _signedBits(r[i]));
      }
      w.bits(escape, method == 0 ? 4 : 5);
      w.bits(raw, 5);
      if (raw > 0) {
        for (var i = s; i < e; i++) {
          w.signed(r[i], raw);
        }
      }
      continue;
    }
    final k = ks[p];
    w.bits(k, method == 0 ? 4 : 5);
    for (var i = s; i < e; i++) {
      final u = r[i] >= 0 ? 2 * r[i] : -2 * r[i] - 1;
      w.unary(u >> k);
      w.bits(u & ((1 << k) - 1), k);
    }
  }
}

void _writeSubframe(_BitWriter w, List<int> x0, int n, int bps0, int kind,
    math.Random rnd) {
  // Wasted bits.
  var wasted = 0;
  var allZero = true;
  var or = 0;
  for (var i = 0; i < n; i++) {
    or |= x0[i];
  }
  if (or != 0) {
    allZero = false;
    while ((or >> wasted) & 1 == 0) {
      wasted++;
    }
  }
  final x = [for (var i = 0; i < n; i++) x0[i] >> wasted];
  final bps = bps0 - wasted;
  final constant = x.every((v) => v == x[0]);
  void header(int type) {
    w.bits(0, 1);
    w.bits(type, 6);
    if (wasted > 0) {
      w.bits(1, 1);
      w.unary(wasted - 1);
    } else {
      w.bits(0, 1);
    }
  }

  if (constant || allZero) {
    header(0);
    w.signed(x[0], bps);
    return;
  }
  if (kind == 0 || n < 40) {
    header(1);
    for (final v in x) {
      w.signed(v, bps);
    }
    return;
  }
  final r = List<int>.filled(n, 0);
  if (kind <= 5) {
    final order = kind - 1; // 0..4
    header(8 + order);
    for (var i = 0; i < order; i++) {
      w.signed(x[i], bps);
    }
    for (var i = order; i < n; i++) {
      final pr = switch (order) {
        0 => 0,
        1 => x[i - 1],
        2 => 2 * x[i - 1] - x[i - 2],
        3 => 3 * x[i - 1] - 3 * x[i - 2] + x[i - 3],
        _ => 4 * x[i - 1] - 6 * x[i - 2] + 4 * x[i - 3] - x[i - 4],
      };
      r[i] = x[i] - pr;
    }
    _writeResidual(w, r, n, order, kind + n);
    return;
  }
  // LPC with arbitrary (but small) quantised coefficients.
  const orders = [1, 2, 3, 8, 12, 17, 32];
  final order = orders[(kind - 6) % orders.length];
  final precision = 12 + rnd.nextInt(4); // 12..15
  final shift = 9 + rnd.nextInt(3);
  // Coefficients ~ an order-2 predictor spread out, plus noise.
  final coefs = List<int>.generate(order, (j) {
    var c = 0;
    if (j == 0) c = order == 1 ? (1 << shift) : (2 << shift) - 7;
    if (j == 1) c = -(1 << shift) + 5;
    c += rnd.nextInt(17) - 8;
    final lim = (1 << (precision - 1)) - 1;
    return c.clamp(-lim, lim);
  });
  header(32 + order - 1);
  for (var i = 0; i < order; i++) {
    w.signed(x[i], bps);
  }
  w.bits(precision - 1, 4);
  w.signed(shift, 5);
  for (final c in coefs) {
    w.signed(c, precision);
  }
  for (var i = order; i < n; i++) {
    var sum = 0;
    for (var j = 0; j < order; j++) {
      sum += coefs[j] * x[i - 1 - j];
    }
    r[i] = x[i] - (sum >> shift);
  }
  _writeResidual(w, r, n, order, kind + n);
}

/// Hand-built variable-blocksize stereo FLAC of [src] at [bps] bits.
Uint8List _handMade(List<Int64List> src, int frames, int bps, int sampleRate,
    {int sampleNumberOffset = 0}) {
  final rnd = math.Random(7);
  const sizes = [1000, 4096, 17, 192, 2304, 256, 65535 ~/ 16, 4608, 1, 576];
  final out = BytesBuilder();
  // STREAMINFO.
  final si = _BitWriter();
  si.bits(1, 16);
  si.bits(65535, 16);
  si.bits(0, 24);
  si.bits(0, 24);
  si.bits(sampleRate, 20);
  si.bits(src.length - 1, 3);
  si.bits(bps - 1, 5);
  si.bits(frames, 36);
  final md5hex = _md5Of(src, frames, bps);
  for (var i = 0; i < 16; i++) {
    si.bits(int.parse(md5hex.substring(2 * i, 2 * i + 2), radix: 16), 8);
  }
  out.add('fLaC'.codeUnits);
  final siBytes = si.takeBytes();
  out.add([0x80, 0, 0, siBytes.length, ...siBytes]);

  var pos = 0, fi = 0;
  while (pos < frames) {
    final bs = math.min(sizes[fi % sizes.length], frames - pos);
    final w = _BitWriter();
    final bsCode = switch (bs) {
      192 => 1,
      576 => 2,
      1152 => 3,
      2304 => 4,
      4608 => 5,
      256 => 8,
      4096 => 12,
      _ => bs <= 256 ? 6 : 7,
    };
    final srCode = fi % 3 == 0 ? 0 : (fi % 3 == 1 ? 13 : 9);
    final chMode = 8 + (fi % 4) - (fi % 4 == 3 ? 4 : 0); // 8,9,10,7->indep
    final chCode = chMode == 7 ? 1 : chMode;
    final ssCode = fi % 2 == 0 ? 0 : (bps == 16 ? 4 : 6);
    w.bits(0x3ffe, 14);
    w.bits(0, 1);
    w.bits(1, 1); // variable blocksize
    w.bits(bsCode, 4);
    w.bits(srCode, 4);
    w.bits(chCode, 4);
    w.bits(ssCode, 3);
    w.bits(0, 1);
    for (final b in _utf8Num(pos + sampleNumberOffset)) {
      w.bits(b, 8);
    }
    if (bsCode == 6) w.bits(bs - 1, 8);
    if (bsCode == 7) w.bits(bs - 1, 16);
    if (srCode == 13) w.bits(sampleRate, 16);
    final head = w.takeBytes();
    final frame = <int>[...head, _crc8(head)];
    final l = src[0].sublist(pos, pos + bs), r = src[1].sublist(pos, pos + bs);
    final List<List<int>> chans;
    final List<int> extra;
    switch (chCode) {
      case 8:
        chans = [l, [for (var i = 0; i < bs; i++) l[i] - r[i]]];
        extra = [0, 1];
      case 9:
        chans = [[for (var i = 0; i < bs; i++) l[i] - r[i]], r];
        extra = [1, 0];
      case 10:
        chans = [
          [for (var i = 0; i < bs; i++) (l[i] + r[i]) >> 1],
          [for (var i = 0; i < bs; i++) l[i] - r[i]],
        ];
        extra = [0, 1];
      default:
        chans = [l, r];
        extra = [0, 0];
    }
    final sw = _BitWriter();
    for (var c = 0; c < 2; c++) {
      _writeSubframe(sw, chans[c], bs, bps + extra[c], (fi * 3 + c * 5) % 14, rnd);
    }
    frame.addAll(sw.takeBytes());
    final crc = _crc16(frame);
    frame.addAll([crc >> 8, crc & 0xff]);
    out.add(frame);
    pos += bs;
    fi++;
  }
  return out.takeBytes();
}

void main() {
  late Directory tmp;
  setUpAll(() async {
    tmp = await Directory.systemTemp.createTemp('flac_decoder_test');
  });
  tearDownAll(() async {
    await tmp.delete(recursive: true);
  });

  void checkFile(String flacPath, List<Int64List> src, int frames, int bits,
      {bool checkMd5 = true}) {
    final (info, pcm, n) = _decodeAll(flacPath);
    expect(n, frames);
    expect(info.channels, src.length);
    for (var c = 0; c < src.length; c++) {
      for (var i = 0; i < frames; i++) {
        if (pcm[c][i] != src[c][i]) {
          fail('ch $c sample $i: got ${pcm[c][i]}, want ${src[c][i]}');
        }
      }
    }
    if (checkMd5 && info.md5.any((b) => b != 0)) {
      expect(_md5Of(pcm, n, info.bitsPerSample), _hex(info.md5));
    }
  }

  group('flac CLI corpus', () {
    final hasFlac = _has('flac');
    final cases = <(int, int, List<String>, int)>[
      // (bits, channels, flac args, wasted bits)
      for (final b in [8, 12, 16, 20, 24, 32])
        for (final ch in [1, 2]) (b, ch, ['-8'], 0),
      (16, 2, ['-0'], 0),
      (16, 2, ['-3'], 0),
      (24, 2, ['-5', '-b', '1152'], 0),
      (16, 2, ['-8', '-b', '192'], 0),
      (16, 2, ['-8', '-b', '576'], 0),
      (16, 2, ['-8', '-b', '2048'], 0),
      (24, 2, ['-8', '--lax', '-b', '300'], 0),
      (24, 2, ['-8', '--lax', '-b', '65535'], 0),
      (16, 1, ['-8', '-b', '100'], 0),
      (24, 2, ['-8', '-e', '-p', '--lax', '-l', '32', '-r', '15'], 0),
      (16, 2, ['-8'], 3),
      (24, 2, ['-5'], 8),
      for (final ch in [3, 4, 5, 6, 7, 8]) (16, ch, ['-5'], 0),
      (24, 8, ['-8'], 0),
    ];
    for (final (bits, ch, args, wasted) in cases) {
      test('$bits-bit ${ch}ch ${args.join(' ')}${wasted > 0 ? ' wasted=$wasted' : ''}',
          () {
        const frames = 30000;
        final src = _signal(ch, frames, bits, bits * 31 + ch, wastedBits: wasted);
        final name = 'c${bits}_${ch}_${args.join('').replaceAll('-', '')}_$wasted';
        final wav = p.join(tmp.path, '$name.wav');
        final flac = p.join(tmp.path, '$name.flac');
        _writeWav(wav, src, frames, 44100, bits);
        final r = Process.runSync(
            'flac', ['-s', '-f', ...args, '-o', flac, wav]);
        expect(r.exitCode, 0, reason: '${r.stderr}');
        checkFile(flac, src, frames, bits);
        // Envelope from FLAC equals envelope from the WAV it came from.
        final ef = computeEnvelopeSync(flac, bins: 50)!;
        final ew = computeEnvelopeSync(wav, bins: 50)!;
        for (var i = 0; i < 50; i++) {
          expect(ef.peak[i], closeTo(ew.peak[i], 1e-9));
          expect(ef.rms[i], closeTo(ew.rms[i], 1e-9));
        }
        expect(ef.seconds, closeTo(frames / 44100, 1e-9));
      }, skip: hasFlac ? false : 'flac CLI not found');
    }

    test('unknown total length (streamed encode)', () async {
      const frames = 40000;
      final src = _signal(2, frames, 16, 99);
      final wav = p.join(tmp.path, 'stream.wav');
      _writeWav(wav, src, frames, 44100, 16);
      final raw = File(wav).readAsBytesSync().sublist(44);
      final proc = await Process.start('flac', [
        '-s', '--force-raw-format', '--endian=little', '--sign=signed',
        '--channels=2', '--bps=16', '--sample-rate=44100', '-c', '-',
      ]);
      proc.stdin.add(raw);
      final outF = proc.stdout.fold<BytesBuilder>(BytesBuilder(), (b, d) => b..add(d));
      await proc.stdin.close();
      final bytes = (await outF).takeBytes();
      expect(await proc.exitCode, 0);
      final flac = p.join(tmp.path, 'stream.flac');
      File(flac).writeAsBytesSync(bytes);
      final info = FlacDecoder(bytes).info;
      expect(info.totalSamples, 0, reason: 'expected an unknown-length stream');
      checkFile(flac, src, frames, 16, checkMd5: false);
      final ef = computeEnvelopeSync(flac, bins: 40)!;
      final ew = computeEnvelopeSync(wav, bins: 40)!;
      expect(ef.bins, 40);
      expect(ef.seconds, closeTo(frames / 44100, 1e-9));
      // Chunk-pooled binning: boundaries may shift by < 256 samples.
      var diff = 0.0;
      for (var i = 0; i < 40; i++) {
        diff += (ef.peak[i] - ew.peak[i]).abs();
      }
      expect(diff / 40, lessThan(0.05));
    }, skip: hasFlac ? false : 'flac CLI not found');
  });

  group('ffmpeg corpus', () {
    final hasFfmpeg = _has('ffmpeg');
    final cases = <(int, List<String>)>[
      for (final m in ['indep', 'left_side', 'right_side', 'mid_side'])
        (16, ['-ch_mode', m]),
      for (final m in ['indep', 'left_side', 'right_side', 'mid_side'])
        (24, ['-ch_mode', m, '-exact_rice_parameters', '1']),
      (24, ['-lpc_type', 'cholesky', '-max_prediction_order', '32']),
      (16, ['-lpc_type', 'fixed']),
      (16, ['-lpc_type', 'none']),
      (24, ['-min_partition_order', '8', '-max_partition_order', '8']),
      (32, ['-strict', 'experimental', '-ch_mode', 'mid_side']),
      (32, ['-strict', 'experimental', '-ch_mode', 'left_side']),
    ];
    for (final (bits, args) in cases) {
      test('$bits-bit ${args.join(' ')}', () {
        const frames = 30000;
        final src = _signal(2, frames, bits, bits + args.length);
        final name = 'ff$bits${args.join('_')}';
        final wav = p.join(tmp.path, '$name.wav');
        final flac = p.join(tmp.path, '$name.flac');
        _writeWav(wav, src, frames, 48000, bits);
        final r = Process.runSync('ffmpeg', [
          '-hide_banner', '-loglevel', 'error', '-y', '-i', wav,
          '-c:a', 'flac', if (bits > 16) ...['-sample_fmt', 's32'],
          if (bits == 24) ...['-bits_per_raw_sample', '24'],
          ...args, flac,
        ]);
        expect(r.exitCode, 0, reason: '${r.stderr}');
        final (info, pcm, n) = _decodeAll(flac);
        expect(n, frames);
        final shift = info.bitsPerSample - bits; // ffmpeg may widen to 32
        for (var c = 0; c < 2; c++) {
          for (var i = 0; i < frames; i++) {
            if (pcm[c][i] != src[c][i] << shift) {
              fail('ch $c sample $i: ${pcm[c][i]} != ${src[c][i] << shift}');
            }
          }
        }
        if (info.md5.any((b) => b != 0)) {
          expect(_md5Of(pcm, n, info.bitsPerSample), _hex(info.md5));
        }
      }, skip: hasFfmpeg ? false : 'ffmpeg not found');
    }
  });

  group('hand-made stream', () {
    for (final bps in [16, 24]) {
      test('$bps-bit variable blocksize, escapes, rice2, wasted bits, all modes',
          () {
        const frames = 50000;
        final src = _signal(2, frames, bps, 5 + bps);
        // A stretch with wasted low bits (coarse quantisation).
        for (final ch in src) {
          for (var i = 30000; i < 34000; i++) {
            ch[i] = (ch[i] >> 5) << 5;
          }
        }
        final bytes = _handMade(src, frames, bps, 44100);
        final path = p.join(tmp.path, 'hand$bps.flac');
        File(path).writeAsBytesSync(bytes);
        if (_has('flac')) {
          final t = Process.runSync('flac', ['-t', '-s', path]);
          expect(t.exitCode, 0, reason: 'reference decoder rejects: ${t.stderr}');
        }
        checkFile(path, src, frames, bps);
        // 7-byte (0xFE-led) sample numbers.
        final big = _handMade(src, frames, bps, 44100,
            sampleNumberOffset: 1 << 33);
        final bigPath = p.join(tmp.path, 'hand${bps}big.flac');
        File(bigPath).writeAsBytesSync(big);
        checkFile(bigPath, src, frames, bps);
      });
    }
  });
}
