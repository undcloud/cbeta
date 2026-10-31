import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart' hide Text;
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import '../cbeta_api_headers.dart';
import '../dictionary/fodict_catalog.dart';
import '../dictionary/fodict_download_manager.dart';
import '../dictionary/fodict_service.dart';
import '../scripture/models.dart';
import '../search/candidates.dart';
import '../search/conversion.dart';
import '../search/goto.dart';
import '../search/history.dart';
import '../search/search_input.dart';
import '../download/catalog_cache.dart';
import '../download/download_manager.dart';
import '../download/download_models.dart';
import '../download/update_manager.dart';
import '../settings/display_settings.dart';
import '../work_picker/work_picker_state.dart';
import '../dictionary/dictionary_sticky_headers.dart';
import '../download/download_status_ui.dart';
import '../reader/reader_layout.dart';
import '../widgets/display_text.dart';
import 'creator_collation.dart';

const int workPickerDictionaryTab = 1;

Future<ScripturePassage?> showWorkPicker(
  BuildContext context, {
  int initialTab = 0,
  bool autoOpenDictionarySelection = false,
  String? initialDictionaryQuery,
}) => showGeneralDialog<ScripturePassage>(
  context: context,
  barrierDismissible: true,
  barrierLabel: '關閉選擇佛經',
  barrierColor: Colors.black54,
  transitionDuration: const Duration(milliseconds: 180),
  pageBuilder: (dialogContext, _, _) {
    final screen = MediaQuery.sizeOf(dialogContext);
    return SafeArea(
      child: Align(
        alignment: Alignment.centerLeft,
        child: SizedBox(
          width: (screen.width * 0.78).clamp(280, 460).toDouble(),
          height: screen.height,
          child: Material(
            elevation: 16,
            clipBehavior: Clip.antiAlias,
            borderRadius: const BorderRadius.horizontal(
              right: Radius.circular(16),
            ),
            child: WorkPickerPage(
              initialTab: initialTab,
              autoOpenDictionarySelection: autoOpenDictionarySelection,
              initialDictionaryQuery: initialDictionaryQuery,
            ),
          ),
        ),
      ),
    );
  },
  transitionBuilder: (context, animation, _, child) => SlideTransition(
    position: Tween<Offset>(
      begin: const Offset(-1, 0),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: animation, curve: Curves.easeOut)),
    child: child,
  ),
);

class WorkPickerPage extends StatefulWidget {
  const WorkPickerPage({
    super.key,
    this.initialTab = 0,
    this.autoOpenDictionarySelection = false,
    this.initialDictionaryQuery,
  });
  final int initialTab;
  final bool autoOpenDictionarySelection;
  final String? initialDictionaryQuery;
  @override
  State<WorkPickerPage> createState() => _WorkPickerPageState();
}

class WorkPickerResponseCache {
  static final Map<String, Future<Map<String, dynamic>>> json = {};
}

/// 清空選擇佛經頁的 API 回應快取（僅供測試使用）。
@visibleForTesting
void resetWorkPickerResponseCache() {
  WorkPickerResponseCache.json.clear();
}

Future<Map<String, dynamic>> cachedPickerJson(
  Uri uri,
  String serviceName,
) async {
  final key = uri.toString();
  final future = WorkPickerResponseCache.json.putIfAbsent(key, () async {
    final response = await http
        .get(uri, headers: cbetaApiHeaders)
        .timeout(const Duration(seconds: 20));
    if (response.statusCode != 200) {
      throw Exception('$serviceName 回傳 ${response.statusCode}');
    }
    return jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
  });
  try {
    return await future;
  } catch (_) {
    if (identical(WorkPickerResponseCache.json[key], future)) {
      WorkPickerResponseCache.json.remove(key);
    }
    rethrow;
  }
}

