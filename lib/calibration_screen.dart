import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import 'audio.dart';
import 'dsp.dart';
import 'model.dart';
import 'practice.dart';
import 'synth.dart';
import 'theme.dart';

enum _Mode { listen, strokes, loopback, playAlong }

/// Strokes recorded for the dum/tek model, alternating and starting with dum.
const _trainStrokes = 20;

class CalibrationScreen extends StatefulWidget {
  const CalibrationScreen({super.key, required this.store});
  final Store store;

  @override
  State<CalibrationScreen> createState() => _CalibrationScreenState();
}

class _CalibrationScreenState extends State<CalibrationScreen> with SingleTickerProviderStateMixin {
  final io = AudioIO.instance;
  Settings get s => widget.store.settings;

  int sampleRate = 48000;
  String route = 'speaker';
  String? error;
  OnsetDetector? det;
  StreamSubscription<MicChunk>? _micSub;
  StreamSubscription<ClockReport>? _clockSub;
  late final Ticker _ticker;
  final _level = ValueNotifier(-120.0);
  final _overload = ValueNotifier(0.0);
  bool unprocessed = false;

  _Mode mode = _Mode.listen;
  Onset? last;
  final _train = <Onset>[];
  String? strokeNote;

  // Latency test.
  final _clock = PlaybackClock();
  Rendered? _test;
  double _testIntro = 0;
  final _testOnsets = <Onset>[];
  Timer? _testTimer;
  String? latencyNote;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker((_) {
      _level.value = det?.levelDb ?? -120;
      _overload.value = det?.overload ?? 0;
    })..start();
    _init();
  }

  Future<void> _init() async {
    try {
      if (!await io.requestMic()) {
        setState(() => error = 'Нет доступа к микрофону');
        return;
      }
      final info = await io.info();
      sampleRate = info.sampleRate;
      route = info.route;
      unprocessed = info.unprocessed;
      _rebuildDetector();
      _micSub = io.mic.listen(_onMic);
      _clockSub = io.clock.listen(_clock.report);
      await io.startMic(source: s.micSource);
      await io.keepScreenOn(true);
      if (mounted) setState(() {});
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    }
  }

  void _rebuildDetector() =>
      det = OnsetDetector(sampleRate: sampleRate, riseDb: s.riseDb, minLevelDb: s.minLevelDb, model: s.strokeModel);

  @override
  void dispose() {
    _ticker.dispose();
    _testTimer?.cancel();
    _micSub?.cancel();
    _clockSub?.cancel();
    io.stopPlay().catchError((_) {});
    io.stopMic().catchError((_) {});
    io.keepScreenOn(false).catchError((_) {});
    super.dispose();
  }

  void _onMic(MicChunk c) {
    final d = det;
    if (d == null) return;
    for (final o in d.feed(c.pcm, c.t)) {
      switch (mode) {
        case _Mode.listen:
          break;
        case _Mode.strokes:
          _train.add(o);
          if (_train.length >= _trainStrokes) _fitStrokes();
        case _Mode.loopback || _Mode.playAlong:
          _testOnsets.add(o);
      }
      setState(() => last = o);
    }
  }

  /// Restarts capture from another Android source; the stroke model was
  /// trained on the old one's sound, so it may need recording again.
  Future<void> _setSource(String id) async {
    if (id == s.micSource) return;
    setState(() => s.micSource = id);
    widget.store.save();
    await io.stopMic();
    _rebuildDetector();
    await io.startMic(source: id);
    if (s.toneCalibrated) setState(() => strokeNote = 'Источник сменился: запишите дум и тек заново.');
  }

  void _startStrokes() => setState(() {
    mode = _Mode.strokes;
    strokeNote = null;
    _train.clear();
  });

  void _fitStrokes() {
    mode = _Mode.listen;
    final dums = [for (var i = 0; i < _train.length; i += 2) _train[i].features];
    final teks = [for (var i = 1; i < _train.length; i += 2) _train[i].features];
    final (sd, st) = StrokeModel.crossValidate(dums, teks);
    final right = sd.where((x) => x >= 0).length + st.where((x) => x < 0).length;
    s
      ..strokeModel = StrokeModel.fit(dums, teks)
      ..dumScores = sd
      ..tekScores = st
      ..toneThreshold = 0;
    final share = right / (sd.length + st.length);
    strokeNote = share >= 0.9
        ? 'Узнаёт ${pct(share)} ударов. Сыграйте ещё немного и посмотрите на подписи ниже.'
        : 'Узнаёт только ${pct(share)}. Попробуйте заново: строго по очереди, начиная с дума, '
              'без лишних касаний. Если не помогает, играйте дум ближе к центру.';
    _rebuildDetector();
    widget.store.save();
  }

  Future<void> _startLatency() async {
    final synth = Synth(sampleRate, clickVolume: s.clickVolume, guideVolume: s.guideVolume);
    final speaker = route == 'speaker';
    Rendered test;
    if (speaker) {
      test = synth.calibration();
      _testIntro = 0;
    } else {
      // Headphones: the mic can't hear the clicks, so the player plays along.
      const bpm = 80, beat = 60 / bpm;
      _testIntro = 4 * beat;
      test = synth.mix(beat * 22, [
        for (var b = 0; b < 20; b++) (t: b * beat, voice: b % 4 == 0 ? Voice.accent : Voice.click),
      ]);
    }
    setState(() {
      mode = speaker ? _Mode.loopback : _Mode.playAlong;
      latencyNote = null;
      _test = test;
      _testOnsets.clear();
      _clock
        ..t0 = null
        ..underruns = 0
        ..jumps = 0;
    });
    await io.play(test.pcm, silence(sampleRate));
    _testTimer = Timer(Duration(milliseconds: (test.seconds(sampleRate) * 1000).round() + 600), _finishLatency);
  }

  void _finishLatency() {
    io.stopPlay();
    final test = _test!, t0 = _clock.t0;
    final wasLoopback = mode == _Mode.loopback;
    mode = _Mode.listen;
    if (t0 == null) {
      setState(() => latencyNote = 'Не удалось получить время воспроизведения, попробуйте ещё раз');
      return;
    }
    if (_clock.jumps > 0) {
      setState(
        () => latencyNote =
            'Звук прерывался во время измерения (${_clock.jumps} раз), результат не сохранён. Попробуйте ещё раз.',
      );
      return;
    }
    final times = [for (final o in _testOnsets) (o.t - t0) / 1e9];
    if (wasLoopback) {
      final clicks = <double>[];
      final levels = <Voice, double>{};
      for (final e in test.events) {
        // First onset from slightly before to well after the scheduled time.
        final i = times.indexWhere((t) => t - e.t >= -0.03 && t - e.t <= 0.3);
        if (i < 0) continue;
        if (e.voice == Voice.click) clicks.add((times[i] - e.t) * 1000);
        final peak = _testOnsets[i].peakDb;
        levels[e.voice] = levels[e.voice] == null ? peak : (peak > levels[e.voice]! ? peak : levels[e.voice]!);
      }
      if (clicks.length < 6) {
        setState(
          () => latencyNote =
              'Микрофон услышал ${clicks.length} щелчков из 10. Прибавьте громкость или снизьте порог атаки.',
        );
        return;
      }
      s.latencyMs[route] = median(clicks);
      s.selfLevelDb = levels;
      latencyNote = 'Услышано ${clicks.length} из 10, разброс ${ms(stdDev(clicks))}';
    } else {
      const beat = 60 / 80;
      final d = <double>[];
      for (final t in times) {
        final k = ((t - _testIntro) / beat).round();
        if (k < 0 || k >= 16) continue;
        final off = t - (_testIntro + k * beat);
        if (off.abs() < 0.3) d.add(off * 1000);
      }
      if (d.length < 10) {
        setState(() => latencyNote = 'Засчитано ${d.length} ударов из 16, нужно хотя бы 10');
        return;
      }
      s.latencyMs[route] = median(d);
      latencyNote = 'Засчитано ${d.length} ударов, разброс ${ms(stdDev(d))}';
    }
    widget.store.save();
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final busy = mode != _Mode.listen;
    final testing = mode == _Mode.loopback || mode == _Mode.playAlong;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Калибровка', style: TextStyle(fontWeight: FontWeight.w600)),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (error != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(error!, style: const TextStyle(color: Palette.bad)),
            ),
          _Section(
            title: '1. Микрофон',
            body:
                'Большой бубен очень громкий, и микрофон телефона легко перегружается: тогда один дум '
                'даёт несколько отметок, а следующие удары теряются. Положите телефон в 2–3 м от бубна, '
                'ударьте дум в полную силу и следите, чтобы не появлялась надпись о перегрузке. Если она '
                'есть, отодвиньте телефон, положите его микрофоном от бубна или попробуйте другой источник.',
            children: [
              ValueListenableBuilder(
                valueListenable: _level,
                builder: (_, v, _) => _Meter(levelDb: v, floorDb: s.minLevelDb),
              ),
              ValueListenableBuilder(
                valueListenable: _overload,
                builder: (_, v, _) => Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    v > OnsetDetector.overloadWarning
                        ? 'Перегрузка: ${pct(v)} времени сигнал упирается в потолок'
                        : 'Перегрузки нет',
                    style: TextStyle(color: v > OnsetDetector.overloadWarning ? Palette.bad : Palette.good),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  const Text('Источник', style: TextStyle(color: Palette.muted)),
                  for (final (id, label) in [
                    ('auto', 'авто'),
                    if (unprocessed) ('unprocessed', 'без обработки'),
                    ('voice', 'распознавание'),
                    ('camcorder', 'видеокамера'),
                    ('mic', 'обычный'),
                  ])
                    ChoiceChip(
                      label: Text(label),
                      selected: s.micSource == id,
                      onSelected: busy ? null : (_) => _setSource(id),
                    ),
                ],
              ),
              const SizedBox(height: 4),
              _SliderRow(
                label: 'Порог атаки',
                value: s.riseDb,
                min: 4,
                max: 20,
                text: '${s.riseDb.round()} дБ',
                onChanged: (v) => setState(() {
                  s.riseDb = v.roundToDouble();
                  _rebuildDetector();
                }),
                onChangeEnd: widget.store.save,
              ),
              _SliderRow(
                label: 'Тише не слушать',
                value: s.minLevelDb,
                min: -75,
                max: -25,
                text: '${s.minLevelDb.round()} дБ',
                onChanged: (v) => setState(() {
                  s.minLevelDb = v.roundToDouble();
                  _rebuildDetector();
                }),
                onChangeEnd: widget.store.save,
              ),
              _LastHit(onset: last, threshold: s.toneThreshold, calibrated: s.toneCalibrated),
            ],
          ),
          const SizedBox(height: 12),
          _Section(
            title: '2. Дум и тек',
            body:
                'Сыграйте $_trainStrokes ударов строго по очереди: дум, тек, дум, тек… начиная с дума, в '
                'спокойном темпе, как обычно играете. Приложение научится различать их именно на вашем '
                'бубне, в том числе когда тек звучит поверх звона дума.',
            children: [
              _ToneChart(dum: s.dumScores, tek: s.tekScores, threshold: s.toneThreshold),
              const SizedBox(height: 4),
              const Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('← тек', style: TextStyle(color: Palette.rim, fontSize: 12)),
                  Text('дум →', style: TextStyle(color: Palette.brass, fontSize: 12)),
                ],
              ),
              if (strokeNote != null)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(strokeNote!, style: const TextStyle(color: Palette.muted)),
                ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: busy || det == null ? null : _startStrokes,
                icon: Icon(mode == _Mode.strokes ? Icons.mic : Icons.fiber_manual_record_outlined),
                label: Text(
                  mode == _Mode.strokes
                      ? 'Сейчас ${_train.length.isEven ? 'дум' : 'тек'}: ${_train.length} из $_trainStrokes'
                      : (s.toneCalibrated ? 'Записать заново' : 'Записать'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          _Section(
            title: '3. Задержка',
            body: route == 'speaker'
                ? 'Телефон сыграет щелчки и звуки бубна и услышит их сам. Не играйте и не шумите '
                      'около 10 секунд. Громкость поставьте такую же, как на занятиях.'
                : 'Подключены наушники (${route == 'bluetooth' ? 'Bluetooth' : 'проводные'}): микрофон не слышит '
                      'щелчки, поэтому после 4 щелчков вступления сыграйте дум точно на каждый из 16 щелчков. '
                      'Ваша собственная привычка спешить или тянуть тоже войдёт в поправку.',
            children: [
              Text(
                'Поправка (${_routeName(route)}): ${ms(s.latencyMs[route] ?? double.nan, sign: true)}',
                style: const TextStyle(fontSize: 16, fontFeatures: tabular),
              ),
              if (latencyNote != null)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(latencyNote!, style: const TextStyle(color: Palette.muted)),
                ),
              Slider(
                min: -150,
                max: 250,
                value: (s.latencyMs[route] ?? 0).clamp(-150, 250),
                onChanged: busy ? null : (v) => setState(() => s.latencyMs[route] = v.roundToDouble()),
                onChangeEnd: (_) => widget.store.save(),
              ),
              FilledButton.icon(
                onPressed: busy || det == null ? null : _startLatency,
                icon: Icon(testing ? Icons.hourglass_top : Icons.timer_outlined),
                label: Text(testing ? 'Идёт измерение…' : 'Измерить'),
              ),
            ],
          ),
          const SizedBox(height: 12),
          _Section(
            title: 'Отладка',
            body:
                'Сохранять звук с микрофона каждого занятия в WAV вместе с тем, что распознало приложение. '
                'Файлы лежат в Android/data/dev.ncrashed.frame_drum/files, их можно забрать через adb pull.',
            children: [
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Записывать занятия'),
                value: s.record,
                onChanged: (v) {
                  s.record = v;
                  widget.store.save();
                },
              ),
            ],
          ),
        ],
      ),
    );
  }
}

