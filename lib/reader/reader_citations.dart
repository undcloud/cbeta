import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart' hide Text;
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import '../cbeta_api_headers.dart';
import '../scripture/models.dart';
import '../common/text_patterns.dart';
import 'reader_layout.dart';
import '../widgets/display_text.dart';

Future<void> copySelectedPassage(
  BuildContext context,
  ScripturePassage passage,
  String selectedText, {
  String? selectedStartLinehead,
  String? selectedEndLinehead,
}) async {
  final fallbackLinehead =
      passage.linehead ?? firstScriptureLinehead(passage.lines);
  var endLinehead = selectedEndLinehead ?? fallbackLinehead;
  var startLinehead = selectedStartLinehead ?? fallbackLinehead;
  String? sectionTitle;
  try {
    if (selectedStartLinehead == null) {
      final lineheads = await _loadSelectionLineheads(passage, selectedText);
      startLinehead = lineheads.firstOrNull ?? startLinehead;
      endLinehead = lineheads.length > 1 ? lineheads.last : endLinehead;
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
        headers: cbetaApiHeaders,
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
    r'^([A-Z]+)\d+n(\d+[A-Z]?)',
  ).firstMatch(selectedStartLinehead ?? '');
  if (work == null || selectedStartLinehead == null) return null;
  final workId = '${work.group(1)}${work.group(2)}';
  final file = selectedStartLinehead.split('_p').first;
  final response = await http
      .get(
        Uri.https('cbdata.dila.edu.tw', '/stable/works/toc', {'work': workId}),
        headers: cbetaApiHeaders,
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
    .replaceAll(citationBrPattern, '')
    .replaceAll(htmlTagPattern, '')
    .replaceAll('&nbsp;', ' ')
    .replaceAll('&quot;', '"')
    .replaceAll('&#39;', "'")
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&amp;', '&');

String _normalizeCitationText(String text) =>
    text.replaceAll(collapseWhitespacePattern, '');

String formatSelectedPassageForCopy(
  ScripturePassage passage,
  String selectedText, {
  String? startLinehead,
  String? endLinehead,
  String? sectionTitle,
}) {
  final start = _citationLocation(
    startLinehead ?? passage.linehead ?? firstScriptureLinehead(passage.lines),
  );
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

({String volume, String number, int page, String column, int line})?
_citationLocation(String? linehead) {
  final match = citationLineheadPattern.firstMatch(linehead ?? '');
  if (match == null) return null;
  return (
    volume: match.group(1)!,
    number: match.group(2)!,
    page: int.parse(match.group(3)!),
    column: match.group(4)!,
    line: int.parse(match.group(5)!),
  );
}
