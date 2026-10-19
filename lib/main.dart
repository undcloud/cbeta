import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/material.dart' as flutter_material;
import 'package:flutter/rendering.dart' show RenderEditable;
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:html/dom.dart' as html_dom;
import 'package:html/parser.dart' show parseFragment;
import 'package:http/http.dart' as http;
import 'package:icu_kit/icu_kit.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SimplifiedTraditionalConverter.load();
  await scriptureDisplaySettings.load();
  runApp(const CbetaSearchApp());
}

final scriptureDisplaySettings = ScriptureDisplaySettings();

final scriptureCacheUpdates = ValueNotifier<Set<String>>({});

class CachedScriptureVolume {
  const CachedScriptureVolume({
    required this.work,
    required this.juan,
    required this.html,
    this.contentVersion,
  });

  final String work;
  final String juan;
  final String html;
  final String? contentVersion;

  String get key => '$work:$juan';

  factory CachedScriptureVolume.fromJson(Map<String, dynamic> json) {
    final work = json['work'];
    final juan = json['juan'];
    final html = json['html'];
    final contentVersion = json['contentVersion'];
    if (work is! String ||
        juan is! String ||
        html is! String ||
        (contentVersion != null && contentVersion is! String)) {
      throw const FormatException('離線經文資料格式無效');
    }
    return CachedScriptureVolume(
      work: work,
      juan: juan,
      html: html,
      contentVersion: contentVersion as String?,
    );
  }

  Map<String, Object?> toJson() => {
    'work': work,
    'juan': juan,
    'html': html,
    'contentVersion': contentVersion,
  };
}

class ScriptureVolumeStore {
  ScriptureVolumeStore({Future<Directory> Function()? directoryProvider})
    : _directoryProvider = directoryProvider ?? getApplicationSupportDirectory;

  static const _webKeyPrefix = 'cbeta_scripture_volume:';
  final Future<Directory> Function() _directoryProvider;

  String _validateKey(String work, String juan) {
    if (!RegExp(r'^[A-Za-z0-9]+$').hasMatch(work) ||
        !RegExp(r'^\d+$').hasMatch(juan)) {
      throw FormatException('無效的經卷識別碼：$work 卷 $juan');
    }
    return '$work-$juan';
  }

  Future<Directory> _cacheDirectory() async {
    final supportDirectory = await _directoryProvider();
    final directory = Directory(
      '${supportDirectory.path}${Platform.pathSeparator}cbeta_scripture',
    );
    await directory.create(recursive: true);
    return directory;
  }

  Future<CachedScriptureVolume?> read(String work, String juan) async {
    final fileKey = _validateKey(work, juan);
    final String? stored;
    if (kIsWeb) {
      stored = (await SharedPreferences.getInstance()).getString(
        '$_webKeyPrefix$fileKey',
      );
    } else {
      final directory = await _cacheDirectory();
      final file = File(
        '${directory.path}${Platform.pathSeparator}$fileKey.json',
      );
      stored = await file.exists() ? await file.readAsString() : null;
    }
    if (stored == null) return null;
    final volume = CachedScriptureVolume.fromJson(
      jsonDecode(stored) as Map<String, dynamic>,
    );
    if (volume.work != work || volume.juan != juan) {
      throw FormatException('離線經卷識別碼不符：$work 卷 $juan');
    }
    return volume;
  }

  Future<void> write(CachedScriptureVolume volume) async {
    final fileKey = _validateKey(volume.work, volume.juan);
    final stored = jsonEncode(volume.toJson());
    if (kIsWeb) {
      final saved = await (await SharedPreferences.getInstance()).setString(
        '$_webKeyPrefix$fileKey',
        stored,
      );
      if (!saved) throw StateError('無法儲存離線經文：${volume.key}');
      return;
    }
    final directory = await _cacheDirectory();
    final file = File(
      '${directory.path}${Platform.pathSeparator}$fileKey.json',
    );
    await file.writeAsString(stored, flush: true);
  }

  Future<List<CachedScriptureVolume>> list() async {
    if (kIsWeb) {
      final preferences = await SharedPreferences.getInstance();
      final volumes = <CachedScriptureVolume>[];
      for (final key in preferences.getKeys().where(
        (key) => key.startsWith(_webKeyPrefix),
      )) {
        final stored = preferences.getString(key);
        if (stored != null) {
          volumes.add(
            CachedScriptureVolume.fromJson(
              jsonDecode(stored) as Map<String, dynamic>,
            ),
          );
        }
      }
      return volumes;
    }
    final directory = await _cacheDirectory();
    if (!await directory.exists()) return const [];
    final files = await directory
        .list()
        .where((entity) => entity is File && entity.path.endsWith('.json'))
        .cast<File>()
        .toList();
    final volumes = <CachedScriptureVolume>[];
    for (final file in files) {
      volumes.add(
        CachedScriptureVolume.fromJson(
          jsonDecode(await file.readAsString()) as Map<String, dynamic>,
        ),
      );
    }
    return volumes;
  }

  Future<void> clearAll() async {
    if (kIsWeb) {
      final preferences = await SharedPreferences.getInstance();
      for (final key in preferences.getKeys().where(
        (key) => key.startsWith(_webKeyPrefix),
      )) {
        final removed = await preferences.remove(key);
        if (!removed) throw StateError('無法清除離線經文快取：$key');
      }
      return;
    }
    final directory = await _cacheDirectory();
    if (!await directory.exists()) return;
    await for (final entity in directory.list()) {
      if (entity is File && entity.path.endsWith('.json')) {
        await entity.delete();
      }
    }
  }
}

var scriptureVolumeStore = ScriptureVolumeStore();

class ScriptureCacheUpdateResult {
  const ScriptureCacheUpdateResult({
    required this.updated,
    required this.unchanged,
    required this.errors,
  });

  final int updated;
  final int unchanged;
  final List<String> errors;
}

Future<CachedScriptureVolume> _fetchScriptureVolume(
  String work,
  String juan,
) async {
  final response = await http
      .get(
        Uri.https('cbdata.dila.edu.tw', '/stable/juans', {
          'work': work,
          'juan': juan,
        }),
      )
      .timeout(const Duration(seconds: 20));
  if (response.statusCode != 200) {
    throw Exception('經卷 API 回傳 ${response.statusCode}');
  }
  final payload =
      jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
  if (payload['success'] == false) {
    throw Exception('CBETA 經卷下載失敗：${payload['error'] ?? '未知錯誤'}');
  }
  final html = (payload['results'] as List<dynamic>? ?? const [])
      .whereType<String>()
      .firstOrNull;
  if (html == null || html.isEmpty) {
    throw FormatException('CBETA 未回傳經卷內容：$work 卷 $juan');
  }
  return CachedScriptureVolume(
    work: work,
    juan: juan,
    html: html,
    contentVersion: payload['content'] as String?,
  );
}

Future<ScriptureCacheUpdateResult> checkAndUpdateCachedScriptures() async {
  final cachedVolumes = await scriptureVolumeStore.list();
  var updated = 0;
  var unchanged = 0;
  final updatedKeys = <String>{};
  final errors = <String>[];
  for (final cached in cachedVolumes) {
    try {
      final latest = await _fetchScriptureVolume(cached.work, cached.juan);
      final isUpdated =
          cached.contentVersion != null && latest.contentVersion != null
          ? cached.contentVersion != latest.contentVersion
          : cached.html != latest.html;
      if (isUpdated) {
        await scriptureVolumeStore.write(latest);
        updated++;
        updatedKeys.add(cached.key);
      } else {
        unchanged++;
      }
    } catch (error) {
      errors.add('${cached.work} 卷 ${cached.juan}：$error');
    }
  }
  if (updatedKeys.isNotEmpty) {
    scriptureCacheUpdates.value = Set.unmodifiable(updatedKeys);
  }
  return ScriptureCacheUpdateResult(
    updated: updated,
    unchanged: unchanged,
    errors: List.unmodifiable(errors),
  );
}

class ScriptureDisplaySettings extends ChangeNotifier {
  static const _storageKey = 'scripture_display_settings';
  static const paperSurface = Color(0xFFFAF6EC);

  int fontSize = 19;
  double lineHeight = 1.9;
  String fontFamily = 'serif';
  String backgroundTheme = 'default';
  bool showCollation = true;
  bool showLineBeginnings = false;
  bool showSimplifiedText = false;
  SharedPreferences? _preferences;

  Color get backgroundColor => switch (backgroundTheme) {
    'warm' => const Color(0xFFF5E6C8),
    'green' => const Color(0xFFE3EDCD),
    'white' => const Color(0xFFFFFFFF),
    'grey' => const Color(0xFFEAEAEA),
    'night' => const Color(0xFF1A1714),
    _ => const Color(0xFFF5EFE0),
  };

  Color get textColor => backgroundTheme == 'night'
      ? const Color(0xFFDCD0BA)
      : const Color(0xFF2C1810);

  Color get surfaceColor =>
      backgroundTheme == 'default' ? paperSurface : backgroundColor;

  String get fontFamilyName => switch (fontFamily) {
    'sans' => 'Noto Sans TC',
    'kai' => 'KaiTi',
    'system' => 'system-ui',
    _ => 'Noto Serif TC',
  };

  Future<void> load() async {
    _preferences = await SharedPreferences.getInstance();
    fontSize = 19;
    lineHeight = 1.9;
    fontFamily = 'serif';
    backgroundTheme = 'default';
    showCollation = true;
    showLineBeginnings = false;
    showSimplifiedText = false;
    final stored = _preferences!.getString(_storageKey);
    if (stored == null) return;
    final values = jsonDecode(stored) as Map<String, dynamic>;
    final savedFontSize = values['fontSize'];
    final savedLineHeight = values['lineHeight'];
    final savedFontFamily = values['fontFamily'];
    final savedBackground = values['backgroundTheme'];
    final savedCollation = values['showCollation'];
    final savedLineBeginnings = values['showLineBeginnings'];
    final savedSimplifiedText = values['showSimplifiedText'];
    if (savedFontSize is int && savedFontSize >= 14 && savedFontSize <= 32) {
      fontSize = savedFontSize;
    }
    if (savedLineHeight is num &&
        savedLineHeight >= 1.2 &&
        savedLineHeight <= 3.0) {
      lineHeight = savedLineHeight.toDouble();
    }
    if (savedFontFamily is String &&
        const {'serif', 'sans', 'kai', 'system'}.contains(savedFontFamily)) {
      fontFamily = savedFontFamily;
    }
    if (savedBackground is String &&
        const {
          'default',
          'warm',
          'green',
          'white',
          'grey',
          'night',
        }.contains(savedBackground)) {
      backgroundTheme = savedBackground;
    }
    if (savedCollation is bool) showCollation = savedCollation;
    if (savedLineBeginnings is bool) {
      showLineBeginnings = savedLineBeginnings;
    }
    if (savedSimplifiedText is bool) {
      showSimplifiedText = savedSimplifiedText;
    }
  }

  Future<void> update({
    int? fontSize,
    double? lineHeight,
    String? fontFamily,
    String? backgroundTheme,
    bool? showCollation,
    bool? showLineBeginnings,
    bool? showSimplifiedText,
  }) async {
    if (fontSize != null) this.fontSize = fontSize.clamp(14, 32);
    if (lineHeight != null) {
      this.lineHeight = (lineHeight.clamp(1.2, 3.0) * 10).round() / 10;
    }
    if (fontFamily != null) this.fontFamily = fontFamily;
    if (backgroundTheme != null) this.backgroundTheme = backgroundTheme;
    if (showCollation != null) this.showCollation = showCollation;
    if (showLineBeginnings != null) {
      this.showLineBeginnings = showLineBeginnings;
    }
    if (showSimplifiedText != null) {
      this.showSimplifiedText = showSimplifiedText;
    }
    notifyListeners();

    final preferences = _preferences;
    if (preferences == null) {
      throw StateError('經文設定尚未初始化');
    }
    final saved = await preferences.setString(
      _storageKey,
      jsonEncode({
        'fontSize': this.fontSize,
        'lineHeight': this.lineHeight,
        'fontFamily': this.fontFamily,
        'backgroundTheme': this.backgroundTheme,
        'showCollation': this.showCollation,
        'showLineBeginnings': this.showLineBeginnings,
        'showSimplifiedText': this.showSimplifiedText,
      }),
    );
    if (!saved) throw StateError('無法儲存經文顯示設定');
  }
}

Future<void> _showDisplaySettings(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: scriptureDisplaySettings.backgroundColor,
    builder: (context) => SafeArea(
      child: FractionallySizedBox(
        heightFactor: 0.88,
        child: _DisplaySettingsPanel(onAbout: () => _showAbout(context)),
      ),
    ),
  );
}

Future<void> _showAbout(BuildContext context) {
  return showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(_displayText('關於我們', context)),
      content: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 480,
          maxHeight: MediaQuery.sizeOf(context).height * 0.68,
        ),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _AboutSection(
                title: '專案介紹',
                children: [
                  Text(
                    _displayText(
                      '本 App 是一款基於 CBETA 提供的 API 開發的佛典閱讀與檢索應用程式，旨在為使用者提供便利的佛教經典瀏覽與查詢體驗。',
                      context,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _displayText(
                      '本專案為獨立開發的開源專案，非 CBETA Online 官方開發或維護之應用程式。',
                      context,
                    ),
                  ),
                ],
              ),
              _AboutSection(
                title: '資料來源',
                children: [
                  _AboutLabelText(
                    label: '經文與檢索資料來源：',
                    value: '中華電子佛典協會（CBETA）相關資料服務及 API',
                  ),
                  const SizedBox(height: 8),
                  _AboutLink(
                    label: '資料服務：https://cbdata.dila.edu.tw/',
                    url: 'https://cbdata.dila.edu.tw/',
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _displayText(
                      '本 App 使用上述資料服務提供的 API，經文內容及相關資料的權利與使用規範，依原資料提供方的相關規定辦理。',
                      context,
                    ),
                  ),
                ],
              ),
              _AboutSection(
                title: '開發資訊',
                children: [
                  _AboutLabelText(label: '開發者：', value: 'undcloud'),
                  const SizedBox(height: 8),
                  _AboutLink(
                    label: '開源專案：https://github.com/undcloud/cbeta',
                    url: 'https://github.com/undcloud/cbeta',
                  ),
                  const SizedBox(height: 8),
                  Text(_displayText('歡迎前往 GitHub 查看原始碼、提出問題或提供改進建議。', context)),
                ],
              ),
              _AboutSection(
                title: '聯絡我們',
                children: [
                  Text(
                    _displayText('如果您在使用過程中遇到問題，或有任何建議，歡迎透過微信聯絡我。', context),
                  ),
                  const SizedBox(height: 8),
                  _AboutLabelText(label: '微信聯絡：', value: 'undcloud'),
                ],
              ),
              _AboutSection(
                title: '資料版本',
                children: [
                  Text(
                    _displayText('CBETA 資料版本：請以實際使用的 API 所提供之資料版本為準。', context),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(_displayText('關閉', context)),
        ),
      ],
    ),
  );
}

class _AboutSection extends StatelessWidget {
  const _AboutSection({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 20),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          _displayText(title, context),
          style: Theme.of(
            context,
          ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 8),
        ...children,
      ],
    ),
  );
}

class _AboutLabelText extends StatelessWidget {
  const _AboutLabelText({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Text.rich(
    TextSpan(
      children: [
        TextSpan(
          text: _displayText(label, context),
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        TextSpan(text: _displayText(value, context)),
      ],
    ),
  );
}

class _AboutLink extends StatelessWidget {
  const _AboutLink({required this.label, required this.url});

  final String label;
  final String url;

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: () async {
      final messenger = ScaffoldMessenger.of(context);
      try {
        final opened = await launchUrl(
          Uri.parse(url),
          mode: LaunchMode.externalApplication,
        );
        if (!opened && context.mounted) {
          messenger.showSnackBar(SnackBar(content: Text('無法開啟連結：$url')));
        }
      } catch (error) {
        if (!context.mounted) return;
        messenger.showSnackBar(SnackBar(content: Text('開啟連結失敗：$error')));
      }
    },
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Text(
        _displayText(label, context),
        style: TextStyle(
          color: Theme.of(context).colorScheme.primary,
          decoration: TextDecoration.underline,
        ),
      ),
    ),
  );
}

Future<void> _updateDisplaySetting(
  BuildContext context,
  Future<void> Function() update,
) async {
  try {
    await update();
  } catch (error) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('儲存介面設定失敗：$error')));
  }
}

class _ScriptDisplayScope extends InheritedNotifier<ScriptureDisplaySettings> {
  const _ScriptDisplayScope({required super.notifier, required super.child});

  static void dependOn(BuildContext context) {
    context.dependOnInheritedWidgetOfExactType<_ScriptDisplayScope>();
  }
}

class _DisplaySettingsPanel extends StatelessWidget {
  const _DisplaySettingsPanel({required this.onAbout});

  final VoidCallback onAbout;

