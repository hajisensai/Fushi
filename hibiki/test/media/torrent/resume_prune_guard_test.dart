// TODO-1961-a 审查修复：resume 剪枝的**数据销毁级**启动竞态守卫。
//
// 竞态长什么样（PR#437 原实现）：
//   startAnimeDownloadService()
//     ├─ AnimeDownloadService(..)..start()            ← 立刻 unawaited(tick())
//     │    └─ _torrentBackendFor → _ensureEmbeddedTorrentHost()
//     │         └─ EmbeddedTorrentHost.open(restoreIds: _animeDownloadPlanIds)
//     │              └─ restoreFromResume({}) → 剪枝 keepIds = 空集合
//     │                   └─ **删光 resume 目录里所有 .resume**
//     └─ await _restoreEmbeddedTorrentSession(store)  ← 计划 id 到这里才加载
// 结果：目标功能（重启后续传/继续做种）被反向实现成一次静默的数据销毁 ——
// 用户所有下载中/做种中的任务在下一次启动全部蒸发，UI 上无声无息。
//
// 两道防线，本文件两组都守：
//   ① 顺序：service `..start()` 之前必须 await 一次计划 id 加载。
//   ② 哨兵：`keepIds == null`（尚未加载）时 [pruneResumeFiles] 拒绝执行，
//      且必须与「真的一个计划都没有」（空集合 → 合法全删）区分得开。
//
// 行为层用例走顶层 [pruneResumeFiles] 而不是 EmbeddedTorrentHost：host 的每个
// 方法都要真 DLL（`FUSHI_TORRENT_LIB`），在 CI 上永远 skip，守不住任何东西。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/torrent/embedded_torrent_host.dart';
import 'package:path/path.dart' as p;

String _read(String relPath) => File(relPath).readAsStringSync();

