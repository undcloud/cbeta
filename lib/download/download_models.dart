import 'package:flutter/foundation.dart';

enum DownloadStatus { pending, downloading, completed, failed, cancelled }

@immutable
class DownloadItem {
  const DownloadItem({
    required this.work,
    required this.title,
    this.juans = const [],
    this.creators = '',
    this.category = '',
  });

  final String work;
  final String title;
  final List<String> juans;
  final String creators;
  final String category;

  int get totalJuans => juans.isEmpty ? 1 : juans.length;

  DownloadItem copyWith({List<String>? juans}) => DownloadItem(
    work: work,
    title: title,
    juans: juans ?? this.juans,
    creators: creators,
    category: category,
  );

  Map<String, Object?> toJson() => {
    'work': work,
    'title': title,
    'juans': juans,
    'creators': creators,
    'category': category,
  };

  factory DownloadItem.fromJson(Map<String, dynamic> json) => DownloadItem(
    work: json['work'] as String,
    title: json['title'] as String? ?? '',
    juans: (json['juans'] as List<dynamic>? ?? const [])
        .whereType<String>()
        .toList(),
    creators: json['creators'] as String? ?? '',
    category: json['category'] as String? ?? '',
  );
}

@immutable
class DownloadGroup {
  const DownloadGroup({
    required this.id,
    required this.label,
    required this.items,
  });

  final String id;
  final String label;
  final List<DownloadItem> items;

  int get totalJuans => items.fold(0, (sum, item) => sum + item.totalJuans);

  Map<String, Object?> toJson() => {
    'id': id,
    'label': label,
    'items': items.map((item) => item.toJson()).toList(),
  };

  factory DownloadGroup.fromJson(Map<String, dynamic> json) => DownloadGroup(
    id: json['id'] as String,
    label: json['label'] as String,
    items: (json['items'] as List<dynamic>? ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(DownloadItem.fromJson)
        .toList(),
  );
}

@immutable
class LocalVersion {
  const LocalVersion({
    required this.work,
    required this.juan,
    required this.ver,
    required this.savedAt,
    this.release,
  });

  final String work;
  final String juan;
  final String ver;

  /// 本地內容對應的修訂版號；更新時取自 changes，初次下載取自經目發佈版號。
  final String? release;
  final DateTime savedAt;

  String get key => '$work:$juan';

  LocalVersion copyWith({String? ver, String? release}) => LocalVersion(
    work: work,
    juan: juan,
    ver: ver ?? this.ver,
    release: release ?? this.release,
    savedAt: savedAt,
  );

  Map<String, Object?> toJson() => {
    'work': work,
    'juan': juan,
    'ver': ver,
    if (release != null && release!.isNotEmpty) 'release': release,
    'savedAt': savedAt.toIso8601String(),
  };

  factory LocalVersion.fromJson(Map<String, dynamic> json) => LocalVersion(
    work: json['work'] as String,
    juan: json['juan'] as String,
    ver: json['ver'] as String,
    release: json['release'] is String ? json['release'] as String : null,
    savedAt: DateTime.parse(json['savedAt'] as String),
  );
}

@immutable
class DownloadProgress {
  const DownloadProgress({
    required this.totalItems,
    required this.completedItems,
    required this.failedItems,
    required this.totalJuans,
    required this.completedJuans,
    this.currentWork,
    this.currentJuan,
  });

  final int totalItems;
  final int completedItems;
  final int failedItems;
  final int totalJuans;
  final int completedJuans;
  final String? currentWork;
  final String? currentJuan;

  double get fraction => totalJuans == 0 ? 0 : completedJuans / totalJuans;

  bool get isComplete => completedItems + failedItems >= totalItems;
}

/// 將下載速度格式化為 KB/s 或 MB/s。
String formatDownloadSpeed(double bytesPerSecond) {
  final kilobytesPerSecond = bytesPerSecond / 1024;
  if (kilobytesPerSecond >= 1024) {
    return '${(kilobytesPerSecond / 1024).toStringAsFixed(2)} MB/s';
  }
  return '${kilobytesPerSecond.toStringAsFixed(1)} KB/s';
}
