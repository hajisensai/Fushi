import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:fushi/src/media/manga/aidoku/aidoku_network_session.dart';

/// [AidokuCloudflareGate] 的抑制区语义。
///
/// 这块覆盖原先寄生在 `aidoku_runtime_cloudflare_test.dart` 里——那份测试整体
/// 驱动的是 iOS 的 MethodChannel runtime，已随 Aidoku 的 iOS 宿主一起按 App Store
/// 合规移除。但 `runSuppressed` 本身不是 iOS 的东西：全源搜索（`manga_global_search_runner`）
/// 与发现页的来源自动匹配（`manga_source_matcher`）在**所有**有 Aidoku 的平台上都
/// 靠它把后台扇出里的 Cloudflare 挑战压成状态码，而不是无操作弹出全屏解题 WebView。
/// 实现没了就把测试一起删，会让这条仍在生产路径上的不变式变成零覆盖。
void main() {
  tearDown(() {
    AidokuCloudflareGate.resolver = null;
  });

  test('默认不在抑制区', () {
    expect(AidokuCloudflareGate.suppressed, isFalse);
  });

  test('抑制区跨 await 继承，退出后自动恢复', () async {
    final bool inside = await AidokuCloudflareGate.runSuppressed(() async {
      expect(AidokuCloudflareGate.suppressed, isTrue);
      // Zone 值随异步链走：await 之后仍在同一个 Zone 里，否则「后台批量流不弹
      // 解题页」只在第一个同步帧内成立，第一次 await 之后就漏。
      await Future<void>.delayed(Duration.zero);
      return AidokuCloudflareGate.suppressed;
    });
    expect(inside, isTrue);
    expect(AidokuCloudflareGate.suppressed, isFalse);
  });

  test('受限并发扇出的每个 worker 都继承抑制区', () async {
    final List<bool> seen = await AidokuCloudflareGate.runSuppressed(() async {
      return Future.wait<bool>(<Future<bool>>[
        for (int i = 0; i < 4; i++)
          Future<bool>(() async {
            await Future<void>.delayed(Duration(milliseconds: i));
            return AidokuCloudflareGate.suppressed;
          }),
      ]);
    });
    expect(seen, everyElement(isTrue));
  });

  test('body 抛异常也不会把抑制区漏到外面', () async {
    await expectLater(
      AidokuCloudflareGate.runSuppressed<void>(
        () async => throw StateError('boom'),
      ),
      throwsStateError,
    );
    expect(AidokuCloudflareGate.suppressed, isFalse);
  });

  test('抑制区外的 Zone 不受影响', () async {
    await AidokuCloudflareGate.runSuppressed(() async {});
    await runZoned<Future<void>>(() async {
      expect(AidokuCloudflareGate.suppressed, isFalse);
    });
  });
}
