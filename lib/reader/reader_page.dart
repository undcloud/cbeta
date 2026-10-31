import 'dart:async';
import 'package:flutter/material.dart' as flutter_material;
import 'package:flutter/material.dart' hide Text;
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';
import '../scripture/cache.dart';
import '../scripture/models.dart';
import '../scripture/parser.dart';
import '../scripture/reader_blocks.dart';
import '../scripture/source_text.dart';
import '../search/candidates.dart';
import '../search/history.dart';
import '../search/search_input.dart';
import '../settings/display_settings.dart';
import 'reader_citations.dart';
import 'reader_layout.dart';
import 'reader_store.dart';
import '../settings/display_settings_ui.dart';
import '../widgets/display_text.dart';
import '../widgets/result_widgets.dart';
import '../work_picker/work_picker_page.dart';

class ScriptureReaderPage extends StatefulWidget {
  const ScriptureReaderPage({
    required this.passage,
    required this.query,
    required this.searchHits,
    required this.initialHitIndex,
    super.key,
  });

  final ScripturePassage passage;
  final String query;
  final List<ScripturePassage> searchHits;
  final int initialHitIndex;

  @override
  State<ScriptureReaderPage> createState() => ScriptureReaderPageState();
}

class ScriptureReaderPageState extends State<ScriptureReaderPage> {
  final readerScrollController = ScrollController();
  final List<GlobalKey> _blockKeys = [];
  List<int> _blockOffsetBases = const [];
  String _selectedContentText = '';
  int _scrollRequestId = 0;
  ({int blockIndex, int localOffset, double delta})? _pendingScrollAnchor;
  final localSearchController = TextEditingController();
  final Map<String, Future<List<ScriptureLine>>> juanCache = {};
  bool preferOnline = false;
  int? _currentSourceOffset;
  String _currentSnippet = '';
  String? _historyPositionKey;
  bool didScrollToMatch = false;
  bool showSearchNavigation = true;
  bool showLocalSearch = false;
  String localSearchQuery = '';
  List<ScriptureLine> localSearchLines = const [];
  int localSearchIndex = 0;
  bool isBookmarked = false;
  late ScripturePassage currentPassage;
  late int currentHitIndex;
  late Future<List<ScriptureLine>> linesFuture;

  @override
  void initState() {
    super.initState();
    currentPassage = widget.passage;
    currentHitIndex = widget.initialHitIndex;
    preferOnline = _preferOnlineFor(currentPassage);
    linesFuture = _cachedJuan(currentPassage, preferOnline: preferOnline);
    _refreshBookmarkState();
    _persistReadingHistory();
    scriptureDisplaySettings.addListener(_onDisplaySettingsChanged);
  }

  bool _preferOnlineFor(ScripturePassage passage) =>
      passage.fromOnlineIndex && passage.sourceOffset == null;

  ScripturePassage _positionedPassage() => currentPassage.copyWith(
    linehead: currentPassage.linehead,
    sourceOffset: _currentSourceOffset ?? currentPassage.sourceOffset,
    snippet: _currentSnippet.isEmpty ? currentPassage.snippet : _currentSnippet,
  );