  @override
  Widget build(BuildContext context) {
    final settings = scriptureDisplaySettings;
    return AnimatedBuilder(
      animation: settings,
      builder: (context, _) => Material(
        color: settings.backgroundColor,
        child: Column(
          children: [
            ListTile(
              title: const Text(
                '介面設定',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    tooltip: _displayText('關閉', context),
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
                children: [
                  _SettingLabel(
                    title: '經文字體大小',
                    value: '${settings.fontSize}px',
                  ),
                  Slider(
                    key: const ValueKey('scriptureFontSize'),
                    min: 14,
                    max: 32,
                    divisions: 18,
                    value: settings.fontSize.toDouble(),
                    label: '${settings.fontSize}px',
                    onChanged: (value) => _updateDisplaySetting(
                      context,
                      () => settings.update(fontSize: value.round()),
                    ),
                  ),
                  _SettingLabel(
                    title: '經文行高',
                    value: settings.lineHeight.toStringAsFixed(1),
                  ),
                  Slider(
                    key: const ValueKey('scriptureLineHeight'),
                    min: 1.2,
                    max: 3,
                    divisions: 18,
                    value: settings.lineHeight,
                    label: settings.lineHeight.toStringAsFixed(1),
                    onChanged: (value) => _updateDisplaySetting(
                      context,
                      () => settings.update(lineHeight: value),
                    ),
                  ),
                  const _SettingLabel(title: '經文字型'),
                  Wrap(
                    spacing: 8,
                    children: [
                      _FontChip(
                        value: 'serif',
                        label: '明體',
                        selected: settings.fontFamily == 'serif',
                      ),
                      _FontChip(
                        value: 'sans',
                        label: '黑體',
                        selected: settings.fontFamily == 'sans',
                      ),
                      _FontChip(
                        value: 'kai',
                        label: '楷體',
                        selected: settings.fontFamily == 'kai',
                      ),
                      _FontChip(
                        value: 'system',
                        label: '系統',
                        selected: settings.fontFamily == 'system',
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  const _SettingLabel(title: '背景顏色'),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      _BackgroundChip(
                        value: 'default',
                        label: '宣紙',
                        color: const Color(0xFFF5EFE0),
                        selected: settings.backgroundTheme == 'default',
                      ),
                      _BackgroundChip(
                        value: 'warm',
                        label: '暖黃',
                        color: const Color(0xFFF5E6C8),
                        selected: settings.backgroundTheme == 'warm',
                      ),
                      _BackgroundChip(
                        value: 'green',
                        label: '護眼',
                        color: const Color(0xFFE3EDCD),
                        selected: settings.backgroundTheme == 'green',
                      ),
                      _BackgroundChip(
                        value: 'white',
                        label: '純白',
                        color: Colors.white,
                        selected: settings.backgroundTheme == 'white',
                      ),
                      _BackgroundChip(
                        value: 'grey',
                        label: '淺灰',
                        color: const Color(0xFFEAEAEA),
                        selected: settings.backgroundTheme == 'grey',
                      ),
                      _BackgroundChip(
                        value: 'night',
                        label: '夜間',
                        color: const Color(0xFF1A1714),
                        selected: settings.backgroundTheme == 'night',
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('顯示勘校'),
                    value: settings.showCollation,
                    onChanged: (value) => _updateDisplaySetting(
                      context,
                      () => settings.update(showCollation: value),
                    ),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('顯示首行'),
                    value: settings.showLineBeginnings,
                    onChanged: (value) => _updateDisplaySetting(
                      context,
                      () => settings.update(showLineBeginnings: value),
                    ),
                  ),
                  const _CachedScriptureUpdateTile(),
                  const Divider(),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('關於我們'),
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: onAbout,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SettingLabel extends StatelessWidget {
  const _SettingLabel({required this.title, this.value});

  final String title;
  final String? value;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 8, bottom: 2),
    child: Row(
      children: [
        Expanded(child: Text(title)),
        if (value != null)
          Text(value!, style: Theme.of(context).textTheme.bodySmall),
      ],
    ),
  );
}

class _FontChip extends StatelessWidget {
  const _FontChip({
    required this.value,
    required this.label,
    required this.selected,
  });

  final String value;
  final String label;
  final bool selected;

  @override
  Widget build(BuildContext context) => ChoiceChip(
    label: Text(label),
    selected: selected,
    onSelected: (_) => _updateDisplaySetting(
      context,
      () => scriptureDisplaySettings.update(fontFamily: value),
    ),
  );
}

class _BackgroundChip extends StatelessWidget {
  const _BackgroundChip({
    required this.value,
    required this.label,
    required this.color,
    required this.selected,
  });

  final String value;
  final String label;
  final Color color;
  final bool selected;

  @override
  Widget build(BuildContext context) => ChoiceChip(
    avatar: CircleAvatar(backgroundColor: color, radius: 10),
    label: Text(label),
    selected: selected,
    onSelected: (_) => _updateDisplaySetting(
      context,
      () => scriptureDisplaySettings.update(backgroundTheme: value),
    ),
  );
}

class _SettingsButton extends StatelessWidget {
  const _SettingsButton();

  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: _displayText('介面設定', context),
    onPressed: () => _showDisplaySettings(context),
    icon: const Icon(Icons.settings_outlined),
  );
}

class _CachedScriptureUpdateTile extends StatefulWidget {
  const _CachedScriptureUpdateTile();

  @override
  State<_CachedScriptureUpdateTile> createState() =>
      _CachedScriptureUpdateTileState();
}

class _CachedScriptureUpdateTileState
    extends State<_CachedScriptureUpdateTile> {
  bool isUpdating = false;

  Future<void> _updateCachedScriptures() async {
    setState(() => isUpdating = true);
    try {
      final result = await checkAndUpdateCachedScriptures();
      if (!mounted) return;
      final message = result.errors.isEmpty
          ? result.updated + result.unchanged == 0
                ? '沒有已儲存的離線經卷'
                : '檢查完成：更新 ${result.updated} 卷，${result.unchanged} 卷已是最新'
          : '檢查完成：更新 ${result.updated} 卷，${result.unchanged} 卷已是最新，'
                '${result.errors.length} 卷更新失敗：'
                '${result.errors.take(2).join('；')}';
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('檢查離線經文更新失敗：$error')));
    } finally {
      if (mounted) setState(() => isUpdating = false);
    }
  }

  @override
  Widget build(BuildContext context) => ListTile(
    contentPadding: EdgeInsets.zero,
    title: const Text('更新離線經文'),
    subtitle: const Text('檢查並更新已儲存的經卷'),
    trailing: isUpdating
        ? const SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(strokeWidth: 2),
          )
        : const Icon(Icons.system_update_alt_rounded),
    onTap: isUpdating ? null : _updateCachedScriptures,
  );
}

class _ScriptDisplayButton extends StatelessWidget {
  const _ScriptDisplayButton();

  @override
  Widget build(BuildContext context) {
    final settings = scriptureDisplaySettings;
    return AnimatedBuilder(
      animation: settings,
      builder: (context, _) => IconButton(
        tooltip: _displayText('切換簡體／繁體', context),
        onPressed: () => _updateDisplaySetting(
          context,
          () =>
              settings.update(showSimplifiedText: !settings.showSimplifiedText),
        ),
        icon: flutter_material.Text(
          settings.showSimplifiedText ? '繁' : '简',
          style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w700),
        ),
      ),
    );
  }
}

class SimplifiedTraditionalConverter {
  static Map<String, String> _mapping = const {};
  static Map<String, String> _reverseMapping = const {};

  static Future<void> load() async {
    final dictionary =
        jsonDecode(
              await rootBundle.loadString(
                'assets/hanzi_simplified_to_traditional.json',
              ),
            )
            as Map<String, dynamic>;
    _mapping = dictionary.map(
      (simplified, traditional) => MapEntry(simplified, traditional as String),
    );
    final reverseMapping = <String, String>{};
    for (final entry in _mapping.entries) {
      for (final rune in entry.value.runes) {
        reverseMapping.putIfAbsent(String.fromCharCode(rune), () => entry.key);
      }
    }
    _reverseMapping = reverseMapping;
  }

  static String convert(String text) {
    final result = StringBuffer();
    for (final rune in text.runes) {
      final character = String.fromCharCode(rune);
      result.write(_mapping[character] ?? character);
    }
    return result.toString();
  }

  static String toTraditionalDisplay(String text) {
    final result = StringBuffer();
    for (final rune in text.runes) {
      final character = String.fromCharCode(rune);
      result.write(
        character == '面' ? character : _mapping[character] ?? character,
      );
    }
    return result.toString();
  }

  static String toSimplified(String text) {
    final result = StringBuffer();
    for (final rune in text.runes) {
      final character = String.fromCharCode(rune);
      result.write(switch (character) {
        '籤' => '签',
        _ => _reverseMapping[character] ?? character,
      });
    }
    return result.toString();
  }
}

String _displayText(String text, [BuildContext? context]) {
  if (context != null) _ScriptDisplayScope.dependOn(context);
  return scriptureDisplaySettings.showSimplifiedText
      ? SimplifiedTraditionalConverter.toSimplified(text)
      : SimplifiedTraditionalConverter.toTraditionalDisplay(text);
}

InlineSpan _displayInlineSpan(InlineSpan span) {
  if (span is! flutter_material.TextSpan) return span;
  return flutter_material.TextSpan(
    text: span.text == null ? null : _displayText(span.text!),
    children: span.children?.map(_displayInlineSpan).toList(),
    style: span.style,
    recognizer: span.recognizer,
    mouseCursor: span.mouseCursor,
    onEnter: span.onEnter,
    onExit: span.onExit,
    semanticsLabel: span.semanticsLabel == null
        ? null
        : _displayText(span.semanticsLabel!),
    semanticsIdentifier: span.semanticsIdentifier,
    locale: span.locale,
    spellOut: span.spellOut,
  );
}

class Text extends StatelessWidget {
  const Text(
    this.data, {
    super.key,
    this.style,
    this.strutStyle,
    this.textAlign,
    this.textDirection,
    this.locale,
    this.softWrap,
    this.overflow,
    this.textScaler,
    this.maxLines,
    this.semanticsLabel,
    this.semanticsIdentifier,
    this.textWidthBasis,
    this.textHeightBehavior,
    this.selectionColor,
  }) : textSpan = null;

  const Text.rich(
    this.textSpan, {
    super.key,
    this.style,
    this.strutStyle,
    this.textAlign,
    this.textDirection,
    this.locale,
    this.softWrap,
    this.overflow,
    this.textScaler,
    this.maxLines,
    this.semanticsLabel,
    this.semanticsIdentifier,
    this.textWidthBasis,
    this.textHeightBehavior,
    this.selectionColor,
  }) : data = null;

  final String? data;
  final InlineSpan? textSpan;
  final TextStyle? style;
  final StrutStyle? strutStyle;
  final TextAlign? textAlign;
  final TextDirection? textDirection;
  final Locale? locale;
  final bool? softWrap;
  final TextOverflow? overflow;
  final TextScaler? textScaler;
  final int? maxLines;
  final String? semanticsLabel;
  final String? semanticsIdentifier;
  final TextWidthBasis? textWidthBasis;
  final TextHeightBehavior? textHeightBehavior;
  final Color? selectionColor;

  @override
  Widget build(BuildContext context) {
    _ScriptDisplayScope.dependOn(context);
    final displayedSpan = textSpan;
    final semantics = semanticsLabel == null
        ? null
        : _displayText(semanticsLabel!);
    if (displayedSpan != null) {
      return flutter_material.Text.rich(
        _displayInlineSpan(displayedSpan),
        style: style,
        strutStyle: strutStyle,
        textAlign: textAlign,
        textDirection: textDirection,
        locale: locale,
        softWrap: softWrap,
        overflow: overflow,
        textScaler: textScaler,
        maxLines: maxLines,
        semanticsLabel: semantics,
        semanticsIdentifier: semanticsIdentifier,
        textWidthBasis: textWidthBasis,
        textHeightBehavior: textHeightBehavior,
        selectionColor: selectionColor,
      );
    }
    return flutter_material.Text(
      _displayText(data!),
      style: style,
      strutStyle: strutStyle,
      textAlign: textAlign,
      textDirection: textDirection,
      locale: locale,
      softWrap: softWrap,
      overflow: overflow,
      textScaler: textScaler,
      maxLines: maxLines,
      semanticsLabel: semantics,
      semanticsIdentifier: semanticsIdentifier,
      textWidthBasis: textWidthBasis,
      textHeightBehavior: textHeightBehavior,
      selectionColor: selectionColor,
    );
  }
}

class _DisplaySelectableText extends StatelessWidget {
  const _DisplaySelectableText(this.data, {this.style})
    : textSpan = null,
      childKey = null,
      onSelectionChanged = null,
      contextMenuBuilder = null;

  const _DisplaySelectableText.rich(
    this.textSpan, {
    required this.onSelectionChanged,
    required this.contextMenuBuilder,
    required this.style,
    Key? key,
  }) : data = null,
       childKey = key;

  final String? data;
  final flutter_material.TextSpan? textSpan;
  final Key? childKey;
  final TextStyle? style;
  final SelectionChangedCallback? onSelectionChanged;
  final Widget Function(BuildContext, EditableTextState)? contextMenuBuilder;

  @override
  Widget build(BuildContext context) {
    _ScriptDisplayScope.dependOn(context);
    final span = textSpan;
    if (span != null) {
      return flutter_material.SelectableText.rich(
        _displayInlineSpan(span) as flutter_material.TextSpan,
        key: childKey,
        onSelectionChanged: onSelectionChanged,
        contextMenuBuilder: contextMenuBuilder,
        style: style,
      );
    }
    return flutter_material.SelectableText(
      _displayText(data!),
      key: childKey,
      style: style,
    );
  }
}

class CbetaSearchApp extends StatelessWidget {
  const CbetaSearchApp({super.key});

  @override
  Widget build(BuildContext context) {
    const green = Color(0xFF176B67);

    return AnimatedBuilder(
      animation: scriptureDisplaySettings,
      builder: (context, _) {
        final settings = scriptureDisplaySettings;
        final colors = ColorScheme.fromSeed(seedColor: green).copyWith(
          surface: settings.surfaceColor,
          onSurface: settings.textColor,
        );
        return _ScriptDisplayScope(
          notifier: settings,
          child: MaterialApp(
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
              inputDecorationTheme: const InputDecorationTheme(
                hintStyle: TextStyle(color: Color(0xFF84918D)),
              ),
            ),
            home: const ScriptureSearchPage(),
          ),
        );
      },
    );
  }
}

class ScriptureSearchPage extends StatefulWidget {
  const ScriptureSearchPage({super.key});

  @override
  State<ScriptureSearchPage> createState() => _ScriptureSearchPageState();
}

class _ScriptureSearchPageState extends State<ScriptureSearchPage> {
  final searchController = TextEditingController();
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
  int nextStart = 0;
  int totalFound = 0;
  int totalTermHits = 0;
  int requestToken = 0;
  List<_ReaderBookmark> recentReadings = [];
  List<_ReaderBookmark> homeBookmarks = [];
  List<String> recentSearches = [];
  int recentReadingsVisibleCount = _initialRecentReadingsCount;
  bool showAllHomeBookmarks = false;
  bool aiMode = false;
  bool offlineSearchActive = false;

  @override
  void initState() {
    super.initState();
    scriptureDisplaySettings.addListener(_onDisplaySettingsChanged);
    resultsScrollController.addListener(_onResultsScroll);
    _loadHomeSections();
  }

  void _onDisplaySettingsChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _loadHomeSections() async {
    try {
      final history = await _loadBookmarkRecords(_readingHistoryKey);
      final bookmarks = await _loadBookmarks();
      final searches = await _loadSearchHistory();
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
    if (resultsScrollController.hasClients &&
        resultsScrollController.position.extentAfter < 400) {
      loadMore();
    }
  }

  Future<void> search([String? value]) async {
    final token = ++requestToken;
    final inputQuery = (value ?? searchController.text).trim();
    final query = SimplifiedTraditionalConverter.convert(inputQuery);
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    FocusScope.of(context).unfocus();
    if (inputQuery.isEmpty) {
      setState(() {
        submittedQuery = '';
        results = const [];
        catalogSearchResults = const [];
        showAllCatalogResults = false;
        errorMessage = null;
        isLoading = false;
        isKeywordSearchPending = false;
        isCatalogSearchPending = false;
        hasMore = false;
        nextStart = 0;
        totalFound = 0;
        totalTermHits = 0;
      });
      return;
    }

    if (value != null) searchController.text = inputQuery;
    try {
      await _recordSearchQuery(inputQuery);
      if (mounted && token == requestToken) {
        setState(() {
          recentSearches = [
            inputQuery,
            ...recentSearches.where(
              (savedQuery) =>
                  SimplifiedTraditionalConverter.convert(
                    savedQuery.trim(),
                  ).toLowerCase() !=
                  query.toLowerCase(),
            ),
          ].take(_maximumSearchHistory).toList();
        });
      }
    } catch (error) {
      if (mounted) {
        messenger.showSnackBar(SnackBar(content: Text('儲存搜尋記錄失敗：$error')));
      }
    }

    if (!mounted || token != requestToken) return;
    if (isCbetaGotoExpression(inputQuery)) {
      await _openGotoSearch(inputQuery, token);
      return;
    }
    if (aiMode) {
      navigator.push(
        MaterialPageRoute<void>(
          builder: (_) => _AiSearchPage(initialQuery: inputQuery),
        ),
      );
      return;
    }

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
      offlineSearchActive = false;
      isLoading = true;
      isKeywordSearchPending = true;
      isCatalogSearchPending = true;
      isLoadingMore = false;
      hasMore = false;
      nextStart = 0;
      totalFound = 0;
      totalTermHits = 0;
    });
    if (resultsScrollController.hasClients) {
      resultsScrollController.jumpTo(0);
    }

    unawaited(_loadKeywordResults(query, token));
    unawaited(_loadCatalogSearchResults(query, token));
  }

  Future<void> _loadKeywordResults(String query, int token) async {
    try {
      if (kIsWeb) {
        throw Exception('CBETA 搜尋服務未開放網頁跨域存取；請使用桌面或行動版 App。');
      }
      final batch = await _searchAllInOne(query, start: 0);
      if (!mounted || token != requestToken) return;
      setState(() {
        offlineSearchActive = false;
        keywordSearchSucceeded = true;
        results = batch.results;
        nextStart = batch.nextStart;
        totalFound = batch.totalFound;
        totalTermHits = batch.totalTermHits;
        hasMore = nextStart < totalFound && batch.results.isNotEmpty;
        _prioritizeSearchResultsByCatalog();
        _FullTextSearchCache.remember(
          query,
          results: results,
          nextStart: nextStart,
          totalFound: totalFound,
          totalTermHits: totalTermHits,
        );
      });
    } catch (error) {
      if (!mounted || token != requestToken) return;
      if (_isNetworkFailure(error)) {
        await _applyOfflineKeywordResults(
          query,
          token,
          start: 0,
          replace: true,
        );
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
              isCatalogSearchPending;
          _updateCombinedSearchError();
        });
      }
    }
  }

  Future<void> _loadCatalogSearchResults(String query, int token) async {
    try {
      if (kIsWeb) {
        throw Exception('CBETA 經目查詢未開放網頁跨域存取；請使用桌面或行動版 App。');
      }
      final matches = await _fetchCatalogSearchResults(query);
      if (!mounted || token != requestToken) return;
      setState(() {
        catalogSearchSucceeded = true;
        catalogSearchResults = matches;
        _prioritizeSearchResultsByCatalog();
        isLoading =
            results.isEmpty && matches.isEmpty && isKeywordSearchPending;
        _updateCombinedSearchError();
      });
    } catch (error) {
      if (!mounted || token != requestToken) return;
      if (_isNetworkFailure(error)) {
        // 離線時改以本地已儲存經卷的經名／作譯者查詢經目。
        final matches = await _searchOfflineCatalog(query);
        if (!mounted || token != requestToken) return;
        setState(() {
          offlineSearchActive = true;
          catalogSearchSucceeded = true;
          catalogSearchError = null;
          catalogSearchResults = matches;
          _prioritizeSearchResultsByCatalog();
        });
        return;
      }
      setState(() => catalogSearchError = '經目查詢失敗：$error');
    } finally {
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

  Future<void> _applyOfflineKeywordResults(
    String query,
    int token, {
    required int start,
    required bool replace,
  }) async {
    final batch = await _searchOfflineVolumes(query, start: start);
    if (!mounted || token != requestToken) return;
    setState(() {
      offlineSearchActive = true;
      keywordSearchSucceeded = true;
      keywordSearchError = null;
      results = replace ? batch.results : [...results, ...batch.results];
      nextStart = batch.nextStart;
      totalFound = batch.totalFound;
      totalTermHits = batch.totalTermHits;
      hasMore = nextStart < totalFound && batch.results.isNotEmpty;
      _prioritizeSearchResultsByCatalog();
      _FullTextSearchCache.remember(
        query,
        results: results,
        nextStart: nextStart,
        totalFound: totalFound,
        totalTermHits: totalTermHits,
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
      final work = _catalogResultWorkId(catalogSearchResults[index]);
      if (work.isNotEmpty) priority.putIfAbsent(work, () => index);
    }
    results.sort((left, right) {
      final leftRank = priority[_searchResultWorkId(left)] ?? priority.length;
      final rightRank = priority[_searchResultWorkId(right)] ?? priority.length;
      return leftRank.compareTo(rightRank);
    });
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
      final passage = await _resolveGotoPassage(input);
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
      final passage = await _resolveCatalogWorkPassage(result);
      if (!mounted) return;
      await _openPassage(passage);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('無法開啟經目查詢結果：$error')));
    }
  }

  Future<void> loadMore() async {
    if (isLoadingMore || !hasMore) return;
    final token = requestToken;
    setState(() {
      isLoadingMore = true;
      loadMoreError = null;
    });
    try {
      final batch = offlineSearchActive
          ? await _searchOfflineVolumes(submittedQuery, start: nextStart)
          : await _searchAllInOne(submittedQuery, start: nextStart);
      if (!mounted || token != requestToken) return;
      setState(() {
        results = [...results, ...batch.results];
        nextStart = batch.nextStart;
        totalFound = batch.totalFound;
        totalTermHits = batch.totalTermHits;
        hasMore = nextStart < totalFound && batch.results.isNotEmpty;
        isLoadingMore = false;
        _prioritizeSearchResultsByCatalog();
        _FullTextSearchCache.remember(
          submittedQuery,
          results: results,
          nextStart: nextStart,
          totalFound: totalFound,
          totalTermHits: totalTermHits,
        );
      });
    } catch (error) {
      if (!mounted || token != requestToken) return;
      if (!offlineSearchActive && _isNetworkFailure(error)) {
        await _applyOfflineKeywordResults(
          submittedQuery,
          token,
          start: 0,
          replace: true,
        );
        if (mounted && token == requestToken) {
          setState(() => isLoadingMore = false);
        }
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
    setState(() {
      submittedQuery = '';
      results = const [];
      catalogSearchResults = const [];
      showAllCatalogResults = false;
      errorMessage = null;
      keywordSearchError = null;
      catalogSearchError = null;
      keywordSearchSucceeded = false;
      catalogSearchSucceeded = false;
      offlineSearchActive = false;
      isLoading = false;
      isKeywordSearchPending = false;
      isCatalogSearchPending = false;
      isLoadingMore = false;
      loadMoreError = null;
      hasMore = false;
      nextStart = 0;
      totalFound = 0;
      totalTermHits = 0;
      requestToken++;
    });
  }

  Future<_SearchBatch> _searchAllInOne(String query, {required int start}) =>
      _fetchSearchBatch(query, start: start);

  @override
  void dispose() {
    scriptureDisplaySettings.removeListener(_onDisplaySettingsChanged);
    searchController.dispose();
    resultsScrollController
      ..removeListener(_onResultsScroll)
      ..dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final settings = scriptureDisplaySettings;
    return PopScope<Object?>(
      canPop: submittedQuery.isEmpty,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && submittedQuery.isNotEmpty) clearSearch();
      },
      child: Scaffold(
        backgroundColor: settings.backgroundColor,
        appBar: AppBar(
          titleSpacing: 0,
          leading: IconButton(
            tooltip: _displayText('選擇佛經', context),
            onPressed: _openWorkPicker,
            icon: const Icon(Icons.menu_rounded),
          ),
          actions: const [
            _ScriptDisplayButton(),
            _SettingsButton(),
            SizedBox(width: 8),
          ],
          title: _HomeBrand(
            onTap: submittedQuery.isEmpty ? () {} : clearSearch,
          ),
        ),
        body: SafeArea(
          child: CustomScrollView(
            controller: resultsScrollController,
            slivers: [
              if (submittedQuery.isEmpty)
                SliverToBoxAdapter(child: _buildWelcome(context)),
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
                  child: _SearchField(
                    controller: searchController,
                    recentSearches: recentSearches,
                    onSubmitted: search,
                    onSearch: () => search(),
                    onClear: clearSearch,
                    aiMode: aiMode,
                    onToggleAiMode: () => setState(() => aiMode = !aiMode),
                  ),
                ),
              ),
              if (submittedQuery.isEmpty)
                SliverToBoxAdapter(child: _buildHomeSections(context)),
              ..._buildResultSlivers(context),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _openWorkPicker() async {
    final passage = await _showWorkPicker(context);
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

  Future<void> _openHistoryItem(_ReaderBookmark bookmark) =>
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

  Future<void> _clearRecentReadingsAndOfflineScriptures() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('清除最近閱讀與離線經文？'),
        content: const Text(
          '此操作會刪除最近閱讀記錄及所有已下載的離線經文。'
          '書籤和介面設定不會受影響，且無法復原。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('清除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await scriptureVolumeStore.clearAll();
      final preferences = await SharedPreferences.getInstance();
      final removed = await preferences.remove(_readingHistoryKey);
      if (!removed && preferences.containsKey(_readingHistoryKey)) {
        throw StateError('無法清除最近閱讀記錄');
      }
      scriptureCacheUpdates.value = {};
      await _loadHomeSections();
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('已清除最近閱讀記錄及離線經文')));
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('清除最近閱讀及離線經文失敗：$error')));
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
              onClear: _clearRecentReadingsAndOfflineScriptures,
              onMore: recentReadings.length > recentReadingsVisibleCount
                  ? () => setState(
                      () =>
                          recentReadingsVisibleCount += _recentReadingsPageSize,
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
              onClear: () => _clearHomeList(_readerBookmarksKey),
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
          '歡迎使用 CBETA 經典閱讀',
          style: Theme.of(
            context,
          ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 8),
        Text(
          '點擊左上角選單，選擇一部佛經開始閱讀',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodyMedium,
        ),
        const SizedBox(height: 4),
        Text(
          '支援部類、冊別、作譯者、年代等多種瀏覽方式',
          textAlign: TextAlign.center,
          style: Theme.of(
            context,
          ).textTheme.bodySmall?.copyWith(color: const Color(0xFF687671)),
        ),
        TextButton(
          onPressed: () => _showAbout(context),
          child: const Text('關於我們'),
        ),
      ],
    ),
  );

  List<Widget> _buildResultSlivers(BuildContext context) {
    if (submittedQuery.isEmpty) {
      return const [];
    }

    if (isLoading) {
      return const [
        SliverFillRemaining(
          hasScrollBody: false,
          child: Center(child: CircularProgressIndicator()),
        ),
      ];
    }

    if (errorMessage != null) {
      return [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: _NoResults(message: errorMessage!),
          ),
        ),
      ];
    }

    final catalogResultsToShow = showAllCatalogResults
        ? catalogSearchResults
        : catalogSearchResults.take(2).toList();
    final partialWarning = _partialSearchWarning();
    final partialWarningWidgets = partialWarning == null
        ? const <Widget>[]
        : <Widget>[
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(
                partialWarning,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.error,
                ),
              ),
            ),
          ];
    if (results.isEmpty && catalogSearchResults.isEmpty) {
      return [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: _NoResults(
              message: offlineSearchActive
                  ? '離線模式下，本地已儲存的經目與經文中找不到「$submittedQuery」'
                  : '找不到「$submittedQuery」相關經文'
                        '${partialWarning == null ? '' : '\n$partialWarning'}',
            ),
          ),
        ),
      ];
    }

    final children = <Widget>[
      if (offlineSearchActive)
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Text(
            '目前為離線模式，顯示本地已儲存的經目與經文',
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(color: const Color(0xFF687671)),
          ),
        ),
      ...partialWarningWidgets,
      for (final match in catalogResultsToShow)
        _CatalogSearchMatch(
          result: match,
          onTap: () => _openCatalogSearchResult(match),
        ),
      if (catalogSearchResults.length > 2)
        Center(
          child: TextButton(
            onPressed: () =>
                setState(() => showAllCatalogResults = !showAllCatalogResults),
            child: Text(showAllCatalogResults ? '收起' : '顯示更多'),
          ),
        ),
      if (results.isEmpty)
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Text(
            '「$submittedQuery」經目查詢：找到 ${catalogSearchResults.length} 部作品',
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(color: const Color(0xFF687671)),
          ),
        )
      else
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Text(
            '「$submittedQuery」搜尋結果：找到 $totalFound 筆結果，共 $totalTermHits 處出現',
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(color: const Color(0xFF687671)),
          ),
        ),
      for (var index = 0; index < results.length; index++) ...[
        _SearchResultCard(
          result: results[index],
          query: submittedQuery,
          onPassageTap: (passage, passages) {
            if (passage.linehead == null) return;
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
        if (index != results.length - 1)
          const Divider(height: 1, indent: 16, endIndent: 16),
      ],
      if (loadMoreError != null) ...[
        const SizedBox(height: 12),
        Text(loadMoreError!, textAlign: TextAlign.center),
      ],
      if (results.isNotEmpty && hasMore) ...[
        const SizedBox(height: 16),
        Center(
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
      ] else if (results.isNotEmpty) ...[
        const SizedBox(height: 20),
        Text('已載入全部 $totalFound 筆結果', textAlign: TextAlign.center),
      ],
      if (isKeywordSearchPending || isCatalogSearchPending)
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 12),
          child: Center(child: CircularProgressIndicator()),
        ),
    ];
    return [
      SliverPadding(
        padding: const EdgeInsets.fromLTRB(24, 4, 24, 32),
        sliver: SliverList(delegate: SliverChildListDelegate(children)),
      ),
    ];
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
  final List<_ReaderBookmark> items;
  final ValueChanged<_ReaderBookmark> onTap;
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
                title,
                style: Theme.of(
                  context,
                ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
              ),
            ),
            if (onClear != null)
              TextButton(onPressed: onClear, child: const Text('清空')),
          ],
        ),
        for (final item in items)
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: Text(item.title),
            subtitle: Text(
              '${item.work}　卷 ${item.juan}'
              '${item.linehead == null ? '' : ' · ${item.linehead!.split('_p').last}'}',
            ),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: () => onTap(item),
          ),
        if (onMore != null)
          Align(
            alignment: Alignment.center,
            child: TextButton(
              onPressed: onMore,
              child: Text(moreLabel ?? '顯示全部'),
            ),
          ),
      ],
    ),
  );
}

