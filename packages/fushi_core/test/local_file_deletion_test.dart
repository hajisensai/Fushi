/// 删除用户本机原件的共用原语：删的范围、以及**删除失败必须逐条回传**。
///
/// 失败回传是这条链路里最要紧的契约：最常见的真实失败是「这个文件正在播放」，
/// Windows 上句柄被占用 `File.delete()` 直接 errno 32。以前这类失败只走
/// `debugPrint`（release 里被剥掉）、返回值被调用方全部丢弃，用户看到「删除成功」，
/// 回头发现盘上一个文件没少。
library;

import 'dart:io';

import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory tmp;
  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('fushi-core-del-');
  });
  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  test('删文件、跳目录、跳不存在的路径', () async {
    final File a = File(p.join(tmp.path, 'a.mp3'))..writeAsStringSync('a');
    final Directory d = Directory(p.join(tmp.path, 'dir'))..createSync();
    final String missing = p.join(tmp.path, 'nope.mp3');

    final LocalFileDeleteReport report = await deleteLocalFiles(<String>[
      a.path,
      d.path,
      missing,
    ]);

    expect(report.removed, <String>[a.path]);
    expect(report.failures, isEmpty, reason: '本来就不存在的路径不是失败');
    expect(a.existsSync(), isFalse);
    expect(d.existsSync(), isTrue, reason: '目录绝不删，更不递归删');
  });

  test('文件被占用（Windows 句柄）→ 记进 failures，不抛、不中断后续', () async {
    final File held = File(p.join(tmp.path, 'held.mp3'))
      ..writeAsStringSync('held');
    final File other = File(p.join(tmp.path, 'other.mp3'))
      ..writeAsStringSync('other');
    // 真正握住句柄：Windows 上这会让 delete 抛 errno 32，正是用户「正在播放这一
    // 本」时的形态。
    final RandomAccessFile handle = await held.open(mode: FileMode.append);
    try {
      final LocalFileDeleteReport report = await deleteLocalFiles(<String>[
        held.path,
        other.path,
      ]);
      expect(
        report.failures.map((LocalFileDeleteFailure f) => f.path),
        <String>[held.path],
      );
      expect(report.failures.single.error, isNotNull);
      expect(held.existsSync(), isTrue);
      expect(
        report.removed,
        <String>[other.path],
        reason: '一个文件失败不能翻转其它文件的结果',
      );
      expect(other.existsSync(), isFalse);
    } finally {
      await handle.close();
    }
  }, skip: !Platform.isWindows ? 'POSIX 允许删除仍被打开的文件' : null);

  test('merge 把两次删除的结果并起来（一条记录可能挂两份原件）', () {
    const LocalFileDeleteReport a = LocalFileDeleteReport(
      removed: <String>['/a'],
    );
    const LocalFileDeleteReport b = LocalFileDeleteReport(
      removed: <String>['/b'],
      failures: <LocalFileDeleteFailure>[LocalFileDeleteFailure('/c', 'boom')],
    );
    final LocalFileDeleteReport merged = a.merge(b);
    expect(merged.removed, <String>['/a', '/b']);
    expect(merged.failures, hasLength(1));
    expect(const LocalFileDeleteReport().isEmpty, isTrue);
  });

  group('platformPathKey', () {
    test('绝对化 + 规范化：相对路径按 cwd 展开、冗余段消掉', () {
      expect(platformPathKey('a/../b.mkv'), platformPathKey('b.mkv'));
      expect(p.isAbsolute(platformPathKey('b.mkv')), isTrue);
    });

    test('Windows 折大小写，大小写敏感平台不折', () {
      final String lower = platformPathKey(p.join(tmp.path, 'case.mkv'));
      final String upper = platformPathKey(p.join(tmp.path, 'CASE.mkv'));
      if (Platform.isWindows) {
        expect(lower, upper);
        expect(isSamePathIdentity(r'D:\a\b.mkv', r'd:\A\B.MKV'), isTrue);
      } else {
        expect(lower, isNot(upper));
      }
    });
  });
}
