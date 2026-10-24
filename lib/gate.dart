import 'dsp.dart';
import 'synth.dart';

/// Our own guide strokes as the mic hears them through a phone speaker are
/// dropped unless the hit is this much louder than the calibrated level.
const gateMarginDb = 6.0;

/// Level assumed for our sounds before calibration.
const defaultSelfLevelDb = -20.0;

/// A stroke raises at least one band outside the click's by this much.
const strokeRiseDb = 6.0;

/// Ignores hits that coincide with sounds the app itself plays.
///
/// Loudness fails for clicks: through the phone's own speaker a click can be
/// as loud as the drum, and it often lands on the ringing of the previous
/// stroke. But a click lives above 5.8 kHz, while a stroke also moves the
/// skin below 720 Hz or has its attack and rim ring at 1.4–2.9 kHz. So an
/// attack at a click time is only provisional ([nearOwnSound]) and doesn't
/// block a stroke right after it; once measured, [isSelf] drops it if it shows
/// neither. Guide strokes sound like real ones, so
/// for them the calibrated level decides.
class SelfSoundGate {
  SelfSoundGate({
    required this.intro,
    required this.loop,
    required this.introSeconds,
    required this.loopSeconds,
    required this.levels,
  });

  final List<Scheduled> intro, loop;
  final double introSeconds, loopSeconds;
  final Map<Voice, double> levels;

  static const before = 0.010, after = 0.025;

  /// Whether song time [t] falls on one of our sounds that may explain an
  /// attack of [peakDb].
  bool nearOwnSound(double t, double peakDb) => _near(t, (v) => _isClick(v) || _quiet(v, peakDb));

  /// Whether a measured onset at song time [t] is probably our own sound.
  bool isSelf(double t, Onset o) => _near(t, (v) => _isClick(v) ? _onlyClickBands(o) : _quiet(v, o.peakDb));

  bool _near(double t, bool Function(Voice v) test) {
    bool at(Scheduled e, double tt) => tt - e.t >= -before && tt - e.t <= after && test(e.voice);
    if (t < introSeconds + after) {
      if (intro.any((e) => at(e, t))) return true;
    }
    if (t >= introSeconds - before) {
      final tl = (t - introSeconds) % loopSeconds;
      for (final e in loop) {
        if (at(e, tl) || at(e, tl + loopSeconds) || at(e, tl - loopSeconds)) return true;
      }
    }
    return false;
  }

  static bool _isClick(Voice v) => v == Voice.click || v == Voice.accent;

  bool _quiet(Voice v, double peakDb) => peakDb < (levels[v] ?? defaultSelfLevelDb) + gateMarginDb;

  static bool _onlyClickBands(Onset o) {
    final r = o.bandRise, l = o.bandLevel;
    if (r.length < 8 || l.length < 8) return true;
    // The skin below 720 Hz moved: a stroke.
    for (var b = 0; b < 4; b++) {
      if (r[b] >= strokeRiseDb) return false;
    }
    // An attack or rim ring at 1.4–2.9 kHz, not just leakage far below the
    // click (2.9–5.8 kHz is too close to the click to tell).
    return !(r[5] >= strokeRiseDb && l[5] >= l[7] - 15);
  }
}
