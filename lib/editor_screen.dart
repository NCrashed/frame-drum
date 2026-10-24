import 'package:flutter/material.dart';

import 'main.dart' show confirm;
import 'model.dart';
import 'pattern.dart';
import 'theme.dart';

class EditorScreen extends StatefulWidget {
  const EditorScreen({super.key, required this.store, required this.pattern});
  final Store store;
  final Pattern pattern;

  @override
  State<EditorScreen> createState() => _EditorScreenState();
}

class _EditorScreenState extends State<EditorScreen> {
  late final name = TextEditingController(text: widget.pattern.name);
  late final notation = TextEditingController(text: widget.pattern.notation);
  String? notationError;
  late final groups = TextEditingController(text: widget.pattern.groupsText);
  String? groupsError;

  Pattern get p => widget.pattern;

  @override
  void dispose() {
    name.dispose();
    notation.dispose();
    groups.dispose();
    super.dispose();
  }

  void _changed() {
    notation.text = p.notation;
    notationError = null;
    widget.store.save();
    setState(() {});
  }

  void _setBeats(int beats) {
    if (beats < 1 || beats > 16) return;
    final n = beats * p.stepsPerBeat;
    p.steps = [for (var i = 0; i < n; i++) i < p.steps.length ? p.steps[i] : Stroke.rest];
    _changed();
  }

  /// Keeps strokes at the same musical positions where the new grid has them.
  void _setSubdivision(int spb) {
    final beats = p.beats;
    final out = List.filled(beats * spb, Stroke.rest);
    for (var i = 0; i < p.steps.length; i++) {
      final pos = i * spb / p.stepsPerBeat;
      if (pos == pos.roundToDouble() && pos < out.length) out[pos.round()] = p.steps[i];
    }
    p
      ..stepsPerBeat = spb
      ..steps = out;
    _changed();
  }

  void _applyGroups(String s) {
    try {
      p.groups = Pattern.parseGroups(s);
    } on FormatException {
      setState(() => groupsError = 'Числа шагов через +, например 3+3+2');
      return;
    }
    groupsError = null;
    _changed();
  }

  String _groupsHelp() {
    final sum = p.groups!.fold(0, (a, b) => a + b);
    return sum == p.steps.length
        ? 'Щелчок в начале каждой группы'
        : 'Сумма групп $sum, а шагов в ритме ${p.steps.length}';
  }

  void _applyNotation(String s) {
    final steps = Pattern.parseSteps(s);
    if (steps == null) {
      setState(() => notationError = 'Используйте D, T, K (или Д, Т, К) и - для паузы');
      return;
    }
    p.steps = steps;
    _changed();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Ритм', style: TextStyle(fontWeight: FontWeight.w600)),
      actions: [
        IconButton(
          tooltip: 'Удалить',
          icon: const Icon(Icons.delete_outline),
          onPressed: () async {
            final nav = Navigator.of(context);
            if (!await confirm(context, 'Удалить «${p.name}»?', 'История занятий с этим ритмом тоже удалится.')) return;
            widget.store.deletePattern(p);
            nav.popUntil((r) => r.isFirst);
          },
        ),
      ],
    ),
    body: ListView(
      padding: const EdgeInsets.all(16),
      children: [
        TextField(
          controller: name,
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(labelText: 'Название', border: OutlineInputBorder()),
          onChanged: (v) {
            p.name = v.trim().isEmpty ? 'Без названия' : v.trim();
            widget.store.save();
          },
        ),
        const SizedBox(height: 20),
        Row(
          children: [
            const SizedBox(
              width: 96,
              child: Text('Деление', style: TextStyle(color: Palette.muted)),
            ),
            Expanded(
              child: SegmentedButton<int>(
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(value: 1, label: Text('1/4')),
                  ButtonSegment(value: 2, label: Text('1/8')),
                  ButtonSegment(value: 3, label: Text('трио')),
                  ButtonSegment(value: 4, label: Text('1/16')),
                ],
                selected: {p.stepsPerBeat},
                onSelectionChanged: (s) => _setSubdivision(s.first),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            const SizedBox(
              width: 96,
              child: Text('Долей', style: TextStyle(color: Palette.muted)),
            ),
            IconButton.outlined(onPressed: () => _setBeats(p.beats - 1), icon: const Icon(Icons.remove)),
            SizedBox(
              width: 48,
              child: Text(
                '${p.beats}',
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600, fontFeatures: tabular),
              ),
            ),
            IconButton.outlined(onPressed: () => _setBeats(p.beats + 1), icon: const Icon(Icons.add)),
          ],
        ),
        const SizedBox(height: 12),
        TextField(
          controller: groups,
          keyboardType: TextInputType.text,
          decoration: InputDecoration(
            labelText: 'Щелчки по группам',
            hintText: 'например 3+3+2',
            helperText: groupsError == null
                ? (p.groups == null ? 'Пусто: щелчок на каждую долю' : _groupsHelp())
                : null,
            errorText: groupsError,
            border: const OutlineInputBorder(),
          ),
          onSubmitted: _applyGroups,
        ),
        const SizedBox(height: 20),
        const Text('Нажимайте клетки: пауза → дум → тек → ка', style: TextStyle(color: Palette.muted)),
        const SizedBox(height: 10),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            for (var b = 0; b < p.beats; b++)
              Container(
                padding: const EdgeInsets.all(4),
                decoration: BoxDecoration(
                  border: Border.all(color: Palette.line),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (var i = b * p.stepsPerBeat; i < (b + 1) * p.stepsPerBeat && i < p.steps.length; i++)
                      _Cell(
                        stroke: p.steps[i],
                        onTap: () {
                          p.steps[i] = p.steps[i].next;
                          _changed();
                        },
                      ),
                  ],
                ),
              ),
          ],
        ),
        const SizedBox(height: 24),
        TextField(
          controller: notation,
          decoration: InputDecoration(
            labelText: 'Запись',
            helperText: 'Например: DT-T D-T-  (пробелы не важны)',
            errorText: notationError,
            border: const OutlineInputBorder(),
          ),
          style: const TextStyle(fontFamily: 'monospace', letterSpacing: 2),
          onSubmitted: _applyNotation,
        ),
      ],
    ),
  );
}

class _Cell extends StatelessWidget {
  const _Cell({required this.stroke, required this.onTap});
  final Stroke stroke;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = Palette.stroke(stroke);
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 40,
        height: 48,
        margin: const EdgeInsets.all(2),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: stroke.isHit ? c.withValues(alpha: 0.16) : Palette.surface,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: stroke.isHit ? c.withValues(alpha: 0.6) : Palette.line),
        ),
        child: Text(
          stroke.isHit ? stroke.letter : '·',
          style: TextStyle(color: c, fontSize: 18, fontWeight: FontWeight.w700),
        ),
      ),
    );
  }
}
