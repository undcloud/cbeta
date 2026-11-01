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
///
/// [reference] 是 CBETA 的 `code`（例如 `SD-A5A9`）；正文裡留的是形似漢字殼字，
/// 別名層（依 `code` 或羅馬转寫檢索）以後只加不改，索引不必重建。
class ScriptureScriptRun {
  const ScriptureScriptRun({
    required this.offset,
    required this.length,
    required this.family,
    this.reference = '',
  });

  final int offset;
  final int length;
  final ScriptureScriptFamily family;
  final String reference;
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
    this.sourceOffset,
    this.snippet = '',
    this.fromOnlineIndex = false,
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

  /// 整卷經文來源中的命中位移（含卷題／作譯者行，以 UTF-16 計）。
  ///
  /// 離線掃描與書籤用它精確回位；線上索引結果沒有可靠的整卷位移。
  final int? sourceOffset;

  /// 命中字元本身，用來在經卷改版後驗證 [sourceOffset] 是否仍然有效。
  final String snippet;

  /// 是否來自線上全文索引；閱讀器據此優先開啟線上經卷。
  final bool fromOnlineIndex;

  ScripturePassage copyWith({
    required String? linehead,
    String? juan,
    String? reference,
    int? sourceOffset,
    String? snippet,
    bool? fromOnlineIndex,
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
      sourceOffset: sourceOffset,
      snippet: snippet ?? this.snippet,
      fromOnlineIndex: fromOnlineIndex ?? this.fromOnlineIndex,
    );
  }
}

/// 離線索引第一階段的命中：只保留定位用的最小資訊。
///
/// 正文索引是無標點的座標系，可讀摘要要等第二階段用 HTML 重新比對才有，
/// 所以全藏掃描只交出 (作品, 卷, 行號)，點開某部經時再展開。
class OfflineHit {
  const OfflineHit({required this.juan, required this.linehead});

  final String juan;
  final String linehead;
}

class ScriptureSearchResult {
  const ScriptureSearchResult({
    required this.title,
    required this.description,
    required this.passages,
    this.workId = '',
    this.pendingHits = const [],
  });

  final String title;
  final String description;
  final List<ScripturePassage> passages;

  /// 離線分組的作品 id；正文尚未展開時仍要能認得是哪一部經。
  final String workId;

  /// 尚未展開成可讀摘要的命中（離線第一段掃描的產物）。
  final List<OfflineHit> pendingHits;

  bool get isDeferred => passages.isEmpty && pendingHits.isNotEmpty;

  ScriptureSearchResult withPassages(List<ScripturePassage> resolved) =>
      ScriptureSearchResult(
        title: title,
        description: description,
        passages: resolved,
        workId: workId,
      );
}
