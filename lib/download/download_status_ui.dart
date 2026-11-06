import 'dart:async';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart' hide Text;
import '../dictionary/fodict_download_manager.dart';
import '../download/download_manager.dart';
import '../download/download_models.dart';
import '../download/update_manager.dart';
import '../common/app_nav.dart';
import '../scripture/index_maintenance.dart';
import '../widgets/display_text.dart';

/// 搜尋索引（`.sidx`）的除錯入口：清除與重建，不需要重新下載經文。
///
/// 索引是經文的派生物，這顆按鈕只驗得出「索引到底省下多少時間」這件事；
/// 驗完把這裡改成 `false` 就隱藏入口，其他程式碼不動。
bool searchIndexDebugEntriesVisible = true;

Future<void> showOfflineDataManager(BuildContext context) {
  Navigator.of(context).pop();
  final rootContext = navigatorKey.currentContext ?? context;
  return showDownloadStatusPanel(rootContext);
}

bool _downloadStatusPanelOpen = false;

Future<void> showDownloadStatusPanel(BuildContext context) async {
  if (_downloadStatusPanelOpen) return;
  _downloadStatusPanelOpen = true;
  try {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) =>
          _DownloadStatusPanel(onDisposed: _markDownloadStatusPanelClosed),
    );
  } finally {
    _downloadStatusPanelOpen = false;
  }
}

void _markDownloadStatusPanelClosed() => _downloadStatusPanelOpen = false;

class DownloadInfoButton extends StatefulWidget {
  const DownloadInfoButton({super.key, required this.onPressed});
  final VoidCallback onPressed;

  @override
  State<DownloadInfoButton> createState() => _DownloadInfoButtonState();
}

class _DownloadInfoButtonState extends State<DownloadInfoButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _flashController;

  @override
  void initState() {
    super.initState();
    _flashController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    );
    downloadManager.addListener(_onManagerChanged);
    fodictDownloadManager.addListener(_onManagerChanged);
    updateManager.addListener(_onManagerChanged);
  }

  void _onManagerChanged() {
    if (downloadManager.isDownloading ||
        fodictDownloadManager.isDownloading ||
        updateManager.isUpdating) {
      if (!_flashController.isAnimating) _flashController.repeat(reverse: true);
    } else {
      _flashController.stop();
      _flashController.reset();
    }
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    downloadManager.removeListener(_onManagerChanged);
    fodictDownloadManager.removeListener(_onManagerChanged);
    updateManager.removeListener(_onManagerChanged);
    _flashController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDownloading =
        downloadManager.isDownloading ||
        fodictDownloadManager.isDownloading ||
        updateManager.isUpdating;
    final idleColor = Theme.of(context).colorScheme.onSurface;
    return AnimatedBuilder(
      animation: _flashController,
      builder: (context, _) {
        final iconColor = isDownloading
            ? (_flashController.value < 0.5 ? idleColor : Colors.green)
            : null;
        return IconButton(
          tooltip: displayText('下載管理', context),
          onPressed: widget.onPressed,
          icon: Icon(Icons.info_outline_rounded, color: iconColor),
        );
      },
    );
  }
}

class _DownloadStatusPanel extends StatefulWidget {
  const _DownloadStatusPanel({this.onDisposed});

  final VoidCallback? onDisposed;

  @override
  State<_DownloadStatusPanel> createState() => _DownloadStatusPanelState();
}

class _DownloadStatusPanelState extends State<_DownloadStatusPanel> {
  /// 除錯入口的回報文字；null 時顯示固定說明。
  String? _indexStatus;
  bool _indexRebuilding = false;

