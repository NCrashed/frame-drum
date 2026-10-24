// Runs the onset detector over a session recorded with "Записывать занятия":
//   dart run tool/replay.dart session-....wav [riseDb] [minLevelDb]
// Prints each onset in song time next to what the app reported, so detector
// changes can be tried on real recordings.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:frame_drum/dsp.dart';

void main(List<String> args) {
  final wav = File(args[0]).readAsBytesSync();
  final meta = jsonDecode(File(args[0].replaceFirst(RegExp(r'\.wav$'), '.json')).readAsStringSync()) as Map;
  final sr = meta['sampleRate'] as int;
  final settings = meta['settings'] as Map<String, dynamic>;
  final pcm16 = Int16List.sublistView(wav, 44);
  final det = OnsetDetector(
    sampleRate: sr,
    riseDb: args.length > 1 ? double.parse(args[1]) : (settings['rise2'] as num).toDouble(),
    minLevelDb: args.length > 2 ? double.parse(args[2]) : (settings['min2'] as num).toDouble(),
    model: StrokeModel.fromJson(settings['model']),
  );
  final chunks = (meta['chunks'] as List).cast<List>();
  final clock = (meta['clock'] as List).cast<List>();
  if (clock.isEmpty) {
    stderr.writeln('no playback clock in the recording');
    exit(1);
  }
  final t0 = clock.last[1] as int;
  final latency = (meta['latencyMs'] as num).toDouble() / 1000;
  double song(int t) => (t - t0) / 1e9 - latency;

  final found = <Onset>[];
  for (var i = 0; i < chunks.length; i++) {
    final start = chunks[i][0] as int;
    final end = i + 1 < chunks.length ? chunks[i + 1][0] as int : pcm16.length;
    final f = Float32List(end - start);
    for (var k = 0; k < f.length; k++) {
      f[k] = pcm16[start + k] / 32768;
    }
    found.addAll(det.feed(f, chunks[i][1] as int));
  }
  final app = (meta['onsets'] as List).cast<Map>();
  stdout.writeln('replay: ${found.length} onsets, app: ${app.length}, clock jumps: ${meta['clockJumps']}');
  for (final o in found) {
    stdout.writeln(
      '${song(o.t).toStringAsFixed(3)}  ${o.toneDb >= 0 ? 'D' : 'T'} tone ${o.toneDb.toStringAsFixed(1).padLeft(6)}'
      '  peak ${o.peakDb.toStringAsFixed(1)}',
    );
  }
}