class _HomeBrand extends StatelessWidget {
  const _HomeBrand({required this.onTap, this.color});

  final VoidCallback onTap;
  final Color? color;

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: onTap,
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Image.asset(
            'assets/cbetaonline.png',
            width: 28,
            height: 28,
            semanticLabel: 'CBETA',
          ),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              'CBETA 閱讀',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                color: color,
                fontWeight: FontWeight.w800,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    ),
  );
}

class _SearchField extends StatefulWidget {
  const _SearchField({
    required this.controller,
    required this.recentSearches,
    required this.onSubmitted,
    required this.onSearch,
    required this.onClear,
    required this.aiMode,
    required this.onToggleAiMode,
  });

  final List<String> recentSearches;
  final TextEditingController controller;
  final ValueChanged<String> onSubmitted;
  final VoidCallback onSearch;
  final VoidCallback onClear;
  final bool aiMode;
  final VoidCallback onToggleAiMode;

  @override
  State<_SearchField> createState() => _SearchFieldState();
}

class _SearchFieldState extends State<_SearchField> {
  final FocusNode focusNode = FocusNode();
  final LayerLink layerLink = LayerLink();
  final GlobalKey fieldKey = GlobalKey();
  OverlayEntry? suggestionOverlay;

  List<String> get suggestions {
    final query = SimplifiedTraditionalConverter.convert(
      widget.controller.text.trim(),
    ).toLowerCase();
    return widget.recentSearches.where((savedQuery) {
      return query.isEmpty ||
          SimplifiedTraditionalConverter.convert(
            savedQuery,
          ).toLowerCase().contains(query);
    }).toList();
  }

  void _showSuggestions() {
    if (suggestions.isEmpty ||
        !focusNode.hasFocus ||
        suggestionOverlay != null) {
      return;
    }
    suggestionOverlay = OverlayEntry(builder: _buildSuggestionOverlay);
    Overlay.of(context).insert(suggestionOverlay!);
  }

