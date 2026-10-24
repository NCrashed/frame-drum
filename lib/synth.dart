import 'dart:math' as math;
import 'dart:typed_data';

import 'pattern.dart';

/// Sounds the app itself plays: metronome clicks and guide strokes.
enum Voice { click, accent, dum, tek, ka }

/// A sound scheduled in a rendered buffer, [t] seconds after its start.
typedef Scheduled = ({double t, Voice voice});

class Rendered {
  Rendered(this.pcm, this.events);
  final Float32List pcm;
  final List<Scheduled> events;

  double seconds(int sampleRate) => pcm.length / sampleRate;
}

/// Metronome tone frequencies: high, in the top octave band (5.8–11.5 kHz),
/// which says little about dum versus tek. The detector notches them and
/// leaves that band out of the stroke features, so a click under a stroke
/// changes its sound as little as possible.
const clickHz = 7000.0, accentHz = 8500.0;
const clickNotchHz = [clickHz, accentHz];

class Synth {
  Synth(this.sampleRate, {this.clickVolume = 0.6, this.guideVolume = 0.7});

  final int sampleRate;
  final double clickVolume;
  final double guideVolume;

  final _cache = <Voice, Float32List>{};

  Float32List sample(Voice v) => _cache[v] ??= _render(v);

  Float32List _render(Voice v) {
    final sr = sampleRate.toDouble();
    final rng = math.Random(v.index + 1);
    switch (v) {
      case Voice.click:
      case Voice.accent:
        // Short sine ping; accent is higher and a bit louder. The 4 ms fade-in
        // keeps its spectrum narrow, so the notches in the detector remove it
        // instead of leaving a broadband edge that looks like a stroke.
        final f = v == Voice.accent ? accentHz : clickHz;
        final a = clickVolume * (v == Voice.accent ? 1.0 : 0.7);
        return _gen((0.12 * sr).round(), (t) {
          final rise = t < 0.004 ? math.pow(math.sin(math.pi / 2 * t / 0.004), 2) : 1.0;
          final fall = t < 0.004 ? 1.0 : math.exp(-(t - 0.004) / 0.008);
          return a * rise * fall * math.sin(2 * math.pi * f * t);
        });
      case Voice.dum:
        // Low membrane: falling pitch plus a soft attack thump.
        var phase = 0.0;
        return _gen((0.35 * sr).round(), (t) {
          final f = 70 + 45 * math.exp(-t / 0.04);
          phase += 2 * math.pi * f / sr;
          final body = math.sin(phase) * math.exp(-t / 0.12);
          final thump = (rng.nextDouble() * 2 - 1) * math.exp(-t / 0.004) * 0.3;
          return guideVolume * (body + thump);
        });
      case Voice.tek:
      case Voice.ka:
        // Rim: bright noise burst with a short ring.
        final ring = v == Voice.tek ? 950.0 : 820.0;
        final a = guideVolume * (v == Voice.tek ? 0.8 : 0.6);
        var prev = 0.0;
        return _gen((0.12 * sr).round(), (t) {
          final n = rng.nextDouble() * 2 - 1;
          final hp = n - prev; // crude high-pass
          prev = n;
          return a * (0.6 * hp * math.exp(-t / 0.008) + 0.5 * math.sin(2 * math.pi * ring * t) * math.exp(-t / 0.03));
        });
    }
  }

  Float32List _gen(int n, double Function(double t) f) {
    final out = Float32List(n);
    for (var i = 0; i < n; i++) {
      out[i] = f(i / sampleRate);
    }
    return out;
  }

  /// Mixes [events] into a buffer of [seconds]; sounds running past the end wrap
  /// around so that the buffer loops seamlessly.
  Rendered mix(double seconds, List<Scheduled> events) {
    final n = (seconds * sampleRate).round();
    final out = Float32List(n);
    for (final e in events) {
      final s = sample(e.voice);
      final start = (e.t * sampleRate).round();
      for (var i = 0; i < s.length; i++) {
        final k = (start + i) % n;
        out[k] += s[i];
      }
    }
    final noise = math.Random(1);
    for (var i = 0; i < n; i++) {
      // A faint noise floor instead of digital silence: some phone speaker
      // amplifiers power down after ~0.3 s of zeros and click when they do.
      out[i] = (out[i] + (noise.nextDouble() - 0.5) * 4e-4).clamp(-1.0, 1.0);
    }
    return Rendered(out, events);
  }

  /// Count-in: [beats] clicks at the pattern tempo, the first accented.
  Rendered countIn(Pattern p, int beats) {
    final beat = 60 / p.bpm;
    return mix(beat * beats, [
      for (var b = 0; b < beats; b++) (t: b * beat, voice: b == 0 ? Voice.accent : Voice.click),
    ]);
  }

  /// One full practice loop: [Pattern.soundCycles] cycles with sound followed by
  /// [Pattern.silentCycles] silent ones (just one cycle if there is no silence).
  Rendered loop(Pattern p) {
    final silent = p.silentCycles > 0;
    final cycles = silent ? p.soundCycles + p.silentCycles : 1;
    final events = <Scheduled>[];
    for (var c = 0; c < (silent ? p.soundCycles : 1); c++) {
      final base = c * p.cycleSeconds;
      for (var b = 0; b < p.beats; b++) {
        final click = switch (p.clickMode) {
          ClickMode.beat => b == 0 ? Voice.accent : Voice.click,
          ClickMode.cycle => b == 0 ? Voice.accent : null,
          ClickMode.off => null,
        };
        if (click != null) events.add((t: base + b * 60 / p.bpm, voice: click));
      }
      if (p.guide) {
        for (var i = 0; i < p.steps.length; i++) {
          final v = switch (p.steps[i]) {
            Stroke.dum => Voice.dum,
            Stroke.tek => Voice.tek,
            Stroke.ka => Voice.ka,
            Stroke.rest => null,
          };
          if (v != null) events.add((t: base + i * p.stepSeconds, voice: v));
        }
      }
    }
    return mix(cycles * p.cycleSeconds, events);
  }

  /// Latency test: clicks, then each guide voice, spaced apart so that echoes
  /// and decays don't overlap.
  Rendered calibration() {
    const gap = 0.45;
    final voices = [
      for (var i = 0; i < 10; i++) Voice.click,
      Voice.accent,
      Voice.accent,
      Voice.dum,
      Voice.dum,
      Voice.tek,
      Voice.tek,
      Voice.ka,
      Voice.ka,
    ];
    return mix(gap * (voices.length + 2), [for (final (i, v) in voices.indexed) (t: gap * (i + 1), voice: v)]);
  }
}
