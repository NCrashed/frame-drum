import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import 'calibration_screen.dart';
import 'dsp.dart';
import 'editor_screen.dart';
import 'history_screen.dart';
import 'model.dart';
import 'pattern.dart';
import 'practice.dart';
import 'scoring.dart';
import 'theme.dart';

class PracticeScreen extends StatefulWidget {
  const PracticeScreen({super.key, required this.store, required this.pattern, this.practice});
  final Store store;
  final Pattern pattern;

  /// Injected in screenshot tests.
  final Practice? practice;

  @override
  State<PracticeScreen> createState() => _PracticeScreenState();
}

class _PracticeScreenState extends State<PracticeScreen> with SingleTickerProviderStateMixin {
  late final practice = widget.practice ?? Practice(widget.store, widget.pattern);
  late final Ticker _ticker;
  final _frame = ValueNotifier(0);

  Pattern get pattern => widget.pattern;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker((_) => _frame.value++);
    practice.addListener(_onPractice);
  }

  void _onPractice() {
    if (practice.running && !_ticker.isActive) _ticker.start();
    if (!practice.running && _ticker.isActive) _ticker.stop();
  }

  @override
  void dispose() {
    _ticker.dispose();
    practice.removeListener(_onPractice);
    if (practice.running) {
      practice.stop().whenComplete(practice.dispose);
    } else {
      practice.dispose();
    }
    super.dispose();
  }

  Future<void> _toggle() async {
    if (!practice.running) {
      await practice.start();
      return;
    }
    final s = await practice.stop();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        duration: Duration(seconds: practice.recordedTo == null ? 4 : 10),
        content: Text(
          [
            s == null
                ? 'Слишком коротко, сессия не сохранена'
                : 'Сохранено: точность ${pct(s.sound.accuracy)}, разброс ${ms(s.sound.sdMs)}',
            if (practice.recordedTo != null) 'Запись: ${practice.recordedTo}',
          ].join('\n'),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([practice, widget.store]),
    builder: (context, _) {
      final busy = practice.state != PracticeState.idle;
      return Scaffold(
        appBar: AppBar(
          title: Text(pattern.name, style: const TextStyle(fontWeight: FontWeight.w600)),
          actions: [
            IconButton(
              tooltip: 'История',
              onPressed: busy ? null : () => _push(HistoryScreen(store: widget.store, pattern: pattern)),
              icon: const Icon(Icons.show_chart),
            ),
            IconButton(
              tooltip: 'Изменить ритм',
              onPressed: busy ? null : () => _push(EditorScreen(store: widget.store, pattern: pattern)),
              icon: const Icon(Icons.edit_outlined),
            ),
          ],
        ),
        body: LayoutBuilder(
          builder: (context, box) {
            final dial = math.min(box.maxWidth - 32, box.maxHeight * 0.46);
            return ListView(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
              children: [
                Center(
                  child: SizedBox.square(
                    dimension: dial,
                    child: CustomPaint(
                      painter: DialPainter(practice, pattern, _frame, DefaultTextStyle.of(context).style),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                OffsetStrip(scorer: practice.scorer),
                const SizedBox(height: 12),
                _Stats(practice: practice),
                if (practice.running && practice.overload > OnsetDetector.overloadWarning)
                  const Padding(
                    padding: EdgeInsets.only(top: 8),
                    child: Text(
                      'Микрофон перегружен: удары считаются неточно. Отодвиньте телефон, отверните '
                      'его микрофоном от бубна или смените источник в калибровке.',
                      style: TextStyle(color: Palette.bad, fontSize: 13),
                    ),
                  ),
                if (practice.clock.jumps > 0)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      'Звук прерывался или сдвигался ${practice.clock.jumps} раз '
                      '(обрывов буфера: ${practice.clock.underruns}). Сдвиги учтены в подсчёте.',
                      style: const TextStyle(color: Palette.off, fontSize: 13),
                    ),
                  ),
                const SizedBox(height: 16),
                if (practice.error != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Text(practice.error!, style: const TextStyle(color: Palette.bad)),
                  ),
                if (!busy) ...[
                  _CalibrationHint(
                    store: widget.store,
                    onOpen: () => _push(CalibrationScreen(store: widget.store)),
                  ),
                  _Controls(store: widget.store, pattern: pattern),
                  const SizedBox(height: 16),
                ],
                SizedBox(
                  height: 56,
                  child: FilledButton.icon(
                    onPressed: practice.state == PracticeState.starting ? null : _toggle,
                    style: FilledButton.styleFrom(
                      backgroundColor: practice.running ? Palette.surfaceHigh : Palette.brass,
                      foregroundColor: practice.running ? Palette.text : const Color(0xFF241A05),
                    ),
                    icon: Icon(practice.running ? Icons.stop : Icons.play_arrow),
                    label: Text(
                      practice.running ? 'Стоп  ·  ${pattern.bpm} уд/мин' : 'Начать',
                      style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      );
    },
  );

  void _push(Widget w) => Navigator.of(context).push(MaterialPageRoute(builder: (_) => w));
}

/// The drum head: steps around the rim, dum lane inside, rim lane outside,
/// a rotating hand and the recent hits where they actually landed.
class DialPainter extends CustomPainter {
  DialPainter(this.practice, this.pattern, Listenable frame, this.textStyle) : super(repaint: frame);
  final TextStyle textStyle;
  final Practice practice;
  final Pattern pattern;

  static const _start = -math.pi / 2;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.shortestSide / 2 - 4;
    final ri = r * 0.42, ro = r * 0.74;
    final n = pattern.steps.length;
    Offset at(double phase, double radius) => c + Offset.fromDirection(_start + 2 * math.pi * phase, radius);

    canvas
      ..drawCircle(c, r, Paint()..color = Palette.skin)
      ..drawCircle(
        c,
        r - r * 0.03,
        Paint()
          ..color = const Color(0xFF4A4134)
          ..style = PaintingStyle.stroke
          ..strokeWidth = r * 0.06,
      );
    final lane = Paint()
      ..color = Palette.line
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    canvas
      ..drawCircle(c, ri, lane)
      ..drawCircle(c, ro, lane);

    for (var i = 0; i < n; i++) {
      final beat = i % pattern.stepsPerBeat == 0;
      canvas.drawLine(
        at(i / n, r * (beat ? 0.83 : 0.86)),
        at(i / n, r * 0.9),
        Paint()
          ..color = beat ? Palette.muted : Palette.line
          ..strokeWidth = beat ? 2.5 : 1.5
          ..strokeCap = StrokeCap.round,
      );
    }

    final sc = practice.scorer;
    final now = practice.now;
    final live = practice.running && sc != null && now != null;
    final song = live && now >= sc.start;
    final next = live ? sc.upcoming(now) : null;

    for (var i = 0; i < n; i++) {
      final s = pattern.steps[i];
      if (!s.isHit) continue;
      final hot = next != null && next.k % n == i;
      final col = Palette.stroke(s).withValues(alpha: hot ? 1 : 0.45);
      final p = at(i / n, s.isLow ? ri : ro);
      switch (s) {
        case Stroke.dum:
          canvas.drawCircle(p, r * (hot ? 0.085 : 0.07), Paint()..color = col);
        case Stroke.tek:
          canvas.drawCircle(p, r * (hot ? 0.06 : 0.05), Paint()..color = col);
        case Stroke.ka:
          canvas.drawCircle(
            p,
            r * (hot ? 0.055 : 0.045),
            Paint()
              ..color = col
              ..style = PaintingStyle.stroke
              ..strokeWidth = 3,
          );
        case Stroke.rest:
      }
    }

    if (live) {
      final span = pattern.cycleSeconds;
      // Missed strokes of the last cycle: red ring around the marker.
      for (final e in sc.expected.reversed) {
        final age = now - e.t;
        if (age > span) break;
        if (!e.closed || e.hit != null) continue;
        canvas.drawCircle(
          at(sc.phase(e.t), e.stroke.isLow ? ri : ro),
          r * 0.1,
          Paint()
            ..color = Palette.bad.withValues(alpha: (1 - age / span).clamp(0, 1) * 0.8)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2,
        );
      }
      for (final h in sc.hits.reversed) {
        final age = now - h.t;
        if (age > span) break;
        final a = (1 - age / span).clamp(0.0, 1.0);
        final p = at(sc.phase(h.t), h.low ? ri : ro);
        final col = Palette.grade(h.grade).withValues(alpha: a);
        if (h.target == null) {
          final d = r * 0.035;
          final pen = Paint()
            ..color = col
            ..strokeWidth = 2.5
            ..strokeCap = StrokeCap.round;
          canvas
            ..drawLine(p + Offset(-d, -d), p + Offset(d, d), pen)
            ..drawLine(p + Offset(-d, d), p + Offset(d, -d), pen);
        } else {
          canvas.drawCircle(p, r * 0.035, Paint()..color = col);
          if (!h.strokeOk) {
            canvas.drawCircle(
              p,
              r * 0.055,
              Paint()
                ..color = Palette.bad.withValues(alpha: a)
                ..style = PaintingStyle.stroke
                ..strokeWidth = 2,
            );
          }
        }
      }
      if (song) {
        final ph = sc.phase(now);
        canvas.drawLine(
          at(ph, r * 0.18),
          at(ph, r * 0.92),
          Paint()
            ..color = Palette.text.withValues(alpha: 0.7)
            ..strokeWidth = 2.5
            ..strokeCap = StrokeCap.round,
        );
      }
    }

    // Centre text.
    String big, small;
    Color color = Palette.text;
    if (!live) {
      big = '${pattern.bpm}';
      small = 'уд/мин';
    } else if (!song) {
      final beat = 60 / pattern.bpm;
      big = '${math.max(1, practice.countInBeats - (now / beat).floor())}';
      small = 'вступление';
    } else {
      final silent = sc.silentAt(((now - sc.start) / pattern.stepSeconds).floor());
      big = next?.stroke.word ?? '';
      color = next == null ? Palette.text : Palette.stroke(next.stroke);
      small = silent ? 'тишина' : '';
    }
    _text(canvas, big, c - Offset(0, r * 0.04), r * 0.2, color, FontWeight.w700);
    if (small.isNotEmpty) _text(canvas, small, c + Offset(0, r * 0.16), r * 0.075, Palette.muted, FontWeight.w500);
  }

  void _text(Canvas canvas, String s, Offset center, double size, Color color, FontWeight w) {
    final tp = TextPainter(
      text: TextSpan(
        text: s,
        style: textStyle.copyWith(color: color, fontSize: size, fontWeight: w, fontFeatures: tabular),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, center - Offset(tp.width / 2, tp.height / 2));
  }

  @override
  bool shouldRepaint(DialPainter old) => true;
}

/// Recent timing errors on a -100..+100 ms axis: left is early, right is late.
class OffsetStrip extends StatelessWidget {
  const OffsetStrip({super.key, required this.scorer});
  final Scorer? scorer;

  @override
  Widget build(BuildContext context) => Column(
    children: [
      SizedBox(
        height: 36,
        child: CustomPaint(size: Size.infinite, painter: _StripPainter(scorer)),
      ),
      const SizedBox(height: 4),
      const Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text('раньше', style: TextStyle(color: Palette.muted, fontSize: 12)),
          Text('±100 мс', style: TextStyle(color: Palette.muted, fontSize: 12)),
          Text('позже', style: TextStyle(color: Palette.muted, fontSize: 12)),
        ],
      ),
    ],
  );
}

class _StripPainter extends CustomPainter {
  _StripPainter(this.scorer);
  final Scorer? scorer;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    double x(double ms) => w / 2 + (ms.clamp(-100, 100) / 100) * (w / 2 - 4);
    final rr = RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(10));
    canvas.drawRRect(rr, Paint()..color = Palette.surface);
    // Good and ok zones.
    canvas
      ..drawRect(Rect.fromLTRB(x(-50), 0, x(50), h), Paint()..color = Palette.ok.withValues(alpha: 0.06))
      ..drawRect(Rect.fromLTRB(x(-25), 0, x(25), h), Paint()..color = Palette.good.withValues(alpha: 0.10))
      ..drawLine(Offset(w / 2, 0), Offset(w / 2, h), Paint()..color = Palette.line);

    final hits = scorer?.hits.where((h) => h.target != null).toList() ?? const <Hit>[];
    final recent = hits.length > 24 ? hits.sublist(hits.length - 24) : hits;
    for (final (i, hit) in recent.indexed) {
      final a = 0.25 + 0.75 * (i + 1) / recent.length;
      canvas.drawLine(
        Offset(x(hit.offsetMs), h * 0.2),
        Offset(x(hit.offsetMs), h * 0.8),
        Paint()
          ..color = Palette.grade(hit.grade).withValues(alpha: a)
          ..strokeWidth = i == recent.length - 1 ? 4 : 2.5
          ..strokeCap = StrokeCap.round,
      );
    }
    final m = scorer?.all.meanMs ?? double.nan;
    if (m.isFinite) {
      final p = Path()
        ..moveTo(x(m) - 6, 0)
        ..lineTo(x(m) + 6, 0)
        ..lineTo(x(m), 7)
        ..close();
      canvas.drawPath(p, Paint()..color = Palette.text);
    }
  }

  @override
  bool shouldRepaint(_StripPainter old) => true;
}

class _Stats extends StatelessWidget {
  const _Stats({required this.practice});
  final Practice practice;

  @override
  Widget build(BuildContext context) {
    final sc = practice.scorer;
    final silent = practice.pattern.silentCycles > 0;
    return Column(
      children: [
        _StatRow(tally: sc?.sound, label: silent ? 'Со звуком' : null),
        if (silent) ...[const SizedBox(height: 8), _StatRow(tally: sc?.silent, label: 'В тишине')],
      ],
    );
  }
}

class _StatRow extends StatelessWidget {
  const _StatRow({required this.tally, this.label});
  final Tally? tally;
  final String? label;

  @override
  Widget build(BuildContext context) {
    final t = tally;
    final mean = t?.meanMs ?? double.nan;
    final drift = !mean.isFinite
        ? ''
        : mean.abs() < 10
        ? 'ровно'
        : (mean < 0 ? 'спешите' : 'тянете');
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (label != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text(label!, style: const TextStyle(color: Palette.muted, fontSize: 12)),
              ),
            Row(
              children: [
                _Stat(
                  'Точность',
                  pct(t?.accuracy ?? double.nan),
                  Palette.accuracy(t?.accuracy ?? double.nan),
                  t == null ? '' : '${t.good + t.ok} из ${t.expected}',
                ),
                _Stat('Сдвиг', ms(mean, sign: true), Palette.text, drift),
                _Stat('Разброс', ms(t?.sdMs ?? double.nan), Palette.text, t == null ? '' : 'σ'),
                _Stat('Удар', pct(t?.strokeRate ?? double.nan), Palette.text, t == null ? '' : 'лишних ${t.extras}'),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat(this.title, this.value, this.color, this.sub);
  final String title, value, sub;
  final Color color;

  @override
  Widget build(BuildContext context) => Expanded(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: const TextStyle(color: Palette.muted, fontSize: 12)),
        const SizedBox(height: 2),
        Text(
          value,
          style: TextStyle(color: color, fontSize: 18, fontWeight: FontWeight.w600, fontFeatures: tabular),
        ),
        Text(
          sub,
          style: const TextStyle(color: Palette.muted, fontSize: 11, fontFeatures: tabular),
        ),
      ],
    ),
  );
}

class _CalibrationHint extends StatelessWidget {
  const _CalibrationHint({required this.store, required this.onOpen});
  final Store store;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final s = store.settings;
    if (s.latencyMs.isNotEmpty && s.toneCalibrated) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Card(
        child: ListTile(
          leading: const Icon(Icons.tune, color: Palette.brass),
          title: const Text('Нужна калибровка'),
          subtitle: Text(
            s.latencyMs.isEmpty
                ? 'Без неё задержка звука телефона попадёт в сдвиг'
                : 'Научите приложение отличать дум от тека',
          ),
          onTap: onOpen,
        ),
      ),
    );
  }
}

class _Controls extends StatefulWidget {
  const _Controls({required this.store, required this.pattern});
  final Store store;
  final Pattern pattern;

  @override
  State<_Controls> createState() => _ControlsState();
}

class _ControlsState extends State<_Controls> {
  Pattern get p => widget.pattern;

  void _bpm(int v) {
    p.bpm = v.clamp(30, 240);
    widget.store.save();
  }

  static const _silence = [(2, 0), (2, 1), (2, 2), (4, 4)];

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Row(
        children: [
          IconButton.outlined(onPressed: () => _bpm(p.bpm - 1), icon: const Icon(Icons.remove)),
          Expanded(
            child: Slider(
              min: 30,
              max: 240,
              value: p.bpm.toDouble(),
              onChanged: (v) => setState(() => p.bpm = v.round()),
              onChangeEnd: (v) => _bpm(v.round()),
            ),
          ),
          IconButton.outlined(onPressed: () => _bpm(p.bpm + 1), icon: const Icon(Icons.add)),
        ],
      ),
      const SizedBox(height: 12),
      _Labeled(
        'Щелчок',
        SegmentedButton<ClickMode>(
          showSelectedIcon: false,
          segments: const [
            ButtonSegment(value: ClickMode.beat, label: Text('доли')),
            ButtonSegment(value: ClickMode.cycle, label: Text('цикл')),
            ButtonSegment(value: ClickMode.off, label: Text('нет')),
          ],
          selected: {p.clickMode},
          onSelectionChanged: (s) {
            p.clickMode = s.first;
            widget.store.save();
          },
        ),
      ),
      const SizedBox(height: 10),
      _Labeled(
        'Тишина',
        SegmentedButton<(int, int)>(
          showSelectedIcon: false,
          segments: [
            for (final o in _silence) ButtonSegment(value: o, label: Text(o.$2 == 0 ? 'нет' : '${o.$1}+${o.$2}')),
          ],
          selected: {p.silentCycles == 0 ? (2, 0) : (p.soundCycles, p.silentCycles)},
          emptySelectionAllowed: true,
          onSelectionChanged: (s) {
            if (s.isEmpty) return;
            p
              ..soundCycles = s.first.$1
              ..silentCycles = s.first.$2;
            widget.store.save();
          },
        ),
      ),
      Padding(
        padding: const EdgeInsets.only(left: 88, top: 4),
        child: Text(
          p.silentCycles == 0
              ? 'Звук всё время'
              : '${p.soundCycles} цикла со звуком, затем ${p.silentCycles} в тишине: держите темп сами',
          style: const TextStyle(color: Palette.muted, fontSize: 12),
        ),
      ),
      const SizedBox(height: 4),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('Подсказка звуком'),
        subtitle: const Text('Телефон играет сам ритм: дум и тек. Лучше в наушниках'),
        value: p.guide,
        onChanged: (v) {
          p.guide = v;
          widget.store.save();
        },
      ),
    ],
  );
}

class _Labeled extends StatelessWidget {
  const _Labeled(this.label, this.child);
  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      SizedBox(
        width: 88,
        child: Text(label, style: const TextStyle(color: Palette.muted)),
      ),
      Expanded(child: child),
    ],
  );
}
