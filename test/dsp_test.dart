import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:frame_drum/dsp.dart';
import 'package:frame_drum/pattern.dart';
import 'package:frame_drum/practice.dart';
import 'package:frame_drum/scoring.dart';
import 'package:frame_drum/synth.dart';

const sr = 48000;

/// Renders [hits] (time s, voice, gain) over noise, as the mic would hear it.
Float32List scene(double seconds, List<(double, Voice, double)> hits, {double noise = 0.003, int seed = 1}) {
  final synth = Synth(sr, clickVolume: 1, guideVolume: 1);
  final rng = math.Random(seed);
  final out = Float32List((seconds * sr).round());
  for (var i = 0; i < out.length; i++) {
    out[i] = (rng.nextDouble() * 2 - 1) * noise;
  }
  for (final (t, v, g) in hits) {
    final s = synth.sample(v);
    final start = (t * sr).round();
    for (var i = 0; i < s.length && start + i < out.length; i++) {
      out[start + i] += g * s[i];
    }
  }
  return out;
}

/// Feeds [pcm] in 10 ms chunks like AudioEngine does; returns onsets in seconds.
List<(double, Onset)> detect(Float32List pcm, {OnsetDetector? det}) {
  final d = det ?? OnsetDetector(sampleRate: sr);
  final out = <(double, Onset)>[];
  const chunk = sr ~/ 100;
  for (var i = 0; i + chunk <= pcm.length; i += chunk) {
    for (final o in d.feed(Float32List.sublistView(pcm, i, i + chunk), (i * 1e9 / sr).round())) {
      out.add((o.t / 1e9, o));
    }
  }
  return out;
}

void main() {
  group('onset detector', () {
    test('finds every hit within 2 ms', () {
      final times = [0.3, 0.55, 0.8, 1.0, 1.25, 1.4, 1.9];
      final voices = [Voice.dum, Voice.tek, Voice.ka, Voice.dum, Voice.tek, Voice.tek, Voice.dum];
      final pcm = scene(2.4, [for (var i = 0; i < times.length; i++) (times[i], voices[i], 0.8)]);
      final found = detect(pcm);
      expect(found, hasLength(times.length));
      for (var i = 0; i < times.length; i++) {
        expect(found[i].$1, closeTo(times[i], 0.002), reason: 'hit $i');
      }
    });

    test('tells dum from rim strokes by tone', () {
      final pcm = scene(2, [(0.2, Voice.dum, 0.8), (0.6, Voice.tek, 0.8), (1.0, Voice.ka, 0.5), (1.4, Voice.dum, 0.3)]);
      final tones = detect(pcm).map((f) => f.$2.toneDb).toList();
      expect(tones, hasLength(4));
      expect(tones[0], greaterThan(10));
      expect(tones[1], lessThan(-10));
      expect(tones[2], lessThan(-10));
      expect(tones[3], greaterThan(10));
    });

    test('ignores steady noise and quiet ticks below the level floor', () {
      final pcm = scene(2, [(0.5, Voice.tek, 0.001)], noise: 0.01);
      expect(detect(pcm), isEmpty);
    });

    test('splits a loud hit following a quiet click', () {
      final pcm = scene(1.2, [(0.3, Voice.click, 0.1), (0.322, Voice.dum, 1.0)]);
      final found = detect(pcm);
      expect(found.map((f) => f.$1), [closeTo(0.3, 0.002), closeTo(0.322, 0.003)]);
      expect(found[1].$2.peakDb, greaterThan(found[0].$2.peakDb + 6));
    });
  });

  group('scorer', () {
    Pattern maqsum() => presetPatterns().firstWhere((p) => p.name == 'Максум')..bpm = 120; // 0.25 s per step

    test('grades hits, misses, extras and stroke type', () {
      final p = maqsum(); // D T - T D - T -
      final sc = Scorer(p, start: 1.0, lowThreshold: 0);
      sc.addHit(0.5, 20, -10); // count-in, ignored
      sc.addHit(1.010, 20, -10); // D, good
      sc.addHit(1.290, -20, -10); // T, +40 ms, ok
      // step 3 (T at 1.75) missed
      sc.addHit(2.0, -20, -10); // D played as rim: good timing, wrong stroke
      sc.addHit(2.25, -20, -10); // rest: extra
      sc.addHit(2.55, -20, -10); // T at 2.5, +50 ms, ok
      sc.addHit(2.56, -20, -10); // double hit: extra
      sc.advance(3.0);
      final a = sc.all;
      expect(a.expected, 5);
      expect((a.good, a.ok, a.off, a.missed, a.extras), (2, 2, 0, 1, 2));
      expect(a.strokeOk, 3);
      expect(a.meanMs, closeTo((10 + 40 + 0 + 50) / 4, 1e-9));
    });

    test('splits silent cycles from sounding ones', () {
      final p = maqsum()
        ..soundCycles = 1
        ..silentCycles = 1;
      final sc = Scorer(p, start: 0, lowThreshold: 0);
      for (final e in [0.0, 0.25, 0.75, 1.0, 1.5]) {
        sc.addHit(e, 0, -10);
        sc.addHit(e + 2, 0, -10);
      }
      sc.advance(3.9);
      expect(sc.sound.expected, 5);
      expect(sc.silent.expected, 5);
      expect(sc.silent.good, 5);
    });
  });

  group('self-sound gate', () {
    test('drops clicks heard through the speaker but keeps loud hits', () {
      final p = presetPatterns().first..bpm = 60;
      final synth = Synth(sr);
      final intro = synth.countIn(p, 4), loop = synth.loop(p);
      final gate = SelfSoundGate(
        intro: intro.events,
        loop: loop.events,
        introSeconds: intro.seconds(sr),
        loopSeconds: loop.seconds(sr),
        levels: {Voice.click: -30, Voice.accent: -28},
      );
      expect(gate.isSelf(1.002, -31), isTrue); // intro click
      expect(gate.isSelf(4.0 + 3 * 1.0 + 0.004, -31), isTrue); // loop click, later cycle
      expect(gate.isSelf(4.0 + 8.0 + 0.003, -27), isTrue); // accent
      expect(gate.isSelf(5.002, -10), isFalse); // drum much louder than click
      expect(gate.isSelf(5.5, -31), isFalse); // between clicks
    });
  });
}
