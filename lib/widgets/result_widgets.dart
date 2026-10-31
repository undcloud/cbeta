import 'package:flutter/material.dart' hide Text;
import '../scripture/models.dart';
import '../search/candidates.dart';
import '../search/history.dart';
import '../search/search_input.dart';
import '../settings/display_settings.dart';
import '../reader/reader_layout.dart';
import '../search/passage_resolver.dart';
import '../search/search_api.dart';
import 'display_text.dart';

class HomeBrand extends StatelessWidget {
  const HomeBrand({super.key, required this.onTap, this.color});

  final VoidCallback onTap;
  final Color? color;

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: onTap,
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Image.asset(
            'assets/cbetaonline.png',
            width: 28,
            height: 28,
            semanticLabel: 'CBETA',
          ),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              'CBETA 閱讀',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                color: color,
                fontWeight: FontWeight.w800,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    ),
  );
}

class SearchField extends StatelessWidget {
  const SearchField({
    super.key,
    required this.controller,
    required this.recentSearches,
    required this.onSearch,
    required this.onClear,
    required this.aiMode,
    required this.onToggleAiMode,
    this.onSelectionChanged,
    this.keyMatchCounter,
    this.countScope,
    this.anchorKey,
  });

  final List<String> recentSearches;
  final TextEditingController controller;
  final ValueChanged<SearchSelection> onSearch;
  final VoidCallback onClear;
  final bool aiMode;
  final VoidCallback onToggleAiMode;
  final ValueChanged<SearchSelection?>? onSelectionChanged;
  final KeyMatchCounter? keyMatchCounter;
  final String? countScope;
  final GlobalKey? anchorKey;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: anchorKey,
      decoration: BoxDecoration(
        color: Theme.of(context).appBarTheme.backgroundColor,
        border: Border.all(color: const Color(0xFFD8CDB8)),
        borderRadius: BorderRadius.circular(8),
        boxShadow: const [
          BoxShadow(
            color: Color(0x0A2C1810),
            blurRadius: 16,
            offset: Offset(0, 4),
          ),
        ],
      ),
      child: Row(
        children: [
          const SizedBox(width: 16),
          const Icon(Icons.search_rounded, color: Color(0xFF176B67)),
          const SizedBox(width: 12),
          Expanded(
            child: AnimatedBuilder(
              animation: scriptureDisplaySettings,
              builder: (context, _) => SearchInput(
                controller: controller,
                recentSearches: recentSearches,
                showCandidates: !aiMode,
                onSearch: onSearch,
                onSelectionChanged: onSelectionChanged,
                keyMatchCounter: keyMatchCounter,
                countScope: countScope,
                textBuilder: (text) => displayText(text, context),
                displayListenable: scriptureDisplaySettings,
                widthAnchorKey: anchorKey,
                decoration: InputDecoration(
                  hintText: displayText('請輸入關鍵字搜尋經典、經題或作譯者…', context),
                  border: InputBorder.none,
                  contentPadding: const EdgeInsets.symmetric(vertical: 18),
                ),
              ),
            ),
          ),
          ValueListenableBuilder<TextEditingValue>(
            valueListenable: controller,
            builder: (context, value, child) => value.text.isEmpty
                ? const SizedBox.shrink()
                : IconButton(
                    tooltip: displayText('清除搜尋', context),
                    onPressed: onClear,
                    icon: const Icon(Icons.close_rounded),
                  ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Tooltip(
              message: displayText(
                aiMode ? 'AI 模式：開啟（語意搜尋）' : 'AI 模式：關閉',
                context,
              ),
              child: InkWell(
                onTap: onToggleAiMode,
                borderRadius: BorderRadius.circular(20),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: aiMode
                        ? const Color(0xFF176B67)
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color: aiMode
                          ? const Color(0xFF176B67)
                          : const Color(0xFFC9BEAA),
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.auto_awesome_rounded,
                        size: 16,
                        color: aiMode ? Colors.white : const Color(0xFF176B67),
                      ),
                      const SizedBox(width: 4),
                      Text(
                        'AI',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          color: aiMode
                              ? Colors.white
                              : const Color(0xFF52615C),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(5),
            child: IconButton.filled(
              tooltip: displayText('搜尋經文', context),
              onPressed: () {
                final raw = controller.text.trim();
                onSearch(SearchSelection(rawInput: raw, query: ''));
              },
              icon: const Icon(Icons.search_rounded),
            ),
          ),
        ],
      ),
    );
  }
}

class SearchPrompt extends StatelessWidget {
  const SearchPrompt({super.key});

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.manage_search_rounded,
            size: 42,
            color: Theme.of(context).colorScheme.primary,
          ),
          const SizedBox(height: 12),
          Text(
            '搜尋經典與經文',
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(color: const Color(0xFF52615C)),
          ),
        ],
      ),
    ),
  );
}

class NoResults extends StatelessWidget {
  const NoResults({super.key, required this.message});

  final String message;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(
            Icons.search_off_rounded,
            size: 40,
            color: Color(0xFF82908C),
          ),
          const SizedBox(height: 12),
          Text(message, textAlign: TextAlign.center),
        ],
      ),
    ),
  );
}

