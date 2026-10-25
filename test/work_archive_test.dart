import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:xuefo/download/api_rate_limiter.dart';
import 'package:xuefo/download/catalog_cache.dart';
import 'package:xuefo/download/download_manager.dart';
import 'package:xuefo/download/download_models.dart';
import 'package:xuefo/download/download_store.dart';
import 'package:xuefo/download/work_archive.dart';
import 'package:xuefo/scripture/cache.dart';
import 'package:xuefo/scripture/parser.dart';

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

  test('normalizes lineInfo markers into parser line beginnings', () {
    const html =
        "<p><span class='lineInfo' line='0311b02'></span>文字</p>"
        '<p><span class="lineInfo" line="0311b03"></span>下一行</p>';

    final normalized = normalizeArchiveHtml(html, 'A091n1057');

    expect(
      normalized,
      contains(
        '<span class="lb" id="A091n1057_p0311b02">'
        'A091n1057_p0311b02</span>',
      ),
    );
    expect(
      normalized,
      contains(
        '<span class="lb" id="A091n1057_p0311b03">'
        'A091n1057_p0311b03</span>',
      ),
    );
    expect(normalized, isNot(contains('lineInfo')));
  });

  test('extracts html entries per juan from a work archive', () {
    final zip = buildZip({
      'T0001_001.html': scriptureHtml('卷第一', '0001a04'),
      'T0001_002.html': scriptureHtml('卷第二', '0002a01'),
      'readme.txt': 'ignored',
    });

    final volumes = extractWorkArchive(
      zip,
      work: 'T0001',
      filePrefix: 'T01n0001',
      version: 'v1',
    );

    expect(volumes, hasLength(2));
    expect(volumes.first.work, 'T0001');
    expect(volumes.first.juan, '1');
    expect(volumes.first.contentVersion, 'v1');
    expect(volumes.first.html, contains('id="T01n0001_p0001a04"'));
    expect(volumes.last.juan, '2');
  });

  test('normalized archive html is readable by the scripture parser', () {
    final zip = buildZip({
      'T0001_001.html':
          "<html><body><div id='body'><p class='juan'>卷第一</p>"
          "<p><span class='lineInfo' line='0001a04'></span>第一行"
          "<span class='lineInfo' line='0001a05'></span>第二行</p>"
          '</div></body></html>',
    });

    final volume = extractWorkArchive(
      zip,
      work: 'T0001',
      filePrefix: 'T01n0001',
    ).single;
    final lines = parseScriptureHtml(volume.html);

    expect(lines.map((line) => line.text.trim()), containsAll(['第一行', '第二行']));
    expect(
      lines.where((line) => line.linehead != null).map((line) => line.linehead),
      ['T01n0001_p0001a04', 'T01n0001_p0001a05'],
    );
  });

  test('fetches the per-work zip endpoint and reads its version', () async {
    Uri? requested;
    var receivedBytes = 0;
    final client = MockClient((request) async {
      requested = request.url;
      return http.Response.bytes(
        buildZip({'T0001_001.html': scriptureHtml('卷第一', '0001a01')}),
        200,
        headers: {'etag': '"abc123"'},
      );
    });

    final archive = await http.runWithClient(
      () => fetchWorkArchive(
        'T0001',
        filePrefix: 'T01n0001',
        onBytesReceived: (bytes) => receivedBytes += bytes,
      ),
      () => client,
    );

    expect(requested?.path, '/stable/download/html/T0001.html.zip');
    expect(receivedBytes, greaterThan(0));
    expect(archive.version, 'abc123');
    expect(archive.volumes.single.juan, '1');
    expect(archive.volumes.single.contentVersion, 'abc123');
    expect(archive.volumes.single.html, contains('id="T01n0001_p0001a01"'));
  });

  test('rejects non-200 responses', () async {
    final client = MockClient(
      (request) async => http.Response('not found', 404),
    );

    await expectLater(
      http.runWithClient(() => fetchWorkArchive('T9999'), () => client),
      throwsException,
    );
  });

  group('DownloadManager', () {
    late Directory tempDir;
    late DownloadStore store;
    late ScriptureVolumeStore volumeStore;
    late ScriptureVolumeStore previousVolumeStore;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('work_archive_test');
      store = DownloadStore(directoryProvider: () async => tempDir);
      volumeStore = ScriptureVolumeStore(
        directoryProvider: () async => tempDir,
      );
      previousVolumeStore = scriptureVolumeStore;
      downloadStore = store;
      scriptureVolumeStore = volumeStore;
      apiRateLimiter.debugReset();
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
      apiRateLimiter.debugReset();
      CatalogCache.instance.debugReset();
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('downloads one zip per work and stores every juan', () async {
      final requested = <String>[];
      final client = MockClient((request) async {
        requested.add(request.url.toString());
        return http.Response.bytes(
          buildZip({
            'T0001_001.html': scriptureHtml('卷第一', '0001a01'),
            'T0001_002.html': scriptureHtml('卷第二', '0002a01'),
          }),
          200,
          headers: {'etag': '"v1"'},
        );
      });

      await http.runWithClient(() async {
        final manager = DownloadManager();
        manager.addToQueue(const [
          DownloadGroup(
            id: 'g1',
            label: '阿含部類（1 部）',
            items: [
              DownloadItem(work: 'T0001', title: '長阿含經', juans: ['1', '2']),
            ],
          ),
        ]);

        await manager.startDownload();

        expect(manager.status, DownloadStatus.completed);
        expect(manager.downloadedJuanCount, 2);
        expect(manager.downloadedWorkCount, 1);
        expect(manager.isWorkDownloaded('T0001'), isTrue);
        expect(manager.hasQueuedItems, isFalse);

        final firstJuan = await volumeStore.read('T0001', '1');
        expect(firstJuan?.html, contains('id="T01n0001_p0001a01"'));
        final secondJuan = await volumeStore.read('T0001', '2');
        expect(secondJuan?.html, contains('id="T01n0001_p0002a01"'));
      }, () => client);

      expect(requested, [
        'https://cbdata.dila.edu.tw/stable/download/html/T0001.html.zip',
      ]);
    });
  });
}
