import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart' hide Text;
import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../dictionary/fodict_service.dart';
import '../scripture/cache.dart';
import '../scripture/index_update_service.dart';
import '../scripture/index_update_status.dart';
import '../scripture/models.dart';
import '../scripture/offline_scan.dart';
import '../search/candidates.dart';
import '../search/conversion.dart';
import '../search/goto.dart';
import '../search/history.dart';
import '../search/offline_preference.dart';
import '../common/app_lifecycle.dart';
import '../common/cbeta_http_client.dart';
import '../download/catalog_cache.dart';
import '../download/download_status_ui.dart';
import '../settings/display_settings.dart';
import '../feedback/feedback_dialog.dart';
import '../ai/ai_search_page.dart';
import '../app_update/app_update.dart';
import '../dictionary/dictionary_sticky_headers.dart';
import '../reader/reader_page.dart';
import '../reader/reader_store.dart';
import '../search/full_text_search_page.dart';
import '../search/passage_resolver.dart';
import '../search/search_api.dart';
import '../settings/display_settings_ui.dart';
import '../widgets/display_text.dart';
import '../widgets/result_widgets.dart';
import '../work_picker/work_picker_page.dart';

class ScriptureSearchPage extends StatefulWidget {
  const ScriptureSearchPage({super.key, this.indexUpdateService});

  /// 測試可注入假的索引更新服務；正式路徑使用全域單例。
  final IndexUpdateService? indexUpdateService;

  @override
  State<ScriptureSearchPage> createState() => ScriptureSearchPageState();
}