  Future<void> _persistReadingHistory() async {
    try {
      await recordRecentReading(_positionedPassage());
    } catch (error) {
      if (!mounted) return;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('儲存閱讀記錄失敗：$error')));
      });
    }
  }

  String get _bookmarkKey {
    final offset = _currentSourceOffset ?? currentPassage.sourceOffset;
    return '${currentPassage.work}:${currentPassage.juan}:'
        '${currentPassage.linehead ?? offset?.toString() ?? ''}';
  }

  Future<void> _refreshBookmarkState() async {
    try {
      final bookmarks = await loadBookmarks();
      if (!mounted) return;
      setState(() {
        isBookmarked = bookmarks.any(
          (bookmark) => bookmark.key == _bookmarkKey,
        );
      });
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('載入書籤失敗：$error')));
    }
  }

  Future<void> _toggleBookmark() async {
    try {
      final bookmarks = await loadBookmarks();
      final index = bookmarks.indexWhere(
        (bookmark) => bookmark.key == _bookmarkKey,
      );
      if (index >= 0) {
        bookmarks.removeAt(index);
      } else {
        bookmarks.insert(0, ReaderBookmark.fromPassage(_positionedPassage()));
      }
      await saveBookmarks(bookmarks);
      if (!mounted) return;
      setState(() => isBookmarked = index < 0);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(index >= 0 ? '已移除書籤' : '已加入書籤')));
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('儲存書籤失敗：$error')));
    }
  }

  Future<void> _showBookmarks() async {
    late final List<ReaderBookmark> bookmarks;
    try {
      bookmarks = await loadBookmarks();
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('載入書籤失敗：$error')));
      return;
    }
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => SafeArea(
        child: SizedBox(
          height: MediaQuery.sizeOf(sheetContext).height * 0.65,
          child: StatefulBuilder(
            builder: (context, refreshSheet) => Column(
              children: [
                ListTile(
                  title: const Text('書籤'),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const ScriptDisplayButton(),
                      IconButton(
                        tooltip: displayText('關閉', context),
                        onPressed: () => Navigator.pop(context),
                        icon: const Icon(Icons.close_rounded),
                      ),
                    ],
                  ),
                ),
                ListTile(
                  leading: Icon(
                    isBookmarked
                        ? Icons.bookmark_added_rounded
                        : Icons.bookmark_add_outlined,
                  ),
                  title: Text(isBookmarked ? '移除此書籤' : '加入目前位置'),
                  onTap: () async {
                    await _toggleBookmark();
                    final latestBookmarks = await loadBookmarks();
                    bookmarks
                      ..clear()
                      ..addAll(latestBookmarks);
                    refreshSheet(() {});
                  },
                ),
                const Divider(height: 1),
                Expanded(
                  child: bookmarks.isEmpty
                      ? const Center(child: Text('尚無書籤'))
                      : ListView.builder(
                          itemCount: bookmarks.length,
                          itemBuilder: (context, index) {
                            final bookmark = bookmarks[index];
                            return ListTile(
                              title: Text(bookmark.title),
                              subtitle: Text(
                                '卷 ${bookmark.juan}'
                                '${bookmark.linehead == null ? '' : ' · ${bookmark.linehead!.split('_p').last}'}',
                              ),
                              onTap: () {
                                Navigator.pop(context);
                                _openBookmark(bookmark);
                              },
                              trailing: IconButton(
                                tooltip: displayText('刪除書籤', context),
                                icon: const Icon(Icons.delete_outline_rounded),
                                onPressed: () async {
                                  bookmarks.removeAt(index);
                                  await saveBookmarks(bookmarks);
                                  await _refreshBookmarkState();
                                  refreshSheet(() {});
                                },
                              ),
                            );
                          },
                        ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _openBookmark(ReaderBookmark bookmark) {
    final passage = bookmark.toPassage();
    setState(() {
      currentPassage = passage;
      currentHitIndex = 0;
      showSearchNavigation = false;
      preferOnline = false;
      _currentSourceOffset = passage.sourceOffset;
      _currentSnippet = passage.snippet;
      didScrollToMatch = false;
      linesFuture = _cachedJuan(passage, preferOnline: preferOnline);
    });
    _refreshBookmarkState();
    _persistReadingHistory();
  }

  Future<void> _selectWork() async {
    final passage = await showWorkPicker(context);
    if (passage == null || !mounted) return;
    setState(() {
      currentPassage = passage;
      currentHitIndex = 0;
      showSearchNavigation = false;
      preferOnline = false;
      _currentSourceOffset = null;
      _currentSnippet = '';
      didScrollToMatch = false;
      linesFuture = _cachedJuan(passage, preferOnline: preferOnline);
    });
    _refreshBookmarkState();
    _persistReadingHistory();
  }

  Future<void> _runLocalSearch(SearchSelection selection) async {
    final raw = selection.rawInput.trim();
    final selected = selection.query.trim();
    if (raw.isEmpty || selected.isEmpty) {
      setState(() {
        localSearchQuery = '';
        localSearchRanges = const [];
        didScrollToMatch = true;
      });
      return;
    }
    try {
      await recordSearchSelection(raw, selected);
    } catch (_) {
      // 記錄失敗不影響搜尋。
    }
    if (!mounted) return;

    localSearchQuery = selected;
    localSearchIndex = 0;
    _recomputeLocalSearchRanges();
    didScrollToMatch = localSearchRanges.isEmpty;
    setState(() {});
  }

  /// 以目前的顯示設定重新計算卷內搜尋命中位置。
  ///
  /// 比對在原始經文文字中進行（可跨過校勘標記），
  /// 再將命中的來源位移轉成畫面文字位移。
  void _recomputeLocalSearchRanges() {
    final lines = localSearchLines;
    final needle = localSearchQuery.toLowerCase();
    if (needle.isEmpty || lines.isEmpty) {
      localSearchRanges = const [];
      return;
    }
    final settings = scriptureDisplaySettings;
    final layout = buildScriptureTextLayout(
      lines,
      showLineBeginnings: settings.showLineBeginnings,
      showCollation: settings.showCollation,
    );
    final haystack = buildScriptureSearchSource(lines).toLowerCase();
    final ranges = <({int start, int end})>[];
    var start = 0;
    while (true) {
      final match = haystack.indexOf(needle, start);
      if (match < 0) break;
      ranges.add((
        start: layoutEditableOffsetForSource(
          layout,
          lines,
          match,
          showCollation: settings.showCollation,
        ),
        end: layoutEditableOffsetForSource(
          layout,
          lines,
          match + needle.length,
          showCollation: settings.showCollation,
        ),
      ));
      start = match + needle.length;
    }
    localSearchRanges = ranges;
    if (localSearchIndex >= ranges.length) localSearchIndex = 0;
  }

  void _moveLocalMatch(int direction) {
    if (localSearchRanges.isEmpty) return;
    setState(() {
      localSearchIndex =
          (localSearchIndex + direction + localSearchRanges.length) %
          localSearchRanges.length;
      didScrollToMatch = false;
    });
  }

  List<({int start, int end})> localSearchRanges = const [];

  int? get localSearchStart => localSearchRanges.isEmpty
      ? null
      : localSearchRanges[localSearchIndex].start;

  ({int start, int end})? get localSearchRange =>
      localSearchRanges.isEmpty ? null : localSearchRanges[localSearchIndex];

  void _onDisplaySettingsChanged() {
    if (!mounted) return;
    // 記錄目前視窗頂端所在的文字位置，讓簡繁轉換或字體調整後維持閱讀座標。
    _captureReaderScrollAnchor();
    if (localSearchQuery.isNotEmpty) {
      _recomputeLocalSearchRanges();
    }
    setState(() => didScrollToMatch = false);
  }

  /// 記錄目前視窗頂端所在的文字位置，讓簡繁轉換或字體調整後維持閱讀座標。
  void _captureReaderScrollAnchor() {
    if (!readerScrollController.hasClients) return;
    final viewport = readerScrollController.position.context.storageContext
        .findRenderObject();
    if (viewport is! RenderBox) return;
    final viewportTop = viewport.localToGlobal(Offset.zero).dy;
    for (var index = 0; index < _blockKeys.length; index++) {
      final paragraph = _blockParagraph(index);
      if (paragraph == null) continue;
      final topLeft = paragraph.localToGlobal(Offset.zero);
      if (topLeft.dy > viewportTop ||
          topLeft.dy + paragraph.size.height < viewportTop) {
        continue;
      }
      final position = paragraph.getPositionForOffset(
        Offset(
          topLeft.dx + paragraph.size.width / 2,
          viewportTop.clamp(topLeft.dy, topLeft.dy + paragraph.size.height),
        ),
      );
      final caretOffset = paragraph.getOffsetForCaret(position, Rect.zero);
      _pendingScrollAnchor = (
        blockIndex: index,
        localOffset: position.offset,
        delta: paragraph.localToGlobal(caretOffset).dy - viewportTop,
      );
      return;
    }
  }

  void _syncBlockKeys(int count) {
    while (_blockKeys.length < count) {
      _blockKeys.add(GlobalKey());
    }
    if (_blockKeys.length > count) {
      _blockKeys.removeRange(count, _blockKeys.length);
    }
  }

  /// 區塊 `Text` 元素的渲染節點是外層 `RenderMouseRegion`，
  /// 真正排版的 `RenderParagraph` 掛在內層 `RichText` 上。
  RenderParagraph? _blockParagraph(int blockIndex) {
    if (blockIndex < 0 || blockIndex >= _blockKeys.length) return null;
    final element = _blockKeys[blockIndex].currentContext;
    if (element is! Element) return null;
    RenderParagraph? paragraph;
    void visit(Element node) {
      if (paragraph != null) return;
      final renderObject = node.renderObject;
      if (renderObject is RenderParagraph) {
        paragraph = renderObject;
        return;
      }
      node.visitChildren(visit);
    }

    final own = element.renderObject;
    if (own is RenderParagraph) return own;
    element.visitChildren(visit);
    return paragraph;
  }

  /// 選取範圍 → 整卷 layout 位移。`SelectionArea` 只公開選取兩端的畫面座標，
  /// 因此把兩端分別回推到所屬區塊的局部位移。
  ({int start, int end})? _selectedLayoutRange(
    SelectableRegionState state,
    int headerPrefixLength,
  ) {
    final endpoints = state.selectionEndpoints;
    if (endpoints.isEmpty) return null;
    final box = state.context.findRenderObject();
    if (box is! RenderBox) return null;
    final start = _layoutOffsetAtGlobalPoint(
      box.localToGlobal(endpoints.first.point),
      headerPrefixLength,
    );
    final end = _layoutOffsetAtGlobalPoint(
      box.localToGlobal(endpoints.last.point),
      headerPrefixLength,
    );
    if (start == null || end == null) return null;
    return start <= end ? (start: start, end: end) : (start: end, end: start);
  }

  int? _layoutOffsetAtGlobalPoint(Offset global, int headerPrefixLength) {
    RenderParagraph? nearest;
    var nearestIndex = -1;
    var nearestDistance = double.infinity;
    for (var index = 0; index < _blockKeys.length; index++) {
      final paragraph = _blockParagraph(index);
      if (paragraph == null) continue;
      final top = paragraph.localToGlobal(Offset.zero).dy;
      final bottom = top + paragraph.size.height;
      final distance = global.dy < top
          ? top - global.dy
          : (global.dy > bottom ? global.dy - bottom : 0.0);
      if (distance < nearestDistance) {
        nearestDistance = distance;
        nearest = paragraph;
        nearestIndex = index;
      }
    }
    if (nearest == null || nearestIndex < 0) return null;
    final position = nearest.getPositionForOffset(
      nearest.globalToLocal(global),
    );
    final header = nearestIndex == 0 ? headerPrefixLength : 0;
    final bodyLength = nearest.text.toPlainText().length - header;
    final bodyOffset = (position.offset - header).clamp(0, bodyLength).toInt();
    final base = nearestIndex < _blockOffsetBases.length
        ? _blockOffsetBases[nearestIndex]
        : 0;
    return base + bodyOffset;
  }

  /// 跨區塊選取的複製工具列。文字與卷號都在按鈕觸發時才讀取，
  /// 避免工具列重建時機決定到選不到的文字。
  Widget _buildReaderSelectionToolbar(
    BuildContext context,
    SelectableRegionState state, {
    required ScripturePassage passage,
    required List<ScriptureLine> lines,
    required ScriptureTextLayout layout,
    required int headerPrefixLength,
  }) {
    String selectedText() =>
        _selectedContentText.replaceAll('\uFFFC', '').trimRight();

    ({String? start, String? end}) selectedLineheads() {
      final fallback = passage.linehead ?? firstScriptureLinehead(lines);
      final range = _selectedLayoutRange(state, headerPrefixLength);
      if (range == null) {
        return (start: fallback, end: fallback);
      }
      return (
        start: scriptureLineheadAtLayoutOffset(
          layout,
          lines,
          fallback,
          range.start,
        ),
        end: scriptureLineheadAtLayoutOffset(
          layout,
          lines,
          fallback,
          range.end - 1,
        ),
      );
    }

    final buttonItems = <ContextMenuButtonItem>[
      ContextMenuButtonItem(
        label: '全選',
        onPressed: () {
          state.selectAll(SelectionChangedCause.toolbar);
        },
      ),
      ContextMenuButtonItem(
        label: '查詞典',
        onPressed: () {
          state.hideToolbar();
          final term = selectedText().trim();
          if (term.isNotEmpty) {
            showWorkPicker(
              context,
              initialTab: workPickerDictionaryTab,
              initialDictionaryQuery: term,
            );
          }
        },
      ),
      ContextMenuButtonItem(
        label: '複製',
        onPressed: () async {
          await Clipboard.setData(ClipboardData(text: selectedText()));
          if (context.mounted) {
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(const SnackBar(content: Text('已複製')));
          }
          state.hideToolbar();
        },
      ),
      ContextMenuButtonItem(
        label: '複製引文',
        onPressed: () {
          state.hideToolbar();
          final lineheads = selectedLineheads();
          copySelectedPassage(
            context,
            passage,
            selectedText(),
            selectedStartLinehead: lineheads.start,
            selectedEndLinehead: lineheads.end,
          );
        },
      ),
      ContextMenuButtonItem(
        label: '分享到其他軟件',
        onPressed: () {
          state.hideToolbar();
          SharePlus.instance.share(ShareParams(text: selectedText()));
        },
      ),
    ];

    return AdaptiveTextSelectionToolbar.buttonItems(
      anchors: state.contextMenuAnchors,
      buttonItems: buttonItems,
    );
  }

  int _blockIndexForLayoutOffset(List<int> blockOffsetBases, int layoutOffset) {
    var lo = 0;
    var hi = blockOffsetBases.length - 1;
    while (lo < hi) {
      final mid = (lo + hi + 1) >> 1;
      if (blockOffsetBases[mid] <= layoutOffset) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    return lo;
  }

  /// 依整卷 layout 位移捲到目標位置。
  ///
  /// 目標區塊通常還沒被 `ListView.builder` 建出來，先按平均行高估算，
  /// 跳過去之後下一次 frame 目標塊已掛載，再用量到的實際位置校正。
  void _scheduleReaderScrollTo({
    required int? layoutOffset,
    required int headerPrefixLength,
    required List<ScriptureReaderBlock> blocks,
    required List<int> blockOffsetBases,
    required List<ScriptureLine> lines,
    required double contentWidth,
  }) {
    if (layoutOffset == null || blocks.isEmpty) return;
    final blockIndex = _blockIndexForLayoutOffset(
      blockOffsetBases,
      layoutOffset,
    );
    // 卷題／作譯者與正文共用第一個區塊的 SelectableText，
    // 位移要加上這一段前置文字。
    final localOffset =
        layoutOffset -
        blockOffsetBases[blockIndex] +
        (blockIndex == 0 ? headerPrefixLength : 0);
    _scheduleReaderScroll(
      _ReaderScrollRequest(
        blockIndex: blockIndex,
        localOffset: localOffset,
        blocks: blocks,
        lines: lines,
        contentWidth: contentWidth,
        onDone: () => didScrollToMatch = true,
      ),
    );
  }

  void _scheduleReaderScroll(_ReaderScrollRequest request) {
    final requestId = ++_scrollRequestId;
    void step(int retries) {
      if (!mounted || !readerScrollController.hasClients) return;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted ||
            requestId != _scrollRequestId ||
            !readerScrollController.hasClients) {
          return;
        }
        final position = readerScrollController.position;
        final viewport = position.context.storageContext.findRenderObject();
        if (viewport is! RenderBox) return;
        final paragraph = _blockParagraph(request.blockIndex);
        if (paragraph != null) {
          final pixels = _pixelsForParagraphCaret(paragraph, viewport, request);
          if (pixels != null) {
            position.jumpTo(pixels);
            request.onDone?.call();
            return;
          }
        }
        final estimated = _estimateBlockPixels(request, viewport);
        if (estimated == null) {
          request.onDone?.call();
          return;
        }
        position.jumpTo(estimated);
        if (retries > 0) step(retries - 1);
      });
    }

    step(8);
  }

  double? _pixelsForParagraphCaret(
    RenderParagraph paragraph,
    RenderBox viewport,
    _ReaderScrollRequest request,
  ) {
    if (!readerScrollController.hasClients) return null;
    final length = paragraph.text.toPlainText().length;
    final caretOffset = paragraph.getOffsetForCaret(
      TextPosition(offset: request.localOffset.clamp(0, length).toInt()),
      Rect.zero,
    );
    final caretContentY =
        readerScrollController.offset +
        paragraph.localToGlobal(caretOffset).dy -
        viewport.localToGlobal(Offset.zero).dy;
    final anchorDelta = request.anchorDelta;
    final target = anchorDelta == null
        ? caretContentY - viewport.size.height / 2
        : caretContentY - anchorDelta;
    return target
        .clamp(0.0, readerScrollController.position.maxScrollExtent)
        .toDouble();
  }

  /// 依已建構區塊的實測位置，估算未建構目標區塊的內容座標。
  double? _estimateBlockPixels(
    _ReaderScrollRequest request,
    RenderBox viewport,
  ) {
    if (!readerScrollController.hasClients) return null;
    int? firstBuilt;
    int? lastBuilt;
    double? firstTop;
    double? lastBottom;
    final viewportTop = viewport.localToGlobal(Offset.zero).dy;
    final scroll = readerScrollController.offset;
    for (var index = 0; index < _blockKeys.length; index++) {
      final box = _blockKeys[index].currentContext?.findRenderObject();
      if (box is! RenderBox || !box.hasSize) continue;
      final top = scroll + box.localToGlobal(Offset.zero).dy - viewportTop;
      firstBuilt ??= index;
      firstTop ??= top;
      lastBuilt = index;
      lastBottom = top + box.size.height;
    }
    if (firstBuilt == null ||
        lastBuilt == null ||
        firstTop == null ||
        lastBottom == null) {
      return null;
    }
    final target = request.blockIndex;
    double offset;
    if (target < firstBuilt) {
      offset = firstTop;
      for (var i = firstBuilt - 1; i >= target; i--) {
        offset -= _estimateBlockExtent(request, i);
      }
    } else if (target > lastBuilt) {
      offset = lastBottom;
      for (var i = lastBuilt + 1; i < target; i++) {
        offset += _estimateBlockExtent(request, i);
      }
    } else {
      return null;
    }
    final anchorDelta = request.anchorDelta ?? viewport.size.height / 2;
    return (offset - anchorDelta)
        .clamp(0.0, readerScrollController.position.maxScrollExtent)
        .toDouble();
  }

  double _estimateBlockExtent(_ReaderScrollRequest request, int index) {
    final block = request.blocks[index];
    final settings = scriptureDisplaySettings;
    final lineHeight = settings.fontSize * settings.lineHeight;
    if (block.kind == ScriptureReaderBlockKind.table) {
      var rows = 0;
      for (var i = block.startLine; i < block.endLine; i++) {
        rows += request.lines[i].tableRows.length;
      }
      return rows * (lineHeight + 12) + 8;
    }
    if (block.kind == ScriptureReaderBlockKind.image) {
      return block.lineCount * 220;
    }
    // 普通行依字數估算換行，偈頌行每行只畫一列，兩者要分開算。
    final charsPerLine = (request.contentWidth / settings.fontSize)
        .floor()
        .clamp(1, 1000)
        .toInt();
    var visualLines = 0;
    var pendingCharacters = 0;
    void flushPending() {
      if (pendingCharacters <= 0) return;
      visualLines += (pendingCharacters / charsPerLine).ceil();
      pendingCharacters = 0;
    }

    for (var i = block.startLine; i < block.endLine; i++) {
      final line = request.lines[i];
      if (line.verseCells.isNotEmpty) {
        flushPending();
        visualLines += 1;
      } else {
        pendingCharacters += line.text.length;
      }
    }
    flushPending();
    return visualLines * lineHeight + 4;
  }

  Future<List<ScriptureLine>> _cachedJuan(
    ScripturePassage passage, {
    required bool preferOnline,
  }) {
    final linehead = passage.linehead;
    final workMatch = RegExp(
      r'^([A-Z]+)\d+n(\d+[A-Z]?)_p',
    ).firstMatch(linehead ?? '');
    final work =
        passage.work ??
        (workMatch == null
            ? null
            : '${workMatch.group(1)}${workMatch.group(2)}');
    final juan = passage.juan;
    if (work == null || juan == null) return _loadJuan(passage);
    final key = '$work:$juan:${preferOnline ? 'online' : 'local'}';
    return juanCache.putIfAbsent(key, () async {
      final cached = await scriptureVolumeStore.read(work, juan);
      if (!preferOnline) {
        if (cached != null) return parseScriptureHtml(cached.html);
        final latest = await fetchScriptureVolume(work, juan);
        await scriptureVolumeStore.write(latest);
        return parseScriptureHtml(latest.html);
      }
      try {
        final latest = await fetchScriptureVolume(work, juan);
        // 本地沒有這卷時才留下線上備份；已下載的經卷不被線上內容覆蓋。
        if (cached == null) await scriptureVolumeStore.write(latest);
        return parseScriptureHtml(latest.html);
      } catch (_) {
        if (cached == null) rethrow;
        return parseScriptureHtml(cached.html);
      }
    });
  }

  Future<List<ScriptureLine>> _loadJuan(ScripturePassage passage) async {
    final linehead = passage.linehead;
    final workMatch = RegExp(
      r'^([A-Z]+)\d+n(\d+[A-Z]?)_p',
    ).firstMatch(linehead ?? '');
    final work =
        passage.work ??
        (workMatch == null
            ? null
            : '${workMatch.group(1)}${workMatch.group(2)}');
    if (work == null) {
      throw FormatException('無法從搜尋結果辨識佛典編號：$linehead');
    }
    final juan = passage.juan;
    if (juan == null) {
      throw FormatException('搜尋結果缺少卷數，無法載入完整經卷：$linehead');
    }
    final latest = await fetchScriptureVolume(work, juan);
    await scriptureVolumeStore.write(latest);
    return parseScriptureHtml(latest.html);
  }

  Future<void> _goToHit(int index) async {
    if (index < 0 || index >= widget.searchHits.length) return;
    final passage = widget.searchHits[index];
    setState(() {
      currentPassage = passage;
      currentHitIndex = index;
      preferOnline = _preferOnlineFor(passage);
      _currentSourceOffset = passage.sourceOffset;
      _currentSnippet = passage.snippet;
      didScrollToMatch = false;
      linesFuture = _cachedJuan(passage, preferOnline: preferOnline);
    });
    _refreshBookmarkState();
    _persistReadingHistory();
  }

  void _changeJuan(int direction) {
    final availableJuans = currentPassage.availableJuans;
    final currentJuan = int.tryParse(currentPassage.juan ?? '');
    if (availableJuans.isEmpty || currentJuan == null) return;
    final currentIndex = availableJuans.indexOf(currentJuan);
    final targetIndex = currentIndex + direction;
    if (currentIndex < 0 ||
        targetIndex < 0 ||
        targetIndex >= availableJuans.length) {
      return;
    }
    final targetJuan = availableJuans[targetIndex];
    final reference = currentPassage.reference.replaceFirst(
      RegExp(r'卷\s*\d+'),
      '卷 $targetJuan',
    );
    final passage = currentPassage.copyWith(
      juan: '$targetJuan',
      linehead: null,
      reference: reference,
      snippet: '',
    );
    setState(() {
      currentPassage = passage;
      _currentSourceOffset = null;
      _currentSnippet = '';
      didScrollToMatch = false;
      linesFuture = _cachedJuan(passage, preferOnline: preferOnline);
    });
    _refreshBookmarkState();
    _persistReadingHistory();
  }

  void _selectJuan(int juan) {
    if (juan == int.tryParse(currentPassage.juan ?? '')) return;
    final passage = currentPassage.copyWith(
      juan: '$juan',
      linehead: null,
      reference: '卷 $juan',
      snippet: '',
    );
    setState(() {
      currentPassage = passage;
      _currentSourceOffset = null;
      _currentSnippet = '';
      didScrollToMatch = false;
      linesFuture = _cachedJuan(passage, preferOnline: preferOnline);
    });
    _refreshBookmarkState();
    _persistReadingHistory();
  }

  @override
  void dispose() {
    scriptureDisplaySettings.removeListener(_onDisplaySettingsChanged);
    readerScrollController.dispose();
    localSearchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: scriptureDisplaySettings,
    builder: (context, _) {
      final settings = scriptureDisplaySettings;
      return Scaffold(
        backgroundColor: settings.backgroundColor,
        appBar: AppBar(
          leading: IconButton(
            tooltip: displayText('選擇佛經', context),
            onPressed: _selectWork,
            icon: const Icon(Icons.menu_rounded),
          ),
          title: HomeBrand(
            onTap: () =>
                Navigator.of(context).popUntil((route) => route.isFirst),
            color: settings.textColor,
          ),
          backgroundColor: settings.surfaceColor,
          foregroundColor: settings.textColor,
          actions: [
            IconButton(
              tooltip: displayText('當卷搜尋', context),
              onPressed: () {
                setState(() {
                  showLocalSearch = !showLocalSearch;
                  if (!showLocalSearch) {
                    localSearchController.clear();
                    localSearchQuery = '';
                    localSearchRanges = const [];
                    didScrollToMatch = false;
                  }
                });
              },
              icon: const Icon(Icons.find_in_page_outlined),
            ),
            IconButton(
              tooltip: displayText('書籤', context),
              onPressed: _toggleBookmark,
              onLongPress: _showBookmarks,
              icon: Icon(
                isBookmarked
                    ? Icons.bookmark_added_rounded
                    : Icons.bookmark_add_outlined,
              ),
            ),
            const ScriptDisplayButton(),
            const SettingsButton(),
          ],
        ),
        bottomNavigationBar:
            widget.searchHits.isNotEmpty && showSearchNavigation
            ? SafeArea(
                top: false,
                child: _SearchResultNavigation(
                  current: currentHitIndex,
                  total: widget.searchHits.length,
                  onBack: () => Navigator.of(context).pop(),
                  onClose: () => setState(() => showSearchNavigation = false),
                  onPrevious: currentHitIndex > 0
                      ? () => _goToHit(currentHitIndex - 1)
                      : null,
                  onNext: currentHitIndex < widget.searchHits.length - 1
                      ? () => _goToHit(currentHitIndex + 1)
                      : null,
                ),
              )
            : null,
        body: Stack(
          children: [
            FutureBuilder<List<ScriptureLine>>(
              future: linesFuture,
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (snapshot.hasError) {
                  return NoResults(message: '無法載入經文：${snapshot.error}');
                }
                final lines = snapshot.data ?? const <ScriptureLine>[];
                if (lines.isEmpty) {
                  return const NoResults(message: '找不到此行的經文內容');
                }
                final headerLines = lines
                    .where(
                      (line) =>
                          line.role == ScriptureLineRole.volumeTitle ||
                          line.role == ScriptureLineRole.byline,
                    )
                    .toList();
                final headerPrefixLength = () {
                  // 每個卷題／作譯者行都有一個對齊用的 WidgetSpan，
                  // 且校勘標記必須跟實際渲染一致。
                  final showCollation = scriptureDisplaySettings.showCollation;
                  var len = 0;
                  for (final line in headerLines) {
                    final text = line.text.trim();
                    final markerLength = showCollation
                        ? line.footnotes.fold<int>(
                            0,
                            (length, note) => length + note.label.length + 2,
                          )
                        : 0;
                    len += 1 + text.length + markerLength + 1;
                  }
                  return len;
                }();
                final scriptureLines = lines
                    .where(
                      (line) =>
                          line.role != ScriptureLineRole.volumeTitle &&
                          line.role != ScriptureLineRole.byline,
                    )
                    .toList();
                final settings = scriptureDisplaySettings;
                final layout = buildScriptureTextLayout(
                  scriptureLines,
                  showLineBeginnings: settings.showLineBeginnings,
                  showCollation: settings.showCollation,
                );
                final text = layout.text;
                // 行號可能屬於其他卷或該卷已改版；找不到時退回卷首，
                // 不要讓整卷內容因錨點失效而無法閱讀。
                final hitOccurrence = hitOccurrenceAtIndex(
                  widget.searchHits,
                  currentHitIndex,
                );
                final hitTarget = resolveSearchTargetOffset(
                  layout,
                  scriptureLines,
                  headerLines,
                  currentPassage,
                  widget.query,
                  hitOccurrence,
                );
                final targetOffset = hitTarget.offset;
                _currentSourceOffset = hitTarget.sourceOffset;
                _currentSnippet = hitTarget.snippet;
                final queryRanges = showLocalSearch
                    ? const <({int start, int end})>[]
                    : matchRangesIn(
                        layout.text,
                        widget.query,
                        minStart: targetOffset,
                      );
                localSearchLines = scriptureLines;
                final passage = ScripturePassage(
                  title: currentPassage.title,
                  reference: currentPassage.reference,
                  text: text,
                  linehead: currentPassage.linehead,
                  juan: currentPassage.juan,
                  work: currentPassage.work,
                  availableJuans: currentPassage.availableJuans,
                  lines: scriptureLines,
                  showCollation: settings.showCollation,
                  showLineBeginnings: settings.showLineBeginnings,
                );
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // 固定顯示經名，不顯示卷號或行號等數字字母資訊。
                    Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 680),
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
                          child: Text(
                            displayText(currentPassage.title, context),
                            key: const ValueKey('reader-fixed-title'),
                            textAlign: TextAlign.center,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontFamily: 'Noto Sans TC',
                              fontSize: 18,
                              fontWeight: FontWeight.w600,
                              color: settings.textColor,
                            ),
                          ),
                        ),
                      ),
                    ),
                    Expanded(
                      child: LayoutBuilder(
                        builder: (context, constraints) {
                          final contentWidth =
                              (constraints.maxWidth < 680.0
                                  ? constraints.maxWidth
                                  : 680.0) -
                              32.0;
                          final blocks = buildScriptureReaderBlocks(
                            scriptureLines,
                          );
                          final blockOffsetBases = scriptureBlockOffsetBases(
                            blocks,
                            scriptureLines,
                            layout,
                            settings.showLineBeginnings,
                          );
                          _syncBlockKeys(blocks.length);
                          _blockOffsetBases = blockOffsetBases;
                          if (!didScrollToMatch) {
                            didScrollToMatch = true;
                            final positionKey =
                                '${currentPassage.work}:'
                                '${currentPassage.juan}:'
                                '${_currentSourceOffset ?? currentPassage.linehead ?? ''}';
                            final anchor = _pendingScrollAnchor;
                            _pendingScrollAnchor = null;
                            // 命中字元置中；卷首或卷末由 clamp 自然貼邊。
                            final targetLayoutOffset =
                                showLocalSearch && localSearchRange != null
                                ? layoutLineStartForOffset(
                                    layout,
                                    localSearchRange!.start,
                                  )
                                : targetOffset;
                            WidgetsBinding.instance.addPostFrameCallback((_) {
                              if (!mounted) return;
                              if (_historyPositionKey != positionKey) {
                                _historyPositionKey = positionKey;
                                unawaited(_persistReadingHistory());
                              }
                              if (anchor != null) {
                                // 字體或簡繁設定改變：維持原本視窗頂端的文字。
                                _scheduleReaderScroll(
                                  _ReaderScrollRequest(
                                    blockIndex: anchor.blockIndex,
                                    localOffset: anchor.localOffset,
                                    anchorDelta: anchor.delta,
                                    blocks: blocks,
                                    lines: scriptureLines,
                                    contentWidth: contentWidth,
                                  ),
                                );
                                return;
                              }
                              if (hitTarget.inHeader) {
                                _scheduleReaderScroll(
                                  _ReaderScrollRequest(
                                    blockIndex: 0,
                                    localOffset: 0,
                                    blocks: blocks,
                                    lines: scriptureLines,
                                    contentWidth: contentWidth,
                                  ),
                                );
                                return;
                              }
                              _scheduleReaderScrollTo(
                                layoutOffset: targetLayoutOffset,
                                headerPrefixLength: headerPrefixLength,
                                blocks: blocks,
                                blockOffsetBases: blockOffsetBases,
                                lines: scriptureLines,
                                contentWidth: contentWidth,
                              );
                            });
                          }
                          return SelectionArea(
                            onSelectionChanged: (content) {
                              _selectedContentText = content?.plainText ?? '';
                            },
                            contextMenuBuilder:
                                (context, selectableRegionState) =>
                                    _buildReaderSelectionToolbar(
                                      context,
                                      selectableRegionState,
                                      passage: passage,
                                      lines: scriptureLines,
                                      layout: layout,
                                      headerPrefixLength: headerPrefixLength,
                                    ),
                            child: ListView.builder(
                              controller: readerScrollController,
                              padding: const EdgeInsets.fromLTRB(0, 4, 0, 40),
                              itemCount: blocks.length + 2,
                              itemBuilder: (context, index) {
                                final Widget child;
                                if (index == 0) {
                                  // 卷數調整按鈕放在捲動內容頂端，需固定區域下方靠右。
                                  child = currentPassage.availableJuans.isEmpty
                                      ? const SizedBox.shrink()
                                      : Align(
                                          alignment: Alignment.centerRight,
                                          child: Padding(
                                            padding: const EdgeInsets.only(
                                              bottom: 4,
                                            ),
                                            child: _JuanSelector(
                                              currentJuan: int.tryParse(
                                                currentPassage.juan ?? '',
                                              ),
                                              availableJuans:
                                                  currentPassage.availableJuans,
                                              onChanged: _selectJuan,
                                            ),
                                          ),
                                        );
                                } else if (index > blocks.length) {
                                  child = Padding(
                                    padding: const EdgeInsets.only(top: 32),
                                    child: _JuanNavigation(
                                      currentJuan: int.tryParse(
                                        currentPassage.juan ?? '',
                                      ),
                                      availableJuans:
                                          currentPassage.availableJuans,
                                      onPrevious: () => _changeJuan(-1),
                                      onNext: () => _changeJuan(1),
                                    ),
                                  );
                                } else {
                                  final blockIndex = index - 1;
                                  final block = blocks[blockIndex];
                                  child = _ReaderPassageBlock(
                                    blockKey: _blockKeys[blockIndex],
                                    passage: passage,
                                    headerLines: blockIndex == 0
                                        ? headerLines
                                        : const [],
                                    layoutLineStarts: layout.lineStarts,
                                    query: showLocalSearch
                                        ? localSearchQuery
                                        : widget.query,
                                    localSearchRange: showLocalSearch
                                        ? localSearchRange
                                        : null,
                                    queryRanges: queryRanges,
                                    headerQuery: hitTarget.inHeader
                                        ? widget.query
                                        : '',
                                    sourceLines: scriptureLines,
                                    firstLineIndex: block.startLine,
                                    lineCount: block.lineCount,
                                    offsetBase: blockOffsetBases[blockIndex],
                                    sourceOffsetBase: layout
                                        .lineSourceStarts[block.startLine],
                                    highlightStart: showLocalSearch
                                        ? null
                                        : targetOffset,
                                  );
                                }
                                return Center(
                                  child: ConstrainedBox(
                                    constraints: const BoxConstraints(
                                      maxWidth: 680,
                                    ),
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 16,
                                      ),
                                      child: child,
                                    ),
                                  ),
                                );
                              },
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                );
              },
            ),
            if (showLocalSearch)
              Positioned(
                top: 8,
                left: 12,
                right: 12,
                child: _LocalSearchBar(
                  controller: localSearchController,
                  count: localSearchRanges.isEmpty
                      ? '0 / 0'
                      : '${localSearchIndex + 1} / ${localSearchRanges.length}',
                  onSearch: (selection) =>
                      unawaited(_runLocalSearch(selection)),
                  onPrevious: () => _moveLocalMatch(-1),
                  onNext: () => _moveLocalMatch(1),
                  onClose: () => setState(() {
                    showLocalSearch = false;
                    localSearchController.clear();
                    localSearchQuery = '';
                    localSearchRanges = const [];
                    didScrollToMatch = false;
                  }),
                ),
              ),
          ],
        ),
      );
    },
  );
}

