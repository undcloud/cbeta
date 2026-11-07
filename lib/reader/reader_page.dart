import 'dart:async';
import 'package:flutter/material.dart' as flutter_material;
import 'package:flutter/material.dart' hide Text;
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart' show RenderParagraph, ScrollDirection;
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';
import '../scripture/cache.dart';
import '../scripture/models.dart';
import '../scripture/parse_runner.dart';
import '../scripture/reader_blocks.dart';
import '../scripture/source_text.dart';
import '../search/candidates.dart';
import '../search/history.dart';
import '../search/offline_preference.dart';
import '../search/search_input.dart';
import '../settings/display_settings.dart';
import '../download/download_status_ui.dart';
import 'reader_citations.dart';
import 'reader_layout.dart';
import 'reader_store.dart';
import '../settings/display_settings_ui.dart';
import '../widgets/display_text.dart';
import '../widgets/result_widgets.dart';
import '../work_picker/work_picker_page.dart';

/// 最近閱讀／書籤回到經卷時，把目標行放在視窗頂端略下方；
/// 使用者離開前記錄的正是視窗頂端那一行。
const double _archiveAnchorTopInset = 12;

/// 離線模式要開的卷不在本地。
class OfflineVolumeUnavailable implements Exception {
  const OfflineVolumeUnavailable({this.work, this.juan});

  final String? work;
  final String? juan;

  String get volumeLabel {
    final work = (this.work ?? '').trim();
    final juan = (this.juan ?? '').trim();
    if (work.isEmpty && juan.isEmpty) return '此卷';
    if (juan.isEmpty) return '《$work》';
    if (work.isEmpty) return '卷 $juan';
    return '《$work》卷 $juan';
  }

  @override
  String toString() => '本地沒有已下載的$volumeLabel';
}

/// 聯網模式取卷失敗；[hasLocalCopy] 讓閱讀器決定要不要提供離線替代。
class ScriptureOnlineLoadFailure implements Exception {
  const ScriptureOnlineLoadFailure({
    required this.work,
    required this.juan,
    required this.hasLocalCopy,
    required this.cause,
  });

  final String? work;
  final String? juan;
  final bool hasLocalCopy;
  final Object cause;

  String get volumeLabel {
    final work = (this.work ?? '').trim();
    final juan = (this.juan ?? '').trim();
    if (work.isEmpty && juan.isEmpty) return '此卷';
    if (juan.isEmpty) return '《$work》';
    if (work.isEmpty) return '卷 $juan';
    return '《$work》卷 $juan';
  }

  @override
  String toString() => '無法從 CBETA 載入$volumeLabel：$cause';
}

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

