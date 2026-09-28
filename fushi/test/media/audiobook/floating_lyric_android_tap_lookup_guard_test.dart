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
/// 2026-09-28：这套弹性启动从 FloatingLyricService 私有方法抽成共享的
/// `BackgroundActivityLauncher`（全局悬浮球 / 截屏 OCR 选取层同样从后台服务拉起查词窗）。
/// 守卫随之改钉两处：悬浮字幕的 `startLookupActivity` 必须委托给共享启动器，
/// 共享启动器本身必须保有上述 opt-in + 两级回退。
///
/// 原生 Java 行为无法在 Dart host 上运行，也无法离屏复现「悬浮窗+后台」时序，故这
/// 里在源码层钉住启动契约防回归（真机验收另行）。
void main() {
  const String root = '../fushi/android/app/src/main/java/app/fushi/reader';
  const String service = '$root/FloatingLyricService.java';
  const String launcher = '$root/BackgroundActivityLauncher.java';

  String read(String path) =>
      File(path).readAsStringSync().replaceAll('\r\n', '\n');

  /// [src] 里从 [sig] 起、到 [endMarker]（下一个方法签名）为止的片段。
  String slice(String src, String sig, String endMarker) {
    final int at = src.indexOf(sig);
    expect(at, greaterThanOrEqualTo(0), reason: '缺少 `$sig`');
    final int end = src.indexOf(endMarker, at + sig.length);
    expect(end, greaterThan(at), reason: '`$sig` 之后找不到 `$endMarker`');
    return src.substring(at, end);
  }

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

  /// 悬浮字幕的 startLookupActivity 函数体（到下一个 javadoc 为止）。
  String lyricLaunchBody(String src) => slice(
      src, 'private void startLookupActivity(Intent intent)', '/**');

  /// 共享启动器入口 `start`（到 bringAppToFront 为止）。
  String launcherStartBody(String src) => slice(
      src,
      'static void start(@NonNull Context context, @NonNull Intent intent)',
      'static void bringAppToFront(');

  /// 共享启动器 `bringAppToFront`（到 opt-in helper 为止）。
  String launcherFrontBody(String src) => slice(
      src,
      'static void bringAppToFront(@NonNull Context context)',
      'private static boolean sendAllowingBackgroundStart(');

  /// 共享启动器的 API 34+ opt-in helper（到文件尾）。
  String launcherOptInBody(String src) {
    const String sig = 'private static boolean sendAllowingBackgroundStart(';
    final int at = src.indexOf(sig);
    expect(at, greaterThanOrEqualTo(0), reason: '共享启动器必须有 API 34+ opt-in helper');
    return src.substring(at);
  }

  group('TODO-1268 Android 悬浮字幕点词后台启动', () {
    test('handleTap 经弹性 helper 启动，不再裸 startActivity', () {
      final String body = handleTapBody(read(service));
      expect(body.contains('startActivity('), isFalse,
          reason: 'handleTap 内不得直接 startActivity——后台点词会被 BAL 拦掉，'
              '必须走 startLookupActivity 的 opt-in + 回退');
    });

    test('handleTap 仍保留点词契约（PopupDictFlutterActivity + 文本 + charIndex）', () {
      final String body = handleTapBody(read(service));
      expect(body.contains('new Intent(this, PopupDictFlutterActivity.class)'),
          isTrue,
          reason: '路由目标必须仍是 Flutter 弹窗 Activity');
      expect(body.contains('Intent.EXTRA_PROCESS_TEXT'), isTrue,
          reason: '必须仍携带当前字幕文本');
      expect(body.contains('PopupDictFlutterActivity.EXTRA_CHAR_INDEX'), isTrue,
          reason: '必须仍携带命中字 charIndex（去键盘分词，BUG-214）');
    });

    test('startLookupActivity 委托共享启动器，不自己裸启动', () {
      final String body = lyricLaunchBody(read(service));
      expect(body.contains('BackgroundActivityLauncher.start(this, intent)'),
          isTrue,
          reason: '悬浮字幕点词必须走共享的弹性启动器（与悬浮球 / 截屏 OCR 同一条路径）');
      expect(body.contains('startActivity('), isFalse,
          reason: '不得在这里另写一份裸 startActivity 分支');
    });

    test('共享启动器在 API 34+ 显式 opt-in 后台 activity 启动', () {
      final String src = read(launcher);
      final String start = launcherStartBody(src);
      expect(start.contains('FLAG_ACTIVITY_NEW_TASK'), isTrue,
          reason: '从非 Activity 上下文启动 Activity 必须带 NEW_TASK');
      expect(start.contains('sendAllowingBackgroundStart(context, intent)'),
          isTrue,
          reason: '入口必须先走 opt-in helper');

      final String optIn = launcherOptInBody(src);
      expect(optIn.contains('Build.VERSION_CODES.UPSIDE_DOWN_CAKE'), isTrue,
          reason: '后台启动 opt-in 门控在 API 34（Android 14）+');
      expect(optIn.contains('PendingIntent.getActivity('), isTrue,
          reason: '走自发 PendingIntent 以携带后台启动授权');
      expect(
          optIn.contains('setPendingIntentBackgroundActivityStartMode'), isTrue,
          reason: 'BUG：必须用官方 opt-in 显式授予后台启动特权');
      expect(
          optIn.contains(
              'ActivityOptions.MODE_BACKGROUND_ACTIVITY_START_ALLOWED'),
          isTrue,
          reason: '必须选 ALLOWED 模式，否则 Android 14+ 默认拦截');
      expect(optIn.contains('Log.w(TAG'), isTrue,
          reason: 'PendingIntent 失败要记 log，真机复现可看到命中了哪条分支');
    });

    test('启动失败绝不静默吞：回退直接 startActivity + 前台化', () {
      final String src = read(launcher);
      final String start = launcherStartBody(src);
      expect(start.contains('context.startActivity(intent)'), isTrue,
          reason: '<34 及 PendingIntent 失败时回退直接 startActivity');
      expect(start.contains('bringAppToFront(context)'), isTrue,
          reason: '两条启动都失败时把 app 拉到前台——一次点词绝不被静默丢弃');
      expect(start.contains('Log.w(TAG'), isTrue,
          reason: '每条回退都记 log，真机复现可看到命中了哪条分支');

      final String front = launcherFrontBody(src);
      expect(front.contains('sendAllowingBackgroundStart(context, intent)'),
          isTrue,
          reason: '前台化本身也是后台启动，同样要走 opt-in');
    });
  });
}
