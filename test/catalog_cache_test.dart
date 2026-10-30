import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xuefo/download/catalog_cache.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    CatalogCache.instance.debugReset();
    CatalogCache.instance.localFileLoader = null;
  });

  test('loads the four scope selector catalogs', () async {
    final cache = CatalogCache.instance;
    await cache.load();

    expect(cache.cbetaTree, isNotNull);
    expect(cache.origTree, isNotNull);
    expect(cache.cbetaTree!.children, isNotEmpty);
    expect(cache.origTree!.children, isNotEmpty);
    expect(cache.creators, isNotEmpty);
    expect(cache.dynasties, isNotEmpty);

    final allWorks = cache.allWorks;
    expect(allWorks.length, greaterThan(5000));
    final workIds = allWorks.map((work) => work.work).toSet();
    expect(workIds.length, allWorks.length);

    final categoryWorks = cache.workIdsInNode(cache.cbetaTree!);
    expect(categoryWorks.length, greaterThan(4000));
    expect(cache.cbetaTree!.workCount, categoryWorks.length);

    final volumeWorks = cache.workIdsInNode(cache.origTree!);
    expect(volumeWorks.length, categoryWorks.length);

    for (final work in allWorks) {
      expect(work.juans, isNotEmpty);
      expect(work.title, isNotEmpty);
    }
  });

  test('parses juan counts, bylines, creators, and dynasties', () async {
    final cache = CatalogCache.instance;
    await cache.load();

    final longAgama = cache.lookupWork('T0001');
    expect(longAgama, isNotNull);
    expect(longAgama!.title, '長阿含經');
    expect(longAgama.juans.length, 22);
    expect(longAgama.creators, contains('佛陀耶舍'));

    final department = cache.departmentForWork('T0001');
    expect(department, contains('阿含部類'));

    final firstCreator = cache.creators.values.first;
    expect(firstCreator.strokeGroup, '1 劃');
    expect(firstCreator.name, '一如');
    expect(firstCreator.works, isNotEmpty);
    expect(firstCreator.works.first.work, 'B0117');
    expect(firstCreator.works.first.label, startsWith('B0117 三藏法數'));
    expect(firstCreator.works.first.juan, 50);

    final firstDynasty = cache.dynasties.first;
    expect(firstDynasty.name, '東漢');
    expect(firstDynasty.start, '25');
    expect(firstDynasty.end, '220');
    expect(firstDynasty.period, '25 CE–220 CE');
    expect(firstDynasty.works, isNotEmpty);
  });

  test('searches the local catalog by work id and title only', () async {
    final cache = CatalogCache.instance;
    await cache.load();

    final byId = cache.searchWorks('T0001');
    expect(byId, isNotEmpty);
    expect(byId.first['work'], 'T0001');
    expect(byId.first['label'], contains('長阿含經'));

    final byTitle = cache.searchWorks('長阿含');
    expect(byTitle.any((item) => item['work'] == 'T0001'), isTrue);

    // 作譯者不再参与經目匹配,結果裡仍保留 byline 供顯示。
    expect(cache.searchWorks('佛陀耶舍'), isEmpty);
    expect(byTitle.first['byline'], isNotEmpty);

    expect(cache.lookupWorkFile('T0001'), 'T01n0001');
    expect(cache.lookupWorkFile('A1057'), 'A091n1057');
    expect(byId.first['file'], 'T01n0001');

    expect(cache.searchWorks('  '), isEmpty);
    expect(cache.searchWorks('T0001', limit: 1), hasLength(1));
  });

  test('prefers downloaded catalog files and picks up reloads', () async {
    final cache = CatalogCache.instance;
    final files = <String, Uint8List>{
      'category.json': _categoryJson('T0001', '長阿含經', '佛陀耶舍'),
      'vol.json': _emptyRootJson('orig'),
      'creators-by-strokes-with-works.json': _emptyRootJson('作譯者'),
      'dynasty-works.json': _emptyRootJson('朝代'),
    };
    cache.localFileLoader = (name) async => files[name];
    var notifications = 0;
    cache.addListener(() => notifications++);
    addTearDown(() => cache.localFileLoader = null);

    await cache.load();

    expect(cache.lookupWork('T0001')?.title, '長阿含經');
    expect(cache.departmentForWork('T0001'), '01 阿含部類');
    expect(cache.creators, isEmpty);

    files['category.json'] = _categoryJson('X9999', '本地下載經', '本地作者');
    await cache.reload();

    expect(notifications, 1);
    expect(cache.lookupWork('X9999')?.title, '本地下載經');
    expect(cache.lookupWork('T0001'), isNull);
    expect(cache.departmentForWork('X9999'), '01 阿含部類');
  });

  test(
    'falls back to bundled assets when downloaded files are corrupt',
    () async {
      final cache = CatalogCache.instance;
      cache.localFileLoader = (name) async => name == 'category.json'
          ? Uint8List.fromList(utf8.encode('{broken'))
          : null;
      addTearDown(() => cache.localFileLoader = null);

      await cache.load();

      expect(cache.lookupWork('T0001'), isNotNull);
      expect(cache.cbetaTree?.children, isNotEmpty);
    },
  );

  test('every catalog work resolves to metadata', () async {
    final cache = CatalogCache.instance;
    await cache.load();

    for (final node in cache.cbetaTree!.children) {
      for (final work in cache.workIdsInNode(node)) {
        expect(cache.lookupWork(work), isNotNull, reason: work);
      }
    }
    for (final creator in cache.creators.values) {
      for (final work in creator.works) {
        expect(cache.lookupWork(work.work), isNotNull, reason: work.work);
      }
    }
    for (final dynasty in cache.dynasties) {
      for (final work in dynasty.works) {
        expect(cache.lookupWork(work.work), isNotNull, reason: work.work);
      }
    }
  });
}

Uint8List _categoryJson(String work, String title, String creators) {
  final root = {
    'title': 'CBETA',
    'children': [
      {
        'title': '01 阿含部類',
        'children': [
          {'key': work, 'title': '$work $title (2 卷)【$creators】'},
        ],
      },
    ],
  };
  return Uint8List.fromList(utf8.encode(jsonEncode(root)));
}

Uint8List _emptyRootJson(String title) {
  final root = {'title': title, 'children': <Object>[]};
  return Uint8List.fromList(utf8.encode(jsonEncode(root)));
}