String _routeName(String r) => switch (r) {
  'wired' => 'проводные наушники',
  'bluetooth' => 'Bluetooth',
  _ => 'динамик',
};

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.body, required this.children});
  final String title, body;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(title, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 6),
          Text(body, style: const TextStyle(color: Palette.muted)),
          const SizedBox(height: 12),
          ...children,
        ],
      ),
    ),
  );
}

class _SliderRow extends StatelessWidget {
  const _SliderRow({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.text,
    required this.onChanged,
    required this.onChangeEnd,
  });
  final String label, text;
  final double value, min, max;
  final ValueChanged<double> onChanged;
  final VoidCallback onChangeEnd;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      SizedBox(
        width: 120,
        child: Text(label, style: const TextStyle(color: Palette.muted)),
      ),
      Expanded(
        child: Slider(
          min: min,
          max: max,
          value: value.clamp(min, max),
          onChanged: onChanged,
          onChangeEnd: (_) => onChangeEnd(),
        ),
      ),
      SizedBox(
        width: 56,
        child: Text(
          text,
          textAlign: TextAlign.right,
          style: const TextStyle(fontFeatures: tabular),
        ),
      ),
    ],
  );
}

class _Meter extends StatelessWidget {
  const _Meter({required this.levelDb, required this.floorDb});
  final double levelDb, floorDb;

