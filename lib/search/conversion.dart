import 'dart:collection';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/services.dart' show rootBundle;

enum ScriptKind { simplified, traditional, mixed, neutral }

class ConversionResult {
  const ConversionResult({
    required this.rawInput,
    required this.scriptKind,
    required this.candidates,
    required this.pinnedCandidates,
    required this.fullSimplified,
    required this.truncated,
  });

  final String rawInput;
  final ScriptKind scriptKind;
  final List<String> candidates;

  /// 固定排在最前面的候选：原命中文字，以及原始输入（若不同）。
  final List<String> pinnedCandidates;

  /// 将输入中的繁体字全部转成简体后的结果。
  final String fullSimplified;
  final bool truncated;

  bool get requiresChoice => candidates.length > 1;
}

class SimplifiedTraditionalConverter {
  static const _maxCandidates = 50;
  static const _maxCandidatesPerSegment = 3;

  static Map<String, List<String>> _mapping = const {};
  static Map<String, List<String>> _reverseMapping = const {};
  static Map<String, List<String>> _simplifiedPhrases = const {};
  static Map<String, List<String>> _traditionalPhrases = const {};
  static Set<String> _simplifiedOnly = const {};
  static Set<String> _traditionalOnly = const {};
  static Set<int> _simplifiedOnlyCodes = const {};
  static Set<int> _traditionalOnlyCodes = const {};
  static int _maxSimplifiedPhraseLength = 1;
  static int _maxTraditionalPhraseLength = 1;

  /// 顯示轉換結果的 LRU 記憶體。整棵結果樹每次重建都會對同一段文字重跑
  /// 逐字分段轉換,沒有快取時每幀成本正比於已渲染的文字量。
  static const int _displayCacheLimit = 4096;
  static final LinkedHashMap<String, String> _toSimplifiedCache =
      LinkedHashMap<String, String>();
  static final LinkedHashMap<String, String> _toTraditionalCache =
      LinkedHashMap<String, String>();

  static String? _cachedLookup(
    LinkedHashMap<String, String> cache,
    String key,
  ) {
    final value = cache.remove(key);
    if (value == null) return null;
    cache[key] = value;
    return value;
  }

  static void _cachePut(
    LinkedHashMap<String, String> cache,
    String key,
    String value,
  ) {
    if (value == key) return;
    cache[key] = value;
    if (cache.length > _displayCacheLimit) cache.remove(cache.keys.first);
  }

  static void clearDisplayCaches() {
    _toSimplifiedCache.clear();
    _toTraditionalCache.clear();
  }

  static Future<String> _loadAssetString(String key) async {
    final data = await rootBundle.load(key);
    return utf8.decode(
      data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
    );
  }

  static Future<void> load() async {
    final dictionary =
        jsonDecode(
              await _loadAssetString(
                'assets/hanzi_simplified_to_traditional.json',
              ),
            )
            as Map<String, dynamic>;
    _mapping = dictionary.map(
      (key, value) => MapEntry(key, _candidateList(value, key)),
    );

    final reverseDictionary =
        jsonDecode(
              await _loadAssetString(
                'assets/hanzi_traditional_to_simplified.json',
              ),
            )
            as Map<String, dynamic>;
    _reverseMapping = reverseDictionary.map(
      (key, value) => MapEntry(key, _candidateList(value, key)),
    );

    final simplifiedPhrases =
        jsonDecode(
              await _loadAssetString(
                'assets/phrases_simplified_to_traditional.json',
              ),
            )
            as Map<String, dynamic>;
    _simplifiedPhrases = simplifiedPhrases.map(
      (key, value) => MapEntry(key, _candidateList(value, key)),
    );

    final traditionalPhrases =
        jsonDecode(
              await _loadAssetString(
                'assets/phrases_traditional_to_simplified.json',
              ),
            )
            as Map<String, dynamic>;
    _traditionalPhrases = traditionalPhrases.map(
      (key, value) => MapEntry(key, _candidateList(value, key)),
    );

    _maxSimplifiedPhraseLength = _maxPhraseLength(_simplifiedPhrases);
    _maxTraditionalPhraseLength = _maxPhraseLength(_traditionalPhrases);

    // 首選與原字不同者才視為「需要轉繁的簡體字」。云、后、里等首選仍是
    // 原字的共用字不會被顯示轉換，避免把「云何」誤轉成「雲何」。
    _simplifiedOnly = {
      for (final entry in _mapping.entries)
        if (entry.value.first != entry.key) entry.key,
    };
    _traditionalOnly = {
      for (final key in _reverseMapping.keys)
        if (!_mapping.containsKey(key)) key,
    };
    _simplifiedOnlyCodes = {
      for (final key in _simplifiedOnly)
        if (key.runes.length == 1) key.runes.first,
    };
    _traditionalOnlyCodes = {
      for (final key in _traditionalOnly)
        if (key.runes.length == 1) key.runes.first,
    };
    clearDisplayCaches();
  }

