class ScriptureLine {
  const ScriptureLine({
    required this.text,
    this.linehead,
    this.footnotes = const [],
    this.inlineNotes = const [],
    this.scriptRuns = const [],
    this.verseCells = const [],
    this.images = const [],
    this.tableRows = const [],
    this.headingLevel = 0,
    this.role = ScriptureLineRole.regular,
  });

  final String text;
  final String? linehead;
  final List<ScriptureFootnote> footnotes;
  final List<ScriptureInlineNote> inlineNotes;
  final List<ScriptureScriptRun> scriptRuns;
  final List<String> verseCells;
  final List<ScriptureImage> images;
  final List<List<ScriptureTableCell>> tableRows;
  final int headingLevel;
  final ScriptureLineRole role;
}

enum ScriptureLineRole { regular, volumeTitle, byline, navigationAnchor }

enum ScriptureScriptFamily { siddam, ranjana }

/// 悉曇／蘭札等特殊字體的文字區間（以 `text` 的 UTF-16 位移計）。
class ScriptureScriptRun {
  const ScriptureScriptRun({
    required this.offset,
    required this.length,
    required this.family,
  });

  final int offset;
  final int length;
  final ScriptureScriptFamily family;
}

class ScriptureImage {
  const ScriptureImage({required this.source, this.alt = ''});

  final String source;
  final String alt;
}

class ScriptureTableCell {
  const ScriptureTableCell({required this.text, this.columnSpan = 1});

  final String text;
  final int columnSpan;
}

class ScriptureInlineNote {
  const ScriptureInlineNote({required this.offset, required this.length});

  final int offset;
  final int length;
}

class ScriptureFootnote {
  const ScriptureFootnote({
    required this.offset,
    required this.label,
    required this.clue,
    required this.content,
  });

  final int offset;
  final String label;
  final String clue;
  final String content;
}

class ScripturePassage {
  const ScripturePassage({
    required this.title,
    required this.reference,
    required this.text,
    this.linehead,
    this.juan,
    this.work,
    this.availableJuans = const [],
    this.lines = const [],
    this.showCollation = true,
    this.showLineBeginnings = false,
  });

  final String title;
  final String reference;
  final String text;
  final String? linehead;
  final String? juan;
  final String? work;
  final List<int> availableJuans;
  final List<ScriptureLine> lines;
  final bool showCollation;
  final bool showLineBeginnings;

  ScripturePassage copyWith({
    required String? linehead,
    String? juan,
    String? reference,
  }) {
    return ScripturePassage(
      title: title,
      reference: reference ?? this.reference,
      text: text,
      linehead: linehead,
      juan: juan ?? this.juan,
      work: work,
      availableJuans: availableJuans,
      lines: lines,
      showCollation: showCollation,
      showLineBeginnings: showLineBeginnings,
    );
  }
}

class ScriptureSearchResult {
  const ScriptureSearchResult({
    required this.title,
    required this.description,
    required this.passages,
  });

  final String title;
  final String description;
  final List<ScripturePassage> passages;
}
