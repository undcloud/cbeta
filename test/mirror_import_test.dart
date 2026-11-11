import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xuefo/download/catalog_cache.dart';
import 'package:xuefo/download/download_manager.dart';
import 'package:xuefo/download/download_store.dart';
import 'package:xuefo/download/work_archive.dart';
import 'package:xuefo/mirror/mirror_models.dart';
import 'package:xuefo/scripture/cache.dart';

Uint8List buildZip(Map<String, String> files) {
  final archive = Archive();
  for (final entry in files.entries) {
    archive.add(ArchiveFile.string(entry.key, entry.value));
  }
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

String scriptureHtml(String title, String line) =>
    "<html><body><div id='body'><p class='juan'>$title</p>"
    "<p><span class='lineInfo' line='$line'></span>經文內容</p></div></body></html>";

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('MirrorLocalState', () {
    const probe = MirrorProbe(
      reachable: true,
      size: 528030605,
      etag: '528030605-1760000000',
      release: '2026.R2',
    );

    test('matches by release first, then etag and size', () {
      const byRelease = MirrorLocalState(
        release: '2026.R2',
        size: 1,
        importCompleted: true,
      );
      expect(byRelease.matchesProbe(probe), isTrue);
      expect(byRelease.isUpToDate, isFalse); // 尚未記錄 importedAt

      const byEtag = MirrorLocalState(
        etag: '528030605-1760000000',
        size: 528030605,
      );
      expect(byEtag.matchesProbe(probe), isTrue);

      const stale = MirrorLocalState(
        release: '2026.R1',
        etag: 'other',
        size: 528030605,
        importedAt: null,
      );
      expect(stale.matchesProbe(probe), isFalse);
    });

    test('json round trip keeps zip and import information', () {
      final state = MirrorLocalState(
        release: '2026.R2',
        etag: 'etag',
        size: 123,
        downloadedAt: DateTime.utc(2026, 11, 11, 8),
        importedAt: DateTime.utc(2026, 11, 11, 9),
        importedWorks: 4899,
        importedJuans: 22150,
        zipPath: '/tmp/a.zip',
        publicZipPath: 'Download/Fodian/a.zip',
        importCompleted: true,
      );
      final restored = MirrorLocalState.fromJson(state.toJson());
      expect(restored.release, '2026.R2');
      expect(restored.importedWorks, 4899);
      expect(restored.importedJuans, 22150);
      expect(restored.zipPath, '/tmp/a.zip');
      expect(restored.publicZipPath, 'Download/Fodian/a.zip');
      expect(restored.importCompleted, isTrue);
      expect(restored.importedAt, DateTime.utc(2026, 11, 11, 9));
    });

    test('formats mirror sizes', () {
      expect(formatMirrorBytes(0), '0 B');
      expect(formatMirrorBytes(528030605), '503.6 MB');
      expect(formatMirrorBytes(2 * 1024 * 1024 * 1024), '2.0 GB');
    });
  });

  test('streams an outer mirror zip and extracts a nested work', () async {
    final tempDir = await Directory.systemTemp.createTemp('mirror_zip_test');
    try {
      final inner = buildZip({
        'T0001_001.html': scriptureHtml('卷第一', '0001a01'),
        'T0001_002.html': scriptureHtml('卷第二', '0002a01'),
      });
      final outer = Archive()
        ..add(ArchiveFile.bytes('cbeta_html/T0001.html.zip', inner))
        ..add(ArchiveFile.string('cbeta_html/_run.log', 'ignored'));
      final path = '${tempDir.path}/html_full.zip';
      await File(path).writeAsBytes(ZipEncoder().encode(outer), flush: true);

      final input = InputFileStream(path);
      try {
        final archive = ZipDecoder().decodeStream(input);
        final entry = archive.files.singleWhere(
          (file) => file.name.endsWith('.html.zip'),
        );
        final base = entry.name.split('/').last;
        final work = base.substring(0, base.length - '.html.zip'.length);
        final bytes = entry.readBytes();
        expect(bytes, isNotNull);

        final volumes = extractWorkArchive(
          bytes!,
          work: work,
          filePrefix: 'T01n0001',
          version: '2026.R2',
        );
        expect(work, 'T0001');
        expect(volumes.map((volume) => volume.juan), ['1', '2']);
        expect(volumes.first.contentVersion, '2026.R2');
        expect(volumes.first.html, contains('id="T01n0001_p0001a01"'));
      } finally {
        input.closeSync();
      }
    } finally {
      if (await tempDir.exists()) await tempDir.delete(recursive: true);
    }
  });

  group('batched mirror import', () {
    late Directory tempDir;
    late DownloadStore store;
    late ScriptureVolumeStore volumeStore;
    late ScriptureVolumeStore previousVolumeStore;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('mirror_import_test');
      store = DownloadStore(directoryProvider: () async => tempDir);
      volumeStore = ScriptureVolumeStore(
        directoryProvider: () async => tempDir,
      );
      previousVolumeStore = scriptureVolumeStore;
      downloadStore = store;
      scriptureVolumeStore = volumeStore;
      CatalogCache.instance.debugReset();
      CatalogCache.instance.debugLoad(
        allWorks: const {
          'T0001': AllWorksEntry(
            work: 'T0001',
            title: '長阿含經',
            juans: ['1', '2'],
            file: 'T01n0001',
          ),
        },
      );
    });

    tearDown(() async {
      downloadStore = DownloadStore();
      scriptureVolumeStore = previousVolumeStore;
      CatalogCache.instance.debugReset();
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('only persists versions when explicitly flushed', () async {
      final manager = DownloadManager();
      final stored = await manager.importVolumes(
        'T0001',
        const [
          CachedScriptureVolume(
            work: 'T0001',
            juan: '1',
            html: '<p>卷一</p>',
            contentVersion: '2026.R2',
          ),
          CachedScriptureVolume(
            work: 'T0001',
            juan: '2',
            html: '<p>卷二</p>',
            contentVersion: '2026.R2',
          ),
        ],
        release: '2026.R2',
        persist: false,
        flushIndex: false,
      );

      expect(stored, 2);
      expect(manager.versions['T0001:1']?.release, '2026.R2');
      expect(await store.loadVersions(), isEmpty);
      expect(await volumeStore.read('T0001', '1'), isNotNull);

      await manager.flushImportProgress();

      final saved = await store.loadVersions();
      expect(saved.keys, containsAll(['T0001:1', 'T0001:2']));
      expect(saved['T0001:1']?.release, '2026.R2');
      expect(await store.loadWorkJuans(), {
        'T0001': ['1', '2'],
      });
    });
  });
}
