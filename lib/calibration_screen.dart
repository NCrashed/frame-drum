import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import 'audio.dart';
import 'dsp.dart';
import 'model.dart';
import 'practice.dart';
import 'synth.dart';
import 'theme.dart';

enum _Mode { listen, dum, tek, loopback, playAlong }

const _samplesPerStroke = 8;

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
  StreamSubscription<int>? _clockSub;
  late final Ticker _ticker;
  final _level = ValueNotifier(-120.0);

  _Mode mode = _Mode.listen;
  Onset? last;
  final dumTones = <double>[], tekTones = <double>[];

  // Latency test.
  int? _t0;
  Rendered? _test;
  double _testIntro = 0;
  final _testOnsets = <Onset>[];
  Timer? _testTimer;
  String? latencyNote;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker((_) => _level.value = det?.levelDb ?? -120)..start();
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
      _rebuildDetector();
      _micSub = io.mic.listen(_onMic);
      _clockSub = io.clock.listen((t) => _t0 = t);
      await io.startMic();
      await io.keepScreenOn(true);
      if (mounted) setState(() {});
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    }
  }

  void _rebuildDetector() => det = OnsetDetector(sampleRate: sampleRate, riseDb: s.riseDb, minLevelDb: s.minLevelDb);

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
        case _Mode.dum:
          dumTones.add(o.toneDb);
          if (dumTones.length >= _samplesPerStroke) _finishTone();
        case _Mode.tek:
          tekTones.add(o.toneDb);
          if (tekTones.length >= _samplesPerStroke) _finishTone();
        case _Mode.loopback || _Mode.playAlong:
          _testOnsets.add(o);
      }
      setState(() => last = o);
    }
  }

  void _collect(_Mode m) {
    setState(() {
      mode = m;
      (m == _Mode.dum ? dumTones : tekTones).clear();
    });
  }

  void _finishTone() {
    if (mode == _Mode.dum) s.dumTone = median(dumTones);
    if (mode == _Mode.tek) s.tekTone = median(tekTones);
    mode = _Mode.listen;
    if (s.dumTone != null && s.tekTone != null) s.toneThreshold = (s.dumTone! + s.tekTone!) / 2;
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
      _t0 = null;
    });
    await io.play(test.pcm, silence(sampleRate));
    _testTimer = Timer(Duration(milliseconds: (test.seconds(sampleRate) * 1000).round() + 600), _finishLatency);
  }

  void _finishLatency() {
    io.stopPlay();
    final test = _test!, t0 = _t0;
    final wasLoopback = mode == _Mode.loopback;
    mode = _Mode.listen;
    if (t0 == null) {
      setState(() => latencyNote = 'Не удалось получить время воспроизведения, попробуйте ещё раз');
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
              'Микрофон услышал ${clicks.length} щелчков из 10. Прибавьте громкость или поднимите чувствительность.',
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
                'Положите телефон в 1–2 м от бубна микрофоном к нему. Ударьте несколько раз: каждый удар '
                'должен давать одну отметку. Если удары теряются, поднимите чувствительность; если '
                'срабатывает на шум, опустите.',
            children: [
              ValueListenableBuilder(
                valueListenable: _level,
                builder: (_, v, _) => _Meter(levelDb: v, floorDb: s.minLevelDb),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  const Text('Чувствительность', style: TextStyle(color: Palette.muted)),
                  Expanded(
                    child: Slider(
                      min: -75,
                      max: -20,
                      value: -s.minLevelDb - 95,
                      onChanged: (v) => setState(() {
                        s.minLevelDb = -v - 95;
                        _rebuildDetector();
                      }),
                      onChangeEnd: (_) => widget.store.save(),
                    ),
                  ),
                ],
              ),
              _LastHit(onset: last, threshold: s.toneThreshold, calibrated: s.toneCalibrated),
            ],
          ),
          const SizedBox(height: 12),
          _Section(
            title: '2. Дум и тек',
            body:
                'Сыграйте $_samplesPerStroke ударов каждого вида, как обычно играете, с паузами. '
                'Приложение запомнит, чем они отличаются по звуку.',
            children: [
              _ToneChart(dum: dumTones, tek: tekTones, settings: s),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: _CollectButton(
                      label: 'Дум',
                      active: mode == _Mode.dum,
                      count: dumTones.length,
                      done: s.dumTone != null,
                      onPressed: busy ? null : () => _collect(_Mode.dum),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _CollectButton(
                      label: 'Тек',
                      active: mode == _Mode.tek,
                      count: tekTones.length,
                      done: s.tekTone != null,
                      onPressed: busy ? null : () => _collect(_Mode.tek),
                    ),
                  ),
                ],
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
                icon: Icon(
                  mode == _Mode.loopback || mode == _Mode.playAlong ? Icons.hourglass_top : Icons.timer_outlined,
                ),
                label: Text(mode == _Mode.loopback || mode == _Mode.playAlong ? 'Идёт измерение…' : 'Измерить'),
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
          if (calibrated)
            TextSpan(
              text: low ? 'дум ' : 'тек ',
              style: TextStyle(color: low ? Palette.brass : Palette.rim, fontWeight: FontWeight.w600),
            ),
          TextSpan(
            text: '(${o.peakDb.round()} дБ, тембр ${o.toneDb.round()})',
            style: const TextStyle(color: Palette.muted, fontFeatures: tabular),
          ),
        ],
      ),
    );
  }
}

class _CollectButton extends StatelessWidget {
  const _CollectButton({
    required this.label,
    required this.active,
    required this.count,
    required this.done,
    required this.onPressed,
  });
  final String label;
  final bool active, done;
  final int count;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => OutlinedButton.icon(
    onPressed: active ? null : onPressed,
    icon: Icon(active ? Icons.mic : (done ? Icons.check : Icons.fiber_manual_record_outlined)),
    label: Text(active ? '$label: $count из $_samplesPerStroke' : (done ? '$label: заново' : '$label: записать')),
  );
}

/// Tone of recorded strokes on one axis, with the dum/tek boundary.
class _ToneChart extends StatelessWidget {
  const _ToneChart({required this.dum, required this.tek, required this.settings});
  final List<double> dum, tek;
  final Settings settings;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 44,
    child: CustomPaint(size: Size.infinite, painter: _TonePainter(dum, tek, settings)),
  );
}

class _TonePainter extends CustomPainter {
  _TonePainter(this.dum, this.tek, this.s);
  final List<double> dum, tek;
  final Settings s;

  @override
  void paint(Canvas canvas, Size size) {
    const lo = -40.0, hi = 40.0;
    double x(double v) => 6 + (v.clamp(lo, hi) - lo) / (hi - lo) * (size.width - 12);
    final mid = size.height / 2;
    canvas.drawLine(Offset(0, mid), Offset(size.width, mid), Paint()..color = Palette.line);
    if (s.toneCalibrated) {
      canvas.drawLine(
        Offset(x(s.toneThreshold), 2),
        Offset(x(s.toneThreshold), size.height - 2),
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
    for (final (v, c, dy) in [(s.tekTone, Palette.rim, -8.0), (s.dumTone, Palette.brass, 8.0)]) {
      if (v == null) continue;
      canvas.drawCircle(
        Offset(x(v), mid + dy),
        8,
        Paint()
          ..color = c
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2,
      );
    }
  }

  @override
  bool shouldRepaint(_TonePainter old) => true;
}
