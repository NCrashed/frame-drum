import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'calibration_screen.dart';
import 'editor_screen.dart';
import 'model.dart';
import 'pattern.dart';
import 'practice_screen.dart';
import 'theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final store = Store();
  try {
    await store.load();
  } on MissingPluginException {
    // Not on Android: keep data in memory.
  }
  runApp(FrameDrumApp(store: store));
}

class FrameDrumApp extends StatelessWidget {
  const FrameDrumApp({super.key, required this.store});
  final Store store;

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Бубен',
    debugShowCheckedModeBanner: false,
    theme: buildTheme(),
    home: HomeScreen(store: store),
  );
}

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key, required this.store});
  final Store store;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: store,
    builder: (context, _) {
      final s = store.settings;
      final calibrated = s.latencyMs.isNotEmpty && s.toneCalibrated;
      return Scaffold(
        appBar: AppBar(
          title: const Text('Ритмы', style: TextStyle(fontWeight: FontWeight.w600)),
          actions: [
            IconButton(
              tooltip: 'Калибровка',
              onPressed: () => _push(context, CalibrationScreen(store: store)),
              icon: Badge(isLabelVisible: !calibrated, smallSize: 8, child: const Icon(Icons.tune)),
            ),
            _HomeMenu(store: store),
          ],
        ),
        floatingActionButton: FloatingActionButton.extended(
          onPressed: () {
            final p = store.addPattern();
            _push(context, EditorScreen(store: store, pattern: p));
          },
          icon: const Icon(Icons.add),
          label: const Text('Ритм'),
        ),
        body: ListView.separated(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
          itemCount: store.patterns.length,
          separatorBuilder: (_, _) => const SizedBox(height: 10),
          itemBuilder: (context, i) => _PatternCard(store: store, pattern: store.patterns[i]),
        ),
      );
    },
  );
}

void _push(BuildContext context, Widget w) => Navigator.of(context).push(MaterialPageRoute(builder: (_) => w));

class _PatternCard extends StatelessWidget {
  const _PatternCard({required this.store, required this.pattern});
  final Store store;
  final Pattern pattern;

  @override
  Widget build(BuildContext context) {
    final sessions = store.sessionsOf(pattern);
    final last = sessions.isEmpty ? null : sessions.last;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => _push(context, PracticeScreen(store: store, pattern: pattern)),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(pattern.name, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
                  ),
                  Text(
                    '${pattern.bpm} уд/мин',
                    style: const TextStyle(color: Palette.muted, fontFeatures: tabular),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              PatternStrip(pattern: pattern),
              if (last != null) ...[
                const SizedBox(height: 10),
                Text(
                  'Последнее: точность ${pct(last.sound.accuracy)}, разброс ${ms(last.sound.sdMs)}'
                  '  ·  занятий ${sessions.length}',
                  style: TextStyle(color: Palette.accuracy(last.sound.accuracy), fontSize: 13, fontFeatures: tabular),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Compact row of the pattern's strokes, grouped by beat.
class PatternStrip extends StatelessWidget {
  const PatternStrip({super.key, required this.pattern});
  final Pattern pattern;

  @override
  Widget build(BuildContext context) => Wrap(
    spacing: 8,
    runSpacing: 6,
    children: [
      for (var b = 0; b < pattern.beats; b++)
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = b * pattern.stepsPerBeat; i < (b + 1) * pattern.stepsPerBeat && i < pattern.steps.length; i++)
              Container(
                width: 22,
                height: 26,
                margin: const EdgeInsets.only(right: 2),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: pattern.steps[i].isHit
                      ? Palette.stroke(pattern.steps[i]).withValues(alpha: 0.16)
                      : Palette.surfaceHigh,
                  borderRadius: BorderRadius.circular(5),
                ),
                child: Text(
                  pattern.steps[i].isHit ? pattern.steps[i].letter : '',
                  style: TextStyle(color: Palette.stroke(pattern.steps[i]), fontWeight: FontWeight.w700, fontSize: 13),
                ),
              ),
          ],
        ),
    ],
  );
}

class _HomeMenu extends StatelessWidget {
  const _HomeMenu({required this.store});
  final Store store;

  @override
  Widget build(BuildContext context) => PopupMenuButton<String>(
    onSelected: (v) async {
      final messenger = ScaffoldMessenger.of(context);
      switch (v) {
        case 'backup':
          await Clipboard.setData(ClipboardData(text: store.exportJson()));
          messenger.showSnackBar(const SnackBar(content: Text('Резервная копия (JSON) в буфере обмена')));
        case 'restore':
          final data = await Clipboard.getData(Clipboard.kTextPlain);
          if (!context.mounted) return;
          final ok = await confirm(context, 'Восстановить из буфера?', 'Текущие данные будут заменены.');
          if (!ok) return;
          try {
            store.importJson(data?.text ?? '');
            messenger.showSnackBar(const SnackBar(content: Text('Восстановлено')));
          } catch (_) {
            messenger.showSnackBar(const SnackBar(content: Text('В буфере нет корректной резервной копии')));
          }
      }
    },
    itemBuilder: (_) => const [
      PopupMenuItem(value: 'backup', child: Text('Резервная копия в буфер')),
      PopupMenuItem(value: 'restore', child: Text('Восстановить из буфера')),
    ],
  );
}

Future<bool> confirm(BuildContext context, String title, String body) async =>
    await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Отмена')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Да')),
        ],
      ),
    ) ??
    false;
