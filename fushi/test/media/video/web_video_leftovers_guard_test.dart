// 源码守卫（#3722 c29 遗留）：原生播放器页网页档的两处收尾。
//
// 1. YouTube 直裁成功要记视频制卡统计：内置网页播放器页的直裁、队列重放落卡、本页其它
//    制卡都记，只有这一条漏了，改走直裁的 YouTube 卡从统计里消失。
// 2. 进程死后换环境不释放旧的窗口宿主档环境：它是进程级缓存，别的页面（另一个原生
//    播放器页、窗口档网页播放器页）拿的是同一个对象，只是渲染进程死了时释放会把别人
//    正用着的环境拆掉。网页播放器页的恢复本来就不释放，两边同一判断。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../helpers/source_guard.dart';

void main() {
  test('原生页网页档 YouTube 直裁成功记视频制卡统计', () {
    final String src = File(
      'lib/src/pages/implementations/video_fushi/web_source.part.dart',
    ).readAsStringSync();
    final String body = maskComments(
      methodBody(src, 'Future<void> _mineWebYoutubeCue('),
    );
    // 发起时冻结库与归属，成功（非重复）分支记账。
    expect(body, contains('final FushiDatabase mineDb = appModel.database;'));
    expect(body, contains('_studyStatsIdentity'));
    // 结局按 `switch (res.result)` 分支：记账只能落在 `case 'success':` 里（排在
    // `case 'duplicate':` 之前），且整段只记一次——重复 / 失败分支都不记。
    const String record = '_recordVideoMineStat(mineDb, statIdentity)';
    final int success = body.indexOf("case 'success':");
    final int duplicate = body.indexOf("case 'duplicate':");
    final int recordAt = body.indexOf(record);
    expect(success, greaterThanOrEqualTo(0));
    expect(duplicate, greaterThan(success));
    expect(recordAt, greaterThan(success), reason: '只在新制成功分支记账');
    expect(recordAt, lessThan(duplicate), reason: '只在新制成功分支记账');
    expect(body.lastIndexOf(record), recordAt, reason: '重复 / 失败分支不记账');
  });

  test('原生页播放器层进程死后不释放共享的窗口宿主档环境', () {
    final String src = File(
      'lib/src/media/video/web_video_session.dart',
    ).readAsStringSync();
    final String body = maskComments(
      methodBody(src, 'Future<void> recoverFromProcessGone()'),
    );
    expect(body, contains('discardWebVideoWindowedEnvironment()'));
    expect(body, isNot(contains('.dispose(')));
  });
}
