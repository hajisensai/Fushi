/// 截屏识字（`/api/ocr/screen`）的 Google Lens 引擎：host 用户在 OCR 设置里选了
/// Google Lens 时，互联设备（Steam Deck 上的 Fushi Lens）发来的每帧交给 Lens 识别，
/// 不要求本机下载 OCR 模型。
///
/// 上传要本机用户同意（[GoogleLensDisclosureScene.gameScreens]，设备本地、与漫画 /
/// 视频分开）。没同意时不上传、回 `lens_consent`，并在本机弹一次同意框；同意后对端
/// 再读一次即可。
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:fushi_engine/media/manga/mokuro_payload.dart';
import 'package:fushi_engine/sync/fushi_screen_ocr_host.dart';

import 'package:fushi/src/media/manga/ocr/google_lens_ocr_service.dart';
import 'package:fushi/src/media/manga/ocr/manga_ocr_engine.dart';

/// 拒绝原因（wire 冻结，对端据此提示「去电脑上的 Fushi 同意」）。
const String kScreenOcrLensConsentReason = 'lens_consent';

class GoogleLensScreenOcrEngine implements ScreenOcrExternalEngine {
  GoogleLensScreenOcrEngine({
    required GoogleLensMangaOcrRunner runner,
    required this.language,
    required Future<bool> Function() hasConsent,
    required void Function() requestConsent,
  }) : _runner = runner,
       _hasConsent = hasConsent,
       _requestConsent = requestConsent;

  final GoogleLensMangaOcrRunner _runner;

  /// Lens 识别语言（OCR 设置里的「Lens 语言」）。
  final String language;
  final Future<bool> Function() _hasConsent;

  /// 在本机弹同意框（不等结果：对端的请求不能挂着等人点）。
  final void Function() _requestConsent;

  @override
  String get id => MangaOcrEngineId.googleLens.name;

  @override
  Future<String?> blockedReason() async {
    if (await _hasConsent()) return null;
    _requestConsent();
    return kScreenOcrLensConsentReason;
  }

  @override
  Future<MokuroImage> recognize(Uint8List image) => _runner.recognizePageBytes(
    image,
    relativeUrl: 'screen',
    language: language,
  );
}

/// 按 host 当前 OCR 引擎偏好选截屏识字引擎：只有明确选了 Google Lens 才用它，
/// 其余（本机模型 / 自动 / 系统 OCR 等）走本机模型，与 `auto` 不自作主张上传的契约一致。
ScreenOcrExternalEngine? selectScreenOcrEngine({
  required String enginePreferenceKey,
  required ScreenOcrExternalEngine Function() lens,
}) {
  final MangaOcrEnginePreference preference =
      MangaOcrEnginePreferenceKey.fromKey(enginePreferenceKey);
  return preference == MangaOcrEnginePreference.googleLens ? lens() : null;
}
