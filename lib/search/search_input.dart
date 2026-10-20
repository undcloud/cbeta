import 'dart:async';

import 'package:flutter/material.dart';

import 'candidates.dart';
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

  @override
  void initState() {
    super.initState();
    _focusNode = widget.focusNode ?? FocusNode();
    _focusNode.addListener(_handleFocusChanged);
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
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _refreshOverlay();
    });
  }

  @override
  void dispose() {
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
    _selectedText = null;
    _refreshOverlay();
  }

  void _handleDisplayChanged() {
    if (!mounted) return;
    setState(() {});
    _overlay?.markNeedsBuild();
  }

  String _text(String text) => widget.textBuilder?.call(text) ?? text;

  List<SearchChoice> _currentChoices() {
    final raw = widget.controller.text.trim();
    if (raw.isEmpty) {
      return buildHistoryChoices(
        _history,
        _selections,
      ).take(widget.maxHistoryEntries).toList();
    }
    if (!widget.showCandidates) return const [];
    return buildSearchChoices(
      raw,
      _selections,
    ).take(widget.maxChoiceRows).toList();
  }

  void _refreshOverlay() {
    if (!mounted) return;
    if (!_focusNode.hasFocus || widget.controller.value.composing.isValid) {
      _hideOverlay();
      return;
    }
    if (_currentChoices().isEmpty) {
      _hideOverlay();
      return;
    }
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

  void _submit(String value) {
    final raw = value.trim();
    if (raw.isEmpty) {
      _hideOverlay();
      widget.onSearch(const SearchSelection(rawInput: '', query: ''));
      return;
    }
    final choices = buildSearchChoices(raw, _selections);
    final query = choices.isNotEmpty
        ? choices.first.query
        : preferredQueryFor(raw, _selections);
    _hideOverlay();
    widget.onSearch(SearchSelection(rawInput: raw, query: query));
  }

  void _choose(SearchChoice choice) {
    final raw = choice.isHistory ? choice.text : widget.controller.text.trim();
    final text = choice.isHistory ? choice.text : choice.query;
    setState(() => _selectedText = text);
    _overlay?.markNeedsBuild();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _suppress = true;
      widget.controller.value = TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: text.length),
      );
      _suppress = false;
      _hideOverlay();
      widget.onSearch(SearchSelection(rawInput: raw, query: choice.query));
    });
  }

  Widget _buildChoiceTile(SearchChoice choice) {
    final labels = <String>[
      if (choice.isHistory) _text('歷史'),
      if (choice.isOriginal) _text('原始輸入'),
      if (choice.query != choice.text) '${_text('實際搜尋')}：${choice.query}',
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
        onTap: _refreshOverlay,
        onTapOutside: (_) => _focusNode.unfocus(),
      ),
    );
  }
}
