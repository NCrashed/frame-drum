// Scores the detector on sessions recorded with "Записывать занятия".
//
//   dart run tool/eval.dart [--notch] [--train N] rec1.wav rec2.wav ...
//
// Ground truth comes from the pattern grid: a detected stroke takes the type
// of the nearest pattern step (within 40% of a step); strokes near rests or
// far from the grid count as extras. With --train N, a fresh dum/tek model is
// fitted on the first N labelled strokes of the first recording and used
// for everything after them; otherwise the model stored in the recording is
// used.
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:frame_drum/dsp.dart';
import 'package:frame_drum/gate.dart';
import 'package:frame_drum/pattern.dart';
import 'package:frame_drum/synth.dart';

class Rec {
  Rec(this.name, this.pcm, this.meta);
  final String name;
  final Float32List pcm;
  final Map<String, dynamic> meta;

  int get sr => meta['sampleRate'] as int;
  Pattern get pattern => Pattern.fromJson(meta['pattern'] as Map<String, dynamic>);
  Map<String, dynamic> get settings => meta['settings'] as Map<String, dynamic>;

  static Rec load(String path) {
    final bytes = File(path).readAsBytesSync();
    final s16 = Int16List.sublistView(bytes, 44);
    final pcm = Float32List(s16.length);
    for (var i = 0; i < pcm.length; i++) {
      pcm[i] = s16[i] / 32768;
    }
    final meta = jsonDecode(File(path.replaceFirst(RegExp(r'\.wav$'), '.json')).readAsStringSync());
    return Rec(path.split('/').last, pcm, meta as Map<String, dynamic>);
  }

  /// Native time of sample 0 from a least-squares fit of chunk timestamps
  /// against the sample counter (removes the per-chunk jitter).
  int get firstSampleNs {
    final c = (meta['chunks'] as List).cast<List>();
    var sum = 0.0;
    for (final x in c) {
      sum += (x[1] as int) - (x[0] as int) * 1e9 / sr;
    }
    return (sum / c.length).round();
  }
}

typedef Labelled = ({Onset onset, double song, Stroke? truth, double offsetMs});

bool noGate = false;

/// Recordings made before the click moved to 7/8.5 kHz.
bool oldClick = false;

List<Labelled> run(Rec r, {required bool notch, StrokeModel? model}) {
  final s = r.settings;
  final p = r.pattern;
  final t0 = (r.meta['clock'] as List).last[1] as int;
  final latency = (r.meta['latencyMs'] as num) / 1000;
  final intro = (r.meta['introSeconds'] as num).toDouble();
  double song(int t) => (t - t0) / 1e9 - latency;

  final synth = Synth(r.sr);
  final introR = synth.countIn(p), loopR = synth.loop(p);
  final levels = {
    for (final e in (s['self'] as Map? ?? {}).entries) ?Voice.values.asNameMap()[e.key]: (e.value as num).toDouble(),
  };
  final gate = r.meta['route'] == 'speaker'
      ? SelfSoundGate(
          intro: introR.events,
          loop: loopR.events,
          introSeconds: introR.seconds(r.sr),
          loopSeconds: loopR.seconds(r.sr),
          levels: levels,
        )
      : null;
  final step = p.stepSeconds;
  final det = OnsetDetector(
    sampleRate: r.sr,
    riseDb: (s['rise2'] as num).toDouble(),
    minLevelDb: (s['min2'] as num).toDouble(),
    minGapMs: (step * 0.4 * 1000).clamp(35, 120),
    model: model ?? StrokeModel.fromJson(s['model']),
    notchHz: oldClick ? (notch ? clickNotches : const []) : clickNotchHz,
  );
  if (gate != null && !noGate) {
    det
      ..provisional = ((t, peak) => gate.nearOwnSound(song(t), peak))
      ..ignore = ((o) => gate.isSelf(song(o.t), o));
  }

  final start = r.firstSampleNs;
  final out = <Labelled>[];
  const chunk = 480;
  for (var i = 0; i + chunk <= r.pcm.length; i += chunk) {
    for (final o in det.feed(Float32List.sublistView(r.pcm, i, i + chunk), start + (i * 1e9 / r.sr).round())) {
      final t = song(o.t);
      if (t < intro - step / 2) continue;
      final k = ((t - intro) / step).round();
      final off = (t - (intro + k * step)) * 1000;
      final st = p.steps[k % p.steps.length];
      final truth = st.isHit && off.abs() < math.min(step * 300, 150) ? st : null;
      out.add((onset: o, song: t, truth: truth, offsetMs: off));
    }
  }
  return out;
}

/// The click of the version these recordings were made with (1.8/2.6 kHz,
/// now 7/8.5 kHz) and its harmonics, for --notch.
const clickNotches = [1800.0, 3600.0, 2600.0, 5200.0];

