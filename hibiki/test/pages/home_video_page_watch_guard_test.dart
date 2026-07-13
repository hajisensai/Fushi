import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-791 source-scan guard：视频库页（[HomeVideoPage]）的列表是一次性
/// `FutureBuilder` + 保活 tab，对 `videoBooks` 表变更零自动感知；非本页发起的
/// 导入路径（外部「用 Hibiki 打开」直接落库、远端下载等）落库后不 `_refresh()`，
/// 用户要下拉刷新/重启才看得到新导入的视频。
///
/// 根因修复：库页在 `initState` 订阅 [VideoBookRepository.watchVideoBookUids]（Drift
/// `.watch()`），任意导入路径落库后自动刷新，并在 `dispose` 取消订阅防泄漏。
///
/// 真机自动刷新行为跑在完整页面 + DB 上（widget 层难落地稳定断言），故这里守
/// *接线机制*：若库页不再订阅该流，或漏了取消订阅，本测试转红——提醒回归者
/// 视频库将退回「导入不自动出现」。DB 流本身的行为由
/// `test/database/video_books_test.dart` 的 `watchVideoBookUids` 组守。
void main() {
  // Tests run with CWD = `hibiki/`.
  final File page = File('lib/src/pages/implementations/home_video_page.dart');

  test('home_video_page.dart exists', () {
    expect(page.existsSync(), isTrue);
  });

  test('HomeVideoPage subscribes to watchVideoBookUids in initState', () {
    final String src = page.readAsStringSync();
    expect(
      src.contains('watchVideoBookUids().listen'),
      isTrue,
      reason: 'BUG-791：库页必须订阅 videoBooks 表，才能在任意导入路径落库后自动刷新',
    );
  });

  test('HomeVideoPage cancels the subscription in dispose', () {
    final String src = page.readAsStringSync();
    expect(
      src.contains('_videoUidsSub?.cancel()'),
      isTrue,
      reason: 'BUG-791：dispose 必须取消 videoBooks 订阅，防止 StreamSubscription 泄漏',
    );
  });
}
