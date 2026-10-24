/// Frame drum strokes. [dum] is the open bass in the centre of the head;
/// [tek] and [ka] are rim strokes of the strong and weak hand. Acoustically
/// tek and ka are both 'high', so the trainer only checks low vs high.
enum Stroke {
  rest('-', '', ''),
  dum('D', 'Д', 'ДУМ'),
  tek('T', 'Т', 'ТЕК'),
  ka('K', 'К', 'КА');

  const Stroke(this.code, this.letter, this.word);

  /// ASCII notation symbol.
  final String code;

  /// Short label on the pattern grid.
  final String letter;

  /// Word shown as the next-stroke hint.
  final String word;

  bool get isLow => this == dum;
  bool get isHit => this != rest;

  /// Order of the grid cell cycle when tapping.
  Stroke get next => Stroke.values[(index + 1) % Stroke.values.length];

  static Stroke? parse(String ch) => switch (ch.toUpperCase()) {
    'D' || 'Д' => dum,
    'T' || 'Т' => tek,
    'K' || 'К' => ka,
    '-' || '.' || '_' => rest,
    _ => null,
  };
}

enum ClickMode {
  beat('каждая доля'),
  cycle('начало цикла'),
  off('без щелчка');

  const ClickMode(this.label);
  final String label;
}

class Pattern {
  Pattern({
    required this.id,
    required this.name,
    required this.steps,
    required this.stepsPerBeat,
    this.bpm = 70,
    this.clickMode = ClickMode.beat,
    this.guide = false,
    this.soundCycles = 2,
    this.silentCycles = 0,
    this.groups,
  });

  final String id;
  String name;
  List<Stroke> steps;

  /// Steps in one metronome beat: 1 quarters, 2 eighths, 3 triplets, 4 sixteenths.
  int stepsPerBeat;

  // Practice settings remembered per pattern.
  int bpm;
  ClickMode clickMode;

  /// Play the pattern itself (dum/tek sounds) as a guide.
  bool guide;

  /// Silent-cycle training: [soundCycles] with sound, then [silentCycles] without.
  int soundCycles;
  int silentCycles;

  /// Steps per metronome click when the rhythm is felt unevenly, e.g. 3+3+2
  /// for malfuf; null clicks every beat.
  List<int>? groups;

  /// Steps where the metronome clicks within a cycle.
  List<int> get clickSteps {
    final g = groups;
    if (g == null || g.isEmpty) return [for (var b = 0; b < beats; b++) b * stepsPerBeat];
    final out = <int>[];
    var s = 0;
    for (final n in g) {
      if (s >= steps.length) break;
      out.add(s);
      s += n;
    }
    return out;
  }

  String get groupsText => groups?.join('+') ?? '';

  /// Parses '3+3+2'; null for empty input, throws on anything else invalid.
  static List<int>? parseGroups(String s) {
    final t = s.replaceAll(' ', '');
    if (t.isEmpty) return null;
    final g = t.split('+').map(int.parse).toList();
    if (g.any((n) => n < 1)) throw const FormatException('group');
    return g;
  }

  int get beats => (steps.length / stepsPerBeat).ceil();

  /// Seconds per step at the current tempo.
  double get stepSeconds => 60 / bpm / stepsPerBeat;

  double get cycleSeconds => stepSeconds * steps.length;

  String get notation {
    final b = StringBuffer();
    for (var i = 0; i < steps.length; i++) {
      if (i > 0 && i % stepsPerBeat == 0) b.write(' ');
      b.write(steps[i].code);
    }
    return b.toString();
  }

  static List<Stroke>? parseSteps(String s) {
    final out = <Stroke>[];
    for (final ch in s.split('')) {
      if (ch.trim().isEmpty || ch == '|') continue;
      final st = Stroke.parse(ch);
      if (st == null) return null;
      out.add(st);
    }
    return out.isEmpty ? null : out;
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'steps': steps.map((s) => s.code).join(),
    'spb': stepsPerBeat,
    'bpm': bpm,
    'click': clickMode.name,
    'guide': guide,
    'sound': soundCycles,
    'silent': silentCycles,
    if (groups != null) 'groups': groups,
  };

  factory Pattern.fromJson(Map<String, dynamic> j) => Pattern(
    id: j['id'] as String,
    name: j['name'] as String,
    steps: parseSteps(j['steps'] as String) ?? [Stroke.dum],
    stepsPerBeat: j['spb'] as int,
    bpm: j['bpm'] as int? ?? 70,
    clickMode: ClickMode.values.asNameMap()[j['click']] ?? ClickMode.beat,
    guide: j['guide'] as bool? ?? false,
    soundCycles: j['sound'] as int? ?? 2,
    silentCycles: j['silent'] as int? ?? 0,
    groups: (j['groups'] as List?)?.cast<int>(),
  );
}

/// Malfuf is felt 3+3+2, not as two even beats.
const malfufGroups = [3, 3, 2];

/// Starting set: basic exercises and common Middle Eastern rhythms.
List<Pattern> presetPatterns() {
  var n = 0;
  Pattern p(String name, String steps, int spb, int bpm, [List<int>? groups]) => Pattern(
    id: 'preset${n++}',
    name: name,
    steps: Pattern.parseSteps(steps)!,
    stepsPerBeat: spb,
    bpm: bpm,
    groups: groups,
  );
  return [
    p('Дум на каждую долю', 'DDDD', 1, 60),
    p('Дум – тек восьмыми', 'DTDT DTDT', 2, 70),
    p('Тек – ка шестнадцатыми', 'TKTK TKTK', 4, 60),
    p('Максум', 'DT-T D-T-', 2, 80),
    p('Баляди', 'DD-T D-T-', 2, 80),
    p('Саиди', 'DT-D D-T-', 2, 80),
    p('Мальфуф', 'D--T --T-', 4, 70, malfufGroups),
    p('Шесть восьмых', 'D-T D-T', 3, 60),
  ];
}