/// 一次「捲到整卷 layout 某位移」的請求。
///
/// `ListView.builder` 尚未建出目標區塊時只能估算，請求會在下一 frame
/// 重新量測，直到目標區塊真的掛載或達到重試上限。
class _ReaderScrollRequest {
  const _ReaderScrollRequest({
    required this.blockIndex,
    required this.localOffset,
    required this.blocks,
    required this.lines,
    required this.contentWidth,
    this.anchorDelta,
    this.onDone,
  });

  final int blockIndex;

  /// 目標字元在目標區塊純文字中的位移。
  final int localOffset;
  final List<ScriptureReaderBlock> blocks;
  final List<ScriptureLine> lines;
  final double contentWidth;

  /// 指定時把目標字元放在距視窗頂端這麼遠的位置，用於維持閱讀座標。
  final double? anchorDelta;
  final VoidCallback? onDone;
}

class _ReaderPassageBlock extends StatefulWidget {
  const _ReaderPassageBlock({
    required this.blockKey,
    required this.passage,
    required this.query,
    required this.sourceLines,
    required this.firstLineIndex,
    required this.lineCount,
    required this.offsetBase,
    required this.sourceOffsetBase,
    this.layoutLineStarts = const [],
    this.headerLines = const [],
    this.localSearchRange,
    this.queryRanges = const [],
    this.headerQuery = '',
    this.highlightStart,
  });

