import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-1928 · 远端卡的删除确认不能谎称「本地数据保留」。
///
/// `sync_compare_delete_confirm`（"…Local data is kept…"）服务了两个真值相反的语境：
///
///  * 云盘/备份的**比较对话框**：本机通常确实还有一份，那里这句话是真话、有信息量；
///  * 互联对端的**远端卡**：这张卡按构造就是「本机没有的条目」——`dedupeRemoteBooks`
///    把标题键已存在于本地的远端条目全部滤掉了。所以「本地数据保留」保留的是空集，
///    读起来却像「删了本机还留着一份」，而实际确认之后对端的 DB 行、阅读进度、书签、
///    有声书和整个 extractDir 页图目录全没了，用户手上一份都不剩。
///
/// 修法是给远端卡另起两个说实话的 key（书和视频删的东西还不一样：书连页图目录一起删，
/// 视频保留对端自己导入的原始文件），而**不是**改老 key 的值——那会把比较对话框里的
/// 真话一起污染掉。这条守卫钉住这个分工。
String _codeOnly(String src) => src
    .split('\n')
    .map((String line) => line.trimLeft().startsWith('//') ? '' : line)
    .join('\n');

void main() {
  String read(String path) =>
      _codeOnly(File(path).readAsStringSync().replaceAll('\r\n', '\n'));

  Map<String, dynamic> locale(String suffix) => jsonDecode(
        File('lib/i18n/strings$suffix.i18n.json').readAsStringSync(),
      ) as Map<String, dynamic>;

  test('远端书卡与远端视频卡各用自己的对端文案', () {
    final String remote =
        read('lib/src/pages/implementations/reader_history/remote.part.dart');
    expect(remote, contains('t.sync_peer_book_delete_confirm(name: name)'));
    expect(remote, isNot(contains('sync_compare_delete_confirm')),
        reason: '远端书卡下「本地数据保留」保留的是空集，是反向暗示。');

    final String video =
        read('lib/src/pages/implementations/home_video_page.dart');
    expect(video, contains('t.sync_peer_video_delete_confirm('));
    expect(video, isNot(contains('sync_compare_delete_confirm')));
  });

  test('比较对话框保留老文案（那里「本地数据保留」是真话）', () {
    expect(read('lib/src/sync/sync_compare_dialog.dart'),
        contains('t.sync_compare_delete_confirm(name: name)'),
        reason: '别为了修远端卡把这里的真话一起改掉。');
  });

  test('对端文案里不得再出现「本地数据保留」', () {
    for (final String suffix in <String>['', '_zh-CN', '_zh-HK']) {
      final Map<String, dynamic> table = locale(suffix);
      for (final String key in <String>[
        'sync_peer_book_delete_confirm',
        'sync_peer_video_delete_confirm',
      ]) {
        final String value = table[key] as String;
        expect(value.contains('Local data is kept'), isFalse,
            reason: '$key ($suffix)');
        expect(value.contains('本地数据保留'), isFalse, reason: '$key ($suffix)');
        expect(value.contains('本機資料會保留'), isFalse, reason: '$key ($suffix)');
      }
    }
  });
}