  @override
  Widget build(BuildContext context) {
    double f(double db) => ((db + 80) / 80).clamp(0, 1);
    return LayoutBuilder(
      builder: (context, box) => Stack(
        children: [
          Container(
            height: 14,
            decoration: BoxDecoration(color: Palette.surfaceHigh, borderRadius: BorderRadius.circular(7)),
          ),
          Container(
            height: 14,
            width: box.maxWidth * f(levelDb),
            decoration: BoxDecoration(
              color: levelDb >= floorDb ? Palette.good : Palette.muted,
              borderRadius: BorderRadius.circular(7),
            ),
          ),
          Positioned(
            left: box.maxWidth * f(floorDb) - 1,
            child: Container(width: 2, height: 14, color: Palette.text),
          ),
        ],
      ),
    );
  }
}

class _LastHit extends StatelessWidget {
  const _LastHit({required this.onset, required this.threshold, required this.calibrated});
  final Onset? onset;
  final double threshold;
  final bool calibrated;

  @override
  Widget build(BuildContext context) {
    final o = onset;
    if (o == null) return const Text('Ударов пока не было', style: TextStyle(color: Palette.muted));
    final low = o.isLow(threshold);
    return Text.rich(
      TextSpan(
        children: [
          const TextSpan(
            text: 'Последний удар: ',
            style: TextStyle(color: Palette.muted),
          ),
          TextSpan(
            text: low ? 'дум ' : 'тек ',
            style: TextStyle(color: low ? Palette.brass : Palette.rim, fontWeight: FontWeight.w600),
          ),
          TextSpan(
            text:
                '(${o.peakDb.round()} дБ${calibrated ? ', уверенность ${o.toneDb.abs().round()}' : ', без калибровки'})',
            style: const TextStyle(color: Palette.muted, fontFeatures: tabular),
          ),
        ],
      ),
    );
  }
}

