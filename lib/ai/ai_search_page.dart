import 'dart:async';
import 'package:flutter/material.dart' hide Text;
import 'package:flutter/foundation.dart';
import '../ai/ai_chunk.dart';
import '../ai/ai_search_service.dart';
import '../scripture/models.dart';
import '../search/conversion.dart';
import '../settings/display_settings.dart';
import '../reader/reader_page.dart';
import '../settings/display_settings_ui.dart';
import '../widgets/display_text.dart';
import '../widgets/result_widgets.dart';

class AiSearchPage extends StatefulWidget {
  const AiSearchPage({super.key, required this.initialQuery});

  final String initialQuery;

  @override
  State<AiSearchPage> createState() => _AiSearchPageState();
}

class _AiSearchPageState extends State<AiSearchPage> {
  late final TextEditingController controller;
  final ScrollController scrollController = ScrollController();
  final AiSearchService aiService = AiSearchService();
  final List<AiChunk> chunks = [];
  final List<String> relatedQuestions = [];
  String submittedQuery = '';
  String answer = '';
  String? error;
  bool retrieving = false;
  bool generating = false;
  int _requestToken = 0;

  @override
  void initState() {
    super.initState();
    controller = TextEditingController(text: widget.initialQuery);
    if (widget.initialQuery.trim().isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) => search());
    }
  }

  @override
  void dispose() {
    _requestToken++;
    aiService.cancel();
    controller.dispose();
    scrollController.dispose();
    super.dispose();
  }

  Future<void> search([String? value]) async {
    final input = (value ?? controller.text).trim();
    if (input.isEmpty) return;
    controller.text = input;
    FocusScope.of(context).unfocus();
    aiService.cancel();
    final token = ++_requestToken;
    setState(() {
      submittedQuery = SimplifiedTraditionalConverter.convert(input);
      chunks.clear();
      relatedQuestions.clear();
      answer = '';
      error = null;
      retrieving = true;
      generating = false;
    });
    if (kIsWeb) {
      setState(() {
        retrieving = false;
        error = 'AI 語意搜尋未開放網頁跨域存取；請使用桌面或行動版 App。';
      });
      return;
    }
    try {
      await aiService.retrieve(
        submittedQuery,
        onBatch: (arrived) {
          if (!mounted || token != _requestToken) return;
          setState(() => chunks.addAll(arrived));
        },
        isCancelled: () => !mounted || token != _requestToken,
      );
      if (!mounted || token != _requestToken) return;
      if (chunks.isEmpty) {
        setState(() => retrieving = false);
        return;
      }
      chunks.sort((a, b) => b.score.compareTo(a.score));
      setState(() {
        retrieving = false;
        generating = true;
      });
      final result = await aiService.generate(
        submittedQuery,
        chunks,
        onAnswer: (value) {
          if (!mounted || token != _requestToken) return;
          setState(() => answer = value);
        },
        isCancelled: () => !mounted || token != _requestToken,
      );
      if (!mounted || token != _requestToken) return;
      setState(() {
        answer = result.answer;
        relatedQuestions
          ..clear()
          ..addAll(result.relatedQuestions);
        generating = false;
      });
    } catch (exception) {
      if (!mounted || token != _requestToken) return;
      setState(() {
        error = 'AI 語意搜尋失敗：$exception';
        retrieving = false;
        generating = false;
      });
    }
  }

  Future<void> _openChunk(AiChunk chunk) async {
    if (chunk.linehead.isEmpty) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => ScriptureReaderPage(
          passage: ScripturePassage(
            title: chunk.title.isEmpty ? chunk.work : chunk.title,
            reference: chunk.juan == null ? '' : '卷 ${chunk.juan}',
            text: '',
            linehead: chunk.linehead.isEmpty ? null : chunk.linehead,
            juan: chunk.juan?.toString(),
            work: chunk.work,
          ),
          query: '',
          searchHits: const [],
          initialHitIndex: 0,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final settings = scriptureDisplaySettings;
    return Scaffold(
      backgroundColor: settings.backgroundColor,
      appBar: AppBar(
        title: const Text('AI 語意搜尋'),
        backgroundColor: settings.surfaceColor,
        foregroundColor: settings.textColor,
        actions: const [ScriptDisplayButton(), SettingsButton()],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: controller,
                    textInputAction: TextInputAction.search,
                    onSubmitted: (_) => search(),
                    decoration: InputDecoration(
                      hintText: displayText('輸入問題，AI 會理解語意並整理相關經文…', context),
                      border: OutlineInputBorder(),
                      isDense: true,
                      prefixIcon: Icon(Icons.auto_awesome_rounded),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filled(
                  tooltip: displayText('語意搜尋', context),
                  onPressed: () => search(),
                  icon: const Icon(Icons.search_rounded),
                ),
              ],
            ),
          ),
          Expanded(child: _buildBody(context)),
        ],
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (error != null) return NoResults(message: error!);
    if (submittedQuery.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: Text('輸入問題，體驗 AI 語意搜尋', textAlign: TextAlign.center),
        ),
      );
    }
    if (retrieving && chunks.isEmpty) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text('語意檢索中…'),
          ],
        ),
      );
    }
    if (chunks.isEmpty && answer.isEmpty && !generating) {
      return const NoResults(message: '找不到相關經文');
    }
    return ListView(
      controller: scrollController,
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
      children: [
        _buildAnswerCard(context),
        if (relatedQuestions.isNotEmpty) ...[
          const SizedBox(height: 12),
          _buildRelated(context),
        ],
        const SizedBox(height: 20),
        Row(
          children: [
            Icon(
              Icons.menu_book_rounded,
              size: 18,
              color: scriptureDisplaySettings.isDark
                  ? const Color(0xFF6FBAB4)
                  : const Color(0xFF176B67),
            ),
            const SizedBox(width: 6),
            Text(
              '引用經文（${chunks.length}）',
              style: Theme.of(
                context,
              ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
            ),
          ],
        ),
        const SizedBox(height: 8),
        for (final chunk in chunks) _buildChunkCard(context, chunk),
      ],
    );
  }

  Widget _buildAnswerCard(BuildContext context) {
    final settings = scriptureDisplaySettings;
    final text = answer.isEmpty
        ? (generating ? '正在生成回答…' : '正在檢索相關經文…')
        : answer;
    return Card(
      elevation: 0,
      color: settings.isDark ? settings.surfaceColor : const Color(0xFFEAF3F1),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: settings.isDark
              ? const Color(0xFF3A4B46)
              : const Color(0xFFCBE0DC),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.auto_awesome_rounded,
                  size: 18,
                  color: settings.isDark
                      ? const Color(0xFF6FBAB4)
                      : const Color(0xFF176B67),
                ),
                const SizedBox(width: 6),
                Text(
                  'AI 回答',
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: settings.isDark
                        ? const Color(0xFF8FD3CC)
                        : const Color(0xFF145D54),
                  ),
                ),
                const Spacer(),
                if (generating)
                  const SizedBox.square(
                    dimension: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
              ],
            ),
            const SizedBox(height: 10),
            DisplaySelectableText(
              text,
              style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                height: 1.8,
                color: settings.textColor,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRelated(BuildContext context) => Card(
    elevation: 0,
    color: scriptureDisplaySettings.surfaceColor,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(12),
      side: BorderSide(
        color: scriptureDisplaySettings.isDark
            ? const Color(0xFF3A4B46)
            : const Color(0xFFE0D6C2),
      ),
    ),
    child: Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.help_outline_rounded, size: 18),
              const SizedBox(width: 6),
              Text(
                '相關問題',
                style: Theme.of(
                  context,
                ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
              ),
            ],
          ),
          for (final question in relatedQuestions)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () => search(question),
                icon: const Icon(Icons.search_rounded, size: 16),
                label: Text(question, textAlign: TextAlign.left),
              ),
            ),
        ],
      ),
    ),
  );

  Widget _buildChunkCard(BuildContext context, AiChunk chunk) {
    final details = [
      if (chunk.title.isNotEmpty) chunk.title,
      if (chunk.byline.isNotEmpty) chunk.byline,
      if (chunk.category.isNotEmpty) chunk.category,
      if (chunk.juan != null) '卷 ${chunk.juan}',
    ].join(' · ');
    return Card(
      elevation: 0,
      color: scriptureDisplaySettings.surfaceColor,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: scriptureDisplaySettings.isDark
              ? const Color(0xFF3A4B46)
              : const Color(0xFFE0D6C2),
        ),
      ),
      child: InkWell(
        onTap: () => _openChunk(chunk),
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                chunk.title.isEmpty ? chunk.work : chunk.title,
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  color: scriptureDisplaySettings.isDark
                      ? const Color(0xFF6FBAB4)
                      : const Color(0xFF176B67),
                  fontWeight: FontWeight.w700,
                ),
              ),
              if (details.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(
                  details,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: const Color(0xFF78847F),
                  ),
                ),
              ],
              const SizedBox(height: 8),
              Text(
                chunk.text,
                maxLines: 4,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(
                  context,
                ).textTheme.bodyMedium?.copyWith(height: 1.7),
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      chunk.linehead,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: const Color(0xFF78847F),
                      ),
                    ),
                  ),
                  const Icon(
                    Icons.chevron_right_rounded,
                    color: Color(0xFF78847F),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