  final GlobalKey blockKey;
  final ScripturePassage passage;
  final String query;

  /// 整卷正文行，與 `layoutLineStarts` 同索引。
  final List<ScriptureLine> sourceLines;

  /// 本區塊首行在 `sourceLines` 中的索引。
  final int firstLineIndex;

  /// 本區塊涵蓋的行數。
  final int lineCount;

  /// 本區塊第一個字元在整卷 layout 純文字中的起始位移。
  final int offsetBase;

  /// 本區塊首行在原始經文文字中的起始位移。
  final int sourceOffsetBase;

  final List<int> layoutLineStarts;
  final List<ScriptureLine> headerLines;
  final ({int start, int end})? localSearchRange;
  final List<({int start, int end})> queryRanges;
  final String headerQuery;
  final int? highlightStart;

  @override
  State<_ReaderPassageBlock> createState() => ReaderPassageBlockState();
}

class ReaderPassageBlockState extends State<_ReaderPassageBlock> {
  /// 卷題／作譯者行的文字片段，校勘標記與正文一致。
  List<InlineSpan> _headerLineSpans(ScriptureLine line) {
    final query = widget.query.trim();
    final showCollation = scriptureDisplaySettings.showCollation;
    final text = line.text.trim();
    if (!showCollation || line.footnotes.isEmpty) {
      return [highlightedPassageText(text, query)];
    }
    final spans = <InlineSpan>[];
    var cursor = 0;
    for (final note in line.footnotes) {
      final noteOffset = note.offset.clamp(cursor, text.length);
      if (noteOffset > cursor) {
        spans.add(
          highlightedPassageText(text.substring(cursor, noteOffset), query),
        );
        cursor = noteOffset;
      }
      final marker = '[${note.label}]';
      if (note.content.isNotEmpty) {
        final recognizer = TapGestureRecognizer()
          ..onTap = () => _showFootnote(note);
        noteRecognizers.add(recognizer);
        spans.add(
          TextSpan(
            text: marker,
            style: headerFootnoteStyle,
            recognizer: recognizer,
          ),
        );
      } else {
        spans.add(TextSpan(text: marker, style: headerFootnoteStyle));
      }
    }
    if (cursor < text.length) {
      spans.add(highlightedPassageText(text.substring(cursor), query));
    }
    return spans;
  }

