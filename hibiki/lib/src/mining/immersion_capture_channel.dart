import 'package:flutter/services.dart';

import 'package:hibiki/src/mining/immersion_mining_request.dart';
import 'package:hibiki/src/sync/immersion_mine_payload.dart';
import 'package:hibiki_anki/hibiki_anki.dart' show AnkiMiningSource;

/// 第二层B（TODO-1000）：驱动后台专用软解 WebView2 实例抓 Netflix 片段音画。仅 Windows。
/// native 缺失（未构建 / 非 Windows）时 [capture] 返回 error，seam 降级为 2A 截图卡。
abstract final class ImmersionCaptureChannel {
  static const MethodChannel _channel =
      MethodChannel('app.hibiki.reader/immersion_capture');

  static Future<ImmersionCaptureResult> capture({
    required String netflixVideoId,
    required int clipStartMs,
    required int clipEndMs,
    int fps = 8,
    int width = 320,
  }) async {
    try {
      final Map<Object?, Object?>? r =
          await _channel.invokeMethod<Map<Object?, Object?>>(
        'capture',
        <String, Object?>{
          'videoId': netflixVideoId,
          'startMs': clipStartMs,
          'endMs': clipEndMs,
          'fps': fps,
          'width': width,
        },
      );
      return ImmersionCaptureResult.fromMap(r ?? const <Object?, Object?>{});
    } on PlatformException catch (e) {
      return ImmersionCaptureResult(error: e.message ?? 'capture failed');
    } on MissingPluginException {
      return const ImmersionCaptureResult(error: 'immersion_capture unavailable');
    }
  }
}

class ImmersionCaptureResult {
  const ImmersionCaptureResult({this.gifBytes, this.audioBytes, this.error});

  final Uint8List? gifBytes;
  final Uint8List? audioBytes;
  final String? error;

  bool get ok => error == null;

  static ImmersionCaptureResult fromMap(Map<Object?, Object?> m) =>
      ImmersionCaptureResult(
        gifBytes: m['gifBytes'] as Uint8List?,
        audioBytes: m['audioBytes'] as Uint8List?,
        error: m['error'] as String?,
      );
}

/// 纯函数：给定 payload + 后台抓取结果 → 引擎请求。可单测降级逻辑。
///
/// [cap] `ok` 时优先用后台抓的 GIF/音频（GIF 缺则回落截图）；失败时降级为 2A 截图卡
/// （无音频，requireAudio=false 不中止）。任何情况下 mediaSource=null（Netflix 无本地源）。
ImmersionMiningRequest buildImmersionRequest(
  ImmersionMinePayload p,
  ImmersionCaptureResult cap,
) {
  final bool useCapture = cap.ok;
  final Uint8List? cover =
      useCapture ? (cap.gifBytes ?? p.screenshotBytes) : p.screenshotBytes;
  final bool coverIsGif = useCapture && cap.gifBytes != null;
  final Uint8List? audio = useCapture ? cap.audioBytes : null;
  return ImmersionMiningRequest(
    fields: p.fields,
    mediaSource: null,
    clipStartMs: 0,
    clipEndMs: 0,
    sentence: p.sentence,
    cueSentence: p.cueSentence,
    documentTitle: p.documentTitle ?? 'Netflix',
    source: AnkiMiningSource.video,
    providedCoverBytes: cover,
    providedCoverName: coverIsGif ? 'netflix_clip.gif' : 'netflix_shot.jpg',
    providedAudioBytes: audio,
    requireAudio: audio != null,
  );
}
