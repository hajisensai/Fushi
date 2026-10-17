import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_engine/ai/ai_feature.dart';
import 'package:fushi_engine/ai/ai_provider_config.dart';
import 'package:fushi_engine/ocr/manga_ai_ocr_refiner.dart';

/// 正在弹的那一次询问：同一时刻多个入口（视频暂停帧查词 + 整轨确认）一起要问时
/// 共用这一次，不连弹两个框、后答覆盖先答。
Future<void>? _pendingDecision;

/// 「低置信度 OCR 结果默认交给 LLM」的一次性确认（2026-10-13 用户拍板）。
///
/// 默认档位是「低置信度」，但它会把裁图上传给第三方并计费，所以**第一次真要用时**
/// 问一次：「开启」写入 `low_confidence`、「不用」写入 `off`，都写进同一个档位键
/// `manga_ocr_ai_mode`，之后不再问——用户在设置里亲手选过档位也同样不问。Esc /
/// 返回键 / 点空白只是关掉，**不算回答**：不写偏好，下次再问（误触一下就被永久记成
/// 关太重）。两个按钮都不默认获焦，回车不会替用户点「开启」。
///
/// 只在用户在场的入口调用（漫画直读 OCR、视频图形字幕查词 / 整轨转文字）。后台
/// 路径（下载后自动 OCR、整卷任务）不弹框：档位没定之前按「关」处理，不发请求
/// （见 `createMangaAiOcrRefiner`）。没解析到可用提供商时不问——问了也没人接。
Future<void> ensureMangaAiOcrDefaultDecided(
  BuildContext context,
  AppModel appModel,
) {
  return _pendingDecision ??= _decide(
    context,
    appModel,
  ).whenComplete(() => _pendingDecision = null);
}

Future<void> _decide(BuildContext context, AppModel appModel) async {
  if (appModel.mangaOcrAiMode.isNotEmpty) return;
  final AiProviderConfig? provider = appModel.prefsRepo.aiFeatureAssignments
      .resolve(AiFeature.mangaOcr, appModel.prefsRepo.aiProviders);
  if (provider == null || !context.mounted) return;
  final String model = provider.model.trim();
  final bool? accepted = await showAppDialog<bool>(
    context: context,
    builder: (BuildContext dialogContext) => FushiAlertDialog(
      icon: const FushiDialogHeroIcon(
        icon: FushiIcons.ai,
        tone: FushiHeroTone.neutral,
      ),
      title: Text(t.ocr_llm_default_title),
      content: Text(
        t.ocr_llm_default_body(
          provider: model.isEmpty ? provider.name : '${provider.name} · $model',
        ),
      ),
      actions: <Widget>[
        FushiDialogAction(
          label: t.ocr_llm_default_decline,
          onPressed: () => Navigator.of(dialogContext).pop(false),
        ),
        FushiDialogAction(
          label: t.ocr_llm_default_accept,
          kind: FushiDialogActionKind.primary,
          onPressed: () => Navigator.of(dialogContext).pop(true),
        ),
      ],
    ),
  );
  if (accepted == null) return;
  await appModel.setMangaOcrAiMode(
    (accepted ? MangaAiOcrMode.lowConfidence : MangaAiOcrMode.off).storageKey,
  );
}