  void _showFootnote(ScriptureFootnote note) {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(note.label.startsWith('A') ? 'CBETA 修訂註解' : '校勘記'),
        content: DisplaySelectableText(note.content),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('關閉'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    ScriptDisplayScope.dependOn(context);
    final settings = scriptureDisplaySettings;
    return LayoutBuilder(
      builder: (context, constraints) {
        // 用不可見的 WidgetSpan 補齊左側空白，讓單一段落可以置中或靠右，
        // 同時保留文字本身的選取能力。
        WidgetSpan leadingSpacer(double pad) => WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: SizedBox(width: pad < 0 ? 0 : pad, height: 0),
        );

        final headerChildren = <InlineSpan>[];

        for (final line in widget.headerLines) {
          final isNight = settings.isDark;
          final isVolumeTitle = line.role == ScriptureLineRole.volumeTitle;
          final lineStyle = scriptureTextStyle(settings).copyWith(
            color: isNight
                ? (isVolumeTitle
                      ? const Color(0xFF72C5B2)
                      : const Color(0xFFA99A85))
                : (isVolumeTitle
                      ? const Color(0xFF007564)
                      : const Color(0xFF8C7B66)),
            fontSize: settings.fontSize * (isVolumeTitle ? 1.05 : 0.8),
            fontWeight: isVolumeTitle ? FontWeight.w600 : null,
          );
          final contentSpans = _headerLineSpans(line);
          final painter = TextPainter(
            text: TextSpan(style: lineStyle, children: contentSpans),
            textDirection: Directionality.of(context),
            textScaler: MediaQuery.textScalerOf(context),
            maxLines: 1,
          )..layout();
          final textWidth = painter.width;
          painter.dispose();
          headerChildren.add(
            leadingSpacer(
              isVolumeTitle
                  ? (constraints.maxWidth - textWidth) / 2
                  : constraints.maxWidth - textWidth,
            ),
          );
          headerChildren.add(
            TextSpan(
              style: lineStyle,
              children: [
                ...contentSpans,
                const TextSpan(text: '\n'),
              ],
            ),
          );
        }

        final bodySpan = displayInlineSpan(
          interactivePassageText(
            context,
            widget.passage,
            widget.query,
            startAt: widget.highlightStart,
            localSearchRange: widget.localSearchRange,
            queryRanges: widget.queryRanges,
            sourceLines: widget.sourceLines,
            firstLineIndex: widget.firstLineIndex,
            lineCount: widget.lineCount,
            offsetBase: widget.offsetBase,
            sourceOffsetBase: widget.sourceOffsetBase,
            width: constraints.maxWidth,
            recognizers: noteRecognizers,
          ),
        );

        final combinedSpan = flutter_material.TextSpan(
          children: [...headerChildren, bodySpan],
        );

        return flutter_material.Text.rich(
          combinedSpan,
          key: widget.blockKey,
          style: scriptureTextStyle(settings),
        );
      },
    );
  }

