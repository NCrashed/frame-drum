import 'dart:math' as math;
import 'dart:typed_data';

/// A detected drum hit.
class Onset {
  Onset({
    required this.t,
    required this.peakDb,
    required this.features,
    this.bandRise = const [],
    this.bandLevel = const [],
    this.strength = 0,
    this.toneDb = 0,
  });

  /// Capture time in the native clock, nanoseconds.
  final int t;

  /// Loudest broadband hop level around the attack, dBFS.
  final double peakDb;

  /// Level rise per octave band against the 20 ms before the attack, dB.
  final List<double> bandRise;

  /// Level per octave band in the 40 ms after the attack, dB.
  final List<double> bandLevel;

  /// Peak of the detection function (average band rise, dB).
  final double strength;

  /// Spectral description of the stroke (see [OnsetDetector]).
  final List<double> features;

  /// Dum-versus-rim score: positive means dum. Set by a [StrokeModel].
  double toneDb;

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

  /// Narrow band-stop at [f]; [q] sets its width (f / q).
  factory Biquad.notch(double f, double sr, [double q = 4]) {
    final w = 2 * math.pi * f / sr, c = math.cos(w), al = math.sin(w) / (2 * q), a0 = 1 + al;
    return Biquad._(1 / a0, -2 * c / a0, 1 / a0, -2 * c / a0, (1 - al) / a0);
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

/// Octave band edges, Hz.
const bandEdges = [40.0, 90.0, 180.0, 360.0, 720.0, 1440.0, 2880.0, 5760.0, 11500.0];

/// Streaming onset detector for a large frame drum.
///
/// The signal is split into 8 octave bands and handled in 64-sample hops
/// (~1.3 ms at 48 kHz). A big drum keeps ringing in the low bands for a long
/// time and its modes beat, so loudness alone gives false and late onsets.
/// Instead the detection function is the weighted average of the rise of
/// each band's level over a few milliseconds; upper bands, where every stroke
/// has a sharp attack and nothing rings for long, weigh the most.
///
/// The attack time is then refined on the raw upper-band energy: the first hop
/// reaching a quarter of the attack peak.
///
/// Each onset carries features for [StrokeModel]: per band, how much the level
/// rose against the 20 ms before the stroke (so leftover ringing of the
/// previous dum doesn't count), and the spectral shape right after it.
class OnsetDetector {
  OnsetDetector({
    required this.sampleRate,
    this.riseDb = 9,
    this.minLevelDb = -55,
    this.minGapMs = 45,
    this.model,
    List<double> notchHz = const [],
  }) : _hp = Biquad.highPass(30, sampleRate.toDouble()),
       // Two cascaded notches per frequency: our metronome tones are removed
       // before analysis, so a click under a stroke doesn't change its sound.
       _notches = [
         for (final f in notchHz)
           if (f < sampleRate * 0.45) ...[
             Biquad.notch(f, sampleRate.toDouble()),
             Biquad.notch(f, sampleRate.toDouble()),
           ],
       ] {
    final sr = sampleRate.toDouble();
    for (var b = 0; b < bandCount; b++) {
      final hi = math.min(bandEdges[b + 1], sr * 0.45);
      _filters.add([
        Biquad.highPass(bandEdges[b], sr),
        Biquad.highPass(bandEdges[b], sr),
        Biquad.lowPass(hi, sr),
        Biquad.lowPass(hi, sr),
      ]);
      // Envelope smoothing over about one and a half periods of the band's
      // lowest frequency, so that low bands don't ripple with the waveform.
      final tau = math.max(0.002, 1.5 / bandEdges[b]);
      _alpha.add(1 - math.exp(-hop / (tau * sr)));
      _lag.add(math.max(3, (tau * sr / hop).round()));
    }
  }

  final int sampleRate;

  /// Detection threshold: weighted average band rise, dB.
  double riseDb;

  /// Quietest broadband hop level that can be a stroke, dBFS.
  double minLevelDb;

  /// No new stroke within this time after the previous one.
  double minGapMs;

  /// A much louder attack this soon after an onset replaces it (pre-touch, flam).
  static const mergeMs = 100.0;

  /// Classifier filling [Onset.toneDb]; a fixed low-minus-high rule without it.
  StrokeModel? model;

  /// Called when an attack is found: true marks it as probably our own sound
  /// (it falls on our click). Such an onset neither starts the refractory
  /// period nor counts towards the typical stroke strength, so a stroke right
  /// after the click is still found; [ignore] makes the final call on both.
  bool Function(int t, double peakDb)? provisional;

  /// Called with each measured onset before it is emitted; returning true
  /// drops it and undoes its refractory period and its effect on the
  /// adaptive threshold (used to skip our own metronome clicks).
  bool Function(Onset onset)? ignore;

  static const hop = 64;

  /// Input magnitude counted as clipping.
  static const clipLevel = 0.98;
  static const bandCount = 8;

  /// Length of [Onset.features].
  static int get featureCount => 2 * (bandCount - featureSkip.length);

  /// Bands left out of [Onset.features].
  static var featureSkip = const {7};
  static const _weights = [0.05, 0.1, 0.2, 0.5, 1.0, 1.0, 1.0, 1.0];
  static const _ring = 128; // hops of history (~170 ms)
  static const _beforeFrom = 18, _beforeTo = 3; // hops before the attack used as "before"
  static const _afterHops = 30; // ~40 ms used as "after"

  final Biquad _hp;
  final List<Biquad> _notches;
  final _filters = <List<Biquad>>[];
  final _alpha = <double>[];
  final _lag = <int>[];

  // Per hop, indexed by absolute hop number modulo _ring.
  final _raw = List.generate(bandCount, (_) => Float64List(_ring));
  final _env = List.generate(bandCount, (_) => Float64List(_ring)); // smoothed, dB
  final _broad = Float64List(_ring); // dB
  final _attack = Float64List(_ring); // raw energy above 720 Hz
  final _hopTime = List<int>.filled(_ring, 0);
  final _smooth = Float64List(bandCount);

  var _n = 0; // hops processed
  var _fill = 0;
  final _acc = Float64List(bandCount);
  var _accBroad = 0.0;
  var _accClip = 0;
  int _lastClipHop = -1 << 30;

  /// [overload] above this means the mic clips often enough to matter.
  static const overloadWarning = 0.01;

  /// Share of recent hops with clipped samples (mic overload), 0..1.
  double overload = 0;
  int? _hopStart;

  // Peak picking.
  int? _candidate; // hop where the detection function crossed the threshold
  var _candidatePeak = 0.0;
  int _lastOnsetHop = -1 << 30;
  double _lastOnsetStrength = 0;
  double _lastLoud = -120;
  (int, double, double) _prevOnset = (-1 << 30, 0, -120);
  var _merging = false;

  /// Strengths of recent strokes: the threshold follows how hard the player hits.
  final _recent = <double>[];

  double get _typicalNeed {
    if (_recent.length < 4) return 0;
    final s = [..._recent]..sort();
    // Distortion of a clipping mic looks like weak attacks, so be stricter then.
    final clipping = _n - _lastClipHop < 20;
    return (clipping ? 0.65 : 0.4) * s[(s.length * 0.8).floor().clamp(0, s.length - 1)];
  }

  final _pending = <int>[]; // onset hops waiting for their "after" window
  final _pendingStrength = <double>[];
  final _pendingProvisional = <bool>[];

  /// Most recent broadband level, for the input meter.
  double levelDb = -120;

  /// Detection function of the latest hop, for diagnostics.
  double strength = 0;

  double get _hopMs => hop * 1000 / sampleRate;

  int get _mergeHops => (mergeMs / _hopMs).ceil();

  /// Feeds samples whose first one was captured at native time [t] (ns).
  List<Onset> feed(Float32List pcm, int t) {
    final out = <Onset>[];
    final nsPerSample = 1e9 / sampleRate;
    for (var i = 0; i < pcm.length; i++) {
      if (pcm[i].abs() >= clipLevel) _accClip++;
      var x = _hp(pcm[i]);
      for (final n in _notches) {
        x = n(x);
      }
      if (_fill == 0) _hopStart = t + (i * nsPerSample).round();
      _accBroad += x * x;
      for (var b = 0; b < bandCount; b++) {
        final f = _filters[b];
        final y = f[3](f[2](f[1](f[0](x))));
        _acc[b] += y * y;
      }
      if (++_fill == hop) {
        _hop(_hopStart!, out);
        _fill = 0;
        _accBroad = 0;
        _accClip = 0;
        _acc.fillRange(0, bandCount, 0);
      }
    }
    return out;
  }

  int _at(int hopIndex) => hopIndex % _ring;

  void _hop(int t, List<Onset> out) {
    final n = _n++;
    final k = _at(n);
    _hopTime[k] = t;
    _broad[k] = levelDb = toDb(_accBroad / hop);
    var attack = 0.0;
    for (var b = 0; b < bandCount; b++) {
      final e = _acc[b] / hop;
      _raw[b][k] = e;
      _smooth[b] += _alpha[b] * (e - _smooth[b]);
      _env[b][k] = toDb(_smooth[b]);
      if (b >= 4) attack += e;
    }
    _attack[k] = attack;
    final clipped = _accClip > 0;
    if (clipped) _lastClipHop = n;
    overload += ((clipped ? 1 : 0) - overload) * 0.002; // ~0.7 s

    // Weighted average rise of the band envelopes (after the filters settle).
    var d = 0.0;
    if (n >= _ring) {
      var w = 0.0, top = 0.0;
      for (var b = 0; b < bandCount; b++) {
        final rise = math.max(0.0, _env[b][k] - _env[b][_at(n - _lag[b])]);
        d += _weights[b] * rise;
        w += _weights[b];
        if (b >= 5) top += rise / 3;
      }
      d /= w;
      // Beating modes of the ringing membrane raise single bands; a stroke
      // also has an attack above 1.4 kHz.
      if (top < riseDb / 2) d = 0;
    }
    strength = d;

    _pick(n, d);
    _flush(n, out);
  }

  void _pick(int n, double d) {
    final c = _candidate;
    if (c != null) {
      // Let the detection function reach its peak (at most ~5 ms).
      if (d > _candidatePeak && n - c < 4) {
        _candidatePeak = d;
        return;
      }
      _candidate = null;
      _accept(c, n, _candidatePeak, merge: _merging);
      _merging = false;
      return;
    }
    final sinceLast = (n - _lastOnsetHop) * _hopMs;
    if (sinceLast < minGapMs) {
      // Fingers touching the skin just before the palm: the louder main
      // stroke may follow within a few tens of ms and should replace it.
      if (sinceLast <= mergeMs && d >= riseDb) {
        _candidate = n;
        _candidatePeak = d;
        _merging = true;
      }
      return;
    }
    // Weak "attacks" are echoes, beating modes or distortion of an overloaded
    // mic: relative to how hard this player hits, and especially soon after
    // the previous stroke while it still rings.
    final mask = 0.6 * _lastOnsetStrength * math.exp(-sinceLast / 500);
    final need = math.max(riseDb, math.max(_typicalNeed, mask));
    if (d >= need) {
      _candidate = n;
      _candidatePeak = d;
    }
  }

  void _accept(int cross, int now, double strength, {bool merge = false}) {
    // Attack peak in the upper bands around the crossing.
    final from = math.max(cross - 3, now - _ring + 1);
    var peakHop = cross, peak = 0.0, loud = -120.0;
    for (var h = from; h <= now; h++) {
      if (_attack[_at(h)] > peak) {
        peak = _attack[_at(h)];
        peakHop = h;
      }
      loud = math.max(loud, _broad[_at(h)]);
    }
    if (loud < minLevelDb) return;
    var onset = peakHop;
    for (var h = from; h <= peakHop; h++) {
      if (_attack[_at(h)] >= peak * 0.25) {
        onset = h;
        break;
      }
    }
    if (!merge && (provisional?.call(_hopTime[_at(onset)], loud) ?? false)) {
      // Neither starts the refractory period nor counts as a typical stroke.
      _pending.add(onset);
      _pendingStrength.add(strength);
      _pendingProvisional.add(true);
      return;
    }
    if (merge) {
      // Replace the previous onset only by a clearly louder one still pending.
      if (loud < _lastLoud + 6 || _pending.isEmpty || _pending.last != _lastOnsetHop) return;
      _pending.removeLast();
      _pendingStrength.removeLast();
      _pendingProvisional.removeLast();
      _recent.removeLast();
    } else {
      _prevOnset = (_lastOnsetHop, _lastOnsetStrength, _lastLoud);
    }
    _lastLoud = loud;
    _lastOnsetHop = onset;
    _lastOnsetStrength = strength;
    _recent.add(strength);
    if (_recent.length > 16) _recent.removeAt(0);
    _pending.add(onset);
    _pendingStrength.add(strength);
    _pendingProvisional.add(false);
  }

  /// Emits pending onsets whose "after" window is complete or cut short by
  /// the next onset.
  void _flush(int n, List<Onset> out) {
    while (_pending.isNotEmpty) {
      final o = _pending.first;
      final last = _pending.length == 1;
      final end = last ? o + _afterHops : math.min(_pending[1], o + _afterHops);
      // The last onset may still be replaced by a louder main stroke.
      if (n < end || (last && n < o + _mergeHops)) return;
      _pending.removeAt(0);
      final strength = _pendingStrength.removeAt(0);
      final prov = _pendingProvisional.removeAt(0);
      final onset = _measure(o, end, strength);
      if (ignore?.call(onset) ?? false) {
        if (prov) continue;
        _recent.remove(strength);
        if (o == _lastOnsetHop) {
          final (hop, s, loud) = _prevOnset;
          _lastOnsetHop = hop;
          _lastOnsetStrength = s;
          _lastLoud = loud;
        }
        continue;
      }
      out.add(onset);
    }
  }

  Onset _measure(int o, int end, double strength) {
    final rises = <double>[], shape = <double>[];
    var loud = -120.0;
    for (var h = o; h < end; h++) {
      loud = math.max(loud, _broad[_at(h)]);
    }
    for (var b = 0; b < bandCount; b++) {
      var before = 0.0, after = 0.0;
      for (var h = o - _beforeFrom; h < o - _beforeTo; h++) {
        before += _raw[b][_at(h)];
      }
      for (var h = o; h < end; h++) {
        after += _raw[b][_at(h)];
      }
      before /= _beforeFrom - _beforeTo;
      after /= math.max(1, end - o);
      rises.add((toDb(after) - toDb(before)).clamp(-10.0, 60.0));
      shape.add(toDb(after));
    }
    // Loudness-free: subtract the mean over bands.
    // Classification skips the octave of the metronome tones (above 5.8 kHz):
    // through a phone speaker the click dominates them, and a dum played on
    // the click would look like a rim stroke.
    final keep = [
      for (var b = 0; b < bandCount; b++)
        if (!featureSkip.contains(b)) b,
    ];
    final mr = mean(keep.map((b) => rises[b])), ms = mean(keep.map((b) => shape[b]));
    final features = [for (final b in keep) rises[b] - mr, for (final b in keep) shape[b] - ms];
    final onset = Onset(
      t: _hopTime[_at(o)],
      peakDb: loud,
      features: features,
      bandRise: rises,
      bandLevel: shape,
      strength: strength,
    );
    onset.toneDb = model?.score(features) ?? StrokeModel.fallback(features);
    return onset;
  }
}

/// Dum-versus-rim classifier learned from the player's own drum: Gaussians
/// with a per-feature variance shared by all classes. Tek and ka are both rim
/// strokes but of different hands, and can sound rather different, so each
/// has its own centre. [score] is the log-likelihood ratio of dum against the
/// closer rim stroke, positive for dum.
class StrokeModel {
  StrokeModel(this.dum, this.tek, this.variance, [this.ka]);

  final List<double> dum, tek, variance;
  final List<double>? ka;

  /// Variance floor: features closer than ~2 dB are not trusted to differ.
  static const _minVar = 4.0;

  /// Fewest ka strokes for ka to get its own centre.
  static const _minKa = 3;

  factory StrokeModel.fit(List<List<double>> dums, List<List<double>> teks, [List<List<double>> kas = const []]) {
    final dim = dums.first.length;
    List<double> meanOf(List<List<double>> xs) => [for (var i = 0; i < dim; i++) mean(xs.map((x) => x[i]))];
    final classes = [(dums, meanOf(dums)), (teks, meanOf(teks)), if (kas.length >= _minKa) (kas, meanOf(kas))];
    final v = List<double>.filled(dim, 0);
    var n = 0;
    for (final (xs, m) in classes) {
      n += xs.length;
      for (final x in xs) {
        for (var i = 0; i < dim; i++) {
          v[i] += (x[i] - m[i]) * (x[i] - m[i]);
        }
      }
    }
    final dof = math.max(1, n - classes.length);
    return StrokeModel(classes[0].$2, classes[1].$2, [
      for (final x in v) math.max(_minVar, x / dof),
    ], classes.length > 2 ? classes[2].$2 : null);
  }

  double _ll(List<double> x, List<double> m) {
    var s = 0.0;
    for (var i = 0; i < x.length; i++) {
      final d = x[i] - m[i];
      s -= d * d / (2 * variance[i]);
    }
    return s;
  }

  double score(List<double> x) {
    final k = ka;
    final rim = k == null ? _ll(x, tek) : math.max(_ll(x, tek), _ll(x, k));
    return _ll(x, dum) - rim;
  }

  /// Without calibration: low bands rising more than high ones means dum.
  /// Features start with the rises of bands 0..6 (see [OnsetDetector.featureSkip]).
  static double fallback(List<double> f) => (f[0] + f[1] + f[2]) / 3 - (f[4] + f[5] + f[6]) / 3;

  /// Leave-one-out scores of the training strokes, showing how separable they are.
  static (List<double>, List<double>, List<double>) crossValidate(
    List<List<double>> dums,
    List<List<double>> teks, [
    List<List<double>> kas = const [],
  ]) {
    List<double> each(List<List<double>> xs, StrokeModel Function(List<List<double>> rest) fit) => [
      for (var i = 0; i < xs.length; i++) fit([...xs]..removeAt(i)).score(xs[i]),
    ];
    return (
      each(dums, (r) => StrokeModel.fit(r, teks, kas)),
      each(teks, (r) => StrokeModel.fit(dums, r, kas)),
      each(kas, (r) => StrokeModel.fit(dums, teks, r)),
    );
  }

  Map<String, dynamic> toJson() => {'dum': dum, 'tek': tek, 'var': variance, if (ka != null) 'ka': ka};

  static StrokeModel? fromJson(Object? j) {
    if (j is! Map) return null;
    List<double> l(Object? x) => (x as List).map((v) => (v as num).toDouble()).toList();
    return StrokeModel(l(j['dum']), l(j['tek']), l(j['var']), j['ka'] == null ? null : l(j['ka']));
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
