import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:xuefo/download/api_rate_limiter.dart';
import 'package:xuefo/download/catalog_cache.dart';
import 'package:xuefo/download/download_manager.dart';
import 'package:xuefo/download/download_models.dart';
import 'package:xuefo/download/download_store.dart';
import 'package:xuefo/main.dart';

void main() {
  setUp(() {
    apiRateLimiter.debugReset();
    resetWorkPickerResponseCache();
    CatalogCache.instance.debugReset();
    CatalogCache.instance.debugLoad(
      cbetaTree: const CatalogNode(
        label: '選擇全部',
        query: 'CBETA',
        totalWorks: 3,
        children: [
          CatalogNode(
            label: '01 阿含部類',
            query: 'CBETA/0',
            totalWorks: 2,
            works: [
              CatalogWork(
                work: 'T0001',
                label: 'T0001 長阿含經',
                title: '長阿含經',
                creators: '後秦 佛陀耶舍共竺佛念譯',
                juans: ['1', '2'],
              ),
              CatalogWork(
                work: 'T0002',
                label: 'T0002 七佛經',
                title: '七佛經',
                creators: '宋 法天譯',
                juans: ['1'],
              ),
            ],
          ),
          CatalogNode(
            label: '02 本緣部類',
            query: 'CBETA/1',
            totalWorks: 1,
            works: [
              CatalogWork(
                work: 'T0152',
                label: 'T0152 六度集經',
                title: '六度集經',
                creators: '吳 康僧會譯',
                juans: ['1'],
              ),
            ],
          ),
        ],
      ),
      origTree: const CatalogNode(label: '選擇全部', query: 'orig'),
      allWorks: {
        'T0001': const AllWorksEntry(
          work: 'T0001',
          title: '長阿含經',
          juans: ['1', '2'],
          creators: '後秦 佛陀耶舍共竺佛念譯',
        ),
        'T0002': const AllWorksEntry(
          work: 'T0002',
          title: '七佛經',
          juans: ['1'],
          creators: '宋 法天譯',
        ),
        'T0152': const AllWorksEntry(
          work: 'T0152',
          title: '六度集經',
          juans: ['1'],
          creators: '吳 康僧會譯',
        ),
      },
      workDepartments: const {
        'T0001': '01 阿含部類',
        'T0002': '01 阿含部類',
        'T0152': '02 本緣部類',
      },
    );
  });

  testWidgets('download mode selects all visible works by default', (
    WidgetTester tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    await scriptureDisplaySettings.load();

    await tester.pumpWidget(const CbetaSearchApp());
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('選擇佛經'));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('下載'));
    await tester.pumpAndSettle();
    expect(find.textContaining('已選 3 部'), findsOneWidget);
    expect(find.textContaining('本地缺少 3 部'), findsOneWidget);
    final checkboxes = tester.widgetList<Checkbox>(find.byType(Checkbox));
    expect(checkboxes, isNotEmpty);
    expect(checkboxes.every((checkbox) => checkbox.value == true), isTrue);

    await tester.tap(find.byType(Checkbox).first);
    await tester.pumpAndSettle();
    expect(find.textContaining('已選 1 部'), findsOneWidget);

    await tester.tap(find.text('01 阿含部類'));
    await tester.pumpAndSettle();
    expect(find.text('T0001 長阿含經'), findsOneWidget);
    expect(find.text('T0002 七佛經'), findsOneWidget);
    expect(find.textContaining('已選 3 部'), findsOneWidget);
  });

  testWidgets('switching picker tabs exits download selection mode', (
    WidgetTester tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    await scriptureDisplaySettings.load();

    await tester.pumpWidget(const CbetaSearchApp());
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('選擇佛經'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('下載'));
    await tester.pumpAndSettle();
    expect(find.textContaining('已選 3 部'), findsOneWidget);
    expect(find.byTooltip('取消下載模式'), findsOneWidget);

    await tester.tap(find.text('冊別'));
    await tester.pumpAndSettle();

    expect(find.textContaining('已選'), findsNothing);
    expect(find.textContaining('本地缺少'), findsNothing);
    expect(find.byTooltip('取消下載模式'), findsNothing);
    expect(find.byTooltip('下載'), findsOneWidget);
  });

  testWidgets('download panel follows script setting and clears all tasks', (
    WidgetTester tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    await SimplifiedTraditionalConverter.load();
    await scriptureDisplaySettings.load();
    await scriptureDisplaySettings.update(showSimplifiedText: true);

    final previousStore = downloadStore;
    downloadStore = _InMemoryDownloadStore();
    downloadManager.clearQueue();
    downloadManager.addToQueue(const [
      DownloadGroup(
        id: 'g1',
        label: '01 阿含部類（2 部）',
        items: [
          DownloadItem(work: 'T0001', title: '長阿含經', juans: ['1', '2']),
          DownloadItem(work: 'T0002', title: '七佛經', juans: ['1']),
        ],
      ),
    ]);
    addTearDown(() async {
      downloadManager.clearQueue();
      downloadStore = previousStore;
      await scriptureDisplaySettings.update(showSimplifiedText: false);
    });

    await tester.pumpWidget(const CbetaSearchApp());
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('选择佛经'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('下载管理'));
    await tester.pumpAndSettle();

    expect(find.text('下载管理'), findsOneWidget);
    expect(find.text('下载队列（2 部待下载）'), findsOneWidget);
    expect(find.text('01 阿含部类（2 部）'), findsOneWidget);
    expect(find.text('2 部经典 · 3 卷'), findsOneWidget);
    expect(find.byTooltip('删除所有下载任务'), findsOneWidget);

    await tester.tap(find.byTooltip('删除所有下载任务'));
    await tester.pumpAndSettle();

    expect(downloadManager.queue, isEmpty);
    expect(find.textContaining('下载队列'), findsNothing);
    expect(find.text('已清除所有下载任务'), findsWidgets);
  });

  testWidgets('download panel uses the home background color', (
    WidgetTester tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    await scriptureDisplaySettings.load();
    addTearDown(
      () => scriptureDisplaySettings.update(backgroundTheme: 'default'),
    );

    await tester.pumpWidget(const CbetaSearchApp());
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('選擇佛經'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('下載管理'));
    await tester.pumpAndSettle();

    expect(
      tester.widget<BottomSheet>(find.byType(BottomSheet)).backgroundColor,
      scriptureDisplaySettings.backgroundColor,
    );

    await tester.tap(find.text('關閉'));
    await tester.pumpAndSettle();
    await scriptureDisplaySettings.update(backgroundTheme: 'night');
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('下載管理'));
    await tester.pumpAndSettle();

    expect(
      tester.widget<BottomSheet>(find.byType(BottomSheet)).backgroundColor,
      const Color(0xFF1A1714),
    );
    expect(
      tester.widget<Scaffold>(find.byType(Scaffold).last).backgroundColor,
      const Color(0xFF1A1714),
    );
  });

  testWidgets('offline TOC search falls back to the local catalog', (
    WidgetTester tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    await scriptureDisplaySettings.load();
    await SimplifiedTraditionalConverter.load();
    final client = MockClient((request) async {
      throw const SocketException('offline');
    });

    await http.runWithClient(() async {
      await tester.pumpWidget(const CbetaSearchApp());
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('選擇佛經'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('經目查詢'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, '長阿含');
      await tester.pumpAndSettle();
      await tester.tap(find.text('搜尋'));
      await tester.pumpAndSettle();

      expect(find.text('離線模式：本地經目找到 1 部作品'), findsOneWidget);
      expect(find.text('T0001 長阿含經'), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    }, () => client);
  });
}

class _InMemoryDownloadStore implements DownloadStore {
  @override
  Future<void> saveQueue(List<DownloadGroup> groups) async {}

  @override
  Future<List<DownloadGroup>> loadQueue() async => const [];

  @override
  Future<void> clearQueue() async {}

  @override
  Future<void> saveVersions(Map<String, LocalVersion> versions) async {}

  @override
  Future<Map<String, LocalVersion>> loadVersions() async => {};

  @override
  Future<void> clearVersions() async {}
}
