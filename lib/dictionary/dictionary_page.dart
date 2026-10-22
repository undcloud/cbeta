import 'package:flutter/material.dart';

import '../dictionary/fodict_service.dart';
import '../search/conversion.dart';
import '../search/search_input.dart';
import '../settings/display_settings.dart';

class DictionarySearchPage extends StatefulWidget {
  final String fodictBaseDir;

  const DictionarySearchPage({super.key, required this.fodictBaseDir});

  @override
  State<DictionarySearchPage> createState() => _DictionarySearchPageState();
}

class _DictionarySearchPageState extends State<DictionarySearchPage> {
  final _controller = TextEditingController();
  final _service = FodictService();
  List<FodictEntry> _results = [];
  List<FodictInfo> _dictionaries = [];
  bool _loading = false;
  bool _loadingDicts = true;
  String? _error;
  String? _resultMessage;
  Set<String> _selectedDicts = {};

  @override
  void initState() {
    super.initState();
    _loadDictionaries();
  }

  Future<void> _loadDictionaries() async {
    try {
      final dicts = await _service.getDictionaries(widget.fodictBaseDir);
      if (!mounted) return;
      setState(() {
        _dictionaries = dicts;
        _selectedDicts = dicts.map((d) => d.id).toSet();
        _loadingDicts = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '載入字典列表失敗：$e';
        _loadingDicts = false;
      });
    }
  }

  Future<void> _search() async {
    final query = _controller.text.trim();
    if (query.isEmpty) return;

    setState(() {
      _loading = true;
      _error = null;
      _resultMessage = null;
      _results = [];
    });

    try {
      final allResults = await _service.search(
        widget.fodictBaseDir,
        query,
        maxResults: 100,
      );

      final filtered = _selectedDicts.length == _dictionaries.length
          ? allResults
          : allResults.where((r) => _selectedDicts.contains(r.dictionaryId)).toList();

      if (!mounted) return;
      setState(() {
        _results = filtered;
        _loading = false;
        _resultMessage = '找到 ${filtered.length} 筆結果';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '查詢失敗：$e';
        _loading = false;
      });
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    String displayText(String text) {
      return scriptureDisplaySettings.showSimplifiedText
          ? SimplifiedTraditionalConverter.toSimplified(text)
          : SimplifiedTraditionalConverter.toTraditionalDisplay(text);
    }

    return DefaultTabController(
      length: 2,
      child: Scaffold(
        backgroundColor: scriptureDisplaySettings.backgroundColor,
        appBar: AppBar(
          title: Text(displayText('詞典查詢')),
          backgroundColor: scriptureDisplaySettings.surfaceColor,
          leading: IconButton(
            tooltip: displayText('返回'),
            icon: const Icon(Icons.arrow_back_rounded),
            onPressed: () => Navigator.of(context).pop(),
          ),
          bottom: TabBar(
            tabs: [
              Tab(text: displayText('查詢')),
              Tab(text: displayText('字典選擇')),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            _buildSearchTab(displayText),
            _buildDictSelectTab(displayText),
          ],
        ),
      ),
    );
  }

  Widget _buildSearchTab(String Function(String) displayText) {
    return Column(
      children: [
        if (_dictionaries.isEmpty && !_loadingDicts)
          _buildNoDictionariesMessage(displayText)
        else ...[
          Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                Expanded(
                  child: SearchInput(
                    controller: _controller,
                    onSearch: (selection) {
                      _controller.text = selection.query;
                      _search();
                    },
                    textBuilder: (text) => displayText(text),
                    displayListenable: scriptureDisplaySettings,
                    decoration: InputDecoration(
                      prefixIcon: const Icon(Icons.search_rounded),
                      hintText: displayText('輸入關鍵詞…'),
                      border: const OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: _loading || _dictionaries.isEmpty ? null : _search,
                  child: Text(displayText('搜尋')),
                ),
              ],
            ),
          ),
          if (_resultMessage != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  _resultMessage!,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            ),
          if (_loading) const LinearProgressIndicator(),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(_error!, textAlign: TextAlign.center),
            ),
          Expanded(
            child: _results.isEmpty && !_loading
                ? Center(
                    child: Text(
                      displayText('輸入關鍵詞查詢佛學詞典'),
                      style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                            color: Theme.of(context).colorScheme.onSurfaceVariant,
                          ),
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    itemCount: _results.length,
                    itemBuilder: (context, index) {
                      final entry = _results[index];
                      return _buildEntryCard(entry, displayText);
                    },
                  ),
          ),
        ],
      ],
    );
  }

