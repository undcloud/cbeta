import 'dart:async';
import 'package:flutter/material.dart' hide Text;
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import '../app_update/app_update.dart';
import '../widgets/display_text.dart';

Future<void> showAbout(BuildContext context) {
  return showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(displayText('關於我們', context)),
      content: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 480,
          maxHeight: MediaQuery.sizeOf(context).height * 0.68,
        ),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _AboutSection(
                title: '專案介紹',
                children: [
                  Text(
                    displayText(
                      '本 App 是一款基於 CBETA 提供的 API 開發的免費開源佛典閱讀與檢索應用程式，支援將經卷與 41 部佛學字典下載至本地，離線單機即可完整使用。本專案為獨立開發，非 CBETA Online 官方開發或維護之應用程式。',
                      context,
                    ),
                  ),
                ],
              ),
              _AboutSection(
                title: '功能特色',
                children: [
                  Text(
                    displayText(
                      '全文搜尋與 AI 語意搜尋，簡體輸入自動轉繁\n'
                      '部類、冊別、作譯者、年代、經目查詢多種瀏覽\n'
                      'Goto 行號／引文直接定位\n'
                      '經卷與字典一鍵下載，完全離線可用\n'
                      '書籤、閱讀位置記憶、字體與簡繁顯示設定',
                      context,
                    ),
                  ),
                ],
              ),
              _AboutSection(
                title: '隱私與授權',
                children: [
                  Text(
                    displayText(
                      '無需註冊，無廣告，不搜集任何個人隱私資訊；網絡請求僅用於搜尋、經文更新與字典下載。本專案以 GPL-3.0 免費開源，原始碼公開。',
                      context,
                    ),
                  ),
                ],
              ),
              _AboutSection(
                title: '下載與聯絡',
                children: [
                  _AboutLink(
                    label: latestApkDownloadUrl,
                    url: latestApkDownloadUrl,
                  ),
                  const SizedBox(height: 8),
                  _AboutLink(
                    label: '開源專案：https://gitee.com/undclouds/cbeta',
                    url: 'https://gitee.com/undclouds/cbeta',
                  ),
                  const SizedBox(height: 8),
                  _AboutLabelText(label: '開發者：', value: 'undcloud'),
                  const SizedBox(height: 4),
                  _AboutLabelText(label: '微信聯絡：', value: 'undcloud'),
                  const SizedBox(height: 8),
                  _AboutLink(
                    label: '資料服務：https://cbdata.dila.edu.tw/',
                    url: 'https://cbdata.dila.edu.tw/',
                  ),
                  const SizedBox(height: 8),
                  Text(
                    displayText(
                      '經文與檢索資料來自中華電子佛典協會（CBETA），資料權利與使用規範依原資料提供方的相關規定辦理。',
                      context,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton.icon(
          onPressed: () async {
            await Clipboard.setData(
              ClipboardData(text: _aboutIntroductionText()),
            );
            if (!context.mounted) return;
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(const SnackBar(content: Text('已複製介紹')));
          },
          icon: const Icon(Icons.copy_rounded, size: 18),
          label: Text(displayText('複製', context)),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(displayText('關閉', context)),
        ),
      ],
    ),
  );
}

String _aboutIntroductionText() => [
  'CBETA 經典全文搜尋 Flutter App',
  '',
  '本 App 是一款基於 CBETA 提供的 API 開發的免費開源佛典閱讀與檢索應用程式，',
  '支援將經卷與 41 部佛學字典下載至本地，離線單機即可完整使用。',
  '本專案為獨立開發，非 CBETA Online 官方開發或維護之應用程式。',
  '',
  '功能特色：全文搜尋與 AI 語意搜尋、多種經目瀏覽、Goto 定位、',
  '經卷與字典離線下載、書籤與閱讀位置、簡繁顯示設定。',
  '',
  '隱私與授權：無需註冊，無廣告，不搜集任何個人隱私資訊；',
  '網絡請求僅用於搜尋、經文更新與字典下載。本專案以 GPL-3.0 免費開源。',
  '',
  '開發者：undcloud（微信：undcloud）',
  '開源專案：https://gitee.com/undclouds/cbeta',
  '下載最新版本：',
  latestApkDownloadUrl,
  '資料來源：中華電子佛典協會（CBETA），https://cbdata.dila.edu.tw/',
].join('\n');

class _AboutSection extends StatelessWidget {
  const _AboutSection({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 20),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          displayText(title, context),
          style: Theme.of(
            context,
          ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 8),
        ...children,
      ],
    ),
  );
}

class _AboutLabelText extends StatelessWidget {
  const _AboutLabelText({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Text.rich(
    TextSpan(
      children: [
        TextSpan(
          text: displayText(label, context),
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        TextSpan(text: displayText(value, context)),
      ],
    ),
  );
}

class _AboutLink extends StatelessWidget {
  const _AboutLink({required this.label, required this.url});

  final String label;
  final String url;

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: () async {
      final messenger = ScaffoldMessenger.of(context);
      try {
        final opened = await launchUrl(
          Uri.parse(url),
          mode: LaunchMode.externalApplication,
        );
        if (!opened && context.mounted) {
          messenger.showSnackBar(SnackBar(content: Text('無法開啟連結：$url')));
        }
      } catch (error) {
        if (!context.mounted) return;
        messenger.showSnackBar(SnackBar(content: Text('開啟連結失敗：$error')));
      }
    },
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Text(
        displayText(label, context),
        style: TextStyle(
          color: Theme.of(context).colorScheme.primary,
          decoration: TextDecoration.underline,
        ),
      ),
    ),
  );
}