class ScriptureReaderPageState extends State<ScriptureReaderPage>
    with WidgetsBindingObserver {
  final readerScrollController = ScrollController();
  final List<GlobalKey> _blockKeys = [];
  List<int> _blockOffsetBases = const [];
  String _selectedContentText = '';
  int _scrollRequestId = 0;
  ({int blockIndex, int localOffset, double delta})? _pendingScrollAnchor;
  final localSearchController = TextEditingController();

  /// 目前畫面要顯示的卷；換卷時只保留當前這一卷，避免快速翻卷把整卷解析
  /// 結果留在記憶體。回看上一卷會重新讀檔解析。
  static const int _juanCacheLimit = 1;
  final Map<String, Future<List<ScriptureLine>>> juanCache = {};
  String? _activeJuanKey;
  bool preferOnline = false;
  bool _lastOfflineMode = false;

  /// 最近閱讀／書籤／AI 段落等「非搜尋命中」入口，定位時把目標行貼齊視窗頂端。
  bool _archiveAnchorMode = true;
  int? _currentSourceOffset;
  String _currentSnippet = '';
  String? _historyPositionKey;

  /// 目前畫面的整卷 layout 與卷首前置資訊，捲動結束後用來換算「視窗頂端」
  /// 實際落在哪一行；只有 `build` 會更新，其他時刻只讀。
  ScriptureTextLayout? _currentLayout;
  List<ScriptureLine> _currentBodyLines = const [];

  /// 使用者捲動後視窗頂端所在行的錨點；沒有手動捲動過時為 null，
  /// 此时「最近閱讀」記錄的是進入经文時的那個位置。
  String? _anchorLinehead;
  int? _anchorSourceOffset;
  String _anchorSnippet = '';
  bool _userScrollActive = false;
  Timer? _anchorFlushTimer;

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
    preferOnline = !offlineMode;
    _lastOfflineMode = offlineMode;
    _archiveAnchorMode = widget.searchHits.isEmpty;
    linesFuture = _cachedJuan(currentPassage, preferOnline: preferOnline);
    _refreshBookmarkState();
    _persistReadingHistory();
    offlineModeListenable.addListener(_onOfflineModeChanged);
    scriptureDisplaySettings.addListener(_onDisplaySettingsChanged);
    WidgetsBinding.instance.addObserver(this);
  }

  void _onOfflineModeChanged() {
    if (!mounted || _lastOfflineMode == offlineMode) return;
    _lastOfflineMode = offlineMode;
    _reloadForSourceMode();
  }

  /// 模式切換後重新取源。失敗的 Future 已從 `juanCache` 移除，重試才會
  /// 真的再打一次 API。
  void _reloadForSourceMode() {
    juanCache.clear();
    final online = !offlineMode;
    final nextFuture = _cachedJuan(currentPassage, preferOnline: online);
    setState(() {
      preferOnline = online;
      _releaseRenderedJuan();
      linesFuture = nextFuture;
    });
    _resetReadingAnchor();
    _refreshBookmarkState();
    _persistReadingHistory();
  }

  ScripturePassage _positionedPassage() => currentPassage.copyWith(
    linehead: _anchorLinehead ?? currentPassage.linehead,
    sourceOffset:
        _anchorSourceOffset ??
        _currentSourceOffset ??
        currentPassage.sourceOffset,
    snippet: _anchorSnippet.isNotEmpty
        ? _anchorSnippet
        : (_currentSnippet.isEmpty ? currentPassage.snippet : _currentSnippet),
  );

  /// 最近閱讀／上次閱讀位置寫入時用的位置戳記：優先使用使用者實際看到的
  /// 視窗頂端行，其次才是進入當下解析到的搜尋命中位置。
  String _currentPositionKey() {
    final position =
        _anchorLinehead ??
        _currentSourceOffset?.toString() ??
        currentPassage.linehead ??
        '';
    return '${currentPassage.work}:${currentPassage.juan}:$position';
  }

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

  void _resetReadingAnchor() {
    _anchorFlushTimer?.cancel();
    _anchorLinehead = null;
    _anchorSourceOffset = null;
    _anchorSnippet = '';
  }

  void _openBookmark(ReaderBookmark bookmark) {
    final passage = bookmark.toPassage();
    final online = !offlineMode;
    final nextFuture = _cachedJuan(passage, preferOnline: online);
    setState(() {
      currentPassage = passage;
      currentHitIndex = 0;
      showSearchNavigation = false;
      _archiveAnchorMode = true;
      preferOnline = online;
      _currentSourceOffset = passage.sourceOffset;
      _currentSnippet = passage.snippet;
      didScrollToMatch = false;
      if (!identical(nextFuture, linesFuture)) _releaseRenderedJuan();
      linesFuture = nextFuture;
    });
    _resetReadingAnchor();
    _refreshBookmarkState();
    _persistReadingHistory();
  }

  Future<void> _selectWork() async {
    final passage = await showWorkPicker(context);
    if (passage == null || !mounted) return;
    final online = !offlineMode;
    final nextFuture = _cachedJuan(passage, preferOnline: online);
    setState(() {
      currentPassage = passage;
      currentHitIndex = 0;
      showSearchNavigation = false;
      _archiveAnchorMode = true;
      preferOnline = online;
      _currentSourceOffset = null;
      _currentSnippet = '';
      didScrollToMatch = false;
      if (!identical(nextFuture, linesFuture)) _releaseRenderedJuan();
      linesFuture = nextFuture;
    });
    _resetReadingAnchor();
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

  /// 找出 `layoutOffset` 落在正文哪一行（`lineStarts` 依序排列，二分查找，
  /// 長卷逐線掃描會在每次捲動結束時都變成明顯的卡頓來源）。
  int? _lineIndexForLayoutOffset(ScriptureTextLayout layout, int layoutOffset) {
    final starts = layout.lineStarts;
    if (starts.isEmpty) return null;
    var lo = 0;
    var hi = starts.length - 1;
    while (lo < hi) {
      final mid = (lo + hi + 1) >> 1;
      if (starts[mid] <= layoutOffset) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    return lo;
  }

  /// 把目前視窗頂端那一行記成閱讀錨點；找不到可量測的排版節點時不更新。
  bool _updateReadingAnchorFromViewportTop() {
    final layout = _currentLayout;
    final lines = _currentBodyLines;
    if (layout == null || lines.isEmpty || _blockOffsetBases.isEmpty) {
      return false;
    }
    if (!readerScrollController.hasClients) return false;
    final viewport = readerScrollController.position.context.storageContext
        .findRenderObject();
    if (viewport is! RenderBox) return false;
    final viewportTop = viewport.localToGlobal(Offset.zero).dy;
    final layoutOffset = _layoutOffsetAtGlobalPoint(Offset(0, viewportTop));
    if (layoutOffset == null) return false;
    final lineIndex = _lineIndexForLayoutOffset(layout, layoutOffset);
    if (lineIndex == null) return false;
    final linehead = scriptureLineheadAtLayoutOffset(
      layout,
      lines,
      currentPassage.linehead,
      layoutOffset,
    );
    final sourceOffset = layout.lineSourceStarts[lineIndex];
    final lineText = lines[lineIndex].text;
    final snippetLength = lineText.length < 24 ? lineText.length : 24;
    _anchorLinehead = linehead;
    _anchorSourceOffset = sourceOffset;
    _anchorSnippet = lineText.substring(0, snippetLength);
    return true;
  }

  /// 捲動停止後延遲一段时间再記錄，避免慣性滑動期間每格都觸發寫入。
  void _scheduleReadingAnchorFlush() {
    _anchorFlushTimer?.cancel();
    _anchorFlushTimer = Timer(const Duration(milliseconds: 400), () {
      if (!mounted) return;
      _flushReadingAnchor();
    });
  }

  void _flushReadingAnchor() {
    if (!_updateReadingAnchorFromViewportTop()) return;
    final positionKey = _currentPositionKey();
    if (_historyPositionKey == positionKey) return;
    _historyPositionKey = positionKey;
    unawaited(_persistReadingHistory());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused) {
      _anchorFlushTimer?.cancel();
      _flushReadingAnchor();
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

  /// 換卷時放掉上一卷的整卷 layout、解析結果與區塊 key，讓 GC 能立即回收；
  /// FutureBuilder 也會因為換了 key 而重建，不再保留舊 snapshot 的經文。
  void _releaseRenderedJuan() {
    _currentLayout = null;
    _currentBodyLines = const [];
    _blockOffsetBases = const [];
    _blockKeys.clear();
    localSearchLines = const [];
    localSearchRanges = const [];
    _selectedContentText = '';
    _pendingScrollAnchor = null;
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
  ({int start, int end})? _selectedLayoutRange(SelectableRegionState state) {
    final endpoints = state.selectionEndpoints;
    if (endpoints.isEmpty) return null;
    final box = state.context.findRenderObject();
    if (box is! RenderBox) return null;
    final start = _layoutOffsetAtGlobalPoint(
      box.localToGlobal(endpoints.first.point),
    );
    final end = _layoutOffsetAtGlobalPoint(
      box.localToGlobal(endpoints.last.point),
    );
    if (start == null || end == null) return null;
    return start <= end ? (start: start, end: end) : (start: end, end: start);
  }

  int? _layoutOffsetAtGlobalPoint(Offset global) {
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
    final bodyLength = nearest.text.toPlainText().length;
    final bodyOffset = position.offset.clamp(0, bodyLength).toInt();
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
  }) {
    String selectedText() =>
        _selectedContentText.replaceAll('\uFFFC', '').trimRight();

    ({String? start, String? end}) selectedLineheads() {
      final fallback = passage.linehead ?? firstScriptureLinehead(lines);
      final range = _selectedLayoutRange(state);
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
    required List<ScriptureReaderBlock> blocks,
    required List<int> blockOffsetBases,
    required List<ScriptureLine> lines,
    required double contentWidth,
    double? anchorDelta,
  }) {
    if (layoutOffset == null || blocks.isEmpty) return;
    final blockIndex = _blockIndexForLayoutOffset(
      blockOffsetBases,
      layoutOffset,
    );
    final localOffset = layoutOffset - blockOffsetBases[blockIndex];
    _scheduleReaderScroll(
      _ReaderScrollRequest(
        blockIndex: blockIndex,
        localOffset: localOffset,
        anchorDelta: anchorDelta,
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
    if (work == null || juan == null) {
      _activeJuanKey = null;
      return _loadJuan(passage, preferOnline: preferOnline);
    }
    final key = '$work:$juan:${preferOnline ? 'online' : 'local'}';
    _activeJuanKey = key;
    final existing = juanCache.remove(key);
    if (existing != null) {
      // 重新插入讓它成為最近使用的一卷，淘汰時才不會先丟掉剛看過的內容。
      juanCache[key] = existing;
      return existing;
    }
    final future = _loadCachedJuan(
      work: work,
      juan: juan,
      preferOnline: preferOnline,
      key: key,
    );
    juanCache[key] = future;
    while (juanCache.length > _juanCacheLimit) {
      juanCache.remove(juanCache.keys.first);
    }
    return future;
  }

  Future<List<ScriptureLine>> _loadCachedJuan({
    required String work,
    required String juan,
    required bool preferOnline,
    required String key,
  }) {
    late final Future<List<ScriptureLine>> future;
    future = () async {
      try {
        final cached = await scriptureVolumeStore.read(work, juan);
        final List<ScriptureLine> lines;
        if (!preferOnline) {
          if (cached == null) {
            throw OfflineVolumeUnavailable(work: work, juan: juan);
          }
          lines = await parseScriptureHtmlAsync(cached.html);
        } else {
          try {
            final latest = await fetchScriptureVolume(work, juan);
            // 本地沒有這卷時才留下線上備份；已下載的經卷不被線上內容覆蓋。
            if (cached == null) await scriptureVolumeStore.write(latest);
            lines = await parseScriptureHtmlAsync(latest.html);
          } catch (error) {
            // 聯網模式不靜默回退本地；由使用者決定是否切換離線模式。
            throw ScriptureOnlineLoadFailure(
              work: work,
              juan: juan,
              hasLocalCopy: cached != null,
              cause: error,
            );
          }
        }
        // 使用者已翻到別的卷：結果仍交給即將卸載的 FutureBuilder，但不再
        // 留在快取裡，避免快速翻卷時同時保留多份整卷經文。
        if (_activeJuanKey != key) _removeJuanCacheEntry(key, future);
        return lines;
      } catch (_) {
        // Future 失敗後留在快取裡會讓「重試」永遠拿到同一個錯誤。
        _removeJuanCacheEntry(key, future);
        rethrow;
      }
    }();
    return future;
  }

  void _removeJuanCacheEntry(String key, Future<List<ScriptureLine>> future) {
    if (identical(juanCache[key], future)) juanCache.remove(key);
  }

  Future<List<ScriptureLine>> _loadJuan(
    ScripturePassage passage, {
    required bool preferOnline,
  }) async {
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
    final cached = await scriptureVolumeStore.read(work, juan);
    if (!preferOnline) {
      if (cached != null) return parseScriptureHtmlAsync(cached.html);
      throw OfflineVolumeUnavailable(work: work, juan: juan);
    }
    try {
      final latest = await fetchScriptureVolume(work, juan);
      if (cached == null) await scriptureVolumeStore.write(latest);
      return parseScriptureHtmlAsync(latest.html);
    } catch (error) {
      throw ScriptureOnlineLoadFailure(
        work: work,
        juan: juan,
        hasLocalCopy: cached != null,
        cause: error,
      );
    }
  }

  Future<void> _goToHit(int index) async {
    if (index < 0 || index >= widget.searchHits.length) return;
    final passage = widget.searchHits[index];
    final online = !offlineMode;
    final nextFuture = _cachedJuan(passage, preferOnline: online);
    setState(() {
      currentPassage = passage;
      currentHitIndex = index;
      _archiveAnchorMode = false;
      preferOnline = online;
      _currentSourceOffset = passage.sourceOffset;
      _currentSnippet = passage.snippet;
      didScrollToMatch = false;
      if (!identical(nextFuture, linesFuture)) _releaseRenderedJuan();
      linesFuture = nextFuture;
    });
    _resetReadingAnchor();
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
    final nextFuture = _cachedJuan(passage, preferOnline: preferOnline);
    setState(() {
      currentPassage = passage;
      _currentSourceOffset = null;
      _currentSnippet = '';
      didScrollToMatch = false;
      if (!identical(nextFuture, linesFuture)) _releaseRenderedJuan();
      linesFuture = nextFuture;
    });
    _resetReadingAnchor();
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
    final nextFuture = _cachedJuan(passage, preferOnline: preferOnline);
    setState(() {
      currentPassage = passage;
      _currentSourceOffset = null;
      _currentSnippet = '';
      didScrollToMatch = false;
      if (!identical(nextFuture, linesFuture)) _releaseRenderedJuan();
      linesFuture = nextFuture;
    });
    _resetReadingAnchor();
    _refreshBookmarkState();
    _persistReadingHistory();
  }

  @override
  void dispose() {
    // 位置記錄在「使用者真的捲動停下」與「App 退到背景」時就會寫入；
    // dispose 是同步呼叫，沒辦法在這裡等非同步寫入完成，硬排一個 unawaited
    // 的存檔反而會在 widget 已銷毀後才回呼、污染下一筆測試，所以只取消計時器。
    _anchorFlushTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    offlineModeListenable.removeListener(_onOfflineModeChanged);
    scriptureDisplaySettings.removeListener(_onDisplaySettingsChanged);
    juanCache.clear();
    _activeJuanKey = null;
    readerScrollController.dispose();
    localSearchController.dispose();
    super.dispose();
  }

  void _retryLoad() {
    juanCache.clear();
    final online = !offlineMode;
    final nextFuture = _cachedJuan(currentPassage, preferOnline: online);
    setState(() {
      preferOnline = online;
      _releaseRenderedJuan();
      linesFuture = nextFuture;
    });
  }

  void _openDownloads() {
    unawaited(showDownloadStatusPanel(context));
  }

  Widget _buildLoadError(Object? error) {
    if (error is OfflineVolumeUnavailable) {
      return NoResults(
        message: '${error.toString()}\n請先下載此卷，或切換到聯網閱讀。',
        actions: [
          FilledButton.tonal(
            onPressed: _openDownloads,
            child: const Text('前往下載'),
          ),
          TextButton(
            onPressed: () => unawaited(setOfflineMode(false)),
            child: const Text('切換到聯網'),
          ),
        ],
      );
    }
    if (error is ScriptureOnlineLoadFailure) {
      return NoResults(
        message: error.hasLocalCopy
            ? '無法連接 CBETA 伺服器：${error.cause}\n本地已有這卷，可以改用離線閱讀。'
            : '無法從 CBETA 載入${error.volumeLabel}：${error.cause}',
        actions: [
          FilledButton.tonal(onPressed: _retryLoad, child: const Text('重試')),
          if (error.hasLocalCopy)
            TextButton(
              onPressed: () => unawaited(setOfflineMode(true)),
              child: const Text('改用離線閱讀'),
            )
          else
            TextButton(onPressed: _openDownloads, child: const Text('前往下載')),
        ],
      );
    }
    return NoResults(message: '無法載入經文：$error');
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
              // 換卷時重建 state，舊 snapshot 不會繼續持有上一卷的經文。
              key: ObjectKey(linesFuture),
              future: linesFuture,
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (snapshot.hasError) {
                  return _buildLoadError(snapshot.error);
                }
                // 卷題與作譯者都留在正文原位：卷題置中變色、作譯者靠右字小。
                final scriptureLines = snapshot.data ?? const <ScriptureLine>[];
                if (scriptureLines.isEmpty) {
                  return const NoResults(message: '找不到此行的經文內容');
                }
                final settings = scriptureDisplaySettings;
                final layout = buildScriptureTextLayout(
                  scriptureLines,
                  showLineBeginnings: settings.showLineBeginnings,
                  showCollation: settings.showCollation,
                );
                final text = layout.text;
                _currentLayout = layout;
                _currentBodyLines = scriptureLines;
                // 行號可能屬於其他卷或該卷已改版；找不到時退回卷首，
                // 不要讓整卷內容因錨點失效而無法閱讀。
                final hitOccurrence = hitOccurrenceAtIndex(
                  widget.searchHits,
                  currentHitIndex,
                );
                // 最近閱讀／書籤：先驗證存檔位移與 snippet，對不上才退回行號。
                // 離線壓縮檔的行號常只標到段首，存檔位移通常更精確。
                final archiveEntry = _archiveAnchorMode && !showLocalSearch;
                final hitTarget = resolveSearchTargetOffset(
                  layout,
                  scriptureLines,
                  currentPassage,
                  widget.query,
                  hitOccurrence,
                  archiveAnchor: archiveEntry,
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
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
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
                              const SizedBox(height: 2),
                              _ReaderSourceBadge(online: preferOnline),
                            ],
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
                            final positionKey = _currentPositionKey();
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
                              _scheduleReaderScrollTo(
                                layoutOffset: targetLayoutOffset,
                                blocks: blocks,
                                blockOffsetBases: blockOffsetBases,
                                lines: scriptureLines,
                                contentWidth: contentWidth,
                                anchorDelta: archiveEntry
                                    ? _archiveAnchorTopInset
                                    : null,
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
                                    ),
                            child: NotificationListener<ScrollNotification>(
                              onNotification: (notification) {
                                // 只在使用者真的拖動／慣性捲動後記錄視窗頂端；
                                // 程式化的 jumpTo 不算「換了一個閱讀位置」。
                                if (notification is UserScrollNotification) {
                                  if (notification.direction !=
                                      ScrollDirection.idle) {
                                    _userScrollActive = true;
                                  }
                                } else if (notification
                                        is ScrollEndNotification &&
                                    _userScrollActive) {
                                  _userScrollActive = false;
                                  _scheduleReadingAnchorFlush();
                                }
                                return false;
                              },
                              child: ListView.builder(
                                controller: readerScrollController,
                                padding: const EdgeInsets.fromLTRB(0, 4, 0, 40),
                                itemCount: blocks.length + 2,
                                itemBuilder: (context, index) {
                                  final Widget child;
                                  if (index == 0) {
                                    // 卷數調整按鈕放在捲動內容頂端，需固定區域下方靠右。
                                    child =
                                        currentPassage.availableJuans.isEmpty
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
                                                availableJuans: currentPassage
                                                    .availableJuans,
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
                                      layoutLineStarts: layout.lineStarts,
                                      query: showLocalSearch
                                          ? localSearchQuery
                                          : widget.query,
                                      localSearchRange: showLocalSearch
                                          ? localSearchRange
                                          : null,
                                      queryRanges: queryRanges,
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
    this.localSearchRange,
    this.queryRanges = const [],
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
  final ({int start, int end})? localSearchRange;
  final List<({int start, int end})> queryRanges;
  final int? highlightStart;

  @override
  State<_ReaderPassageBlock> createState() => ReaderPassageBlockState();
}

class ReaderPassageBlockState extends State<_ReaderPassageBlock> {
  @override
  Widget build(BuildContext context) {
    ScriptDisplayScope.dependOn(context);
    final settings = scriptureDisplaySettings;
    return LayoutBuilder(
      builder: (context, constraints) {
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

        return flutter_material.Text.rich(
          bodySpan,
          key: widget.blockKey,
          style: scriptureTextStyle(settings),
          // 區塊用滿可用寬度，行內留白才能按父寬精確置中；
          // 否則短段落會先縮成內容寬，再被外層 Center 二次置中。
          textWidthBasis: TextWidthBasis.parent,
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

/// 經文來源只做低調提示，不打斷閱讀。
class _ReaderSourceBadge extends StatelessWidget {
  const _ReaderSourceBadge({required this.online});

  final bool online;

  @override
  Widget build(BuildContext context) {
    final settings = scriptureDisplaySettings;
    return Tooltip(
      message: online ? '經文來源：CBETA 線上' : '經文來源：本地下載',
      child: Text(
        displayText(online ? '線上經文' : '離線經文', context),
        key: const ValueKey('reader-source-badge'),
        maxLines: 1,
        style: TextStyle(
          fontFamily: 'Noto Sans TC',
          fontSize: 10,
          letterSpacing: 0.4,
          color: settings.textColor.withValues(alpha: 0.42),
        ),
      ),
    );
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
