import 'dart:async';
import 'package:flutter/material.dart' as flutter_material;
import 'package:flutter/material.dart' hide Text;
import 'package:package_info_plus/package_info_plus.dart';
import '../download/download_manager.dart';
import '../settings/display_settings.dart';
import '../about/about_dialog.dart';
import '../app_update/app_update.dart';
import '../download/download_status_ui.dart';
import '../widgets/display_text.dart';

Future<void> showDisplaySettings(
  BuildContext context, {
  AppUpdateInfo? availableUpdate,
  VoidCallback? onUpdate,
  Future<AppUpdateCheckResult> Function()? onCheckUpdate,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (context) => SafeArea(
      child: FractionallySizedBox(
        heightFactor: 0.88,
        child: _DisplaySettingsPanel(
          onAbout: () => showAbout(context),
          availableUpdate: availableUpdate,
          onUpdate: onUpdate,
          onCheckUpdate: onCheckUpdate,
        ),
      ),
    ),
  );
}

Future<void> updateDisplaySetting(
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

class ScriptDisplayScope extends InheritedNotifier<ScriptureDisplaySettings> {
  const ScriptDisplayScope({
    super.key,
    required super.notifier,
    required super.child,
  });

  static void dependOn(BuildContext context) {
    context.dependOnInheritedWidgetOfExactType<ScriptDisplayScope>();
  }
}

class _DisplaySettingsPanel extends StatelessWidget {
  const _DisplaySettingsPanel({
    required this.onAbout,
    this.availableUpdate,
    this.onUpdate,
    this.onCheckUpdate,
  });

  final VoidCallback onAbout;
  final AppUpdateInfo? availableUpdate;
  final VoidCallback? onUpdate;
  final Future<AppUpdateCheckResult> Function()? onCheckUpdate;

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
                    tooltip: displayText('關閉', context),
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
                    onChanged: (value) => updateDisplaySetting(
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
                    onChanged: (value) => updateDisplaySetting(
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
                    onChanged: (value) => updateDisplaySetting(
                      context,
                      () => settings.update(showCollation: value),
                    ),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('顯示首行'),
                    value: settings.showLineBeginnings,
                    onChanged: (value) => updateDisplaySetting(
                      context,
                      () => settings.update(showLineBeginnings: value),
                    ),
                  ),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(displayText('離線資料管理', context)),
                    subtitle: AnimatedBuilder(
                      animation: downloadManager,
                      builder: (context, _) {
                        final count = downloadManager.versions.length;
                        return Text(
                          displayText(
                            count == 0 ? '尚未下載經文' : '已下載 $count 卷',
                            context,
                          ),
                        );
                      },
                    ),
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () => showOfflineDataManager(context),
                  ),
                  const Divider(),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('關於我們'),
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: onAbout,
                  ),
                  const Divider(),
                  Padding(
                    padding: const EdgeInsets.only(top: 16, bottom: 8),
                    child: Row(
                      children: [
                        const Expanded(child: AppVersionLabel()),
                        const SizedBox(width: 12),
                        _UpdateButton(
                          availableUpdate: availableUpdate,
                          onUpdate: onUpdate,
                          onCheckUpdate: onCheckUpdate,
                        ),
                      ],
                    ),
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

class AppVersionLabel extends StatefulWidget {
  const AppVersionLabel({super.key});

  @override
  State<AppVersionLabel> createState() => _AppVersionLabelState();
}

class _AppVersionLabelState extends State<AppVersionLabel> {
  String? _version;

  @override
  void initState() {
    super.initState();
    unawaited(_loadVersion());
  }

  Future<void> _loadVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      if (!mounted) return;
      setState(() {
        _version = info.buildNumber.isEmpty
            ? info.version
            : '${info.version}（${info.buildNumber}）';
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _version = '未知');
    }
  }

  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.centerLeft,
    child: Text(
      displayText('目前版本：${_version ?? '載入中…'}', context),
      style: Theme.of(context).textTheme.bodySmall?.copyWith(
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    ),
  );
}

/// 顯性顯示的更新入口：有新版為綠色，無新版為灰色；
/// 點擊時重新檢查並回報「已是最新版本」或檢查失敗。
class _UpdateButton extends StatefulWidget {
  const _UpdateButton({
    this.availableUpdate,
    this.onUpdate,
    this.onCheckUpdate,
  });

  final AppUpdateInfo? availableUpdate;
  final VoidCallback? onUpdate;
  final Future<AppUpdateCheckResult> Function()? onCheckUpdate;

  @override
  State<_UpdateButton> createState() => _UpdateButtonState();
}

class _UpdateButtonState extends State<_UpdateButton> {
  AppUpdateInfo? _update;
  bool _checking = false;

  @override
  void initState() {
    super.initState();
    _update = widget.availableUpdate;
  }

  Future<void> _handlePressed() async {
    if (_checking) return;
    if (_update != null) {
      widget.onUpdate?.call();
      return;
    }
    final check = widget.onCheckUpdate;
    if (check == null) {
      await _showNotice('目前已是最新版本');
      return;
    }
    setState(() => _checking = true);
    final result = await check();
    if (!mounted) return;
    setState(() {
      _checking = false;
      _update = result.info;
    });
    switch (result.status) {
      case AppUpdateCheckStatus.updateAvailable:
        if (widget.onUpdate != null) {
          widget.onUpdate!();
        } else {
          await _showNotice('發現新版本 ${result.info?.version ?? ''}');
        }
      case AppUpdateCheckStatus.upToDate:
        await _showNotice('目前已是最新版本');
      case AppUpdateCheckStatus.failed:
        await _showNotice('檢查更新失敗，請稍後再試');
    }
  }

  Future<void> _showNotice(String message) async {
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('檢查更新'),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.availableUpdate == null &&
        widget.onUpdate == null &&
        widget.onCheckUpdate == null) {
      return const SizedBox.shrink();
    }
    final theme = Theme.of(context);
    final hasUpdate = _update != null;
    final background = hasUpdate
        ? const Color(0xFF176B67)
        : theme.colorScheme.surfaceContainerHighest;
    final foreground = hasUpdate
        ? Colors.white
        : theme.colorScheme.onSurfaceVariant;
    final label = _checking
        ? '檢查中…'
        : hasUpdate
        ? '更新 ${_update!.version}'
        : '檢查更新';
    return TextButton.icon(
      onPressed: _checking ? null : _handlePressed,
      icon: Icon(
        hasUpdate ? Icons.system_update_alt_rounded : Icons.refresh_rounded,
        size: 16,
      ),
      label: Text(label),
      style: TextButton.styleFrom(
        minimumSize: const Size(0, 30),
        padding: const EdgeInsets.symmetric(horizontal: 10),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        backgroundColor: background,
        foregroundColor: foreground,
        disabledBackgroundColor: background,
        disabledForegroundColor: foreground,
        textStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
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
    onSelected: (_) => updateDisplaySetting(
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
    onSelected: (_) => updateDisplaySetting(
      context,
      () => scriptureDisplaySettings.update(backgroundTheme: value),
    ),
  );
}

class SettingsButton extends StatelessWidget {
  const SettingsButton({
    super.key,
    this.availableUpdate,
    this.onUpdate,
    this.onCheckUpdate,
  });

  final AppUpdateInfo? availableUpdate;
  final VoidCallback? onUpdate;
  final Future<AppUpdateCheckResult> Function()? onCheckUpdate;

  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: displayText('介面設定', context),
    onPressed: () => showDisplaySettings(
      context,
      availableUpdate: availableUpdate,
      onUpdate: onUpdate,
      onCheckUpdate: onCheckUpdate,
    ),
    icon: const Icon(Icons.settings_outlined),
  );
}

class ScriptDisplayButton extends StatelessWidget {
  const ScriptDisplayButton({super.key});

  @override
  Widget build(BuildContext context) {
    final settings = scriptureDisplaySettings;
    return AnimatedBuilder(
      animation: settings,
      builder: (context, _) {
        final currentIcon = switch (settings.scriptMode) {
          'traditional' => '繁',
          'simplified' => '简',
          _ => '原',
        };
        return IconButton(
          tooltip: displayText('切換簡體／繁體／原样', context),
          onPressed: () =>
              updateDisplaySetting(context, settings.cycleScriptMode),
          icon: flutter_material.Text(
            currentIcon,
            style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w700),
          ),
        );
      },
    );
  }
}
