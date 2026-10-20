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
    required this.truncated,
  });

  final String rawInput;
  final ScriptKind scriptKind;
  final List<String> candidates;
  final List<String> pinnedCandidates;
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
  static int _maxSimplifiedPhraseLength = 1;
  static int _maxTraditionalPhraseLength = 1;

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

    _simplifiedOnly = {
      for (final entry in _mapping.entries)
        if (entry.value.first != entry.key) entry.key,
    };
    _traditionalOnly = {
      for (final key in _reverseMapping.keys)
        if (!_mapping.containsKey(key)) key,
    };
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

  static ScriptKind classify(String input) {
    var hasSimplified = false;
    var hasTraditional = false;
    for (final rune in input.runes) {
      final character = String.fromCharCode(rune);
      if (_simplifiedOnly.contains(character)) hasSimplified = true;
      if (_traditionalOnly.contains(character)) hasTraditional = true;
    }
    if (hasSimplified && hasTraditional) return ScriptKind.mixed;
    if (hasSimplified) return ScriptKind.simplified;
    if (hasTraditional) return ScriptKind.traditional;
    return ScriptKind.neutral;
  }

  static bool _containsSimplifiedOnly(String text) {
    for (final rune in text.runes) {
      if (_simplifiedOnly.contains(String.fromCharCode(rune))) return true;
    }
    return false;
  }

  static bool _containsTraditionalOnly(String text) {
    for (final rune in text.runes) {
      if (_traditionalOnly.contains(String.fromCharCode(rune))) return true;
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

  static ConversionResult convertCandidates(
    String input, {
    String? historicalQuery,
  }) {
    final rawInput = input.trim();
    if (rawInput.isEmpty) {
      return const ConversionResult(
        rawInput: '',
        scriptKind: ScriptKind.neutral,
        candidates: [],
        pinnedCandidates: [],
        truncated: false,
      );
    }
    final scriptKind = classify(rawInput);
    if (scriptKind == ScriptKind.traditional ||
        scriptKind == ScriptKind.neutral) {
      return ConversionResult(
        rawInput: rawInput,
        scriptKind: scriptKind,
        candidates: [rawInput],
        pinnedCandidates: const [],
        truncated: false,
      );
    }

    final segments = _segments(
      rawInput,
      _simplifiedPhrases,
      _mapping,
      _maxSimplifiedPhraseLength,
    );
    var combinations = <String>[''];
    var truncated = false;
    for (final segment in segments) {
      final options = segment.take(_maxCandidatesPerSegment).toList();
      final next = <String>[];
      for (final prefix in combinations) {
        for (final option in options) {
          final candidate = '$prefix$option';
          if (!next.contains(candidate)) next.add(candidate);
          if (next.length >= _maxCandidates) {
            truncated = true;
            break;
          }
        }
        if (next.length >= _maxCandidates) break;
      }
      combinations = next;
      if (combinations.isEmpty) break;
    }

    final pinned = <String>[];
    if (historicalQuery != null &&
        historicalQuery.isNotEmpty &&
        historicalQuery != rawInput) {
      if (!combinations.contains(historicalQuery)) {
        combinations = [historicalQuery, ...combinations];
      }
      pinned.add(historicalQuery);
    }
    if (scriptKind == ScriptKind.mixed && combinations.length > 1) {
      if (!combinations.contains(rawInput)) {
        combinations = [rawInput, ...combinations];
      }
      if (!pinned.contains(rawInput)) pinned.add(rawInput);
    }

    final ordered = <String>[];
    for (final candidate in [...pinned, ...combinations]) {
      if (candidate.isNotEmpty && !ordered.contains(candidate)) {
        if (ordered.length >= _maxCandidates) {
          truncated = true;
          break;
        }
        ordered.add(candidate);
      }
    }

    return ConversionResult(
      rawInput: rawInput,
      scriptKind: scriptKind,
      candidates: ordered,
      pinnedCandidates: pinned,
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
    if (!_containsSimplifiedOnly(text)) return text;
    final segments = _segments(
      text,
      _simplifiedPhrases,
      _mapping,
      _maxSimplifiedPhraseLength,
    );
    final result = StringBuffer();
    for (final segment in segments) {
      result.write(segment.first);
    }
    return result.toString();
  }

  static String toSimplified(String text) {
    if (!_containsTraditionalOnly(text)) return text;
    final segments = _segments(
      text,
      _traditionalPhrases,
      _reverseMapping,
      _maxTraditionalPhraseLength,
    );
    final result = StringBuffer();
    for (final segment in segments) {
      result.write(segment.first);
    }
    return result.toString();
  }
}