  static List<String> _candidateList(dynamic value, String key) {
    final candidates = <String>[];
    if (value is String) {
      if (value.isNotEmpty) candidates.add(value);
    } else if (value is List) {
      for (final item in value) {
        if (item is String && item.isNotEmpty && !candidates.contains(item)) {
          candidates.add(item);
        }
      }
    }
    if (candidates.isEmpty) candidates.add(key);
    return List.unmodifiable(candidates);
  }

  static int _maxPhraseLength(Map<String, List<String>> phrases) {
    var length = 1;
    for (final key in phrases.keys) {
      final runes = key.runes.length;
      if (runes > length) length = runes;
    }
    return length;
  }

  static bool _isSimplifiedOnlyRune(int rune) =>
      _simplifiedOnlyCodes.contains(rune) ||
      (rune > 0xFFFF && _simplifiedOnly.contains(String.fromCharCode(rune)));

  static bool _isTraditionalOnlyRune(int rune) =>
      _traditionalOnlyCodes.contains(rune) ||
      (rune > 0xFFFF && _traditionalOnly.contains(String.fromCharCode(rune)));

  static ScriptKind classify(String input) {
    var hasSimplified = false;
    var hasTraditional = false;
    for (final rune in input.runes) {
      if (hasSimplified && hasTraditional) return ScriptKind.mixed;
      if (!hasSimplified && _isSimplifiedOnlyRune(rune)) hasSimplified = true;
      if (!hasTraditional && _isTraditionalOnlyRune(rune)) {
        hasTraditional = true;
      }
    }
    if (hasSimplified && hasTraditional) return ScriptKind.mixed;
    if (hasSimplified) return ScriptKind.simplified;
    if (hasTraditional) return ScriptKind.traditional;
    return ScriptKind.neutral;
  }

  /// 候選排序用：繁體／混排視為繁體側（優先），簡體／中性視為簡體側。
  static bool ranksAsTraditional(String input) {
    final kind = classify(input);
    return kind == ScriptKind.traditional || kind == ScriptKind.mixed;
  }

  static bool _containsSimplifiedOnly(String text) {
    for (final rune in text.runes) {
      if (_isSimplifiedOnlyRune(rune)) return true;
    }
    return false;
  }

  static bool _containsTraditionalOnly(String text) {
    for (final rune in text.runes) {
      if (_isTraditionalOnlyRune(rune)) return true;
    }
    return false;
  }

  static List<List<String>> _segments(
    String input,
    Map<String, List<String>> phrases,
    Map<String, List<String>> characters,
    int maxPhraseLength,
  ) {
    final units = input.runes.map(String.fromCharCode).toList();
    final segments = <List<String>>[];
    var index = 0;
    while (index < units.length) {
      List<String>? phrase;
      var phraseLength = 0;
      final limit = math.min(maxPhraseLength, units.length - index);
      for (var length = limit; length >= 1; length--) {
        final key = units.sublist(index, index + length).join();
        final candidates = phrases[key];
        if (candidates != null) {
          phrase = candidates;
          phraseLength = length;
          break;
        }
      }
      if (phrase != null) {
        segments.add(phrase);
        index += phraseLength;
      } else {
        final character = units[index];
        segments.add(characters[character] ?? [character]);
        index++;
      }
    }
    return segments;
  }

  /// 原命中文字：簡體／混合輸入沿用原有的「簡→繁」首選；
  /// 繁體／共用字輸入則以原輸入為命中結果。
  static String _preferredText(String input, ScriptKind scriptKind) {
    if (scriptKind == ScriptKind.traditional ||
        scriptKind == ScriptKind.neutral) {
      return input;
    }
    final segments = _segments(
      input,
      _simplifiedPhrases,
      _mapping,
      _maxSimplifiedPhraseLength,
    );
    return segments.map((segment) => segment.first).join();
  }

