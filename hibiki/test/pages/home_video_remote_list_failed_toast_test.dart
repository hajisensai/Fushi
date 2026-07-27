import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/i18n/strings.g.dart';

/// BUG-811 回归守卫：下拉刷新时远端清单拉取失败，用户可见的 toast 必须是**本地化
/// 友好文案**，绝不泄漏原始异常（`TimeoutException after 0:00:15.000000: Future not
/// completed` 等开发者文本）进 UI。
///
/// 根因：`home_video_page._pullToRefresh`（`t.remote_video_list_failed(error:
/// state.errorMessage ?? '')`）把 catch 里的 `e.toString()` 直接拼进 toast，异常源自
/// `InterconnectSyncBackend.listRemoteVideos()` 对 `GET /api/library/videos` 的
/// `.timeout(listTimeout=15s)`。修复：i18n key 改成无参自包含友好文案，toast 调用点去
/// `error:` 参数，删掉承载异常的 `_RemoteVideoState.errorMessage` 死字段，原始异常只
/// 留 `debugPrint`。
///
/// 用**确定性守卫**（无 widget 树、无定时器）——本仓库 HomeVideoPage widget 测试在
/// 无 GUI 环境有既有的 teardown 定时器伪影，源码/生成物级守卫更可落地、更稳。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => LocaleSettings.setLocale(AppLocale.zhCn));

  test('remote_video_list_failed 是无参自包含友好文案，不含异常占位/开发者文本', () {
    // 无参 getter（改成带 error 参数的方法就编译不过 → 这行本身就是签名守卫）。
    final String msg = t.remote_video_list_failed;
    expect(msg.trim(), isNotEmpty);
    // 不再带 $error 之类插值占位。
    expect(msg.contains(r'$'), isFalse);
    // 绝不含原始异常文本形态。
    expect(msg.contains('Exception'), isFalse);
    expect(msg.contains('Future not completed'), isFalse);
    expect(msg.contains('0:00:15'), isFalse);
  });

  test('home_video_page 失败 toast 不再把异常拼进用户可见文案', () {
    final String src = File(
      'lib/src/pages/implementations/home_video_page.dart',
    ).readAsStringSync();
    // 旧写法 t.remote_video_list_failed(error: state.errorMessage ?? '') 必须消失。
    expect(src.contains('remote_video_list_failed(error:'), isFalse,
        reason: '失败 toast 不得再向 remote_video_list_failed 传 error 参数');
    // 用户可见 toast 走无参 getter。
    expect(src.contains('Text(t.remote_video_list_failed)'), isTrue);
    // 承载原始异常的死字段随异常泄漏一并删除。
    expect(src.contains('errorMessage'), isFalse,
        reason: '_RemoteVideoState.errorMessage 死字段应删除');
  });
}
