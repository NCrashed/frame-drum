import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/services.dart';

/// Microphone chunk with the native capture time of its first sample (ns).
typedef MicChunk = ({int t, Float32List pcm});

/// Thin wrapper over the channels implemented in MainActivity/AudioEngine.
class AudioIO {
  AudioIO._();
  static final instance = AudioIO._();

  static const _methods = MethodChannel('frame_drum/audio');
  static const _events = EventChannel('frame_drum/events');

  final _mic = StreamController<MicChunk>.broadcast();
  final _clock = StreamController<int>.broadcast();
  StreamSubscription<dynamic>? _sub;

  /// Native time minus Dart stopwatch time, ns.
  int? _clockOffset;
  final _watch = Stopwatch()..start();

  Stream<MicChunk> get mic => _mic.stream;

  /// Native time at which the first frame of the current playback reaches the output.
  Stream<int> get clock => _clock.stream;

  void _listen() {
    _sub ??= _events.receiveBroadcastStream().listen((e) {
      final m = e as Map;
      switch (m['type']) {
        case 'mic':
          _mic.add((t: m['t'] as int, pcm: m['pcm'] as Float32List));
        case 'clock':
          _clock.add(m['t0'] as int);
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
