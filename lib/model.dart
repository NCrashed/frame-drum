import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'dsp.dart';
import 'pattern.dart';
import 'scoring.dart';
import 'synth.dart';

/// Summary of a [Tally], as stored in history.
class TallySummary {
  TallySummary({
    required this.expected,
    required this.good,
    required this.ok,
    required this.off,
    required this.missed,
    required this.extras,
    required this.strokeOk,
    required this.meanMs,
    required this.sdMs,
  });

  factory TallySummary.of(Tally t) => TallySummary(
    expected: t.expected,
    good: t.good,
    ok: t.ok,
    off: t.off,
    missed: t.missed,
    extras: t.extras,
    strokeOk: t.strokeOk,
    meanMs: t.meanMs,
    sdMs: t.sdMs,
  );

  final int expected, good, ok, off, missed, extras, strokeOk;
  final double meanMs, sdMs;

  int get hits => good + ok + off;
  double get accuracy => expected == 0 ? double.nan : (good + ok) / expected;
  double get strokeRate => hits == 0 ? double.nan : strokeOk / hits;

  static double? _num(double x) => x.isFinite ? double.parse(x.toStringAsFixed(1)) : null;

  Map<String, dynamic> toJson() => {
    'n': expected,
    'g': good,
    'o': ok,
    'f': off,
    'm': missed,
    'x': extras,
    's': strokeOk,
    'mean': _num(meanMs),
    'sd': _num(sdMs),
  };

  factory TallySummary.fromJson(Map<String, dynamic> j) => TallySummary(
    expected: j['n'] as int,
    good: j['g'] as int,
    ok: j['o'] as int,
    off: j['f'] as int,
    missed: j['m'] as int,
    extras: j['x'] as int,
    strokeOk: j['s'] as int,
    meanMs: (j['mean'] as num?)?.toDouble() ?? double.nan,
    sdMs: (j['sd'] as num?)?.toDouble() ?? double.nan,
  );
}

class Session {
  Session({
    required this.patternId,
    required this.at,
    required this.bpm,
    required this.seconds,
    required this.sound,
    this.silent,
  });

  final String patternId;
  final DateTime at;
  final int bpm;
  final int seconds;
  final TallySummary sound;
  final TallySummary? silent;

  Map<String, dynamic> toJson() => {
    'p': patternId,
    't': at.millisecondsSinceEpoch,
    'bpm': bpm,
    'sec': seconds,
    'sound': sound.toJson(),
    if (silent != null) 'silent': silent!.toJson(),
  };

  factory Session.fromJson(Map<String, dynamic> j) => Session(
    patternId: j['p'] as String,
    at: DateTime.fromMillisecondsSinceEpoch(j['t'] as int),
    bpm: j['bpm'] as int,
    seconds: j['sec'] as int,
    sound: TallySummary.fromJson(j['sound'] as Map<String, dynamic>),
    silent: j['silent'] == null ? null : TallySummary.fromJson(j['silent'] as Map<String, dynamic>),
  );
}

/// Device-specific calibration and detector settings.
class Settings {
  /// Detected-minus-true time per output route ("speaker", "wired", "bluetooth"), ms.
  Map<String, double> latencyMs = {};

  /// Mic level of each of our own sounds through the speaker, dBFS; used to
  /// ignore them when practising without headphones.
  Map<Voice, double> selfLevelDb = {};

  /// Dum-versus-rim classifier trained on the player's drum.
  StrokeModel? strokeModel;

  /// Leave-one-out scores of the training strokes, for the calibration chart.
  List<double> dumScores = [], tekScores = [];

  /// Score boundary between dum and rim strokes (0 is the model's own).
  double toneThreshold = 0;

  /// Detector sensitivity: attack threshold and quietest stroke.
  double riseDb = 9;
  double minLevelDb = -55;

  /// Write the mic signal of each session to a WAV file for debugging.
  bool record = false;

  double clickVolume = 0.6;
  double guideVolume = 0.7;

  bool get toneCalibrated => strokeModel != null;