  Widget _buildSuggestionOverlay(BuildContext context) {
    final renderBox = fieldKey.currentContext?.findRenderObject() as RenderBox?;
    final size = renderBox?.size ?? Size.zero;
    final items = suggestions;
    if (items.isEmpty || size.width == 0) return const SizedBox.shrink();
    return Positioned.fill(
      child: CompositedTransformFollower(
        link: layerLink,
        showWhenUnlinked: false,
        offset: Offset(0, size.height),
        child: Align(
          alignment: Alignment.topLeft,
          child: TapRegion(
            groupId: focusNode,
            child: Material(
              elevation: 8,
              color: Theme.of(context).colorScheme.surface,
              borderRadius: BorderRadius.circular(8),
              clipBehavior: Clip.antiAlias,
              child: SizedBox(
                width: size.width,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 280),
                  child: ListView.separated(
                    padding: EdgeInsets.zero,
                    shrinkWrap: true,
                    itemCount: items.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (context, index) {
                      final query = items[index];
                      return ListTile(
                        dense: true,
                        title: Text(
                          query,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        onTap: () {
                          _hideSuggestions();
                          widget.controller.text = query;
                          widget.onSubmitted(query);
                        },
                      );
                    },
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _hideSuggestions() {
    suggestionOverlay?.remove();
    suggestionOverlay = null;
  }

  void _refreshSuggestions() {
    if (!focusNode.hasFocus || suggestions.isEmpty) {
      _hideSuggestions();
      return;
    }
    if (suggestionOverlay == null) {
      _showSuggestions();
    } else {
      suggestionOverlay!.markNeedsBuild();
    }
  }

  @override
  void initState() {
    super.initState();
    focusNode.addListener(_refreshSuggestions);
    widget.controller.addListener(_refreshSuggestions);
  }

  @override
  void didUpdateWidget(covariant _SearchField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_refreshSuggestions);
      widget.controller.addListener(_refreshSuggestions);
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _refreshSuggestions();
    });
  }

  @override
  void dispose() {
    _hideSuggestions();
    focusNode
      ..removeListener(_refreshSuggestions)
      ..dispose();
    widget.controller.removeListener(_refreshSuggestions);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return CompositedTransformTarget(
      link: layerLink,
      child: Container(
        key: fieldKey,
        decoration: BoxDecoration(
          color: Theme.of(context).appBarTheme.backgroundColor,
          border: Border.all(color: const Color(0xFFD8CDB8)),
          borderRadius: BorderRadius.circular(8),
          boxShadow: const [
            BoxShadow(
              color: Color(0x0A2C1810),
              blurRadius: 16,
              offset: Offset(0, 4),
            ),
          ],
        ),
        child: Row(
          children: [
            const SizedBox(width: 16),
            const Icon(Icons.search_rounded, color: Color(0xFF176B67)),
            const SizedBox(width: 12),
            Expanded(
              child: AnimatedBuilder(
                animation: scriptureDisplaySettings,
                builder: (context, _) => TextField(
                  controller: widget.controller,
                  focusNode: focusNode,
                  groupId: focusNode,
                  onTapOutside: (_) => focusNode.unfocus(),
                  onChanged: (_) => _refreshSuggestions(),
                  textInputAction: TextInputAction.search,
                  onSubmitted: (value) {
                    _hideSuggestions();
                    widget.onSubmitted(value);
                  },
                  decoration: InputDecoration(
                    hintText: _displayText('請輸入關鍵字搜尋經典、經題或作譯者…', context),
                    border: InputBorder.none,
                    contentPadding: const EdgeInsets.symmetric(vertical: 18),
                  ),
                ),
              ),
            ),
            ValueListenableBuilder<TextEditingValue>(
              valueListenable: widget.controller,
              builder: (context, value, child) => value.text.isEmpty
                  ? const SizedBox.shrink()
                  : IconButton(
                      tooltip: _displayText('清除搜尋', context),
                      onPressed: widget.onClear,
                      icon: const Icon(Icons.close_rounded),
                    ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Tooltip(
                message: _displayText(
                  widget.aiMode ? 'AI 模式：開啟（語意搜尋）' : 'AI 模式：關閉',
                  context,
                ),
                child: InkWell(
                  onTap: widget.onToggleAiMode,
                  borderRadius: BorderRadius.circular(20),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: widget.aiMode
                          ? const Color(0xFF176B67)
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                        color: widget.aiMode
                            ? const Color(0xFF176B67)
                            : const Color(0xFFC9BEAA),
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.auto_awesome_rounded,
                          size: 16,
                          color: widget.aiMode
                              ? Colors.white
                              : const Color(0xFF176B67),
                        ),
                        const SizedBox(width: 4),
                        Text(
                          'AI',
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                            color: widget.aiMode
                                ? Colors.white
                                : const Color(0xFF52615C),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(5),
              child: IconButton.filled(
                tooltip: _displayText('搜尋經文', context),
                onPressed: widget.onSearch,
                icon: const Icon(Icons.search_rounded),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SearchPrompt extends StatelessWidget {
  const _SearchPrompt();

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.manage_search_rounded,
            size: 42,
            color: Theme.of(context).colorScheme.primary,
          ),
          const SizedBox(height: 12),
          Text(
            '搜尋經典與經文',
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(color: const Color(0xFF52615C)),
          ),
        ],
      ),
    ),
  );
}

class _NoResults extends StatelessWidget {
  const _NoResults({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(
            Icons.search_off_rounded,
            size: 40,
            color: Color(0xFF82908C),
          ),
          const SizedBox(height: 12),
          Text(message, textAlign: TextAlign.center),
        ],
      ),
    ),
  );
}

class _CatalogSearchMatch extends StatelessWidget {
  const _CatalogSearchMatch({required this.result, required this.onTap});

  final Map<String, dynamic> result;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final work = _catalogResultWorkId(result);
    final title =
        '${result['title'] ?? result['label'] ?? result['name'] ?? work}';
    final label = title.startsWith('$work ') ? title : '$work $title';
    final byline = '${result['byline'] ?? result['author'] ?? ''}';
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: const Icon(Icons.menu_book_outlined),
        title: Text(label.trim()),
        subtitle: Text(
          byline.isEmpty ? '經目匹配 · 點擊開啟' : '經目匹配 · $byline',
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: const Icon(Icons.chevron_right_rounded),
        onTap: onTap,
      ),
    );
  }
}

class _SearchResultCard extends StatelessWidget {
  const _SearchResultCard({
    required this.result,
    required this.query,
    required this.onPassageTap,
  });

  final ScriptureSearchResult result;
  final String query;
  final void Function(ScripturePassage passage, List<ScripturePassage> passages)
  onPassageTap;

  @override
  Widget build(BuildContext context) => Material(
    color: Colors.transparent,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            result.title,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
              color: const Color(0xFF176B67),
              fontWeight: FontWeight.w700,
            ),
          ),
          if (result.description.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              result.description,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: const Color(0xFF78847F)),
            ),
          ],
          for (final passage in result.passages) ...[
            const SizedBox(height: 10),
            InkWell(
              onTap: passage.linehead == null
                  ? null
                  : () => onPassageTap(passage, result.passages),
              borderRadius: BorderRadius.circular(8),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (passage.reference.isNotEmpty)
                      Text(
                        passage.reference,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: const Color(0xFF78847F),
                        ),
                      ),
                    const SizedBox(height: 4),
                    Text.rich(
                      _highlightedPassageText(passage.text, query),
                      style: Theme.of(
                        context,
                      ).textTheme.bodyLarge?.copyWith(height: 1.8),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    ),
  );
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
  State<ScriptureReaderPage> createState() => _ScriptureReaderPageState();
}

class _ScriptureReaderPageState extends State<ScriptureReaderPage> {
  final readerScrollController = ScrollController();
  final scriptureTextKey = GlobalKey();
  final localSearchController = TextEditingController();
  final Map<String, Future<List<ScriptureLine>>> juanCache = {};
  bool didScrollToMatch = false;
  int? _pendingScrollAnchorOffset;
  double? _pendingScrollAnchorDelta;
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
    linesFuture = _cachedJuan(currentPassage);
    _refreshBookmarkState();
    _persistReadingHistory();
    scriptureDisplaySettings.addListener(_onDisplaySettingsChanged);
    scriptureCacheUpdates.addListener(_onCachedScripturesUpdated);
  }

  Future<void> _persistReadingHistory() async {
    try {
      await _recordRecentReading(currentPassage);
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

  String get _bookmarkKey =>
      '${currentPassage.work}:${currentPassage.juan}:${currentPassage.linehead ?? ''}';

  Future<void> _refreshBookmarkState() async {
    try {
      final bookmarks = await _loadBookmarks();
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
      final bookmarks = await _loadBookmarks();
      final index = bookmarks.indexWhere(
        (bookmark) => bookmark.key == _bookmarkKey,
      );
      if (index >= 0) {
        bookmarks.removeAt(index);
      } else {
        bookmarks.insert(0, _ReaderBookmark.fromPassage(currentPassage));
      }
      await _saveBookmarks(bookmarks);
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
    late final List<_ReaderBookmark> bookmarks;
    try {
      bookmarks = await _loadBookmarks();
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
      backgroundColor: scriptureDisplaySettings.surfaceColor,
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
                      const _ScriptDisplayButton(),
                      IconButton(
                        tooltip: _displayText('關閉', context),
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
                    final latestBookmarks = await _loadBookmarks();
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
                                tooltip: _displayText('刪除書籤', context),
                                icon: const Icon(Icons.delete_outline_rounded),
                                onPressed: () async {
                                  bookmarks.removeAt(index);
                                  await _saveBookmarks(bookmarks);
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

  void _openBookmark(_ReaderBookmark bookmark) {
    final passage = bookmark.toPassage();
    setState(() {
      currentPassage = passage;
      currentHitIndex = 0;
      showSearchNavigation = false;
      didScrollToMatch = false;
      linesFuture = _cachedJuan(passage);
    });
    _refreshBookmarkState();
    _persistReadingHistory();
  }

  Future<void> _selectWork() async {
    final passage = await _showWorkPicker(context);
    if (passage == null || !mounted) return;
    setState(() {
      currentPassage = passage;
      currentHitIndex = 0;
      showSearchNavigation = false;
      didScrollToMatch = false;
      linesFuture = _cachedJuan(passage);
    });
    _refreshBookmarkState();
    _persistReadingHistory();
  }

  Future<void> _openFullTextSearch() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => _FullTextSearchPage(
          initialQuery: _FullTextSearchCache.lastQuery ?? widget.query,
        ),
      ),
    );
  }

  void _findLocalMatches(String query, List<ScriptureLine> lines) {
    localSearchQuery = SimplifiedTraditionalConverter.convert(query.trim());
    localSearchLines = lines;
    localSearchIndex = 0;
    final needle = localSearchQuery.toLowerCase();
    final haystack = lines
        .map((line) => '${line.text}${line.verseCells.isNotEmpty ? '\n' : ''}')
        .join()
        .toLowerCase();
    if (needle.isEmpty) {
      localSearchOffsets = const [];
    } else {
      final matches = <int>[];
      var start = 0;
      while (true) {
        final match = haystack.indexOf(needle, start);
        if (match < 0) break;
        matches.add(match);
        start = match + needle.length;
      }
      localSearchOffsets = matches;
    }
    didScrollToMatch = localSearchOffsets.isEmpty;
    setState(() {});
  }

  void _moveLocalMatch(int direction) {
    if (localSearchOffsets.isEmpty) return;
    setState(() {
      localSearchIndex =
          (localSearchIndex + direction + localSearchOffsets.length) %
          localSearchOffsets.length;
      didScrollToMatch = false;
    });
  }

  List<int> localSearchOffsets = const [];

  int? get localSearchStart =>
      localSearchOffsets.isEmpty ? null : localSearchOffsets[localSearchIndex];

  ({int start, int end})? get localSearchRange {
    final start = localSearchStart;
    return start == null
        ? null
        : (start: start, end: start + localSearchQuery.length);
  }

  void _onDisplaySettingsChanged() {
    if (!mounted) return;
    // 記錄目前視窗頂端所在的文字位置，讓簡繁轉換或字體調整後維持閱讀座標。
    _captureReaderScrollAnchor();
    setState(() => didScrollToMatch = false);
  }

  void _captureReaderScrollAnchor() {
    if (!readerScrollController.hasClients) return;
    final editable = _findRenderEditable(
      scriptureTextKey.currentContext?.findRenderObject(),
    );
    final viewport = readerScrollController.position.context.storageContext
        .findRenderObject();
    if (editable is! RenderEditable || viewport is! RenderBox) return;
    final viewportTop = viewport.localToGlobal(Offset.zero).dy;
    final editableTopLeft = editable.localToGlobal(Offset.zero);
    final globalY = viewportTop.clamp(
      editableTopLeft.dy,
      editableTopLeft.dy + editable.size.height,
    );
    final position = editable.getPositionForPoint(
      Offset(editableTopLeft.dx + editable.size.width / 2, globalY),
    );
    final caretRect = editable.getLocalRectForCaret(position);
    _pendingScrollAnchorOffset = position.offset;
    _pendingScrollAnchorDelta =
        editable.localToGlobal(caretRect.topLeft).dy - viewportTop;
  }

  void _onCachedScripturesUpdated() {
    final work = currentPassage.work;
    final juan = currentPassage.juan;
    if (!mounted ||
        work == null ||
        juan == null ||
        !scriptureCacheUpdates.value.contains('$work:$juan')) {
      return;
    }
    juanCache.remove('$work:$juan');
    setState(() {
      didScrollToMatch = false;
      linesFuture = _cachedJuan(currentPassage);
    });
  }

  Future<List<ScriptureLine>> _cachedJuan(ScripturePassage passage) {
    final linehead = passage.linehead;
    final workMatch = RegExp(
      r'^([A-Z]+)\d+n(\d+)_p',
    ).firstMatch(linehead ?? '');
    final work =
        passage.work ??
        (workMatch == null
            ? null
            : '${workMatch.group(1)}${workMatch.group(2)}');
    final juan = passage.juan;
    if (work == null || juan == null) return _loadJuan(passage);
    final key = '$work:$juan';
    return juanCache.putIfAbsent(key, () async {
      final cached = await scriptureVolumeStore.read(work, juan);
      if (cached != null) return parseScriptureHtml(cached.html);
      final latest = await _fetchScriptureVolume(work, juan);
      await scriptureVolumeStore.write(latest);
      return parseScriptureHtml(latest.html);
    });
  }

  Future<List<ScriptureLine>> _loadJuan(ScripturePassage passage) async {
    final linehead = passage.linehead;
    final workMatch = RegExp(
      r'^([A-Z]+)\d+n(\d+)_p',
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
    final latest = await _fetchScriptureVolume(work, juan);
    await scriptureVolumeStore.write(latest);
    return parseScriptureHtml(latest.html);
  }

  Future<void> _goToHit(int index) async {
    if (index < 0 || index >= widget.searchHits.length) return;
    final passage = widget.searchHits[index];
    setState(() {
      currentPassage = passage;
      currentHitIndex = index;
      didScrollToMatch = false;
      linesFuture = _cachedJuan(passage);
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
    );
    setState(() {
      currentPassage = passage;
      didScrollToMatch = false;
      linesFuture = _cachedJuan(passage);
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
    );
    setState(() {
      currentPassage = passage;
      didScrollToMatch = false;
      linesFuture = _cachedJuan(passage);
    });
    _refreshBookmarkState();
    _persistReadingHistory();
  }

  @override
  void dispose() {
    scriptureDisplaySettings.removeListener(_onDisplaySettingsChanged);
    scriptureCacheUpdates.removeListener(_onCachedScripturesUpdated);
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
            tooltip: _displayText('選擇佛經', context),
            onPressed: _selectWork,
            icon: const Icon(Icons.menu_rounded),
          ),
          title: _HomeBrand(
            onTap: () =>
                Navigator.of(context).popUntil((route) => route.isFirst),
            color: settings.textColor,
          ),
          backgroundColor: settings.surfaceColor,
          foregroundColor: settings.textColor,
          actions: [
            IconButton(
              tooltip: _displayText('當卷搜尋', context),
              onPressed: () {
                setState(() {
                  showLocalSearch = !showLocalSearch;
                  if (!showLocalSearch) {
                    localSearchController.clear();
                    localSearchQuery = '';
                    localSearchOffsets = const [];
                    didScrollToMatch = false;
                  }
                });
              },
              icon: const Icon(Icons.find_in_page_outlined),
            ),
            IconButton(
              tooltip: _displayText('全文搜尋', context),
              onPressed: _openFullTextSearch,
              icon: const Icon(Icons.search_rounded),
            ),
            IconButton(
              tooltip: _displayText('書籤', context),
              onPressed: _toggleBookmark,
              onLongPress: _showBookmarks,
              icon: Icon(
                isBookmarked
                    ? Icons.bookmark_added_rounded
                    : Icons.bookmark_add_outlined,
              ),
            ),
            const _ScriptDisplayButton(),
            const _SettingsButton(),
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
                  return _NoResults(message: '無法載入經文：${snapshot.error}');
                }
                final lines = snapshot.data ?? const <ScriptureLine>[];
                if (lines.isEmpty) {
                  return const _NoResults(message: '找不到此行的經文內容');
                }
                final headerLines = lines
                    .where(
                      (line) =>
                          line.role == ScriptureLineRole.volumeTitle ||
                          line.role == ScriptureLineRole.byline,
                    )
                    .toList();
                final scriptureLines = lines
                    .where(
                      (line) =>
                          line.role != ScriptureLineRole.volumeTitle &&
                          line.role != ScriptureLineRole.byline,
                    )
                    .toList();
                final settings = scriptureDisplaySettings;
                final visibleLines = scriptureLines
                    .map(
                      (line) => visibleScriptureLine(
                        line,
                        showLineBeginnings: settings.showLineBeginnings,
                        showCollation: settings.showCollation,
                      ),
                    )
                    .toList();
                final text = visibleLines.join();
                final targetLine = currentPassage.linehead == null
                    ? -1
                    : scriptureLines.indexWhere(
                        (line) => line.linehead == currentPassage.linehead,
                      );
                final targetIsHeader = headerLines.any(
                  (line) => line.linehead == currentPassage.linehead,
                );
                if (currentPassage.linehead != null &&
                    targetLine < 0 &&
                    !targetIsHeader) {
                  return _NoResults(
                    message: '完整經卷中找不到搜尋命中行：${currentPassage.linehead}',
                  );
                }
                final passageTargetOffset = targetLine < 0
                    ? 0
                    : visibleLines
                          .take(targetLine)
                          .fold<int>(0, (offset, line) => offset + line.length);
                final localTargetOffset = localSearchStart == null
                    ? null
                    : _visibleOffsetForSearchSource(
                        scriptureLines,
                        localSearchStart!,
                        showLineBeginnings: settings.showLineBeginnings,
                        showCollation: settings.showCollation,
                      );
                localSearchLines = scriptureLines;
                final targetOffset = localTargetOffset ?? passageTargetOffset;
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
                    Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 680),
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                currentPassage.title,
                                style: TextStyle(
                                  fontFamily: 'Noto Sans TC',
                                  fontSize: 20,
                                  fontWeight: FontWeight.w600,
                                  color: settings.textColor,
                                ),
                              ),
                              const SizedBox(height: 6),
                              Text(
                                currentPassage.reference,
                                style: TextStyle(
                                  fontFamily: 'Noto Sans TC',
                                  fontSize: 13,
                                  color: settings.backgroundTheme == 'night'
                                      ? const Color(0xFFB2A48F)
                                      : const Color(0xFF6B5744),
                                ),
                              ),
                              if (currentPassage.availableJuans.isNotEmpty)
                                _JuanSelector(
                                  currentJuan: int.tryParse(
                                    currentPassage.juan ?? '',
                                  ),
                                  availableJuans: currentPassage.availableJuans,
                                  onChanged: _selectJuan,
                                ),
                              const Divider(height: 24),
                            ],
                          ),
                        ),
                      ),
                    ),
                    Expanded(
                      child: LayoutBuilder(
                        builder: (context, constraints) {
                          if (!didScrollToMatch) {
                            WidgetsBinding.instance.addPostFrameCallback((_) {
                              if (!mounted ||
                                  !readerScrollController.hasClients) {
                                return;
                              }
                              final style = _scriptureTextStyle(settings);
                              final renderObject = _findRenderEditable(
                                scriptureTextKey.currentContext
                                    ?.findRenderObject(),
                              );
                              final viewportRenderObject = context
                                  .findRenderObject();
                              final anchorOffset = _pendingScrollAnchorOffset;
                              final anchorDelta = _pendingScrollAnchorDelta;
                              _pendingScrollAnchorOffset = null;
                              _pendingScrollAnchorDelta = null;
                              if (anchorOffset != null &&
                                  anchorDelta != null &&
                                  renderObject is RenderEditable &&
                                  viewportRenderObject is RenderBox) {
                                final editableLength =
                                    renderObject.text?.toPlainText().length ??
                                    0;
                                final caretRect = renderObject
                                    .getLocalRectForCaret(
                                      TextPosition(
                                        offset: anchorOffset.clamp(
                                          0,
                                          editableLength,
                                        ),
                                      ),
                                    );
                                final caretY = renderObject
                                    .localToGlobal(caretRect.topLeft)
                                    .dy;
                                final viewportTop = viewportRenderObject
                                    .localToGlobal(Offset.zero)
                                    .dy;
                                didScrollToMatch = true;
                                readerScrollController.jumpTo(
                                  (readerScrollController.offset +
                                          caretY -
                                          viewportTop -
                                          anchorDelta)
                                      .clamp(
                                        0.0,
                                        readerScrollController
                                            .position
                                            .maxScrollExtent,
                                      )
                                      .toDouble(),
                                );
                                return;
                              }
                              if (localSearchRange != null &&
                                  renderObject is RenderEditable &&
                                  viewportRenderObject is RenderBox) {
                                final editableOffset =
                                    _editableOffsetForSearchSource(
                                      lines,
                                      localSearchRange!.start,
                                      showLineBeginnings:
                                          settings.showLineBeginnings,
                                      showCollation: settings.showCollation,
                                    );
                                final caretRect = renderObject
                                    .getLocalRectForCaret(
                                      TextPosition(offset: editableOffset),
                                    );
                                final caretY = renderObject
                                    .localToGlobal(caretRect.topLeft)
                                    .dy;
                                final viewportTop = viewportRenderObject
                                    .localToGlobal(Offset.zero)
                                    .dy;
                                didScrollToMatch = true;
                                readerScrollController.jumpTo(
                                  (readerScrollController.offset +
                                          caretY -
                                          viewportTop -
                                          constraints.maxHeight / 2)
                                      .clamp(
                                        0.0,
                                        readerScrollController
                                            .position
                                            .maxScrollExtent,
                                      )
                                      .toDouble(),
                                );
                                return;
                              }
                              final focusText = localSearchRange == null
                                  ? ''
                                  : text.substring(
                                      targetOffset,
                                      (targetOffset + localSearchQuery.length)
                                          .clamp(0, text.length),
                                    );
                              final textBeforeTarget = text.substring(
                                0,
                                targetOffset,
                              );
                              final painter =
                                  TextPainter(
                                    text: TextSpan(
                                      style: style,
                                      text: '$textBeforeTarget$focusText',
                                    ),
                                    textDirection: Directionality.of(context),
                                    textScaler: MediaQuery.textScalerOf(
                                      context,
                                    ),
                                  )..layout(
                                    maxWidth:
                                        (constraints.maxWidth > 680
                                            ? 680
                                            : constraints.maxWidth) -
                                        32,
                                  );
                              final y = painter
                                  .getOffsetForCaret(
                                    TextPosition(
                                      offset: textBeforeTarget.length,
                                    ),
                                    Rect.zero,
                                  )
                                  .dy;
                              painter.dispose();
                              didScrollToMatch = true;
                              readerScrollController.jumpTo(
                                (4 +
                                        y -
                                        (localSearchRange == null
                                            ? 0
                                            : constraints.maxHeight / 2))
                                    .clamp(
                                      0.0,
                                      readerScrollController
                                          .position
                                          .maxScrollExtent,
                                    )
                                    .toDouble(),
                              );
                            });
                          }
                          return SingleChildScrollView(
                            controller: readerScrollController,
                            padding: const EdgeInsets.fromLTRB(0, 4, 0, 40),
                            child: Center(
                              child: ConstrainedBox(
                                constraints: const BoxConstraints(
                                  maxWidth: 680,
                                ),
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 16,
                                  ),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.stretch,
                                    children: [
                                      _SelectablePassageText(
                                        selectableTextKey: scriptureTextKey,
                                        passage: passage,
                                        headerLines: headerLines,
                                        query: localSearchQuery.isEmpty
                                            ? (showLocalSearch
                                                  ? ''
                                                  : widget.query)
                                            : widget.query,
                                        localSearchRange: showLocalSearch
                                            ? localSearchRange
                                            : null,
                                        sourceLines: lines,
                                        highlightStart:
                                            localSearchOffsets.isNotEmpty
                                            ? targetOffset
                                            : currentPassage.linehead == null
                                            ? null
                                            : targetOffset,
                                      ),
                                      const SizedBox(height: 32),
                                      _JuanNavigation(
                                        currentJuan: int.tryParse(
                                          currentPassage.juan ?? '',
                                        ),
                                        availableJuans:
                                            currentPassage.availableJuans,
                                        onPrevious: () => _changeJuan(-1),
                                        onNext: () => _changeJuan(1),
                                      ),
                                    ],
                                  ),
                                ),
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
                  count: localSearchOffsets.isEmpty
                      ? '0 / 0'
                      : '${localSearchIndex + 1} / ${localSearchOffsets.length}',
                  onSearch: (query) => _findLocalMatches(
                    query,
                    localSearchLines.isEmpty ? const [] : localSearchLines,
                  ),
                  onPrevious: () => _moveLocalMatch(-1),
                  onNext: () => _moveLocalMatch(1),
                  onClose: () => setState(() {
                    showLocalSearch = false;
                    localSearchController.clear();
                    localSearchQuery = '';
                    localSearchOffsets = const [];
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

TextStyle _scriptureTextStyle(ScriptureDisplaySettings settings) {
  final fallbackFamilies = switch (settings.fontFamily) {
    'sans' => const [
      'Noto Sans CJK TC',
      'PingFang TC',
      'CBETA Supplement',
      'sans-serif',
    ],
    'kai' => const ['DFKai-SB', 'BiauKai', 'CBETA Supplement', 'serif'],
    'system' => const ['system-ui', 'CBETA Supplement', 'sans-serif'],
    _ => const ['Noto Serif CJK TC', 'Songti SC', 'CBETA Supplement', 'serif'],
  };
  return TextStyle(
    fontFamily: settings.fontFamilyName,
    fontFamilyFallback: fallbackFamilies,
    fontSize: settings.fontSize.toDouble(),
    height: settings.lineHeight,
    letterSpacing: 0.02 * settings.fontSize,
    color: settings.textColor,
  );
}

class ScriptureLine {
  const ScriptureLine({
    required this.text,
    this.linehead,
    this.footnotes = const [],
    this.inlineNotes = const [],
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
  final List<String> verseCells;
  final List<ScriptureImage> images;
  final List<List<ScriptureTableCell>> tableRows;
  final int headingLevel;
  final ScriptureLineRole role;
}

enum ScriptureLineRole { regular, volumeTitle, byline, navigationAnchor }

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

String visibleScriptureLine(
  ScriptureLine line, {
  required bool showLineBeginnings,
  required bool showCollation,
}) {
  final result = StringBuffer();
  if (showLineBeginnings &&
      line.linehead != null &&
      line.role != ScriptureLineRole.navigationAnchor) {
    result
      ..write('[')
      ..write(line.linehead!.split('_p').last)
      ..write('] ');
  }
  var offset = 0;
  if (showCollation) {
    for (final footnote in line.footnotes) {
      final noteOffset = footnote.offset.clamp(offset, line.text.length);
      result
        ..write(line.text.substring(offset, noteOffset))
        ..write('[${footnote.label}]');
      offset = noteOffset;
    }
  }
  result.write(line.text.substring(offset));
  if (line.verseCells.isNotEmpty) result.write('\n');
  return result.toString();
}

List<ScriptureLine> parseScriptureHtml(String source) {
  final fragment = parseFragment(source);
  final root = fragment.querySelector('#body') ?? fragment;
  final footnoteContent = {
    for (final note in fragment.querySelectorAll('#back .footnote'))
      if (note.id.isNotEmpty)
        note.id: note.text.trim().replaceAll(RegExp(r'\s+'), ' '),
  };
  final lines = <ScriptureLine>[];
  String? linehead;
  var headingLevel = 0;
  var lineRole = ScriptureLineRole.regular;
  final text = StringBuffer();
  StringBuffer? activeCell;
  List<String> verseCells = [];
  final images = <ScriptureImage>[];
  List<List<ScriptureTableCell>> tableRows = [];
  var footnotes = <ScriptureFootnote>[];
  var inlineNotes = <ScriptureInlineNote>[];

  void flushLine() {
    if (linehead != null ||
        text.isNotEmpty ||
        images.isNotEmpty ||
        tableRows.isNotEmpty) {
      final rawText = text.toString();
      final trimmedText = rawText
          .replaceFirst(RegExp(r'^[ \t]+'), '')
          .replaceFirst(RegExp(r'[ \t]+$'), '');
      final leadingWhitespace =
          rawText.length - rawText.replaceFirst(RegExp(r'^[ \t]+'), '').length;
      lines.add(
        ScriptureLine(
          text: trimmedText,
          linehead: linehead,
          footnotes: footnotes
              .map(
                (note) => ScriptureFootnote(
                  offset: (note.offset - leadingWhitespace).clamp(
                    0,
                    trimmedText.length,
                  ),
                  label: note.label,
                  clue: note.clue,
                  content: note.content,
                ),
              )
              .toList(),
          inlineNotes: inlineNotes
              .map(
                (note) => ScriptureInlineNote(
                  offset: (note.offset - leadingWhitespace).clamp(
                    0,
                    trimmedText.length,
                  ),
                  length: note.length,
                ),
              )
              .toList(),
          verseCells: verseCells,
          images: List.unmodifiable(images),
          tableRows: List.unmodifiable(
            tableRows.map((row) => List<ScriptureTableCell>.unmodifiable(row)),
          ),
          headingLevel: headingLevel,
          role: lineRole,
        ),
      );
    }
    linehead = null;
    text.clear();
    verseCells = [];
    images.clear();
    tableRows = [];
    footnotes = [];
    inlineNotes = [];
    headingLevel = 0;
    lineRole = ScriptureLineRole.regular;
  }

  void appendText(String value) {
    text.write(value);
    activeCell?.write(value);
  }

  String tableCellText(html_dom.Node node) {
    if (node is html_dom.Text) return node.data;
    if (node is! html_dom.Element) return '';
    if (node.classes.contains('lb') || node.classes.contains('lineInfo')) {
      return '';
    }
    if (node.localName == 'br') return '\n';
    final children = node.nodes.map(tableCellText).join();
    return const {'p', 'div'}.contains(node.localName)
        ? '$children\n'
        : children;
  }

  void visit(html_dom.Node node) {
    if (node is html_dom.Element && node.classes.contains('lb')) {
      flushLine();
      linehead = node.attributes['id'];
      return;
    }
    if (node is html_dom.Element && node.localName == 'img') {
      final source = node.attributes['src']?.trim() ?? '';
      if (source.isNotEmpty) {
        final uri = Uri.tryParse(source);
        if (uri != null) {
          images.add(
            ScriptureImage(
              source: uri.hasScheme
                  ? source
                  : Uri.parse(
                      'https://cbetaonline.dila.edu.tw/',
                    ).resolveUri(uri).toString(),
              alt: node.attributes['alt']?.trim() ?? '',
            ),
          );
        }
      }
      return;
    }
    if (node is html_dom.Element &&
        (node.classes.contains('bip-table-row') || node.localName == 'tr')) {
      final cells = node.children
          .where(
            (child) =>
                child.classes.contains('bip-table-cell') ||
                child.localName == 'td' ||
                child.localName == 'th',
          )
          .map((cell) {
            final cellText = cell.nodes.map(tableCellText).join().trim();
            final columnSpan =
                int.tryParse(cell.attributes['colspan'] ?? '') ?? 1;
            return ScriptureTableCell(
              text: cellText.replaceAll(RegExp(r'\s+'), ' '),
              columnSpan: columnSpan.clamp(1, 12),
            );
          })
          .toList();
      if (cells.length > 1) {
        if (text.isNotEmpty || images.isNotEmpty || tableRows.isNotEmpty) {
          flushLine();
        }
        tableRows = [cells];
        text.write(cells.map((cell) => cell.text).join('\t'));
        flushLine();
        return;
      }
    }
    if (node is html_dom.Element &&
        node.localName == 'a' &&
        node.classes.contains('noteAnchor')) {
      final href = node.attributes['href'] ?? '';
      final clue = href.replaceFirst(RegExp(r'^#'), '');
      final addNote = node.classes.contains('add');
      final noteNumber = RegExp(r'n\d+(\d{3})$').firstMatch(href)?.group(1);
      final label = addNote
          ? 'A${RegExp(r'(\d+)$').firstMatch(clue)?.group(1) ?? ''}'
          : noteNumber == null
          ? null
          : int.tryParse(noteNumber)?.toString();
      if (label != null && clue.isNotEmpty) {
        footnotes.add(
          ScriptureFootnote(
            offset: text.length,
            label: label,
            clue: clue,
            content: footnoteContent[clue] ?? '',
          ),
        );
      }
      return;
    }
    if (node is html_dom.Text) {
      appendText(node.data);
      return;
    }
    if (node is html_dom.Element && node.localName == 'br') {
      appendText('\n');
      return;
    }
    if (node is html_dom.Element &&
        (node.classes.contains('inline-note') ||
            node.classes.contains('doube-line-note'))) {
      final start = text.length;
      appendText('（');
      for (final child in node.nodes) {
        visit(child);
      }
      appendText('）');
      inlineNotes.add(
        ScriptureInlineNote(offset: start, length: text.length - start),
      );
      return;
    }
    if (node is html_dom.Element && node.classes.contains('lg-row')) {
      verseCells = [];
      for (final cell in node.children.where(
        (child) => child.classes.contains('lg-cell'),
      )) {
        final cellText = StringBuffer();
        activeCell = cellText;
        for (final child in cell.nodes) {
          visit(child);
        }
        verseCells.add(cellText.toString().trim());
      }
      activeCell = null;
      flushLine();
      return;
    }
    final isBlock = node is html_dom.Element && node.localName == 'p';
    final isVolumeTitle = isBlock && node.classes.contains('juan');
    final isByline = isBlock && node.classes.contains('byline');
    final isStyledLine = isVolumeTitle || isByline;
    final isHeading =
        isBlock &&
        (node.classes.contains('head') ||
            node.attributes.containsKey('data-head-level'));
    if ((isHeading || isStyledLine) && text.isNotEmpty) flushLine();
    if (isVolumeTitle) lineRole = ScriptureLineRole.volumeTitle;
    if (isByline) lineRole = ScriptureLineRole.byline;
    if (isHeading) {
      headingLevel =
          int.tryParse(node.attributes['data-head-level'] ?? '') ?? 1;
      headingLevel = headingLevel.clamp(1, 6);
    }
    if (isBlock && text.isNotEmpty && !text.toString().endsWith('\n')) {
      appendText('\n');
    }
    for (final child in node.nodes) {
      visit(child);
    }
    if (isBlock && text.isNotEmpty && !text.toString().endsWith('\n')) {
      appendText('\n');
    }
    if (isHeading || isStyledLine) flushLine();
  }

  for (final child in root.nodes) {
    visit(child);
  }
  flushLine();
  final seenVolumeTitles = <String>{};
  return lines.map((line) {
    if (line.role != ScriptureLineRole.volumeTitle) return line;
    final normalizedTitle = line.text
        .replaceAll(RegExp(r'\s+'), '')
        .replaceAll(RegExp(r'\[\d+\]'), '');
    if (seenVolumeTitles.add(normalizedTitle)) return line;
    return ScriptureLine(
      text: '',
      linehead: line.linehead,
      role: ScriptureLineRole.navigationAnchor,
    );
  }).toList();
}

class _SelectablePassageText extends StatefulWidget {
  const _SelectablePassageText({
    required this.selectableTextKey,
    required this.passage,
    required this.query,
    required this.sourceLines,
    this.headerLines = const [],
    this.localSearchRange,
    this.highlightStart,
  });

  final GlobalKey selectableTextKey;
  final ScripturePassage passage;
  final String query;
  final List<ScriptureLine> sourceLines;
  final List<ScriptureLine> headerLines;
  final ({int start, int end})? localSearchRange;
  final int? highlightStart;

  @override
  State<_SelectablePassageText> createState() => _SelectablePassageTextState();
}

class _SelectablePassageTextState extends State<_SelectablePassageText> {
  String selectedText = '';
  String? selectedStartLinehead;
  String? selectedEndLinehead;

  Future<void> _copyCitation() async {
    if (selectedText.isNotEmpty) {
      await _copySelectedPassage(
        context,
        widget.passage,
        selectedText,
        selectedStartLinehead: selectedStartLinehead,
        selectedEndLinehead: selectedEndLinehead,
      );
    }
  }

  @override
  Widget build(BuildContext context) => Focus(
    onKeyEvent: (node, event) {
      final isCopyShortcut =
          event is KeyDownEvent &&
          event.logicalKey == LogicalKeyboardKey.keyC &&
          (HardwareKeyboard.instance.isControlPressed ||
              HardwareKeyboard.instance.isMetaPressed);
      if (isCopyShortcut && selectedText.isNotEmpty) {
        _copyCitation();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    },
    child: LayoutBuilder(
      builder: (context, constraints) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final line in widget.headerLines)
            Padding(
              padding: EdgeInsets.only(
                bottom: line.role == ScriptureLineRole.volumeTitle ? 6 : 0,
              ),
              child: Text(
                line.text.trim(),
                textAlign: line.role == ScriptureLineRole.volumeTitle
                    ? TextAlign.center
                    : TextAlign.right,
                style: _scriptureTextStyle(scriptureDisplaySettings).copyWith(
                  color: scriptureDisplaySettings.backgroundTheme == 'night'
                      ? line.role == ScriptureLineRole.volumeTitle
                            ? const Color(0xFF72C5B2)
                            : const Color(0xFFB2A48F)
                      : line.role == ScriptureLineRole.volumeTitle
                      ? const Color(0xFF007564)
                      : const Color(0xFF6B5744),
                  fontSize:
                      scriptureDisplaySettings.fontSize *
                      (line.role == ScriptureLineRole.volumeTitle
                          ? 1.05
                          : 0.85),
                  fontWeight: line.role == ScriptureLineRole.volumeTitle
                      ? FontWeight.w600
                      : null,
                ),
              ),
            ),
          _DisplaySelectableText.rich(
            _interactivePassageText(
              context,
              widget.passage,
              widget.query,
              startAt: widget.highlightStart,
              localSearchRange: widget.localSearchRange,
              sourceLines: widget.sourceLines,
              width: constraints.maxWidth,
              recognizers: noteRecognizers,
            ),
            key: widget.selectableTextKey,
            onSelectionChanged: (selection, _) {
              final start = selection.start < selection.end
                  ? selection.start
                  : selection.end;
              final end = selection.start > selection.end
                  ? selection.start
                  : selection.end;
              final sourceStart = _sourceOffsetForSelectableOffset(
                widget.passage.lines,
                start,
                showLineBeginnings: widget.passage.showLineBeginnings,
                showCollation: widget.passage.showCollation,
              );
              final sourceEnd = _sourceOffsetForSelectableOffset(
                widget.passage.lines,
                end,
                showLineBeginnings: widget.passage.showLineBeginnings,
                showCollation: widget.passage.showCollation,
              );
              selectedText = widget.passage.text.substring(
                sourceStart,
                sourceEnd.clamp(sourceStart, widget.passage.text.length),
              );
              selectedStartLinehead = _lineheadAtOffset(
                widget.passage.lines,
                sourceStart,
                showLineBeginnings: widget.passage.showLineBeginnings,
                showCollation: widget.passage.showCollation,
              );
              selectedEndLinehead = _lineheadAtOffset(
                widget.passage.lines,
                sourceEnd > sourceStart ? sourceEnd - 1 : sourceEnd,
                showLineBeginnings: widget.passage.showLineBeginnings,
                showCollation: widget.passage.showCollation,
              );
            },
            contextMenuBuilder: (context, editableTextState) {
              final buttonItems = editableTextState.contextMenuButtonItems.map((
                item,
              ) {
                if (item.type == ContextMenuButtonType.copy) {
                  return item.copyWith(
                    label: '複製引文',
                    onPressed: () {
                      _copyCitation();
                      editableTextState.hideToolbar();
                    },
                  );
                }
                return item;
              }).toList();
              return AdaptiveTextSelectionToolbar.buttonItems(
                anchors: editableTextState.contextMenuAnchors,
                buttonItems: buttonItems,
              );
            },
            style: _scriptureTextStyle(scriptureDisplaySettings),
          ),
        ],
      ),
    ),
  );

  final List<TapGestureRecognizer> noteRecognizers = [];

  @override
  void dispose() {
    for (final recognizer in noteRecognizers) {
      recognizer.dispose();
    }
    super.dispose();
  }
}

int _sourceOffsetForSelectableOffset(
  List<ScriptureLine> lines,
  int selectableOffset, {
  required bool showLineBeginnings,
  required bool showCollation,
}) {
  var sourceOffset = 0;
  var renderedOffset = 0;
  for (final line in lines) {
    final lineBeginning =
        showLineBeginnings &&
            line.linehead != null &&
            line.role != ScriptureLineRole.navigationAnchor
        ? '[${line.linehead!.split('_p').last}] '
        : '';
    sourceOffset += lineBeginning.length;
    renderedOffset += lineBeginning.length;
    final visibleLine = visibleScriptureLine(
      line,
      showLineBeginnings: false,
      showCollation: showCollation,
    );
    if (line.verseCells.isNotEmpty) {
      final widgetEnd = renderedOffset + 1;
      final sourceEnd = sourceOffset + visibleLine.length;
      if (selectableOffset <= widgetEnd) {
        return selectableOffset <= renderedOffset ? sourceOffset : sourceEnd;
      }
      renderedOffset += 2;
      sourceOffset = sourceEnd;
    } else {
      final lineEnd = renderedOffset + visibleLine.length;
      if (selectableOffset <= lineEnd) {
        return sourceOffset + (selectableOffset - renderedOffset);
      }
      renderedOffset = lineEnd;
      sourceOffset += visibleLine.length;
    }
  }
  return sourceOffset.clamp(
    0,
    lines.fold<int>(
      0,
      (length, line) =>
          length +
          visibleScriptureLine(
            line,
            showLineBeginnings: showLineBeginnings,
            showCollation: showCollation,
          ).length,
    ),
  );
}

int _visibleOffsetForSearchSource(
  List<ScriptureLine> lines,
  int sourceOffset, {
  required bool showLineBeginnings,
  required bool showCollation,
}) {
  var sourceStart = 0;
  var visibleStart = 0;
  for (final line in lines) {
    final prefix =
        showLineBeginnings &&
            line.linehead != null &&
            line.role != ScriptureLineRole.navigationAnchor
        ? '[${line.linehead!.split('_p').last}] '
        : '';
    final lineSourceEnd = sourceStart + line.text.length;
    if (sourceOffset < lineSourceEnd) {
      final inLineOffset = (sourceOffset - sourceStart).clamp(
        0,
        line.text.length,
      );
      final noteMarkersBeforeMatch = showCollation
          ? line.footnotes
                .where((note) => note.offset <= inLineOffset)
                .fold<int>(0, (length, note) => length + note.label.length + 2)
          : 0;
      return visibleStart +
          prefix.length +
          inLineOffset +
          noteMarkersBeforeMatch;
    }
    sourceStart = lineSourceEnd + (line.verseCells.isNotEmpty ? 1 : 0);
    visibleStart += visibleScriptureLine(
      line,
      showLineBeginnings: showLineBeginnings,
      showCollation: showCollation,
    ).length;
  }
  return visibleStart;
}

int _editableOffsetForSearchSource(
  List<ScriptureLine> lines,
  int sourceOffset, {
  required bool showLineBeginnings,
  required bool showCollation,
}) {
  var sourceStart = 0;
  var editableStart = 0;
  for (final line in lines) {
    final prefixLength =
        showLineBeginnings &&
            line.linehead != null &&
            line.role != ScriptureLineRole.navigationAnchor
        ? '[${line.linehead!.split('_p').last}] '.length
        : 0;
    final sourceEnd = sourceStart + line.text.length;
    if (line.verseCells.isNotEmpty) {
      if (sourceOffset < sourceEnd) return editableStart + prefixLength;
      sourceStart = sourceEnd + 1;
      editableStart += prefixLength + 2;
      continue;
    }
    if (sourceOffset < sourceEnd) {
      final inLineOffset = sourceOffset - sourceStart;
      final markersBeforeMatch = showCollation
          ? line.footnotes
                .where((note) => note.offset <= inLineOffset)
                .fold<int>(0, (length, note) => length + note.label.length + 2)
          : 0;
      return editableStart + prefixLength + inLineOffset + markersBeforeMatch;
    }
    sourceStart = sourceEnd;
    editableStart +=
        prefixLength +
        line.text.length +
        (showCollation
            ? line.footnotes.fold<int>(
                0,
                (length, note) => length + note.label.length + 2,
              )
            : 0);
  }
  return editableStart;
}

RenderEditable? _findRenderEditable(RenderObject? renderObject) {
  if (renderObject is RenderEditable) return renderObject;
  RenderEditable? editable;
  renderObject?.visitChildren((child) {
    editable ??= _findRenderEditable(child);
  });
  return editable;
}

TextSpan _interactivePassageText(
  BuildContext context,
  ScripturePassage passage,
  String query, {
  required int? startAt,
  required ({int start, int end})? localSearchRange,
  required List<ScriptureLine> sourceLines,
  required double width,
  required List<TapGestureRecognizer> recognizers,
}) {
  for (final recognizer in recognizers) {
    recognizer.dispose();
  }
  recognizers.clear();
  final settings = scriptureDisplaySettings;
  final children = <InlineSpan>[];
  var offset = 0;
  var sourceOffset = 0;
  var didHighlight = false;

  TextSpan highlighted(String value, int start, int sourceStart) {
    final range = localSearchRange;
    if (range != null) {
      final startInValue = (range.start - sourceStart).clamp(0, value.length);
      final endInValue = (range.end - sourceStart).clamp(0, value.length);
      if (startInValue >= endInValue) return TextSpan(text: value);
      return TextSpan(
        children: [
          if (startInValue > 0)
            TextSpan(text: value.substring(0, startInValue)),
          TextSpan(
            text: value.substring(startInValue, endInValue),
            style: const TextStyle(
              backgroundColor: Color(0xFFFFE08A),
              color: Color(0xFF2C1810),
              fontWeight: FontWeight.w700,
            ),
          ),
          if (endInValue < value.length)
            TextSpan(text: value.substring(endInValue)),
        ],
      );
    }
    if (query.isEmpty || didHighlight) return TextSpan(text: value);
    var index = value.toLowerCase().indexOf(query.toLowerCase());
    while (index >= 0 && startAt != null && start + index < startAt) {
      index = value.toLowerCase().indexOf(
        query.toLowerCase(),
        index + query.length,
      );
    }
    if (index < 0) return TextSpan(text: value);
    didHighlight = true;
    return TextSpan(
      children: [
        TextSpan(text: value.substring(0, index)),
        TextSpan(
          text: value.substring(index, index + query.length),
          style: const TextStyle(
            backgroundColor: Color(0xFFDDEDE8),
            color: Color(0xFF145D54),
            fontWeight: FontWeight.w700,
          ),
        ),
        TextSpan(text: value.substring(index + query.length)),
      ],
    );
  }

  List<InlineSpan> spansForRange(
    String text,
    int from,
    int to,
    int lineStart,
    int sourceLineStart,
    List<ScriptureInlineNote> inlineNotes,
  ) {
    final spans = <InlineSpan>[];
    var cursor = from;
    for (final note in inlineNotes) {
      final noteStart = note.offset;
      final noteEnd = note.offset + note.length;
      if (noteEnd <= cursor || noteStart >= to) continue;
      final cut = noteStart.clamp(cursor, to);
      if (cut > cursor) {
        spans.add(
          highlighted(
            text.substring(cursor, cut),
            lineStart + cursor,
            sourceLineStart + cursor,
          ),
        );
      }
      final noteFrom = noteStart.clamp(cursor, to);
      final noteTo = noteEnd.clamp(noteFrom, to);
      if (noteTo > noteFrom) {
        spans.add(
          TextSpan(
            style: TextStyle(
              color: const Color(0xFF9C8B78),
              fontSize: settings.fontSize * 0.85,
            ),
            children: [
              highlighted(
                text.substring(noteFrom, noteTo),
                lineStart + noteFrom,
                sourceLineStart + noteFrom,
              ),
            ],
          ),
        );
      }
      cursor = noteTo;
    }
    if (cursor < to) {
      spans.add(
        highlighted(
          text.substring(cursor, to),
          lineStart + cursor,
          sourceLineStart + cursor,
        ),
      );
    }
    return spans;
  }

  List<InlineSpan> contentSpans(
    ScriptureLine line,
    int lineStart,
    int sourceLineStart,
  ) {
    final spans = <InlineSpan>[];
    var contentOffset = 0;
    for (final note in line.footnotes) {
      final noteOffset = note.offset.clamp(contentOffset, line.text.length);
      spans.addAll(
        spansForRange(
          line.text,
          contentOffset,
          noteOffset,
          lineStart,
          sourceLineStart,
          line.inlineNotes,
        ),
      );
      if (settings.showCollation) {
        final marker = '[${note.label}]';
        if (note.content.isNotEmpty) {
          final recognizer = TapGestureRecognizer()
            ..onTap = () => showDialog<void>(
              context: context,
              builder: (context) => AlertDialog(
                title: Text(note.label.startsWith('A') ? 'CBETA 修訂註解' : '校勘記'),
                content: _DisplaySelectableText(note.content),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('關閉'),
                  ),
                ],
              ),
            );
          recognizers.add(recognizer);
          spans.add(
            TextSpan(
              text: marker,
              style: const TextStyle(
                color: Color(0xFF8B6B2F),
                fontSize: 13,
                decoration: TextDecoration.underline,
              ),
              recognizer: recognizer,
            ),
          );
        } else {
          spans.add(TextSpan(text: marker));
        }
      }
      contentOffset = noteOffset;
    }
    spans.addAll(
      spansForRange(
        line.text,
        contentOffset,
        line.text.length,
        lineStart,
        sourceLineStart,
        line.inlineNotes,
      ),
    );
    return spans;
  }

  int visibleLineLength(ScriptureLine line) =>
      line.text.length +
      (settings.showCollation
          ? line.footnotes.fold<int>(
              0,
              (length, note) => length + note.label.length + 2,
            )
          : 0);

  TextStyle headingStyle(int level) {
    final scale = switch (level) {
      1 => 1.35,
      2 => 1.25,
      3 => 1.16,
      4 => 1.1,
      5 => 1.05,
      _ => 1.0,
    };
    return _scriptureTextStyle(settings).copyWith(
      fontSize: settings.fontSize * scale,
      fontWeight: level <= 2 ? FontWeight.w700 : FontWeight.w600,
      letterSpacing: 0,
    );
  }

  void addContent(ScriptureLine line) {
    final content = contentSpans(line, offset, sourceOffset);
    if (line.headingLevel > 0) {
      children.add(
        TextSpan(style: headingStyle(line.headingLevel), children: content),
      );
    } else {
      children.addAll(content);
    }
    offset = offset + visibleLineLength(line);
    sourceOffset += line.text.length + (line.verseCells.isNotEmpty ? 1 : 0);
  }

  for (final line in sourceLines) {
    if (settings.showLineBeginnings &&
        line.linehead != null &&
        line.role != ScriptureLineRole.navigationAnchor) {
      final marker = '[${line.linehead!.split('_p').last}] ';
      children.add(
        TextSpan(
          text: marker,
          style: const TextStyle(
            color: Color(0xFF9A7A42),
            fontSize: 13,
            fontWeight: FontWeight.w600,
          ),
        ),
      );
      offset += marker.length;
    }
    if (line.tableRows.isNotEmpty) {
      var tableTextOffset = 0;
      children.add(
        WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: SizedBox(
            width: width,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final row in line.tableRows)
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (final cell in row)
                        Expanded(
                          flex: cell.columnSpan,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 6,
                            ),
                            decoration: BoxDecoration(
                              border: Border.all(
                                color: settings.textColor.withValues(
                                  alpha: 0.25,
                                ),
                              ),
                            ),
                            child: Text.rich(
                              TextSpan(
                                children: [
                                  highlighted(
                                    cell.text,
                                    offset + tableTextOffset,
                                    sourceOffset + tableTextOffset,
                                  ),
                                ],
                              ),
                              style: _scriptureTextStyle(settings),
                            ),
                          ),
                        ),
                    ],
                  ),
              ],
            ),
          ),
        ),
      );
      offset += visibleLineLength(line) + 1;
      children.add(const TextSpan(text: '\n'));
      sourceOffset += line.text.length + 1;
    } else if (line.images.isNotEmpty) {
      for (final image in line.images) {
        children.add(
          WidgetSpan(
            alignment: PlaceholderAlignment.middle,
            child: SizedBox(
              width: width,
              child: Image.network(
                image.source,
                width: width,
                fit: BoxFit.contain,
                semanticLabel: image.alt.isEmpty ? null : image.alt,
                loadingBuilder: (context, child, progress) => progress == null
                    ? child
                    : SizedBox(
                        height: 180,
                        child: Center(
                          child: CircularProgressIndicator(
                            value: progress.expectedTotalBytes == null
                                ? null
                                : progress.cumulativeBytesLoaded /
                                      progress.expectedTotalBytes!,
                          ),
                        ),
                      ),
                errorBuilder: (context, error, stackTrace) => Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Text(
                    '圖片載入失敗${image.alt.isEmpty ? '' : '：${image.alt}'}',
                    style: _scriptureTextStyle(settings),
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
            ),
          ),
        );
      }
      if (line.text.isNotEmpty) {
        addContent(line);
      } else {
        children.add(const TextSpan(text: '\n'));
        offset++;
      }
    } else if (line.verseCells.isNotEmpty) {
      children.add(
        WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: SizedBox(
            width: width,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                for (
                  var cellIndex = 0;
                  cellIndex < line.verseCells.length;
                  cellIndex++
                )
                  Flexible(
                    child: Text.rich(
                      TextSpan(
                        children: contentSpans(
                          ScriptureLine(
                            text: line.verseCells[cellIndex],
                            footnotes: line.footnotes
                                .where(
                                  (note) =>
                                      note.offset >=
                                          line.verseCells
                                              .take(cellIndex)
                                              .fold<int>(
                                                0,
                                                (length, cell) =>
                                                    length + cell.length,
                                              ) &&
                                      note.offset <=
                                          line.verseCells
                                                  .take(cellIndex)
                                                  .fold<int>(
                                                    0,
                                                    (length, cell) =>
                                                        length + cell.length,
                                                  ) +
                                              line.verseCells[cellIndex].length,
                                )
                                .map(
                                  (note) => ScriptureFootnote(
                                    offset:
                                        note.offset -
                                        line.verseCells
                                            .take(cellIndex)
                                            .fold<int>(
                                              0,
                                              (length, cell) =>
                                                  length + cell.length,
                                            ),
                                    label: note.label,
                                    clue: note.clue,
                                    content: note.content,
                                  ),
                                )
                                .toList(),
                          ),
                          offset +
                              line.verseCells
                                  .take(cellIndex)
                                  .fold<int>(
                                    0,
                                    (length, cell) => length + cell.length,
                                  ),
                          sourceOffset +
                              line.verseCells
                                  .take(cellIndex)
                                  .fold<int>(
                                    0,
                                    (length, cell) => length + cell.length,
                                  ),
                        ),
                      ),
                      textAlign: TextAlign.center,
                      style: _scriptureTextStyle(settings),
                    ),
                  ),
              ],
            ),
          ),
        ),
      );
      offset += visibleLineLength(line);
      children.add(const TextSpan(text: '\n'));
      offset++;
      sourceOffset += line.text.length + 1;
    } else {
      addContent(line);
    }
  }
  return TextSpan(children: children);
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
            tooltip: _displayText('上一筆', context),
            onPressed: onPrevious,
            icon: const Icon(Icons.keyboard_arrow_up_rounded),
          ),
          Text('${current + 1} / $total 筆'),
          IconButton(
            tooltip: _displayText('下一筆', context),
            onPressed: onNext,
            icon: const Icon(Icons.keyboard_arrow_down_rounded),
          ),
          IconButton(
            tooltip: _displayText('關閉搜尋導航', context),
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

String? _lineheadAtOffset(
  List<ScriptureLine> lines,
  int offset, {
  required bool showLineBeginnings,
  required bool showCollation,
}) {
  var currentOffset = 0;
  String? currentLinehead;
  for (final line in lines) {
    if (currentOffset > offset) break;
    if (line.linehead != null) currentLinehead = line.linehead;
    final lineEnd =
        currentOffset +
        visibleScriptureLine(
          line,
          showLineBeginnings: showLineBeginnings,
          showCollation: showCollation,
        ).length;
    if (offset <= lineEnd) return currentLinehead;
    currentOffset = lineEnd;
  }
  return currentLinehead;
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

TextSpan _highlightedPassageText(String text, String query, {int? startAt}) {
  final index = text.toLowerCase().indexOf(query.toLowerCase(), startAt ?? 0);
  if (query.isEmpty || index < 0) return TextSpan(text: text);
  return TextSpan(
    children: [
      TextSpan(text: text.substring(0, index)),
      TextSpan(
        text: text.substring(index, index + query.length),
        style: const TextStyle(
          backgroundColor: Color(0xFFDDEDE8),
          color: Color(0xFF145D54),
          fontWeight: FontWeight.w700,
        ),
      ),
      TextSpan(text: text.substring(index + query.length)),
    ],
  );
}

Future<void> _copySelectedPassage(
  BuildContext context,
  ScripturePassage passage,
  String selectedText, {
  String? selectedStartLinehead,
  String? selectedEndLinehead,
}) async {
  var endLinehead = selectedEndLinehead ?? passage.linehead;
  var startLinehead = selectedStartLinehead ?? passage.linehead;
  String? sectionTitle;
  try {
    if (selectedStartLinehead == null) {
      final lineheads = await _loadSelectionLineheads(passage, selectedText);
      startLinehead = lineheads.firstOrNull ?? passage.linehead;
      endLinehead = lineheads.length > 1 ? lineheads.last : passage.linehead;
    }
    sectionTitle = await _loadSectionTitle(passage, startLinehead);
  } catch (_) {
    // Keep the citation useful even if optional metadata requests fail.
  }

  await Clipboard.setData(
    ClipboardData(
      text: formatSelectedPassageForCopy(
        passage,
        selectedText,
        startLinehead: startLinehead,
        endLinehead: endLinehead,
        sectionTitle: sectionTitle,
      ),
    ),
  );
  if (context.mounted) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('引文已複製')));
  }
}