class _WorkPickerPageState extends State<WorkPickerPage>
    with SingleTickerProviderStateMixin {
  static const _tabs = ['部類', '詞典', '冊別', '作譯者', '年代', '經目查詢', 'Goto 查詢'];
  static const _tabBuLei = 0;
  static const _tabDict = 1;
  static const _tabCeBie = 2;
  static const _tabCreator = 3;
  static const _tabDynasty = 4;
  static const _tabJingMu = 5;
  static const _tabGoto = 6;

  final Map<int, List<({String q, String label})>> catalogLevels = {
    _tabBuLei: [],
    _tabCeBie: [],
  };
  final Map<int, List<Map<String, dynamic>>> catalogEntries = {
    _tabBuLei: [],
    _tabCeBie: [],
  };
  final TextEditingController creatorController = TextEditingController();
  final TextEditingController tocController = TextEditingController();
  final TextEditingController gotoController = TextEditingController();
  SearchSelection? _tocPendingSelection;
  SearchSelection? _dictionaryPendingSelection;
  List<MapEntry<String, CreatorEntry>> creators = [];
  List<DynastyEntry> dynasties = [];
  List<Map<String, dynamic>> listedWorks = [];
  int selectedTab = 0;
  int activeCatalogTab = 0;
  bool loading = false;
  bool loadingCreators = false;
  bool loadingDynasties = false;
  Future<void>? _creatorsLoadingFuture;
  Future<void>? _dynastiesLoadingFuture;
  bool showingWorks = false;
  String creatorQuery = '';
  String? error;
  String? resultMessage;
  bool downloadMode = false;
  final Set<String> selectedDownloadWorks = {};
  final TextEditingController dictionaryController = TextEditingController();
  final FodictService _fodictService = FodictService();
  List<FodictEntry> dictionaryResults = [];
  List<FodictInfo> availableDictionaries = [];
  Set<String> selectedDictionaries = {};
  bool loadingDictionaries = true;
  bool loadingDictionaryResults = false;
  bool dictionarySelectionExpanded = false;
  String? dictionaryError;
  String? dictionaryResultMessage;
  String? _fodictBaseDir;
  String? _pendingDictionaryQuery;
  final Set<String> _expandedDictionaryIds = {};
  final Set<String> _expandedEntryKeys = {};
  int _lastFodictInstallRevision = 0;
  List<FodictRemoteDictionary> _remoteDictionaries = const [];
  bool _loadingRemoteDictionaries = false;
  String? _remoteDictionariesError;
  bool _collapseAfterFodictDownloads = false;
  late final TabController _tabController;
  final Map<int, ScrollController> _scrollControllers = {};
  final Map<int, double> _savedScrollOffsets = {};
  final Map<int, double> _pendingScrollOffsets = {};
  final Set<String> _restoredDictionaryExpandedIds = {};
  final Set<String> _restoredDictionaryExpandedEntryKeys = {};

  @override
  void initState() {
    super.initState();
    selectedTab = widget.initialTab;
    _tabController = TabController(
      length: _tabs.length,
      vsync: this,
      initialIndex: selectedTab.clamp(0, _tabs.length - 1),
    );
    _lastFodictInstallRevision = fodictDownloadManager.installRevision;
    fodictDownloadManager.addListener(_onFodictDownloadManagerChanged);
    CatalogCache.instance.addListener(_onCatalogReloaded);
    if (widget.initialDictionaryQuery != null &&
        widget.initialDictionaryQuery!.isNotEmpty) {
      final term = widget.initialDictionaryQuery!.trim();
      dictionaryController.text = term;
      _pendingDictionaryQuery = term;
    }
    unawaited(_boot());
    if (widget.autoOpenDictionarySelection) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _openFodictDownloadPanel();
      });
    }
  }

  Future<void> _boot() async {
    final snapshot = await loadWorkPickerSnapshot();
    if (!mounted) return;
    if (snapshot != null) {
      setState(() => _applySnapshot(snapshot));
    }
    final tabData = switch (selectedTab) {
      _tabCreator => _loadCreators(),
      _tabDynasty => _loadDynasties(),
      _ => Future<void>.value(),
    };
    await Future.wait([_initLocalCatalog(), _initDictionaries(), tabData]);
    if (!mounted) return;
    _scheduleApplyScroll(selectedTab);
  }

  void _applySnapshot(WorkPickerSnapshot snapshot) {
    final hasExplicitQuery =
        widget.initialDictionaryQuery?.trim().isNotEmpty ?? false;
    // 由閱讀頁「查詞典」開啟時，永遠以當下選取的詞語為準。
    if (hasExplicitQuery || widget.initialTab != 0) return;

    selectedTab = snapshot.tab.clamp(0, _tabs.length - 1);
    if (_tabController.index != selectedTab) {
      _tabController.index = selectedTab;
    }
    if (selectedTab == _tabBuLei || selectedTab == _tabCeBie) {
      activeCatalogTab = selectedTab;
    }
    _savedScrollOffsets
      ..clear()
      ..addAll(snapshot.scrollOffsets);
    _pendingScrollOffsets.clear();
    final restoredOffset = snapshot.scrollOffsets[selectedTab];
    if (restoredOffset != null) {
      _pendingScrollOffsets[selectedTab] = restoredOffset;
    }
    final restoredLevels = snapshot.catalogLevels[selectedTab];
    if (restoredLevels != null && restoredLevels.isNotEmpty) {
      catalogLevels[selectedTab] = [
        for (final level in restoredLevels) (q: level.q, label: level.label),
      ];
    }
    creatorController.text = snapshot.creatorQuery;
    creatorQuery = SimplifiedTraditionalConverter.convertPreferred(
      snapshot.creatorQuery.trim(),
    );
    tocController.text = snapshot.tocQuery;
    gotoController.text = snapshot.gotoQuery;
    dictionaryController.text = snapshot.dictionaryQuery;
    _pendingDictionaryQuery = snapshot.dictionaryQuery.trim().isEmpty
        ? null
        : snapshot.dictionaryQuery.trim();
    _restoredDictionaryExpandedIds
      ..clear()
      ..addAll(snapshot.dictionaryExpandedIds);
    _restoredDictionaryExpandedEntryKeys
      ..clear()
      ..addAll(snapshot.dictionaryExpandedEntryKeys);
    resultMessage = snapshot.resultMessage;
    final restoresWorksView =
        selectedTab == _tabCreator ||
        selectedTab == _tabDynasty ||
        selectedTab == _tabJingMu;
    if (snapshot.showingWorks && restoresWorksView) {
      showingWorks = true;
      listedWorks = snapshot.listedWorks;
    }
  }

  ScrollController _scrollControllerFor(int tab) {
    return _scrollControllers.putIfAbsent(tab, () {
      final controller = ScrollController();
      controller.addListener(() {
        if (controller.hasClients) {
          _savedScrollOffsets[tab] = controller.offset;
        }
      });
      return controller;
    });
  }

  void _scheduleApplyScroll(int tab) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _applyPendingScroll(tab);
    });
  }

  void _applyPendingScroll(int tab) {
    final offset = _pendingScrollOffsets.remove(tab);
    if (offset == null) return;
    final controller = _scrollControllers[tab];
    if (controller == null || !controller.hasClients) return;
    controller.jumpTo(offset.clamp(0.0, controller.position.maxScrollExtent));
  }

  void _restoreSavedScroll(int tab) {
    final saved = _savedScrollOffsets[tab];
    if (saved == null) return;
    _pendingScrollOffsets[tab] = saved;
    _scheduleApplyScroll(tab);
  }

  void _resetScrollToTop(int tab) {
    _pendingScrollOffsets.remove(tab);
    _savedScrollOffsets[tab] = 0;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final controller = _scrollControllers[tab];
      if (controller != null &&
          controller.hasClients &&
          controller.offset != 0) {
        controller.jumpTo(0);
      }
    });
  }

  void _onFodictDownloadManagerChanged() {
    if (!mounted) return;
    final manager = fodictDownloadManager;
    if (manager.installRevision != _lastFodictInstallRevision) {
      _lastFodictInstallRevision = manager.installRevision;
      unawaited(_refreshDictionaries());
    }
    if (_collapseAfterFodictDownloads &&
        dictionarySelectionExpanded &&
        manager.queue.isEmpty &&
        !manager.isDownloading) {
      _collapseAfterFodictDownloads = false;
      setState(() => dictionarySelectionExpanded = false);
      return;
    }
    if (dictionarySelectionExpanded) setState(() {});
  }

  void _onCatalogReloaded() {
    if (!mounted) return;
    unawaited(_reloadCatalogAfterUpdate());
  }

  Future<void> _reloadCatalogAfterUpdate() async {
    if (!mounted) return;
    _creatorsLoadingFuture = null;
    _dynastiesLoadingFuture = null;
    setState(() {
      for (final tab in catalogLevels.keys) {
        catalogLevels[tab] = [];
        catalogEntries[tab] = [];
      }
      creators = [];
      dynasties = [];
      listedWorks = [];
      showingWorks = false;
      creatorQuery = '';
      error = null;
      resultMessage = null;
    });
    await _initLocalCatalog();
    if (!mounted) return;
    if (selectedTab == _tabCreator) await _loadCreators();
    if (selectedTab == _tabDynasty) await _loadDynasties();
  }

  void _toggleDictionarySelection() {
    final expanding = !dictionarySelectionExpanded;
    setState(() {
      dictionarySelectionExpanded = expanding;
      if (expanding) {
        _collapseAfterFodictDownloads = fodictDownloadManager.hasQueuedItems;
      }
    });
    if (expanding) unawaited(_loadRemoteDictionaries());
  }

  Future<void> _openFodictDownloadPanel() async {
    if (!dictionarySelectionExpanded) {
      setState(() {
        dictionarySelectionExpanded = true;
        _collapseAfterFodictDownloads = fodictDownloadManager.hasQueuedItems;
      });
    }
    await _loadRemoteDictionaries();
    if (!mounted) return;

    final allIds = <String>{
      ...availableDictionaries.map((dict) => dict.id),
      ..._remoteDictionaries.map((dict) => dict.id),
    };
    setState(() => selectedDictionaries = allIds);

    final downloadable = _remoteDictionaries
        .where(
          (dict) =>
              dict.available &&
              !fodictDownloadManager.isBundled(dict.id) &&
              !fodictDownloadManager.isInstalled(dict.id),
        )
        .toList();

    if (downloadable.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(displayText('全部詞典均已下載', context))));
      return;
    }

    final confirmed = await _confirmDownloadAllDictionaries(downloadable);
    if (confirmed != true || !mounted) return;
    _collapseAfterFodictDownloads = true;
    for (final dict in downloadable) {
      fodictDownloadManager.enqueue(dict);
    }
  }

  Future<bool?> _confirmDownloadAllDictionaries(
    List<FodictRemoteDictionary> dictionaries,
  ) {
    final totalBytes = dictionaries.fold<int>(
      0,
      (sum, dict) => sum + dict.zipSize,
    );
    return showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(displayText('下載詞典', dialogContext)),
        content: Text(
          displayText(
            '將下載 ${dictionaries.length} 部詞典（約 ${formatDownloadBytes(totalBytes)}），是否繼續？',
            dialogContext,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(displayText('取消', dialogContext)),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(displayText('下載', dialogContext)),
          ),
        ],
      ),
    );
  }

  Future<void> _loadRemoteDictionaries() async {
    if (_loadingRemoteDictionaries) return;
    setState(() {
      _loadingRemoteDictionaries = true;
      _remoteDictionariesError = null;
    });
    try {
      final remote = await FodictCatalogService.instance.load(refresh: true);
      if (!mounted) return;
      setState(() {
        _remoteDictionaries = remote;
        _loadingRemoteDictionaries = false;
      });
    } catch (error) {
      debugPrint('詞典清單載入失敗：$error');
      if (!mounted) return;
      setState(() {
        _remoteDictionariesError = '$error';
        _loadingRemoteDictionaries = false;
      });
    }
  }

  void _startFodictDownload(FodictRemoteDictionary dictionary) {
    _collapseAfterFodictDownloads = true;
    fodictDownloadManager.enqueue(dictionary);
  }

  Future<void> _confirmDeleteFodict(String id, String name) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(displayText('刪除詞典', context)),
        content: Text(displayText('確定刪除「$name」的本地文件？', context)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(displayText('取消', context)),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(displayText('刪除', context)),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await fodictDownloadManager.deleteInstalled(id);
    }
  }

  void _collapseDictionarySelectionForInput() {
    if (!dictionarySelectionExpanded) return;
    setState(() => dictionarySelectionExpanded = false);
  }

  Future<void> _initDictionaries() async {
    var baseDir = '';
    try {
      baseDir = await FodictService.defaultBaseDir();
    } catch (_) {
      // 沒有文件目錄時仍可使用內建字典。
    }
    if (!mounted) return;
    setState(() => _fodictBaseDir = baseDir);
    await _refreshDictionaries();
    final pending = _pendingDictionaryQuery;
    if (pending != null && pending.isNotEmpty && mounted) {
      _pendingDictionaryQuery = null;
      await _executeDictionarySearch(pending, allowFallback: true);
      if (mounted &&
          (_restoredDictionaryExpandedIds.isNotEmpty ||
              _restoredDictionaryExpandedEntryKeys.isNotEmpty)) {
        setState(() {
          _expandedDictionaryIds.addAll(_restoredDictionaryExpandedIds);
          _expandedEntryKeys.addAll(_restoredDictionaryExpandedEntryKeys);
        });
      }
    }
    _restoredDictionaryExpandedIds.clear();
    _restoredDictionaryExpandedEntryKeys.clear();
  }

  Future<void> _refreshDictionaries() async {
    final baseDir = _fodictBaseDir;
    if (baseDir == null) return;
    try {
      _fodictService.clearCache();
      final dicts = await _fodictService.getDictionaries(baseDir);
      if (!mounted) return;
      final ids = dicts.map((dictionary) => dictionary.id).toSet();
      final oldIds = availableDictionaries
          .map((dictionary) => dictionary.id)
          .toSet();
      setState(() {
        availableDictionaries = dicts;
        selectedDictionaries = {
          ...selectedDictionaries.where(ids.contains),
          ...ids.difference(oldIds),
        };
        loadingDictionaries = false;
        dictionaryError = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        dictionaryError = '載入字典列表失敗：$e';
        loadingDictionaries = false;
      });
    }
  }

  Future<void> _initLocalCatalog() async {
    await CatalogCache.instance.load();
    if (!mounted) return;
    if (selectedTab == _tabBuLei || selectedTab == _tabCeBie) {
      activeCatalogTab = selectedTab;
      final levels = catalogLevels[selectedTab]!;
      if (levels.isNotEmpty) {
        await _loadCatalog(selectedTab, levels.last.q, resetScroll: false);
        return;
      }
      await _loadCatalog(
        selectedTab,
        selectedTab == _tabCeBie ? 'orig' : 'CBETA',
      );
    }
  }

  Future<Map<String, dynamic>> _getJson(
    String path, [
    Map<String, String> parameters = const {},
  ]) => cachedPickerJson(
    Uri.https('cbdata.dila.edu.tw', '/stable/$path', parameters),
    'CBETA API',
  );

  Future<void> _loadCatalog(
    int tab,
    String query, {
    int? breadcrumbIndex,
    bool resetScroll = true,
  }) async {
    activeCatalogTab = tab;
    if (resetScroll) _resetScrollToTop(tab);
    setState(() {
      loading = true;
      error = null;
      showingWorks = false;
    });
    try {
      final cache = CatalogCache.instance;
      final node = cache.findNode(query);
      if (node == null) throw Exception('找不到目錄節點：$query');
      final nextEntries = cache.nodeToItems(node);
      if (!mounted) return;
      setState(() {
        catalogEntries[tab] = nextEntries;
        loading = false;
        final levels = catalogLevels[tab]!;
        if (breadcrumbIndex != null) {
          levels.removeRange(breadcrumbIndex + 1, levels.length);
        }
        if (levels.isEmpty || levels.last.q != query) {
          levels.add((q: query, label: node.label));
        } else {
          levels[levels.length - 1] = (q: query, label: node.label);
        }
      });
      if (downloadMode) {
        _addWorksToSelection(node.collectWorkIds());
      }
    } catch (exception) {
      if (!mounted) return;
      setState(() {
        error = '載入作品目錄失敗：$exception';
        loading = false;
      });
    }
  }

  Future<void> _selectTab(int tab) async {
    if (_tabController.index != tab) _tabController.index = tab;
    setState(() {
      selectedTab = tab;
      error = null;
      resultMessage = null;
      showingWorks = false;
      if (downloadMode) {
        downloadMode = false;
        selectedDownloadWorks.clear();
      }
    });
    if (tab == _tabBuLei && catalogLevels[_tabBuLei]!.isEmpty) {
      await _loadCatalog(_tabBuLei, 'CBETA');
    } else if (tab == _tabCeBie && catalogLevels[_tabCeBie]!.isEmpty) {
      await _loadCatalog(_tabCeBie, 'orig');
    } else if (tab == _tabCreator && creators.isEmpty) {
      await _loadCreators();
    } else if (tab == _tabDynasty && dynasties.isEmpty) {
      await _loadDynasties();
    }
    _autoSelectCurrentView();
    _restoreSavedScroll(tab);
  }

  Future<void> _loadCreators() {
    return _creatorsLoadingFuture ??= _loadCreatorsOnce().whenComplete(() {
      _creatorsLoadingFuture = null;
    });
  }

  Future<void> _loadCreatorsOnce() async {
    setState(() {
      loadingCreators = true;
      error = null;
    });
    try {
      await ensureCreatorCollator();
      await CatalogCache.instance.load();
      if (!mounted) return;
      setState(() {
        creators = CatalogCache.instance.creators.entries.toList();
        loadingCreators = false;
      });
      _autoSelectCurrentView();
    } catch (exception) {
      if (!mounted) return;
      setState(() {
        error = '載入作譯者失敗：$exception';
        loadingCreators = false;
      });
    }
  }

  Future<void> _loadDynasties() {
    return _dynastiesLoadingFuture ??= _loadDynastiesOnce().whenComplete(() {
      _dynastiesLoadingFuture = null;
    });
  }

  Future<void> _loadDynastiesOnce() async {
    setState(() {
      loadingDynasties = true;
      error = null;
    });
    try {
      await CatalogCache.instance.load();
      if (!mounted) return;
      setState(() {
        dynasties = CatalogCache.instance.dynasties;
        loadingDynasties = false;
      });
      _autoSelectCurrentView();
    } catch (exception) {
      if (!mounted) return;
      setState(() {
        error = '載入年代列表失敗：$exception';
        loadingDynasties = false;
      });
    }
  }

  Future<void> _loadWorks(
    Map<String, String> parameters, {
    required String description,
  }) async {
    _resetScrollToTop(selectedTab);
    setState(() {
      loading = true;
      error = null;
      resultMessage = null;
      showingWorks = true;
    });
    try {
      final cache = CatalogCache.instance;
      List<Map<String, dynamic>> results;
      final creatorId = parameters['creator_id'];
      final dynasty = parameters['dynasty'];
      if (creatorId != null) {
        final creator = cache.creators[creatorId];
        results = (creator?.works ?? const []).map((w) => w.toMap()).toList();
      } else if (dynasty != null) {
        final dynastyEntry = cache.dynasties.firstWhere(
          (d) => d.name == dynasty,
          orElse: () => const DynastyEntry(name: '', start: '', end: ''),
        );
        results = dynastyEntry.works.map((w) => w.toMap()).toList();
      } else {
        results = const [];
      }
      if (!mounted) return;
      setState(() {
        listedWorks = results;
        resultMessage = '$description：${results.length} 部作品';
        loading = false;
      });
      _autoSelectCurrentView();
    } catch (exception) {
      if (!mounted) return;
      setState(() {
        error = '查詢作品失敗：$exception';
        loading = false;
      });
    }
  }

  Future<void> _searchToc() async {
    final raw = tocController.text.trim();
    if (raw.isEmpty) return;
    final pending = _tocPendingSelection;
    _tocPendingSelection = null;
    if (pending != null && (raw == pending.rawInput || raw == pending.query)) {
      await _runTocSearch(pending.rawInput, pending.query);
      return;
    }
    final query = await preferredQueryForInput(raw);
    await _runTocSearch(raw, query);
  }

  Future<void> _onTocSelection(SearchSelection selection) async {
    final raw = selection.rawInput.trim();
    if (raw.isEmpty) return;
    _tocPendingSelection = null;
    await _runTocSearch(raw, selection.query);
  }

  Future<void> _runTocSearch(String raw, String query) async {
    if (raw.isEmpty || query.isEmpty) return;
    _resetScrollToTop(_tabJingMu);
    try {
      await recordSearchSelection(raw, query);
    } catch (_) {
      // 記錄失敗不影響查詢。
    }
    if (!mounted) return;
    final localResults = CatalogCache.instance.searchWorks(query);
    setState(() {
      loading = true;
      error = null;
      resultMessage = null;
      if (localResults.isNotEmpty) {
        listedWorks = localResults;
        showingWorks = true;
      }
    });
    try {
      final payload = await _getJson('search/toc', {'q': query});
      final remoteResults = (payload['results'] as List<dynamic>? ?? const [])
          .whereType<Map<String, dynamic>>()
          .where((result) => result['type'] == 'work')
          .toList();
      final merged = <Map<String, dynamic>>[...remoteResults];
      final seenWorks = remoteResults
          .map((result) => '${result['work'] ?? ''}')
          .toSet();
      for (final result in localResults) {
        if (seenWorks.add('${result['work'] ?? ''}')) {
          merged.add(result);
        }
      }
      if (!mounted) return;
      setState(() {
        listedWorks = merged;
        showingWorks = true;
        resultMessage =
            '找到 ${payload['num_found'] ?? remoteResults.length} 筆經目'
            '${localResults.isEmpty ? '' : '，本地經目 ${localResults.length} 部'}';
        loading = false;
      });
      _autoSelectCurrentView();
    } catch (exception) {
      if (!mounted) return;
      if (localResults.isNotEmpty) {
        setState(() {
          listedWorks = localResults;
          showingWorks = true;
          resultMessage = '離線模式：本地經目找到 ${localResults.length} 部作品';
          loading = false;
        });
        _autoSelectCurrentView();
        return;
      }
      setState(() {
        error = '經目查詢失敗：$exception';
        loading = false;
      });
    }
  }

  Future<void> _gotoLine() async {
    final query = normalizeCbetaGotoLinehead(
      extractCbetaGotoQuery(gotoController.text),
    );
    if (query.isEmpty) return;
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final payload = await _getJson('juans/goto', {'linehead': query});
      final apiError = payload['error'];
      if (apiError is Map<String, dynamic>) {
        throw FormatException('${apiError['message'] ?? '無法識別此行號'}');
      }
      if (apiError is String && apiError.isNotEmpty) {
        throw FormatException(apiError);
      }
      final result = (payload['results'] as List<dynamic>? ?? const [])
          .whereType<Map<String, dynamic>>()
          .firstOrNull;
      if (result == null) throw FormatException('找不到此行號對應的經卷');
      await _openWork(result, targetLinehead: '${result['linehead'] ?? query}');
    } catch (exception) {
      if (!mounted) return;
      setState(() {
        error = 'Goto 查詢失敗：$exception';
        loading = false;
      });
    }
  }

  Future<void> _openWork(
    Map<String, dynamic> item, {
    String? targetLinehead,
  }) async {
    final work = item['work'] as String?;
    if (work == null || work.isEmpty) return;
    setState(() {
      loading = true;
      error = null;
    });
    try {
      await CatalogCache.instance.load();
      final cache = CatalogCache.instance;
      final allWorksEntry = cache.lookupWork(work);
      final juanStrings = allWorksEntry?.juans ?? const <String>[];
      final availableJuans =
          juanStrings
              .map((s) => int.tryParse(s))
              .whereType<int>()
              .toSet()
              .toList()
            ..sort();
      if (availableJuans.isEmpty) {
        throw FormatException('此作品沒有可讀取的卷');
      }
      final file = (item['file'] as String?)?.trim().isNotEmpty == true
          ? item['file'] as String
          : cache.lookupWorkFile(work) ?? work;
      final targetJuan = targetLinehead == null
          ? null
          : int.tryParse('${item['juan'] ?? ''}');
      if (targetJuan != null && !availableJuans.contains(targetJuan)) {
        availableJuans.add(targetJuan);
        availableJuans.sort();
      }
      final firstJuan = availableJuans.first;
      final selectedJuan = targetJuan ?? firstJuan;
      final line = targetLinehead == null
          ? ''
          : targetLinehead.split('_p').last;
      final rawTitle =
          allWorksEntry?.title ??
          item['title'] as String? ??
          item['label'] as String? ??
          work;
      final title = rawTitle.replaceFirst(
        RegExp('^${RegExp.escape(work)}\\s+'),
        '',
      );
      final passage = ScripturePassage(
        title: title,
        reference: '卷 $selectedJuan',
        text: '',
        linehead: line.isEmpty ? null : '${file}_p$line',
        juan: '$selectedJuan',
        work: work,
        availableJuans: availableJuans,
      );
      if (!mounted) return;
      Navigator.of(context).pop(passage);
    } catch (exception) {
      if (!mounted) return;
      setState(() {
        error = '無法開啟此作品：$exception';
        loading = false;
      });
    }
  }

  List<Object> get visibleCreatorRows {
    final query = creatorQuery.trim().toLowerCase();
    final groups = <String, List<MapEntry<String, CreatorEntry>>>{};
    for (final entry in creators) {
      final name = entry.value.name;
      if (query.isNotEmpty &&
          ![
            name,
            ...entry.value.aliases,
          ].any((value) => value.toLowerCase().contains(query))) {
        continue;
      }
      final group = entry.value.strokeGroup.isNotEmpty
          ? entry.value.strokeGroup
          : creatorStrokeGroup(name);
      groups.putIfAbsent(group, () => []).add(entry);
    }

    final groupNames = groups.keys.toList();
    final groupOrder = {
      for (var index = 0; index < groupNames.length; index++)
        groupNames[index]: index,
    };
    groupNames.sort((left, right) {
      final byStroke =
          creatorStrokeGroupNumber(left) - creatorStrokeGroupNumber(right);
      return byStroke != 0 ? byStroke : groupOrder[left]! - groupOrder[right]!;
    });
    final rows = <Object>[];
    for (final group in groupNames) {
      rows.add(group);
      final names = groups[group]!
        ..sort(
          (left, right) =>
              compareCreatorNames(left.value.name, right.value.name),
        );
      rows.addAll(names);
    }
    return rows;
  }

  Set<String> _workIdsForItem(Map<String, dynamic> item) {
    final work = item['work'];
    if (work is String && work.isNotEmpty) return {work};
    final query = item['n'];
    if (query is String && query.isNotEmpty) {
      final node = CatalogCache.instance.findNode(query);
      if (node != null) return CatalogCache.instance.workIdsInNode(node);
    }
    return const {};
  }

  Iterable<String> _currentViewWorkIds() sync* {
    final cache = CatalogCache.instance;
    if (selectedTab == _tabBuLei || selectedTab == _tabCeBie) {
      final levels = catalogLevels[selectedTab]!;
      if (levels.isNotEmpty) {
        final node = cache.findNode(levels.last.q);
        if (node != null) yield* node.collectWorkIds();
      }
      return;
    }
    if (selectedTab == _tabCreator) {
      if (showingWorks) {
        for (final item in listedWorks) {
          yield* _workIdsForItem(item);
        }
      } else {
        for (final entry in creators) {
          for (final work in entry.value.works) {
            yield work.work;
          }
        }
      }
      return;
    }
    if (selectedTab == _tabDynasty && !showingWorks) {
      for (final dynasty in dynasties) {
        for (final work in dynasty.works) {
          yield work.work;
        }
      }
      return;
    }
    for (final item in listedWorks) {
      yield* _workIdsForItem(item);
    }
  }

  void _autoSelectCurrentView() {
    if (!downloadMode) return;
    _addWorksToSelection(_currentViewWorkIds());
  }

  void _addWorksToSelection(Iterable<String> works) {
    final additions = works
        .where(
          (work) => work.isNotEmpty && !selectedDownloadWorks.contains(work),
        )
        .toList();
    if (additions.isEmpty) return;
    setState(() => selectedDownloadWorks.addAll(additions));
  }

  void _toggleWorkIds(Iterable<String> works, bool selected) {
    final ids = works.where((work) => work.isNotEmpty).toSet();
    if (ids.isEmpty) return;
    setState(() {
      if (selected) {
        selectedDownloadWorks.addAll(ids);
      } else {
        selectedDownloadWorks.removeAll(ids);
      }
    });
  }

  bool _allSelected(Iterable<String> works) {
    var hasWork = false;
    for (final work in works) {
      if (work.isEmpty) continue;
      hasWork = true;
      if (!selectedDownloadWorks.contains(work)) return false;
    }
    return hasWork;
  }

  bool _noneSelected(Iterable<String> works) {
    for (final work in works) {
      if (selectedDownloadWorks.contains(work)) return false;
    }
    return true;
  }

  int _missingCount(Iterable<String> works) => works
      .where(
        (work) => work.isNotEmpty && !downloadManager.isWorkDownloaded(work),
      )
      .length;

  Widget? _downloadCheckbox(Iterable<String> works) {
    if (!downloadMode) return null;
    final ids = works.where((work) => work.isNotEmpty).toList();
    if (ids.isEmpty) return null;
    return Checkbox(
      tristate: true,
      value: _allSelected(ids)
          ? true
          : _noneSelected(ids)
          ? false
          : null,
      onChanged: (checked) =>
          _toggleWorkIds(ids, checked ?? !_allSelected(ids)),
    );
  }

  Widget _buildCatalog(int tab) {
    final levels = catalogLevels[tab]!;
    final entries = catalogEntries[tab]!;
    return Column(
      children: [
        if (levels.isNotEmpty)
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              children: [
                for (var index = 0; index < levels.length; index++) ...[
                  if (index > 0) const Text(' › '),
                  TextButton(
                    onPressed: index == levels.length - 1
                        ? null
                        : () => _loadCatalog(
                            tab,
                            levels[index].q,
                            breadcrumbIndex: index,
                          ),
                    child: Text(levels[index].label),
                  ),
                ],
              ],
            ),
          ),
        Expanded(
          child: _buildItemList(
            entries,
            onTap: (item) {
              if (item['work'] is String) {
                _openWork(item);
              } else if (item['n'] is String) {
                _loadCatalog(tab, item['n'] as String);
              }
            },
          ),
        ),
      ],
    );
  }

  Widget _buildItemList(
    List<Map<String, dynamic>> items, {
    required ValueChanged<Map<String, dynamic>> onTap,
  }) => ListView.builder(
    controller: _scrollControllerFor(selectedTab),
    itemCount: items.length,
    itemBuilder: (context, index) {
      final item = items[index];
      final work = item['work'] is String;
      var title = '${item['title'] ?? ''}';
      if (title.isEmpty) {
        title = '${item['label'] ?? item['name'] ?? ''}';
      }
      final workId = item['work']?.toString();
      final label = work && workId != null && !title.startsWith('$workId ')
          ? '$workId $title'
          : title;
      final period = item['period'];
      final baseDetails = [
        if (!work && period is String && period.isNotEmpty)
          period
        else if (!work && item['start'] != null && item['end'] != null)
          '${item['start']}–${item['end']} CE',
        if (item['vol'] != null) '${item['vol']}',
        if (item['juan'] != null) '共 ${item['juan']} 卷',
        if (item['byline'] is String && '${item['byline']}'.isNotEmpty)
          '${item['byline']}',
        if (item['count'] != null) '${item['count']} 部',
      ].join(' · ');
      final workIds = _workIdsForItem(item);
      final isDownloaded =
          work && workId != null && downloadManager.isWorkDownloaded(workId);
      final details = !downloadMode || workIds.isEmpty
          ? baseDetails
          : [
              baseDetails,
              if (work)
                isDownloaded ? '已下載' : '本地缺少'
              else
                '本地缺少 ${_missingCount(workIds)} 部',
            ].where((detail) => detail.isNotEmpty).join(' · ');
      final checkbox = _downloadCheckbox(workIds);

      return ListTile(
        leading:
            checkbox ??
            Icon(work ? Icons.menu_book_outlined : Icons.folder_outlined),
        title: Text(displayText(label, context)),
        subtitle: details.isEmpty ? null : Text(displayText(details, context)),
        trailing: isDownloaded
            ? const Icon(Icons.download_done, color: Colors.green)
            : const Icon(Icons.chevron_right_rounded),
        onTap: () => onTap(item),
      );
    },
  );

  Future<void> _onCreatorSelection(SearchSelection selection) async {
    final raw = selection.rawInput.trim();
    final selected = selection.query.trim();
    if (raw.isEmpty) {
      setState(() => creatorQuery = '');
      return;
    }
    if (selected.isEmpty) return;
    try {
      await recordSearchSelection(raw, selected);
    } catch (_) {
      // 記錄失敗不影響搜尋。
    }
    if (!mounted) return;
    setState(() {
      showingWorks = false;
      creatorQuery = selected;
    });
  }

  Widget _buildCreatorTab() => Column(
    children: [
      Padding(
        padding: const EdgeInsets.all(12),
        child: SearchInput(
          controller: creatorController,
          onSearch: _onCreatorSelection,
          onSelectionChanged: (selection) {
            if (selection == null) return;
            setState(() {
              showingWorks = false;
              creatorQuery = selection.query;
            });
          },
          textBuilder: (text) => displayText(text, context),
          displayListenable: scriptureDisplaySettings,
          onChanged: (value) => setState(() {
            showingWorks = false;
            creatorQuery = SimplifiedTraditionalConverter.convertPreferred(
              value.trim(),
            );
          }),
          decoration: InputDecoration(
            prefixIcon: Icon(Icons.search_rounded),
            hintText: displayText('搜尋作譯者…', context),
            border: OutlineInputBorder(),
            isDense: true,
          ),
        ),
      ),
      if (showingWorks)
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: () => setState(() => showingWorks = false),
            icon: const Icon(Icons.arrow_back_rounded),
            label: const Text('返回作譯者'),
          ),
        ),
      Expanded(
        child: showingWorks
            ? _buildItemList(listedWorks, onTap: _openWork)
            : Builder(
                builder: (context) {
                  final rows = visibleCreatorRows;
                  return ListView.builder(
                    controller: _scrollControllerFor(_tabCreator),
                    itemCount: rows.length,
                    itemBuilder: (context, index) {
                      final row = rows[index];
                      if (row is String) {
                        return Padding(
                          padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
                          child: Text(
                            row,
                            style: Theme.of(context).textTheme.titleSmall
                                ?.copyWith(
                                  color: Theme.of(context).colorScheme.primary,
                                  fontWeight: FontWeight.w700,
                                ),
                          ),
                        );
                      }
                      if (row case MapEntry<String, CreatorEntry> entry) {
                        final name = entry.value.name;
                        final aliases = entry.value.aliases;
                        final workIds = entry.value.works
                            .map((work) => work.work)
                            .toList();
                        return ListTile(
                          leading: _downloadCheckbox(workIds),
                          title: Text(name),
                          subtitle: downloadMode
                              ? Text(
                                  '共 ${workIds.length} 部 · '
                                  '本地缺少 ${_missingCount(workIds)} 部',
                                )
                              : aliases.isEmpty
                              ? null
                              : Text(
                                  aliases.take(3).join('、'),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                          trailing: const Icon(Icons.chevron_right_rounded),
                          onTap: () => _loadWorks({
                            'creator_id': entry.key,
                          }, description: name),
                        );
                      }
                      return const SizedBox.shrink();
                    },
                  );
                },
              ),
      ),
    ],
  );

  Widget _buildDynastyTab() => Column(
    children: [
      Expanded(
        child: _buildItemList(
          showingWorks ? listedWorks : dynasties.map((d) => d.toMap()).toList(),
          onTap: (item) => showingWorks
              ? _openWork(item)
              : _loadWorks({
                  'dynasty': '${item['name']}',
                }, description: '${item['name']}'),
        ),
      ),
      if (showingWorks)
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: () => setState(() => showingWorks = false),
            icon: const Icon(Icons.arrow_back_rounded),
            label: const Text('返回年代'),
          ),
        ),
    ],
  );

  Widget _buildSearchTab({
    required TextEditingController controller,
    required String hint,
    required String buttonText,
    required VoidCallback onSearch,
    ValueChanged<SearchSelection>? onSelection,
    ValueChanged<SearchSelection?>? onSelectionChanged,
    TextStyle? hintStyle,
  }) => Column(
    children: [
      Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            Expanded(
              child: onSelection == null
                  ? TextField(
                      controller: controller,
                      textInputAction: TextInputAction.search,
                      onSubmitted: (_) => onSearch(),
                      decoration: InputDecoration(
                        hintText: displayText(hint, context),
                        hintStyle: hintStyle,
                        border: const OutlineInputBorder(),
                        isDense: true,
                      ),
                    )
                  : SearchInput(
                      controller: controller,
                      onSearch: onSelection,
                      onSelectionChanged: onSelectionChanged,
                      textBuilder: (text) => displayText(text, context),
                      displayListenable: scriptureDisplaySettings,
                      decoration: InputDecoration(
                        hintText: displayText(hint, context),
                        hintStyle: hintStyle,
                        border: const OutlineInputBorder(),
                        isDense: true,
                      ),
                    ),
            ),
            const SizedBox(width: 8),
            FilledButton(onPressed: onSearch, child: Text(buttonText)),
          ],
        ),
      ),
      Expanded(
        child: _buildItemList(
          listedWorks,
          onTap: (item) =>
              _openWork(item, targetLinehead: item['linehead'] as String?),
        ),
      ),
    ],
  );

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: scriptureDisplaySettings.backgroundColor,
    appBar: AppBar(
      title: const Text('選擇佛經'),
      backgroundColor: scriptureDisplaySettings.surfaceColor,
      leading: IconButton(
        tooltip: displayText('返回', context),
        onPressed: () {
          final levels = catalogLevels[activeCatalogTab]!;
          if ((selectedTab == _tabBuLei || selectedTab == _tabCeBie) &&
              !showingWorks &&
              levels.length > 1) {
            final parentIndex = levels.length - 2;
            final parent = levels[parentIndex];
            _loadCatalog(
              activeCatalogTab,
              parent.q,
              breadcrumbIndex: parentIndex,
            );
          } else if ((selectedTab == _tabCreator ||
                  selectedTab == _tabDynasty) &&
              showingWorks) {
            setState(() => showingWorks = false);
          } else {
            Navigator.of(context).pop();
          }
        },
        icon: const Icon(Icons.arrow_back_rounded),
      ),
      actions: [
        AnimatedBuilder(
          animation: downloadManager,
          builder: (context, _) => DownloadInfoButton(
            onPressed: () => showDownloadStatusPanel(context),
          ),
        ),
        if (selectedTab == _tabDict)
          IconButton(
            tooltip: displayText('下載全部詞典', context),
            onPressed: _openFodictDownloadPanel,
            icon: const Icon(Icons.download_rounded),
          )
        else
          IconButton(
            tooltip: displayText(downloadMode ? '取消下載模式' : '下載', context),
            onPressed: _toggleDownloadMode,
            icon: Icon(downloadMode ? Icons.close : Icons.download_rounded),
          ),
      ],
    ),
    body: Column(
      children: [
        TabBar(
          controller: _tabController,
          isScrollable: true,
          onTap: _selectTab,
          tabs: [for (final tab in _tabs) Tab(text: displayText(tab, context))],
        ),
        if (resultMessage != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(resultMessage!),
            ),
          ),
        if (loading) const LinearProgressIndicator(),
        if (error != null)
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(error!, textAlign: TextAlign.center),
          ),
        Expanded(
          child: switch (selectedTab) {
            _tabBuLei => _buildCatalog(_tabBuLei),
            _tabDict => _buildDictionaryTab(),
            _tabCeBie => _buildCatalog(_tabCeBie),
            _tabCreator =>
              loadingCreators && creators.isEmpty
                  ? const Center(child: CircularProgressIndicator())
                  : _buildCreatorTab(),
            _tabDynasty =>
              loadingDynasties && dynasties.isEmpty
                  ? const Center(child: CircularProgressIndicator())
                  : _buildDynastyTab(),
            _tabJingMu => _buildSearchTab(
              controller: tocController,
              hint: '輸入經典名稱…',
              buttonText: '搜尋',
              onSearch: _searchToc,
              onSelection: _onTocSelection,
              onSelectionChanged: (selection) =>
                  _tocPendingSelection = selection,
            ),
            _tabGoto => _buildSearchTab(
              controller: gotoController,
              hint: '輸入行號或完整引文，如 CBETA 2026.R2, B22, no. 117, p. 5a1',
              buttonText: '到該行',
              onSearch: _gotoLine,
            ),
            _ => const SizedBox.shrink(),
          },
        ),
        if (downloadMode) _buildDownloadBottomBar(),
      ],
    ),
  );

  Widget _buildDownloadBottomBar() {
    final selected = selectedDownloadWorks;
    final missing = selected
        .where((work) => !downloadManager.isWorkDownloaded(work))
        .toList();
    final totalJuans = selected.fold<int>(
      0,
      (sum, work) =>
          sum + (CatalogCache.instance.lookupWork(work)?.juans.length ?? 0),
    );
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scriptureDisplaySettings.surfaceColor,
        border: Border(top: BorderSide(color: Colors.grey.shade300)),
      ),
      child: SafeArea(
        child: Row(
          children: [
            Expanded(
              child: Text(
                displayText(
                  '已選 ${selected.length} 部 · 共 $totalJuans 卷\n'
                  '本地缺少 ${missing.length} 部',
                  context,
                ),
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ),
            TextButton(
              onPressed: () => setState(() {
                downloadMode = false;
                selectedDownloadWorks.clear();
              }),
              child: Text(displayText('取消', context)),
            ),
            const SizedBox(width: 8),
            FilledButton(
              onPressed: missing.isEmpty
                  ? null
                  : () => _confirmDownload(context),
              child: Text(displayText('確認下載', context)),
            ),
          ],
        ),
      ),
    );
  }

  void _toggleDownloadMode() {
    final entering = !downloadMode;
    setState(() {
      downloadMode = entering;
      if (!entering) selectedDownloadWorks.clear();
    });
    if (entering) _autoSelectCurrentView();
  }

  Future<void> _confirmDownload(BuildContext context) async {
    if (updateManager.isUpdating) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(displayText('更新進行中，完成後再下載經文', context))),
      );
      return;
    }
    final grouped = <String, List<DownloadItem>>{};
    for (final workId in selectedDownloadWorks) {
      if (downloadManager.isWorkDownloaded(workId)) continue;
      final entry = CatalogCache.instance.lookupWork(workId);
      if (entry == null) continue;
      final department =
          CatalogCache.instance.departmentForWork(workId) ?? '其他';
      grouped
          .putIfAbsent(department, () => [])
          .add(
            DownloadItem(
              work: workId,
              title: entry.title,
              juans: entry.juans,
              creators: entry.creators,
              category: department,
            ),
          );
    }
    if (grouped.isEmpty) return;
    final stamp = DateTime.now().microsecondsSinceEpoch;
    var index = 0;
    final groups = grouped.entries.map((entry) {
      final group = DownloadGroup(
        id: '$stamp-${index++}',
        label: '${entry.key}（${entry.value.length} 部）',
        items: entry.value,
      );
      return group;
    }).toList();
    downloadManager.addToQueue(groups);
    setState(() {
      downloadMode = false;
      selectedDownloadWorks.clear();
    });
    unawaited(downloadManager.startDownload());
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(displayText('已加入下載隊列，共 ${groups.length} 部', context)),
      ),
    );
  }

  String get _dictionaryCountScope => _fodictBaseDir ?? '';

  Future<Map<String, int>> _dictionaryKeyMatchCounter(
    List<String> candidates,
  ) async {
    final baseDir = _fodictBaseDir;
    if (baseDir == null) {
      return {for (final candidate in candidates) candidate: 0};
    }
    try {
      return await _fodictService.countKeyMatches(baseDir, candidates);
    } catch (_) {
      return {for (final candidate in candidates) candidate: 0};
    }
  }

  Future<void> _searchDictionary() async {
    final raw = dictionaryController.text.trim();
    if (raw.isEmpty || _fodictBaseDir == null) return;
    final pending = _dictionaryPendingSelection;
    _dictionaryPendingSelection = null;
    if (pending != null && (raw == pending.rawInput || raw == pending.query)) {
      await _executeDictionarySelection(
        pending.rawInput,
        pending.query,
        allowFallback: !pending.isExplicit,
      );
      return;
    }
    await _executeDictionarySelection(raw, null);
  }

  Future<void> _onDictionarySelection(SearchSelection selection) async {
    _dictionaryPendingSelection = null;
    await _executeDictionarySelection(
      selection.rawInput,
      selection.query,
      allowFallback: !selection.isExplicit,
    );
  }

  Future<void> _executeDictionarySelection(
    String rawInput,
    String? selectedQuery, {
    bool allowFallback = true,
  }) async {
    final raw = rawInput.trim();
    if (raw.isEmpty || _fodictBaseDir == null) return;
    if (dictionarySelectionExpanded) {
      setState(() => dictionarySelectionExpanded = false);
    }
    var query = selectedQuery?.trim() ?? '';
    if (query.isEmpty) {
      Map<String, String> selections = const {};
      try {
        selections = await loadSearchSelections();
      } catch (_) {
        // 歷史記錄損壞時仍可查詢。
      }
      query = await resolveSearchQuery(
        raw,
        selections: selections,
        keyMatchCounter: _dictionaryKeyMatchCounter,
      );
    }
    if (query.isEmpty || !mounted) return;
    FocusScope.of(context).unfocus();
    final actualQuery = await _executeDictionarySearch(
      query,
      allowFallback: allowFallback,
    );
    try {
      await recordSearchQuery(raw);
      await recordSearchSelection(raw, actualQuery);
    } catch (_) {
      // 記錄失敗不影響查詢。
    }
    if (!mounted) return;
    dictionaryController.value = TextEditingValue(
      text: actualQuery,
      selection: TextSelection.collapsed(offset: actualQuery.length),
    );
  }

  /// 依序嘗試原字串、繁體與簡體形式，回傳第一個有結果的查詢。
  Future<({String query, List<FodictEntry> results})> _searchDictionaryKeys(
    String query, {
    bool allowFallback = true,
  }) async {
    final variants = <String>[];
    void add(String value) {
      final text = value.trim();
      if (text.isEmpty || variants.contains(text)) return;
      variants.add(text);
    }

    add(query);
    if (allowFallback) {
      add(SimplifiedTraditionalConverter.toSimplified(query));
      add(SimplifiedTraditionalConverter.toTraditionalDisplay(query));
    }

    bool isSelected(FodictEntry entry) =>
        selectedDictionaries.length == availableDictionaries.length ||
        selectedDictionaries.contains(entry.dictionaryId);

    for (final variant in variants) {
      final results = await _fodictService.searchByKey(
        _fodictBaseDir!,
        variant,
        maxResults: 200,
      );
      final filtered = results.where(isSelected).toList();
      if (filtered.isEmpty) continue;
      return (query: variant, results: filtered);
    }
    return (query: query, results: const <FodictEntry>[]);
  }

  Future<String> _executeDictionarySearch(
    String query, {
    bool allowFallback = true,
  }) async {
    if (_fodictBaseDir == null) return query;
    if (!_pendingScrollOffsets.containsKey(_tabDict)) {
      _resetScrollToTop(_tabDict);
    }
    setState(() {
      loadingDictionaryResults = true;
      dictionaryError = null;
      dictionaryResultMessage = null;
      dictionaryResults = [];
      _expandedDictionaryIds.clear();
      _expandedEntryKeys.clear();
    });
    try {
      final match = await _searchDictionaryKeys(
        query,
        allowFallback: allowFallback,
      );
      final filtered = match.results;
      if (!mounted) return match.query;
      setState(() {
        dictionaryResults = filtered;
        loadingDictionaryResults = false;
        dictionaryResultMessage = match.query == query
            ? '找到 ${filtered.length} 筆結果'
            : '找到 ${filtered.length} 筆結果（已用「${displayText(match.query, context)}」查詢）';
      });
      return match.query;
    } catch (e) {
      if (!mounted) return query;
      setState(() {
        dictionaryError = '查詢失敗：$e';
        loadingDictionaryResults = false;
      });
      return query;
    }
  }

  Map<String, List<FodictEntry>> get _dictionaryGroupedResults {
    final groups = <String, List<FodictEntry>>{};
    for (final entry in dictionaryResults) {
      groups.putIfAbsent(entry.dictionaryId, () => []).add(entry);
    }
    return groups;
  }

  Widget _buildDictionaryTab() {
    if (loadingDictionaries) {
      return const Center(child: CircularProgressIndicator());
    }
    final selecting = dictionarySelectionExpanded;
    return Column(
      children: [
        if (selecting)
          Expanded(child: _buildDictionarySelectionPanel())
        else
          _buildDictionarySelectionPanel(),
        _buildDictionarySearchRow(),
        if (!selecting) ...[
          if (dictionaryResultMessage != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  dictionaryResultMessage!,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            ),
          if (loadingDictionaryResults) const LinearProgressIndicator(),
          if (dictionaryError != null)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(dictionaryError!, textAlign: TextAlign.center),
            ),
          Expanded(
            child: dictionaryResults.isEmpty && !loadingDictionaryResults
                ? Center(
                    child: Text(
                      displayText('輸入關鍵詞查詢佛學詞典', context),
                      style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  )
                : _buildDictionaryGroupedResults(),
          ),
        ],
      ],
    );
  }

  Widget _buildDictionarySearchRow() {
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Row(
        children: [
          Expanded(
            child: SearchInput(
              controller: dictionaryController,
              onSearch: _onDictionarySelection,
              onSelectionChanged: (selection) =>
                  _dictionaryPendingSelection = selection,
              onFieldTap: _collapseDictionarySelectionForInput,
              keyMatchCounter: _dictionaryKeyMatchCounter,
              countScope: _dictionaryCountScope,
              textBuilder: (text) => displayText(text, context),
              displayListenable: scriptureDisplaySettings,
              decoration: InputDecoration(
                prefixIcon: const Icon(Icons.search_rounded),
                hintText: displayText('輸入關鍵詞…', context),
                border: const OutlineInputBorder(),
                isDense: true,
              ),
            ),
          ),
          const SizedBox(width: 8),
          FilledButton(
            onPressed: loadingDictionaryResults || availableDictionaries.isEmpty
                ? null
                : _searchDictionary,
            child: Text(displayText('搜尋', context)),
          ),
        ],
      ),
    );
  }

  Widget _buildDictionaryGroupedResults() {
    final groups = _dictionaryGroupedResults;
    final dictIds = groups.keys.toList()..sort((a, b) => a.compareTo(b));

    return CustomScrollView(
      controller: _scrollControllerFor(_tabDict),
      slivers: [
        for (final dictId in dictIds)
          DictionaryStickyHeader(
            dictId: dictId,
            entries: groups[dictId]!,
            dictName:
                availableDictionaries
                    .where((d) => d.id == dictId)
                    .firstOrNull
                    ?.name ??
                dictId,
            isExpanded: _expandedDictionaryIds.contains(dictId),
            onExpansionChanged: (expanded) {
              setState(() {
                if (expanded) {
                  _expandedDictionaryIds.add(dictId);
                } else {
                  _expandedDictionaryIds.remove(dictId);
                }
              });
            },
            buildEntryTile: (entry) => _buildDictionaryKeywordTile(entry),
            context: context,
          ),
      ],
    );
  }

  Future<void> _lookupDictionarySelection(String text) async {
    final term = text.trim();
    if (term.isEmpty) return;
    _dictionaryPendingSelection = null;
    dictionaryController.value = TextEditingValue(
      text: term,
      selection: TextSelection.collapsed(offset: term.length),
    );
    // 直接以选中的文字执行查询，等同按下「搜尋」按钮。
    await _executeDictionarySelection(term, term);
  }

  Widget _buildDictionaryKeywordTile(FodictEntry entry) {
    final entryKey = '${entry.dictionaryId}:${entry.keyword}';
    final isEntryExpanded = _expandedEntryKeys.contains(entryKey);
    final bodyStyle = scriptureTextStyle(scriptureDisplaySettings);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Divider(height: 1),
        InkWell(
          onTap: () => setState(() {
            if (isEntryExpanded) {
              _expandedEntryKeys.remove(entryKey);
            } else {
              _expandedEntryKeys.add(entryKey);
            }
          }),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 10, 12, 10),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    displayText(entry.keyword, context),
                    style: bodyStyle.copyWith(fontWeight: FontWeight.w600),
                  ),
                ),
                Icon(
                  isEntryExpanded ? Icons.expand_less : Icons.expand_more,
                  size: 20,
                ),
              ],
            ),
          ),
        ),
        if (isEntryExpanded)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 16, 12),
            child: SelectableText(
              displayText(cleanFodictDefinition(entry.definition), context),
              style: bodyStyle,
              contextMenuBuilder: (context, editableTextState) {
                final value = editableTextState.textEditingValue;
                final selection = value.selection;
                final selected = selection.isValid && !selection.isCollapsed
                    ? selection.textInside(value.text).trim()
                    : '';
                return AdaptiveTextSelectionToolbar.buttonItems(
                  anchors: editableTextState.contextMenuAnchors,
                  buttonItems: [
                    ContextMenuButtonItem(
                      label: '全選',
                      onPressed: () {
                        editableTextState.selectAll(
                          SelectionChangedCause.toolbar,
                        );
                        editableTextState.hideToolbar();
                      },
                    ),
                    if (selected.isNotEmpty)
                      ContextMenuButtonItem(
                        label: '查詞典',
                        onPressed: () {
                          editableTextState.hideToolbar();
                          _lookupDictionarySelection(selected);
                        },
                      ),
                    if (selected.isNotEmpty)
                      ContextMenuButtonItem(
                        label: '複製',
                        onPressed: () async {
                          await Clipboard.setData(
                            ClipboardData(text: selected),
                          );
                          editableTextState.hideToolbar();
                        },
                      ),
                  ],
                );
              },
            ),
          ),
      ],
    );
  }

  Widget _buildDictionarySelectionPanel() {
    final expanded = dictionarySelectionExpanded;
    return Column(
      children: [
        InkWell(
          onTap: _toggleDictionarySelection,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              children: [
                const Icon(Icons.menu_book_outlined, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    displayText(
                      '字典選擇（${selectedDictionaries.length}/${availableDictionaries.length}）',
                      context,
                    ),
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                ),
                Icon(expanded ? Icons.expand_less : Icons.expand_more),
              ],
            ),
          ),
        ),
        if (expanded) ...[
          const Divider(height: 1),
          _buildDictionarySelectionToolbar(),
          if (_loadingRemoteDictionaries) const LinearProgressIndicator(),
          if (_remoteDictionariesError != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 8, 0),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      displayText('詞典清單載入失敗，請檢查網絡後重試', context),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                        fontSize: 13,
                      ),
                    ),
                  ),
                  TextButton(
                    onPressed: _loadRemoteDictionaries,
                    child: Text(displayText('重試', context)),
                  ),
                ],
              ),
            ),
          if (fodictDownloadManager.error != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Text(
                fodictDownloadManager.error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          Expanded(child: _buildDictionaryPickerList()),
        ],
      ],
    );
  }

  Widget _buildDictionarySelectionToolbar() {
    final manager = fodictDownloadManager;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Row(
        children: [
          TextButton(
            onPressed: availableDictionaries.isEmpty
                ? null
                : () => setState(() {
                    if (selectedDictionaries.length ==
                        availableDictionaries.length) {
                      selectedDictionaries.clear();
                    } else {
                      selectedDictionaries = availableDictionaries
                          .map((dict) => dict.id)
                          .toSet();
                    }
                  }),
            child: Text(
              selectedDictionaries.length == availableDictionaries.length
                  ? displayText('全不選', context)
                  : displayText('全選', context),
            ),
          ),
          const SizedBox(width: 4),
          Expanded(
            child: manager.hasQueuedItems
                ? Text(
                    displayText(
                      manager.currentTask == null
                          ? '${manager.queue.length} 個任務等待下載'
                          : '下載中 ${(manager.progress * 100).toStringAsFixed(0)}%',
                      context,
                    ),
                    style: Theme.of(context).textTheme.bodySmall,
                  )
                : const SizedBox.shrink(),
          ),
          if (manager.isDownloading)
            IconButton(
              tooltip: displayText('暫停下載', context),
              onPressed: manager.pauseDownload,
              icon: const Icon(Icons.pause_rounded, size: 20),
            )
          else if (manager.canResume)
            IconButton(
              tooltip: displayText('繼續下載', context),
              onPressed: manager.resumeDownload,
              icon: const Icon(Icons.play_arrow_rounded, size: 20),
            ),
          IconButton(
            tooltip: displayText('重新整理詞典清單', context),
            onPressed: _loadingRemoteDictionaries
                ? null
                : _loadRemoteDictionaries,
            icon: const Icon(Icons.refresh_rounded, size: 20),
          ),
        ],
      ),
    );
  }

  Widget _buildDictionaryPickerList() {
    final localById = {for (final dict in availableDictionaries) dict.id: dict};
    final remoteById = {for (final dict in _remoteDictionaries) dict.id: dict};
    final ids = <String>{...localById.keys, ...remoteById.keys}.toList()
      ..sort();
    if (ids.isEmpty) {
      return Center(
        child: Text(
          displayText(
            _loadingRemoteDictionaries ? '正在取得詞典清單…' : '沒有可用詞典',
            context,
          ),
        ),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.only(bottom: 8),
      itemCount: ids.length,
      itemBuilder: (context, index) {
        final id = ids[index];
        return _buildDictionaryPickerTile(id, localById[id], remoteById[id]);
      },
    );
  }

  Widget _buildDictionaryPickerTile(
    String id,
    FodictInfo? local,
    FodictRemoteDictionary? remote,
  ) {
    final manager = fodictDownloadManager;
    final installed = local != null || manager.isInstalled(id);
    final bundled = manager.isBundled(id);
    final update = remote != null && manager.hasUpdate(remote);
    final current = manager.currentTask?.id == id;
    final selected = selectedDictionaries.contains(id);
    final name = local?.name ?? remote?.name ?? id;
    FodictDownloadTask? task;
    for (final item in manager.queue) {
      if (item.id == id) {
        task = item;
        break;
      }
    }

    final subtitle = StringBuffer(id);
    final size = local?.datSize ?? remote?.zipSize ?? 0;
    if (size > 0) subtitle.write(' · ${_formatDictSize(size)}');
    if (remote != null && remote.entries > 0) {
      subtitle.write(' · ${remote.entries} ${displayText('條', context)}');
    }
    if (bundled) {
      subtitle.write(' · ${displayText('內建', context)}');
    } else if (installed) {
      subtitle.write(' · ${displayText('已安裝', context)}');
      if (update) subtitle.write(' · ${displayText('有新版本', context)}');
    } else if (remote != null && !remote.available) {
      subtitle.write(' · ${displayText('尚未上傳', context)}');
    }

    final subtitleStyle = Theme.of(context).textTheme.bodySmall;
    final actions = _buildDictionaryPickerActions(
      id: id,
      name: name,
      remote: remote,
      installed: installed,
      bundled: bundled,
      update: update,
      task: task,
      current: current,
    );
    final subtitleWidget = current
        ? _buildDictionaryTaskProgress(subtitleStyle)
        : Text(subtitle.toString(), style: subtitleStyle);

    if (installed) {
      return CheckboxListTile(
        value: selected,
        onChanged: (value) => setState(() {
          if (value == true) {
            selectedDictionaries.add(id);
          } else {
            selectedDictionaries.remove(id);
          }
        }),
        title: Text(displayText(name, context)),
        subtitle: subtitleWidget,
        isThreeLine: current,
        secondary: actions,
        dense: true,
        controlAffinity: ListTileControlAffinity.leading,
      );
    }
    return ListTile(
      leading: Icon(
        bundled ? Icons.menu_book_rounded : Icons.book_outlined,
        size: 20,
      ),
      title: Text(displayText(name, context)),
      subtitle: subtitleWidget,
      isThreeLine: current,
      trailing: actions,
      dense: true,
    );
  }

  Widget _buildDictionaryPickerActions({
    required String id,
    required String name,
    required FodictRemoteDictionary? remote,
    required bool installed,
    required bool bundled,
    required bool update,
    required FodictDownloadTask? task,
    required bool current,
  }) {
    final manager = fodictDownloadManager;
    if (task != null) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (current)
            SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                value: manager.progress,
              ),
            )
          else
            const Icon(Icons.schedule_rounded, size: 20),
          IconButton(
            tooltip: displayText('移除此下載任務', context),
            visualDensity: VisualDensity.compact,
            onPressed: () => manager.removeTask(id),
            icon: const Icon(Icons.close_rounded, size: 20),
          ),
        ],
      );
    }
    if (bundled) {
      return Text(
        displayText('內建', context),
        style: TextStyle(color: Theme.of(context).colorScheme.primary),
      );
    }
    if (update && remote != null) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: displayText('刪除本地詞典', context),
            visualDensity: VisualDensity.compact,
            onPressed: () => _confirmDeleteFodict(id, name),
            icon: const Icon(Icons.delete_outline, size: 20),
          ),
          TextButton(
            onPressed: () => _startFodictDownload(remote),
            child: Text(displayText('更新', context)),
          ),
        ],
      );
    }
    if (installed) {
      return IconButton(
        tooltip: displayText('刪除本地詞典', context),
        visualDensity: VisualDensity.compact,
        onPressed: () => _confirmDeleteFodict(id, name),
        icon: const Icon(Icons.delete_outline, size: 20),
      );
    }
    if (remote != null && remote.available) {
      return FilledButton.tonal(
        onPressed: () => _startFodictDownload(remote),
        child: Text(displayText('下載', context)),
      );
    }
    return const Icon(Icons.cloud_off_outlined, size: 20);
  }

  Widget _buildDictionaryTaskProgress(TextStyle? style) {
    final manager = fodictDownloadManager;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 4),
        LinearProgressIndicator(value: manager.progress),
        const SizedBox(height: 2),
        Text(
          '${formatDownloadBytes(manager.receivedBytes)} / '
          '${formatDownloadBytes(manager.totalBytes)} · '
          '${formatDownloadSpeed(manager.downloadSpeedBytesPerSecond)}',
          style: style,
        ),
      ],
    );
  }

  String _formatDictSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  @override
  void dispose() {
    for (final entry in _scrollControllers.entries) {
      if (entry.value.hasClients) {
        _savedScrollOffsets[entry.key] = entry.value.offset;
      }
      entry.value.dispose();
    }
    unawaited(_saveSnapshot());
    _tabController.dispose();
    fodictDownloadManager.removeListener(_onFodictDownloadManagerChanged);
    CatalogCache.instance.removeListener(_onCatalogReloaded);
    creatorController.dispose();
    tocController.dispose();
    gotoController.dispose();
    dictionaryController.dispose();
    super.dispose();
  }

  Future<void> _saveSnapshot() {
    final levels = <int, List<PickerCatalogLevel>>{};
    for (final entry in catalogLevels.entries) {
      if (entry.value.isEmpty) continue;
      levels[entry.key] = [
        for (final level in entry.value)
          PickerCatalogLevel(q: level.q, label: level.label),
      ];
    }
    final restoresWorksView =
        selectedTab == _tabCreator ||
        selectedTab == _tabDynasty ||
        selectedTab == _tabJingMu;
    return saveWorkPickerSnapshot(
      WorkPickerSnapshot(
        tab: selectedTab,
        scrollOffsets: Map.of(_savedScrollOffsets),
        dictionaryQuery: dictionaryController.text.trim(),
        dictionaryExpandedIds: Set.of(_expandedDictionaryIds),
        dictionaryExpandedEntryKeys: Set.of(_expandedEntryKeys),
        catalogLevels: levels,
        creatorQuery: creatorController.text,
        tocQuery: tocController.text,
        gotoQuery: gotoController.text,
        showingWorks: restoresWorksView && showingWorks,
        listedWorks: restoresWorksView && showingWorks
            ? List.of(listedWorks)
            : const [],
        resultMessage: resultMessage,
      ),
    );
  }
}