void main() {
  group('resume 剪枝：计划 id 未加载时绝不删文件', () {
    late Directory tempDir;
    late String resumeDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('hibiki_resume_prune');
      resumeDir = p.join(tempDir.path, 'resume');
      Directory(resumeDir).createSync(recursive: true);
      for (final String id in <String>['aaaa1111', 'bbbb2222', 'cccc3333']) {
        File(p.join(resumeDir, '$id.resume')).writeAsStringSync('d1:xe');
      }
      File(p.join(resumeDir, 'notes.txt')).writeAsStringSync('unrelated');
    });

    tearDown(() {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });

    List<String> resumeNames() => Directory(resumeDir)
        .listSync()
        .whereType<File>()
        .map((File f) => p.basename(f.path))
        .where((String n) => n.endsWith('.resume'))
        .toList()
      ..sort();

    test('keepIds == null（尚未加载）→ 拒绝剪枝，一个文件都不许删', () {
      expect(
        pruneResumeFiles(resumeDir: resumeDir, keepIds: null),
        -1,
        reason: '哨兵路径必须有独立返回值，不能和「删了 0 个」混为一谈',
      );
      expect(
        resumeNames(),
        <String>['aaaa1111.resume', 'bbbb2222.resume', 'cccc3333.resume'],
        reason: '计划 id 未加载时剪枝 = 删光用户所有下载/做种任务，'
            '这是数据销毁，不是「清理」',
      );
    });

    test('keepIds == 空集合（真的没有计划）→ 合法全删，与哨兵区分得开', () {
      expect(
          pruneResumeFiles(resumeDir: resumeDir, keepIds: const <String>{}), 3);
      expect(resumeNames(), isEmpty);
      // 非 .resume 文件不碰。
      expect(File(p.join(resumeDir, 'notes.txt')).existsSync(), isTrue);
    });

    test('keepIds 有值 → 只删无主的；keepIds 的大小写不影响判定', () {
      expect(
        pruneResumeFiles(
            resumeDir: resumeDir, keepIds: <String>{'AAAA1111', 'cccc3333'}),
        1,
      );
      expect(resumeNames(), <String>['aaaa1111.resume', 'cccc3333.resume']);
    });

    test('目录不存在：null 仍拒绝、非 null 是无害 no-op', () {
      final String missing = p.join(tempDir.path, 'no-such-resume');
      expect(pruneResumeFiles(resumeDir: missing, keepIds: null), -1);
      expect(
          pruneResumeFiles(resumeDir: missing, keepIds: const <String>{}), 0);
    });
  });

  group('resume 剪枝：启动顺序源码守卫', () {
    late String appModel;
    late String host;

    setUpAll(() {
      appModel = _read('lib/src/models/app_model.dart');
      host = _read('lib/src/media/torrent/embedded_torrent_host.dart');
    });

    test('计划 id 集合是可空哨兵，不许退化成 const {}', () {
      expect(appModel.contains('Set<String>? _animeDownloadPlanIds;'), isTrue,
          reason: '空集合初值 = 「没有任何计划」，会让第一次剪枝删光 resume');
      expect(
          appModel.contains('Set<String> _animeDownloadPlanIds = const'), false,
          reason: '回归：哨兵被改回空集合初值');
    });

    test('startAnimeDownloadService 必须先 await 计划 id 再 start service', () {
      final int start =
          appModel.indexOf('Future<void> startAnimeDownloadService()');
      expect(start, greaterThanOrEqualTo(0));
      final int end = appModel.indexOf('\n  }', start);
      final String body = appModel.substring(start, end > start ? end : start);

      // needle 用赋值形式：方法名 `startAnimeDownloadService()` 自身就含子串
      // `AnimeDownloadService(`，直接找会命中函数签名（永远在最前面）。
      final int refresh = body.indexOf('await _refreshAnimeDownloadPlanIds(');
      final int service =
          body.indexOf('_animeDownloadService = AnimeDownloadService(');
      final int subscription = body.indexOf(
          '_animeDownloadSubscriptionService = AnimeDownloadSubscriptionService(');
      expect(refresh, greaterThanOrEqualTo(0),
          reason: '启动路径必须 await 一次计划 id 加载');
      expect(service, greaterThanOrEqualTo(0));
      expect(subscription, greaterThanOrEqualTo(0));
      expect(refresh, lessThan(service),
          reason: 'AnimeDownloadService..start() 会立刻 tick → 懒建 host → 剪枝；'
              '计划 id 必须在它之前就位');
      expect(refresh, lessThan(subscription), reason: '订阅服务同样会 tick → 懒建 host');
    });

    test('剪枝/恢复/保存的 keepIds 一律可空（哨兵能穿到底）', () {
      expect(host.contains('required Set<String>? keepIds,'), isTrue);
      expect(
          host.contains('int restoreFromResume(Set<String>? keepIds)'), true);
      expect(
          host.contains(
              'int? saveResumeSnapshot(Set<String>? keepIds, {bool force = false})'),
          isTrue);
      expect(host.contains('void dispose({Set<String>? keepIds})'), isTrue,
          reason: 'dispose 的 keepIds 默认值若是空集合，退出时同样会删光 resume');
      expect(host.contains('Set<String> restoreIds = const <String>{}'), false,
          reason: '回归：open 的 restoreIds 默认空集合 = 竞态里删光 resume');
    });

    test('保存/剪枝失败必须留痕，不许静默吞', () {
      final int i = host.indexOf('int? saveResumeSnapshot(');
      expect(i, greaterThanOrEqualTo(0));
      final int end = host.indexOf('\n  }', i);
      final String body = host.substring(i, end > i ? end : i + 2500);
      expect(body.contains('debugPrint('), isTrue,
          reason: 'resume 长期写不进去 = 重启后所有下载蒸发，必须可见');
      expect(body.contains('} on Object {'), isFalse,
          reason: '回归：裸 `on Object { return 0; }` 把 native 的 '
              'failed/timed_out 全吞了');
    });
  });
}
