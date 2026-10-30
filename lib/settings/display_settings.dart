import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

final scriptureDisplaySettings = ScriptureDisplaySettings();

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

  /// 系统是否为深色模式；为 true 时强制使用「夜間」配色（不持久化）。
  bool platformDark = false;

  /// true 時完全不做簡繁轉換，保持文字原始樣式（字典等外部資料用）。
  bool showOriginalText = false;
  SharedPreferences? _preferences;

  /// 實際生效的背景配色：系統深色時強制「夜間」，否則使用使用者選擇。
  String get effectiveBackgroundTheme =>
      platformDark ? 'night' : backgroundTheme;

  bool get isDark => effectiveBackgroundTheme == 'night';

  Color get backgroundColor => switch (effectiveBackgroundTheme) {
    'warm' => const Color(0xFFF5E6C8),
    'green' => const Color(0xFFE3EDCD),
    'white' => const Color(0xFFFFFFFF),
    'grey' => const Color(0xFFEAEAEA),
    'night' => const Color(0xFF1A1714),
    _ => const Color(0xFFF5EFE0),
  };

  Color get textColor => effectiveBackgroundTheme == 'night'
      ? const Color(0xFFDCD0BA)
      : const Color(0xFF2C1810);

  Color get surfaceColor =>
      effectiveBackgroundTheme == 'default' ? paperSurface : backgroundColor;

  /// 更新系统深浅色状态；仅在变化时通知重建。
  void setPlatformDark(bool value) {
    if (platformDark == value) return;
    platformDark = value;
    notifyListeners();
  }

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
    showOriginalText = false;
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
    final savedOriginalText = values['showOriginalText'];
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
    if (savedOriginalText is bool) {
      showOriginalText = savedOriginalText;
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
    bool? showOriginalText,
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
    if (showOriginalText != null) {
      this.showOriginalText = showOriginalText;
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
        'showOriginalText': this.showOriginalText,
      }),
    );
    if (!saved) throw StateError('無法儲存經文顯示設定');
  }

  /// 目前簡繁顯示模式：'traditional'（繁）、'simplified'（简）、'original'（原样）。
  String get scriptMode => switch ((showOriginalText, showSimplifiedText)) {
    (true, _) => 'original',
    (false, true) => 'simplified',
    (false, false) => 'traditional',
  };

  /// 依 繁 → 简 → 原样 → 繁 循環切換顯示模式。
  Future<void> cycleScriptMode() => switch (scriptMode) {
    'traditional' => update(showOriginalText: false, showSimplifiedText: true),
    'simplified' => update(showOriginalText: true, showSimplifiedText: false),
    _ => update(showOriginalText: false, showSimplifiedText: false),
  };
}