  @override
  void dispose() {
    widget.onDisposed?.call();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([
        downloadManager,
        fodictDownloadManager,
        updateManager,
      ]),
      builder: (context, _) {
        final manager = downloadManager;
        final progress = manager.progress;
        final queue = manager.queue;
        final pendingGroups =
            <({DownloadGroup group, List<DownloadItem> items})>[];
        for (final group in queue) {
          final items = group.items
              .where((item) => !manager.isItemComplete(item))
              .toList();
          if (items.isNotEmpty) {
            pendingGroups.add((group: group, items: items));
          }
        }
        return Padding(
          padding: EdgeInsets.fromLTRB(
            16,
            16,
            16,
            MediaQuery.of(context).viewInsets.bottom + 16,
          ),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  displayText('下載管理', context),
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        displayText(
                          '已下載 ${manager.downloadedWorkCount} 部經文 · '
                          '${manager.downloadedJuanCount} 卷',
                          context,
                        ),
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                    const SizedBox(width: 8),
                    TextButton.icon(
                      onPressed: manager.isDownloading
                          ? null
                          : () => _confirmUpdate(context),
                      icon: const Icon(Icons.sync_rounded, size: 18),
                      label: Text(
                        displayText(
                          updateManager.canResume ? '繼續更新' : '更新',
                          context,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                ..._buildUpdateSection(context),
                if (manager.isDownloading && progress != null) ...[
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          displayText(
                            '下載中：${progress.completedItems}/${progress.totalItems} 部'
                            ' · ${progress.completedJuans}/${progress.totalJuans} 卷',
                            context,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        displayText(
                          '速度 ${formatDownloadSpeed(manager.downloadSpeedBytesPerSecond)}',
                          context,
                        ),
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  LinearProgressIndicator(value: progress.fraction),
                  if (progress.currentWork != null) ...[
                    const SizedBox(height: 4),
                    Text(
                      displayText(
                        progress.currentJuan == null
                            ? '目前：${progress.currentWork}'
                            : '目前：${progress.currentWork} 卷 ${progress.currentJuan}',
                        context,
                      ),
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          onPressed: manager.cancelDownload,
                          child: Text(displayText('暫停', context)),
                        ),
                      ),
                    ],
                  ),
                ] else ...[
                  if (manager.status == DownloadStatus.completed)
                    Text(
                      displayText('下載完成', context),
                      style: const TextStyle(color: Colors.green),
                    )
                  else if (manager.status == DownloadStatus.cancelled)
                    Text(displayText('已暫停下載', context))
                  else if (manager.status == DownloadStatus.failed)
                    Text(
                      displayText('下載中斷，尚有未完成的經卷', context),
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    )
                  else if (manager.hasQueuedItems)
                    Text(displayText('有未完成的下載任務', context))
                  else
                    Text(displayText('目前沒有下載任務', context)),
                  if (manager.status == DownloadStatus.failed &&
                      manager.failedWorkIds.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        displayText(
                          '失敗作品：${manager.failedWorkIds.take(12).join('、')}'
                          '${manager.failedWorkIds.length > 12 ? ' 等 ${manager.failedWorkIds.length} 部' : ''}',
                          context,
                        ),
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                  if (manager.canResume && !updateManager.isUpdating) ...[
                    const SizedBox(height: 8),
                    FilledButton.icon(
                      onPressed: manager.resumeDownload,
                      icon: const Icon(Icons.play_arrow_rounded),
                      label: Text(displayText('繼續下載', context)),
                    ),
                  ],
                ],
                if (pendingGroups.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  const Divider(),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          displayText(
                            '下載隊列（${manager.pendingWorkCount} 部待下載）',
                            context,
                          ),
                          style: const TextStyle(fontWeight: FontWeight.bold),
                        ),
                      ),
                      IconButton(
                        tooltip: displayText('刪除所有下載任務', context),
                        icon: const Icon(Icons.delete_sweep_outlined),
                        onPressed: () {
                          manager.clearQueue();
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text(displayText('已清除所有下載任務', context)),
                            ),
                          );
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 200),
                    child: ListView.builder(
                      shrinkWrap: true,
                      itemCount: pendingGroups.length,
                      itemBuilder: (context, index) {
                        final entry = pendingGroups[index];
                        final group = entry.group;
                        final juanCount = entry.items.fold<int>(
                          0,
                          (sum, item) =>
                              sum + manager.pendingJuans(item).length,
                        );
                        return ListTile(
                          dense: true,
                          title: Text(
                            displayText(
                              group.label.replaceFirst(
                                RegExp(r'（\d+ 部）\s*$'),
                                '（${entry.items.length} 部）',
                              ),
                              context,
                            ),
                          ),
                          subtitle: Text(
                            displayText(
                              '${entry.items.length} 部經典 · $juanCount 卷',
                              context,
                            ),
                          ),
                          trailing: IconButton(
                            tooltip: displayText('移除此下載任務', context),
                            icon: const Icon(Icons.delete_outline),
                            onPressed: () => manager.removeFromQueue(group.id),
                          ),
                        );
                      },
                    ),
                  ),
                ],
                const SizedBox(height: 16),
                const Divider(),
                ..._buildFodictDownloadSection(context),
                if (!kIsWeb && searchIndexDebugEntriesVisible) ...[
                  const SizedBox(height: 16),
                  const Divider(),
                  ..._buildIndexDebugSection(context),
                ],
                const SizedBox(height: 16),
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: Text(displayText('關閉', context)),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _confirmUpdate(BuildContext context) async {
    if (downloadManager.isDownloading) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(displayText('經文下載中，完成後再更新', context))),
      );
      return;
    }
    if (updateManager.canResume) {
      updateManager.resume();
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(displayText('更新經目與經文', dialogContext)),
        content: Text(
          displayText(
            '確定要檢查並更新部類、冊別、作譯者、年代與已下載經文嗎？\n'
            '只有遠端有變更時才會下載。',
            dialogContext,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(displayText('取消', dialogContext)),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(displayText('更新', dialogContext)),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    final started = await updateManager.start();
    if (!started && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(displayText('目前無法更新，請等經文下載完成後再試', context))),
      );
    }
  }

