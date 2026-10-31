import 'dart:async';
import 'package:flutter/material.dart' hide Text;
import 'package:flutter/foundation.dart';
import '../scripture/models.dart';
import '../scripture/offline_scan.dart';
import '../search/candidates.dart';
import '../search/conversion.dart';
import '../search/history.dart';
import '../search/search_input.dart';
import '../settings/display_settings.dart';
import '../reader/reader_page.dart';
import 'search_api.dart';
import '../settings/display_settings_ui.dart';
import '../widgets/display_text.dart';
import '../widgets/result_widgets.dart';

class FullTextSearchPage extends StatefulWidget {
  const FullTextSearchPage({super.key, required this.initialQuery});

  final String initialQuery;

  @override
  State<FullTextSearchPage> createState() => _FullTextSearchPageState();
}

class FullTextSearchSnapshot {
  const FullTextSearchSnapshot({
    required this.results,
    required this.nextStart,
    required this.totalFound,
    required this.totalTermHits,
    this.hasMore = false,
  });

  final List<ScriptureSearchResult> results;
  final int nextStart;
  final int totalFound;
  final int totalTermHits;
  final bool hasMore;
}

class FullTextSearchCache {
  static final Map<String, FullTextSearchSnapshot> _snapshots = {};

  static FullTextSearchSnapshot? get(String query) => _snapshots[query];
  static void remember(
    String query, {
    required List<ScriptureSearchResult> results,
    required int nextStart,
    required int totalFound,
    required int totalTermHits,
    bool hasMore = false,
  }) {
    _snapshots[query] = FullTextSearchSnapshot(
      results: List.unmodifiable(results),
      nextStart: nextStart,
      totalFound: totalFound,
      totalTermHits: totalTermHits,
      hasMore: hasMore,
    );
  }

  static void debugReset() => _snapshots.clear();
}

/// 清空全文搜尋結果快取（僅供測試使用）。
@visibleForTesting
void resetFullTextSearchCache() => FullTextSearchCache.debugReset();

class _FullTextSearchPageState extends State<FullTextSearchPage> {
  late final TextEditingController controller;
  final ScrollController scrollController = ScrollController();
  List<ScriptureSearchResult> results = const [];
  String submittedQuery = '';
  String? error;
  bool loading = false;
  bool loadingMore = false;
  bool offlineMode = false;
  bool hasMore = false;
  int nextStart = 0;
  int totalFound = 0;
  int totalTermHits = 0;
  int scannedVolumes = 0;
  int totalVolumes = 0;
  OfflineScanSession? offlineSession;

  @override
  void initState() {
    super.initState();
    controller = TextEditingController(text: widget.initialQuery);
    scrollController.addListener(_onScroll);
    if (widget.initialQuery.trim().isNotEmpty) {
      final query = SimplifiedTraditionalConverter.convert(
        widget.initialQuery.trim(),
      );
      final cached = FullTextSearchCache.get(query);
      if (cached != null) {
        submittedQuery = query;
        results = cached.results;
        nextStart = cached.nextStart;
        totalFound = cached.totalFound;
        totalTermHits = cached.totalTermHits;
        hasMore = cached.hasMore;
      } else {
        WidgetsBinding.instance.addPostFrameCallback((_) => search());
      }
    }
  }

  void _onScroll() {
    if (scrollController.hasClients &&
        scrollController.position.extentAfter < 400 &&
        hasMore &&
        !loading &&
        !loadingMore) {
      setState(() => loadingMore = true);
      _loadPage(submittedQuery, nextStart);
    }
  }

  Future<void> search() async {
    final raw = controller.text.trim();
    if (raw.isEmpty) return;
    final query = await preferredQueryForInput(raw);
    await _runSearch(raw, query);
  }

  Future<void> _onSearchSelection(SearchSelection selection) async {
    final raw = selection.rawInput.trim();
    if (raw.isEmpty) return;
    await _runSearch(raw, selection.query);
  }

  Future<void> _runSearch(String raw, String query) async {
    if (raw.isEmpty || query.isEmpty) return;
    try {
      await recordSearchSelection(raw, query);
    } catch (_) {
      // 記錄失敗不影響搜尋。
    }
    if (!mounted) return;
    FocusScope.of(context).unfocus();
    if (kIsWeb) {
      setState(() {
        submittedQuery = query;
        results = const [];
        totalFound = 0;
        loading = false;
        error = 'CBETA 搜尋服務未開放網頁跨域存取；請使用桌面或行動版 App 搜尋。';
      });
      return;
    }
    setState(() {
      loading = true;
      loadingMore = false;
      error = null;
      offlineMode = false;
      hasMore = false;
      scannedVolumes = 0;
      totalVolumes = 0;
      offlineSession = null;
      submittedQuery = query;
      results = const [];
      nextStart = 0;
      totalTermHits = 0;
    });
    await _loadPage(query, 0);
  }

