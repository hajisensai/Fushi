import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/utils.dart';

/// 正在弹的那一次询问：设置页选后端与字幕生成面板「开始」同时要问时共用这一次。
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
/// 只在用户在场的入口调用。没选后端（关闭）或已答过时直接返回。
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
