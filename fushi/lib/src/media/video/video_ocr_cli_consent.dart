/// 图形字幕 OCR 两个一次性同意的**无头**答案（桌面 CLI `--consent-llm` /
/// `--consent-upload`）：写入与 app 内同意框完全相同的同意状态，没给参数且尚未同意时
/// 如实报「需要同意」，不在 app 里弹框把 CLI 挂住。
///
/// 两份状态与对应的询问框同源：
/// * 「低置信度默认交给 LLM」= 档位键 `manga_ocr_ai_mode`（`ensureMangaAiOcrDefaultDecided`
///   的「开启」写 `low_confidence`、「不用」写 `off`）；档位已选过 / 没指派 LLM 提供商时
///   不需要回答（询问框同样不问）。
/// * Google Lens 上传 = SharedPreferences 里按场景分开的版本号
///   （`ensureGoogleLensDisclosure`，视频画面用 [GoogleLensDisclosureScene.videoFrames]）。
library;

import 'package:fushi_engine/ai/ai_feature.dart';
import 'package:fushi_engine/ai/ai_provider_config.dart';
import 'package:fushi_engine/ocr/manga_ai_ocr_refiner.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fushi/src/media/manga/ocr/google_lens_disclosure.dart';
import 'package:fushi/src/models/app_model.dart';

/// Lens 上传同意：已同意过（当前版本）→ true；[consent] 为 true 时写入同意记录后
/// true；否则 false（未同意，调用方报错）。
Future<bool> acceptGoogleLensUploadHeadless({
  required GoogleLensDisclosureScene scene,
  required bool consent,
}) async {
  final SharedPreferences preferences = await SharedPreferences.getInstance();
  if (preferences.getInt(scene.preferenceKey) == kGoogleLensDisclosureVersion) {
    return true;
  }
  if (!consent) return false;
  await preferences.setInt(scene.preferenceKey, kGoogleLensDisclosureVersion);
  return true;
}

/// 「默认交给 LLM」：不需要回答（档位已定 / 没有可用提供商）或已按 [consent] 写入
/// 档位 → true；需要回答但 [consent] 为 null → false。
Future<bool> decideMangaAiOcrDefaultHeadless(
  AppModel appModel, {
  required bool? consent,
}) async {
  if (appModel.mangaOcrAiMode.isNotEmpty) return true;
  final AiProviderConfig? provider = appModel.prefsRepo.aiFeatureAssignments
      .resolve(AiFeature.mangaOcr, appModel.prefsRepo.aiProviders);
  if (provider == null) return true;
  if (consent == null) return false;
  await appModel.setMangaOcrAiMode(
    (consent ? MangaAiOcrMode.lowConfidence : MangaAiOcrMode.off).storageKey,
  );
  return true;
}
