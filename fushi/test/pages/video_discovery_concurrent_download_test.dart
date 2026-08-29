import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/video/discovery/video_discovery_provider.dart';
import 'package:fushi/src/media/video/metadata/video_metadata_models.dart';
import 'package:fushi/src/pages/implementations/video_discovery_detail_page.dart';

/// 用户反馈：「感觉下的源不对劲，想再下一个，但是下不了，只能取消或者等下载结束…
/// 完成的不影响，还可以下，但是下载中的不行」。
///
/// 队列层**从来没有** per-series 并发限制（enqueue 不查重、claimNextVideoDownloadJob
/// 无 per-series 谓词、唯一去重门是「同后端指纹 + 同 info hash」即同一个种子），
/// 「下不了」纯粹是作品页那颗按钮的 `|| state.isBusy` 造出来的死局；而作品页此前
/// **连取消入口都没有**（唯一的取消按钮在下载任务面板里）。
VideoDiscoveryItem _item() {
  return VideoDiscoveryItem(
    reference: VideoMediaReference(
      providerId: 'tmdb',
      mediaId: '100',
      mediaKind: VideoMetadataMediaKind.tv,
      discoveryCategory: VideoDiscoveryCategory.tv,
      title: '薬屋のひとりごと',
      originalTitle: '薬屋のひとりごと',
      year: 2023,
    ),
    overview: '简介。',
    score: 8.8,
    genres: const <String>['番剧'],
  );
}

Widget _harness(VideoDiscoveryDetailPage page) {
  return TranslationProvider(
    child: MaterialApp(
      theme: ThemeData.dark(useMaterial3: true),
      home: page,
    ),
  );
}

VideoDiscoveryActions _actions({
  required VideoDiscoveryAcquisitionState state,
  void Function()? onSearchResource,
  Future<void> Function(List<String>)? onCancelDownloads,
  VoidCallback? onOpenDownloads,
}) {
  return VideoDiscoveryActions(
    loadDetails: (_) async => VideoDiscoveryDetailData(
      item: _item(),
      facts: const <VideoDiscoveryFact>[],
      people: const <VideoDiscoveryPerson>[],
    ),
    watchStatus: (_) => Stream<VideoDiscoveryAcquisitionState>.value(state),
    onSearchResource: (_, __) async => onSearchResource?.call(),
    onSearchSubtitle: (_, __) async {},
    onSubscribe: (_, __) async {},
    onCancelDownloads: onCancelDownloads,
    onOpenDownloads: onOpenDownloads,
  );
}

