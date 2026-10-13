import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_engine/ai/ai_feature.dart';
import 'package:fushi_engine/ai/ai_provider_config.dart';
import 'package:fushi_engine/ocr/manga_ai_ocr_refiner.dart';

/// 「低置信度 OCR 结果默认交给 LLM」的一次性确认（2026-10-13 用户拍板）。
///
/// 默认档位是「低置信度」，但它会把裁图上传给第三方并计费，所以**第一次真要用时**
/// 问一次：同意写入 `low_confidence`、拒绝写入 `off`，都写进同一个档位键
/// `manga_ocr_ai_mode`，之后不再问——用户在设置里亲手选过档位也同样不问。
///
/// 只在用户在场的入口调用（漫画直读 OCR、视频图形字幕查词 / 整轨转文字）。后台
/// 路径（下载后自动 OCR、整卷任务）不弹框：档位没定之前按「关」处理，不发请求
/// （见 `createMangaAiOcrRefiner`）。没解析到可用提供商时不问——问了也没人接。
Future<void> ensureMangaAiOcrDefaultDecided(
  BuildContext context,
  AppModel appModel,
) async {
  if (appModel.mangaOcrAiMode.isNotEmpty) return;
  final AiProviderConfig? provider = appModel.prefsRepo.aiFeatureAssignments
      .resolve(AiFeature.mangaOcr, appModel.prefsRepo.aiProviders);
  if (provider == null || !context.mounted) return;
  final String model = provider.model.trim();
  final bool accepted = await showFushiConfirmDialog(
    context: context,
    title: t.ocr_llm_default_title,
    message: t.ocr_llm_default_body(
      provider: model.isEmpty ? provider.name : '${provider.name} · $model',
    ),
    icon: FushiIcons.ai,
    cancelLabel: t.ocr_llm_default_decline,
    confirmLabel: t.ocr_llm_default_accept,
    // 点空白关掉不算「拒绝」：误触一下就被永久记成关，太重。
    barrierDismissible: false,
  );
  await appModel.setMangaOcrAiMode(
    (accepted ? MangaAiOcrMode.lowConfidence : MangaAiOcrMode.off).storageKey,
  );
}
