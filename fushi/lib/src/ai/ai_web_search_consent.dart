import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/utils/components/fushi_m3e_overlays.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_overlays.dart';
import 'package:fushi/src/utils/misc/show_app_dialog.dart';

/// 正在弹的那一次询问：几个面板同时要问时共用这一次，不连弹两个框。
Future<void>? _pendingDecision;

/// 「联网搜索抓前 3 页网页交给 AI」的一次性确认（2026-11-04 用户拍板）。
///
/// 联网搜索会把排名前几的结果网页正文发给用户的 AI 提供商（按 token 计费），所以
/// 选了后端之后**第一次**问：「允许」/「不允许」写进 `ai_web_search_page_fetch`，之后
/// 不再问，改主意去「设置 › AI › 联网搜索」的开关。没答过 / 不允许时 AI 功能读到的
/// 联网搜索是 null（[PreferencesRepository.aiWebSearch]），只查 LRCLIB。
///
/// 照 `ocr_llm_default_consent.dart`：Esc / 返回键 / 点空白只是关掉，**不算回答**，
/// 不写偏好，下次再问；两个按钮都不默认获焦。说明里写明部分 AI 提供商自带联网搜索
/// （有的收费），用那种提供商可以不配置这里。
///
/// 只在用户在场、真要抓页之前的入口调用（字幕生成面板开 AI 点「开始」）。**不**挂在
/// 设置项的 onChanged 上：那也是 ctl `settings.set` 的写入口，弹框会把 CLI / AI 助手的
/// 调用卡在主窗口上等人点。没选后端（关闭）或已答过时直接返回。
Future<void> ensureAiWebSearchPageFetchDecided(
  BuildContext context,
  PreferencesRepository prefs,
) {
  return _pendingDecision ??= _decide(
    context,
    prefs,
  ).whenComplete(() => _pendingDecision = null);
}

Future<void> _decide(BuildContext context, PreferencesRepository prefs) async {
  if (prefs.aiWebSearchPageFetchDecision.isNotEmpty) return;
  if (prefs.aiWebSearchConfig == null || !context.mounted) return;
  final bool? accepted = await showAppDialog<bool>(
    context: context,
    builder: (BuildContext dialogContext) => FushiAlertDialog(
      icon: const FushiDialogHeroIcon(
        icon: FushiIcons.globe,
        tone: FushiHeroTone.neutral,
      ),
      title: Text(t.ai_web_search_consent_title),
      content: Text(t.ai_web_search_consent_body),
      actions: <Widget>[
        FushiDialogAction(
          label: t.ai_web_search_consent_decline,
          onPressed: () => Navigator.of(dialogContext).pop(false),
        ),
        FushiDialogAction(
          label: t.ai_web_search_consent_accept,
          kind: FushiDialogActionKind.primary,
          onPressed: () => Navigator.of(dialogContext).pop(true),
        ),
      ],
    ),
  );
  if (accepted == null) return;
  await prefs.setAiWebSearchPageFetchAllowed(accepted);
}