  static List<String> _combinations(
    String input,
    Map<String, List<String>> phrases,
    Map<String, List<String>> characters,
    int maxPhraseLength,
  ) {
    final segments = _segments(input, phrases, characters, maxPhraseLength);
    var combinations = <String>[''];
    for (final segment in segments) {
      final options = segment.take(_maxCandidatesPerSegment).toList();
      final next = <String>[];
      for (final prefix in combinations) {
        for (final option in options) {
          final candidate = '$prefix$option';
          if (!next.contains(candidate)) next.add(candidate);
          if (next.length >= _maxCandidates) break;
        }
        if (next.length >= _maxCandidates) break;
      }
      combinations = next;
      if (combinations.isEmpty) break;
    }
    return combinations;
  }

  static ConversionResult convertCandidates(String input) {
    final rawInput = input.trim();
    if (rawInput.isEmpty) {
      return const ConversionResult(
        rawInput: '',
        scriptKind: ScriptKind.neutral,
        candidates: [],
        pinnedCandidates: [],
        fullSimplified: '',
        truncated: false,
      );
    }
    final scriptKind = classify(rawInput);
    final preferred = _preferredText(rawInput, scriptKind);
    final fullSimplified = toSimplifiedAll(rawInput);

    final simplifiedCombinations = _combinations(
      rawInput,
      _simplifiedPhrases,
      _mapping,
      _maxSimplifiedPhraseLength,
    );
    final traditionalCombinations = _combinations(
      rawInput,
      _traditionalPhrases,
      _reverseMapping,
      _maxTraditionalPhraseLength,
    );

    final candidates = <String>[];
    var truncated = false;
    void add(String candidate) {
      if (candidate.isEmpty || candidates.contains(candidate)) return;
      if (candidates.length >= _maxCandidates) {
        truncated = true;
        return;
      }
      candidates.add(candidate);
    }

    add(preferred);
    add(rawInput);
    add(fullSimplified);
    final orderedGroups = scriptKind == ScriptKind.traditional
        ? [traditionalCombinations, simplifiedCombinations]
        : [simplifiedCombinations, traditionalCombinations];
    for (final group in orderedGroups) {
      for (var index = 0; index < group.length; index++) {
        add(group[index]);
        if (candidates.length >= _maxCandidates && index < group.length - 1) {
          truncated = true;
          break;
        }
      }
    }

    final pinned = <String>[preferred];
    if (rawInput != preferred) pinned.add(rawInput);

    return ConversionResult(
      rawInput: rawInput,
      scriptKind: scriptKind,
      candidates: candidates,
      pinnedCandidates: pinned,
      fullSimplified: fullSimplified,
      truncated: truncated,
    );
  }

  static String convertPreferred(String input) {
    final result = convertCandidates(input);
    return result.candidates.isEmpty ? input.trim() : result.candidates.first;
  }

  /// 舊介面：回傳首選候選。
  static String convert(String text) => convertPreferred(text);

  static String toTraditionalDisplay(String text) {
    final cached = _cachedLookup(_toTraditionalCache, text);
    if (cached != null) return cached;
    final result = !_containsSimplifiedOnly(text)
        ? text
        : _joinFirstSegments(
            _segments(
              text,
              _simplifiedPhrases,
              _mapping,
              _maxSimplifiedPhraseLength,
            ),
          );
    _cachePut(_toTraditionalCache, text, result);
    return result;
  }

  static String toSimplified(String text) {
    final cached = _cachedLookup(_toSimplifiedCache, text);
    if (cached != null) return cached;
    final result = !_containsTraditionalOnly(text)
        ? text
        : toSimplifiedAll(text);
    _cachePut(_toSimplifiedCache, text, result);
    return result;
  }

  static String _joinFirstSegments(List<List<String>> segments) {
    final result = StringBuffer();
    for (final segment in segments) {
      result.write(segment.first);
    }
    return result.toString();
  }

  static String toSimplifiedAll(String text) {
    if (text.isEmpty) return text;
    return _joinFirstSegments(
      _segments(
        text,
        _traditionalPhrases,
        _reverseMapping,
        _maxTraditionalPhraseLength,
      ),
    );
  }
}