/// 让 loadDetails / watchStatus 两个 Future/Stream 落地，但**不等动画停**。
///
/// busy 态渲染的是无限旋转的 CircularProgressIndicator，帧永远不会停，
/// `pumpAndSettle` 必然超时。
Future<void> settle(WidgetTester tester) async {
  for (int i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

void main() {
  setUp(() => LocaleSettings.setLocale(AppLocale.zhCn));

  Future<void> pump(
    WidgetTester tester,
    VideoDiscoveryActions actions,
  ) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      _harness(VideoDiscoveryDetailPage(item: _item(), actions: actions)),
    );
    // 不能用 pumpAndSettle：busy 态渲染的是**无限旋转**的
    // CircularProgressIndicator，帧永远不会停，pumpAndSettle 必然超时。
    await settle(tester);
  }

  testWidgets('下载进行中仍然可以再搜一次资源（换源重下）', (WidgetTester tester) async {
    bool searched = false;
    await pump(
      tester,
      _actions(
        state: const VideoDiscoveryAcquisitionState(
          statusLabel: '下载中',
          isBusy: true,
          activeJobIds: <String>['job-1'],
        ),
        onSearchResource: () => searched = true,
      ),
    );

    final Finder button =
        find.byKey(const ValueKey<String>('video-discovery-search-resource'));
    expect(button, findsOneWidget);
    // key 就挂在 OutlinedButton.icon 产出的 OutlinedButton 上（不是它的祖先）。
    expect(tester.widget<OutlinedButton>(button).onPressed, isNotNull,
        reason: '下载进行中这颗按钮必须是 enabled 的。');

    await tester.tap(button);
    await settle(tester);
    expect(searched, isTrue,
        reason: '这是本次修复的核心：按钮此前在 isBusy 时被 disable，'
            '而队列层根本没有 per-series 限制。');
  });

  testWidgets('下载进行中出现取消入口，点击带走全部在飞任务 id', (WidgetTester tester) async {
    List<String>? cancelled;
    await pump(
      tester,
      _actions(
        state: const VideoDiscoveryAcquisitionState(
          statusLabel: '下载中',
          isBusy: true,
          activeJobIds: <String>['job-1', 'job-2'],
        ),
        onCancelDownloads: (List<String> ids) async => cancelled = ids,
      ),
    );

    final Finder cancel =
        find.byKey(const ValueKey<String>('video-discovery-cancel-download'));
    expect(cancel, findsOneWidget, reason: '作品页此前没有任何取消入口，用户得自己翻到下载页去停。');

    await tester.tap(cancel);
    await settle(tester);
    expect(cancelled, <String>['job-1', 'job-2'],
        reason: '同一部作品可以并存多条下载，取消要一次带走全部在飞的。');
  });

  testWidgets('没在下载时不渲染取消 / 查看任务', (WidgetTester tester) async {
    await pump(
      tester,
      _actions(
        state: const VideoDiscoveryAcquisitionState(isInLibrary: true),
        onCancelDownloads: (_) async {},
        onOpenDownloads: () {},
      ),
    );

    expect(
        find.byKey(const ValueKey<String>('video-discovery-cancel-download')),
        findsNothing);
    expect(
        find.byKey(const ValueKey<String>('video-discovery-detail-downloads')),
        findsNothing);
  });

  testWidgets('isBusy 但拿不到任务 id 时不渲染取消（按下去无事可取消）', (WidgetTester tester) async {
    await pump(
      tester,
      _actions(
        state: const VideoDiscoveryAcquisitionState(
          statusLabel: '下载中',
          isBusy: true,
        ),
        onCancelDownloads: (_) async {},
      ),
    );

    expect(
        find.byKey(const ValueKey<String>('video-discovery-cancel-download')),
        findsNothing);
  });

  testWidgets('未接取消端口时不渲染取消按钮', (WidgetTester tester) async {
    await pump(
      tester,
      _actions(
        state: const VideoDiscoveryAcquisitionState(
          isBusy: true,
          activeJobIds: <String>['job-1'],
        ),
      ),
    );

    expect(
        find.byKey(const ValueKey<String>('video-discovery-cancel-download')),
        findsNothing);
  });

  testWidgets('窄窗（360dp 下限）下操作行不溢出', (WidgetTester tester) async {
    // 状态文案本身就在抢宽度，取消 / 查看任务并排塞进同一个 Row 必然溢出；
    // 它们住在单独一行的 Wrap 里。测试字体是 Ahem（每字符 = 字号宽），比真机更宽，
    // 这里过了真机就一定过。
    tester.view.physicalSize = const Size(360, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      _harness(
        VideoDiscoveryDetailPage(
          item: _item(),
          actions: _actions(
            state: const VideoDiscoveryAcquisitionState(
              statusLabel: '下载中 · 整理文件',
              isBusy: true,
              activeJobIds: <String>['job-1'],
            ),
            onCancelDownloads: (_) async {},
            onOpenDownloads: () {},
          ),
        ),
      ),
    );
    await settle(tester);

    expect(tester.takeException(), isNull);
    expect(
        find.byKey(const ValueKey<String>('video-discovery-cancel-download')),
        findsOneWidget);
  });

  group('home_page 侧的「在飞」判定', () {
    test('busy 取「任意一条 active」，不是排序后第一条', () {
      final String source = File('lib/src/pages/implementations/home_page.dart')
          .readAsStringSync();
      // 锚点必须是**定义**：文件里先出现的是 emit() 里的调用点，从那里取窗口
      // 只会读到一段无关代码，断言恒假。
      final int at = source.indexOf(
          'Future<VideoDiscoveryAcquisitionState> _readVideoDiscoveryStatus(');
      expect(at, isNonNegative);
      final String body = source.substring(at, at + 2200);

      expect(body, contains('activeJobs.isNotEmpty'),
          reason: '排序是 priority DESC, createdAt DESC —— 新提交的那条一旦完成，'
              '仍在跑的旧任务就会被判成「不忙」，取消入口跟着消失。');
      expect(
          body.contains('job?.lifecycle == VideoDownloadJobLifecycle.active'),
          isFalse,
          reason: '旧的单条判定必须真的被替换掉，而不是留着并存。');
      expect(body, contains('activeJobIds:'),
          reason: '取消需要知道取消哪几条，聚合成一个 bool 不够。');
    });

    test('取消必须先弹确认，且一条都没取消掉要说话', () {
      final String source = maskComments(
          File('lib/src/pages/implementations/home_page.dart')
              .readAsStringSync());
      final String body = methodBody(
        source,
        'Future<void> _cancelVideoDiscoveryDownloads(List<String> jobIds) async',
      );

      // 一颗按钮停掉**该作品全部**在飞任务，而这个入口的动机场景恰恰是「A 下错了
      // 再下 B」—— 不确认就点等于把 A 和 B 一起干掉。
      final int confirmAt = body.indexOf('FushiDestructiveConfirmDialog(');
      final int loopAt = body.indexOf('for (final String jobId in jobIds)');
      expect(confirmAt, isNonNegative, reason: '取消必须先确认');
      expect(loopAt, greaterThan(confirmAt),
          reason: '确认必须排在真正调 cancelJob 之前');
      expect(body, contains('if (confirmed == null) return;'),
          reason: '用户取消对话框就得真的不动手');

      // cancelJob 在 backendTaskId 还没落库、或后端解析不出来时会失败，而 UI 这边
      // 什么都不变 —— 用户只看到「点了没反应，还在下」。
      expect(body, contains('cancelled == 0'),
          reason: '一条都没取消掉必须给提示，不能只 debugPrint');
      expect(body, contains('video_discovery_cancel_downloads_failed'));
      expect(body, isNot(contains('debugPrint(')),
          reason: '失败要进 ErrorLogService，不是 debugPrint 吞掉');
    });
  });
}