  final List<TapGestureRecognizer> noteRecognizers = [];

  @override
  void dispose() {
    for (final recognizer in noteRecognizers) {
      recognizer.dispose();
    }
    super.dispose();
  }
}

class _SearchResultNavigation extends StatelessWidget {
  const _SearchResultNavigation({
    required this.current,
    required this.total,
    required this.onBack,
    required this.onClose,
    required this.onPrevious,
    required this.onNext,
  });

  final int current;
  final int total;
  final VoidCallback onBack;
  final VoidCallback onClose;
  final VoidCallback? onPrevious;
  final VoidCallback? onNext;

  @override
  Widget build(BuildContext context) => Material(
    color: scriptureDisplaySettings.surfaceColor,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        children: [
          TextButton.icon(
            onPressed: onBack,
            icon: const Icon(Icons.chevron_left_rounded, size: 18),
            label: const Text('搜尋結果'),
          ),
          const Spacer(),
          IconButton(
            tooltip: displayText('上一筆', context),
            onPressed: onPrevious,
            icon: const Icon(Icons.keyboard_arrow_up_rounded),
          ),
          Text('${current + 1} / $total 筆'),
          IconButton(
            tooltip: displayText('下一筆', context),
            onPressed: onNext,
            icon: const Icon(Icons.keyboard_arrow_down_rounded),
          ),
          IconButton(
            tooltip: displayText('關閉搜尋導航', context),
            onPressed: onClose,
            icon: const Icon(Icons.close_rounded),
          ),
        ],
      ),
    ),
  );
}

