import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';

/// HEAD 探測結果。
@immutable
class MirrorProbe {
  const MirrorProbe({
    required this.reachable,
    this.size = 0,
    this.etag = '',
    this.lastModified = '',
    this.release = '',
    this.acceptsRanges = false,
    this.error,
  });

  final bool reachable;
  final int size;
  final String etag;
  final String lastModified;
  final String release;
  final bool acceptsRanges;
  final String? error;

  bool get usable => reachable && size > 0;
}

/// 上一次下載/匯入留下的本機狀態。
@immutable
class MirrorLocalState {
  const MirrorLocalState({
    this.release = '',
    this.etag = '',
    this.size = 0,
    this.downloadedAt,
    this.importedAt,
    this.importedWorks = 0,
    this.importedJuans = 0,
    this.zipPath = '',
    this.publicZipPath = '',
    this.importCompleted = false,
  });

  static const _prefsKey = 'mirror_local_state';

  final String release;
  final String etag;
  final int size;
  final DateTime? downloadedAt;
  final DateTime? importedAt;
  final int importedWorks;
  final int importedJuans;

  /// 私有目錄中的 ZIP 路徑；匯出成功後會被刪除。
  final String zipPath;

  /// 已匯出到公有 Downloads 的路徑/URI。
  final String publicZipPath;
  final bool importCompleted;

  /// 本機狀態是否對應伺服器目前這一份鏡像。
  ///
  /// 版本號兩邊都有時以版本號為準；否則退回 ETag + 大小。
  bool matchesProbe(MirrorProbe probe) {
    if (!probe.usable) return false;
    if (etag.isNotEmpty && probe.etag.isNotEmpty) {
      return etag == probe.etag &&
          (size == 0 || probe.size == 0 || size == probe.size);
    }
    if (release.isNotEmpty && probe.release.isNotEmpty) {
      return release == probe.release;
    }
    return size > 0 && size == probe.size;
  }

  bool get isUpToDate => importCompleted && importedAt != null;

  MirrorLocalState copyWith({
    String? release,
    String? etag,
    int? size,
    DateTime? downloadedAt,
    DateTime? importedAt,
    int? importedWorks,
    int? importedJuans,
    String? zipPath,
    String? publicZipPath,
    bool? importCompleted,
  }) => MirrorLocalState(
    release: release ?? this.release,
    etag: etag ?? this.etag,
    size: size ?? this.size,
    downloadedAt: downloadedAt ?? this.downloadedAt,
    importedAt: importedAt ?? this.importedAt,
    importedWorks: importedWorks ?? this.importedWorks,
    importedJuans: importedJuans ?? this.importedJuans,
    zipPath: zipPath ?? this.zipPath,
    publicZipPath: publicZipPath ?? this.publicZipPath,
    importCompleted: importCompleted ?? this.importCompleted,
  );

  Map<String, Object?> toJson() => {
    'release': release,
    'etag': etag,
    'size': size,
    'downloadedAt': downloadedAt?.toIso8601String(),
    'importedAt': importedAt?.toIso8601String(),
    'importedWorks': importedWorks,
    'importedJuans': importedJuans,
    'zipPath': zipPath,
    'publicZipPath': publicZipPath,
    'importCompleted': importCompleted,
  };

  factory MirrorLocalState.fromJson(Map<String, dynamic> json) =>
      MirrorLocalState(
        release: json['release'] as String? ?? '',
        etag: json['etag'] as String? ?? '',
        size: json['size'] as int? ?? 0,
        downloadedAt: _parseDate(json['downloadedAt']),
        importedAt: _parseDate(json['importedAt']),
        importedWorks: json['importedWorks'] as int? ?? 0,
        importedJuans: json['importedJuans'] as int? ?? 0,
        zipPath: json['zipPath'] as String? ?? '',
        publicZipPath: json['publicZipPath'] as String? ?? '',
        importCompleted: json['importCompleted'] as bool? ?? false,
      );

  static DateTime? _parseDate(Object? value) =>
      value is String ? DateTime.tryParse(value) : null;

  static Future<MirrorLocalState> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefsKey);
      if (raw == null || raw.isEmpty) return const MirrorLocalState();
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        return MirrorLocalState.fromJson(decoded);
      }
    } catch (error) {
      debugPrint('讀取鏡像本機狀態失敗: $error');
    }
    return const MirrorLocalState();
  }

  Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsKey, jsonEncode(toJson()));
  }
}

enum MirrorImportPhase {
  idle,
  probing,
  downloading,
  extracting,
  indexing,
  exporting,
  completed,
  failed,
  cancelled,
}

@immutable
class MirrorImportProgress {
  const MirrorImportProgress({
    this.phase = MirrorImportPhase.idle,
    this.receivedBytes = 0,
    this.totalBytes = 0,
    this.works = 0,
    this.juans = 0,
    this.totalWorks = 0,
    this.currentWork,
    this.message,
    this.speedBytesPerSecond = 0,
  });

  final MirrorImportPhase phase;
  final int receivedBytes;
  final int totalBytes;
  final int works;
  final int juans;
  final int totalWorks;
  final String? currentWork;
  final String? message;
  final double speedBytesPerSecond;

  double get bytesFraction =>
      totalBytes <= 0 ? 0 : (receivedBytes / totalBytes).clamp(0.0, 1.0);

  bool get isActive =>
      phase == MirrorImportPhase.probing ||
      phase == MirrorImportPhase.downloading ||
      phase == MirrorImportPhase.extracting ||
      phase == MirrorImportPhase.indexing ||
      phase == MirrorImportPhase.exporting;
}

/// 格式化大檔大小（用於鏡像卡片）。
String formatMirrorBytes(int bytes) {
  if (bytes <= 0) return '0 B';
  const units = ['B', 'KB', 'MB', 'GB'];
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  return '${value.toStringAsFixed(unit == 0 ? 0 : 1)} ${units[unit]}';
}