Future<List<String>> _loadSelectionLineheads(
  ScripturePassage passage,
  String selectedText,
) async {
  final linehead = passage.linehead;
  if (linehead == null) return const [];
  final response = await http
      .get(
        Uri.https('cbdata.dila.edu.tw', '/stable/lines', {
          'linehead': linehead,
          'before': '20',
          'after': '30',
        }),
      )
      .timeout(const Duration(seconds: 20));
  if (response.statusCode != 200) return [linehead];

  final payload =
      jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
  final rows = (payload['results'] as List<dynamic>? ?? const [])
      .whereType<Map<String, dynamic>>()
      .toList();
  final normalizedSelection = _normalizeCitationText(selectedText);
  if (normalizedSelection.isEmpty) return [linehead];

  final rowText = rows
      .map(
        (row) =>
            _normalizeCitationText(_decodeCitationHtml('${row['html'] ?? ''}')),
      )
      .toList();
  final joinedText = rowText.join();
  final selectionStart = joinedText.indexOf(normalizedSelection);
  if (selectionStart < 0) return [linehead];
  final selectionEnd = selectionStart + normalizedSelection.length - 1;

  var characterOffset = 0;
  String? startLinehead;
  String? endLinehead;
  for (var index = 0; index < rows.length; index++) {
    final nextOffset = characterOffset + rowText[index].length;
    if (startLinehead == null && selectionStart < nextOffset) {
      startLinehead = '${rows[index]['linehead']}';
    }
    if (selectionEnd < nextOffset) {
      endLinehead = '${rows[index]['linehead']}';
      break;
    }
    characterOffset = nextOffset;
  }
  return [startLinehead ?? linehead, endLinehead ?? startLinehead ?? linehead];
}

