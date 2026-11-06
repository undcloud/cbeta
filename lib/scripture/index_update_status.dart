import 'package:flutter/material.dart' hide Text;

import '../widgets/display_text.dart';
import 'index_update_service.dart';

/// 搜尋索引背景更新的共用顯示：下載管理與首頁離線搜尋都用這一份。
class IndexUpdateStatusView extends StatelessWidget {
  const IndexUpdateStatusView({
    super.key,
    required this.progress,
    this.showTitle = true,
  });

  final IndexUpdateProgress progress;
  final bool showTitle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final failed = progress.phase == IndexUpdatePhase.failed;
    final completed = progress.phase == IndexUpdatePhase.completed;
    final message = progress.message ?? _defaultMessage(progress.phase);
    final color = failed
        ? theme.colorScheme.error
        : completed
        ? const Color(0xFF2E7D32)
        : null;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (showTitle) ...[
          Row(
            children: [
              const Icon(Icons.manage_search_rounded, size: 18),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  displayText('搜尋索引更新', context),
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
        ],
        Text(
          displayText(message, context),
          style: failed || completed
              ? theme.textTheme.bodySmall?.copyWith(color: color)
              : null,
        ),
        if (progress.isActive &&
            progress.phase == IndexUpdatePhase.running) ...[
          const SizedBox(height: 6),
          LinearProgressIndicator(value: progress.fraction),
          if (progress.total > 0) ...[
            const SizedBox(height: 4),
            Text(
              displayText('${progress.done}/${progress.total} 卷', context),
              style: theme.textTheme.bodySmall,
            ),
          ],
        ],
      ],
    );
  }

  String _defaultMessage(IndexUpdatePhase phase) => switch (phase) {
    IndexUpdatePhase.idle => '搜尋索引沒有更新任務',
    IndexUpdatePhase.preparing => '準備更新搜尋索引…',
    IndexUpdatePhase.running => '正在更新搜尋索引…',
    IndexUpdatePhase.completed => '搜尋索引已更新',
    IndexUpdatePhase.failed => '搜尋索引更新失敗',
  };
}