/// Leave-one-out scores of the training strokes on one axis, with the boundary.
class _ToneChart extends StatelessWidget {
  const _ToneChart({required this.dum, required this.tek, required this.threshold});
  final List<double> dum, tek;
  final double threshold;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 44,
    child: CustomPaint(size: Size.infinite, painter: _TonePainter(dum, tek, threshold)),
  );
}

class _TonePainter extends CustomPainter {
  _TonePainter(this.dum, this.tek, this.threshold);
  final List<double> dum, tek;
  final double threshold;

  @override
  void paint(Canvas canvas, Size size) {
    const lo = -30.0, hi = 30.0;
    double x(double v) => 6 + (v.clamp(lo, hi) - lo) / (hi - lo) * (size.width - 12);
    final mid = size.height / 2;
    canvas.drawLine(Offset(0, mid), Offset(size.width, mid), Paint()..color = Palette.line);
    if (dum.isNotEmpty || tek.isNotEmpty) {
      canvas.drawLine(
        Offset(x(threshold), 2),
        Offset(x(threshold), size.height - 2),
        Paint()
          ..color = Palette.text
          ..strokeWidth = 2,
      );
    }
    for (final v in tek) {
      canvas.drawCircle(Offset(x(v), mid - 8), 5, Paint()..color = Palette.rim.withValues(alpha: 0.8));
    }
    for (final v in dum) {
      canvas.drawCircle(Offset(x(v), mid + 8), 5, Paint()..color = Palette.brass.withValues(alpha: 0.8));
    }
  }

  @override
  bool shouldRepaint(_TonePainter old) => true;
}
