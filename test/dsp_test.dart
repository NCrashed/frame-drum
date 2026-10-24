import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:frame_drum/audio.dart';
import 'package:frame_drum/dsp.dart';
import 'package:frame_drum/pattern.dart';
import 'package:frame_drum/practice.dart';
import 'package:frame_drum/scoring.dart';
import 'package:frame_drum/synth.dart';

import 'drum_sim.dart';

const sr = 48000;

/// Renders app sounds [hits] (time s, voice, gain) over noise.
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

/// Maqsum-like phrase (D T - T D - T -) with human timing jitter.
List<(double, bool)> phrase({required double step, required int cycles, required double start, int seed = 2}) {
  final rng = math.Random(seed);
  const p = 'DT-TD-T-';
  return [
    for (var k = 0; k < cycles * p.length; k++)
      if (p[k % p.length] != '-') (start + k * step + (rng.nextDouble() - 0.5) * 0.02, p[k % p.length] == 'D'),
  ];
}

void main() {
  group('onset detector', () {
    for (final (name, step) in [('slow', 0.3), ('fast', 0.15)]) {
      test('finds every stroke of a ringing drum within 3 ms ($name)', () {
        final hits = phrase(step: step, cycles: 4, start: 0.4);
        final pcm = DrumSim(sr).render(hits.last.$1 + 1.5, hits, gainJitter: 0.5);
        final found = detect(pcm);
        expect(found.map((f) => f.$1.toStringAsFixed(3)), hasLength(hits.length));
        for (var i = 0; i < hits.length; i++) {
          expect(found[i].$1, closeTo(hits[i].$1, 0.003), reason: 'stroke $i');
        }
      });
    }

    for (final similar in [false, true]) {
      test('learns dum from tek on a drum where both ring low (similar: $similar)', () {
        // Training: alternating strokes as in calibration, from another "session".
        final train = [for (var i = 0; i < 20; i++) (0.4 + i * 0.45, i.isEven)];
        final tf = detect(DrumSim(sr, seed: 7, similar: similar).render(10.5, train, gainJitter: 0.4));
        expect(tf, hasLength(20));
        final model = StrokeModel.fit(
          [for (var i = 0; i < 20; i += 2) tf[i].$2.features],
          [for (var i = 1; i < 20; i += 2) tf[i].$2.features],
        );

        final hits = phrase(step: 0.2, cycles: 6, start: 0.4, seed: 4);
        final found = detect(
          DrumSim(sr, seed: 9, similar: similar).render(hits.last.$1 + 1.5, hits, gainJitter: 0.5),
          det: OnsetDetector(sampleRate: sr, model: model),
        );
        expect(found, hasLength(hits.length));
        var correct = 0;
        for (var i = 0; i < hits.length; i++) {
          if (found[i].$2.isLow(0) == hits[i].$2) correct++;
        }
        expect(correct / hits.length, greaterThanOrEqualTo(0.95));
      });
    }

    test('ignores steady noise and quiet ticks below the level floor', () {
      final pcm = scene(2, [(0.5, Voice.tek, 0.001)], noise: 0.01);
      expect(detect(pcm), isEmpty);
    });

    test('a stroke right after an ignored click still counts', () {
      final pcm = Float32List(sr * 2);
      final click = Synth(sr).sample(Voice.click);
      for (var i = 0; i < click.length; i++) {
        pcm[(0.5 * sr).round() + i] += 0.3 * click[i];
      }
      DrumSim(sr).stroke(pcm, 0.52, dum: true);
      final det = OnsetDetector(sampleRate: sr)..ignore = (t, _) => (t / 1e9 - 0.5).abs() < 0.008;
      final found = detect(pcm, det: det);
      expect(found.map((f) => f.$1), [closeTo(0.52, 0.003)]);
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

  group('playback clock', () {
    test('averages timestamp jitter but follows real jumps', () {
      final c = PlaybackClock();
      c.report((t0: 1000000000, underruns: 0));
      c.report((t0: 1004000000, underruns: 0)); // 4 ms jitter: smoothed
      expect(c.t0, 1000400000);
      c.report((t0: 1050000000, underruns: 0)); // 50 ms: real jump
      expect((c.t0, c.jumps), (1050000000, 1));
      c.report((t0: 1052000000, underruns: 1)); // underrun reported: taken as is
      expect((c.t0, c.jumps), (1052000000, 2));
    });
  });
}