  Widget _buildNoDictionariesMessage(String Function(String) displayText) {
    return Expanded(
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.folder_off_outlined,
                size: 64,
                color: Theme.of(context).colorScheme.error,
              ),
              const SizedBox(height: 16),
              Text(
                displayText('未找到字典文件'),
                style: Theme.of(context).textTheme.headlineSmall,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              Text(
                displayText('請將字典文件複製到以下目錄：'),
                style: Theme.of(context).textTheme.bodyMedium,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: SelectableText(
                  widget.fodictBaseDir,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        fontFamily: 'monospace',
                      ),
                ),
              ),
              const SizedBox(height: 16),
              Text(
                displayText('字典文件結構：'),
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: SelectableText(
                  'fodict/\n'
                  '  ├── 001.dfb-j/\n'
                  '  │   ├── fodict.dat\n'
                  '  │   ├── fodict.idx\n'
                  '  │   └── fodict.ini\n'
                  '  ├── 002.cyx-j/\n'
                  '  └── ...',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        fontFamily: 'monospace',
                      ),
                ),
              ),
              const SizedBox(height: 16),
              Text(
                displayText('可通過以下方式複製文件：\n'
                    '1. 使用 adb push 命令\n'
                    '2. 使用文件管理器複製\n'
                    '3. 從雲端下載'),
                style: Theme.of(context).textTheme.bodySmall,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              Text(
                displayText('當前目錄：${widget.fodictBaseDir}'),
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.primary,
                    ),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildEntryCard(FodictEntry entry, String Function(String) displayText) {
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: ExpansionTile(
        title: Text(
          entry.keyword,
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        subtitle: Text(
          entry.dictionaryName,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.primary,
              ),
        ),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Align(
              alignment: Alignment.centerLeft,
              child: SelectableText(
                _cleanDefinition(entry.definition),
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _cleanDefinition(String def) {
    return def
        .replaceAll(RegExp(r'^\s*（[^）]*）\s*'), '')
        .replaceAll('<SEEALSO>', '【參見】')
        .replaceAll('</SEEALSO>', '】')
        .trim();
  }

  Widget _buildDictSelectTab(String Function(String) displayText) {
    if (_loadingDicts) {
      return const Center(child: CircularProgressIndicator());
    }

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  displayText('選擇要查詢的字典（${_selectedDicts.length}/${_dictionaries.length}）'),
                  style: Theme.of(context).textTheme.titleSmall,
                ),
              ),
              TextButton(
                onPressed: () {
                  setState(() {
                    if (_selectedDicts.length == _dictionaries.length) {
                      _selectedDicts.clear();
                    } else {
                      _selectedDicts = _dictionaries.map((d) => d.id).toSet();
                    }
                  });
                },
                child: Text(
                  _selectedDicts.length == _dictionaries.length
                      ? displayText('全不選')
                      : displayText('全選'),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView.builder(
            itemCount: _dictionaries.length,
            itemBuilder: (context, index) {
              final dict = _dictionaries[index];
              final selected = _selectedDicts.contains(dict.id);
              return CheckboxListTile(
                value: selected,
                onChanged: (value) {
                  setState(() {
                    if (value == true) {
                      _selectedDicts.add(dict.id);
                    } else {
                      _selectedDicts.remove(dict.id);
                    }
                  });
                },
                title: Text(dict.name),
                subtitle: Text(
                  '${dict.id} · ${_formatSize(dict.datSize)}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                secondary: const Icon(Icons.menu_book_outlined),
                dense: true,
              );
            },
          ),
        ),
      ],
    );
  }

  String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}
