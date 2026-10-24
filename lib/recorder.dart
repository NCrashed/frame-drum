import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';

import 'audio.dart';

/// Writes the raw mic signal of a session to `<name>.wav` plus `<name>.json`
/// with everything needed to replay detection and scoring offline: chunk
/// timestamps, playback clock reports and what the app detected.
class SessionRecorder {
  SessionRecorder._(this.wav, this._file, this.sampleRate, this.meta);

  static const _storage = MethodChannel('frame_drum/storage');

  final File wav;
  final RandomAccessFile _file;
  final int sampleRate;
  final Map<String, Object?> meta;

  final _buf = BytesBuilder(copy: false);
  var _samples = 0;
  final _chunks = <List<int>>[]; // [sample index, native time]
  final _clock = <List<int>>[]; // [native time received, t0, underruns]
  final _onsets = <Map<String, Object?>>[];

  /// Opens a new recording in the app's external files directory.
  static Future<SessionRecorder?> open(String name, int sampleRate, Map<String, Object?> meta) async {
    final dir = await _storage.invokeMethod<String>('externalDir');
    if (dir == null) return null;
    final wav = File('$dir/$name.wav');
    final f = await wav.open(mode: FileMode.write);
    await f.writeFrom(Uint8List(44)); // header written on close
    return SessionRecorder._(wav, f, sampleRate, meta);
  }

  void addChunk(MicChunk c) {
    _chunks.add([_samples, c.t]);
    final pcm = Int16List(c.pcm.length);
    for (var i = 0; i < pcm.length; i++) {
      pcm[i] = (c.pcm[i].clamp(-1.0, 1.0) * 32767).round();
    }
    _buf.add(pcm.buffer.asUint8List());
    _samples += pcm.length;
    if (_buf.length > sampleRate) _file.writeFromSync(_buf.takeBytes());
  }

  void addClock(int now, ClockReport r) => _clock.add([now, r.t0, r.underruns]);

  void addOnset(Map<String, Object?> o) => _onsets.add(o);

  Future<void> close(Map<String, Object?> summary) async {
    _file.writeFromSync(_buf.takeBytes());
    final dataBytes = _samples * 2;
    final h = ByteData(44)
      ..setUint32(0, 0x52494646) // RIFF
      ..setUint32(4, 36 + dataBytes, Endian.little)
      ..setUint32(8, 0x57415645) // WAVE
      ..setUint32(12, 0x666d7420) // fmt
      ..setUint32(16, 16, Endian.little)
      ..setUint16(20, 1, Endian.little) // PCM
      ..setUint16(22, 1, Endian.little) // mono
      ..setUint32(24, sampleRate, Endian.little)
      ..setUint32(28, sampleRate * 2, Endian.little)
      ..setUint16(32, 2, Endian.little)
      ..setUint16(34, 16, Endian.little)
      ..setUint32(36, 0x64617461) // data
      ..setUint32(40, dataBytes, Endian.little);
    _file.setPositionSync(0);
    _file.writeFromSync(h.buffer.asUint8List());
    await _file.close();
    final json = File(wav.path.replaceFirst(RegExp(r'\.wav$'), '.json'));
    await json.writeAsString(
      const JsonEncoder.withIndent(
        ' ',
      ).convert({...meta, ...summary, 'sampleRate': sampleRate, 'chunks': _chunks, 'clock': _clock, 'onsets': _onsets}),
    );
  }
}
