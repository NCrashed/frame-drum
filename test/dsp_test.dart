import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:frame_drum/audio.dart';
import 'package:frame_drum/dsp.dart';
import 'package:frame_drum/pattern.dart';
import 'package:frame_drum/gate.dart';
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

    test('survives an overloaded mic and reports the overload', () {
      final hits = [for (var i = 0; i < 16; i++) (0.4 + i * 0.5, i % 4 != 3)];
      final pcm = DrumSim(sr, seed: 3).render(hits.last.$1 + 1.5, hits, gainJitter: 0.3);
      for (var i = 0; i < pcm.length; i++) {
        pcm[i] = (pcm[i] * 4).clamp(-1.0, 1.0); // ~15% of samples clipped
      }
      final det = OnsetDetector(sampleRate: sr);
      final found = detect(pcm, det: det);
      final matched = hits.where((h) => found.any((f) => (f.$1 - h.$1).abs() < 0.01)).length;
      expect(matched, greaterThanOrEqualTo(13));
      expect(found.length - matched, lessThanOrEqualTo(3));
      expect(det.overload, greaterThan(OnsetDetector.overloadWarning));
    });

    test('ignores steady noise and quiet ticks below the level floor', () {
      final pcm = scene(2, [(0.5, Voice.tek, 0.001)], noise: 0.01);
      expect(detect(pcm), isEmpty);
    });

    test('a dum played right on a speaker click counts, a lone click does not', () {
      final p = presetPatterns().first..bpm = 60; // a dum on every beat
      final synth = Synth(sr, clickVolume: 0.35); // click peaks around -15 dBFS at the mic
      final intro = synth.countIn(p), loop = synth.loop(p);

      // Calibration: click level as the latency test hears it.
      final calib = Float32List(sr * 6);
      for (var b = 0; b < 5; b++) {
        final s = synth.sample(Voice.click);
        for (var i = 0; i < s.length; i++) {
          calib[sr * (b + 1) + i] += s[i];
        }
      }
      final clicks = detect(
        calib,
        det: OnsetDetector(sampleRate: sr), // the latency test listens without notches
      );
      expect(clicks, isNotEmpty);
      final train = [for (var i = 0; i < 20; i++) (0.4 + i * 0.45, i.isEven)];
      final tf = detect(
        DrumSim(sr, seed: 7).render(10.5, train),
        det: OnsetDetector(sampleRate: sr, notchHz: clickNotchHz),
      );
      final model = StrokeModel.fit(
        [for (var i = 0; i < tf.length; i += 2) tf[i].$2.features],
        [for (var i = 1; i < tf.length; i += 2) tf[i].$2.features],
      );

      // Session: count-in, then 8 beats; the player skips beats 3 and 6.
      final pcm = Float32List(sr * 14);
      void add(Float32List s, int at) {
        for (var i = 0; i < s.length && at + i < pcm.length; i++) {
          pcm[at + i] += s[i];
        }
      }

      add(intro.pcm, 0);
      add(loop.pcm, sr * 4);
      add(loop.pcm, sr * 8);
      final played = [
        for (var b = 0; b < 8; b++)
          if (b != 3 && b != 6) 4.0 + b + 0.004,
      ];
      final sim = DrumSim(sr, seed: 5);
      for (final t in played) {
        sim.stroke(pcm, t, dum: true);
      }
      final gate = SelfSoundGate(
        intro: intro.events,
        loop: loop.events,
        introSeconds: 4,
        loopSeconds: loop.seconds(sr),
        levels: {
          for (final v in [Voice.click, Voice.accent]) v: clicks.map((c) => c.$2.peakDb).reduce(math.max),
        },
      );
      final det = OnsetDetector(sampleRate: sr, notchHz: clickNotchHz, model: model)
        ..provisional = ((t, peak) => gate.nearOwnSound(t / 1e9, peak))
        ..ignore = ((o) => gate.isSelf(o.t / 1e9, o));
      final found = detect(pcm, det: det).where((f) => f.$1 > 3.9).toList();
      expect(found.map((f) => f.$1), [for (final t in played) closeTo(t, 0.004)]);
      expect(found.where((f) => f.$2.isLow(0)).length, greaterThanOrEqualTo(found.length - 1));
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
    test('finds our clicks by time and tells them from strokes by spectrum', () {
      final p = presetPatterns().first..bpm = 60;
      final synth = Synth(sr);
      final intro = synth.countIn(p), loop = synth.loop(p);
      final gate = SelfSoundGate(
        intro: intro.events,
        loop: loop.events,
        introSeconds: intro.seconds(sr),
        loopSeconds: loop.seconds(sr),
        levels: const {},
      );
      expect(gate.nearOwnSound(1.002, -31), isTrue); // intro click
      expect(gate.nearOwnSound(4.0 + 3 * 1.0 + 0.004, -10), isTrue); // loop click, later cycle, any level
      expect(gate.nearOwnSound(5.5, -31), isFalse); // between clicks

      Onset onset(List<double> rise, List<double> level) =>
          Onset(t: 0, peakDb: -20, features: const [], bandRise: rise, bandLevel: level);
      final click = onset([0, 1, 0, -2, 3, 8, 30, 40], [-30, -32, -45, -60, -80, -95, -70, -50]);
      final dum = onset([12, 15, 20, 25, 30, 40, 45, 50], [-20, -20, -24, -35, -45, -55, -60, -52]);
      final tekOnRing = onset([0, 1, 2, 3, 20, 35, 40, 45], [-25, -27, -30, -40, -45, -50, -58, -52]);
      expect(gate.isSelf(5.003, click), isTrue);
      expect(gate.isSelf(5.003, dum), isFalse);
      expect(gate.isSelf(5.003, tekOnRing), isFalse);
      expect(gate.isSelf(5.5, click), isFalse); // not at a click time
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
