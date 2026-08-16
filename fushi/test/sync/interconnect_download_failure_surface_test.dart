import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/sync/interconnect_download_manager.dart';

import '../helpers/source_guard.dart';

/// BUG-1561：互联下载的失败态**只写进内存、永远不上屏**，且任务表只增不减。
///
/// - 失败出口：[InterconnectDownloadManager.startVideoDownload] 标 failed + 存错误后
///   rethrow，唯一的 UI 消费点（视频首页远端占位卡）却只读 `isRunning` / `progressFor`。
///   下载与页面生命周期解耦（这是它的设计目的），所以失败常发生在用户已离开该页之后，
///   `_downloadRemote` 的 `if (!mounted) return;` 把那条 SnackBar 吃掉 → 用户等半天
///   回来，看到的还是一张什么都没发生的占位卡。
/// - 生命周期：`clearTask` 生产零调用，completed/failed 任务在 Map 里永久占格。
///
/// 修法两头：卡片上给失败态一个恒定出口（[RemoteDownloadFailedBadge]，重进页面照样
/// 在，tooltip 带真实错误文本，再点一次下载即重试），以及结束态有界保留。
void main() {
  group('InterconnectDownloadManager 结束态生命周期', () {
    late Directory dir;
    late InterconnectDownloadManager manager;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('hibiki-dl-lifecycle');
      manager = InterconnectDownloadManager();
    });

    tearDown(() async {
      manager.dispose();
      if (dir.existsSync()) {
        try {
          dir.deleteSync(recursive: true);
        } catch (_) {}
      }
    });

    File dest(String name) => File('${dir.path}/$name');

    Future<void> runOk(String id) => manager.startVideoDownload(
          id: id,
          title: id,
          dest: dest('$id.mp4'),
          run: (File target,
              {void Function(double progress)? onProgress}) async {},
        );

    test('结束态有界保留：超过 maxFinishedTasks 的最旧任务被淘汰（不再只增不减）', () async {
      const int cap = InterconnectDownloadManager.maxFinishedTasks;
      for (int i = 0; i < cap + 5; i++) {
        await runOk('v$i');
      }
      expect(manager.tasks.length, cap, reason: '结束态必须有界；旧实现一次会话下载多少条就永久占多少格');
      // 最旧的 5 个被淘汰，最新的还在。
      expect(manager.taskFor('v0'), isNull);
      expect(manager.taskFor('v4'), isNull);
      expect(manager.taskFor('v5'), isNotNull);
      expect(manager.taskFor('v${cap + 4}'), isNotNull);
    });

    test('重跑同一个 id（用户重试）把上一轮的结束态顶掉，不占两格', () async {
      await expectLater(
        manager.startVideoDownload(
          id: 'v1',
          title: 'v1',
          dest: dest('v1.mp4'),
          run: (File target, {void Function(double progress)? onProgress}) =>
              throw const SocketException('reset'),
        ),
        throwsA(isA<SocketException>()),
      );
      expect(manager.taskFor('v1')!.status, InterconnectDownloadStatus.failed);

      await runOk('v1');
      expect(
          manager.taskFor('v1')!.status, InterconnectDownloadStatus.completed);
      expect(manager.tasks.length, 1);
    });

    test('running 任务永不被淘汰（状态槽不能悬空）', () async {
      const int cap = InterconnectDownloadManager.maxFinishedTasks;
      bool released = false;
      final Future<void> pending = manager.startVideoDownload(
        id: 'running',
        title: 'running',
        dest: dest('running.mp4'),
        run: (File target, {void Function(double progress)? onProgress}) async {
          while (!released) {
            await Future<void>.delayed(const Duration(milliseconds: 1));
          }
        },
      );
      for (int i = 0; i < cap + 5; i++) {
        await runOk('v$i');
      }
      expect(manager.isRunning('running'), isTrue,
          reason: '进行中的任务被淘汰会让占位卡的进度环凭空消失');
      released = true;
      await pending;
    });

    test('失败态存用户可读原因（BUG-1693：连接类错误 → 本地化文案，不上屏原始异常）', () async {
      await expectLater(
        manager.startVideoDownload(
          id: 'v1',
          title: 'v1',
          dest: dest('v1.mp4'),
          run: (File target, {void Function(double progress)? onProgress}) =>
              throw const SocketException('connection reset by peer'),
        ),
        throwsA(isA<SocketException>()),
      );
      final InterconnectDownloadTask task = manager.taskFor('v1')!;
      expect(task.status, InterconnectDownloadStatus.failed);
      // 角标 tooltip 的数据源：连接类失败给本地化网络文案，而不是
      // `SocketException: … errno = 1225` 这类开发者文本。
      expect(task.error, equals(t.sync_err_network));
      expect(task.error, isNot(contains('SocketException')));
    });

    test('未知错误保留原文（friendly 回落不吞信息）', () async {
      await expectLater(
        manager.startVideoDownload(
          id: 'v2',
          title: 'v2',
          dest: dest('v2.mp4'),
          run: (File target, {void Function(double progress)? onProgress}) =>
              throw StateError('weird custom failure'),
        ),
        throwsA(isA<StateError>()),
      );
      final InterconnectDownloadTask task = manager.taskFor('v2')!;
      expect(task.status, InterconnectDownloadStatus.failed);
      expect(task.error, contains('weird custom failure'));
    });
  });

  group('远端占位卡把失败态渲染出来', () {
    String pageSource() => File(
          'lib/src/pages/implementations/home_video_page.dart',
        ).readAsStringSync().replaceAll('\r\n', '\n');

    test('角标按任务状态分流：running → 进度环，failed → 失败角标', () {
      final String badge = methodBody(
        pageSource(),
        '  Widget? _remoteDownloadBadge(RemoteVideoInfo video, String safeKey)',
      );
      expect(
          containsCodeLine(badge, 'InterconnectDownloadStatus.failed'), isTrue,
          reason: '失败态不分流 = 失败永远没有卡片出口（旧实现只看 isRunning）');
      expect(containsIdentifierCall(badge, 'RemoteDownloadFailedBadge'), isTrue,
          reason: '失败角标是失败态唯一恒定的出口（SnackBar 会被 !mounted 吃掉）');
      expect(
          containsIdentifierCall(badge, 'RemoteDownloadProgressBadge'), isTrue,
          reason: '进行中仍要显示进度环');
      expect(containsCodeLine(badge, 'task.error'), isTrue,
          reason: 'tooltip 必须带真实错误文本，否则用户只知道「失败了」');
    });

    test('占位卡渲染的是这个分流后的角标，不是裸 isRunning 判据', () {
      final String card = methodBody(
        pageSource(),
        '  Widget _buildRemoteVideoCard(',
      );
      expect(containsIdentifierCall(card, '_remoteDownloadBadge'), isTrue);
      expect(
        RegExp(r'\.isRunning\(video\.id\)').hasMatch(maskComments(card)),
        isFalse,
        reason: '卡片直接读 isRunning 就等于把 failed 分支永久排除在渲染之外',
      );
    });
  });
}
