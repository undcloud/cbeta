import 'dart:async';

import 'package:flutter/material.dart' hide Text;
import 'package:flutter_localizations/flutter_localizations.dart';

import 'common/app_nav.dart';
import 'common/dila_http_client.dart';
import 'dictionary/fodict_download_manager.dart';
import 'download/catalog_cache.dart';
import 'download/catalog_store.dart';
import 'download/download_manager.dart';
import 'download/download_notifications.dart';
import 'download/download_status_ui.dart';
import 'download/update_manager.dart';
import 'home/home_page.dart';
import 'mirror/mirror_importer.dart';
import 'scripture/index_update_notification.dart';
import 'scripture/index_update_service.dart';
import 'search/conversion.dart';
import 'search/offline_preference.dart';
import 'settings/display_settings.dart';
import 'settings/display_settings_ui.dart';
import 'widgets/display_text.dart';

export 'scripture/cache.dart';
export 'scripture/index_update_service.dart';
export 'scripture/index_update_status.dart';
export 'scripture/models.dart';
export 'scripture/parser.dart';
export 'search/conversion.dart';
export 'search/goto.dart';
export 'settings/display_settings.dart';
export 'about/about_dialog.dart';
export 'ai/ai_search_page.dart';
export 'app_update/app_update.dart';
export 'common/app_nav.dart';
export 'common/cbeta_http_client.dart';
export 'common/text_patterns.dart';
export 'dictionary/dictionary_sticky_headers.dart';
export 'download/download_status_ui.dart';
export 'home/home_page.dart';
export 'reader/reader_citations.dart';
export 'reader/reader_layout.dart';
export 'reader/reader_page.dart';
export 'reader/reader_store.dart';
export 'search/full_text_search_page.dart';
export 'search/offline_preference.dart';
export 'search/passage_resolver.dart';
export 'search/search_api.dart';
export 'settings/display_settings_ui.dart';
export 'widgets/result_widgets.dart';
export 'work_picker/creator_collation.dart';
export 'work_picker/work_picker_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await installDilaTrust();
  await SimplifiedTraditionalConverter.load();
  await scriptureDisplaySettings.load();
  await loadOfflineMode();
  CatalogCache.instance.localFileLoader = catalogStore.read;
  await downloadManager.initialize();
  await updateManager.initialize();
  await fodictDownloadManager.initialize();
  await mirrorImporter.initialize();
  await indexUpdateService.initialize();
  indexUpdateService.isBusy = () =>
      downloadManager.isDownloading ||
      updateManager.isUpdating ||
      mirrorImporter.isImporting;
  indexUpdateNotification.otherTaskActive = () =>
      downloadManager.isDownloading ||
      updateManager.isUpdating ||
      mirrorImporter.isImporting;
  indexUpdateNotification.initialize();
  downloadNotifications
    ..initialize()
    ..onOpenDownloadManager = _openDownloadManagerFromNotification;
  runApp(const CbetaSearchApp());
  unawaited(_consumePendingDownloadManagerRequest());
  unawaited(_startBackgroundIndexUpdate());
}

/// APP 升級後若索引版本落後，等第一幀畫完再在背景重建，避免拖慢啟動。
Future<void> _startBackgroundIndexUpdate() async {
  if (!indexUpdateService.needsUpdate) return;
  await Future<void>.delayed(const Duration(seconds: 2));
  final started = await indexUpdateService.startIfNeeded();
  if (!started) return;
  final context = navigatorKey.currentContext;
  if (context == null || !context.mounted) return;
  ScaffoldMessenger.maybeOf(context)?.showSnackBar(
    SnackBar(
      content: Text('正在背景更新搜尋索引，完成後離線全文搜尋會自動使用新索引'),
      action: SnackBarAction(
        label: displayText('查看'),
        onPressed: _openDownloadManagerFromNotification,
      ),
    ),
  );
}

