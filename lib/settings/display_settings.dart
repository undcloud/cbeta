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