  List<Widget> _buildUpdateSection(BuildContext context) {
    final manager = updateManager;
    final progress = manager.progress;
    if (manager.status == UpdateStatus.idle) return const [];
    final counts = progress.totalWorks == 0
        ? ''
        : '（${progress.checkedWorks}/${progress.totalWorks} 部）';
    final statusText = switch (manager.status) {
      UpdateStatus.completed => progress.message ?? '更新完成',
      UpdateStatus.failed => progress.message ?? '更新中斷',
      _ => '${progress.message ?? ''}$counts',
    };
    return [
      Row(
        children: [
          const Icon(Icons.sync_rounded, size: 18),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              displayText('經目與經文更新', context),
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
          if (manager.isUpdating)
            IconButton(
              tooltip: displayText('暫停更新', context),
              onPressed: manager.pause,
              icon: const Icon(Icons.pause_rounded),
            )
          else if (manager.canResume)
            IconButton(
              tooltip: displayText('繼續更新', context),
              onPressed: manager.resume,
              icon: const Icon(Icons.play_arrow_rounded),
            ),
          IconButton(
            tooltip: displayText('刪除更新任務', context),
            onPressed: manager.deleteTask,
            icon: const Icon(Icons.delete_outline),
          ),
        ],
      ),
      Text(
        displayText(statusText, context),
        style: manager.status == UpdateStatus.failed
            ? TextStyle(color: Theme.of(context).colorScheme.error)
            : null,
      ),
      const SizedBox(height: 2),
      Text(
        displayText(
          '已更新 ${progress.updatedWorks} 部 · '
          '已是最新 ${progress.skippedWorks} 部'
          '${progress.failedWorks > 0 ? ' · 失敗 ${progress.failedWorks} 部' : ''}',
          context,
        ),
        style: Theme.of(context).textTheme.bodySmall,
      ),
      if (manager.isUpdating) ...[
        const SizedBox(height: 6),
        LinearProgressIndicator(value: progress.fraction),
        if (progress.currentWork != null) ...[
          const SizedBox(height: 4),
          Text(
            displayText('目前：${progress.currentWork}', context),
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
        if (progress.receivedBytes > 0) ...[
          const SizedBox(height: 2),
          Text(
            displayText(
              '${formatDownloadBytes(progress.receivedBytes)}'
              '${progress.totalBytes > 0 ? ' / ${formatDownloadBytes(progress.totalBytes)}' : ''}'
              ' · 速度 ${formatDownloadSpeed(manager.downloadSpeedBytesPerSecond)}',
              context,
            ),
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ],
      if (manager.status == UpdateStatus.failed && manager.error != null) ...[
        const SizedBox(height: 4),
        Text(
          manager.error!,
          style: TextStyle(color: Theme.of(context).colorScheme.error),
        ),
      ],
      const SizedBox(height: 12),
      const Divider(),
    ];
  }

  /// 除錯用：把派生的搜尋索引清掉或全量重建，經文本體不受影響。
  List<Widget> _buildIndexDebugSection(BuildContext context) {
    return [
      Text(
        displayText('搜尋索引（除錯）', context),
        style: const TextStyle(fontWeight: FontWeight.bold),
      ),
      const SizedBox(height: 4),
      Text(
        displayText(_indexStatus ?? '索引是經文的派生物，刪掉就能重建；第一次搜尋會逐卷補回。', context),
        style: Theme.of(context).textTheme.bodySmall,
      ),
      const SizedBox(height: 8),
      Row(
        children: [
          Expanded(
            child: OutlinedButton.icon(
              onPressed: _indexRebuilding ? null : _clearSearchIndexes,
              icon: const Icon(Icons.cleaning_services_outlined, size: 18),
              label: Text(displayText('清除索引', context)),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: FilledButton.tonalIcon(
              onPressed: _indexRebuilding ? null : _rebuildSearchIndexes,
              icon: const Icon(Icons.construction_outlined, size: 18),
              label: Text(displayText('重建索引', context)),
            ),
          ),
        ],
      ),
    ];
  }

  Future<void> _clearSearchIndexes() async {
    final removed = await scriptureIndexMaintenance.clearAllIndexes();
    if (!mounted) return;
    setState(() => _indexStatus = '已刪除 $removed 卷索引（經文未動），下次搜尋或重建時補回');
  }

  Future<void> _rebuildSearchIndexes() async {
    setState(() {
      _indexRebuilding = true;
      _indexStatus = '正在重建索引…';
    });
    final removed = await scriptureIndexMaintenance.clearAllIndexes();
    final head = '已清除 $removed 卷舊索引';
    final built = await scriptureIndexMaintenance.rebuildIndexes(
      onProgress: (done, total) {
        if (!mounted) return;
        setState(() => _indexStatus = '$head · 已重建 $done/$total 卷');
      },
      shouldAbort: () => !mounted,
    );
    if (!mounted) return;
    setState(() {
      _indexRebuilding = false;
      _indexStatus = '$head · 重建完成，共 $built 卷';
    });
  }

  List<Widget> _buildFodictDownloadSection(BuildContext context) {
    final manager = fodictDownloadManager;
    final tasks = manager.queue;
    final current = manager.currentTask;
    final children = <Widget>[
      Row(
        children: [
          const Icon(Icons.cloud_download_outlined, size: 18),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              displayText('詞典下載', context),
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
          if (manager.isDownloading)
            IconButton(
              tooltip: displayText('暫停下載', context),
              onPressed: manager.pauseDownload,
              icon: const Icon(Icons.pause_rounded),
            )
          else if (manager.canResume)
            IconButton(
              tooltip: displayText('繼續下載', context),
              onPressed: manager.resumeDownload,
              icon: const Icon(Icons.play_arrow_rounded),
            ),
          if (tasks.isNotEmpty)
            IconButton(
              tooltip: displayText('清除詞典下載任務', context),
              onPressed: manager.clearQueue,
              icon: const Icon(Icons.delete_sweep_outlined),
            ),
        ],
      ),
      Text(
        displayText('已安裝 ${manager.installedIds.length} 部下載詞典', context),
        style: Theme.of(context).textTheme.bodySmall,
      ),
    ];

    if (tasks.isEmpty) {
      children.add(const SizedBox(height: 8));
      children.add(
        Text(
          displayText(
            manager.status == FodictDownloadStatus.completed
                ? '詞典下載完成'
                : '目前沒有詞典下載任務',
            context,
          ),
          style: manager.status == FodictDownloadStatus.completed
              ? const TextStyle(color: Colors.green)
              : null,
        ),
      );
    } else {
      if (current != null) {
        children.add(const SizedBox(height: 8));
        children.add(
          Text(
            '${displayText('下載中', context)}：'
            '${displayText(current.name, context)}',
          ),
        );
        children.add(const SizedBox(height: 4));
        children.add(LinearProgressIndicator(value: manager.progress));
        children.add(const SizedBox(height: 4));
        children.add(
          Text(
            '${formatDownloadBytes(manager.receivedBytes)} / '
            '${formatDownloadBytes(manager.totalBytes)} · '
            '速度 ${formatDownloadSpeed(manager.downloadSpeedBytesPerSecond)}',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        );
      }
      children.add(const SizedBox(height: 8));
      children.add(
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 160),
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: tasks.length,
            itemBuilder: (context, index) {
              final task = tasks[index];
              final isCurrent = current?.id == task.id;
              return ListTile(
                dense: true,
                title: Text(displayText(task.name, context)),
                subtitle: Text(
                  displayText(
                    isCurrent
                        ? '下載中 ${(manager.progress * 100).toStringAsFixed(0)}%'
                        : '等待下載',
                    context,
                  ),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                trailing: IconButton(
                  tooltip: displayText('移除此下載任務', context),
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () => manager.removeTask(task.id),
                ),
              );
            },
          ),
        ),
      );
      if (manager.error != null) {
        children.add(const SizedBox(height: 8));
        children.add(
          Text(
            manager.error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        );
      }
    }
    return children;
  }
}

String formatDownloadBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}
