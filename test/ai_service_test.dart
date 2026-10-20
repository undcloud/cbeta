import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:xuefo/ai/ai_chunk.dart';
import 'package:xuefo/ai/ai_search_service.dart';

void main() {
  test('AiChunk parses retrieval JSON', () {
    final chunk = AiChunk.fromJson({
      'chunk_id': 'c1',
      'work': 'T0001',
      'linehead': 'T01n0001_p0001a01',
      'text': '經文',
      'title': '長阿含經',
      'juan': 1,
      'vector_similarity': 0.75,
    });
    expect(chunk.chunkId, 'c1');
    expect(chunk.juan, 1);
    expect(chunk.score, 0.75);
    expect(chunk.toLlmJson()['text'], '經文');
  });

  test('JsonObjectStreamDecoder tolerates split objects', () {
    final decoder = JsonObjectStreamDecoder();
    final decoded = <Map<String, dynamic>>[];
    decoder.add('{"a":', decoded.add);
    decoder.add('1}{"b":2}', decoded.add);
    expect(decoded, [
      {'a': 1},
      {'b': 2},
    ]);
  });

  test('AiSearchService retrieves and generates', () async {
    final client = MockClient((request) async {
      if (request.url.path.contains('/rag/retrieve')) {
        return http.Response(
          '${jsonEncode({'chunk_id': 'c1', 'work': 'T0001', 'linehead': 'T01n0001_p0001a01', 'text': '經文內容', 'title': '長阿含經', 'juan': 1, 'score': 0.9})}\n',
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      if (request.url.path.contains('/cbss/llmStream.php')) {
        return http.Response(
          '${jsonEncode({'t': 'start', 'tag': 'p'})}'
          '${jsonEncode({'t': 'text', 'data': '答案'})}'
          '${jsonEncode({'t': 'end'})}'
          '${jsonEncode({'t': 'start', 'tag': 'blockquote'})}'
          '${jsonEncode({'t': 'text', 'data': '追問'})}'
          '${jsonEncode({'t': 'end'})}',
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      return http.Response('{}', 404);
    });
    final service = AiSearchService(clientFactory: () => client);
    final chunks = <AiChunk>[];
    await service.retrieve(
      '五蘊',
      onBatch: chunks.addAll,
      isCancelled: () => false,
    );
    expect(chunks, hasLength(1));

    final result = await service.generate(
      '五蘊',
      chunks,
      onAnswer: (_) {},
      isCancelled: () => false,
    );
    expect(result.answer, '答案');
    expect(result.relatedQuestions, ['追問']);
    service.cancel();
  });
}
