// TODO-2482：用户暂停集跨会话持久（宿主落盘 <resumeDir>/user_paused.json）。
//
// 这里守的是纯文件契约（读写往返 / 坏文件容错 / 大小写归一 / 原子写不留
// tmp），不依赖原生 DLL —— 与 pruneResumeFiles 的守卫同姿态：宿主行为层
// 的用例要 DLL 在 CI 恒 skip，持久化契约必须有任何环境都会跑的用例守着。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/torrent/embedded_torrent_host.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('ht_paused_');
  });

  tearDown(() {
    try {
      tempDir.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows 偶发句柄未释放；留给系统清理。
    }
  });

  test('写读往返：集合原样回来（含大小写归一为小写）', () {
    writeUserPausedFile(tempDir.path, <String>{'AABB01', 'ccdd02'});
    expect(readUserPausedFile(tempDir.path), <String>{'aabb01', 'ccdd02'});
  });

  test('文件不存在返回空集（首次运行不是错误）', () {
    expect(readUserPausedFile(tempDir.path), isEmpty);
  });

  test('坏 JSON 返回空集而不是抛（暂停态丢失可接受，崩溃不可接受）', () {
    File(p.join(tempDir.path, kUserPausedFileName))
        .writeAsStringSync('{not json');
    expect(readUserPausedFile(tempDir.path), isEmpty);
  });

  test('JSON 是对象而非数组时同样空集', () {
    File(p.join(tempDir.path, kUserPausedFileName))
        .writeAsStringSync('{"a":1}');
    expect(readUserPausedFile(tempDir.path), isEmpty);
  });

  test('数组里的非字符串/空串条目被丢弃', () {
    File(p.join(tempDir.path, kUserPausedFileName))
        .writeAsStringSync('["aa", 42, "", null, "BB"]');
    expect(readUserPausedFile(tempDir.path), <String>{'aa', 'bb'});
  });

  test('覆盖写：新集合完全替换旧集合，且不留 .tmp 半成品', () {
    writeUserPausedFile(tempDir.path, <String>{'aa'});
    writeUserPausedFile(tempDir.path, <String>{'bb'});
    expect(readUserPausedFile(tempDir.path), <String>{'bb'});
    expect(
      tempDir
          .listSync()
          .whereType<File>()
          .where((File f) => f.path.endsWith('.tmp')),
      isEmpty,
    );
  });

  test('resumeDir 不存在时写入自动建目录', () {
    final String nested = p.join(tempDir.path, 'not', 'yet');
    writeUserPausedFile(nested, <String>{'aa'});
    expect(readUserPausedFile(nested), <String>{'aa'});
  });

  group('retainUserPausedRecords（TODO-2526：重启恢复时的记录去留判据）', () {
    test('瞬时加载失败但 .resume 还在 → 记录保留；文件已不存在 → 剪', () {
      // aa：加载成功；bb：加载失败但 .resume 在盘上（瞬时失败）；
      // cc：加载失败且文件已不存在（计划已删，真无主）。
      File(p.join(tempDir.path, 'aa.resume')).writeAsStringSync('x');
      File(p.join(tempDir.path, 'bb.resume')).writeAsStringSync('x');
      final Set<String> keep = retainUserPausedRecords(
        resumeDir: tempDir.path,
        wanted: <String>{'aa', 'bb', 'cc'},
        restoredIds: <String>['aa'],
      );
      expect(keep, <String>{'aa', 'bb'},
          reason: 'bb 的 .resume 还在 —— 剪掉它，下次成功加载就会以跑态复活，'
              '用户按过的暂停凭空消失');
    });

    test('加载成功的记录保留，不依赖 .resume 文件是否存在', () {
      // 极端时序：加载成功后文件被剪 —— in-session 是更强的存活证据。
      final Set<String> keep = retainUserPausedRecords(
        resumeDir: tempDir.path,
        wanted: <String>{'aa'},
        restoredIds: <String>['aa'],
      );
      expect(keep, <String>{'aa'});
    });

    test('restoredIds 大小写归一（infohash 大小写只是书写差异）', () {
      final Set<String> keep = retainUserPausedRecords(
        resumeDir: tempDir.path,
        wanted: <String>{'aabb01'},
        restoredIds: <String>['AABB01'],
      );
      expect(keep, <String>{'aabb01'});
    });

    test('resume 目录不存在：只有本轮加载成功的保留', () {
      final Set<String> keep = retainUserPausedRecords(
        resumeDir: p.join(tempDir.path, 'nope'),
        wanted: <String>{'aa', 'bb'},
        restoredIds: <String>['bb'],
      );
      expect(keep, <String>{'bb'});
    });
  });
}
