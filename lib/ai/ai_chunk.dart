class AiChunk {
  const AiChunk({
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

  factory AiChunk.fromJson(Map<String, dynamic> json) => AiChunk(
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
}
