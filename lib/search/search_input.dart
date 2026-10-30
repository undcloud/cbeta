import 'dart:async';

import 'package:flutter/material.dart';

import 'candidates.dart';
import 'conversion.dart';
import 'history.dart';

class SearchInput extends StatefulWidget {
  const SearchInput({
    super.key,
    required this.controller,
    required this.onSearch,
    this.focusNode,
    this.decoration,
    this.autofocus = false,
    this.enabled = true,
    this.recentSearches,
    this.showCandidates = true,
    this.onChanged,
    this.onSelectionChanged,
    this.onFieldTap,
    this.keyMatchCounter,
    this.countScope,
    this.textInputAction = TextInputAction.search,
    this.style,
    this.textBuilder,
    this.displayListenable,
    this.widthAnchorKey,
    this.maxHistoryEntries = 8,
    this.maxChoiceRows = 20,
  });

  final TextEditingController controller;
  final ValueChanged<SearchSelection> onSearch;
  final FocusNode? focusNode;
  final InputDecoration? decoration;
  final bool autofocus;
  final bool enabled;
  final List<String>? recentSearches;
  final bool showCandidates;
  final ValueChanged<String>? onChanged;

  /// 選中候選／歷史後回報待搜尋內容；使用者再次輸入時回報 null。
  final ValueChanged<SearchSelection?>? onSelectionChanged;

  /// 使用者點擊輸入框時回報。
  final VoidCallback? onFieldTap;

  /// 查詢每個候選在字典 key 中的命中次數；null 時不顯示次數。
  final KeyMatchCounter? keyMatchCounter;

  /// 字典範圍（例如已選詞典）變更時，重新統計命中次數。
  final String? countScope;
  final TextInputAction textInputAction;
  final TextStyle? style;
  final String Function(String text)? textBuilder;
  final Listenable? displayListenable;
  final GlobalKey? widthAnchorKey;
  final int maxHistoryEntries;
  final int maxChoiceRows;

  @override
  State<SearchInput> createState() => _SearchInputState();
}

class _SearchInputState extends State<SearchInput> {
  final LayerLink _layerLink = LayerLink();
  final GlobalKey _fieldKey = GlobalKey();
  late FocusNode _focusNode;
  OverlayEntry? _overlay;
  List<String> _history = const [];
  Map<String, String> _selections = const {};
  int _loadToken = 0;
  bool _suppress = false;
  String? _selectedText;
  String _lastText = '';
  SearchSelection? _pendingSelection;
  final Map<String, int> _hitCounts = {};
  final Set<String> _countingCandidates = {};
  Timer? _countDebounce;
  int _scopeToken = 0;

  @override
  void initState() {
    super.initState();
    _focusNode = widget.focusNode ?? FocusNode();
    _focusNode.addListener(_handleFocusChanged);
    _lastText = widget.controller.text;
    widget.controller.addListener(_handleControllerChanged);
    widget.displayListenable?.addListener(_handleDisplayChanged);
    if (widget.recentSearches != null) {
      _history = widget.recentSearches!;
    }
    unawaited(_loadMetadata());
  }