class _JuanNavigation extends StatelessWidget {
  const _JuanNavigation({
    required this.currentJuan,
    required this.availableJuans,
    required this.onPrevious,
    required this.onNext,
  });

  final int? currentJuan;
  final List<int> availableJuans;
  final VoidCallback onPrevious;
  final VoidCallback onNext;

  @override
  Widget build(BuildContext context) {
    final currentIndex = availableJuans.indexOf(currentJuan ?? -1);
    final canNavigate = currentIndex >= 0 && availableJuans.length > 1;
    return Row(
      children: [
        OutlinedButton.icon(
          onPressed: canNavigate && currentIndex > 0 ? onPrevious : null,
          icon: const Icon(Icons.chevron_left_rounded),
          label: const Text('上一卷'),
        ),
        const Spacer(),
        Text(
          currentIndex < 0
              ? '第 ${currentJuan ?? '-'} 卷'
              : '第 ${currentIndex + 1} / ${availableJuans.length} 卷',
        ),
        const Spacer(),
        OutlinedButton.icon(
          onPressed: canNavigate && currentIndex < availableJuans.length - 1
              ? onNext
              : null,
          icon: const Icon(Icons.chevron_right_rounded),
          label: const Text('下一卷'),
        ),
      ],
    );
  }
}

class _JuanSelector extends StatelessWidget {
  const _JuanSelector({
    required this.currentJuan,
    required this.availableJuans,
    required this.onChanged,
  });

