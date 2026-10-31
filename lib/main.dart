import 'dart:async';

import 'package:flutter/material.dart' hide Text;
import 'package:flutter_localizations/flutter_localizations.dart';

import 'common/app_nav.dart';
import 'dictionary/fodict_download_manager.dart';
import 'download/catalog_cache.dart';
import 'download/catalog_store.dart';
import 'download/download_manager.dart';
import 'download/download_notifications.dart';
import 'download/download_status_ui.dart';
import 'download/update_manager.dart';
import 'home/home_page.dart';
import 'search/conversion.dart';
import 'settings/display_settings.dart';
import 'settings/display_settings_ui.dart';

export 'scripture/cache.dart';
export 'scripture/models.dart';
export 'scripture/parser.dart';
export 'search/conversion.dart';
export 'search/goto.dart';
export 'settings/display_settings.dart';
export 'about/about_dialog.dart';
export 'ai/ai_search_page.dart';
export 'app_update/app_update.dart';
export 'common/app_nav.dart';
export 'common/text_patterns.dart';
export 'dictionary/dictionary_sticky_headers.dart';
export 'download/download_status_ui.dart';
export 'home/home_page.dart';
export 'reader/reader_citations.dart';
export 'reader/reader_layout.dart';
export 'reader/reader_page.dart';
export 'reader/reader_store.dart';
export 'search/full_text_search_page.dart';
export 'search/passage_resolver.dart';
export 'search/search_api.dart';
export 'settings/display_settings_ui.dart';
export 'widgets/result_widgets.dart';
export 'work_picker/creator_collation.dart';
export 'work_picker/work_picker_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SimplifiedTraditionalConverter.load();
  await scriptureDisplaySettings.load();
  CatalogCache.instance.localFileLoader = catalogStore.read;
  await downloadManager.initialize();
  await updateManager.initialize();
  await fodictDownloadManager.initialize();
  downloadNotifications
    ..initialize()
    ..onOpenDownloadManager = _openDownloadManagerFromNotification;
  runApp(const CbetaSearchApp());
  unawaited(_consumePendingDownloadManagerRequest());
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
  const CbetaSearchApp({super.key});

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
            title: 'CBETA 經文搜尋',
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
            home: const ScriptureSearchPage(),
          ),
        );
      },
    );
  }
}
