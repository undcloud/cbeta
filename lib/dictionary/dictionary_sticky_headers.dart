import 'package:flutter/material.dart' hide Text;
import '../dictionary/fodict_service.dart';
import '../common/text_patterns.dart';
import '../widgets/display_text.dart';

String cleanFodictDefinition(String definition) {
  return definition
      .replaceAll(leadingParentheticalPattern, '')
      .replaceAll('<SEEALSO>', '【參見】')
      .replaceAll('</SEEALSO>', '】')
      .trim();
}

String fodictDefinitionSnippet(String definition, {int maxLength = 80}) {
  final compact = cleanFodictDefinition(
    definition,
  ).replaceAll(collapseWhitespacePattern, ' ');
  final runes = compact.runes.toList();
  if (runes.length <= maxLength) return compact;
  return '${String.fromCharCodes(runes.take(maxLength))}…';
}

class DictionaryStickyHeader extends StatefulWidget {
  const DictionaryStickyHeader({
    super.key,
    required this.dictId,
    required this.entries,
    required this.dictName,
    required this.isExpanded,
    required this.onExpansionChanged,
    required this.buildEntryTile,
    required this.context,
  });

  final String dictId;
  final List<FodictEntry> entries;
  final String dictName;
  final bool isExpanded;
  final ValueChanged<bool> onExpansionChanged;
  final Widget Function(FodictEntry) buildEntryTile;
  final BuildContext context;

  @override
  State<DictionaryStickyHeader> createState() => _DictionaryStickyHeaderState();
}

class _DictionaryStickyHeaderState extends State<DictionaryStickyHeader>
    with AutomaticKeepAliveClientMixin {
  bool _childrenBuilt = false;
  final _headerKey = GlobalKey();

  @override
  bool get wantKeepAlive => widget.isExpanded;

  @override
  void didUpdateWidget(DictionaryStickyHeader oldWidget) {
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
          delegate: _DictionaryHeaderDelegate(
            headerKey: _headerKey,
            dictName: widget.dictName,
            entryCount: widget.entries.length,
            isExpanded: widget.isExpanded,
            onToggle: () {
              final newExpanded = !widget.isExpanded;
              widget.onExpansionChanged(newExpanded);
              if (newExpanded && !_childrenBuilt) {
                setState(() => _childrenBuilt = true);
              }
            },
            context: widget.context,
          ),
        ),
        if (widget.isExpanded && _childrenBuilt)
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            sliver: SliverToBoxAdapter(
              child: Card(
                margin: const EdgeInsets.symmetric(vertical: 4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final entry in widget.entries)
                      widget.buildEntryTile(entry),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _DictionaryHeaderDelegate extends SliverPersistentHeaderDelegate {
  _DictionaryHeaderDelegate({
    required this.headerKey,
    required this.dictName,
    required this.entryCount,
    required this.isExpanded,
    required this.onToggle,
    required this.context,
  });

  final GlobalKey headerKey;
  final String dictName;
  final int entryCount;
  final bool isExpanded;
  final VoidCallback onToggle;
  final BuildContext context;

  @override
  double get minExtent => 56;

  @override
  double get maxExtent => 80;

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) {
    final theme = Theme.of(context);
    final elevation = isExpanded && shrinkOffset > 0 ? 4.0 : 0.0;

    return Material(
      key: headerKey,
      color: theme.colorScheme.surface,
      elevation: elevation,
      child: InkWell(
        onTap: onToggle,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '${displayText(dictName, context)}（$entryCount）',
                  style: const TextStyle(fontWeight: FontWeight.bold),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Icon(isExpanded ? Icons.expand_less : Icons.expand_more),
            ],
          ),
        ),
      ),
    );
  }

  @override
  bool shouldRebuild(covariant _DictionaryHeaderDelegate oldDelegate) {
    return dictName != oldDelegate.dictName ||
        entryCount != oldDelegate.entryCount ||
        isExpanded != oldDelegate.isExpanded;
  }
}

class HomepageDictionaryStickyHeader extends StatefulWidget {
  const HomepageDictionaryStickyHeader({
    super.key,
    required this.dictId,
    required this.entries,
    required this.dictName,
    required this.isExpanded,
    required this.onExpansionChanged,
    required this.onEntryTap,
    required this.expandedEntryKeys,
    required this.context,
  });