class ScriptureSearchPageState extends State<ScriptureSearchPage>
    with WidgetsBindingObserver {
  final searchController = TextEditingController();
  final searchFieldAnchorKey = GlobalKey();
  final resultsScrollController = ScrollController();
  String submittedQuery = '';
  List<ScriptureSearchResult> results = const [];
  bool isLoading = false;
  bool isKeywordSearchPending = false;
  bool isCatalogSearchPending = false;
  bool isLoadingMore = false;
  bool hasMore = false;
  String? errorMessage;
  String? loadMoreError;
  String? keywordSearchError;
  String? catalogSearchError;
  bool keywordSearchSucceeded = false;
  bool catalogSearchSucceeded = false;
  List<Map<String, dynamic>> catalogSearchResults = const [];
  bool showAllCatalogResults = false;
  List<FodictEntry> dictionarySearchResults = const [];
  bool isDictionarySearchPending = false;
  String? dictionarySearchError;
  bool showAllDictionaryResults = false;
  bool catalogSectionExpanded = true;
  bool dictionarySectionExpanded = true;
  bool keywordSectionExpanded = true;
  int nextStart = 0;
  int totalFound = 0;
  int totalTermHits = 0;
  int totalHitVolumes = 0;
  int requestToken = 0;

  /// 分組結果的快取。分組本身是 O(命中數) 的列表重建,不該在每次
  /// 全頁重建時重跑;簽名同時捕捉順序與每組命中數,因此就地排序
  /// 或載入更多都會讓它失效。
  List<ScriptureSearchResult>? _groupedResultsCache;
  String _groupedResultsSignature = '';

  /// 自動載入更多但沒有任何進展時停住,避免捲動事件每幀重複觸發掃描。
  bool _scrollLoadMoreHalted = false;
  int catalogVisibleCount = 1;
  int dictionaryVisibleCount = 1;

  /// 離線連續掃描動輒累積數百卷,正文分區一次只渲染這麼多部作品,
  /// 全部建立成 Card 會讓路由轉場的每一幀都重畫整串卡片;
  /// 捲動到底會自動再放行一頁,「載入更多結果」只在線上分批時出現。
  int keywordVisibleGroups = resultSectionPageSize;
  int _keywordTotalGroups = 0;

  /// 正文搜尋結果中當前展開的 work key，用於實現互斥展開。
  String? _expandedWorkKey;

  /// 正在做第二階段展開的作品，避免連續點擊同一部經重複解析。
  final Set<String> _expandingOfflineWorks = {};

  /// 主頁字典搜尋結果中當前展開的詞典 ID，用於實現互斥展開。
  final Set<String> _expandedDictionaryIds = {};

  /// 主頁字典搜尋結果中已展開的詞條（`dictionaryId:keyword`）。
  final Set<String> _expandedHomepageDictionaryEntries = {};

  List<ReaderBookmark> recentReadings = [];
  List<ReaderBookmark> homeBookmarks = [];
  List<String> recentSearches = [];
  int recentReadingsVisibleCount = initialRecentReadingsCount;
  bool showAllHomeBookmarks = false;
  bool aiMode = false;
  bool offlineSearchActive = false;
  OfflineScanSession? offlineSearchSession;
  int offlineScannedVolumes = 0;
  int offlineTotalVolumes = 0;

  /// 索引版本落後時，離線全文搜尋不掃舊索引，改顯示更新進度並等待完成。
  bool waitingForIndexUpdate = false;

  /// 連續掃描每一塊都會更新進度;先把這些更新合併,最多每 300 毫秒才寫回
  /// state,否則掃描期間會不斷重建整個結果頁。
  static const Duration _offlinePublishInterval = Duration(milliseconds: 300);
  Timer? _offlinePublishTimer;
  OfflineScanProgress? _pendingOfflineProgress;

  /// 聯網模式連不上伺服器時的提示；[connectionFailureHasLocal] 決定是否
  /// 提供「改用離線搜尋」。離線模式下一卷都沒有時用 [offlineVolumesMissing]。
  bool connectionFailurePrompt = false;
  bool connectionFailureHasLocal = false;
  bool offlineVolumesMissing = false;

  /// 連線已建立但伺服器算得比 5 秒久時，提供手動切離線的入口，不中止請求。
  bool serverSlowHint = false;
  Timer? _serverSlowTimer;

  bool _lastOfflineMode = false;
  bool _modeChangePending = false;
  ModalRoute<Object?>? _ownRoute;
  bool _offlineScanPausedByUser = false;
  bool _offlineScanPausedByLifecycle = false;

  /// 結果頁被上一頁（閱讀器等）完全蓋住時自動停下掃描，回到結果頁才接上。
  bool _offlineScanHaltedByOverlay = false;
  AppUpdateInfo? _availableUpdate;
  String _currentVersion = '';
  bool _autoUpdatePromptScheduled = false;
  Future<AppUpdateCheckResult>? _appUpdateCheckInFlight;
  bool _isUpdating = false;
  bool _awaitingInstallPermission = false;
  bool _installLaunched = false;
  String? _pendingInstallApkPath;
  String? _fodictBaseDir;
  Future<void>? _fodictBaseDirTask;
  SearchSelection? _pendingSearchSelection;

  /// 最近一次真正送出全文搜尋的原始輸入（用來辨認「輸入沒變的重複點擊」）。
  String _lastSubmittedRawInput = '';
  final FodictService _fodictService = FodictService();

  IndexUpdateService get _indexUpdate =>
      widget.indexUpdateService ?? indexUpdateService;

  /// 背景索引更新也使用同一個常駐池；它還在跑時拆掉 worker，下一批索引
  /// 會退回主 isolate 解析 HTML。
  void _releaseOfflineScanPool() {
    if (_indexUpdate.isActive) return;
    releaseSharedOfflineScanPool();
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    scriptureDisplaySettings.addListener(_onDisplaySettingsChanged);
    resultsScrollController.addListener(_onResultsScroll);
    _loadHomeSections();
    _fodictBaseDirTask = _loadFodictBaseDir();
    unawaited(_checkForAppUpdate(promptIfAvailable: true));
    // 經目查詢改走本地全量目錄,先暖好，第一次搜尋才不用等解析 4 MB JSON。
    unawaited(CatalogCache.instance.load().catchError((_) {}));
    // 離線模式要在第一次搜尋前就知道狀態；main() 已先載入，這裡再保險一次。
    _lastOfflineMode = offlineMode;
    offlineModeListenable.addListener(_onOfflineModeChanged);
    _indexUpdate.addListener(_onIndexUpdateChanged);
    unawaited(loadOfflineMode());
  }

  void _onIndexUpdateChanged() {
    if (!mounted || !waitingForIndexUpdate) return;
    setState(() {});
  }

  void _onOfflineModeChanged() {
    if (!mounted) return;
    final changed = _lastOfflineMode != offlineMode;
    _lastOfflineMode = offlineMode;
    setState(() {});
    if (!changed || submittedQuery.isEmpty) return;
    _modeChangePending = true;
    // 閱讀器可能蓋在首頁上；等轉場結束後再重跑，避免在背景掃描整藏。
    if (!(_ownRoute?.isCurrent ?? true)) return;
    _restartKeywordSearchForMode();
  }

  void _restartKeywordSearchForMode() {
    if (submittedQuery.isEmpty) return;
    _modeChangePending = false;
    final token = ++requestToken;
    _stopOfflineScan();
    _serverSlowTimer?.cancel();
    _serverSlowTimer = null;
    setState(() {
      results = const [];
      keywordSearchError = null;
      loadMoreError = null;
      keywordSearchSucceeded = false;
      offlineSearchActive = false;
      offlineVolumesMissing = false;
      connectionFailurePrompt = false;
      serverSlowHint = false;
      offlineScannedVolumes = 0;
      offlineTotalVolumes = 0;
      waitingForIndexUpdate = false;
      isLoading = true;
      isKeywordSearchPending = true;
      isLoadingMore = false;
      hasMore = false;
      nextStart = 0;
      totalFound = 0;
      totalTermHits = 0;
      keywordVisibleGroups = resultSectionPageSize;
      _scrollLoadMoreHalted = false;
    });
    unawaited(_loadKeywordResults(submittedQuery, token));
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (!identical(route, _ownRoute)) {
      _ownRoute?.secondaryAnimation?.removeListener(_onRouteTransitionChanged);
      _ownRoute = route;
      route?.secondaryAnimation?.addListener(_onRouteTransitionChanged);
    }
  }

  /// 上方頁面完全蓋住或移開時,轉場已經結束,這時才補上留住的掃描進度。
  void _onRouteTransitionChanged() {
    final animation = _ownRoute?.secondaryAnimation;
    if (animation == null) return;
    if (animation.status == AnimationStatus.completed) {
      // 結果頁已經看不見了：不再排下一塊，也把 worker 還給系統。
      // 留著掃描等於使用者在讀經文時主執行緒還被一批批經卷排著。
      final session = offlineSearchSession;
      if (session != null && session.scanning) {
        _offlineScanHaltedByOverlay = true;
        session.pause();
      }
      _releaseOfflineScanPool();
      return;
    }
    if (animation.status != AnimationStatus.dismissed) return;
    if (_offlineScanHaltedByOverlay) {
      _offlineScanHaltedByOverlay = false;
      final session = offlineSearchSession;
      if (session != null && !session.finished && !_offlineScanPausedByUser) {
        session.resume();
      }
    }
    if (_modeChangePending) {
      _restartKeywordSearchForMode();
      return;
    }
    if (_pendingOfflineProgress != null &&
        !(_offlinePublishTimer?.isActive ?? false)) {
      _flushOfflineScan();
    }
  }

  Future<void> _loadFodictBaseDir() async {
    try {
      final baseDir = await FodictService.defaultBaseDir();
      if (!mounted) return;
      setState(() => _fodictBaseDir = baseDir);
    } catch (_) {
      // 沒有字典目錄時仍可搜尋，只是不統計 key 命中次數。
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      // 離開前台時先暫停離線掃描,回到前台再自動接上。
      if (offlineSearchSession != null &&
          !_offlineScanPausedByUser &&
          !_offlineScanPausedByLifecycle) {
        offlineSearchSession?.pause();
        _offlineScanPausedByLifecycle = true;
      }
      return;
    }
    if (_offlineScanPausedByLifecycle) {
      _offlineScanPausedByLifecycle = false;
      final session = offlineSearchSession;
      // 回到前台但結果頁還被上一頁蓋著：維持停住，等轉場結束再說。
      final isCovered =
          _offlineScanHaltedByOverlay || !(_ownRoute?.isCurrent ?? true);
      if (session != null &&
          !session.finished &&
          !_offlineScanPausedByUser &&
          !isCovered) {
        session.resume();
        setState(() {});
      }
    }
    final apkPath = _pendingInstallApkPath;
    if (_awaitingInstallPermission) {
      _awaitingInstallPermission = false;
      if (apkPath == null) return;
      // 給予系統一點時間處理設定頁返回，再自動繼續安裝。
      unawaited(
        Future<void>.delayed(const Duration(milliseconds: 400), () async {
          if (!mounted) return;
          if (!await File(apkPath).exists()) {
            await _showUpdateError('安裝失敗', '更新檔案已不存在，請重新下載');
            return;
          }
          if (await canInstallApk()) {
            await _launchInstallerSafely(apkPath);
          } else {
            // 設定尚未生效時再次顯示權限指引。
            await _installDownloadedApk(apkPath);
          }
        }),
      );
      return;
    }
    if (_installLaunched) {
      _installLaunched = false;
      if (apkPath == null) return;
      unawaited(_promptRetryInstall(apkPath));
    }
  }

  Future<void> _promptRetryInstall(String apkPath) async {
    if (!mounted || !await File(apkPath).exists()) return;
    if (!mounted) return;
    final retry = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('安裝尚未完成'),
        content: const Text('是否再次開啟系統安裝程式？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('稍後'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('再次安裝'),
          ),
        ],
      ),
    );
    if (retry == true) {
      await _launchInstallerSafely(apkPath);
    }
  }

  Future<AppUpdateCheckResult> _checkForAppUpdate({
    bool promptIfAvailable = false,
  }) {
    final existing = _appUpdateCheckInFlight;
    if (existing != null) return existing;
    final future = _runAppUpdateCheck(promptIfAvailable: promptIfAvailable);
    _appUpdateCheckInFlight = future;
    unawaited(
      future.whenComplete(() {
        if (identical(_appUpdateCheckInFlight, future)) {
          _appUpdateCheckInFlight = null;
        }
      }),
    );
    return future;
  }

  Future<AppUpdateCheckResult> _runAppUpdateCheck({
    required bool promptIfAvailable,
  }) async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      return const AppUpdateCheckResult.upToDate();
    }
    try {
      final packageInfo = await PackageInfo.fromPlatform();
      final info = await fetchLatestGiteeRelease(
        preferredAbis: await deviceAbis(),
      );
      final hasUpdate =
          info != null && isNewerVersion(info.version, packageInfo.version);
      final pendingPath = hasUpdate
          ? await _restorePendingUpdateApk(info.version)
          : null;
      if (!hasUpdate) {
        await _clearPendingUpdate();
      }
      if (mounted) {
        setState(() {
          _currentVersion = packageInfo.version;
          _availableUpdate = hasUpdate ? info : null;
          _pendingInstallApkPath = pendingPath;
        });
      }
      if (hasUpdate) {
        if (promptIfAvailable) _scheduleAutoUpdatePrompt();
        return AppUpdateCheckResult.updateAvailable(info);
      }
      return const AppUpdateCheckResult.upToDate();
    } catch (_) {
      // 檢查更新失敗時保持安靜，避免影響正常使用；手動檢查會回報失敗。
      return const AppUpdateCheckResult.failed();
    }
  }

  void _scheduleAutoUpdatePrompt() {
    if (_autoUpdatePromptScheduled) return;
    _autoUpdatePromptScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      if (!await loadAutoUpdatePromptEnabled() || !mounted) return;
      final route = _ownRoute;
      if (route != null && !route.isCurrent) return;
      unawaited(_promptForAppUpdate(fromAutoPrompt: true));
    });
  }

  Future<String?> _restorePendingUpdateApk(String version) async {
    try {
      final preferences = await SharedPreferences.getInstance();
      if (preferences.getString(pendingUpdateVersionKey) != version) {
        return null;
      }
      final path = preferences.getString(pendingUpdatePathKey);
      if (path == null) return null;
      return await File(path).exists() ? path : null;
    } catch (_) {
      return null;
    }
  }

  Future<void> _rememberPendingUpdate(String apkPath, String version) async {
    try {
      final preferences = await SharedPreferences.getInstance();
      await preferences.setString(pendingUpdatePathKey, apkPath);
      await preferences.setString(pendingUpdateVersionKey, version);
    } catch (_) {
      // 無法記住下載位置時，本次仍可直接安裝。
    }
  }

  Future<void> _clearPendingUpdate() async {
    _pendingInstallApkPath = null;
    try {
      final preferences = await SharedPreferences.getInstance();
      final path = preferences.getString(pendingUpdatePathKey);
      await preferences.remove(pendingUpdatePathKey);
      await preferences.remove(pendingUpdateVersionKey);
      if (path != null) {
        final file = File(path);
        if (await file.exists()) await file.delete();
      }
    } catch (_) {
      // 忽略清理暫存檔失敗。
    }
  }

  Future<void> _promptForAppUpdate({bool fromAutoPrompt = false}) async {
    final info = _availableUpdate;
    if (info == null || _isUpdating || !mounted) return;
    final notes = releaseNotesForDisplay(info.releaseNotes);
    final releaseName = info.releaseName.trim();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('發現新版本 ${info.version}'),
        content: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: 480,
            maxHeight: MediaQuery.sizeOf(dialogContext).height * 0.55,
          ),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '目前版本：${_currentVersion.isEmpty ? '未知' : _currentVersion}',
                ),
                if (releaseName.isNotEmpty && releaseName != info.version) ...[
                  const SizedBox(height: 6),
                  Text(
                    releaseName,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ],
                if (notes.isNotEmpty) ...[
                  const SizedBox(height: 14),
                  const Text(
                    '更新內容',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 6),
                  Text(notes),
                ],
                const SizedBox(height: 14),
                const Text(
                  '將從 Gitee 下載最新 APK 並覆蓋安裝，'
                  '已下載的經文與偏好設定都會保留。',
                ),
                if (fromAutoPrompt) ...[
                  const SizedBox(height: 8),
                  const Text(
                    '取消後將不再自動提示更新，'
                    '你仍可在「介面設定」中手動檢查；'
                    '手動完成一次更新後會恢復自動提示。',
                  ),
                ],
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('立即更新'),
          ),
        ],
      ),
    );
    if (confirmed != true) {
      if (fromAutoPrompt) await saveAutoUpdatePromptEnabled(false);
      return;
    }
    if (!mounted) return;
    await _performAppUpdate(info);
  }

  Future<void> _performAppUpdate(AppUpdateInfo info) async {
    if (_isUpdating || !mounted) return;

    // 若先前已下載同一版本，直接沿用，避免重複下載。
    // 使用者主動下載更新後，恢復啟動時自動提示新版本。
    final cachedApk =
        _pendingInstallApkPath ?? await _restorePendingUpdateApk(info.version);
    if (cachedApk != null && await File(cachedApk).exists()) {
      _pendingInstallApkPath = cachedApk;
      await saveAutoUpdatePromptEnabled(true);
      await _installDownloadedApk(cachedApk);
      return;
    }

    if (!mounted) return;
    setState(() => _isUpdating = true);
    final progress = ValueNotifier<double?>(null);
    final navigator = Navigator.of(context, rootNavigator: true);
    var dialogOpen = true;
    unawaited(
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) =>
            UpdateProgressDialog(progress: progress, version: info.version),
      ),
    );

    final String apkPath;
    try {
      apkPath = await downloadUpdateApk(info, progress);
    } catch (error) {
      if (dialogOpen && navigator.canPop()) {
        navigator.pop();
        dialogOpen = false;
      }
      if (mounted) {
        setState(() => _isUpdating = false);
        await _showUpdateError('下載失敗', error);
      }
      return;
    }

    if (dialogOpen && navigator.canPop()) {
      navigator.pop();
      dialogOpen = false;
    }
    _pendingInstallApkPath = apkPath;
    await saveAutoUpdatePromptEnabled(true);
    await _rememberPendingUpdate(apkPath, info.version);
    if (!mounted) return;
    setState(() => _isUpdating = false);
    await _installDownloadedApk(apkPath);
  }

  Future<void> _installDownloadedApk(String apkPath) async {
    _pendingInstallApkPath = apkPath;
    if (await canInstallApk()) {
      await _launchInstallerSafely(apkPath);
      return;
    }
    if (!mounted) return;
    final action = await showDialog<InstallPermissionAction>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('需要安裝權限'),
        content: const Text(
          '系統目前未允許「Fodian」安裝應用程式。\n\n'
          '請點「前往設定」，確認設定頁上方顯示的是「Fodian」，'
          '並開啟「允許安裝未知應用程式」。\n\n'
          '如果該頁顯示 Fodian 已經允許，可選「仍然嘗試安裝」。',
        ),
        actions: [
          TextButton(
            onPressed: () =>
                Navigator.pop(dialogContext, InstallPermissionAction.cancel),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () =>
                Navigator.pop(dialogContext, InstallPermissionAction.proceed),
            child: const Text('仍然嘗試'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.pop(dialogContext, InstallPermissionAction.settings),
            child: const Text('前往設定'),
          ),
        ],
      ),
    );
    if (!mounted) return;
    switch (action) {
      case InstallPermissionAction.settings:
        _awaitingInstallPermission = true;
        await openInstallPermissionSettings();
      case InstallPermissionAction.proceed:
        await _launchInstallerSafely(apkPath);
      case InstallPermissionAction.cancel:
      case null:
        break;
    }
  }

  Future<void> _launchInstallerSafely(String apkPath) async {
    try {
      await launchApkInstaller(apkPath);
      _installLaunched = true;
    } on InstallPermissionRequiredException catch (error) {
      if (!mounted) return;
      final openSettings = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('需要安裝權限'),
          content: Text(
            '${error.message}\n\n請在系統設定中允許「Fodian」安裝未知來源的應用程式，'
            '返回 App 後會自動繼續安裝。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('前往設定'),
            ),
          ],
        ),
      );
      if (openSettings == true) {
        _awaitingInstallPermission = true;
        await openInstallPermissionSettings();
      }
    } catch (error) {
      if (!mounted) return;
      final openSettings = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('無法啟動安裝'),
          content: Text('$error\n\n若系統不允許安裝，請開啟「安裝未知應用程式」權限後再試一次。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('前往設定'),
            ),
          ],
        ),
      );
      if (openSettings == true) {
        _awaitingInstallPermission = true;
        await openInstallPermissionSettings();
      }
    }
  }

  Future<void> _showUpdateError(String title, Object error) async {
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: Text('$error'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }

  void _onDisplaySettingsChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _loadHomeSections() async {
    try {
      final history = await loadBookmarkRecords(readingHistoryKey);
      final bookmarks = await loadBookmarks();
      final searches = await loadSearchHistory();
      if (!mounted) return;
      setState(() {
        recentReadings = history;
        homeBookmarks = bookmarks;
        recentSearches = searches;
      });
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('載入閱讀記錄失敗：$error')));
    }
  }

  void _onResultsScroll() {
    if (!resultsScrollController.hasClients) return;
    if (resultsScrollController.position.extentAfter >= 400) return;
    // 離線掃描的結果是自己累積上來的,捲到底就再放行一頁作品卡片。
    if (offlineSearchActive) {
      _revealMoreKeywordGroups();
      return;
    }
    if (_scrollLoadMoreHalted) return;
    loadMore(fromScroll: true);
  }

  void _revealMoreKeywordGroups() {
    if (keywordVisibleGroups >= _keywordTotalGroups) return;
    setState(() => keywordVisibleGroups += resultSectionPageSize);
  }

  Future<void> search([String? value]) async {
    final raw = (value ?? searchController.text).trim();
    if (value != null) searchController.text = raw;
    final pending = _pendingSearchSelection;
    _pendingSearchSelection = null;
    if (pending != null && (raw == pending.rawInput || raw == pending.query)) {
      await _executeSearch(pending.rawInput, pending.query);
      return;
    }
    await _executeSearch(raw, null);
  }

  Future<void> _onSearchSelection(SearchSelection selection) async {
    final raw = selection.rawInput.trim();
    final pending = _pendingSearchSelection;
    _pendingSearchSelection = null;
    if (pending != null && (raw == pending.rawInput || raw == pending.query)) {
      await _executeSearch(pending.rawInput, pending.query);
      return;
    }
    await _executeSearch(raw, selection.query);
  }

  Future<void> _executeSearch(String rawInput, String? selectedQuery) async {
    // 輸入沒變就再點一次搜尋：全文、經目、字典三條管線會全部重跑，畫面上的結果
    // 先被清空、字典還要重解析整本，看起來就是卡好幾秒。這種點擊當沒發生過。
    if (rawInput.isNotEmpty && rawInput == _lastSubmittedRawInput) return;
    final token = ++requestToken;
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    FocusScope.of(context).unfocus();
    if (rawInput.isEmpty) {
      _lastSubmittedRawInput = '';
      setState(() {
        submittedQuery = '';
        results = const [];
        catalogSearchResults = const [];
        dictionarySearchResults = const [];
        isDictionarySearchPending = false;
        dictionarySearchError = null;
        showAllCatalogResults = false;
        showAllDictionaryResults = false;
        catalogSectionExpanded = true;
        dictionarySectionExpanded = true;
        keywordSectionExpanded = true;
        errorMessage = null;
        isLoading = false;
        isKeywordSearchPending = false;
        isCatalogSearchPending = false;
        hasMore = false;
        nextStart = 0;
        totalFound = 0;
        totalTermHits = 0;
        offlineVolumesMissing = false;
        connectionFailurePrompt = false;
        serverSlowHint = false;
      });
      return;
    }

    // Goto 只作用于首页关键字搜索，且必须早于简繁转换。
    if (isCbetaGotoExpression(rawInput)) {
      try {
        await _recordSearchEntry(rawInput, rawInput);
      } catch (error) {
        if (mounted) {
          messenger.showSnackBar(SnackBar(content: Text('儲存搜尋記錄失敗：$error')));
        }
      }
      if (!mounted || token != requestToken) return;
      await _openGotoSearch(rawInput, token);
      return;
    }

    if (aiMode) {
      if (offlineMode) {
        messenger.showSnackBar(
          const SnackBar(content: Text('離線模式下不支援 AI 搜尋，請先切換到聯網模式。')),
        );
        return;
      }
      try {
        await _recordSearchEntry(rawInput, rawInput);
      } catch (error) {
        if (mounted) {
          messenger.showSnackBar(SnackBar(content: Text('儲存搜尋記錄失敗：$error')));
        }
      }
      if (!mounted || token != requestToken) return;
      navigator.push(
        MaterialPageRoute<void>(
          builder: (_) => AiSearchPage(initialQuery: rawInput),
        ),
      );
      return;
    }

    var query = selectedQuery?.trim() ?? '';
    if (query.isEmpty) {
      Map<String, String> selections = const {};
      try {
        selections = await loadSearchSelections();
      } catch (_) {
        // 歷史記錄損壞時不影響搜尋。
      }
      query = await resolveSearchQuery(rawInput, selections: selections);
    }
    if (query.isEmpty) return;
    if (!mounted || token != requestToken) return;

    try {
      await _recordSearchEntry(rawInput, query);
    } catch (error) {
      if (mounted) {
        messenger.showSnackBar(SnackBar(content: Text('儲存搜尋記錄失敗：$error')));
      }
    }
    if (!mounted || token != requestToken) return;
    // 未選候選時實際查詢詞是簡繁轉換的結果，輸入框若仍留原字，看起來就像搜的是
    // 那幾個簡體字。同步成實際查詢詞，與點選候選後的行為一致。
    if (query != searchController.text) {
      searchController.value = TextEditingValue(
        text: query,
        selection: TextSelection.collapsed(offset: query.length),
      );
    }
    // 攔截重複點擊的鍵必須是框裡最終的文字，否則轉換後再點一次會重跑三條管線。
    _lastSubmittedRawInput = query;
    await _runKeywordSearch(query, token);
  }

  Future<void> _recordSearchEntry(String rawInput, String selectedQuery) async {
    await recordSearchQuery(rawInput);
    await recordSearchSelection(rawInput, selectedQuery);
    if (!mounted) return;
    setState(() {
      recentSearches = [
        rawInput,
        ...recentSearches.where(
          (savedQuery) =>
              savedQuery.trim().toLowerCase() != rawInput.toLowerCase(),
        ),
      ].take(maximumSearchHistory).toList();
    });
  }

  Future<void> _runKeywordSearch(String query, int token) async {
    // 同一個字再搜一次時沿用還在跑（或已掃完）的本地掃描會話：
    // 重建會話要把兩萬多卷從頭再掃一遍，那就是重送搜尋卡住的來源。
    // 聯網模式不跑本地掃描，也就沒有會話可重用。
    final reuseOfflineScan =
        offlineMode && offlineSearchSession?.query == query;
    if (!reuseOfflineScan) _stopOfflineScan();
    _serverSlowTimer?.cancel();
    _serverSlowTimer = null;
    setState(() {
      submittedQuery = query;
      results = const [];
      errorMessage = null;
      loadMoreError = null;
      keywordSearchError = null;
      catalogSearchError = null;
      keywordSearchSucceeded = false;
      catalogSearchSucceeded = false;
      catalogSearchResults = const [];
      showAllCatalogResults = false;
      dictionarySearchResults = const [];
      dictionarySearchError = null;
      isDictionarySearchPending = true;
      showAllDictionaryResults = false;
      _expandedHomepageDictionaryEntries.clear();
      catalogSectionExpanded = true;
      dictionarySectionExpanded = true;
      keywordSectionExpanded = true;
      offlineSearchActive = false;
      offlineVolumesMissing = false;
      connectionFailurePrompt = false;
      connectionFailureHasLocal = false;
      serverSlowHint = false;
      offlineScannedVolumes = 0;
      offlineTotalVolumes = 0;
      waitingForIndexUpdate = false;
      isLoading = true;
      isKeywordSearchPending = true;
      isCatalogSearchPending = true;
      isLoadingMore = false;
      hasMore = false;
      nextStart = 0;
      totalFound = 0;
      totalTermHits = 0;
      catalogVisibleCount = 1;
      dictionaryVisibleCount = 1;
      keywordVisibleGroups = resultSectionPageSize;
      _scrollLoadMoreHalted = false;
    });
    if (resultsScrollController.hasClients) {
      resultsScrollController.jumpTo(0);
    }
    if (reuseOfflineScan) {
      // 同一個字重送：既有會話的結果直接畫回去。
      _publishOfflineScan(offlineSearchSession!.current);
    }

    unawaited(_loadKeywordResults(query, token));
    unawaited(_loadCatalogSearchResults(query, token));
    unawaited(_loadDictionarySearchResults(query, token));
  }

  Future<bool> _hasLocalVolumes() async {
    try {
      return (await scriptureVolumeStore.listRefs()).isNotEmpty;
    } catch (_) {
      // 本地清單讀不到只影響能不能提示離線替代方案，不能拖累線上搜尋。
      return false;
    }
  }

  void _scheduleServerSlowHint(int token) {
    _serverSlowTimer?.cancel();
    _serverSlowTimer = Timer(cbetaConnectTimeout, () async {
      if (!mounted || token != requestToken || offlineMode) return;
      final hasLocal = await _hasLocalVolumes();
      if (!mounted || token != requestToken || !hasLocal) return;
      setState(() => serverSlowHint = true);
    });
  }

  Future<void> _loadKeywordResults(String query, int token) async {
    _serverSlowTimer?.cancel();
    _serverSlowTimer = null;
    try {
      if (kIsWeb) {
        throw Exception('CBETA 搜尋服務未開放網頁跨域存取；請使用桌面或行動版 App。');
      }
      if (offlineMode) {
        // 離線模式不發任何正文請求；一卷都沒有時直接引導下載或切回聯網。
        final hasLocal = await _hasLocalVolumes();
        if (!mounted || token != requestToken) return;
        if (!hasLocal) {
          setState(() {
            offlineSearchActive = true;
            offlineVolumesMissing = true;
            connectionFailurePrompt = false;
            keywordSearchSucceeded = true;
            keywordSearchError = null;
            isLoading = false;
            results = const [];
            hasMore = false;
            nextStart = 0;
            totalFound = 0;
            totalTermHits = 0;
          });
          return;
        }
        setState(() {
          offlineVolumesMissing = false;
          connectionFailurePrompt = false;
        });
        // 索引版本落後時，舊索引的正規化規則可能與目前程式不同；先等背景
        // 重建完成再掃，期間只顯示進度，不拿過期索引回答。
        final indexUpdate = _indexUpdate;
        if (indexUpdate.needsUpdate) {
          await indexUpdate.startIfNeeded();
          if (!mounted || token != requestToken) return;
        }
        if (indexUpdate.isActive) {
          _stopOfflineScan();
          setState(() {
            waitingForIndexUpdate = true;
            offlineSearchActive = true;
            offlineVolumesMissing = false;
            connectionFailurePrompt = false;
            serverSlowHint = false;
            keywordSearchSucceeded = true;
            keywordSearchError = null;
            isLoading = false;
            isKeywordSearchPending = false;
            results = const [];
            hasMore = false;
            nextStart = 0;
            totalFound = 0;
            totalTermHits = 0;
            offlineScannedVolumes = 0;
            offlineTotalVolumes = 0;
          });
          await indexUpdate.waitForCompletion();
          if (!mounted || token != requestToken) return;
          setState(() => waitingForIndexUpdate = false);
          if (!offlineMode) return;
        }
        await _applyOfflineKeywordResults(query, token);
        return;
      }

      final cached = FullTextSearchCache.get(query, offline: false);
      if (cached != null && mounted && token == requestToken) {
        // 同一個字再查一次時先用上次的線上結果頂住畫面,回覆後再整批取代;
        // 高频單字的 API 要等數秒,不該讓使用者對著轉圈發呆。
        setState(() {
          offlineSearchActive = false;
          offlineVolumesMissing = false;
          connectionFailurePrompt = false;
          keywordSearchSucceeded = true;
          isLoading = false;
          results = cached.results;
          nextStart = cached.nextStart;
          totalFound = cached.totalFound;
          totalTermHits = cached.totalTermHits;
          hasMore = cached.hasMore;
          _prioritizeSearchResultsByCatalog();
        });
      }
      _scheduleServerSlowHint(token);
      final batch = await _searchAllInOne(query, start: 0);
      _serverSlowTimer?.cancel();
      _serverSlowTimer = null;
      if (!mounted || token != requestToken) return;
      _stopOfflineScan();
      setState(() {
        offlineSearchActive = false;
        offlineVolumesMissing = false;
        connectionFailurePrompt = false;
        serverSlowHint = false;
        keywordSearchSucceeded = true;
        results = batch.results;
        nextStart = batch.nextStart;
        totalFound = batch.totalFound;
        totalTermHits = batch.totalTermHits;
        hasMore = batch.hasMore;
        offlineScannedVolumes = 0;
        offlineTotalVolumes = 0;
        _prioritizeSearchResultsByCatalog();
        FullTextSearchCache.remember(
          query,
          offline: false,
          results: results,
          nextStart: nextStart,
          totalFound: totalFound,
          totalTermHits: totalTermHits,
          hasMore: hasMore,
        );
      });
    } catch (error) {
      _serverSlowTimer?.cancel();
      _serverSlowTimer = null;
      if (!mounted || token != requestToken) return;
      if (isRequestTimeout(error)) {
        // 伺服器只是慢,不代表沒有網路。聯網模式不自動切本地，只提示可手動切換。
        final hasLocal = await _hasLocalVolumes();
        if (!mounted || token != requestToken) return;
        setState(() {
          serverSlowHint = hasLocal;
          keywordSearchError =
              '全文搜尋逾時（等待超過 ${keywordSearchTimeout.inSeconds} 秒）：'
              '常用單字伺服端要跑十幾秒以上，請稍後重試或改用較長的關鍵字。';
        });
        return;
      }
      if (isNetworkFailure(error)) {
        // 連線失敗不自動掃本地：聯網模式的結果必須來自伺服器，由使用者決定
        // 是否切換離線模式。
        final hasLocal = await _hasLocalVolumes();
        if (!mounted || token != requestToken) return;
        setState(() {
          connectionFailurePrompt = true;
          connectionFailureHasLocal = hasLocal;
          serverSlowHint = false;
          offlineSearchActive = false;
          offlineVolumesMissing = false;
          keywordSearchSucceeded = false;
          keywordSearchError = null;
          isLoading = false;
          results = const [];
          hasMore = false;
          nextStart = 0;
          totalFound = 0;
          totalTermHits = 0;
        });
        return;
      }
      setState(() => keywordSearchError = '全文搜尋失敗：$error');
    } finally {
      if (mounted && token == requestToken) {
        setState(() {
          isKeywordSearchPending = false;
          isLoading =
              results.isEmpty &&
              catalogSearchResults.isEmpty &&
              isCatalogSearchPending &&
              !connectionFailurePrompt &&
              !offlineVolumesMissing;
          _updateCombinedSearchError();
        });
      }
    }
  }

  Future<void> _loadCatalogSearchResults(String query, int token) async {
    try {
      // 經目分區完全離線回答：先用內建全量目錄的書名／編號查，查不到再看本地
      // 已儲存經卷的經名。伺服器的 toc 端點不吃 rows/start，常見字彙要回傳
      // 上千筆、七十秒左右，而且它是按朝代／譯者等元数据匹配，跟書名查詢
      // 不是同一件事（作譯者与年代在「選擇佛經」側欄有各自分頁）。
      var matches = await searchLocalCatalog(query);
      if (matches.isEmpty) {
        matches = await searchOfflineCatalog(
          query,
          // 這一圈要在主 isolate 上逐卷解析 HTML：使用者已經換了搜尋或離開頁面，
          // 就別再往下讀了，否則畫面換走了主執行緒還被排著。
          shouldAbort: () => !mounted || token != requestToken,
        );
      }
      if (!mounted || token != requestToken) return;
      setState(() {
        catalogSearchSucceeded = true;
        catalogSearchError = null;
        catalogSearchResults = matches;
        _prioritizeSearchResultsByCatalog();
        isLoading =
            results.isEmpty && matches.isEmpty && isKeywordSearchPending;
        _updateCombinedSearchError();
      });
    } finally {
      // 本地查不到也要清掉 pending：部分失敗的警告與 isLoading 都要等兩個
      // pending 都結束後才會更新，卡在 true 會讓全文逾時完全不被顯示。
      if (mounted && token == requestToken) {
        setState(() {
          isCatalogSearchPending = false;
          isLoading =
              results.isEmpty &&
              catalogSearchResults.isEmpty &&
              isKeywordSearchPending;
          _updateCombinedSearchError();
        });
      }
    }
  }

  Future<void> _loadDictionarySearchResults(String query, int token) async {
    try {
      await _fodictBaseDirTask;
      if (!mounted || token != requestToken) return;
      final baseDir = _fodictBaseDir ?? '';
      final variants = <String>[];
      void add(String value) {
        final text = value.trim();
        if (text.isEmpty || variants.contains(text)) return;
        variants.add(text);
      }

      add(query);
      add(SimplifiedTraditionalConverter.toSimplified(query));
      add(SimplifiedTraditionalConverter.toTraditionalDisplay(query));

      var matches = const <FodictEntry>[];
      for (final variant in variants) {
        final found = await _fodictService.searchByKey(
          baseDir,
          variant,
          maxResults: 100,
        );
        if (found.isEmpty) continue;
        matches = found;
        break;
      }
      if (!mounted || token != requestToken) return;
      setState(() {
        dictionarySearchError = null;
        isDictionarySearchPending = false;
        dictionarySearchResults = matches;
      });
    } catch (error) {
      if (!mounted || token != requestToken) return;
      setState(() {
        dictionarySearchError = '字典搜尋失敗：$error';
        isDictionarySearchPending = false;
      });
    }
  }

  Future<void> _applyOfflineKeywordResults(String query, int token) async {
    final existing = offlineSearchSession;
    if (existing != null && existing.query == query) {
      // 這一輪的本地掃描還在跑或已掃完：把進度画回去就好，不要再建第二個會話
      // 從第一卷重掃。
      _publishOfflineScan(existing.current);
      return;
    }
    _stopOfflineScan();
    final session = OfflineScanSession(query);
    offlineSearchSession = session;
    session.progress.addListener(_onOfflineScanProgress);
    await session.prepare();
    // 等待期間線上可能已经回来并停掉了这一轮扫描，别再发布旧会话的进度。
    if (!mounted ||
        token != requestToken ||
        !identical(offlineSearchSession, session)) {
      return;
    }
    // 先掃一塊讓首屏就有結果,其餘由會話自行連續推進,不再依賴捲動觸發。
    await session.scanChunk();
    if (!mounted ||
        token != requestToken ||
        !identical(offlineSearchSession, session)) {
      return;
    }
    _publishOfflineScan(session.current);
    if (!identical(offlineSearchSession, session)) return;
    if (!_offlineScanPausedByUser && !_offlineScanPausedByLifecycle) {
      session.start();
    }
  }

  void _stopOfflineScan() {
    _offlinePublishTimer?.cancel();
    _offlinePublishTimer = null;
    _pendingOfflineProgress = null;
    _expandingOfflineWorks.clear();
    _offlineScanPausedByUser = false;
    _offlineScanPausedByLifecycle = false;
    _offlineScanHaltedByOverlay = false;
    final session = offlineSearchSession;
    offlineSearchSession = null;
    if (session != null) {
      session.progress.removeListener(_onOfflineScanProgress);
      session.dispose();
    }
  }

  void _toggleOfflineScan() {
    final session = offlineSearchSession;
    if (session == null || session.finished) return;
    setState(() {
      if (session.scanning) {
        _offlineScanPausedByUser = true;
        session.pause();
      } else {
        _offlineScanPausedByUser = false;
        session.resume();
      }
    });
  }

  /// 全域離線模式開關：正文閱讀與正文搜尋一起切換。
  ///
  /// 真正的重跑交給 `_onOfflineModeChanged`，切回聯網時才會重新請求伺服器。
  void _toggleOfflineMode() {
    unawaited(setOfflineMode(!offlineMode));
  }

  void _switchToOfflineMode() => unawaited(setOfflineMode(true));

  void _retryKeywordSearch() {
    if (submittedQuery.isEmpty) return;
    final token = ++requestToken;
    _serverSlowTimer?.cancel();
    _serverSlowTimer = null;
    setState(() {
      connectionFailurePrompt = false;
      serverSlowHint = false;
      keywordSearchError = null;
      isLoading = true;
      isKeywordSearchPending = true;
    });
    unawaited(_loadKeywordResults(submittedQuery, token));
  }

  /// 第一階段只掃出（作品, 卷, 行號）；點開一部經時用 HTML 再比對一次，
  /// 摘要與 `sourceOffset` 都取自帶標點的原文。
  void _expandOfflineHits(ScriptureSearchResult result) {
    final session = offlineSearchSession;
    final work = result.workId;
    if (session == null || work.isEmpty || result.pendingHits.isEmpty) return;
    if (!_expandingOfflineWorks.add(work)) return;
    unawaited(() async {
      try {
        final passages = await expandOfflineWork(
          work: work,
          hits: session.pendingHitsFor(work),
          query: session.query,
          availableJuans: session.juansFor(work),
          // 離開頁面、換搜尋字（會話被換掉）就停手：展開要在主 isolate 上
          // 一卷一卷解析 HTML，不叫停的話使用者已經走了還在排隊。
          shouldAbort: () =>
              !mounted || !identical(offlineSearchSession, session),
        );
        if (!mounted) return;
        if (identical(offlineSearchSession, session)) {
          session.applyPassages(work, passages);
        }
      } catch (_) {
        // 展開失敗就維持在「只有行號」的狀態，使用者可以再點一次。
      } finally {
        _expandingOfflineWorks.remove(work);
      }
    }());
  }

  void _onOfflineScanProgress() {
    final session = offlineSearchSession;
    if (session == null) return;
    _pendingOfflineProgress = session.current;
    if (_offlinePublishTimer?.isActive ?? false) return;
    _flushOfflineScan();
    _offlinePublishTimer = Timer(_offlinePublishInterval, _flushOfflineScan);
  }

  void _flushOfflineScan() {
    _offlinePublishTimer?.cancel();
    _offlinePublishTimer = null;
    final progress = _pendingOfflineProgress;
    _pendingOfflineProgress = null;
    if (progress == null) return;
    _publishOfflineScan(progress);
  }

  void _publishOfflineScan(OfflineScanProgress progress) {
    if (!mounted || offlineSearchSession == null) return;
    // 被上一頁（例如閱讀器）蓋住時先留住進度,轉場結束再一次更新;
    // 否則掃描會在路由動畫期間不斷重建底下的整串結果卡,點擊最後一卷就會卡死。
    if (!(_ownRoute?.isCurrent ?? true)) {
      _pendingOfflineProgress = progress;
      return;
    }
    setState(() {
      offlineSearchActive = true;
      offlineVolumesMissing = false;
      connectionFailurePrompt = false;
      serverSlowHint = false;
      keywordSearchSucceeded = true;
      keywordSearchError = null;
      isLoading = false;
      results = progress.results;
      nextStart = progress.results.length;
      totalFound = progress.results.length;
      totalTermHits = progress.termHits;
      totalHitVolumes = progress.hitVolumes;
      hasMore = !progress.finished;
      offlineScannedVolumes = progress.scannedVolumes;
      offlineTotalVolumes = progress.totalVolumes;
      _prioritizeSearchResultsByCatalog();
      FullTextSearchCache.remember(
        submittedQuery,
        offline: true,
        results: results,
        nextStart: nextStart,
        totalFound: totalFound,
        totalTermHits: totalTermHits,
        hasMore: hasMore,
      );
    });
  }

  void _updateCombinedSearchError() {
    if (isKeywordSearchPending || isCatalogSearchPending) return;
    if (!keywordSearchSucceeded && !catalogSearchSucceeded) {
      errorMessage = [
        if (keywordSearchError != null) keywordSearchError,
        if (catalogSearchError != null) catalogSearchError,
      ].join('\n');
    } else {
      errorMessage = null;
    }
  }

  String? _partialSearchWarning() {
    if (isKeywordSearchPending || isCatalogSearchPending) return null;
    final failures = [
      if (keywordSearchError != null && catalogSearchSucceeded)
        keywordSearchError!,
      if (catalogSearchError != null && keywordSearchSucceeded)
        catalogSearchError!,
    ];
    return failures.isEmpty ? null : '部分搜尋來源無法使用：${failures.join('；')}';
  }

  void _prioritizeSearchResultsByCatalog() {
    if (catalogSearchResults.isEmpty || results.length < 2) return;
    final priority = <String, int>{};
    for (var index = 0; index < catalogSearchResults.length; index++) {
      final work = catalogResultWorkId(catalogSearchResults[index]);
      if (work.isNotEmpty) priority.putIfAbsent(work, () => index);
    }
    final fallback = priority.length;
    // work id 每筆只解析一次,而不是每次比較都解析一次。
    final keyed = [
      for (var index = 0; index < results.length; index++)
        (
          result: results[index],
          rank: priority[searchResultWorkId(results[index])] ?? fallback,
          index: index,
        ),
    ];
    keyed.sort((left, right) {
      final byRank = left.rank.compareTo(right.rank);
      return byRank != 0 ? byRank : left.index.compareTo(right.index);
    });
    results = [for (final item in keyed) item.result];
  }

  Future<void> _openGotoSearch(String input, int token) async {
    setState(() {
      submittedQuery = input;
      results = const [];
      catalogSearchResults = const [];
      showAllCatalogResults = false;
      isLoading = true;
      isKeywordSearchPending = false;
      isCatalogSearchPending = false;
      errorMessage = null;
    });
    try {
      final passage = await resolveGotoPassage(input);
      if (!mounted || token != requestToken) return;
      clearSearch();
      await _openPassage(passage);
    } catch (error) {
      if (!mounted || token != requestToken) return;
      setState(() {
        errorMessage = 'Goto 查詢失敗：$error';
        isLoading = false;
      });
    }
  }

  Future<void> _openCatalogSearchResult(Map<String, dynamic> result) async {
    try {
      final passage = await resolveCatalogWorkPassage(result);
      if (!mounted) return;
      await _openPassage(passage);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('無法開啟經目查詢結果：$error')));
    }
  }

  Future<void> loadMore({bool fromScroll = false}) async {
    if (isLoadingMore || !hasMore) return;
    if (fromScroll && _scrollLoadMoreHalted) return;
    // 離線掃描自己會一塊一塊推進,不需要捲動或按鈕再觸發。
    if (offlineSearchActive) return;
    // 手動按下「載入更多」永遠保留重試能力。
    if (!fromScroll) _scrollLoadMoreHalted = false;
    final token = requestToken;
    setState(() {
      isLoadingMore = true;
      loadMoreError = null;
    });
    try {
      final batch = await _searchAllInOne(submittedQuery, start: nextStart);
      if (!mounted || token != requestToken) return;
      _scrollLoadMoreHalted = fromScroll && batch.results.isEmpty;
      setState(() {
        results = [...results, ...batch.results];
        nextStart = batch.nextStart;
        totalFound = batch.totalFound;
        totalTermHits = batch.totalTermHits;
        hasMore = batch.hasMore;
        isLoadingMore = false;
        _prioritizeSearchResultsByCatalog();
        FullTextSearchCache.remember(
          submittedQuery,
          offline: false,
          results: results,
          nextStart: nextStart,
          totalFound: totalFound,
          totalTermHits: totalTermHits,
          hasMore: hasMore,
        );
      });
    } catch (error) {
      if (!mounted || token != requestToken) return;
      if (isRequestTimeout(error)) {
        // 已經有結果了,下一批慢就只是慢,不切換到離線模式。
        setState(() {
          isLoadingMore = false;
          loadMoreError =
              '載入更多結果逾時（等待超過 ${keywordSearchTimeout.inSeconds} 秒），請再按一次。';
        });
        return;
      }
      if (isNetworkFailure(error)) {
        // 聯網模式的「載入更多」也必須來自伺服器；連不上就提示切離線，
        // 不把後半段結果換成本地掃描。
        final hasLocal = await _hasLocalVolumes();
        if (!mounted || token != requestToken) return;
        setState(() {
          isLoadingMore = false;
          connectionFailurePrompt = true;
          connectionFailureHasLocal = hasLocal;
        });
        return;
      }
      setState(() {
        loadMoreError = '載入更多結果失敗：$error';
        isLoadingMore = false;
      });
    }
  }

  void clearSearch() {
    FocusScope.of(context).unfocus();
    searchController.clear();
    _lastSubmittedRawInput = '';
    _stopOfflineScan();
    _serverSlowTimer?.cancel();
    _serverSlowTimer = null;
    _modeChangePending = false;
    // 離開三项結果的画面回到首頁：把掃描用的 worker 也還給系統，
    // 下一次搜尋再重新拉起（冷啟動只要幾百毫秒）。
    _releaseOfflineScanPool();
    setState(() {
      submittedQuery = '';
      results = const [];
      catalogSearchResults = const [];
      showAllCatalogResults = false;
      dictionarySearchResults = const [];
      isDictionarySearchPending = false;
      dictionarySearchError = null;
      showAllDictionaryResults = false;
      catalogSectionExpanded = true;
      dictionarySectionExpanded = true;
      keywordSectionExpanded = true;
      errorMessage = null;
      keywordSearchError = null;
      catalogSearchError = null;
      keywordSearchSucceeded = false;
      catalogSearchSucceeded = false;
      offlineSearchActive = false;
      offlineVolumesMissing = false;
      connectionFailurePrompt = false;
      connectionFailureHasLocal = false;
      serverSlowHint = false;
      offlineScannedVolumes = 0;
      offlineTotalVolumes = 0;
      waitingForIndexUpdate = false;
      isLoading = false;
      isKeywordSearchPending = false;
      isCatalogSearchPending = false;
      isLoadingMore = false;
      loadMoreError = null;
      hasMore = false;
      nextStart = 0;
      totalFound = 0;
      totalTermHits = 0;
      catalogVisibleCount = 1;
      dictionaryVisibleCount = 1;
      keywordVisibleGroups = resultSectionPageSize;
      _scrollLoadMoreHalted = false;
      requestToken++;
    });
  }

  Future<SearchBatch> _searchAllInOne(String query, {required int start}) =>
      fetchSearchBatch(query, start: start);

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    scriptureDisplaySettings.removeListener(_onDisplaySettingsChanged);
    offlineModeListenable.removeListener(_onOfflineModeChanged);
    _indexUpdate.removeListener(_onIndexUpdateChanged);
    _serverSlowTimer?.cancel();
    _ownRoute?.secondaryAnimation?.removeListener(_onRouteTransitionChanged);
    _stopOfflineScan();
    _releaseOfflineScanPool();
    searchController.dispose();
    resultsScrollController
      ..removeListener(_onResultsScroll)
      ..dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final settings = scriptureDisplaySettings;
    // Android 根頁面的返回鍵只把 App 退到背景，避免中斷下載、更新與索引重建。
    final backgroundOnBack =
        !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
    return PopScope<Object?>(
      canPop: !backgroundOnBack && submittedQuery.isEmpty,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (submittedQuery.isNotEmpty) {
          clearSearch();
        } else if (backgroundOnBack) {
          unawaited(moveTaskToBack());
        }
      },
      child: Scaffold(
        backgroundColor: settings.backgroundColor,
        appBar: AppBar(
          titleSpacing: 0,
          leading: IconButton(
            tooltip: displayText('選擇佛經', context),
            onPressed: _openWorkPicker,
            icon: const Icon(Icons.menu_rounded),
          ),
          actions: [
            IconButton(
              tooltip: displayText(
                offlineMode
                    ? '離線模式：開啟（正文閱讀與搜尋都只用本地經卷）'
                    : '離線模式：關閉（正文閱讀與搜尋都請求 CBETA）',
                context,
              ),
              icon: Icon(
                offlineMode ? Icons.cloud_off_rounded : Icons.cloud_outlined,
              ),
              color: offlineMode ? const Color(0xFF176B67) : null,
              onPressed: kIsWeb ? null : _toggleOfflineMode,
            ),
            ScriptDisplayButton(),
            SettingsButton(
              availableUpdate: _availableUpdate,
              onUpdate: _promptForAppUpdate,
              onCheckUpdate: () => _checkForAppUpdate(),
            ),
            SizedBox(width: 8),
          ],
          title: HomeBrand(onTap: submittedQuery.isEmpty ? () {} : clearSearch),
        ),
        body: SafeArea(
          child: CustomScrollView(
            controller: resultsScrollController,
            slivers: [
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
                  child: SearchField(
                    controller: searchController,
                    recentSearches: recentSearches,
                    onSearch: _onSearchSelection,
                    onClear: clearSearch,
                    aiMode: aiMode,
                    onToggleAiMode: () => setState(() => aiMode = !aiMode),
                    onSelectionChanged: (selection) =>
                        _pendingSearchSelection = selection,
                    keyMatchCounter: aiMode || _fodictBaseDir == null
                        ? null
                        : (candidates) => _fodictService.countKeyMatches(
                            _fodictBaseDir!,
                            candidates,
                          ),
                    countScope: _fodictBaseDir,
                    anchorKey: searchFieldAnchorKey,
                  ),
                ),
              ),
              if (submittedQuery.isEmpty)
                SliverToBoxAdapter(child: _buildWelcome(context)),
              if (submittedQuery.isEmpty)
                SliverToBoxAdapter(child: _buildHomeSections(context)),
              if (submittedQuery.isEmpty)
                SliverToBoxAdapter(child: _buildFeedbackButton(context)),
              ..._buildResultSlivers(context),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _openWorkPicker() async {
    final passage = await showWorkPicker(context);
    if (passage == null || !mounted) return;
    await _openPassage(passage);
  }

  Future<void> _openPassage(ScripturePassage passage) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => ScriptureReaderPage(
          passage: passage,
          query: '',
          searchHits: const [],
          initialHitIndex: 0,
        ),
      ),
    );
    if (mounted) await _loadHomeSections();
  }

  Future<void> _openHistoryItem(ReaderBookmark bookmark) =>
      _openPassage(bookmark.toPassage());

  Future<void> _clearHomeList(String key) async {
    try {
      final preferences = await SharedPreferences.getInstance();
      await preferences.remove(key);
      await _loadHomeSections();
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('清空記錄失敗：$error')));
    }
  }

  Future<void> _clearRecentReadings() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(displayText('清除最近閱讀記錄？', dialogContext)),
        content: Text(
          displayText(
            '此操作只會清除首頁的最近閱讀記錄，已下載的離線經文不會被刪除。'
            '書籤和介面設定不會受影響。',
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
            child: Text(displayText('清除', dialogContext)),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      final preferences = await SharedPreferences.getInstance();
      final removed = await preferences.remove(readingHistoryKey);
      if (!removed && preferences.containsKey(readingHistoryKey)) {
        throw StateError('無法清除最近閱讀記錄');
      }
      await _loadHomeSections();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(displayText('已清除最近閱讀記錄', context))),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(displayText('清除最近閱讀記錄失敗：$error', context))),
      );
    }
  }

  Widget _buildHomeSections(BuildContext context) {
    if (recentReadings.isEmpty && homeBookmarks.isEmpty) {
      return const SizedBox.shrink();
    }
    final mostRecent = recentReadings.isEmpty ? null : recentReadings.first;
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 28, 24, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (mostRecent != null)
            _HomeHistorySection(
              title: '上次閱讀位置',
              icon: Icons.play_arrow_rounded,
              items: [mostRecent],
              onTap: _openHistoryItem,
            ),
          if (recentReadings.isNotEmpty)
            _HomeHistorySection(
              title: '最近閱讀',
              icon: Icons.history_rounded,
              items: recentReadings.take(recentReadingsVisibleCount).toList(),
              onTap: _openHistoryItem,
              onClear: _clearRecentReadings,
              onMore: recentReadings.length > recentReadingsVisibleCount
                  ? () => setState(
                      () =>
                          recentReadingsVisibleCount += recentReadingsPageSize,
                    )
                  : null,
              moreLabel: '顯示全部 (${recentReadings.length})',
            ),
          if (homeBookmarks.isNotEmpty)
            _HomeHistorySection(
              title: '我的書籤',
              icon: Icons.bookmark_border_rounded,
              items: homeBookmarks
                  .take(showAllHomeBookmarks ? homeBookmarks.length : 5)
                  .toList(),
              onTap: _openHistoryItem,
              onClear: () => _clearHomeList(readerBookmarksKey),
              onMore: homeBookmarks.length > 5
                  ? () => setState(
                      () => showAllHomeBookmarks = !showAllHomeBookmarks,
                    )
                  : null,
              moreLabel: showAllHomeBookmarks
                  ? '收起'
                  : '顯示全部 (${homeBookmarks.length})',
            ),
        ],
      ),
    );
  }

  Widget _buildFeedbackButton(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 32),
      child: Center(
        child: TextButton.icon(
          onPressed: () => showFeedbackDialog(context),
          icon: Icon(
            Icons.feedback_outlined,
            color: theme.colorScheme.primary,
            size: 20,
          ),
          label: Text(
            '告訴我們你的想法',
            style: TextStyle(
              color: theme.colorScheme.primary,
              fontSize: 15,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildWelcome(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(24, 30, 24, 0),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Container(
          width: 72,
          height: 72,
          decoration: BoxDecoration(
            color: const Color(0xFF176B67).withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(22),
          ),
          child: const Icon(
            Icons.menu_book_rounded,
            size: 42,
            color: Color(0xFF176B67),
          ),
        ),
        const SizedBox(height: 16),
        Text(
          '歡迎使用 Fodian 經典閱讀',
          style: Theme.of(
            context,
          ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 4),
        Text(
          '左上角選單可下載經文與詞典\n'
          '雲朵圖示切換在線／本地搜尋 · 右上角切換簡繁體\n'
          '支援部類、冊別、作譯者、年代等多種瀏覽方式',
          textAlign: TextAlign.center,
          style: Theme.of(
            context,
          ).textTheme.bodySmall?.copyWith(color: const Color(0xFF687671)),
        ),
      ],
    ),
  );

  List<Widget> _buildResultSlivers(BuildContext context) {
    if (submittedQuery.isEmpty) {
      return const [];
    }

    if (isLoading && !connectionFailurePrompt && !offlineVolumesMissing) {
      return const [
        SliverFillRemaining(
          hasScrollBody: false,
          child: Center(child: CircularProgressIndicator()),
        ),
      ];
    }

    if (errorMessage != null && !connectionFailurePrompt) {
      return [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: NoResults(message: errorMessage!),
          ),
        ),
      ];
    }

    final partialWarning = _partialSearchWarning();
    final slivers = <Widget>[
      SliverPadding(
        padding: const EdgeInsets.fromLTRB(24, 4, 24, 0),
        sliver: SliverList(
          delegate: SliverChildListDelegate([
            if (connectionFailurePrompt) _buildConnectionFailureCard(context),
            if (offlineVolumesMissing) _buildOfflineVolumesMissingCard(context),
            if (serverSlowHint) _buildServerSlowHint(context),
            if (offlineSearchActive)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(
                  '目前為離線模式，顯示本地經目與經文',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: const Color(0xFF687671),
                  ),
                ),
              ),
            if (partialWarning != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(
                  partialWarning,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.error,
                  ),
                ),
              ),
            _buildResultSection(
              context,
              title: '經目搜尋結果',
              count: catalogSearchResults.length,
              expanded: catalogSectionExpanded,
              onToggle: () => setState(() {
                if (!catalogSectionExpanded) {
                  dictionarySectionExpanded = false;
                  keywordSectionExpanded = false;
                }
                catalogSectionExpanded = !catalogSectionExpanded;
              }),
              pending: isCatalogSearchPending,
              content: _buildCatalogSectionContent(context),
            ),
          ]),
        ),
      ),
    ];

    // 字典分区：使用 sticky header
    slivers.addAll(_buildDictionarySectionSlivers(context));

    // 关键词分区：使用 sticky header
    slivers.addAll(_buildKeywordSectionSlivers(context));

    return slivers;
  }

  Widget _buildConnectionFailureCard(BuildContext context) {
    final hasLocal = connectionFailureHasLocal;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Card(
        margin: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                hasLocal
                    ? '無法連接 CBETA 伺服器。已下載的經卷可以離線搜尋。'
                    : '無法連接 CBETA 伺服器，本地也沒有已下載的經卷。',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  if (hasLocal)
                    FilledButton.tonal(
                      onPressed: _switchToOfflineMode,
                      child: const Text('改用離線搜尋'),
                    )
                  else
                    FilledButton.tonal(
                      onPressed: _openDownloads,
                      child: const Text('前往下載'),
                    ),
                  TextButton(
                    onPressed: _retryKeywordSearch,
                    child: const Text('重試'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildOfflineVolumesMissingCard(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Card(
        margin: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '離線模式下沒有可搜尋的本地經卷。請先下載經卷，或切換到聯網模式。',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilledButton.tonal(
                    onPressed: _openDownloads,
                    child: const Text('前往下載'),
                  ),
                  TextButton(
                    onPressed: () => unawaited(setOfflineMode(false)),
                    child: const Text('切換到聯網模式'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildServerSlowHint(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        children: [
          Expanded(
            child: Text(
              '伺服器較慢；已下載的經卷可改用離線搜尋。',
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: const Color(0xFF687671)),
            ),
          ),
          TextButton(
            onPressed: _switchToOfflineMode,
            child: const Text('改用離線搜尋'),
          ),
        ],
      ),
    );
  }

  void _openDownloads() {
    unawaited(showDownloadStatusPanel(context));
  }

  Widget _buildResultSection(
    BuildContext context, {
    required String title,
    required int count,
    required bool expanded,
    required VoidCallback onToggle,
    required bool pending,
    required Widget content,
  }) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Card(
            margin: EdgeInsets.zero,
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: onToggle,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                child: Row(
                  children: [
                    Icon(
                      expanded
                          ? Icons.expand_less_rounded
                          : Icons.expand_more_rounded,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        displayText(title, context),
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    Text(
                      pending ? '搜尋中…' : '$count 筆',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: const Color(0xFF687671),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (expanded)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: content,
            ),
        ],
      ),
    );
  }

  Widget _buildSectionMessage(String message) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      child: Text(
        message,
        style: Theme.of(
          context,
        ).textTheme.bodyMedium?.copyWith(color: const Color(0xFF687671)),
      ),
    );
  }

  Widget _buildCatalogSectionContent(BuildContext context) {
    if (isCatalogSearchPending && catalogSearchResults.isEmpty) {
      return _buildSectionMessage(displayText('經目搜尋中…', context));
    }
    if (catalogSearchResults.isEmpty) {
      return _buildSectionMessage(
        catalogSearchError ??
            displayText('本地經目沒有書名含「$submittedQuery」的作品', context),
      );
    }
    final visibleCount = showAllCatalogResults ? catalogVisibleCount : 1;
    final catalogResultsToShow = catalogSearchResults
        .take(visibleCount)
        .toList();
    final remaining = catalogSearchResults.length - catalogResultsToShow.length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final match in catalogResultsToShow)
          CatalogSearchMatch(
            result: match,
            onTap: () => _openCatalogSearchResult(match),
          ),
        if (catalogSearchResults.length > 1)
          Center(
            child: TextButton(
              onPressed: () => setState(() {
                if (!showAllCatalogResults) {
                  showAllCatalogResults = true;
                  catalogVisibleCount = resultSectionPageSize;
                } else if (remaining > 0) {
                  catalogVisibleCount += resultSectionPageSize;
                } else {
                  showAllCatalogResults = false;
                  catalogVisibleCount = 1;
                }
              }),
              child: Text(
                displayText(
                  !showAllCatalogResults
                      ? '顯示更多'
                      : remaining > 0
                      ? '再顯示更多（剩餘 $remaining 筆）'
                      : '收起',
                  context,
                ),
              ),
            ),
          ),
      ],
    );
  }

  List<Widget> _buildDictionarySectionSlivers(BuildContext context) {
    final slivers = <Widget>[];
    final theme = Theme.of(context);

    // 字典分区的标题
    slivers.add(
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 12, 24, 0),
          child: Card(
            margin: EdgeInsets.zero,
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: () => setState(() {
                if (!dictionarySectionExpanded) {
                  catalogSectionExpanded = false;
                  keywordSectionExpanded = false;
                }
                dictionarySectionExpanded = !dictionarySectionExpanded;
              }),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                child: Row(
                  children: [
                    Icon(
                      dictionarySectionExpanded
                          ? Icons.expand_less_rounded
                          : Icons.expand_more_rounded,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        displayText('字典搜尋結果', context),
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    Text(
                      isDictionarySearchPending
                          ? '搜尋中…'
                          : '${dictionarySearchResults.length} 筆',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: const Color(0xFF687671),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );

    // 字典分区的内容
    if (dictionarySectionExpanded) {
      slivers.addAll(_buildDictionaryContentSlivers(context));
    }

    return slivers;
  }

  List<Widget> _buildDictionaryContentSlivers(BuildContext context) {
    final slivers = <Widget>[];

    if (isDictionarySearchPending && dictionarySearchResults.isEmpty) {
      slivers.add(
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(40, 24, 24, 24),
            child: _buildSectionMessage(displayText('字典搜尋中…', context)),
          ),
        ),
      );
      return slivers;
    }

    if (dictionarySearchResults.isEmpty) {
      slivers.add(
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(40, 12, 40, 0),
            child: Card(
              margin: EdgeInsets.zero,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  dictionarySearchError ?? displayText('沒有字典結果', context),
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: const Color(0xFF687671),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      return slivers;
    }

    // 按词典分组
    final groups = <String, List<FodictEntry>>{};
    for (final entry in dictionarySearchResults) {
      groups.putIfAbsent(entry.dictionaryId, () => []).add(entry);
    }
    final dictIds = groups.keys.toList()..sort((a, b) => a.compareTo(b));

    final visibleCount = showAllDictionaryResults ? dictionaryVisibleCount : 1;
    final visibleDictIds = dictIds.take(visibleCount).toList();

    // 为每个词典创建 sticky header
    for (final dictId in visibleDictIds) {
      final entries = groups[dictId]!;
      slivers.add(
        HomepageDictionaryStickyHeader(
          dictId: dictId,
          entries: entries,
          dictName: entries.first.dictionaryName,
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
          onEntryTap: (entry) {
            final entryKey = '${entry.dictionaryId}:${entry.keyword}';
            setState(() {
              if (!_expandedHomepageDictionaryEntries.add(entryKey)) {
                _expandedHomepageDictionaryEntries.remove(entryKey);
              }
            });
          },
          expandedEntryKeys: _expandedHomepageDictionaryEntries,
          context: context,
        ),
      );
    }

    // 显示更多按钮
    if (dictIds.length > 1) {
      final remaining = dictIds.length - visibleDictIds.length;
      slivers.add(
        SliverToBoxAdapter(
          child: Center(
            child: TextButton(
              onPressed: () => setState(() {
                if (!showAllDictionaryResults) {
                  showAllDictionaryResults = true;
                  dictionaryVisibleCount = resultSectionPageSize;
                } else if (remaining > 0) {
                  dictionaryVisibleCount += resultSectionPageSize;
                } else {
                  showAllDictionaryResults = false;
                  dictionaryVisibleCount = 1;
                }
              }),
              child: Text(
                displayText(
                  !showAllDictionaryResults
                      ? '顯示更多字典結果'
                      : remaining > 0
                      ? '再顯示更多字典結果（剩餘 $remaining 筆）'
                      : '收起字典結果',
                  context,
                ),
              ),
            ),
          ),
        ),
      );
    }

    return slivers;
  }

  List<ScriptureSearchResult> _groupedSearchResults() {
    final signature = StringBuffer();
    for (final result in results) {
      signature
        ..write(resultWorkKey(result))
        ..write('#')
        ..write(result.passages.length)
        ..write('/')
        ..write(result.pendingHits.length)
        ..write('#')
        ..write(result.hitCount)
        ..write('|');
    }
    final text = signature.toString();
    final cached = _groupedResultsCache;
    if (cached != null && text == _groupedResultsSignature) return cached;
    final grouped = groupResultsByWork(results);
    _groupedResultsCache = grouped;
    _groupedResultsSignature = text;
    return grouped;
  }

  List<Widget> _buildKeywordSectionSlivers(BuildContext context) {
    final slivers = <Widget>[];
    final theme = Theme.of(context);

    // 关键词分区的标题
    slivers.add(
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 12, 24, 0),
          child: Card(
            margin: EdgeInsets.zero,
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: () => setState(() {
                if (!keywordSectionExpanded) {
                  catalogSectionExpanded = false;
                  dictionarySectionExpanded = false;
                }
                keywordSectionExpanded = !keywordSectionExpanded;
              }),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                child: Row(
                  children: [
                    Icon(
                      keywordSectionExpanded
                          ? Icons.expand_less_rounded
                          : Icons.expand_more_rounded,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        displayText('正文搜尋結果', context),
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    Text(
                      offlineMode ? '本地' : '線上',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: const Color(0xFF687671),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      waitingForIndexUpdate
                          ? '索引更新中'
                          : isKeywordSearchPending
                          ? '搜尋中…'
                          : offlineSearchActive
                          ? '$totalFound 部'
                          : '$totalFound 筆',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: const Color(0xFF687671),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );

    // 关键词分区的内容
    if (keywordSectionExpanded) {
      slivers.addAll(_buildKeywordContentSlivers(context));
    }

    return slivers;
  }

  List<Widget> _buildKeywordContentSlivers(BuildContext context) {
    final slivers = <Widget>[];

    if (waitingForIndexUpdate) {
      slivers.add(
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(40, 12, 40, 12),
            child: Card(
              margin: EdgeInsets.zero,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: IndexUpdateStatusView(progress: _indexUpdate.progress),
              ),
            ),
          ),
        ),
      );
      return slivers;
    }

    if (isKeywordSearchPending && results.isEmpty) {
      slivers.add(
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(40, 24, 24, 24),
            child: _buildSectionMessage(displayText('關鍵字搜尋中…', context)),
          ),
        ),
      );
      return slivers;
    }

    if (results.isEmpty) {
      if (!offlineVolumesMissing &&
          !connectionFailurePrompt &&
          keywordSearchError == null &&
          !(offlineSearchActive && hasMore)) {
        slivers.add(
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(40, 12, 40, 0),
              child: Card(
                margin: EdgeInsets.zero,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    offlineSearchActive
                        ? '離線模式下，本地已儲存的經目與經文中找不到「$submittedQuery」'
                        : '找不到「$submittedQuery」相關經文',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: const Color(0xFF687671),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      }
      if (offlineSearchActive) {
        slivers.add(
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(40, 12, 24, 0),
              child: _buildOfflineScanControls(),
            ),
          ),
        );
      }
      return slivers;
    }

    // 搜索结果统计
    slivers.add(
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(40, 12, 24, 0),
          child: Text(
            offlineSearchActive
                ? '「$submittedQuery」離線搜尋：已找到 $totalFound 部、'
                      '$totalHitVolumes 卷，共 $totalTermHits 處出現'
                      '${hasMore ? '（已掃描 $offlineScannedVolumes/$offlineTotalVolumes 卷）' : ''}'
                : '「$submittedQuery」搜尋結果：找到 $totalFound 筆結果，共 $totalTermHits 處出現',
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(color: const Color(0xFF687671)),
          ),
        ),
      ),
    );

    // Work 列表，每个 work 使用 sticky header
    final groupedResults = _groupedSearchResults();
    _keywordTotalGroups = groupedResults.length;
    final visibleGroups = offlineSearchActive
        ? groupedResults.take(keywordVisibleGroups).toList()
        : groupedResults;
    final hiddenGroups = groupedResults.length - visibleGroups.length;

    for (var index = 0; index < visibleGroups.length; index++) {
      final result = visibleGroups[index];
      final workKey = resultWorkKey(result);
      slivers.add(
        WorkStickyHeader(
          key: ValueKey('work:$workKey:$index'),
          result: result,
          query: submittedQuery,
          workKey: workKey,
          isExpanded: _expandedWorkKey == workKey,
          scrollController: resultsScrollController,
          onExpansionChanged: (expanded) {
            setState(() {
              _expandedWorkKey = expanded ? workKey : null;
            });
            if (expanded) _expandOfflineHits(result);
          },
          onPassageTap: (passage, passages) {
            Navigator.of(context)
                .push<void>(
                  MaterialPageRoute(
                    builder: (_) => ScriptureReaderPage(
                      passage: passage,
                      query: submittedQuery,
                      searchHits: passages,
                      initialHitIndex: passages.indexOf(passage),
                    ),
                  ),
                )
                .then((_) => _loadHomeSections());
          },
        ),
      );
    }

    // 离线模式的"显示更多"按钮
    if (offlineSearchActive &&
        (hiddenGroups > 0 || keywordVisibleGroups > resultSectionPageSize)) {
      slivers.add(
        SliverToBoxAdapter(
          child: Center(
            child: TextButton(
              onPressed: () => setState(() {
                if (hiddenGroups > 0) {
                  keywordVisibleGroups += resultSectionPageSize;
                } else {
                  keywordVisibleGroups = resultSectionPageSize;
                }
              }),
              child: Text(
                hiddenGroups > 0 ? '顯示更多作品（剩餘 $hiddenGroups 部）' : '收合多顯示的作品',
              ),
            ),
          ),
        ),
      );
    }

    // loadMore 错误提示
    if (loadMoreError != null) {
      slivers.add(
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 12, 24, 0),
            child: Text(loadMoreError!, textAlign: TextAlign.center),
          ),
        ),
      );
    }

    // "载入更多结果"按钮
    if (hasMore && !offlineSearchActive) {
      slivers.add(
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
            child: Center(
              child: FilledButton.tonalIcon(
                onPressed: isLoadingMore ? null : loadMore,
                icon: isLoadingMore
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.expand_more_rounded),
                label: Text(isLoadingMore ? '載入中…' : '載入更多結果'),
              ),
            ),
          ),
        ),
      );
    } else if (!hasMore && !offlineSearchActive) {
      slivers.add(
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 20, 24, 0),
            child: Text('已載入全部 $totalFound 筆結果', textAlign: TextAlign.center),
          ),
        ),
      );
    }

    // 离线扫描控制
    if (offlineSearchActive) {
      slivers.add(
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 12, 24, 0),
            child: _buildOfflineScanControls(),
          ),
        ),
      );
    }

    // 底部间距
    slivers.add(SliverToBoxAdapter(child: const SizedBox(height: 32)));

    return slivers;
  }

  Widget _buildOfflineScanControls() {
    final session = offlineSearchSession;
    final scanning = session?.scanning ?? false;
    final finished = session?.finished ?? true;
    if (finished) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            scanning
                ? '離線掃描中…已掃描 $offlineScannedVolumes/$offlineTotalVolumes 卷，目前找到 $totalFound 部'
                : '已暫停掃描（已掃描 $offlineScannedVolumes/$offlineTotalVolumes 卷）',
            textAlign: TextAlign.center,
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: const Color(0xFF687671)),
          ),
          const SizedBox(height: 8),
          Center(
            child: OutlinedButton.icon(
              onPressed: _toggleOfflineScan,
              icon: Icon(
                scanning ? Icons.pause_rounded : Icons.play_arrow_rounded,
                size: 18,
              ),
              label: Text(scanning ? '暫停掃描' : '繼續掃描'),
            ),
          ),
        ],
      ),
    );
  }
}