  @override
  void didUpdateWidget(covariant SearchInput oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_handleControllerChanged);
      _lastText = widget.controller.text;
      widget.controller.addListener(_handleControllerChanged);
    }
    if (oldWidget.focusNode != widget.focusNode) {
      oldWidget.focusNode?.removeListener(_handleFocusChanged);
      if (oldWidget.focusNode == null) {
        // 由本元件建立的 FocusNode 需要釋放。
        _focusNode
          ..removeListener(_handleFocusChanged)
          ..dispose();
      }
      _focusNode = widget.focusNode ?? FocusNode();
      _focusNode.addListener(_handleFocusChanged);
    }
    if (oldWidget.displayListenable != widget.displayListenable) {
      oldWidget.displayListenable?.removeListener(_handleDisplayChanged);
      widget.displayListenable?.addListener(_handleDisplayChanged);
    }
    if (widget.recentSearches != null) {
      _history = widget.recentSearches!;
    }
    if (oldWidget.countScope != widget.countScope ||
        (oldWidget.keyMatchCounter == null) !=
            (widget.keyMatchCounter == null)) {
      _scopeToken++;
      _countDebounce?.cancel();
      _hitCounts.clear();
      _countingCandidates.clear();
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _refreshOverlay();
    });
  }

  @override
  void dispose() {
    _scopeToken++;
    _countDebounce?.cancel();
    _hideOverlay();
    _focusNode.removeListener(_handleFocusChanged);
    if (widget.focusNode == null) _focusNode.dispose();
    widget.controller.removeListener(_handleControllerChanged);
    widget.displayListenable?.removeListener(_handleDisplayChanged);
    super.dispose();
  }

  Future<void> _loadMetadata() async {
    final token = ++_loadToken;
    var history = widget.recentSearches ?? const <String>[];
    if (widget.recentSearches == null) {
      try {
        history = await loadSearchHistory();
      } catch (_) {
        history = const [];
      }
    }
    Map<String, String> selections = const {};
    try {
      selections = await loadSearchSelections();
    } catch (_) {
      selections = const {};
    }
    if (!mounted || token != _loadToken) return;
    setState(() {
      _history = history;
      _selections = selections;
    });
    _refreshOverlay();
  }

  void _handleFocusChanged() {
    if (!_focusNode.hasFocus) {
      _selectedText = null;
      _hideOverlay();
      return;
    }
    unawaited(_loadMetadata());
    _refreshOverlay();
  }

  void _handleControllerChanged() {
    if (_suppress) return;
    final text = widget.controller.text;
    if (text == _lastText) {
      _refreshOverlay();
      return;
    }
    _lastText = text;
    if (_pendingSelection != null) {
      _pendingSelection = null;
      widget.onSelectionChanged?.call(null);
    }
    _selectedText = null;
    _refreshOverlay();
  }

  void _handleDisplayChanged() {
    if (!mounted) return;
    setState(() {});
    _overlay?.markNeedsBuild();
  }

  String _text(String text) => widget.textBuilder?.call(text) ?? text;

  /// 繁體（含混排）候選排在簡體／中性候選之前。
  int _traditionalGroup(String query) =>
      SimplifiedTraditionalConverter.ranksAsTraditional(query) ? 0 : 1;

  List<SearchChoice> _currentChoices() {
    final raw = widget.controller.text.trim();
    if (raw.isEmpty) {
      return buildHistoryChoices(
        _history,
        _selections,
      ).take(widget.maxHistoryEntries).toList();
    }
    if (!widget.showCandidates) return const [];
    final choices = buildSearchChoices(raw, _selections);
    return _applyHitCounts(choices).take(widget.maxChoiceRows).toList();
  }

  List<SearchChoice> _applyHitCounts(List<SearchChoice> choices) {
    if (_hitCounts.isEmpty || widget.controller.text.trim().isEmpty) {
      return choices;
    }
    final entries = <({SearchChoice choice, int index})>[];
    for (var index = 0; index < choices.length; index++) {
      entries.add((
        choice: choices[index].withHitCount(_hitCounts[choices[index].query]),
        index: index,
      ));
    }
    final pinned = entries.where((entry) => entry.choice.isPinned).toList();
    final others = entries.where((entry) => !entry.choice.isPinned).toList();
    if (others.any((entry) => entry.choice.hitCount == null)) {
      return [for (final entry in entries) entry.choice];
    }
    others.sort((left, right) {
      final group = _traditionalGroup(
        left.choice.query,
      ).compareTo(_traditionalGroup(right.choice.query));
      if (group != 0) return group;
      final difference = (right.choice.hitCount ?? 0).compareTo(
        (left.choice.hitCount ?? 0),
      );
      if (difference != 0) return difference;
      return left.index.compareTo(right.index);
    });
    return [
      for (final entry in [...pinned, ...others]) entry.choice,
    ];
  }

  void _scheduleHitCounts(List<SearchChoice> choices) {
    final counter = widget.keyMatchCounter;
    if (counter == null) return;
    if (widget.controller.text.trim().isEmpty) return;
    final missing = <String>{};
    for (final choice in choices) {
      if (_hitCounts.containsKey(choice.query)) continue;
      if (_countingCandidates.contains(choice.query)) continue;
      missing.add(choice.query);
    }
    if (missing.isEmpty) return;

    _countDebounce?.cancel();
    _countDebounce = Timer(const Duration(milliseconds: 180), () async {
      final scopeToken = _scopeToken;
      _countingCandidates.addAll(missing);
      var succeeded = true;
      var counts = const <String, int>{};
      try {
        counts = await counter(missing.toList());
      } catch (_) {
        succeeded = false;
      }
      if (!mounted || scopeToken != _scopeToken) {
        _countingCandidates.removeAll(missing);
        return;
      }
      _countingCandidates.removeAll(missing);
      if (!succeeded) return;
      final merged = <String, int>{...counts};
      for (final candidate in missing) {
        merged.putIfAbsent(candidate, () => 0);
      }
      _hitCounts.addAll(merged);
      _overlay?.markNeedsBuild();
    });
  }

  void _refreshOverlay() {
    if (!mounted) return;
    if (!_focusNode.hasFocus || widget.controller.value.composing.isValid) {
      _hideOverlay();
      return;
    }
    final choices = _currentChoices();
    if (choices.isEmpty) {
      _hideOverlay();
      return;
    }
    _scheduleHitCounts(choices);
    if (_overlay == null) {
      _overlay = OverlayEntry(builder: _buildOverlay);
      Overlay.of(context, rootOverlay: true).insert(_overlay!);
    } else {
      _overlay!.markNeedsBuild();
    }
  }

  void _hideOverlay() {
    _overlay?.remove();
    _overlay = null;
    _selectedText = null;
  }

  Future<void> _submit(String value) async {
    final raw = value.trim();
    if (raw.isEmpty) {
      _hideOverlay();
      widget.onSearch(const SearchSelection(rawInput: '', query: ''));
      return;
    }
    final pending = _pendingSelection;
    if (pending != null && (raw == pending.rawInput || raw == pending.query)) {
      _pendingSelection = null;
      _hideOverlay();
      widget.onSearch(pending);
      return;
    }
    final query = await resolveSearchQuery(
      raw,
      selections: _selections,
      keyMatchCounter: widget.keyMatchCounter,
    );
    if (!mounted) return;
    _pendingSelection = null;
    _hideOverlay();
    widget.onSearch(SearchSelection(rawInput: raw, query: query));
  }

  void _choose(SearchChoice choice) {
    final original = choice.rawInput.isNotEmpty
        ? choice.rawInput
        : widget.controller.text.trim();
    final selection = SearchSelection(
      rawInput: original,
      query: choice.query,
      isExplicit: true,
    );
    _pendingSelection = selection;
    widget.onSelectionChanged?.call(selection);
    final text = choice.text;
    setState(() => _selectedText = text);
    _overlay?.markNeedsBuild();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _suppress = true;
      widget.controller.value = TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: text.length),
      );
      _lastText = text;
      _suppress = false;
      _hideOverlay();
      _focusNode.unfocus();
    });
  }

  Widget _buildChoiceTile(SearchChoice choice) {
    final labels = <String>[
      if (choice.isSimplified) _text('簡體'),
      if (choice.isOriginal) _text('原始輸入'),
      if (choice.query != choice.text) '${_text('實際搜尋')}：${choice.query}',
      if (choice.hitCount != null) '${_text('字典')} ${choice.hitCount}',
    ];
    final selected = _selectedText == choice.text;
    return ListTile(
      dense: true,
      title: Text(choice.text, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: labels.isEmpty
          ? null
          : Text(
              labels.join(' · '),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
      trailing: selected
          ? const Icon(Icons.check_rounded, color: Color(0xFF2E7D32))
          : null,
      onTap: () => _choose(choice),
    );
  }

  Widget _buildOverlay(BuildContext overlayContext) {
    final choices = _currentChoices();
    if (choices.isEmpty) return const SizedBox.shrink();
    final fieldContext = _fieldKey.currentContext;
    final renderBox = fieldContext?.findRenderObject() as RenderBox?;
    if (renderBox == null || !renderBox.hasSize) {
      return const SizedBox.shrink();
    }
    final fieldSize = renderBox.size;
    if (fieldSize.width <= 0) return const SizedBox.shrink();

    final anchorContext = widget.widthAnchorKey?.currentContext;
    final anchorBox = anchorContext?.findRenderObject() as RenderBox?;
    final hasAnchor = anchorBox != null && anchorBox.hasSize;
    final width = hasAnchor ? anchorBox.size.width : fieldSize.width;
    final fieldOrigin = renderBox.localToGlobal(Offset.zero);
    final anchorOrigin = hasAnchor
        ? anchorBox.localToGlobal(Offset.zero)
        : fieldOrigin;
    final height = hasAnchor ? anchorBox.size.height : fieldSize.height;
    final offset = Offset(
      anchorOrigin.dx - fieldOrigin.dx,
      anchorOrigin.dy + height - fieldOrigin.dy,
    );

    return Positioned.fill(
      child: CompositedTransformFollower(
        link: _layerLink,
        showWhenUnlinked: false,
        offset: offset,
        child: Align(
          alignment: Alignment.topLeft,
          child: TapRegion(
            groupId: _focusNode,
            child: Material(
              elevation: 8,
              color: Theme.of(overlayContext).colorScheme.surface,
              borderRadius: BorderRadius.circular(8),
              clipBehavior: Clip.antiAlias,
              child: SizedBox(
                width: width,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 280),
                  child: SingleChildScrollView(
                    padding: EdgeInsets.zero,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        for (
                          var index = 0;
                          index < choices.length;
                          index++
                        ) ...[
                          if (index > 0) const Divider(height: 1),
                          _buildChoiceTile(choices[index]),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return CompositedTransformTarget(
      link: _layerLink,
      child: TextField(
        key: _fieldKey,
        controller: widget.controller,
        focusNode: _focusNode,
        groupId: _focusNode,
        autofocus: widget.autofocus,
        enabled: widget.enabled,
        textInputAction: widget.textInputAction,
        style: widget.style,
        decoration: widget.decoration,
        onChanged: (value) {
          _selectedText = null;
          _refreshOverlay();
          widget.onChanged?.call(value);
        },
        onSubmitted: _submit,
        onTap: () {
          _refreshOverlay();
          widget.onFieldTap?.call();
        },
        onTapOutside: (_) => _focusNode.unfocus(),
      ),
    );
  }
}
