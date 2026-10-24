import 'dart:math' as math;
import 'dart:typed_data';

/// Crude model of a 40 cm frame drum for tests: circular membrane modes with
/// long decays and beating, and an attack transient. A dum excites the low
/// modes strongly; a tek (rim) excites the same membrane, only weaker in the
/// low modes and with a sharper, brighter attack. Both ring well past the
/// next stroke at practice tempos.
class DrumSim {
  DrumSim(this.sampleRate, {int seed = 1, this.similar = false}) : _rng = math.Random(seed);

  final int sampleRate;

  /// Tek nearly as low and long as dum, dum attack nearly as bright as tek.
  final bool similar;
  final math.Random _rng;

  static const f0 = 68.0;

  // Bessel-zero ratios of a membrane; 2.14/2.30 are close enough to beat.
  static const _ratios = [1.0, 1.59, 2.14, 2.30, 2.65, 2.92, 3.16, 3.50, 3.60, 4.06];

  double _j(double spread) => 1 + (_rng.nextDouble() * 2 - 1) * spread;

  /// Adds one stroke at [t] seconds into [out].
  void stroke(Float32List out, double t, {required bool dum, double gain = 1}) {
    final start = (t * sampleRate).round();
    final sr = sampleRate.toDouble();
    final g = gain * _j(0.3);
    final modes = <(double, double, double)>[]; // freq, amp, tau
    for (final (i, r) in _ratios.indexed) {
      final amp = dum ? 1.0 / (1 + i * 0.6) : (similar ? 0.6 / (1 + i * 0.5) : 0.25 / (1 + (i - 5).abs() * 0.4));
      final tau = (dum ? 0.9 : (similar ? 0.6 : 0.35)) / (1 + i * 0.25);
      modes.add((f0 * r * _j(0.01), amp * _j(0.3), tau * _j(0.15)));
    }
    final n = (3.0 * sr).round();
    final phases = [for (var i = 0; i < modes.length; i++) _rng.nextDouble() * 2 * math.pi];
    // Attack: high-passed noise, longer and duller for dum.
    final clickTau = dum ? 0.004 : 0.0015;
    final clickAmp = similar ? (dum ? 0.4 : 0.5) : (dum ? 0.25 : 0.6);
    var prev = 0.0;
    for (var k = 0; k < n && start + k < out.length; k++) {
      final tt = k / sr;
      var y = 0.0;
      for (var m = 0; m < modes.length; m++) {
        final (f, a, tau) = modes[m];
        y += a * math.exp(-tt / tau) * math.sin(2 * math.pi * f * tt + phases[m]);
      }
      final nz = _rng.nextDouble() * 2 - 1;
      final hp = nz - prev;
      prev = nz;
      y += clickAmp * hp * math.exp(-tt / clickTau);
      if (!dum) y += 0.15 * math.sin(2 * math.pi * 1900 * tt) * math.exp(-tt / 0.02); // rim ring
      // Soft attack ramp (~0.5 ms) like a hand on a skin.
      final ramp = math.min(1.0, tt / 0.0005) * math.min(1.0, (n - k) / (0.5 * sr));
      out[start + k] += 0.25 * g * ramp * y;
    }
  }

  /// [hits] as (time, isDum) over room noise; starts with silence for the filters.
  Float32List render(double seconds, List<(double, bool)> hits, {double noise = 0.002, double gainJitter = 0}) {
    final out = Float32List((seconds * sampleRate).round());
    for (var i = 0; i < out.length; i++) {
      out[i] = (_rng.nextDouble() * 2 - 1) * noise;
    }
    for (final (t, dum) in hits) {
      stroke(out, t, dum: dum, gain: 1 + (_rng.nextDouble() * 2 - 1) * gainJitter);
    }
    return out;
  }
}