class _HomeHistorySection extends StatelessWidget {
  const _HomeHistorySection({
    required this.title,
    required this.icon,
    required this.items,
    required this.onTap,
    this.onClear,
    this.onMore,
    this.moreLabel,
  });

  final String title;
  final IconData icon;
  final List<ReaderBookmark> items;
  final ValueChanged<ReaderBookmark> onTap;
  final VoidCallback? onClear;
  final VoidCallback? onMore;
  final String? moreLabel;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 18),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(icon, size: 18),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                displayText(title, context),
                style: Theme.of(
                  context,
                ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
              ),
            ),
            if (onClear != null)
              TextButton(
                onPressed: onClear,
                child: Text(displayText('清空', context)),
              ),
          ],
        ),
        Padding(
          padding: const EdgeInsets.only(left: 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final item in items)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: Text(displayText(item.title, context)),
                  subtitle: Text(
                    displayText(
                      '${item.work}　卷 ${item.juan}'
                      '${item.linehead == null ? '' : ' · ${item.linehead!.split('_p').last}'}',
                      context,
                    ),
                  ),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () => onTap(item),
                ),
              if (onMore != null)
                Align(
                  alignment: Alignment.center,
                  child: TextButton(
                    onPressed: onMore,
                    child: Text(displayText(moreLabel ?? '顯示全部', context)),
                  ),
                ),
            ],
          ),
        ),
      ],
    ),
  );
}
