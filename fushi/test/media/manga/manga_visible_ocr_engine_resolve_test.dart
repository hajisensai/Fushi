import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/manga/ocr/manga_ocr_engine.dart';
import 'package:fushi/src/media/manga/reader/manga_visible_ocr_backend.dart';
import 'package:fushi_engine/ocr/manga_ocr_service.dart';

/// 显式引擎走早返回分支，不碰模型状态与系统 OCR 通道；这里任何一次调用都算回归。
class _UntouchedService implements MangaOcrService {
  @override
  bool get isSupportedPlatform => throw UnimplementedError();

  @override
  Future<MangaOcrModelStatus> modelStatus() => throw UnimplementedError();

  @override
  Stream<MangaOcrDownloadEvent> downloadModels() => throw UnimplementedError();

  @override
  Future<int> deleteModels() => throw UnimplementedError();

  @override
  Stream<MangaOcrVolumeEvent> ocrFolder({
    required String imageDirPath,
    String? volumeTitle,
  }) => throw UnimplementedError();
}

Future<MangaOcrEngineId> _resolve(
  MangaOcrEnginePreference preference, {
  required bool userInitiated,
}) => MangaVisibleOcrBackend.resolveEngine(
  preference,
  _UntouchedService(),
  userInitiated: userInitiated,
);

void main() {
  group('边看边 OCR 的引擎解析边界', () {
    test('云端引擎（Google Lens）不许自动触发：翻页不弹授权框、不上传', () async {
      // 授权文案同意的是「识别本漫画」这个用户动作；Lens 又是出厂默认引擎，
      // 放行的话自动模式开书就弹授权框，同意过的存量用户则翻一页传一页。
      await expectLater(
        _resolve(MangaOcrEnginePreference.googleLens, userInitiated: false),
        throwsA(isA<MangaVisibleOcrEngineUnavailable>()),
      );
      expect(
        await _resolve(
          MangaOcrEnginePreference.googleLens,
          userInitiated: true,
        ),
        MangaOcrEngineId.googleLens,
      );
    });

    test('只支持整卷任务的引擎判为页级不可用（自动路径据此静默，不每页报错）', () async {
      for (final MangaOcrEnginePreference preference
          in <MangaOcrEnginePreference>[
            MangaOcrEnginePreference.externalMokuro,
            MangaOcrEnginePreference.pairedHost,
          ]) {
        for (final bool userInitiated in <bool>[false, true]) {
          await expectLater(
            _resolve(preference, userInitiated: userInitiated),
            throwsA(isA<MangaVisibleOcrEngineUnavailable>()),
            reason: '$preference userInitiated=$userInitiated',
          );
        }
      }
    });

    test('本机引擎自动与手动都放行', () async {
      for (final bool userInitiated in <bool>[false, true]) {
        expect(
          await _resolve(
            MangaOcrEnginePreference.localOnnx,
            userInitiated: userInitiated,
          ),
          MangaOcrEngineId.localOnnx,
        );
        expect(
          await _resolve(
            MangaOcrEnginePreference.systemOcr,
            userInitiated: userInitiated,
          ),
          MangaOcrEngineId.systemOcr,
        );
      }
    });
  });
}