class CatalogSearchMatch extends StatelessWidget {
  const CatalogSearchMatch({
    super.key,
    required this.result,
    required this.onTap,
  });

  final Map<String, dynamic> result;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final work = catalogResultWorkId(result);
    final title =
        '${result['title'] ?? result['label'] ?? result['name'] ?? work}';
    final label = title.startsWith('$work ') ? title : '$work $title';
    final byline = '${result['byline'] ?? result['author'] ?? ''}';
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: const Icon(Icons.menu_book_outlined, color: Color(0xFF176B67)),
        title: Text(
          label.trim(),
          style: const TextStyle(
            color: Color(0xFF176B67),
            fontWeight: FontWeight.w600,
            fontSize: 15,
          ),
        ),
        subtitle: Text(
          byline.isEmpty ? '經目匹配 · 點擊開啟' : '經目匹配 · $byline',
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(color: Color(0xFF687671), fontSize: 12),
        ),
        trailing: const Icon(
          Icons.chevron_right_rounded,
          color: Color(0xFF687671),
        ),
        onTap: onTap,
      ),
    );
  }
}

String resultWorkKey(ScriptureSearchResult result) {
  final work = result.passages.isEmpty
      ? ''
      : (result.passages.first.work ?? '');
  return work.isNotEmpty ? work : result.title;
}

/// 把同一部作品（work）跨卷的搜尋結果合併成一筆，讓結果只以作品為一級分組。
List<ScriptureSearchResult> groupResultsByWork(
  List<ScriptureSearchResult> results,
) {
  final order = <String>[];
  final titles = <String, String>{};
  final descriptions = <String, String>{};
  final passages = <String, List<ScripturePassage>>{};
  for (final result in results) {
    final key = resultWorkKey(result);
    final bucket = passages[key];
    if (bucket == null) {
      order.add(key);
      passages[key] = List.of(result.passages);
      titles[key] = result.title;
      descriptions[key] = result.description;
      continue;
    }
    // 直接追加,不要再重建整個 passages 列表（原本是 O(n²) 複製）。
    bucket.addAll(result.passages);
  }
  return [
    for (final key in order)
      ScriptureSearchResult(
        title: titles[key]!,
        description: descriptions[key]!,
        passages: passages[key]!,
      ),
  ];
}

class WorkStickyHeader extends StatefulWidget {
  const WorkStickyHeader({
    super.key,
    required this.result,
    required this.query,
    required this.onPassageTap,
    required this.workKey,
    required this.isExpanded,
    required this.onExpansionChanged,
    required this.scrollController,
  });

  final ScriptureSearchResult result;
  final String query;
  final void Function(ScripturePassage passage, List<ScripturePassage> passages)
  onPassageTap;
  final String workKey;
  final bool isExpanded;
  final ValueChanged<bool> onExpansionChanged;
  final ScrollController scrollController;

  @override
  State<WorkStickyHeader> createState() => _WorkStickyHeaderState();
}

class _WorkStickyHeaderState extends State<WorkStickyHeader>
    with AutomaticKeepAliveClientMixin {
  bool _childrenBuilt = false;
  final _headerKey = GlobalKey();

  @override
  bool get wantKeepAlive => widget.isExpanded;

  @override
  void didUpdateWidget(WorkStickyHeader oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isExpanded && !_childrenBuilt) {
      setState(() => _childrenBuilt = true);
    }
    // 当从展开变为折叠时，滚动到 header 位置
    if (oldWidget.isExpanded && !widget.isExpanded) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _scrollToHeader();
      });
    }
  }

  void _scrollToHeader() {
    final context = _headerKey.currentContext;
    if (context != null) {
      Scrollable.ensureVisible(
        context,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeInOut,
        alignment: 0.0,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);

    return SliverMainAxisGroup(
      slivers: [
        SliverPersistentHeader(
          pinned: true,
          delegate: _WorkStickyHeaderDelegate(
            headerKey: _headerKey,
            title: widget.result.title,
            description: widget.result.description,
            isExpanded: widget.isExpanded,
            onToggle: () {
              final newExpanded = !widget.isExpanded;
              widget.onExpansionChanged(newExpanded);
              if (newExpanded && !_childrenBuilt) {
                setState(() => _childrenBuilt = true);
              }
            },
          ),
        ),
        if (widget.isExpanded && _childrenBuilt)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(40, 0, 40, 8),
              child: Card(
                margin: EdgeInsets.zero,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: _buildChildren(),
                ),
              ),
            ),
          ),
      ],
    );
  }

  List<Widget> _buildChildren() {
    final groups = <String, List<ScripturePassage>>{};
    final order = <String>[];
    for (final passage in widget.result.passages) {
      final juan = passage.juan ?? '';
      if (!groups.containsKey(juan)) {
        groups[juan] = <ScripturePassage>[];
        order.add(juan);
      }
      groups[juan]!.add(passage);
    }
    return [
      for (final juan in order)
        JuanResultGroup(
          juan: juan,
          passages: groups[juan]!,
          allPassages: widget.result.passages,
          query: widget.query,
          onPassageTap: widget.onPassageTap,
        ),
    ];
  }
}