Future<String?> _loadSectionTitle(
  ScripturePassage passage,
  String? selectedStartLinehead,
) async {
  final work = RegExp(
    r'^([A-Z]+)\d+n(\d+)',
  ).firstMatch(selectedStartLinehead ?? '');
  if (work == null || selectedStartLinehead == null) return null;
  final workId = '${work.group(1)}${work.group(2)}';
  final file = selectedStartLinehead.split('_p').first;
  final response = await http
      .get(
        Uri.https('cbdata.dila.edu.tw', '/stable/works/toc', {'work': workId}),
      )
      .timeout(const Duration(seconds: 20));
  if (response.statusCode != 200) return null;

  final payload =
      jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
  final result = (payload['results'] as List<dynamic>? ?? const []).firstOrNull;
  if (result is! Map<String, dynamic>) return null;
  final nodes = <Map<String, dynamic>>[];
  void collect(dynamic value) {
    if (value is! Map<String, dynamic>) return;
    nodes.add(value);
    for (final child in value['children'] as List<dynamic>? ?? const []) {
      collect(child);
    }
  }

  for (final node in result['mulu'] as List<dynamic>? ?? const []) {
    collect(node);
  }
  final line = selectedStartLinehead.split('_p').last;
  final candidates = nodes.where((node) {
    return node['type'] == '品' &&
        node['file'] == file &&
        '${node['lb']}'.compareTo(line) <= 0;
  }).toList()..sort((a, b) => '${b['lb']}'.compareTo('${a['lb']}'));
  return candidates.firstOrNull?['title'] as String?;
}

String _decodeCitationHtml(String value) => value
    .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '')
    .replaceAll(RegExp(r'<[^>]*>'), '')
    .replaceAll('&nbsp;', ' ')
    .replaceAll('&quot;', '"')
    .replaceAll('&#39;', "'")
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&amp;', '&');

String _normalizeCitationText(String text) =>
    text.replaceAll(RegExp(r'\s+'), '');

String formatSelectedPassageForCopy(
  ScripturePassage passage,
  String selectedText, {
  String? startLinehead,
  String? endLinehead,
  String? sectionTitle,
}) {
  final start = _citationLocation(startLinehead ?? passage.linehead);
  final end = _citationLocation(endLinehead) ?? start;
  final citationLocation = start == null
      ? ''
      : start.page == end?.page && start.column == end?.column
      ? '${start.page}${start.column}${start.line}'
            '${start.line == end?.line ? '' : '-${end!.line}'}'
      : '${start.page}${start.column}${start.line}-'
            '${end?.page}${end?.column}${end?.line}';
  final citation = start == null
      ? '(CBETA 2026.R1)'
      : '(CBETA 2026.R1, ${start.volume}, no. ${start.number}, '
            'p. $citationLocation)';
  final volume = passage.juan == null ? '' : '卷${passage.juan}';
  final section = sectionTitle == null ? '' : '〈$sectionTitle〉';
  return '《${passage.title}》$volume$section：「\n$selectedText」$citation';
}

String extractCbetaGotoQuery(String input) {
  final trimmed = input.trim();
  final citation = RegExp(
    r'[\(（]\s*(CBETA\b[^)）]*?)\s*[\)）]',
    caseSensitive: false,
  ).firstMatch(trimmed);
  return citation?.group(1)?.trim() ?? trimmed;
}

String normalizeCbetaGotoLinehead(String input) {
  final linehead = RegExp(
    r'\b([A-Z]\d{1,3})\s*,?\s*no\.?\s*(\d+)\s*,?\s*p{1,2}\.?\s*([a-z]?)(\d{1,4})([a-z])(\d{1,2})',
    caseSensitive: false,
  ).firstMatch(input);
  if (linehead == null) return input.trim();
  return '${linehead.group(1)!.toUpperCase()}n'
      '${linehead.group(2)!.padLeft(4, '0')}_p'
      '${linehead.group(3)!.toLowerCase()}'
      '${linehead.group(4)!.padLeft(linehead.group(3)!.isEmpty ? 4 : 3, '0')}'
      '${linehead.group(5)!.toLowerCase()}'
      '${linehead.group(6)!.padLeft(2, '0')}';
}

bool isCbetaGotoExpression(String input) {
  final candidate = normalizeCbetaGotoLinehead(extractCbetaGotoQuery(input));
  return RegExp(
    r'^[A-Z]\d{1,3}n\d{4}_p[a-z]?\d{3,4}[a-z]\d{2}$',
  ).hasMatch(candidate);
}

String _catalogResultWorkId(Map<String, dynamic> result) {
  final work = '${result['work'] ?? ''}'.trim();
  if (work.isNotEmpty) return work;
  final file = '${result['file'] ?? ''}';
  final match = RegExp(r'^([A-Z]+)\d+n(\d+)').firstMatch(file);
  return match == null ? '' : '${match.group(1)}${match.group(2)}';
}

/// 取得作品的卷清單。
///
/// 多數作品以 `juan` 欄位提供卷資料；部分作品（例如印順法師著作等 Y 系列）
/// 只提供 `mulu` 目錄樹，此時改由目錄樹依卷彙整出可讀取的卷。
List<Map<String, dynamic>> _tocJuanEntries(Map<String, dynamic>? toc) {
  final juans = (toc?['juan'] as List<dynamic>? ?? const [])
      .whereType<Map<String, dynamic>>()
      .toList();
  if (juans.isNotEmpty) return juans;

  void collect(List<dynamic> entries, Map<int, Map<String, dynamic>> byJuan) {
    for (final entry in entries.whereType<Map<String, dynamic>>()) {
      final juan = int.tryParse('${entry['juan'] ?? ''}');
      final lb = '${entry['lb'] ?? ''}';
      if (juan != null) {
        final current = byJuan[juan];
        if (current == null ||
            (lb.isNotEmpty && lb.compareTo('${current['lb'] ?? ''}') < 0)) {
          byJuan[juan] = {
            'file': entry['file'],
            'juan': juan,
            'lb': entry['lb'],
            'title': '第$juan卷',
          };
        }
      }
      collect(entry['children'] as List<dynamic>? ?? const [], byJuan);
    }
  }

  final byJuan = <int, Map<String, dynamic>>{};
  collect(toc?['mulu'] as List<dynamic>? ?? const [], byJuan);
  return byJuan.values.toList()..sort(
    (left, right) => (left['juan'] as int).compareTo(right['juan'] as int),
  );
}

String _searchResultWorkId(ScriptureSearchResult result) {
  final passageWork = result.passages.firstOrNull?.work;
  if (passageWork != null && passageWork.isNotEmpty) return passageWork;
  final match = RegExp(r'^([A-Z]+\d+)').firstMatch(result.title);
  return match?.group(1) ?? '';
}

Future<List<Map<String, dynamic>>> _fetchCatalogSearchResults(
  String query,
) async {
  final response = await http
      .get(Uri.https('cbdata.dila.edu.tw', '/stable/search/toc', {'q': query}))
      .timeout(const Duration(seconds: 20));
  if (response.statusCode != 200) {
    throw Exception('經目查詢 API 回傳 ${response.statusCode}');
  }
  final payload =
      jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
  if (payload['success'] == false) {
    throw Exception('經目查詢失敗：${payload['error'] ?? '未知錯誤'}');
  }
  final seen = <String>{};
  return (payload['results'] as List<dynamic>? ?? const [])
      .whereType<Map<String, dynamic>>()
      .where((row) => row['type'] == null || row['type'] == 'work')
      .where((row) {
        final work = _catalogResultWorkId(row);
        return work.isNotEmpty && seen.add(work);
      })
      .toList();
}

Future<ScripturePassage> _resolveGotoPassage(String input) async {
  final linehead = normalizeCbetaGotoLinehead(extractCbetaGotoQuery(input));
  if (!isCbetaGotoExpression(linehead)) {
    throw const FormatException('請輸入有效的 CBETA 行號或引文');
  }
  try {
    return await _resolveGotoPassageOnline(linehead);
  } catch (error) {
    if (_isNetworkFailure(error)) {
      final local = await _resolveGotoPassageLocally(linehead);
      if (local != null) return local;
      throw FormatException('離線模式下，本地尚未儲存「$linehead」所在的經卷');
    }
    rethrow;
  }
}

Future<ScripturePassage> _resolveGotoPassageOnline(String linehead) async {
  final response = await http
      .get(
        Uri.https('cbdata.dila.edu.tw', '/stable/juans/goto', {
          'linehead': linehead,
        }),
      )
      .timeout(const Duration(seconds: 20));
  if (response.statusCode != 200) {
    throw Exception('Goto API 回傳 ${response.statusCode}');
  }
  final payload =
      jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
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
  if (result == null) throw const FormatException('找不到此行號對應的經卷');
  return _resolveWorkPassage(
    result,
    targetLinehead: '${result['linehead'] ?? linehead}',
  );
}

Future<ScripturePassage> _resolveCatalogWorkPassage(
  Map<String, dynamic> result,
) async {
  final work = _catalogResultWorkId(result);
  if (work.isEmpty) throw const FormatException('經目資料缺少作品編號');
  return _resolveWorkPassage({...result, 'work': work});
}

Future<ScripturePassage> _resolveWorkPassage(
  Map<String, dynamic> item, {
  String? targetLinehead,
}) async {
  final work = '${item['work'] ?? _catalogResultWorkId(item)}';
  if (work.isEmpty) throw const FormatException('經目資料缺少作品編號');
  try {
    return await _resolveWorkPassageOnline(
      work,
      item,
      targetLinehead: targetLinehead,
    );
  } catch (error) {
    if (_isNetworkFailure(error)) {
      final local = await _localWorkPassage(
        work,
        targetLinehead: targetLinehead,
      );
      if (local != null) return local;
    }
    rethrow;
  }
}

Future<ScripturePassage> _resolveWorkPassageOnline(
  String work,
  Map<String, dynamic> item, {
  String? targetLinehead,
}) async {
  final response = await http
      .get(Uri.https('cbdata.dila.edu.tw', '/stable/works/toc', {'work': work}))
      .timeout(const Duration(seconds: 20));
  if (response.statusCode != 200) {
    throw Exception('作品目錄 API 回傳 ${response.statusCode}');
  }
  final payload =
      jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
  final toc = (payload['results'] as List<dynamic>? ?? const [])
      .whereType<Map<String, dynamic>>()
      .firstOrNull;
  final juans = _tocJuanEntries(toc);
  if (juans.isEmpty) throw const FormatException('此作品沒有可讀取的卷');

  final availableJuans =
      juans
          .map((entry) => entry['juan'])
          .whereType<num>()
          .map((value) => value.toInt())
          .toSet()
          .toList()
        ..sort();
  final targetJuan = targetLinehead == null
      ? null
      : int.tryParse('${item['juan'] ?? ''}');
  if (targetJuan != null && !availableJuans.contains(targetJuan)) {
    availableJuans.add(targetJuan);
    availableJuans.sort();
  }
  final selected =
      juans.where((entry) => entry['juan'] == targetJuan).firstOrNull ??
      (targetJuan == null
          ? null
          : {
              'file': item['file'],
              'juan': targetJuan,
              'lb': item['lb'] ?? targetLinehead!.split('_p').last,
            }) ??
      juans
          .where((entry) => entry['juan'] == availableJuans.first)
          .firstOrNull ??
      juans.first;
  final file = '${selected['file'] ?? item['file'] ?? work}';
  final line = targetLinehead == null
      ? '${selected['lb'] ?? ''}'
      : targetLinehead.split('_p').last;
  final rawTitle = '${item['title'] ?? item['label'] ?? work}';
  final title = rawTitle.replaceFirst(
    RegExp('^${RegExp.escape(work)}\\s+'),
    '',
  );
  return ScripturePassage(
    title: title,
    reference: '卷 ${selected['juan']}',
    text: '',
    linehead: line.isEmpty ? null : '${file}_p$line',
    juan: '${selected['juan']}',
    work: work,
    availableJuans: availableJuans,
  );
}

String _creatorStrokeGroup(String name) {
  if (name.isEmpty) return '其他';
  final code = name.codeUnitAt(0);
  if (code < 0x4E00 || code > 0x9FFF) return '其他';
  const commonCharacters = <int, String>{
    1: '一丨丶丿乙',
    2: '二十丁七人入八九刀力又乃了',
    3: '三上下大女子小山已也凡口土士',
    4: '不中之五今元六天太少日月比王',
    5: '以出去正生他加功北半古可四外',
    6: '如字守安有百而自至全同名合因',
    7: '但住何佛作即含吾我更每見身足',
    8: '使來其具所受取和定於明法知空',
    9: '則前南品度是為相約若要',
    10: '修根般起能記高時真',
    11: '得從教理現眾處通問國',
    12: '善復智無等結菩開集',
    13: '意業經義聖解道達',
    14: '說種福聞與語',
    15: '慧論質德慶廣',
  };
  final character = String.fromCharCode(code);
  for (final entry in commonCharacters.entries) {
    if (entry.value.contains(character)) return '${entry.key} 劃';
  }
  final estimate = (((code - 0x4E00) / (0x9FFF - 0x4E00)) * 25).round() + 1;
  if (estimate <= 5) return '1-5 劃';
  if (estimate <= 10) return '6-10 劃';
  if (estimate <= 15) return '11-15 劃';
  if (estimate <= 20) return '16-20 劃';
  return '21 劃以上';
}

int _creatorStrokeGroupNumber(String group) =>
    int.tryParse(RegExp(r'^\d+').firstMatch(group)?.group(0) ?? '') ?? 999;

int _compareCreatorNames(String left, String right) =>
    (_creatorCollator ?? (throw StateError('作譯者排序尚未初始化'))).compare(left, right);

IcuCollator? _creatorCollator;
Future<void>? _icuInitialization;

Future<void> _ensureCreatorCollator() async {
  await (_icuInitialization ??= IcuKit.init(webEngine: WebEngine.browserIntl));
  _creatorCollator ??= IcuCollator(locale: 'zh-Hant');
}

({String volume, String number, int page, String column, int line})?
_citationLocation(String? linehead) {
  final match = RegExp(
    r'^([A-Z]\d+)n(\d+)_p(\d{4})([a-z])(\d+)$',
  ).firstMatch(linehead ?? '');
  if (match == null) return null;
  return (
    volume: match.group(1)!,
    number: match.group(2)!,
    page: int.parse(match.group(3)!),
    column: match.group(4)!,
    line: int.parse(match.group(5)!),
  );
}

class _SearchBatch {
  const _SearchBatch({
    required this.results,
    required this.nextStart,
    required this.totalFound,
    required this.totalTermHits,
  });

  final List<ScriptureSearchResult> results;
  final int nextStart;
  final int totalFound;
  final int totalTermHits;
}

/// 判斷錯誤是否來自網路連線不可用，而非遠端服務回傳的錯誤。
bool _isNetworkFailure(Object error) =>
    error is SocketException ||
    error is TimeoutException ||
    error is http.ClientException ||
    error is HandshakeException;

int _countOccurrences(String haystack, String needle) {
  if (needle.isEmpty) return 0;
  var count = 0;
  var index = haystack.indexOf(needle);
  while (index >= 0) {
    count += 1;
    index = haystack.indexOf(needle, index + needle.length);
  }
  return count;
}

/// 在無網路連線時，改以本地已儲存的離線經卷進行全文比對，
/// 盡量沿用與線上搜尋相同的結果結構與分頁行為。
Future<_SearchBatch> _searchOfflineVolumes(
  String query, {
  int start = 0,
  int pageSize = 20,
}) async {
  final needle = query.trim().toLowerCase();
  if (needle.isEmpty) {
    return const _SearchBatch(
      results: [],
      nextStart: 0,
      totalFound: 0,
      totalTermHits: 0,
    );
  }
  final volumes = await scriptureVolumeStore.list();
  volumes.sort((left, right) {
    final byWork = left.work.compareTo(right.work);
    if (byWork != 0) return byWork;
    return (int.tryParse(left.juan) ?? 0).compareTo(
      int.tryParse(right.juan) ?? 0,
    );
  });
  final workJuans = <String, Set<int>>{};
  for (final volume in volumes) {
    final juan = int.tryParse(volume.juan);
    if (juan != null) {
      workJuans.putIfAbsent(volume.work, () => <int>{}).add(juan);
    }
  }
  final results = <ScriptureSearchResult>[];
  var totalTermHits = 0;
  for (final volume in volumes) {
    final List<ScriptureLine> lines;
    try {
      lines = parseScriptureHtml(volume.html);
    } catch (_) {
      continue;
    }
    final title = _localWorkTitle(lines);
    final juans = (workJuans[volume.work]?.toList() ?? <int>[])..sort();
    final passages = <ScripturePassage>[];
    for (final line in lines) {
      if (line.role != ScriptureLineRole.regular) continue;
      final text = line.text.replaceAll(RegExp(r'\s+'), ' ').trim();
      if (text.isEmpty) continue;
      final lower = text.toLowerCase();
      if (!lower.contains(needle)) continue;
      totalTermHits += _countOccurrences(lower, needle);
      final linehead = line.linehead;
      final lineLabel = linehead == null ? '' : linehead.split('_p').last;
      passages.add(
        ScripturePassage(
          title: title.isEmpty ? volume.work : title,
          reference: [
            '卷${volume.juan}',
            if (lineLabel.isNotEmpty) lineLabel,
          ].join(' · '),
          text: text,
          linehead: linehead,
          juan: volume.juan,
          work: volume.work,
          availableJuans: juans,
        ),
      );
    }
    if (passages.isEmpty) continue;
    results.add(
      ScriptureSearchResult(
        title: '${volume.work} ${title.isEmpty ? '（離線經文）' : title}'.trim(),
        description: '離線經文 · 命中 ${passages.length} 處',
        passages: passages,
      ),
    );
  }
  final page = results.skip(start).take(pageSize).toList();
  return _SearchBatch(
    results: page,
    nextStart: start + page.length,
    totalFound: results.length,
    totalTermHits: totalTermHits,
  );
}

List<ScriptureLine>? _tryParseLocalVolume(CachedScriptureVolume volume) {
  try {
    return parseScriptureHtml(volume.html);
  } catch (_) {
    return null;
  }
}

({String title, String byline}) _localVolumeInfo(List<ScriptureLine> lines) {
  String pick(ScriptureLineRole role) => lines
      .firstWhere(
        (line) => line.role == role && line.text.trim().isNotEmpty,
        orElse: () => const ScriptureLine(text: ''),
      )
      .text
      .trim();
  return (
    title: pick(ScriptureLineRole.volumeTitle),
    byline: pick(ScriptureLineRole.byline),
  );
}

/// 去掉卷名尾端的「卷…」字樣，取得作品名稱。
String _localWorkTitle(List<ScriptureLine> lines) {
  final title = _localVolumeInfo(lines).title;
  final stripped = title
      .replaceFirst(RegExp(r'卷[第]?[〇零一二三四五六七八九十百千兩0-9]+$'), '')
      .trim();
  return stripped.isEmpty ? title : stripped;
}

List<int> _cachedJuansForWork(
  List<CachedScriptureVolume> volumes,
  String work,
) =>
    volumes
        .where((volume) => volume.work == work)
        .map((volume) => int.tryParse(volume.juan))
        .whereType<int>()
        .toSet()
        .toList()
      ..sort();

String _lineheadWorkId(String linehead) {
  final match = RegExp(r'^([A-Z]+)\d+n(\d+)_p').firstMatch(linehead);
  return match == null ? '' : '${match.group(1)}${match.group(2)}';
}

ScripturePassage _localPassage({
  required String work,
  required CachedScriptureVolume volume,
  required List<ScriptureLine> lines,
  required List<int> juans,
  String? linehead,
}) {
  final title = _localWorkTitle(lines);
  return ScripturePassage(
    title: title.isEmpty ? work : title,
    reference: '卷 ${volume.juan}',
    text: '',
    linehead: linehead,
    juan: volume.juan,
    work: work,
    availableJuans: juans,
  );
}

/// 以本地已儲存的離線經卷建立可開啟的經卷位置，
/// 供離線經目點擊與 Goto 使用。
Future<ScripturePassage?> _localWorkPassage(
  String work, {
  String? targetLinehead,
}) async {
  if (work.isEmpty) return null;
  final volumes = await scriptureVolumeStore.list();
  final workVolumes = volumes.where((volume) => volume.work == work).toList()
    ..sort(
      (left, right) => (int.tryParse(left.juan) ?? 0).compareTo(
        int.tryParse(right.juan) ?? 0,
      ),
    );
  if (workVolumes.isEmpty) return null;
  final juans = _cachedJuansForWork(volumes, work);
  if (targetLinehead != null) {
    for (final volume in workVolumes) {
      final lines = _tryParseLocalVolume(volume);
      if (lines != null &&
          lines.any((line) => line.linehead == targetLinehead)) {
        return _localPassage(
          work: work,
          volume: volume,
          lines: lines,
          juans: juans,
          linehead: targetLinehead,
        );
      }
    }
  }
  final target = workVolumes.first;
  final lines = _tryParseLocalVolume(target) ?? const <ScriptureLine>[];
  return _localPassage(work: work, volume: target, lines: lines, juans: juans);
}

/// 離線時依行號在本地已儲存的經卷中尋找對應位置。
Future<ScripturePassage?> _resolveGotoPassageLocally(String linehead) async {
  final work = _lineheadWorkId(linehead);
  if (work.isEmpty) return null;
  final volumes = await scriptureVolumeStore.list();
  for (final volume in volumes.where((volume) => volume.work == work)) {
    final lines = _tryParseLocalVolume(volume);
    if (lines == null || !lines.any((line) => line.linehead == linehead)) {
      continue;
    }
    return _localPassage(
      work: work,
      volume: volume,
      lines: lines,
      juans: _cachedJuansForWork(volumes, work),
      linehead: linehead,
    );
  }
  return null;
}

