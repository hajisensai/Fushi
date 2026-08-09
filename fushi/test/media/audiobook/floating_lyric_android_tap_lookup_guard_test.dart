import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Source-scan guards for TODO-1268 / BUG — 「点击悬浮字幕文字，没有出现查词窗口」
/// on **Android**.
///
/// 根因：Android 悬浮字幕点词由原生 [FloatingLyricService.handleTap] 直接
/// `startActivity(PopupDictFlutterActivity)` 拉起弹窗。悬浮字幕的使用场景恰恰是
/// Hibiki 不在前台（悬浮窗画在别的 app 上），所以这是一次 *background activity
/// launch*：自 API 29 起默认被拦；API 34（targetSdk 34+）不再让 app 默默继承
/// 后台启动特权；API 35（Android 15）把 SYSTEM_ALERT_WINDOW 豁免收窄到「有权限
/// 且有可见 overlay」。现代 Android / 更激进的 OEM ROM 上裸 startActivity 被丢弃
/// → 点词没反应。之前的 TODO-1268 只改了桌面/全局查词路径
/// (`global_lookup_controller.lookupText`)，从没触及这条 Android 入口。
///
/// 修复：API 34+ 走自发 [PendingIntent] + `ActivityOptions
/// .setPendingIntentBackgroundActivityStartMode(MODE_BACKGROUND_ACTIVITY_START_ALLOWED)`
/// —— 官方文档化的后台启动 opt-in；失败回退直接 startActivity，最终回退把 app 拉
/// 到前台，保证一次点词绝不被静默吞掉。
///
/// 原生 Java 行为无法在 Dart host 上运行，也无法离屏复现「悬浮窗+后台」时序，故这
/// 里在源码层钉住启动契约防回归（真机验收另行）。
void main() {
  const String service =
      '../fushi/android/app/src/main/java/app/fushi/reader/FloatingLyricService.java';

  String read() => File(service).readAsStringSync().replaceAll('\r\n', '\n');

  /// handleTap 函数体（签名 → 其收尾的 `startLookupActivity(intent);`）。
  String handleTapBody(String src) {
    const String sig = 'private void handleTap(MotionEvent event)';
    final int at = src.indexOf(sig);
    expect(at, greaterThanOrEqualTo(0), reason: 'handleTap 入口必须存在');
    final int end = src.indexOf('startLookupActivity(intent);', at);
    expect(end, greaterThan(at),
        reason: 'handleTap 必须以 startLookupActivity(intent) 收尾');
    return src.substring(at, end);
  }

  /// startLookupActivity 函数体。
  String launchBody(String src) {
    const String sig = 'private void startLookupActivity(Intent intent)';
    final int at = src.indexOf(sig);
    expect(at, greaterThanOrEqualTo(0), reason: 'TODO-1268：必须有集中的弹性启动 helper');
    // 到下一个方法声明前（本 helper 后面紧跟 bringAppToFront 的 javadoc）。
    final int end = src.indexOf('private void bringAppToFront()', at);
    expect(end, greaterThan(at));
    return src.substring(at, end);
  }

  group('TODO-1268 Android 悬浮字幕点词后台启动', () {
    test('handleTap 经弹性 helper 启动，不再裸 startActivity', () {
      final String body = handleTapBody(read());
      expect(body.contains('startActivity('), isFalse,
          reason: 'handleTap 内不得直接 startActivity——后台点词会被 BAL 拦掉，'
              '必须走 startLookupActivity 的 opt-in + 回退');
    });

    test('handleTap 仍保留点词契约（PopupDictFlutterActivity + 文本 + charIndex）', () {
      final String body = handleTapBody(read());
      expect(body.contains('new Intent(this, PopupDictFlutterActivity.class)'),
          isTrue,
          reason: '路由目标必须仍是 Flutter 弹窗 Activity');
      expect(body.contains('Intent.EXTRA_PROCESS_TEXT'), isTrue,
          reason: '必须仍携带当前字幕文本');
      expect(body.contains('PopupDictFlutterActivity.EXTRA_CHAR_INDEX'), isTrue,
          reason: '必须仍携带命中字 charIndex（去键盘分词，BUG-214）');
    });

    test('启动 helper 在 API 34+ 显式 opt-in 后台 activity 启动', () {
      final String body = launchBody(read());
      expect(body.contains('Build.VERSION_CODES.UPSIDE_DOWN_CAKE'), isTrue,
          reason: '后台启动 opt-in 门控在 API 34（Android 14）+');
      expect(body.contains('PendingIntent.getActivity('), isTrue,
          reason: '走自发 PendingIntent 以携带后台启动授权');
      expect(
          body.contains('setPendingIntentBackgroundActivityStartMode'), isTrue,
          reason: 'BUG：必须用官方 opt-in 显式授予后台启动特权');
      expect(
          body.contains(
              'ActivityOptions.MODE_BACKGROUND_ACTIVITY_START_ALLOWED'),
          isTrue,
          reason: '必须选 ALLOWED 模式，否则 Android 14+ 默认拦截');
      expect(body.contains('FLAG_ACTIVITY_NEW_TASK'), isTrue,
          reason: '从非 Activity 上下文启动 Activity 必须带 NEW_TASK');
    });

    test('启动失败绝不静默吞：回退直接 startActivity + 前台化', () {
      final String body = launchBody(read());
      expect(body.contains('startActivity(intent)'), isTrue,
          reason: '<34 及 PendingIntent 失败时回退直接 startActivity');
      expect(body.contains('bringAppToFront()'), isTrue,
          reason: '两条启动都失败时把 Hibiki 拉到前台——一次点词绝不被静默丢弃');
      expect(body.contains('Log.w(TAG'), isTrue,
          reason: '每条回退都记 log，真机复现可看到命中了哪条分支');
    });
  });
}