  Map<String, dynamic> toJson() => {
    'latency': latencyMs,
    'self': {for (final e in selfLevelDb.entries) e.key.name: e.value},
    'model': strokeModel?.toJson(),
    'dumScores': dumScores,
    'tekScores': tekScores,
    'tone': toneThreshold,
    // Keys changed with the band-based detector, so old values are not reused.
    'rise2': riseDb,
    'min2': minLevelDb,
    'record': record,
    'click': clickVolume,
    'guide': guideVolume,
  };

  void fromJson(Map<String, dynamic> j) {
    List<double> nums(Object? x) => (x as List? ?? []).map((v) => (v as num).toDouble()).toList();
    latencyMs = (j['latency'] as Map? ?? {}).map((k, v) => MapEntry(k as String, (v as num).toDouble()));
    selfLevelDb = {
      for (final e in (j['self'] as Map? ?? {}).entries) ?Voice.values.asNameMap()[e.key]: (e.value as num).toDouble(),
    };
    strokeModel = StrokeModel.fromJson(j['model']);
    dumScores = nums(j['dumScores']);
    tekScores = nums(j['tekScores']);
    toneThreshold = strokeModel == null ? 0 : (j['tone'] as num?)?.toDouble() ?? 0;
    riseDb = (j['rise2'] as num?)?.toDouble() ?? 9;
    minLevelDb = (j['min2'] as num?)?.toDouble() ?? -55;
    record = j['record'] as bool? ?? false;
    clickVolume = (j['click'] as num?)?.toDouble() ?? 0.6;
    guideVolume = (j['guide'] as num?)?.toDouble() ?? 0.7;
  }
}

class Store extends ChangeNotifier {
  static const _channel = MethodChannel('frame_drum/storage');

  final List<Pattern> patterns = presetPatterns();
  final List<Session> sessions = [];
  final settings = Settings();
  File? _file;
  Future<void> _pending = Future.value();

  /// Loads data from the app's private files directory (provided by
  /// MainActivity). Without it (tests, other platforms) data is in-memory only.
  Future<void> load() async {
    final dir = await _channel.invokeMethod<String>('filesDir');
    if (dir == null) return;
    final file = _file = File('$dir/frame_drum.json');
    if (!await file.exists()) return;
    _fromJson(jsonDecode(await file.readAsString()) as Map<String, dynamic>);
  }

  void _fromJson(Map<String, dynamic> j) {
    final ps = (j['patterns'] as List).map((p) => Pattern.fromJson(p as Map<String, dynamic>)).toList();
    final ss = (j['sessions'] as List).map((s) => Session.fromJson(s as Map<String, dynamic>)).toList();
    patterns
      ..clear()
      ..addAll(ps);
    sessions
      ..clear()
      ..addAll(ss);
    settings.fromJson(j['settings'] as Map<String, dynamic>? ?? {});
  }

  /// Persists and notifies; call after changing any pattern or setting in place.
  void save() {
    notifyListeners();
    final file = _file;
    if (file == null) return;
    final data = exportJson();
    // Serialize writes; write-then-rename so a crash never leaves a torn file.
    _pending = _pending
        .then((_) async {
          final tmp = File('${file.path}.tmp');
          await tmp.writeAsString(data, flush: true);
          await tmp.rename(file.path);
        })
        .catchError((Object e) => debugPrint('save failed: $e'));
  }

  Pattern addPattern() {
    final p = Pattern(
      id: DateTime.now().microsecondsSinceEpoch.toRadixString(36),
      name: 'Новый ритм',
      steps: Pattern.parseSteps('D-T-D-T-')!,
      stepsPerBeat: 2,
    );
    patterns.add(p);
    save();
    return p;
  }

  void deletePattern(Pattern p) {
    patterns.remove(p);
    sessions.removeWhere((s) => s.patternId == p.id);
    save();
  }

  void addSession(Session s) {
    sessions.add(s);
    save();
  }

  void deleteSession(Session s) {
    sessions.remove(s);
    save();
  }

  List<Session> sessionsOf(Pattern p) => sessions.where((s) => s.patternId == p.id).toList();

  String exportJson() => jsonEncode({
    'patterns': patterns.map((p) => p.toJson()).toList(),
    'sessions': sessions.map((s) => s.toJson()).toList(),
    'settings': settings.toJson(),
  });

  void importJson(String raw) {
    _fromJson(jsonDecode(raw) as Map<String, dynamic>);
    save();
  }
}
