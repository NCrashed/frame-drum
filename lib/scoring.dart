import 'dart:math' as math;

import 'dsp.dart';
import 'pattern.dart';

enum Grade {
  good('точно'),
  ok('близко'),
  off('мимо'),
  miss('пропуск'),
  extra('лишний');

  const Grade(this.label);
  final String label;
}

/// A stroke the player is supposed to play, [t] seconds into the session.
class Expected {
  Expected(this.k, this.stroke, this.t, this.silent);
  final int k; // global step number since the end of the count-in
  final Stroke stroke;
  final double t;
  final bool silent;
  Hit? hit;
  bool closed = false;
}

class Hit {
  Hit(this.t, this.low, this.peakDb);
  final double t;
  final bool low;
  final double peakDb;
  Expected? target;
  Grade grade = Grade.extra;

  /// Positive when late.
  double get offsetMs => target == null ? double.nan : (t - target!.t) * 1000;
  bool get strokeOk => target != null && target!.stroke.isLow == low;
}

class Tally {
  int expected = 0, good = 0, ok = 0, off = 0, missed = 0, extras = 0, strokeOk = 0;
  final offsets = <double>[];

  int get hits => good + ok + off;
  double get accuracy => expected == 0 ? double.nan : (good + ok) / expected;
  double get strokeRate => hits == 0 ? double.nan : strokeOk / hits;
  double get meanMs => mean(offsets);
  double get sdMs => stdDev(offsets);

  void add(Expected e) {
    expected++;
    final h = e.hit;
    if (h == null) {
      missed++;
      return;
    }
    switch (h.grade) {
      case Grade.good:
        good++;
      case Grade.ok:
        ok++;
      default:
        off++;
    }
    if (h.strokeOk) strokeOk++;
    offsets.add(h.offsetMs);
  }
}

/// Matches detected hits to the pattern's expected strokes.
///
/// Times are seconds from the start of the count-in; [start] is where the
/// first cycle begins. A hit goes to the nearest expected stroke within
/// [window]; a hit with no free stroke nearby is "extra". A stroke whose window
/// has passed without a hit is a miss.
class Scorer {
  Scorer(this.pattern, {required this.start, required this.lowThreshold, this.goodMs = 25, this.okMs = 50})
    : window = _window(pattern);

  final Pattern pattern;
  final double start;
  final double lowThreshold;
  final double goodMs, okMs;
  final double window;

  final expected = <Expected>[];
  final hits = <Hit>[];
  final sound = Tally();
  final silent = Tally();
  Tally get all => _all;
  final _all = Tally();

  var _nextK = 0;
  var _firstOpen = 0;

  /// Half the shortest gap between strokes, within 40..150 ms.
  static double _window(Pattern p) {
    final idx = [
      for (var i = 0; i < p.steps.length; i++)
        if (p.steps[i].isHit) i,
    ];
    if (idx.isEmpty) return 0.15;
    var gap = p.steps.length;
    for (var i = 0; i < idx.length; i++) {
      final d = (idx[(i + 1) % idx.length] - idx[i] + p.steps.length) % p.steps.length;
      gap = math.min(gap, d == 0 ? p.steps.length : d);
    }
    return (gap * p.stepSeconds / 2).clamp(0.04, 0.15);
  }

  bool silentAt(int k) {
    if (pattern.silentCycles == 0) return false;
    final c = k ~/ pattern.steps.length;
    return c % (pattern.soundCycles + pattern.silentCycles) >= pattern.soundCycles;
  }

  /// Cycle position in 0..1 for time [t].
  double phase(double t) {
    final x = (t - start) / pattern.cycleSeconds;
    return x - x.floorToDouble();
  }

  void _generateUntil(double t) {
    final n = pattern.steps.length;
    while (true) {
      final et = start + _nextK * pattern.stepSeconds;
      if (et > t) break;
      final s = pattern.steps[_nextK % n];
      if (s.isHit) expected.add(Expected(_nextK, s, et, silentAt(_nextK)));
      _nextK++;
    }
  }

  /// Next stroke to play at or after [t], for the hint.
  Expected? upcoming(double t) {
    _generateUntil(t + pattern.cycleSeconds);
    for (var i = _firstOpen; i < expected.length; i++) {
      if (expected[i].t >= t - 0.03) return expected[i];
    }
    return null;
  }

  Hit? addHit(double t, double toneDb, double peakDb) {
    if (t < start - window) return null; // count-in
    final h = Hit(t, toneDb >= lowThreshold, peakDb);
    _generateUntil(t + window);
    Expected? best;
    for (var i = expected.length - 1; i >= 0; i--) {
      final e = expected[i];
      if (e.t < t - window) break;
      if ((e.t - t).abs() <= window && (best == null || (e.t - t).abs() < (best.t - t).abs())) best = e;
    }
    if (best != null && best.hit == null && !best.closed) {
      best.hit = h;
      h.target = best;
      final d = h.offsetMs.abs();
      h.grade = d <= goodMs ? Grade.good : (d <= okMs ? Grade.ok : Grade.off);
    } else {
      final k = ((t - start) / pattern.stepSeconds).round();
      (silentAt(k) ? silent : sound).extras++;
      _all.extras++;
    }
    hits.add(h);
    return h;
  }

  /// Closes strokes whose window ended before [now]; returns the new misses.
  List<Expected> advance(double now) {
    _generateUntil(now);
    final missed = <Expected>[];
    while (_firstOpen < expected.length && expected[_firstOpen].t + window < now) {
      final e = expected[_firstOpen++]..closed = true;
      (e.silent ? silent : sound).add(e);
      _all.add(e);
      if (e.hit == null) missed.add(e);
    }
    return missed;
  }
}
