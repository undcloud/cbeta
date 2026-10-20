import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'ai_chunk.dart';

class AiGenerationResult {
  const AiGenerationResult({
    required this.answer,
    required this.relatedQuestions,
  });

  final String answer;
  final List<String> relatedQuestions;
}

/// AI 語意搜尋的網路層。
///
/// 將 HTTP、串流 JSON 解析與取消集中在此，頁面只負責 UI 狀態。
class AiSearchService {
  AiSearchService({http.Client Function()? clientFactory})
    : _clientFactory = clientFactory ?? http.Client.new;

  static const retrieveBase = 'https://cbss.dila.edu.tw/rag/retrieve/';
  static const llmUrl = 'https://cbetaonline.dila.edu.tw/cbss/llmStream.php';
  static const maxRetrievedChunks = 30;
  static const maxChunksForLlm = 20;

  final http.Client Function() _clientFactory;
  http.Client? _activeClient;

  void cancel() {
    _activeClient?.close();
    _activeClient = null;
  }

  Future<void> retrieve(
    String query, {
    required void Function(List<AiChunk> chunks) onBatch,
    required bool Function() isCancelled,
  }) async {
    final uri = Uri.parse(retrieveBase).replace(
      queryParameters: {
        'q': query,
        'stream': '1',
        'cache': '0',
        'rows': '$maxRetrievedChunks',
        'start': '0',
        'log_query': '0',
      },
    );
    final client = _clientFactory();
    _activeClient = client;
    final decoder = JsonObjectStreamDecoder();
    var received = 0;
    try {
      final response = await client
          .send(http.Request('GET', uri))
          .timeout(const Duration(seconds: 30));
      if (response.statusCode != 200) {
        throw Exception('語意檢索 API 回傳 ${response.statusCode}');
      }
      await for (final part in response.stream.transform(utf8.decoder)) {
        if (isCancelled()) return;
        final arrived = <AiChunk>[];
        decoder.add(part, (object) {
          final chunk = AiChunk.fromJson(object);
          if (chunk.text.isNotEmpty && chunk.linehead.isNotEmpty) {
            arrived.add(chunk);
          }
        });
        if (arrived.isEmpty) continue;
        if (isCancelled()) return;
        onBatch(arrived);
        received += arrived.length;
        if (received >= maxRetrievedChunks) break;
      }
    } finally {
      client.close();
      if (identical(_activeClient, client)) _activeClient = null;
    }
  }

  Future<AiGenerationResult> generate(
    String query,
    List<AiChunk> chunks, {
    required void Function(String answer) onAnswer,
    required bool Function() isCancelled,
  }) async {
    final answerBuffer = StringBuffer();
    final relatedBuffer = StringBuffer();
    final tagStack = <String>[];
    var inRelated = false;
    final client = _clientFactory();
    _activeClient = client;
    final decoder = JsonObjectStreamDecoder();
    try {
      final request = http.Request('POST', Uri.parse(llmUrl))
        ..headers['Content-Type'] = 'application/json'
        ..body = jsonEncode({
          'query': query,
          'chunks': [
            for (final chunk in chunks.take(maxChunksForLlm)) chunk.toLlmJson(),
          ],
          'lang': 'zh-hant-tw',
        });
      final response = await client.send(request);
      if (response.statusCode != 200) {
        throw Exception('AI 生成 API 回傳 ${response.statusCode}');
      }
      await for (final part in response.stream.transform(utf8.decoder)) {
        if (isCancelled()) {
          return AiGenerationResult(
            answer: answerBuffer.toString().trim(),
            relatedQuestions: _splitRelated(relatedBuffer),
          );
        }
        decoder.add(part, (object) {
          switch (object['t']) {
            case 'start':
              final tag = '${object['tag']}';
              tagStack.add(tag);
              if (tag == 'blockquote') {
                inRelated = true;
              } else if (tag == 'p') {
                (inRelated ? relatedBuffer : answerBuffer).write('\n');
              }
            case 'end':
              if (tagStack.isNotEmpty) tagStack.removeLast();
            case 'text':
              // 引用錨點會挾帶佔位文字，直接略過錨點內文字。
              if (tagStack.contains('a')) break;
              final data = object['data'];
              if (data is String && data.isNotEmpty) {
                (inRelated ? relatedBuffer : answerBuffer).write(data);
              }
          }
        });
        if (isCancelled()) {
          return AiGenerationResult(
            answer: answerBuffer.toString().trim(),
            relatedQuestions: _splitRelated(relatedBuffer),
          );
        }
        onAnswer(answerBuffer.toString().trim());
      }
      return AiGenerationResult(
        answer: answerBuffer.toString().trim(),
        relatedQuestions: _splitRelated(relatedBuffer),
      );
    } finally {
      client.close();
      if (identical(_activeClient, client)) _activeClient = null;
    }
  }

  List<String> _splitRelated(StringBuffer buffer) => buffer
      .toString()
      .split('\n')
      .map((line) => line.trim())
      .where((line) => line.isNotEmpty)
      .toList();
}

/// 解析串流中的 JSON 物件，容忍跨 chunk 的不完整資料。
class JsonObjectStreamDecoder {
  final StringBuffer _buffer = StringBuffer();

  void add(String chunk, void Function(Map<String, dynamic> object) handler) {
    _buffer.write(chunk);
    final text = _buffer.toString();
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
        // 忽略不完整或格式錯誤的片段，繼續讀取下一個物件。
      }
      searchFrom = end + 1;
      consumed = end + 1;
    }
    _buffer
      ..clear()
      ..write(text.substring(consumed));
  }
}
