import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/media/manga/panel_detection.dart';

/// 分镜检测的两条资源不变式（PR #1591 审查）。
///
/// 1. **整页解码不得落在 UI isolate**：`img.decodeImage` + 640×640 letterbox 是
///    纯 Dart 的同步大循环，一张 2000×3000 的漫画页在移动端要数百毫秒，写在
///    `_detectPanels` 里就是每次翻页卡住整个界面。生产路径必须把这一步整个丢进
///    后台 isolate（`compute(preprocessPanelPageBytes, bytes)`），并且走
///    `detectPrepared`——它先查缓存再调预处理，翻回读过的页一次解码都不做。
/// 2. **ONNX session 必须随页面释放**：detector 是每本书建一个（模型 9 MB 级），
///    `dispose()` 不关就是每开一本书泄漏一份 native session。`close()` 因此挂在
///    `PanelDetector` 接口上，宿主只认接口也能关。
void main() {
  final File readerPage = File(
    'lib/src/media/manga/reader/manga_fushi_page.dart',
  );

  test('分镜检测的解码与预处理不在 UI isolate 上做', () {
    final String source = readerPage.readAsStringSync();
    expect(
      source.contains('decodeImage('),
      isFalse,
      reason: '整页解码必须留在后台 isolate 的 preprocessPanelPageBytes 里',
    );
    final String flat = source.replaceAll(RegExp(r'\s+'), '');
    expect(
      flat.contains('compute(preprocessPanelPageBytes,'),
      isTrue,
      reason: '预处理必须经 compute 送进后台 isolate',
    );
    expect(
      flat.contains('detector.detectPrepared('),
      isTrue,
      reason: '走 detectPrepared 才能在缓存命中时跳过预处理',
    );
  });

  test('分镜导航的模式判据统一走枚举语义', () {
    // pagedVertical 与 spread 共用分页几何，分镜导航对它成立；webtoonGaps 是连续
    // 长条，和 webtoon 一样没有「分镜格」。裸比 `== MangaReadingMode.webtoon` /
    // `== MangaReadingMode.spread` 会让四值枚举里的两个新模式各错一边——
    // 检测/翻页放行 webtoonGaps，状态 chip 又漏掉 pagedVertical。
    final String flat = readerPage.readAsStringSync().replaceAll(
      RegExp(r'\s+'),
      '',
    );
    expect(
      'appModel.mangaPanelNavigation||_mode.isWebtoon'.allMatches(flat).length,
      2,
      reason: '_ensurePanelDetector 与 _tryPanelTurn 都要按 isWebtoon 收口',
    );
    expect(
      flat.contains('appModel.mangaPanelNavigation&&_mode.isPaged'),
      isTrue,
    );
    expect(
      flat.contains('mangaPanelNavigation||_mode==MangaReadingMode.webtoon'),
      isFalse,
    );
    expect(
      flat.contains('mangaPanelNavigation&&_mode==MangaReadingMode.spread'),
      isFalse,
    );
  });

  test('页面销毁时释放 detector 的 ONNX session', () {
    final String flat = readerPage.readAsStringSync().replaceAll(
      RegExp(r'\s+'),
      '',
    );
    expect(
      flat.contains('detector.close()'),
      isTrue,
      reason: 'dispose() 必须关掉 detector，否则每开一本书泄漏一份 ONNX session',
    );
  });

  test('close() 挂在 PanelDetector 契约上而不是某个实现上', () {
    // 宿主只持有接口类型；`close()` 若只写在 OnnxPanelDetector 上，宿主就没法关。
    final PanelDetector detector = _ClosableDetector();
    expect(detector.close(), isA<Future<void>>());
  });
}

class _ClosableDetector implements PanelDetector {
  @override
  Future<PanelDetectionResult> detect(
    Object page, {
    required String pageKey,
    required PanelReadingDirection direction,
  }) async => const PanelDetectionResult.unavailable('stub');

  @override
  Future<PanelDetectionResult> detectPrepared({
    required String pageKey,
    required PanelReadingDirection direction,
    required Future<PreprocessedPanelPage?> Function() prepare,
  }) async => const PanelDetectionResult.unavailable('stub');

  @override
  Future<void> close() async {}
}