/// 離線時以本地已儲存經卷的經名／作譯者進行經目查詢。
Future<List<Map<String, dynamic>>> _searchOfflineCatalog(String query) async {
  final needle = query.trim().toLowerCase();
  if (needle.isEmpty) return const [];
  final volumes = await scriptureVolumeStore.list();
  final byWork = <String, List<CachedScriptureVolume>>{};
  for (final volume in volumes) {
    byWork
        .putIfAbsent(volume.work, () => <CachedScriptureVolume>[])
        .add(volume);
  }
  final results = <Map<String, dynamic>>[];
  for (final entry in byWork.entries) {
    final volume = entry.value.reduce(
      (left, right) =>
          (int.tryParse(left.juan) ?? 0) <= (int.tryParse(right.juan) ?? 0)
          ? left
          : right,
    );
    final lines = _tryParseLocalVolume(volume);
    if (lines == null) continue;
    final info = _localVolumeInfo(lines);
    final title = _localWorkTitle(lines).isNotEmpty
        ? _localWorkTitle(lines)
        : entry.key;
    final haystack = '$title ${info.byline} ${entry.key}'.toLowerCase();
    if (!haystack.contains(needle)) continue;
    results.add({
      'work': entry.key,
      'title': title,
      if (info.byline.isNotEmpty) 'byline': info.byline,
      'offline': true,
    });
  }
  results.sort(
    (left, right) => '${left['title']}'.compareTo('${right['title']}'),
  );
  return results;
}

Future<_SearchBatch> _fetchSearchBatch(String query, {int start = 0}) async {
  const pageSize = 20;
  final response = await http
      .get(
        Uri.https('cbdata.dila.edu.tw', '/stable/search/all_in_one', {
          'q': query,
          'start': '$start',
          'rows': '$pageSize',
          'around': '30',
          'facet': '1',
        }),
      )
      .timeout(const Duration(seconds: 20));
  if (response.statusCode != 200) {
    throw Exception('全文檢索 API 回傳 ${response.statusCode}');
  }

  final payload =
      jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
  if (payload['success'] == false) {
    throw Exception('全文檢索失敗：${payload['error'] ?? '未知錯誤'}');
  }
  final rows = (payload['results'] as List<dynamic>? ?? const [])
      .whereType<Map<String, dynamic>>()
      .toList();
  return _SearchBatch(
    results: rows.map(_parseSearchResult).toList(),
    nextStart: start + rows.length,
    totalFound: payload['num_found'] as int? ?? start + rows.length,
    totalTermHits: (payload['total_term_hits'] as num?)?.toInt() ?? 0,
  );
}

ScriptureSearchResult _parseSearchResult(Map<String, dynamic> row) {
  final work = '${row['work'] ?? row['file'] ?? ''}';
  final juan = row['juan']?.toString();
  final title = '${row['title'] ?? ''}';
  final byline = '${row['byline'] ?? ''}';
  final dynasty = '${row['time_dynasty'] ?? ''}';
  final availableJuans = '${row['juan_list'] ?? ''}'
      .split(',')
      .map(int.tryParse)
      .whereType<int>()
      .toList();
  final kwics = row['kwics'];
  final kwicRows = kwics is Map<String, dynamic>
      ? (kwics['results'] as List<dynamic>? ?? const [])
            .whereType<Map<String, dynamic>>()
      : const <Map<String, dynamic>>[];
  final passages = kwicRows
      .map((kwic) {
        final text = _stripSearchMarkup('${kwic['kwic'] ?? ''}');
        final volume = '${kwic['vol'] ?? ''}';
        final line = '${kwic['lb'] ?? ''}';
        final linehead =
            kwic['linehead']?.toString() ??
            (line.isEmpty ? null : '${row['file']}_p$line');
        final reference = [
          if (juan != null) '卷$juan',
          if (volume.isNotEmpty) volume,
          if (line.isNotEmpty) line,
        ].join(' · ');
        return ScripturePassage(
          title: title,
          reference: reference,
          text: text,
          linehead: linehead,
          juan: juan,
          work: work,
          availableJuans: availableJuans,
        );
      })
      .where((passage) => passage.text.isNotEmpty)
      .toList();

  return ScriptureSearchResult(
    title: '$work $title'.trim(),
    description: [
      if (byline.isNotEmpty) byline,
      if (dynasty.isNotEmpty && dynasty != 'unknown') dynasty,
      if (juan != null) '卷 $juan',
    ].join(' '),
    passages: passages,
  );
}

String _stripSearchMarkup(String text) => text
    .replaceAll(RegExp(r'<[^>]*>'), '')
    .replaceAll('&nbsp;', ' ')
    .replaceAll('&quot;', '"')
    .replaceAll('&#39;', "'")
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&amp;', '&')
    .trim();

class _ReaderBookmark {
  const _ReaderBookmark({
    required this.work,
    required this.title,
    required this.juan,
    required this.linehead,
    required this.availableJuans,
  });

  final String work;
  final String title;
  final String juan;
  final String? linehead;
  final List<int> availableJuans;

  String get key => '$work:$juan:${linehead ?? ''}';

  factory _ReaderBookmark.fromPassage(ScripturePassage passage) =>
      _ReaderBookmark(
        work: passage.work ?? '',
        title: passage.title,
        juan: passage.juan ?? '1',
        linehead: passage.linehead,
        availableJuans: passage.availableJuans,
      );

  factory _ReaderBookmark.fromJson(Map<String, dynamic> json) =>
      _ReaderBookmark(
        work: json['work'] as String? ?? '',
        title: json['title'] as String? ?? '',
        juan: json['juan']?.toString() ?? '1',
        linehead: json['linehead'] as String?,
        availableJuans: (json['availableJuans'] as List<dynamic>? ?? const [])
            .whereType<num>()
            .map((value) => value.toInt())
            .toList(),
      );

  Map<String, Object?> toJson() => {
    'work': work,
    'title': title,
    'juan': juan,
    'linehead': linehead,
    'availableJuans': availableJuans,
  };

  ScripturePassage toPassage() => ScripturePassage(
    title: title,
    reference: '卷 $juan',
    text: '',
    linehead: linehead,
    juan: juan,
    work: work,
    availableJuans: availableJuans,
  );
}

const _readerBookmarksKey = 'reader_bookmarks';
const _readingHistoryKey = 'reading_history';
const _searchHistoryKey = 'search_history';
const _maximumSearchHistory = 20;
const _initialRecentReadingsCount = 3;
const _recentReadingsPageSize = 20;

Future<List<String>> _loadSearchHistory() async {
  final preferences = await SharedPreferences.getInstance();
  final stored = preferences.getString(_searchHistoryKey);
  if (stored == null) return [];
  final decoded = jsonDecode(stored);
  if (decoded is! List<dynamic> || decoded.any((item) => item is! String)) {
    throw const FormatException('搜尋記錄資料格式錯誤');
  }
  return decoded.whereType<String>().toList();
}

Future<void> _recordSearchQuery(String query) async {
  final history = await _loadSearchHistory();
  final normalizedQuery = SimplifiedTraditionalConverter.convert(
    query.trim(),
  ).toLowerCase();
  history.removeWhere(
    (savedQuery) =>
        SimplifiedTraditionalConverter.convert(
          savedQuery.trim(),
        ).toLowerCase() ==
        normalizedQuery,
  );
  history.insert(0, query.trim());
  if (history.length > _maximumSearchHistory) {
    history.removeRange(_maximumSearchHistory, history.length);
  }
  final saved = await (await SharedPreferences.getInstance()).setString(
    _searchHistoryKey,
    jsonEncode(history),
  );
  if (!saved) throw StateError('無法儲存搜尋記錄');
}

Future<List<_ReaderBookmark>> _loadBookmarkRecords(String key) async {
  final preferences = await SharedPreferences.getInstance();
  final stored = preferences.getString(key);
  if (stored == null) return [];
  final decoded = jsonDecode(stored);
  if (decoded is! List<dynamic>) {
    throw const FormatException('閱讀記錄資料格式錯誤');
  }
  return decoded
      .whereType<Map<String, dynamic>>()
      .map(_ReaderBookmark.fromJson)
      .toList();
}

Future<List<_ReaderBookmark>> _loadBookmarks() async {
  return _loadBookmarkRecords(_readerBookmarksKey);
}

Future<void> _saveBookmarks(List<_ReaderBookmark> bookmarks) async {
  final preferences = await SharedPreferences.getInstance();
  final saved = await preferences.setString(
    _readerBookmarksKey,
    jsonEncode(bookmarks.map((bookmark) => bookmark.toJson()).toList()),
  );
  if (!saved) throw StateError('無法儲存書籤');
}

Future<void> _recordRecentReading(ScripturePassage passage) async {
  final history = await _loadBookmarkRecords(_readingHistoryKey);
  final current = _ReaderBookmark.fromPassage(passage);
  history.removeWhere((item) => item.work == current.work);
  history.insert(0, current);
  final preferences = await SharedPreferences.getInstance();
  final saved = await preferences.setString(
    _readingHistoryKey,
    jsonEncode(history.map((bookmark) => bookmark.toJson()).toList()),
  );
  if (!saved) throw StateError('無法儲存閱讀記錄');
}

Future<ScripturePassage?> _showWorkPicker(BuildContext context) =>
    showGeneralDialog<ScripturePassage>(
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
                child: const _WorkPickerPage(),
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
  final ValueChanged<String> onSearch;
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
          child: TextField(
            controller: controller,
            autofocus: true,
            decoration: InputDecoration(
              hintText: _displayText('在此卷中搜尋…', context),
              border: InputBorder.none,
              contentPadding: const EdgeInsets.symmetric(horizontal: 14),
            ),
            onChanged: onSearch,
            onSubmitted: onSearch,
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Text(count),
        ),
        IconButton(
          tooltip: _displayText('上一筆', context),
          onPressed: onPrevious,
          icon: const Icon(Icons.keyboard_arrow_up_rounded),
        ),
        IconButton(
          tooltip: _displayText('下一筆', context),
          onPressed: onNext,
          icon: const Icon(Icons.keyboard_arrow_down_rounded),
        ),
        IconButton(
          tooltip: _displayText('關閉', context),
          onPressed: onClose,
          icon: const Icon(Icons.close_rounded),
        ),
      ],
    ),
  );
}

class _FullTextSearchPage extends StatefulWidget {
  const _FullTextSearchPage({required this.initialQuery});

  final String initialQuery;

  @override
  State<_FullTextSearchPage> createState() => _FullTextSearchPageState();
}

class _FullTextSearchSnapshot {
  const _FullTextSearchSnapshot({
    required this.results,
    required this.nextStart,
    required this.totalFound,
    required this.totalTermHits,
  });

  final List<ScriptureSearchResult> results;
  final int nextStart;
  final int totalFound;
  final int totalTermHits;
}

class _FullTextSearchCache {
  static final Map<String, _FullTextSearchSnapshot> _snapshots = {};
  static String? lastQuery;

  static _FullTextSearchSnapshot? get(String query) => _snapshots[query];

  static void remember(
    String query, {
    required List<ScriptureSearchResult> results,
    required int nextStart,
    required int totalFound,
    required int totalTermHits,
  }) {
    lastQuery = query;
    _snapshots[query] = _FullTextSearchSnapshot(
      results: List.unmodifiable(results),
      nextStart: nextStart,
      totalFound: totalFound,
      totalTermHits: totalTermHits,
    );
  }
}

class _FullTextSearchPageState extends State<_FullTextSearchPage> {
  late final TextEditingController controller;
  List<ScriptureSearchResult> results = const [];
  String submittedQuery = '';
  String? error;
  bool loading = false;
  bool loadingMore = false;
  bool offlineMode = false;
  int nextStart = 0;
  int totalFound = 0;
  int totalTermHits = 0;

  @override
  void initState() {
    super.initState();
    controller = TextEditingController(text: widget.initialQuery);
    if (widget.initialQuery.trim().isNotEmpty) {
      final query = SimplifiedTraditionalConverter.convert(
        widget.initialQuery.trim(),
      );
      final cached = _FullTextSearchCache.get(query);
      if (cached != null) {
        submittedQuery = query;
        results = cached.results;
        nextStart = cached.nextStart;
        totalFound = cached.totalFound;
        totalTermHits = cached.totalTermHits;
        _FullTextSearchCache.lastQuery = query;
      } else {
        WidgetsBinding.instance.addPostFrameCallback((_) => search());
      }
    }
  }

