import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:path/path.dart' as p;

import '../core/library/library.dart';
import '../core/library/song.dart';
import '../state/generate_form.dart';
import 'snapshot.dart';
import 'widgets/sleeve.dart';

/// `STUDIO_UITEST=<report dir>`: drives the real UI by tapping cells (licence, Start, the
/// recording sheet, Record), waits for the take, captures the screens and writes uitest.json.
/// `STUDIO_UITEST_SECONDS` (default 20) sets the length; `STUDIO_UITEST_QUIT=1` exits after.
class UiTest {
  UiTest(this.dir, this.library, this.form);

  final String dir;
  final Library library;
  final GenerateForm form;
  final report = <String, dynamic>{};
  final steps = <String>[];

  static bool get active => (Platform.environment['STUDIO_UITEST'] ?? '').isNotEmpty;

  Element? _find(String label) {
    Element? hit;
    void visit(Element e) {
      if (hit != null) return;
      final w = e.widget;
      if (w is Cell && w.semanticLabel == label) {
        hit = e;
        return;
      }
      e.visitChildren(visit);
    }

    WidgetsBinding.instance.rootElement?.visitChildren(visit);
    return hit;
  }

  Future<bool> tap(String label, {Duration wait = const Duration(seconds: 20)}) async {
    final end = DateTime.now().add(wait);
    while (DateTime.now().isBefore(end)) {
      final e = _find(label);
      final box = e?.findRenderObject() as RenderBox?;
      if (box != null && box.hasSize && box.attached) {
        final at = box.localToGlobal(box.size.center(Offset.zero));
        final b = GestureBinding.instance;
        b.handlePointerEvent(PointerDownEvent(position: at, pointer: 9000 + steps.length));
        await Future.delayed(const Duration(milliseconds: 60));
        b.handlePointerEvent(PointerUpEvent(position: at, pointer: 9000 + steps.length));
        steps.add('tap "$label" at ${at.dx.round()},${at.dy.round()}');
        await Future.delayed(const Duration(milliseconds: 900));
        return true;
      }
      await Future.delayed(const Duration(milliseconds: 300));
    }
    steps.add('NOT FOUND "$label"');
    return false;
  }

  Future<void> shot(String name) async {
    await WidgetsBinding.instance.endOfFrame;
    final b = Snapshot.key.currentContext?.findRenderObject() as RenderRepaintBoundary?;
    if (b == null) return;
    final img = await b.toImage(pixelRatio: 1);
    final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
    await File(p.join(dir, name)).writeAsBytes(bytes!.buffer.asUint8List());
  }

  Future<void> run() async {
    await Directory(dir).create(recursive: true);
    final secs = double.tryParse(Platform.environment['STUDIO_UITEST_SECONDS'] ?? '') ?? 20;
    report['started'] = DateTime.now().toIso8601String();
    try {
      await Future.delayed(const Duration(seconds: 3));
      await shot('01-first-screen.png');
      // First run: accept the licence and start (only if the setup shows).
      if (_find('I accept the model licence') != null) {
        await tap('I accept the model licence');
        await shot('02-licence-accepted.png');
        await tap('START');
      }
      await Future.delayed(const Duration(seconds: 3));
      await shot('03-studio.png');
      // The etched settings: 8 steps, 8-bit.
      final before = form.summary;
      await tap('Recording settings: $before');
      await tap('Steps 8');
      await tap('Precision 8bit', wait: const Duration(seconds: 3));
      // Lengths in the sheet start at 0:30; the test wants a short take.
      form.update(() {
        form.limitLength = true;
        form.maxSeconds = secs;
      });
      await shot('04-sheet.png');
      await tap('Close');
      final next = library.catalogue.next;
      final label = 'RECORD LRS-${next.toString().padLeft(3, '0')}';
      final sw = Stopwatch()..start();
      if (!await tap(label)) throw StateError('Record cell not found ($label)');
      Song? s;
      while (sw.elapsed < const Duration(minutes: 15)) {
        await Future.delayed(const Duration(seconds: 2));
        s = library.byNumber(next);
        if (sw.elapsed.inSeconds % 10 < 2 && s?.status == SongStatus.running) await shot('05-recording.png');
        if (s != null && !s.active) break;
      }
      report['wall_seconds'] = sw.elapsedMilliseconds / 1000;
      report['number'] = next;
      report['status'] = s?.status.name;
      report['error'] = s?.error;
      report['audio'] = s?.audioPath;
      report['audio_seconds'] = s?.seconds;
      report['params'] = s?.params;
      await Future.delayed(const Duration(seconds: 4)); // the envelope is computed
      report['envelope'] = s == null ? false : File(p.join(s.dir, 'envelope.json')).existsSync();
      await shot('06-after.png');
      await tap('Catalogue');
      await Future.delayed(const Duration(seconds: 2));
      await shot('07-catalogue.png');
      report['ok'] = s?.status == SongStatus.done && report['envelope'] == true;
    } catch (e) {
      report['ok'] = false;
      report['exception'] = e.toString();
    }
    report['steps'] = steps;
    report['finished'] = DateTime.now().toIso8601String();
    await File(p.join(dir, 'uitest.json')).writeAsString(const JsonEncoder.withIndent('  ').convert(report));
    if (Platform.environment['STUDIO_UITEST_QUIT'] == '1') exit(report['ok'] == true ? 0 : 1);
  }
}
