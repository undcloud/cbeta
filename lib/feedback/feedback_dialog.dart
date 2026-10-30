import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'feedback_service.dart';

class FeedbackDialog extends StatefulWidget {
  const FeedbackDialog({super.key});

  @override
  State<FeedbackDialog> createState() => _FeedbackDialogState();
}

class _FeedbackDialogState extends State<FeedbackDialog> {
  final _contentController = TextEditingController();
  final _contactController = TextEditingController();
  final _formKey = GlobalKey<FormState>();
  bool _isSubmitting = false;

  @override
  void dispose() {
    _contentController.dispose();
    _contactController.dispose();
    super.dispose();
  }

  void _showErrorDialog(FeedbackResult result) {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Row(
          children: [
            Icon(Icons.error_outline, color: Colors.red[700], size: 28),
            const SizedBox(width: 8),
            const Text('提交失敗'),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              result.message ?? '未知錯誤',
              style: const TextStyle(fontSize: 15),
            ),
            const SizedBox(height: 16),
            const Divider(),
            const SizedBox(height: 8),
            const Text(
              '服務器已失效，反饋發送失敗，作者暫時失联。',
              style: TextStyle(fontSize: 14, color: Colors.grey),
            ),
            const SizedBox(height: 12),
            const Text(
              '建議您主動通過微信聯繫作者：',
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                const Icon(Icons.chat, size: 18, color: Colors.green),
                const SizedBox(width: 8),
                const Text('微信：', style: TextStyle(fontSize: 14)),
                const Text(
                  'undcloud',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    color: Colors.green,
                  ),
                ),
                const Spacer(),
                TextButton(
                  onPressed: () {
                    Clipboard.setData(const ClipboardData(text: 'undcloud'));
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('微信號已複製'),
                        duration: Duration(seconds: 2),
                      ),
                    );
                  },
                  child: const Text('複製'),
                ),
              ],
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    if (_contentController.text.trim().isEmpty) return;

    setState(() => _isSubmitting = true);

    final result = await FeedbackService.submitFeedback(
      content: _contentController.text.trim(),
      contact: _contactController.text.trim(),
    );

    if (!mounted) return;
    setState(() => _isSubmitting = false);

    if (result.success) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('感謝您的反饋！')));
      Navigator.of(context).pop();
    } else {
      _showErrorDialog(result);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: const Text('意見反饋'),
      content: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 480,
          maxHeight: MediaQuery.sizeOf(context).height * 0.6,
        ),
        child: Form(
          key: _formKey,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextFormField(
                  controller: _contactController,
                  decoration: const InputDecoration(
                    labelText: '聯繫方式（可選）',
                    hintText: '微信、郵箱或手機號，方便我們回覆您',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 16),
                TextFormField(
                  controller: _contentController,
                  decoration: const InputDecoration(
                    labelText: '反饋內容 *',
                    hintText: '請輸入您的意見或建議...',
                    border: OutlineInputBorder(),
                  ),
                  maxLines: 5,
                  validator: (value) {
                    if (value == null || value.trim().isEmpty) {
                      return '請輸入反饋內容';
                    }
                    return null;
                  },
                ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _isSubmitting ? null : () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _isSubmitting ? null : _submit,
          style: FilledButton.styleFrom(backgroundColor: theme.primaryColor),
          child: _isSubmitting
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('提交'),
        ),
      ],
    );
  }
}

void showFeedbackDialog(BuildContext context) {
  showDialog<void>(
    context: context,
    builder: (context) => const FeedbackDialog(),
  );
}