  Future<void> search() async {
    final input = controller.text.trim();
    if (input.isEmpty) return;
    final query = SimplifiedTraditionalConverter.convert(input);
    _FullTextSearchCache.lastQuery = query;
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
      submittedQuery = query;
      results = const [];
      nextStart = 0;
      totalTermHits = 0;
    });
    await _loadPage(query, 0);
  }

  Future<void> _loadPage(String query, int start) async {
    try {
      final batch = offlineMode
          ? await _searchOfflineVolumes(query, start: start)
          : await _fetchSearchBatch(query, start: start);
      if (!mounted) return;
      setState(() {
        results = [...results, ...batch.results];
        nextStart = batch.nextStart;
        totalFound = batch.totalFound;
        totalTermHits = batch.totalTermHits;
        loading = false;
        loadingMore = false;
        _FullTextSearchCache.remember(
          query,
          results: results,
          nextStart: nextStart,
          totalFound: totalFound,
          totalTermHits: totalTermHits,
        );
      });
    } catch (exception) {
      if (!mounted) return;
      if (!offlineMode && _isNetworkFailure(exception)) {
        final batch = await _searchOfflineVolumes(query, start: start);
        if (!mounted) return;
        setState(() {
          offlineMode = true;
          results = [...results, ...batch.results];
          nextStart = batch.nextStart;
          totalFound = batch.totalFound;
          totalTermHits = batch.totalTermHits;
          loading = false;
          loadingMore = false;
          _FullTextSearchCache.remember(
            query,
            results: results,
            nextStart: nextStart,
            totalFound: totalFound,
            totalTermHits: totalTermHits,
          );
        });
        return;
      }
      setState(() {
        error = '全文搜尋失敗：$exception';
        loading = false;
        loadingMore = false;
      });
    }
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
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: scriptureDisplaySettings.backgroundColor,
    appBar: AppBar(
      title: const Text('全文搜尋'),
      backgroundColor: scriptureDisplaySettings.surfaceColor,
      actions: const [_ScriptDisplayButton(), _SettingsButton()],
    ),
    body: Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: controller,
                  textInputAction: TextInputAction.search,
                  onSubmitted: (_) => search(),
                  decoration: InputDecoration(
                    hintText: _displayText('輸入關鍵字搜尋經文…', context),
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              IconButton.filled(
                tooltip: _displayText('搜尋', context),
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
                    ? '「$submittedQuery」離線模式，本地找到 $totalFound 筆'
                    : '「$submittedQuery」找到 $totalFound 筆',
              ),
            ),
          ),
        Expanded(
          child: loading && results.isEmpty
              ? const Center(child: CircularProgressIndicator())
              : error != null
              ? _NoResults(message: error!)
              : results.isEmpty
              ? const _SearchPrompt()
              : ListView(
                  children: [
                    for (final result in results)
                      _SearchResultCard(
                        result: result,
                        query: submittedQuery,
                        onPassageTap: _openPassage,
                      ),
                    if (nextStart < totalFound)
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

const _cbssRetrieveBase = 'https://cbss.dila.edu.tw/rag/retrieve/';
const _cbssLlmUrl = 'https://cbetaonline.dila.edu.tw/cbss/llmStream.php';

class _AiChunk {
  const _AiChunk({
    required this.chunkId,
    required this.work,
    required this.linehead,
    required this.text,
    required this.title,
    required this.byline,
    required this.category,
    required this.juan,
    required this.score,
  });

  final String chunkId;
  final String work;
  final String linehead;
  final String text;
  final String title;
  final String byline;
  final String category;
  final int? juan;
  final double score;

  factory _AiChunk.fromJson(Map<String, dynamic> json) => _AiChunk(
    chunkId: '${json['chunk_id'] ?? ''}',
    work: '${json['work'] ?? ''}',
    linehead: '${json['linehead'] ?? ''}',
    text: '${json['text'] ?? ''}',
    title: '${json['title'] ?? ''}',
    byline: '${json['byline'] ?? ''}',
    category: '${json['category'] ?? ''}',
    juan: json['juan'] is num
        ? (json['juan'] as num).toInt()
        : int.tryParse('${json['juan']}'),
    score:
        (json['score'] as num?)?.toDouble() ??
        (json['vector_similarity'] as num?)?.toDouble() ??
        0,
  );

  Map<String, Object?> toLlmJson() => {
    'chunk_id': chunkId,
    'work': work,
    'linehead': linehead,
    'text': text,
    'title': title,
    'juan': juan,
    'score': score,
  };

  ScripturePassage toPassage() => ScripturePassage(
    title: title.isEmpty ? work : title,
    reference: juan == null ? '' : '卷 $juan',
    text: '',
    linehead: linehead.isEmpty ? null : linehead,
    juan: juan?.toString(),
    work: work,
  );
}

class _AiSearchPage extends StatefulWidget {
  const _AiSearchPage({required this.initialQuery});

  final String initialQuery;

  @override
  State<_AiSearchPage> createState() => _AiSearchPageState();
}

class _AiSearchPageState extends State<_AiSearchPage> {
  late final TextEditingController controller;
  final ScrollController scrollController = ScrollController();
  final StringBuffer _jsonBuffer = StringBuffer();
  final List<_AiChunk> chunks = [];
  final List<String> relatedQuestions = [];
  String submittedQuery = '';
  String answer = '';
  String? error;
  bool retrieving = false;
  bool generating = false;
  int _requestToken = 0;
  http.Client? _client;

  @override
  void initState() {
    super.initState();
    controller = TextEditingController(text: widget.initialQuery);
    if (widget.initialQuery.trim().isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) => search());
    }
  }

  @override
  void dispose() {
    _requestToken++;
    _client?.close();
    controller.dispose();
    scrollController.dispose();
    super.dispose();
  }

  Future<void> search([String? value]) async {
    final input = (value ?? controller.text).trim();
    if (input.isEmpty) return;
    controller.text = input;
    FocusScope.of(context).unfocus();
    final token = ++_requestToken;
    _jsonBuffer.clear();
    setState(() {
      submittedQuery = SimplifiedTraditionalConverter.convert(input);
      chunks.clear();
      relatedQuestions.clear();
      answer = '';
      error = null;
      retrieving = true;
      generating = false;
    });
    if (kIsWeb) {
      setState(() {
        retrieving = false;
        error = 'AI 語意搜尋未開放網頁跨域存取；請使用桌面或行動版 App。';
      });
      return;
    }
    try {
      await _retrieve(token);
      if (!mounted || token != _requestToken) return;
      chunks.sort((a, b) => b.score.compareTo(a.score));
      await _generate(token);
    } catch (exception) {
      if (!mounted || token != _requestToken) return;
      setState(() {
        error = 'AI 語意搜尋失敗：$exception';
        retrieving = false;
        generating = false;
      });
    }
  }

  Future<void> _retrieve(int token) async {
    final uri = Uri.parse(_cbssRetrieveBase).replace(
      queryParameters: {
        'q': submittedQuery,
        'stream': '1',
        'cache': '0',
        'rows': '30',
        'start': '0',
        'log_query': '0',
      },
    );
    final client = http.Client();
    _client = client;
    try {
      final response = await client
          .send(http.Request('GET', uri))
          .timeout(const Duration(seconds: 30));
      if (response.statusCode != 200) {
        throw Exception('語意檢索 API 回傳 ${response.statusCode}');
      }
      await for (final part in response.stream.transform(utf8.decoder)) {
        if (token != _requestToken) return;
        final arrived = <_AiChunk>[];
        _consumeJson(part, (obj) {
          final chunk = _AiChunk.fromJson(obj);
          if (chunk.text.isNotEmpty && chunk.linehead.isNotEmpty) {
            arrived.add(chunk);
          }
        });
        if (arrived.isEmpty) continue;
        if (!mounted || token != _requestToken) return;
        setState(() => chunks.addAll(arrived));
        if (chunks.length >= 30) break;
      }
    } finally {
      client.close();
      if (identical(_client, client)) _client = null;
      if (mounted && token == _requestToken) {
        setState(() => retrieving = false);
      }
    }
  }

  Future<void> _generate(int token) async {
    if (chunks.isEmpty) return;
    setState(() => generating = true);
    final client = http.Client();
    _client = client;
    final answerBuffer = StringBuffer();
    final relatedBuffer = StringBuffer();
    final tagStack = <String>[];
    var inRelated = false;
    try {
      final request = http.Request('POST', Uri.parse(_cbssLlmUrl))
        ..headers['Content-Type'] = 'application/json'
        ..body = jsonEncode({
          'query': submittedQuery,
          'chunks': [for (final chunk in chunks.take(20)) chunk.toLlmJson()],
          'lang': 'zh-hant-tw',
        });
      final response = await client.send(request);
      if (response.statusCode != 200) {
        throw Exception('AI 生成 API 回傳 ${response.statusCode}');
      }
      await for (final part in response.stream.transform(utf8.decoder)) {
        if (token != _requestToken) return;
        _consumeJson(part, (obj) {
          switch (obj['t']) {
            case 'start':
              final tag = '${obj['tag']}';
              tagStack.add(tag);
              if (tag == 'blockquote') {
                inRelated = true;
              } else if (tag == 'p') {
                (inRelated ? relatedBuffer : answerBuffer).write('\n');
              }
            case 'end':
              if (tagStack.isNotEmpty) tagStack.removeLast();
            case 'text':
              // 引用錨點 (<a rel="noopener noreferrer">) 會挾帶一個多餘的
              // 佔位文字 ("r")，官方網頁會把整個錨點刪除或改寫成引用編號，
              // 因此這裡直接略過錨點內的文字，避免露出雜訊。
              if (tagStack.contains('a')) break;
              final data = obj['data'];
              if (data is String && data.isNotEmpty) {
                (inRelated ? relatedBuffer : answerBuffer).write(data);
              }
          }
        });
        if (!mounted || token != _requestToken) return;
        setState(() => answer = answerBuffer.toString().trim());
      }
      if (!mounted || token != _requestToken) return;
      setState(() {
        answer = answerBuffer.toString().trim();
        relatedQuestions
          ..clear()
          ..addAll(
            relatedBuffer
                .toString()
                .split('\n')
                .map((line) => line.trim())
                .where((line) => line.isNotEmpty),
          );
        generating = false;
      });
    } finally {
      client.close();
      if (identical(_client, client)) _client = null;
      if (mounted && token == _requestToken && generating) {
        setState(() => generating = false);
      }
    }
  }

  void _consumeJson(
    String chunk,
    void Function(Map<String, dynamic> object) handler,
  ) {
    _jsonBuffer.write(chunk);
    final text = _jsonBuffer.toString();
    var searchFrom = 0;
    var consumed = 0;
    while (true) {
      final start = text.indexOf('{', searchFrom);
      if (start < 0) break;
      var depth = 0;
      var inString = false;
      var escaped = false;
      var end = -1;
      for (var i = start; i < text.length; i++) {
        final code = text.codeUnitAt(i);
        if (inString) {
          if (escaped) {
            escaped = false;
          } else if (code == 0x5C) {
            escaped = true;
          } else if (code == 0x22) {
            inString = false;
          }
        } else if (code == 0x22) {
          inString = true;
        } else if (code == 0x7B) {
          depth++;
        } else if (code == 0x7D) {
          depth--;
          if (depth == 0) {
            end = i;
            break;
          }
        }
      }
      if (end < 0) {
        consumed = start;
        break;
      }
      try {
        final decoded = jsonDecode(text.substring(start, end + 1));
        if (decoded is Map<String, dynamic>) handler(decoded);
      } catch (_) {
        // Ignore incomplete or malformed fragments and keep reading.
      }
      searchFrom = end + 1;
      consumed = end + 1;
    }
    _jsonBuffer
      ..clear()
      ..write(text.substring(consumed));
  }

  Future<void> _openChunk(_AiChunk chunk) async {
    if (chunk.linehead.isEmpty) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => ScriptureReaderPage(
          passage: chunk.toPassage(),
          query: '',
          searchHits: const [],
          initialHitIndex: 0,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final settings = scriptureDisplaySettings;
    return Scaffold(
      backgroundColor: settings.backgroundColor,
      appBar: AppBar(
        title: const Text('AI 語意搜尋'),
        backgroundColor: settings.surfaceColor,
        foregroundColor: settings.textColor,
        actions: const [_ScriptDisplayButton(), _SettingsButton()],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: controller,
                    textInputAction: TextInputAction.search,
                    onSubmitted: (_) => search(),
                    decoration: InputDecoration(
                      hintText: _displayText('輸入問題，AI 會理解語意並整理相關經文…', context),
                      border: OutlineInputBorder(),
                      isDense: true,
                      prefixIcon: Icon(Icons.auto_awesome_rounded),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filled(
                  tooltip: _displayText('語意搜尋', context),
                  onPressed: () => search(),
                  icon: const Icon(Icons.search_rounded),
                ),
              ],
            ),
          ),
          Expanded(child: _buildBody(context)),
        ],
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (error != null) return _NoResults(message: error!);
    if (submittedQuery.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: Text('輸入問題，體驗 AI 語意搜尋', textAlign: TextAlign.center),
        ),
      );
    }
    if (retrieving && chunks.isEmpty) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text('語意檢索中…'),
          ],
        ),
      );
    }
    if (chunks.isEmpty && answer.isEmpty && !generating) {
      return const _NoResults(message: '找不到相關經文');
    }
    return ListView(
      controller: scrollController,
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
      children: [
        _buildAnswerCard(context),
        if (relatedQuestions.isNotEmpty) ...[
          const SizedBox(height: 12),
          _buildRelated(context),
        ],
        const SizedBox(height: 20),
        Row(
          children: [
            const Icon(
              Icons.menu_book_rounded,
              size: 18,
              color: Color(0xFF176B67),
            ),
            const SizedBox(width: 6),
            Text(
              '引用經文（${chunks.length}）',
              style: Theme.of(
                context,
              ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
            ),
          ],
        ),
        const SizedBox(height: 8),
        for (final chunk in chunks) _buildChunkCard(context, chunk),
      ],
    );
  }

  Widget _buildAnswerCard(BuildContext context) {
    final text = answer.isEmpty
        ? (generating ? '正在生成回答…' : '正在檢索相關經文…')
        : answer;
    return Card(
      elevation: 0,
      color: const Color(0xFFEAF3F1),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(color: Color(0xFFCBE0DC)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(
                  Icons.auto_awesome_rounded,
                  size: 18,
                  color: Color(0xFF176B67),
                ),
                const SizedBox(width: 6),
                Text(
                  'AI 回答',
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: const Color(0xFF145D54),
                  ),
                ),
                const Spacer(),
                if (generating)
                  const SizedBox.square(
                    dimension: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
              ],
            ),
            const SizedBox(height: 10),
            _DisplaySelectableText(
              text,
              style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                height: 1.8,
                color: const Color(0xFF1F2E2B),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRelated(BuildContext context) => Card(
    elevation: 0,
    color: scriptureDisplaySettings.surfaceColor,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(12),
      side: const BorderSide(color: Color(0xFFE0D6C2)),
    ),
    child: Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.help_outline_rounded, size: 18),
              const SizedBox(width: 6),
              Text(
                '相關問題',
                style: Theme.of(
                  context,
                ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
              ),
            ],
          ),
          for (final question in relatedQuestions)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () => search(question),
                icon: const Icon(Icons.search_rounded, size: 16),
                label: Text(question, textAlign: TextAlign.left),
              ),
            ),
        ],
      ),
    ),
  );

  Widget _buildChunkCard(BuildContext context, _AiChunk chunk) {
    final details = [
      if (chunk.title.isNotEmpty) chunk.title,
      if (chunk.byline.isNotEmpty) chunk.byline,
      if (chunk.category.isNotEmpty) chunk.category,
      if (chunk.juan != null) '卷 ${chunk.juan}',
    ].join(' · ');
    return Card(
      elevation: 0,
      color: scriptureDisplaySettings.surfaceColor,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(color: Color(0xFFE0D6C2)),
      ),
      child: InkWell(
        onTap: () => _openChunk(chunk),
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                chunk.title.isEmpty ? chunk.work : chunk.title,
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  color: const Color(0xFF176B67),
                  fontWeight: FontWeight.w700,
                ),
              ),
              if (details.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(
                  details,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: const Color(0xFF78847F),
                  ),
                ),
              ],
              const SizedBox(height: 8),
              Text(
                chunk.text,
                maxLines: 4,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(
                  context,
                ).textTheme.bodyMedium?.copyWith(height: 1.7),
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      chunk.linehead,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: const Color(0xFF78847F),
                      ),
                    ),
                  ),
                  const Icon(
                    Icons.chevron_right_rounded,
                    color: Color(0xFF78847F),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _WorkPickerPage extends StatefulWidget {
  const _WorkPickerPage();
  @override
  State<_WorkPickerPage> createState() => _WorkPickerPageState();
}

class _WorkPickerResponseCache {
  static final Map<String, Future<Map<String, dynamic>>> json = {};
  static final Map<String, Future<String>> text = {};
}

Future<Map<String, dynamic>> _cachedPickerJson(
  Uri uri,
  String serviceName,
) async {
  final key = uri.toString();
  final future = _WorkPickerResponseCache.json.putIfAbsent(key, () async {
    final response = await http.get(uri).timeout(const Duration(seconds: 20));
    if (response.statusCode != 200) {
      throw Exception('$serviceName 回傳 ${response.statusCode}');
    }
    return jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
  });
  try {
    return await future;
  } catch (_) {
    if (identical(_WorkPickerResponseCache.json[key], future)) {
      _WorkPickerResponseCache.json.remove(key);
    }
    rethrow;
  }
}

Future<String> _cachedPickerText(Uri uri, String serviceName) async {
  final key = uri.toString();
  final future = _WorkPickerResponseCache.text.putIfAbsent(key, () async {
    final response = await http.get(uri).timeout(const Duration(seconds: 20));
    if (response.statusCode != 200) {
      throw Exception('$serviceName 回傳 ${response.statusCode}');
    }
    return utf8.decode(response.bodyBytes);
  });
  try {
    return await future;
  } catch (_) {
    if (identical(_WorkPickerResponseCache.text[key], future)) {
      _WorkPickerResponseCache.text.remove(key);
    }
    rethrow;
  }
}

class _WorkPickerPageState extends State<_WorkPickerPage> {
  static const _tabs = ['部類', '冊別', '作譯者', '年代', '經目查詢', 'Goto 查詢'];

  final Map<int, List<({String q, String label})>> catalogLevels = {
    0: [],
    1: [],
  };
  final Map<int, List<Map<String, dynamic>>> catalogEntries = {0: [], 1: []};
  final TextEditingController creatorController = TextEditingController();
  final TextEditingController tocController = TextEditingController();
  final TextEditingController gotoController = TextEditingController();
  List<MapEntry<String, Map<String, dynamic>>> creators = [];
  List<Map<String, dynamic>> dynasties = [];
  List<Map<String, dynamic>> listedWorks = [];
  int selectedTab = 0;
  int activeCatalogTab = 0;
  bool loading = false;
  bool loadingCreators = false;
  bool loadingDynasties = false;
  bool showingWorks = false;
  String? error;
  String? resultMessage;

  @override
  void initState() {
    super.initState();
    _loadCatalog(0, 'CBETA');
  }

  Future<Map<String, dynamic>> _getJson(
    String path, [
    Map<String, String> parameters = const {},
  ]) => _cachedPickerJson(
    Uri.https('cbdata.dila.edu.tw', '/stable/$path', parameters),
    'CBETA API',
  );

  Future<String> _getText(String path) =>
      _cachedPickerText(Uri.https('cbdata.dila.edu.tw', path), 'CBETA 下載');

  Future<void> _loadCatalog(
    int tab,
    String query, {
    int? breadcrumbIndex,
  }) async {
    activeCatalogTab = tab;
    setState(() {
      loading = true;
      error = null;
      showingWorks = false;
    });
    try {
      final payload = await _getJson('catalog_entry', {'q': query});
      final nextEntries = (payload['results'] as List<dynamic>? ?? const [])
          .whereType<Map<String, dynamic>>()
          .toList();
      if (!mounted) return;
      setState(() {
        catalogEntries[tab] = nextEntries;
        loading = false;
        final levels = catalogLevels[tab]!;
        if (breadcrumbIndex != null) {
          levels.removeRange(breadcrumbIndex + 1, levels.length);
        }
        if (levels.isEmpty || levels.last.q != query) {
          levels.add((q: query, label: '${payload['label'] ?? query}'));
        } else {
          levels[levels.length - 1] = (
            q: query,
            label: '${payload['label'] ?? query}',
          );
        }
      });
    } catch (exception) {
      if (!mounted) return;
      setState(() {
        error = '載入作品目錄失敗：$exception';
        loading = false;
      });
    }
  }

  Future<void> _selectTab(int tab) async {
    setState(() {
      selectedTab = tab;
      error = null;
      resultMessage = null;
      showingWorks = false;
    });
    if (tab == 0 && catalogLevels[0]!.isEmpty) {
      await _loadCatalog(0, 'CBETA');
    } else if (tab == 1 && catalogLevels[1]!.isEmpty) {
      await _loadCatalog(1, 'orig');
    } else if (tab == 2 && creators.isEmpty) {
      await _loadCreators();
    } else if (tab == 3 && dynasties.isEmpty) {
      await _loadDynasties();
    }
  }

  Future<void> _loadCreators() async {
    setState(() {
      loadingCreators = true;
      error = null;
    });
    try {
      await _ensureCreatorCollator();
      final payload = await _getJson('download/all-creators-with-alias.json');
      if (!mounted) return;
      setState(() {
        creators = payload.entries
            .whereType<MapEntry<String, dynamic>>()
            .where((entry) => entry.value is Map<String, dynamic>)
            .map(
              (entry) =>
                  MapEntry(entry.key, entry.value as Map<String, dynamic>),
            )
            .toList();
        loadingCreators = false;
      });
    } catch (exception) {
      if (!mounted) return;
      setState(() {
        error = '載入作譯者失敗：$exception';
        loadingCreators = false;
      });
    }
  }

  Future<void> _loadDynasties() async {
    setState(() {
      loadingDynasties = true;
      error = null;
    });
    try {
      final csv = await _getText('/stable/download/stat/dynasty-all.csv');
      final rows = const LineSplitter()
          .convert(csv)
          .skip(1)
          .where((line) => line.isNotEmpty)
          .map((line) => line.split(','))
          .where((cells) => cells.length >= 4)
          .map(
            (cells) => {
              'name': cells[0],
              'start': cells[1],
              'end': cells[2],
              'count': cells[3],
            },
          )
          .toList();
      if (!mounted) return;
      setState(() {
        dynasties = rows;
        loadingDynasties = false;
      });
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
    setState(() {
      loading = true;
      error = null;
      resultMessage = null;
      showingWorks = true;
    });
    try {
      final payload = await _getJson('works', parameters);
      final results = (payload['results'] as List<dynamic>? ?? const [])
          .whereType<Map<String, dynamic>>()
          .toList();
      if (!mounted) return;
      setState(() {
        listedWorks = results;
        resultMessage =
            '$description：${payload['num_found'] ?? results.length} 部作品';
        loading = false;
      });
    } catch (exception) {
      if (!mounted) return;
      setState(() {
        error = '查詢作品失敗：$exception';
        loading = false;
      });
    }
  }

  Future<void> _searchToc() async {
    final input = tocController.text.trim();
    if (input.isEmpty) return;
    final query = SimplifiedTraditionalConverter.convert(input);
    setState(() {
      loading = true;
      error = null;
      resultMessage = null;
    });
    try {
      final payload = await _getJson('search/toc', {'q': query});
      final results = (payload['results'] as List<dynamic>? ?? const [])
          .whereType<Map<String, dynamic>>()
          .where((result) => result['type'] == 'work')
          .toList();
      if (!mounted) return;
      setState(() {
        listedWorks = results;
        showingWorks = true;
        resultMessage = '找到 ${payload['num_found'] ?? results.length} 筆經目';
        loading = false;
      });
    } catch (exception) {
      if (!mounted) return;
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
      final payload = await _getJson('works/toc', {'work': work});
      final result = (payload['results'] as List<dynamic>? ?? const [])
          .whereType<Map<String, dynamic>>()
          .firstOrNull;
      final juans = _tocJuanEntries(result);
      if (juans.isEmpty) throw FormatException('此作品沒有可讀取的卷');
      final availableJuans =
          juans
              .map((item) => item['juan'])
              .whereType<num>()
              .map((value) => value.toInt())
              .toSet()
              .toList()
            ..sort();
      final targetJuan = targetLinehead == null
          ? null
          : int.tryParse('${item['juan'] ?? ''}');
      if (targetJuan != null && !availableJuans.contains(targetJuan)) {
        availableJuans.add(targetJuan);
        availableJuans.sort();
      }
      final selectedJuan = targetJuan == null
          ? null
          : juans.where((juan) => juan['juan'] == targetJuan).firstOrNull;
      final firstJuan = availableJuans.first;
      final selected =
          selectedJuan ??
          (targetJuan == null
              ? null
              : {
                  'file': item['file'],
                  'juan': targetJuan,
                  'lb': item['lb'] ?? targetLinehead!.split('_p').last,
                }) ??
          juans.where((juan) => juan['juan'] == firstJuan).firstOrNull ??
          juans.first;
      final file = '${selected['file'] ?? item['file'] ?? work}';
      final line = targetLinehead == null
          ? '${selected['lb'] ?? ''}'
          : targetLinehead.split('_p').last;
      final rawTitle = '${item['title'] ?? item['label'] ?? work}';
      final title = rawTitle.replaceFirst(
        RegExp('^${RegExp.escape(work)}\\s+'),
        '',
      );
      final passage = ScripturePassage(
        title: title,
        reference: '卷 ${selected['juan']}',
        text: '',
        linehead: line.isEmpty ? null : '${file}_p$line',
        juan: '${selected['juan']}',
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
    final query = creatorController.text.trim().toLowerCase();
    final groups = <String, List<MapEntry<String, Map<String, dynamic>>>>{};
    for (final entry in creators) {
      final name = '${entry.value['regular_name'] ?? ''}';
      final aliases = (entry.value['aliases_all'] as List<dynamic>? ?? const [])
          .whereType<String>()
          .toList();
      if (query.isNotEmpty &&
          ![
            name,
            ...aliases,
          ].any((value) => value.toLowerCase().contains(query))) {
        continue;
      }
      final group = _creatorStrokeGroup(name);
      groups.putIfAbsent(group, () => []).add(entry);
    }

    final groupNames = groups.keys.toList();
    final groupOrder = {
      for (var index = 0; index < groupNames.length; index++)
        groupNames[index]: index,
    };
    groupNames.sort((left, right) {
      final byStroke =
          _creatorStrokeGroupNumber(left) - _creatorStrokeGroupNumber(right);
      return byStroke != 0 ? byStroke : groupOrder[left]! - groupOrder[right]!;
    });
    final rows = <Object>[];
    for (final group in groupNames) {
      rows.add(group);
      final names = groups[group]!
        ..sort(
          (left, right) => _compareCreatorNames(
            '${left.value['regular_name'] ?? ''}',
            '${right.value['regular_name'] ?? ''}',
          ),
        );
      rows.addAll(names);
    }
    return rows;
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
    itemCount: items.length,
    itemBuilder: (context, index) {
      final item = items[index];
      final work = item['work'] is String;
      final title = '${item['title'] ?? item['label'] ?? item['name'] ?? ''}';
      final workId = item['work']?.toString();
      final label = work && workId != null && !title.startsWith('$workId ')
          ? '$workId $title'
          : title;
      final details = [
        if (!work && item['start'] != null && item['end'] != null)
          '${item['start']}–${item['end']} CE',
        if (item['vol'] != null) '${item['vol']}',
        if (item['juan'] != null) '共 ${item['juan']} 卷',
        if (item['byline'] is String) '${item['byline']}',
        if (item['count'] != null) '${item['count']} 部',
      ].join(' · ');
      return ListTile(
        leading: Icon(work ? Icons.menu_book_outlined : Icons.folder_outlined),
        title: Text(label),
        subtitle: details.isEmpty ? null : Text(details),
        trailing: const Icon(Icons.chevron_right_rounded),
        onTap: () => onTap(item),
      );
    },
  );

  Widget _buildCreatorTab() => Column(
    children: [
      Padding(
        padding: const EdgeInsets.all(12),
        child: TextField(
          controller: creatorController,
          onChanged: (_) => setState(() => showingWorks = false),
          decoration: InputDecoration(
            prefixIcon: Icon(Icons.search_rounded),
            hintText: _displayText('搜尋作譯者…', context),
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
                      if (row
                          case MapEntry<String, Map<String, dynamic>> entry) {
                        final name = '${entry.value['regular_name'] ?? ''}';
                        final aliases =
                            (entry.value['aliases_all'] as List<dynamic>? ??
                                    const [])
                                .whereType<String>()
                                .take(3)
                                .join('、');
                        return ListTile(
                          title: Text(name),
                          subtitle: aliases.isEmpty ? null : Text(aliases),
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
          showingWorks ? listedWorks : dynasties,
          onTap: (item) => showingWorks
              ? _openWork(item)
              : _loadWorks({
                  'dynasty': '${item['name']}'.replaceAll('/', ','),
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
    TextStyle? hintStyle,
  }) => Column(
    children: [
      Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: controller,
                textInputAction: TextInputAction.search,
                onSubmitted: (_) => onSearch(),
                decoration: InputDecoration(
                  hintText: _displayText(hint, context),
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
  Widget build(BuildContext context) => DefaultTabController(
    length: _tabs.length,
    initialIndex: selectedTab,
    child: Scaffold(
      backgroundColor: scriptureDisplaySettings.backgroundColor,
      appBar: AppBar(
        title: const Text('選擇佛經'),
        backgroundColor: scriptureDisplaySettings.surfaceColor,
        leading: IconButton(
          tooltip: _displayText('返回', context),
          onPressed: () {
            final levels = catalogLevels[activeCatalogTab]!;
            if ((selectedTab == 0 || selectedTab == 1) &&
                !showingWorks &&
                levels.length > 1) {
              final parentIndex = levels.length - 2;
              final parent = levels[parentIndex];
              _loadCatalog(
                activeCatalogTab,
                parent.q,
                breadcrumbIndex: parentIndex,
              );
            } else if ((selectedTab == 2 || selectedTab == 3) && showingWorks) {
              setState(() => showingWorks = false);
            } else {
              Navigator.of(context).pop();
            }
          },
          icon: const Icon(Icons.arrow_back_rounded),
        ),
      ),
      body: Column(
        children: [
          TabBar(
            isScrollable: true,
            onTap: _selectTab,
            tabs: [
              for (final tab in _tabs) Tab(text: _displayText(tab, context)),
            ],
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
              0 => _buildCatalog(0),
              1 => _buildCatalog(1),
              2 =>
                loadingCreators && creators.isEmpty
                    ? const Center(child: CircularProgressIndicator())
                    : _buildCreatorTab(),
              3 =>
                loadingDynasties && dynasties.isEmpty
                    ? const Center(child: CircularProgressIndicator())
                    : _buildDynastyTab(),
              4 => _buildSearchTab(
                controller: tocController,
                hint: '輸入經典名稱…',
                buttonText: '搜尋',
                onSearch: _searchToc,
              ),
              _ => _buildSearchTab(
                controller: gotoController,
                hint: '輸入行號或完整引文，如 CBETA 2026.R2, B22, no. 117, p. 5a1',
                buttonText: '到該行',
                onSearch: _gotoLine,
              ),
            },
          ),
        ],
      ),
    ),
  );

  @override
  void dispose() {
    creatorController.dispose();
    tocController.dispose();
    gotoController.dispose();
    super.dispose();
  }
}
