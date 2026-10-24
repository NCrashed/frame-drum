import 'dart:math' as math;
import 'dart:typed_data';

/// A detected drum hit.
class Onset {
  Onset({required this.t, required this.peakDb, required this.toneDb});

  /// Capture time in the native clock, nanoseconds.
  final int t;

  /// Loudest hop energy after the attack, dBFS.
  final double peakDb;

  /// Low-band minus high-band energy right after the attack, dB. Positive for
  /// a dum (centre of the head), negative for rim strokes.
  final double toneDb;

  bool isLow(double threshold) => toneDb >= threshold;

  @override
  String toString() => 'Onset(t: $t, peak: ${peakDb.toStringAsFixed(1)}, tone: ${toneDb.toStringAsFixed(1)})';
}

/// Second-order section (RBJ cookbook).
class Biquad {
  Biquad._(this.b0, this.b1, this.b2, this.a1, this.a2);

  factory Biquad.lowPass(double f, double sr, [double q = 0.7071]) {
    final w = 2 * math.pi * f / sr, c = math.cos(w), al = math.sin(w) / (2 * q), a0 = 1 + al;
    return Biquad._((1 - c) / 2 / a0, (1 - c) / a0, (1 - c) / 2 / a0, -2 * c / a0, (1 - al) / a0);
  }

  factory Biquad.highPass(double f, double sr, [double q = 0.7071]) {
    final w = 2 * math.pi * f / sr, c = math.cos(w), al = math.sin(w) / (2 * q), a0 = 1 + al;
    return Biquad._((1 + c) / 2 / a0, -(1 + c) / a0, (1 + c) / 2 / a0, -2 * c / a0, (1 - al) / a0);
  }

  final double b0, b1, b2, a1, a2;
  double _x1 = 0, _x2 = 0, _y1 = 0, _y2 = 0;

  double call(double x) {
    final y = b0 * x + b1 * _x1 + b2 * _x2 - a1 * _y1 - a2 * _y2;
    _x2 = _x1;
    _x1 = x;
    _y2 = _y1;
    _y1 = y;
    return y;
  }
}

double toDb(double power) => 10 * math.log(power + 1e-12) / math.ln10;

/// Streaming onset detector tuned for hand drums.
///
/// Works on 64-sample hops (~1.3 ms at 48 kHz). An onset starts when the hop
/// energy jumps [riseDb] above the quietest hop of the preceding ~15 ms and is
/// above [minLevelDb]. Then for [measureMs] it collects the peak level and the
/// low/high band balance used to tell dum from tek. A louder event inside that
/// window that rises [riseDb] from the decay of the first one (e.g. a drum hit
/// right after a metronome click) closes the current onset and starts a new one.
class OnsetDetector {
  OnsetDetector({required this.sampleRate, this.riseDb = 12, this.minLevelDb = -50, this.measureMs = 35})
    : _hp = Biquad.highPass(40, sampleRate.toDouble()),
      _lowA = Biquad.lowPass(250, sampleRate.toDouble()),
      _lowB = Biquad.lowPass(250, sampleRate.toDouble()),
      _highA = Biquad.highPass(1500, sampleRate.toDouble()),
      _highB = Biquad.highPass(1500, sampleRate.toDouble());

  final int sampleRate;
  double riseDb;
  double minLevelDb;
  final double measureMs;

  static const hop = 64;
  static const _ring = 24;
  static const _baseHops = 16; // ~21 ms: longer than a period of the lowest dum partial
  static const _skip = 2; // most recent hops left out of the baseline (attack ramp)
  static const _smoothHops = 8;

  final Biquad _hp, _lowA, _lowB, _highA, _highB;
  final _power = List<double>.filled(_ring, 1e-12); // linear hop powers
  var _pos = 0;
  var _warmup = _ring;

  // Partial hop carried between feed() calls.
  var _fill = 0;
  var _accE = 0.0, _accLow = 0.0, _accHigh = 0.0;
  int? _hopStart; // native time of the current hop's first sample

  // Active measurement.
  int? _onsetT;
  var _hopsLeft = 0;
  var _peak = -120.0, _smoothPeak = -120.0, _dip = -120.0, _low = 0.0, _high = 0.0;

  /// Most recent hop level, for the input meter.
  double levelDb = -120;

  int get _measureHops => (measureMs / 1000 * sampleRate / hop).round();

  /// Feeds samples whose first one was captured at native time [t] (ns).
  List<Onset> feed(Float32List pcm, int t) {
    final out = <Onset>[];
    final nsPerSample = 1e9 / sampleRate;
    for (var i = 0; i < pcm.length; i++) {
      final x = _hp(pcm[i]);
      final lo = _lowB(_lowA(x)), hi = _highB(_highA(x));
      if (_fill == 0) _hopStart = t + (i * nsPerSample).round();
      _accE += x * x;
      _accLow += lo * lo;
      _accHigh += hi * hi;
      if (++_fill == hop) {
        _hop(_hopStart!, out);
        _fill = 0;
        _accE = _accLow = _accHigh = 0;
      }
    }
    return out;
  }

  /// Mean power of hops [from, to) back from the current one, dB.
  double _meanDb(int from, int to) {
    var s = 0.0;
    for (var k = from; k < to; k++) {
      s += _power[(_pos - k + _ring) % _ring];
    }
    return toDb(s / (to - from));
  }

  void _hop(int t, List<Onset> out) {
    final p = _accE / hop;
    final e = toDb(p);
    levelDb = e;
    _pos = (_pos + 1) % _ring;
    _power[_pos] = p;
    // Hop energy of a low sine swings with its phase, so compare against
    // averages rather than single hops.
    final base = _meanDb(_skip, _skip + _baseHops);
    final smooth = _meanDb(0, _smoothHops);

    if (_onsetT != null) {
      // A new attack rising well above the decay (not the ramp) of the current one.
      if (e > _peak && e - _dip >= riseDb && _dip < _smoothPeak - 3) {
        _emit(out);
        _start(t, e, smooth);
        return;
      }
      _peak = math.max(_peak, e);
      if (smooth > _smoothPeak) {
        _smoothPeak = _dip = smooth;
      } else {
        _dip = math.min(_dip, smooth);
      }
      _low += _accLow;
      _high += _accHigh;
      if (--_hopsLeft == 0) _emit(out);
      return;
    }
    if (_warmup > 0) {
      _warmup--;
      return;
    }
    if (e - base >= riseDb && e >= minLevelDb) _start(t, e, smooth);
  }

  void _start(int t, double e, double smooth) {
    _onsetT = t;
    _hopsLeft = _measureHops;
    _peak = e;
    _smoothPeak = _dip = smooth;
    _low = _accLow;
    _high = _accHigh;
  }

  void _emit(List<Onset> out) {
    out.add(Onset(t: _onsetT!, peakDb: _peak, toneDb: toDb(_low) - toDb(_high)));
    _onsetT = null;
  }
}

double median(List<double> xs) {
  if (xs.isEmpty) return double.nan;
  final s = [...xs]..sort();
  final m = s.length ~/ 2;
  return s.length.isOdd ? s[m] : (s[m - 1] + s[m]) / 2;
}

double mean(Iterable<double> xs) => xs.isEmpty ? double.nan : xs.reduce((a, b) => a + b) / xs.length;

double stdDev(List<double> xs) {
  if (xs.length < 2) return double.nan;
  final m = mean(xs);
  return math.sqrt(xs.map((x) => (x - m) * (x - m)).reduce((a, b) => a + b) / (xs.length - 1));
}
