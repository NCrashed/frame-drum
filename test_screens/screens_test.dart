// Renders app screens to PNG for visual review without a device:
//   SCREEN_FONT_DIR=/path/to/ttf flutter test test_screens --update-goldens
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frame_drum/calibration_screen.dart';
import 'package:frame_drum/editor_screen.dart';
import 'package:frame_drum/history_screen.dart';
import 'package:frame_drum/main.dart';
import 'package:frame_drum/model.dart';
import 'package:frame_drum/practice.dart';
import 'package:frame_drum/practice_screen.dart';
import 'package:frame_drum/scoring.dart';
import 'package:frame_drum/theme.dart';

Future<void> _loadFonts() async {
  final dir = Platform.environment['SCREEN_FONT_DIR'];
  if (dir != null) {
    final loader = FontLoader('Roboto')
      ..addFont(File('$dir/LiberationSans-Regular.ttf').readAsBytes().then(ByteData.sublistView))
      ..addFont(File('$dir/LiberationSans-Bold.ttf').readAsBytes().then(ByteData.sublistView));
    await loader.load();
  }
  final icons = Platform.environment['SCREEN_ICON_FONT'];
  if (icons != null) {
    await (FontLoader('MaterialIcons')..addFont(File(icons).readAsBytes().then(ByteData.sublistView))).load();
  }
}

/// A session in progress at a fixed moment, with a plausible slightly rushed player.
class _FrozenPractice extends Practice {
  _FrozenPractice(super.store, super.pattern, this._now) {
    state = PracticeState.running;
    introSeconds = 4 * 60 / pattern.bpm;
    final sc = scorer = Scorer(pattern, start: introSeconds, lowThreshold: 0);
    final rng = math.Random(3);
    for (var k = 0; k * pattern.stepSeconds + introSeconds < _now - 0.05; k++) {
      final s = pattern.steps[k % pattern.steps.length];
      if (!s.isHit || rng.nextDouble() < 0.06) continue;
      final t = introSeconds + k * pattern.stepSeconds + (-0.012 + rng.nextDouble() * 0.05 - 0.03);
      final wrong = rng.nextDouble() < 0.08;
      lastHit = sc.addHit(t, (s.isLow != wrong) ? 15 : -15, -12);
    }
    sc
      ..addHit(_now - 0.7, -15, -20)
      ..hits.sort((a, b) => a.t.compareTo(b.t));
    sc.advance(_now - 0.08);
  }

  final double _now;

  @override
  double? get now => _now;
}

Store _sample() {
  final s = Store();
  s.settings
    ..latencyMs['speaker'] = 38
    ..dumTone = 14
    ..tekTone = -18
    ..toneThreshold = -2;
  final maqsum = s.patterns[3];
  final rng = math.Random(5);
  for (var i = 0; i < 9; i++) {
    TallySummary t(double acc, double sd) {
      final n = 120 + rng.nextInt(60);
      final good = (n * acc * 0.7).round(), ok = (n * acc * 0.3).round();
      return TallySummary(
        expected: n,
        good: good,
        ok: ok,
        off: (n - good - ok) ~/ 2,
        missed: n - good - ok - (n - good - ok) ~/ 2,
        extras: rng.nextInt(6),
        strokeOk: n - rng.nextInt(10) - 10,
        meanMs: -18 + i * 1.6 + rng.nextDouble() * 4,
        sdMs: sd,
      );
    }

    s.sessions.add(
      Session(
        patternId: maqsum.id,
        at: DateTime(2026, 10, 10 + i, 19, 5 * i),
        bpm: 70 + i * 2,
        seconds: 300 + rng.nextInt(400),
        sound: t(0.55 + i * 0.04, 42 - i * 2.5 + rng.nextDouble() * 3),
        silent: i >= 5 ? t(0.45 + i * 0.03, 50 - i * 2.0) : null,
      ),
    );
  }
  return s;
}

void main() {
  setUpAll(() async {
    await _loadFonts();
  });

  setUp(() {
    final m = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    m.setMockMethodCallHandler(const MethodChannel('frame_drum/audio'), (call) async {
      return switch (call.method) {
        'requestMic' => true,
        'info' => {'sampleRate': 48000, 'route': 'speaker'},
        'now' => 0,
        _ => null,
      };
    });
    m.setMockMethodCallHandler(const MethodChannel('frame_drum/events'), (_) async => null);
  });

  Future<void> shoot(WidgetTester tester, Widget home, String name, {bool tall = false}) async {
    tester.view.physicalSize = Size(1080, tall ? 3400 : 2340);
    tester.view.devicePixelRatio = 2.75;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(debugShowCheckedModeBanner: false, theme: buildTheme(), home: home));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 500));
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('out/$name.png'));
  }

  testWidgets('home', (t) async {
    await shoot(t, HomeScreen(store: _sample()), 'home');
  });

  testWidgets('practice idle', (t) async {
    final s = _sample();
    final p = s.patterns[3]..silentCycles = 0;
    await shoot(t, PracticeScreen(store: s, pattern: p), 'practice_idle', tall: true);
  });

  testWidgets('practice running', (t) async {
    final s = _sample();
    final p = s.patterns[3]
      ..bpm = 80
      ..soundCycles = 2
      ..silentCycles = 1;
    final pr = _FrozenPractice(s, p, 4 * 0.75 + 4 * 6 + 1.1);
    await shoot(t, PracticeScreen(store: s, pattern: p, practice: pr), 'practice_running');
  });

  testWidgets('editor', (t) async {
    final s = _sample();
    await shoot(t, EditorScreen(store: s, pattern: s.patterns[6]), 'editor');
  });

  testWidgets('history', (t) async {
    final s = _sample();
    await shoot(t, HistoryScreen(store: s, pattern: s.patterns[3]), 'history');
  });

  testWidgets('calibration', (t) async {
    await shoot(t, CalibrationScreen(store: _sample()), 'calibration', tall: true);
  });
}