void report(String title, List<Labelled> xs, Rec r) {
  final p = r.pattern;
  final intro = (r.meta['introSeconds'] as num).toDouble();
  final last = xs.isEmpty ? intro : xs.last.song;
  final first = xs.isEmpty ? intro : xs.first.song - p.stepSeconds / 2;
  var expected = 0;
  for (var k = 0; intro + k * p.stepSeconds <= last; k++) {
    if (intro + k * p.stepSeconds < first) continue;
    if (p.steps[k % p.steps.length].isHit) expected++;
  }
  final lab = xs.where((x) => x.truth != null).toList();
  final extras = xs.length - lab.length;
  final ok = lab.where((x) => x.onset.isLow(0) == x.truth!.isLow).length;
  final dums = lab.where((x) => x.truth!.isLow).toList(), teks = lab.where((x) => !x.truth!.isLow).toList();
  final dOk = dums.where((x) => x.onset.isLow(0)).length, tOk = teks.where((x) => !x.onset.isLow(0)).length;
  final offs = lab.map((x) => x.offsetMs).toList();
  stdout.writeln(
    '$title: found ${lab.length}/$expected strokes, extra $extras; stroke type ${pct(ok, lab.length)} '
    '(dum ${pct(dOk, dums.length)}, tek ${pct(tOk, teks.length)}); offset mean ${mean(offs).toStringAsFixed(0)} '
    'sd ${stdDev(offs).toStringAsFixed(0)} ms',
  );
}

String pct(int a, int b) => b == 0 ? '-' : '${(100 * a / b).round()}% of $b';

void main(List<String> args) {
  final notch = args.contains('--notch');
  noGate = args.contains('--no-gate');
  oldClick = args.contains('--old-click');
  if (args.contains('--all-bands')) OnsetDetector.featureSkip = const {};
  final ti = args.indexOf('--train');
  final trainN = ti >= 0 ? int.parse(args[ti + 1]) : 0;
  final files = [
    for (var i = 0; i < args.length; i++)
      if (args[i].endsWith('.wav')) args[i],
  ];
  final recs = files.map(Rec.load).toList();
  StrokeModel? model;
  var skip = 0;
  if (trainN > 0) {
    final first = run(recs.first, notch: notch).where((x) => x.truth != null).take(trainN).toList();
    final d = [
      for (final x in first)
        if (x.truth!.isLow) x.onset.features,
    ];
    final t = [
      for (final x in first)
        if (!x.truth!.isLow) x.onset.features,
    ];
    model = StrokeModel.fit(d, t);
    skip = first.isEmpty ? 0 : math.max(0, first.length);
    stdout.writeln('trained on ${d.length} dum + ${t.length} tek from ${recs.first.name}');
  }
  if (args.contains('--online')) {
    // As the app learns: each session is scored with the model built from
    // the earlier ones (the first with its stored calibration model), then
    // its on-time strokes join the training set, at most 200 per class.
    final samples = <Stroke, List<List<double>>>{};
    StrokeModel? m;
    for (final r in recs) {
      final xs = run(r, notch: notch, model: m);
      report('${r.name} (learned from ${samples.values.fold(0, (a, l) => a + l.length)})', xs, r);
      final onTime = xs.where((x) => x.truth != null && x.offsetMs.abs() <= 40).toList();
      final agree = onTime.where((x) => x.onset.isLow(0) == x.truth!.isLow).length / math.max(1, onTime.length);
      if (agree < 0.6) {
        stdout.writeln('  skipped for learning: labels agree with the model on ${(agree * 100).round()}%');
        continue;
      }
      for (final x in onTime) {
        final l = samples.putIfAbsent(x.truth!, () => [])..add(x.onset.features);
        if (l.length > 200) l.removeAt(0);
      }
      final d = samples[Stroke.dum] ?? [], t = samples[Stroke.tek] ?? [], k = samples[Stroke.ka] ?? [];
      if (d.length >= 3 && t.length + k.length >= 3) {
        m = t.length < 3 ? StrokeModel.fit(d, k) : StrokeModel.fit(d, t, k);
      }
    }
    return;
  }
  if (args.contains('--cross')) {
    // Leave one session out: train on the strokes of all the others, which
    // only needs features, so detect once and refit per held-out session.
    final all = [for (final r in recs) run(r, notch: notch)];
    for (final (i, r) in recs.indexed) {
      final train = [
        for (final (j, xs) in all.indexed)
          if (j != i) ...xs.where((x) => x.truth != null && x.offsetMs.abs() < 60),
      ];
      final m = StrokeModel.fit(
        [
          for (final x in train)
            if (x.truth!.isLow) x.onset.features,
        ],
        [
          for (final x in train)
            if (!x.truth!.isLow) x.onset.features,
        ],
      );
      for (final x in all[i]) {
        x.onset.toneDb = m.score(x.onset.features);
      }
      report('${r.name} (trained on ${train.length} from other sessions)', all[i], r);
    }
    return;
  }
  for (final (i, r) in recs.indexed) {
    var xs = run(r, notch: notch, model: model);
    if (i == 0 && skip > 0) {
      final lab = xs.where((x) => x.truth != null).toList();
      final cut = lab.length > skip ? lab[skip].song : double.infinity;
      xs = xs.where((x) => x.song >= cut).toList();
    }
    report('${r.name}${notch ? ' +notch' : ''}', xs, r);
  }
}