class _WorkStickyHeaderDelegate extends SliverPersistentHeaderDelegate {
  _WorkStickyHeaderDelegate({
    required this.headerKey,
    required this.title,
    required this.description,
    required this.isExpanded,
    required this.onToggle,
  });

  final GlobalKey headerKey;
  final String title;
  final String description;
  final bool isExpanded;
  final VoidCallback onToggle;

  @override
  double get minExtent => 60;

  @override
  double get maxExtent => description.isEmpty ? 60 : 80;

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) {
    final theme = Theme.of(context);
    final elevation = isExpanded && shrinkOffset > 0 ? 4.0 : 0.0;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 40),
      child: Material(
        key: headerKey,
        color: theme.cardColor,
        elevation: elevation,
        borderRadius: BorderRadius.circular(12),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onToggle,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
            child: Row(
              children: [
                Icon(
                  isExpanded
                      ? Icons.expand_less_rounded
                      : Icons.expand_more_rounded,
                  color: const Color(0xFF176B67),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        title,
                        style: const TextStyle(
                          color: Color(0xFF176B67),
                          fontWeight: FontWeight.w700,
                          fontSize: 16,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (description.isNotEmpty)
                        Text(
                          description,
                          style: const TextStyle(
                            color: Color(0xFF687671),
                            fontSize: 12,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  bool shouldRebuild(covariant _WorkStickyHeaderDelegate oldDelegate) {
    return title != oldDelegate.title ||
        description != oldDelegate.description ||
        isExpanded != oldDelegate.isExpanded;
  }
}

class JuanResultGroup extends StatefulWidget {
  const JuanResultGroup({
    super.key,
    required this.juan,
    required this.passages,
    required this.allPassages,
    required this.query,
    required this.onPassageTap,
  });

  final String juan;
  final List<ScripturePassage> passages;
  final List<ScripturePassage> allPassages;
  final String query;
  final void Function(ScripturePassage passage, List<ScripturePassage> passages)
  onPassageTap;

  @override
  State<JuanResultGroup> createState() => _JuanResultGroupState();
}

class _JuanResultGroupState extends State<JuanResultGroup> {
  /// 一部作品可能在同一卷命中數百處,一次全部建立 Paragraph 會卡住捲動,
  /// 因此命中列也走分頁增長。
  int _visiblePassages = resultSectionPageSize;

  @override
  Widget build(BuildContext context) {
    final passages = widget.passages;
    final shown = passages.take(_visiblePassages).toList();
    final remaining = passages.length - shown.length;
    return ExpansionTile(
      initiallyExpanded: true,
      tilePadding: const EdgeInsets.symmetric(horizontal: 16),
      title: Text(
        widget.juan.isEmpty ? '本卷' : widget.juan,
        style: const TextStyle(
          color: Color(0xFF3A4B46),
          fontWeight: FontWeight.w600,
          fontSize: 14,
        ),
      ),
      children: [
        for (var i = 0; i < shown.length; i++) ...[
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: PassageResultTile(
              passage: shown[i],
              query: widget.query,
              onTap: () => widget.onPassageTap(shown[i], widget.allPassages),
            ),
          ),
          if (i != shown.length - 1 || remaining > 0)
            const Divider(height: 1, indent: 16, endIndent: 16),
        ],
        if (remaining > 0)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                onPressed: () =>
                    setState(() => _visiblePassages += resultSectionPageSize),
                child: Text('顯示更多命中（剩餘 $remaining 筆）'),
              ),
            ),
          ),
      ],
    );
  }
}

class PassageResultTile extends StatelessWidget {
  const PassageResultTile({
    super.key,
    required this.passage,
    required this.query,
    required this.onTap,
  });

  final ScripturePassage passage;
  final String query;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onTap,
    borderRadius: BorderRadius.circular(8),
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (passage.reference.isNotEmpty)
            Text(
              passage.reference,
              style: const TextStyle(color: Color(0xFF687671), fontSize: 12),
            ),
          const SizedBox(height: 4),
          Text.rich(
            highlightedPassageText(passage.text, query),
            style: Theme.of(context).textTheme.bodyLarge?.copyWith(height: 1.8),
          ),
        ],
      ),
    ),
  );
}

class SearchResultCard extends StatelessWidget {
  const SearchResultCard({
    super.key,
    required this.result,
    required this.query,
    required this.onPassageTap,
  });

  final ScriptureSearchResult result;
  final String query;
  final void Function(ScripturePassage passage, List<ScripturePassage> passages)
  onPassageTap;

  @override
  Widget build(BuildContext context) => Material(
    color: Colors.transparent,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            result.title,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
              color: const Color(0xFF176B67),
              fontWeight: FontWeight.w700,
            ),
          ),
          if (result.description.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              result.description,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: const Color(0xFF78847F)),
            ),
          ],
          for (final passage in result.passages) ...[
            const SizedBox(height: 10),
            PassageResultTile(
              passage: passage,
              query: query,
              onTap: () => onPassageTap(passage, result.passages),
            ),
          ],
        ],
      ),
    ),
  );
}