Future<void> _consumePendingDownloadManagerRequest() async {
  if (await downloadNotifications.consumePendingOpenRequest()) {
    _openDownloadManagerFromNotification();
  }
}

void _openDownloadManagerFromNotification() {
  final context = navigatorKey.currentContext;
  if (context != null) {
    unawaited(showDownloadStatusPanel(context));
    return;
  }
  WidgetsBinding.instance.addPostFrameCallback((_) {
    final readyContext = navigatorKey.currentContext;
    if (readyContext != null) {
      unawaited(showDownloadStatusPanel(readyContext));
    }
  });
}

class CbetaSearchApp extends StatefulWidget {
  const CbetaSearchApp({super.key, this.indexUpdateService});

  final IndexUpdateService? indexUpdateService;

  @override
  State<CbetaSearchApp> createState() => _CbetaSearchAppState();
}

class _CbetaSearchAppState extends State<CbetaSearchApp>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    scriptureDisplaySettings.setPlatformDark(
      WidgetsBinding.instance.platformDispatcher.platformBrightness ==
          Brightness.dark,
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangePlatformBrightness() {
    scriptureDisplaySettings.setPlatformDark(
      WidgetsBinding.instance.platformDispatcher.platformBrightness ==
          Brightness.dark,
    );
  }

  @override
  Widget build(BuildContext context) {
    const green = Color(0xFF176B67);

    return AnimatedBuilder(
      animation: scriptureDisplaySettings,
      builder: (context, _) {
        final settings = scriptureDisplaySettings;
        final colors =
            ColorScheme.fromSeed(
              seedColor: green,
              brightness: settings.isDark ? Brightness.dark : Brightness.light,
            ).copyWith(
              surface: settings.surfaceColor,
              onSurface: settings.textColor,
            );
        return ScriptDisplayScope(
          notifier: settings,
          child: MaterialApp(
            navigatorKey: navigatorKey,
            debugShowCheckedModeBanner: false,
            title: 'Fodian 經文搜尋',
            locale: const Locale('zh', 'TW'),
            supportedLocales: const [Locale('zh', 'TW')],
            localizationsDelegates: GlobalMaterialLocalizations.delegates,
            theme: ThemeData(
              useMaterial3: true,
              colorScheme: colors,
              scaffoldBackgroundColor: settings.backgroundColor,
              appBarTheme: AppBarTheme(
                backgroundColor: settings.surfaceColor,
                foregroundColor: settings.textColor,
                surfaceTintColor: Colors.transparent,
              ),
              cardTheme: CardThemeData(
                color: settings.surfaceColor,
                surfaceTintColor: Colors.transparent,
                elevation: 0,
                margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              ),
              expansionTileTheme: ExpansionTileThemeData(
                backgroundColor: settings.surfaceColor,
                collapsedBackgroundColor: settings.surfaceColor,
                iconColor: settings.textColor,
                textColor: settings.textColor,
              ),
              drawerTheme: DrawerThemeData(
                backgroundColor: settings.surfaceColor,
              ),
              navigationDrawerTheme: NavigationDrawerThemeData(
                backgroundColor: settings.surfaceColor,
                surfaceTintColor: Colors.transparent,
              ),
              snackBarTheme: SnackBarThemeData(
                backgroundColor: settings.surfaceColor,
                contentTextStyle: TextStyle(color: settings.textColor),
                actionTextColor: green,
              ),
              inputDecorationTheme: const InputDecorationTheme(
                hintStyle: TextStyle(color: Color(0xFF84918D)),
              ),
              dialogTheme: DialogThemeData(
                backgroundColor: settings.backgroundColor,
                surfaceTintColor: Colors.transparent,
              ),
              bottomSheetTheme: BottomSheetThemeData(
                backgroundColor: settings.backgroundColor,
                surfaceTintColor: Colors.transparent,
              ),
            ),
            home: ScriptureSearchPage(
              indexUpdateService: widget.indexUpdateService,
            ),
          ),
        );
      },
    );
  }
}