  final String dictId;
  final List<FodictEntry> entries;
  final String dictName;
  final bool isExpanded;
  final ValueChanged<bool> onExpansionChanged;
  final ValueChanged<FodictEntry> onEntryTap;
  final Set<String> expandedEntryKeys;
  final BuildContext context;

  @override
  State<HomepageDictionaryStickyHeader> createState() =>
      _HomepageDictionaryStickyHeaderState();
}

class _HomepageDictionaryStickyHeaderState
    extends State<HomepageDictionaryStickyHeader>
    with AutomaticKeepAliveClientMixin {
  bool _childrenBuilt = false;
  final _headerKey = GlobalKey();

  @override
  bool get wantKeepAlive => widget.isExpanded;

  @override
  void didUpdateWidget(HomepageDictionaryStickyHeader oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isExpanded && !_childrenBuilt) {
      setState(() => _childrenBuilt = true);
    }
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
          delegate: _HomepageDictionaryHeaderDelegate(
            headerKey: _headerKey,
            dictName: widget.dictName,
            entryCount: widget.entries.length,
            isExpanded: widget.isExpanded,
            onToggle: () {
              final newExpanded = !widget.isExpanded;
              widget.onExpansionChanged(newExpanded);
              if (newExpanded && !_childrenBuilt) {
                setState(() => _childrenBuilt = true);
              }
            },
            context: widget.context,
          ),
        ),
        if (widget.isExpanded && _childrenBuilt)
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(40, 0, 40, 8),
            sliver: SliverToBoxAdapter(
              child: Card(
                margin: const EdgeInsets.symmetric(vertical: 4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final entry in widget.entries)
                      _buildHomepageDictionaryEntryTile(entry),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildHomepageDictionaryEntryTile(FodictEntry entry) {
    final entryKey = '${entry.dictionaryId}:${entry.keyword}';
    final isEntryExpanded = widget.expandedEntryKeys.contains(entryKey);
    final snippet = fodictDefinitionSnippet(entry.definition);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Divider(height: 1),
        InkWell(
          onTap: () => widget.onEntryTap(entry),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 10, 12, 10),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        displayText(entry.keyword, widget.context),
                        style: const TextStyle(
                          color: Color(0xFF176B67),
                          fontWeight: FontWeight.w600,
                          fontSize: 15,
                        ),
                      ),
                      if (!isEntryExpanded && snippet.isNotEmpty)
                        Text(
                          snippet,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Color(0xFF687671),
                            fontSize: 14,
                            height: 1.6,
                          ),
                        ),
                    ],
                  ),
                ),
                Icon(
                  isEntryExpanded
                      ? Icons.expand_less_rounded
                      : Icons.expand_more_rounded,
                  size: 20,
                ),
              ],
            ),
          ),
        ),
        if (isEntryExpanded)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 16, 12),
            child: SelectableText(
              displayText(
                cleanFodictDefinition(entry.definition),
                widget.context,
              ),
              style: const TextStyle(fontSize: 16, height: 1.8),
            ),
          ),
      ],
    );
  }
}

class _HomepageDictionaryHeaderDelegate extends SliverPersistentHeaderDelegate {
  _HomepageDictionaryHeaderDelegate({
    required this.headerKey,
    required this.dictName,
    required this.entryCount,
    required this.isExpanded,
    required this.onToggle,
    required this.context,
  });

  final GlobalKey headerKey;
  final String dictName;
  final int entryCount;
  final bool isExpanded;
  final VoidCallback onToggle;
  final BuildContext context;

  @override
  double get minExtent => 56;

  @override
  double get maxExtent => 80;

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
                Expanded(
                  child: Text(
                    '${displayText(dictName, context)}（$entryCount）',
                    style: const TextStyle(
                      color: Color(0xFF176B67),
                      fontWeight: FontWeight.w700,
                      fontSize: 16,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Icon(
                  isExpanded ? Icons.expand_less : Icons.expand_more,
                  color: const Color(0xFF176B67),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  bool shouldRebuild(covariant _HomepageDictionaryHeaderDelegate oldDelegate) {
    return dictName != oldDelegate.dictName ||
        entryCount != oldDelegate.entryCount ||
        isExpanded != oldDelegate.isExpanded;
  }
}
