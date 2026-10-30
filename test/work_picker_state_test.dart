import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xuefo/work_picker/work_picker_state.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('work picker snapshot round-trips through preferences', () async {
    const snapshot = WorkPickerSnapshot(
      tab: 3,
      scrollOffsets: {3: 128.5},
      dictionaryQuery: '般若',
      dictionaryExpandedIds: {'011.fjrwz-j'},
      dictionaryExpandedEntryKeys: {'011.fjrwz-j:般若'},
      catalogLevels: {
        0: [PickerCatalogLevel(q: 'CBETA', label: '部類目錄')],
      },
      creatorQuery: '一如',
      tocQuery: '三藏法數',
      gotoQuery: 'B22n0117_p0005a01',
      showingWorks: true,
      listedWorks: [
        {'work': 'B0117', 'title': '三藏法數'},
      ],
      resultMessage: '找到 1 筆結果',
    );

    await saveWorkPickerSnapshot(snapshot);
    final loaded = await loadWorkPickerSnapshot();

    expect(loaded, isNotNull);
    expect(loaded!.tab, 3);
    expect(loaded.scrollOffsets, {3: 128.5});
    expect(loaded.dictionaryQuery, '般若');
    expect(loaded.dictionaryExpandedIds, {'011.fjrwz-j'});
    expect(loaded.dictionaryExpandedEntryKeys, {'011.fjrwz-j:般若'});
    expect(loaded.catalogLevels[0]!.single.q, 'CBETA');
    expect(loaded.catalogLevels[0]!.single.label, '部類目錄');
    expect(loaded.creatorQuery, '一如');
    expect(loaded.tocQuery, '三藏法數');
    expect(loaded.gotoQuery, 'B22n0117_p0005a01');
    expect(loaded.showingWorks, isTrue);
    expect(loaded.listedWorks, [
      {'work': 'B0117', 'title': '三藏法數'},
    ]);
    expect(loaded.resultMessage, '找到 1 筆結果');
  });

  test('malformed work picker snapshot is ignored', () async {
    SharedPreferences.setMockInitialValues({workPickerStateKey: 'not json'});

    expect(await loadWorkPickerSnapshot(), isNull);
  });
}
