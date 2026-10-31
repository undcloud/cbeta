import 'dart:async';
import 'package:icu_kit/icu_kit.dart';

String creatorStrokeGroup(String name) {
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

int creatorStrokeGroupNumber(String group) =>
    int.tryParse(RegExp(r'^\d+').firstMatch(group)?.group(0) ?? '') ?? 999;

int compareCreatorNames(String left, String right) =>
    (_creatorCollator ?? (throw StateError('作譯者排序尚未初始化'))).compare(left, right);

IcuCollator? _creatorCollator;
Future<void>? _icuInitialization;

Future<void> ensureCreatorCollator() async {
  // 已初始化過就直接返回；避免重複 await 跨測試 zone 的快取 Future。
  if (_creatorCollator != null) return;
  await (_icuInitialization ??= IcuKit.init(webEngine: WebEngine.browserIntl));
  _creatorCollator ??= IcuCollator(locale: 'zh-Hant');
}