  Future<void> _loadPage(String query, int start) async {
    try {
      if (offlineMode) {
        final session = offlineSession ??= OfflineScanSession(query);
        await session.prepare();
        await session.scanChunk();
        if (!mounted) return;
        _applyOfflineScanPage(query, session.current);
        return;
      }
      final batch = await fetchSearchBatch(query, start: start);
      if (!mounted) return;
      setState(() {
        results = [...results, ...batch.results];
        nextStart = batch.nextStart;
        totalFound = batch.totalFound;
        totalTermHits = batch.totalTermHits;
        hasMore = batch.hasMore;
        loading = false;
        loadingMore = false;
        FullTextSearchCache.remember(
          query,
          results: results,
          nextStart: nextStart,
          totalFound: totalFound,
          totalTermHits: totalTermHits,
          hasMore: hasMore,
        );
      });
    } catch (exception) {
      if (!mounted) return;
      if (!offlineMode && isNetworkFailure(exception)) {
        final session = OfflineScanSession(query);
        offlineSession = session;
        await session.prepare();
        await session.scanChunk();
        if (!mounted) return;
        setState(() => offlineMode = true);
        _applyOfflineScanPage(query, session.current);
        return;
      }
      setState(() {
        error = '全文搜尋失敗：$exception';
        loading = false;
        loadingMore = false;
      });
    }
  }

  void _applyOfflineScanPage(String query, OfflineScanProgress progress) {
    setState(() {
      results = progress.results;
      nextStart = progress.results.length;
      totalFound = progress.results.length;
      totalTermHits = progress.termHits;
      hasMore = !progress.finished;
      scannedVolumes = progress.scannedVolumes;
      totalVolumes = progress.totalVolumes;
      loading = false;
      loadingMore = false;
      FullTextSearchCache.remember(
        query,
        results: results,
        nextStart: nextStart,
        totalFound: totalFound,
        totalTermHits: totalTermHits,
        hasMore: hasMore,
      );
    });
  }

  void _openPassage(ScripturePassage passage, List<ScripturePassage> hits) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ScriptureReaderPage(
          passage: passage,
          query: submittedQuery,
          searchHits: hits,
          initialHitIndex: hits.indexOf(passage),
        ),
      ),
    );
  }

  @override
  void dispose() {
    offlineSession?.dispose();
    scrollController
      ..removeListener(_onScroll)
      ..dispose();
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: scriptureDisplaySettings.backgroundColor,
    appBar: AppBar(
      title: const Text('全文搜尋'),
      backgroundColor: scriptureDisplaySettings.surfaceColor,
      actions: const [ScriptDisplayButton(), SettingsButton()],
    ),
    body: Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Expanded(
                child: SearchInput(
                  controller: controller,
                  onSearch: _onSearchSelection,
                  textBuilder: (text) => displayText(text, context),
                  displayListenable: scriptureDisplaySettings,
                  decoration: InputDecoration(
                    hintText: displayText('輸入關鍵字搜尋經文…', context),
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              IconButton.filled(
                tooltip: displayText('搜尋', context),
                onPressed: search,
                icon: const Icon(Icons.search_rounded),
              ),
            ],
          ),
        ),
        if (submittedQuery.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                offlineMode
                    ? '「$submittedQuery」離線模式，已找到 $totalFound 筆'
                          '${hasMore ? '（已掃描 $scannedVolumes/$totalVolumes 卷）' : ''}'
                    : '「$submittedQuery」找到 $totalFound 筆',
              ),
            ),
          ),
        Expanded(
          child: loading && results.isEmpty
              ? const Center(child: CircularProgressIndicator())
              : error != null
              ? NoResults(message: error!)
              : results.isEmpty && !hasMore
              ? const SearchPrompt()
              : ListView(
                  controller: scrollController,
                  children: [
                    if (results.isEmpty)
                      Padding(
                        padding: const EdgeInsets.all(24),
                        child: NoResults(
                          message:
                              '正在掃描本地經卷…\n'
                              '已掃描 $scannedVolumes/$totalVolumes 卷，'
                              '目前找到 $totalFound 筆',
                        ),
                      ),
                    for (final result in results)
                      SearchResultCard(
                        result: result,
                        query: submittedQuery,
                        onPassageTap: _openPassage,
                      ),
                    if (hasMore)
                      Center(
                        child: TextButton(
                          onPressed: loadingMore
                              ? null
                              : () {
                                  setState(() => loadingMore = true);
                                  _loadPage(submittedQuery, nextStart);
                                },
                          child: Text(loadingMore ? '載入中…' : '載入更多結果'),
                        ),
                      ),
                  ],
                ),
        ),
      ],
    ),
  );
}
