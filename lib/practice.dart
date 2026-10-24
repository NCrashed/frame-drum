import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'audio.dart';
import 'dsp.dart';
import 'gate.dart';
import 'model.dart';
import 'pattern.dart';
import 'recorder.dart';
import 'scoring.dart';
import 'synth.dart';

enum PracticeState { idle, starting, running }

class Practice extends ChangeNotifier {
  Practice(this.store, this.pattern, {AudioIO? io}) : io = io ?? AudioIO.instance;

  final Store store;
  final Pattern pattern;
  final AudioIO io;

  PracticeState state = PracticeState.idle;
  String? error;
  String route = 'speaker';

  Scorer? scorer;
  OnsetDetector? _detector;
  SessionRecorder? _recorder;
  double _latency = 0;
  final clock = PlaybackClock();
  final _mic = MicClock();
  DateTime? _startedAt;
  double introSeconds = 0;
  int countInBeats = 4;
  Hit? lastHit;

  /// Where the last debug recording was saved.
  String? recordedTo;
  final _subs = <StreamSubscription<dynamic>>[];

  bool get running => state == PracticeState.running;
  double get levelDb => _detector?.levelDb ?? -120;

  /// Share of recent time the mic clipped, see [OnsetDetector.overload].
  double get overload => _detector?.overload ?? 0;

  /// Song time (seconds since count-in start) of what is heard right now.
  double? get now => clock.t0 == null ? null : (io.now() - clock.t0!) / 1e9;

  /// Song time of a native timestamp, corrected for latency.
  double _song(int t) => (t - clock.t0!) / 1e9 - _latency;

  Future<void> start() async {
    if (state != PracticeState.idle) return;
    state = PracticeState.starting;
    error = null;
    recordedTo = null;
    notifyListeners();
    try {
      if (!await io.requestMic()) {
        throw 'Нет доступа к микрофону';
      }
      final info = await io.info();
      route = info.route;
      final s = store.settings;
      _latency = (s.latencyMs[route] ?? 0) / 1000;
      final synth = Synth(info.sampleRate, clickVolume: s.clickVolume, guideVolume: s.guideVolume);
      countInBeats = pattern.beats < 3 ? pattern.beats * 2 : pattern.beats;
      final intro = synth.countIn(pattern, countInBeats);
      final loop = synth.loop(pattern);
      introSeconds = intro.seconds(info.sampleRate);
      // With headphones the mic can't hear us, so nothing to filter.
      final gate = route == 'speaker'
          ? SelfSoundGate(
              intro: intro.events,
              loop: loop.events,
              introSeconds: introSeconds,
              loopSeconds: loop.seconds(info.sampleRate),
              levels: s.selfLevelDb,
            )
          : null;
      final sc = scorer = Scorer(pattern, start: introSeconds, lowThreshold: s.toneThreshold);
      _detector = OnsetDetector(
        sampleRate: info.sampleRate,
        riseDb: s.riseDb,
        minLevelDb: s.minLevelDb,
        // A second stroke can't come sooner than most of the shortest gap.
        minGapMs: (sc.window * 800).clamp(35, 120),
        model: s.strokeModel,
        notchHz: clickNotchHz,
      );
      if (gate != null) {
        _detector!
          ..provisional = ((t, peak) => clock.t0 != null && gate.nearOwnSound(_song(t), peak))
          ..ignore = ((o) => clock.t0 != null && gate.isSelf(_song(o.t), o));
      }
      _mic.reset();
      lastHit = null;
      clock
        ..t0 = null
        ..underruns = 0
        ..jumps = 0;
      _recorder = s.record
          ? await SessionRecorder.open(_stamp(), info.sampleRate, {
              'pattern': pattern.toJson(),
              'route': route,
              'micSource': s.micSource,
              'latencyMs': _latency * 1000,
              'introSeconds': introSeconds,
              'settings': s.toJson(),
            })
          : null;
      await io.syncClock();
      _subs
        ..add(
          io.clock.listen((r) {
            _recorder?.addClock(io.now(), r);
            final jumps = clock.jumps;
            clock.report(r);
            if (clock.jumps != jumps) notifyListeners();
          }),
        )
        ..add(io.mic.listen(_onMic));
      await io.startMic(source: s.micSource);
      await io.play(intro.pcm, loop.pcm);
      await io.keepScreenOn(true);
      _startedAt = DateTime.now();
      state = PracticeState.running;
    } catch (e) {
      error = e is PlatformException ? (e.message ?? e.code) : '$e';
      await _teardown();
      state = PracticeState.idle;
    }
    notifyListeners();
  }

  static String _stamp() {
    final d = DateTime.now();
    String two(int x) => x.toString().padLeft(2, '0');
    return 'session-${d.year}${two(d.month)}${two(d.day)}-${two(d.hour)}${two(d.minute)}${two(d.second)}';
  }

  void _onMic(MicChunk c) {
    final det = _detector, sc = scorer;
    if (det == null || sc == null) return;
    _recorder?.addChunk(c);
    final t = _mic.chunk(c.t, c.pcm.length, det.sampleRate);
    final onsets = det.feed(c.pcm, t);
    if (clock.t0 == null) return;
    var changed = false;
    for (final o in onsets) {
      final t = _song(o.t);
      final h = sc.addHit(t, o.toneDb, o.peakDb);
      _recorder?.addOnset({
        't': o.t,
        'song': t,
        'peak': o.peakDb,
        'tone': o.toneDb,
        'features': o.features,
        'grade': h?.grade.name,
        'offsetMs': h == null || h.target == null ? null : h.offsetMs,
      });
      if (h != null) {
        lastHit = h;
        changed = true;
      }
    }
    // Onsets are reported after their measurement window, so lag behind a bit
    // before declaring a stroke missed.
    final end = _song(t + c.pcm.length * 1000000000 ~/ det.sampleRate);
    if (sc.advance(end - 0.16).isNotEmpty) changed = true;
    if (changed) notifyListeners();
  }

  /// Stops and stores the session; returns it if it was long enough to keep.
  Future<Session?> stop() async {
    if (state != PracticeState.running) return null;
    await _teardown();
    state = PracticeState.idle;
    final sc = scorer!;
    final started = _startedAt ?? DateTime.now();
    Session? session;
    if (sc.all.expected >= 8) {
      session = Session(
        patternId: pattern.id,
        at: started,
        bpm: pattern.bpm,
        seconds: DateTime.now().difference(started).inSeconds,
        sound: TallySummary.of(sc.sound),
        silent: pattern.silentCycles > 0 ? TallySummary.of(sc.silent) : null,
      );
      store.addSession(session);
    }
    final rec = _recorder;
    _recorder = null;
    if (rec != null) {
      await rec.close({'underruns': clock.underruns, 'clockJumps': clock.jumps});
      recordedTo = rec.wav.path;
    }
    notifyListeners();
    return session;
  }

  Future<void> _teardown() async {
    for (final s in _subs) {
      await s.cancel();
    }
    _subs.clear();
    try {
      await io.stopPlay();
      await io.stopMic();
      await io.keepScreenOn(false);
    } catch (_) {}
  }

  @override
  void dispose() {
    if (state != PracticeState.idle) _teardown();
    super.dispose();
  }
}

/// Silence used as the loop when only a one-shot buffer should play.
Float32List silence(int sampleRate) => Float32List(sampleRate ~/ 10);
