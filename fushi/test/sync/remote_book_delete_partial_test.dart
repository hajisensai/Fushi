import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';

/// BUG-1565：删除远端书是**两次**远端调用（书 + 有声书），旧实现只有一个 `failed`
/// 布尔。书删成功、有声书删失败时它弹「无法在对端设备上删除」并直接 return 不刷新
/// 列表 —— 两句都与实情相反：书其实已经从 host 消失了，不刷新就留一张点了必 404 的
/// 幽灵卡，而提示语还告诉用户「没删掉」。
///
/// 修法：分别记账 `bookDeleted` / `audiobookFailed`，书删掉了就刷新（哪怕有声书没
/// 删掉），并用专门的部分成功文案说清「书已删、有声书未删」。
void main() {
  String remoteSource() => File(
        'lib/src/pages/implementations/reader_history/remote.part.dart',
      ).readAsStringSync().replaceAll('\r\n', '\n');

  test('半成功也刷新列表：书删掉了就不能留幽灵卡', () {
    final String body = methodBody(
      remoteSource(),
      '  Future<void> _confirmDeleteRemoteBook(',
    );
    expect(containsCodeLine(body, 'bookDeleted = true'), isTrue,
        reason: '两次远端调用必须分别记账，单个 failed 布尔表达不了半成功');
    final String masked = maskComments(body);
    expect(
      RegExp(r'if \(bookDeleted\) _forceRefreshRemoteBooks\(\);')
          .hasMatch(masked),
      isTrue,
      reason: '书已删就必须刷新列表，否则原地留一张点了必 404 的幽灵卡',
    );
    final int refreshAt = masked.indexOf('_forceRefreshRemoteBooks()');
    final int failMsgAt = masked.indexOf('t.remote_delete_failed');
    expect(refreshAt, isNonNegative);
    expect(failMsgAt, isNonNegative);
    expect(refreshAt, lessThan(failMsgAt),
        reason: '刷新必须发生在失败早退之前，否则半成功路径又不刷新了');
  });

  test('提示语区分「书没删掉」与「书已删、有声书未删」', () {
    final String body = methodBody(
      remoteSource(),
      '  Future<void> _confirmDeleteRemoteBook(',
    );
    expect(containsCodeLine(body, 't.remote_delete_audiobook_partial'), isTrue,
        reason: '半成功必须有自己的文案；沿用「删除失败」与实情相反');
    expect(containsCodeLine(body, 'if (!bookDeleted)'), isTrue,
        reason: '「删除失败」只能留给书本身没删掉的情形');
  });

  test('部分成功文案在 17 个语言文件里齐全（Slang 缺 key 直接编译失败）', () {
    int seen = 0;
    for (final FileSystemEntity f in Directory('lib/i18n').listSync()) {
      if (f is! File || !f.path.endsWith('.i18n.json')) continue;
      final Map<String, dynamic> map =
          jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
      expect(map.containsKey('remote_delete_audiobook_partial'), isTrue,
          reason: '${f.path} 缺 remote_delete_audiobook_partial');
      seen++;
    }
    expect(seen, 17);
  });
}
