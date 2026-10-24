import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'model.dart';
import 'pattern.dart';
import 'theme.dart';

class HistoryScreen extends StatelessWidget {
  const HistoryScreen({super.key, required this.store, required this.pattern});
  final Store store;
  final Pattern pattern;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: store,
    builder: (context, _) {
      final sessions = store.sessionsOf(pattern);
      return Scaffold(
        appBar: AppBar(
          title: Text('История: ${pattern.name}', style: const TextStyle(fontWeight: FontWeight.w600)),
        ),
        body: sessions.isEmpty
            ? const Center(
                child: Padding(
                  padding: EdgeInsets.all(32),
                  child: Text(
                    'Занятий пока нет. Сессия сохраняется, когда вы нажимаете «Стоп».',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Palette.muted),
                  ),
                ),
              )
            : ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  if (sessions.length >= 2) ...[
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Row(
                              children: [
                                _Legend(color: Palette.good, label: 'Точность, %'),
                                SizedBox(width: 16),
                                _Legend(color: Palette.rim, label: 'Разброс, мс'),
                              ],
                            ),
                            const SizedBox(height: 8),
                            SizedBox(
                              height: 140,
                              child: CustomPaint(size: Size.infinite, painter: _ProgressPainter(sessions)),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                  ],
                  for (final s in sessions.reversed) ...[
                    _SessionCard(store: store, session: s),
                    const SizedBox(height: 8),
                  ],
                ],
              ),
      );
    },
  );
}

class _Legend extends StatelessWidget {
  const _Legend({required this.color, required this.label});
  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Container(width: 12, height: 3, color: color),
      const SizedBox(width: 6),
      Text(label, style: const TextStyle(color: Palette.muted, fontSize: 12)),
    ],
  );
}

class _ProgressPainter extends CustomPainter {
  _ProgressPainter(this.sessions);
  final List<Session> sessions;

  @override
  void paint(Canvas canvas, Size size) {
    final n = sessions.length;
    double x(int i) => n == 1 ? size.width / 2 : 4 + i * (size.width - 8) / (n - 1);
    final grid = Paint()..color = Palette.line;
    for (var k = 0; k <= 4; k++) {
      final y = size.height * k / 4;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), grid);
    }
    final sdMax = math.max(40.0, sessions.map((s) => s.sound.sdMs).where((v) => v.isFinite).fold(0.0, math.max));
    void series(double Function(Session) f, double max, Color c) {
      final path = Path();
      var started = false;
      for (var i = 0; i < n; i++) {
        final v = f(sessions[i]);
        if (!v.isFinite) continue;
        final p = Offset(x(i), size.height * (1 - (v / max).clamp(0, 1)));
        started ? path.lineTo(p.dx, p.dy) : path.moveTo(p.dx, p.dy);
        started = true;
        canvas.drawCircle(p, 3, Paint()..color = c);
      }
      canvas.drawPath(
        path,
        Paint()
          ..color = c
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2,
      );
    }

    series((s) => s.sound.accuracy, 1, Palette.good);
    series((s) => s.sound.sdMs, sdMax, Palette.rim);
  }

  @override
  bool shouldRepaint(_ProgressPainter old) => old.sessions != sessions;
}

class _SessionCard extends StatelessWidget {
  const _SessionCard({required this.store, required this.session});
  final Store store;
  final Session session;

  String _date(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}.${d.month.toString().padLeft(2, '0')} '
      '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final s = session;
    String line(TallySummary t) =>
        'точность ${pct(t.accuracy)} · сдвиг ${ms(t.meanMs, sign: true)} · разброс ${ms(t.sdMs)} · удар ${pct(t.strokeRate)}';
    return Card(
      child: ListTile(
        title: Text(
          '${_date(s.at)}  ·  ${s.bpm} уд/мин  ·  ${(s.seconds / 60).toStringAsFixed(1)} мин',
          style: const TextStyle(fontFeatures: tabular),
        ),
        subtitle: Text(
          [
            line(s.sound),
            if (s.silent != null) 'в тишине: ${line(s.silent!)}',
            'пропусков ${s.sound.missed + (s.silent?.missed ?? 0)}, лишних ${s.sound.extras + (s.silent?.extras ?? 0)}',
          ].join('\n'),
          style: const TextStyle(fontFeatures: tabular),
        ),
        isThreeLine: true,
        trailing: IconButton(
          icon: const Icon(Icons.delete_outline, color: Palette.muted),
          onPressed: () => store.deleteSession(s),
        ),
      ),
    );
  }
}
