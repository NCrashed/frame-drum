import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/services.dart';

/// Microphone chunk with the native capture time of its first sample (ns).
typedef MicChunk = ({int t, Float32List pcm});

/// Playback clock report: native time of frame 0 and the count of buffer underruns.
typedef ClockReport = ({int t0, int underruns});

/// Thin wrapper over the channels implemented in MainActivity/AudioEngine.
class AudioIO {
  AudioIO._();
  static final instance = AudioIO._();

  static const _methods = MethodChannel('frame_drum/audio');
  static const _events = EventChannel('frame_drum/events');

  final _mic = StreamController<MicChunk>.broadcast();
  final _clock = StreamController<ClockReport>.broadcast();
  StreamSubscription<dynamic>? _sub;

  /// Native time minus Dart stopwatch time, ns.
  int? _clockOffset;
  final _watch = Stopwatch()..start();

  Stream<MicChunk> get mic => _mic.stream;

  /// Native time at which the first frame of the current playback reaches the output.
  Stream<ClockReport> get clock => _clock.stream;

  void _listen() {
    _sub ??= _events.receiveBroadcastStream().listen((e) {
      final m = e as Map;
      switch (m['type']) {
        case 'mic':
          _mic.add((t: m['t'] as int, pcm: m['pcm'] as Float32List));
        case 'clock':
          _clock.add((t0: m['t0'] as int, underruns: m['underruns'] as int? ?? 0));
      }
    });
  }

  Future<({int sampleRate, String route})> info() async {
    final m = (await _methods.invokeMapMethod<String, dynamic>('info'))!;
    return (sampleRate: m['sampleRate'] as int, route: m['route'] as String);
  }

  /// Aligns [now] with the native clock (best of a few round trips).
  Future<void> syncClock() async {
    var best = 1 << 62;
    for (var i = 0; i < 5; i++) {
      final a = _watch.elapsedMicroseconds;
      final native = (await _methods.invokeMethod<int>('now'))!;
      final b = _watch.elapsedMicroseconds;
      if (b - a < best) {
        best = b - a;
        _clockOffset = native - (a + b) * 500;
      }
    }
  }

  /// Current time in the native clock, ns.
  int now() => _watch.elapsedMicroseconds * 1000 + (_clockOffset ?? 0);

  Future<bool> requestMic() async => await _methods.invokeMethod<bool>('requestMic') ?? false;

  Future<void> startMic() async {
    _listen();
    await _methods.invokeMethod('startMic');
  }

  Future<void> stopMic() => _methods.invokeMethod('stopMic');

  Future<void> play(Float32List intro, Float32List loop) async {
    _listen();
    await _methods.invokeMethod('play', {'intro': intro, 'loop': loop});
  }

  Future<void> stopPlay() => _methods.invokeMethod('stopPlay');

  Future<void> keepScreenOn(bool on) => _methods.invokeMethod('keepScreenOn', on);
}

/// Keeps a steady estimate of when playback started from noisy timestamp
/// reports. Small differences are averaged out so that neither the dial nor
/// the scoring jitter; a jump larger than [jumpNs] is real (the output ran
/// dry and every later click moved) and is taken as is.
class PlaybackClock {
  PlaybackClock({this.jumpNs = 15000000});

  final int jumpNs;
  int? t0;
  int underruns = 0;

  /// Number of real jumps seen.
  int jumps = 0;

  void report(ClockReport r) {
    final cur = t0;
    final grew = r.underruns > underruns;
    underruns = r.underruns;
    if (cur == null) {
      t0 = r.t0;
    } else if ((r.t0 - cur).abs() > jumpNs || grew) {
      t0 = r.t0;
      jumps++;
    } else {
      t0 = cur + ((r.t0 - cur) * 0.1).round();
    }
  }
}