  final int? currentJuan;
  final List<int> availableJuans;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      const Text('卷：'),
      DropdownButton<int>(
        value: availableJuans.contains(currentJuan)
            ? currentJuan
            : availableJuans.first,
        underline: const SizedBox.shrink(),
        items: [
          for (final juan in availableJuans)
            DropdownMenuItem(value: juan, child: Text('第 $juan 卷')),
        ],
        onChanged: (juan) {
          if (juan != null) onChanged(juan);
        },
      ),
    ],
  );
}

class _LocalSearchBar extends StatelessWidget {
  const _LocalSearchBar({
    required this.controller,
    required this.count,
    required this.onSearch,
    required this.onPrevious,
    required this.onNext,
    required this.onClose,
  });

  final TextEditingController controller;
  final String count;
  final ValueChanged<SearchSelection> onSearch;
  final VoidCallback onPrevious;
  final VoidCallback onNext;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) => Material(
    elevation: 6,
    color: scriptureDisplaySettings.surfaceColor,
    borderRadius: BorderRadius.circular(8),
    child: Row(
      children: [
        Expanded(
          child: SearchInput(
            controller: controller,
            autofocus: true,
            onSearch: onSearch,
            textBuilder: (text) => displayText(text, context),
            displayListenable: scriptureDisplaySettings,
            decoration: InputDecoration(
              hintText: displayText('在此卷中搜尋…', context),
              border: InputBorder.none,
              contentPadding: const EdgeInsets.symmetric(horizontal: 14),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Text(count),
        ),
        IconButton(
          tooltip: displayText('上一筆', context),
          onPressed: onPrevious,
          icon: const Icon(Icons.keyboard_arrow_up_rounded),
        ),
        IconButton(
          tooltip: displayText('下一筆', context),
          onPressed: onNext,
          icon: const Icon(Icons.keyboard_arrow_down_rounded),
        ),
        IconButton(
          tooltip: displayText('關閉', context),
          onPressed: onClose,
          icon: const Icon(Icons.close_rounded),
        ),
      ],
    ),
  );
}
