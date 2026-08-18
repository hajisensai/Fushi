// BUG-1706：下载页「资源」标签把三种截然不同的缺口报成同一句话。
//
// 用户现场：qBittorrent 后端已配好（地址 http://127.0.0.1:1236、账密齐、
// 分类 fushi），本地受管视频来源 0 条，于是页面显示「请先配置下载后端。」+
// 「去设置」。用户照着跳到下载设置页，看到后端配置完好无缺，无从下手——
// 提示把他指向了一个根本没问题的地方。
//
// 根因是页面把「后端没就绪」「没有受管视频来源」「后端身份解析失败」三种
// 情况一律折叠成一个 `null`，只剩一句话可说。本文件钉住三者必须分开，以及
// 判定顺序。

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/download/video_download_backend_identity.dart';
import 'package:fushi/src/pages/implementations/downloads_resource_gap.dart';

void main() {
  group('findDownloadsResourceGap', () {
    test('后端就绪 + 有受管来源 + 身份解析成功 → 无缺口', () {
      expect(
        findDownloadsResourceGap(
          backendReady: true,
          managedSourceCount: 2,
          identityError: null,
        ),
        isNull,
      );
    });

    test('后端已配好、只是没有受管视频来源 → 报「缺来源」，绝不能报成「缺后端」', () {
      final DownloadsResourceGap? gap = findDownloadsResourceGap(
        backendReady: true,
        managedSourceCount: 0,
        identityError: null,
      );
      expect(
        gap,
        isA<DownloadsResourceNoManagedSource>(),
        reason: 'BUG-1706 的用户现场：后端配置完好，缺的只是本地视频文件夹。'
            '报成「请先配置下载后端」会把用户支到一个没问题的页面。',
      );
      expect(gap, isNot(isA<DownloadsResourceNoBackend>()));
    });

    test('后端没就绪 → 报「缺后端」', () {
      expect(
        findDownloadsResourceGap(
          backendReady: false,
          managedSourceCount: 3,
          identityError: null,
        ),
        isA<DownloadsResourceNoBackend>(),
      );
    });

    test('后端没就绪时优先报后端：没来源也先说后端（谈别的没意义）', () {
      expect(
        findDownloadsResourceGap(
          backendReady: false,
          managedSourceCount: 0,
          identityError: null,
        ),
        isA<DownloadsResourceNoBackend>(),
      );
    });

    test('后端配了但不可用 → 透传后端自己给的原因，不退化成「请先配置」', () {
      final DownloadsResourceGap? gap = findDownloadsResourceGap(
        backendReady: true,
        managedSourceCount: 1,
        identityError: const VideoDownloadBackendUnavailable(
          videoDownloadEmbeddedBackendUnavailableMessage,
        ),
      );
      expect(gap, isA<DownloadsResourceNoBackend>());
      expect(
        (gap! as DownloadsResourceNoBackend).detail,
        videoDownloadEmbeddedBackendUnavailableMessage,
        reason: '用户已经配过后端了，只说「请先配置」等于没说；'
            '得把后端自己报的原因端到他面前。',
      );
    });

    test('身份解析抛的是别的异常 → 仍报缺后端，但不编造原因', () {
      final DownloadsResourceGap? gap = findDownloadsResourceGap(
        backendReady: true,
        managedSourceCount: 1,
        identityError: ArgumentError('qBittorrent address must not be empty'),
      );
      expect(gap, isA<DownloadsResourceNoBackend>());
      expect((gap! as DownloadsResourceNoBackend).detail, isNull);
    });

    test('尚未配置的缺后端不带 detail（由 UI 落到通用文案）', () {
      final DownloadsResourceGap? gap = findDownloadsResourceGap(
        backendReady: false,
        managedSourceCount: 0,
        identityError: null,
      );
      expect((gap! as DownloadsResourceNoBackend).detail, isNull);
    });
  });
}
