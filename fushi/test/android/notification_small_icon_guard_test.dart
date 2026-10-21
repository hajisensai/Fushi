import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 守卫：Android 状态栏 / 通知小图标。
///
/// 两个用户可见的坏法（2026-10 用户截图）：
/// 1. 下载、悬浮球、悬浮词典、OCR 等前台服务通知在状态栏都显示「耳机」——
///    `ic_stat_fushi.xml` 当年是给有声书通知画的 Material headset，后来所有
///    通知都复用了它；
/// 2. 偶尔出现一团黑色剪影——更新提醒把彩色 `@mipmap/ic_launcher` 当小图标，
///    系统只取 alpha 画小图标，彩色图标就成了一团。
///
/// 另外钉住悬浮球常驻通知的「点按 = 查剪贴板」（同 Google「点按翻译」）：
/// 必须是 `PendingIntent.getActivity` 直达查词窗——Android 12+ 禁止
/// 「通知 → Service → 启动 Activity」蹦床，绕道服务会被系统静默拦下。
void main() {
  const String res = 'android/app/src/main/res';
  const String javaRoot = 'android/app/src/main/java';

  test('ic_stat_fushi 是单色白海兔剪影，不再是耳机', () {
    final String xml = File(
      '$res/drawable/ic_stat_fushi.xml',
    ).readAsStringSync();
    // Material「headset」图标的路径开头。
    expect(xml, isNot(contains('M12,3C8.69,3 6,5.69 6,9v5.25')));
    final List<String> fills = RegExp(
      r'android:fillColor="([^"]+)"',
    ).allMatches(xml).map((RegExpMatch m) => m.group(1)!).toList();
    expect(fills, isNotEmpty);
    expect(fills.toSet(), <String>{'@android:color/white'});
    // 眼睛镂空靠 evenOdd：没有它洞会被填实。
    expect(xml, contains('android:fillType="evenOdd"'));
    expect(xml, contains('gen_notification_icon.py'));
  });

  test('原生通知的 setSmallIcon 一律用单色 drawable，不用 mipmap', () {
    final List<String> offenders = <String>[];
    for (final FileSystemEntity e in Directory(
      javaRoot,
    ).listSync(recursive: true)) {
      if (e is! File) continue;
      if (!e.path.endsWith('.java') && !e.path.endsWith('.kt')) continue;
      final String src = e.readAsStringSync();
      for (final RegExpMatch m in RegExp(
        r'setSmallIcon\(([^)]*)\)',
      ).allMatches(src)) {
        if (m.group(1)!.contains('mipmap')) {
          offenders.add('${e.path}: ${m.group(0)}');
        }
      }
    }
    expect(offenders, isEmpty);
  });

  test('Dart 侧通知小图标不用彩色 mipmap', () {
    final List<String> offenders = <String>[];
    for (final FileSystemEntity e in Directory(
      'lib',
    ).listSync(recursive: true)) {
      if (e is! File || !e.path.endsWith('.dart')) continue;
      if (e.path.endsWith('.g.dart')) continue;
      final String src = e.readAsStringSync();
      for (final RegExpMatch m in RegExp(
        r'(AndroidInitializationSettings\([^)]*\)|androidNotificationIcon:[^,]*,)',
      ).allMatches(src)) {
        if (m.group(0)!.contains('mipmap')) {
          offenders.add('${e.path}: ${m.group(0)}');
        }
      }
    }
    expect(offenders, isEmpty);
    final String notifier = File(
      'lib/src/updates/local_update_notifier.dart',
    ).readAsStringSync();
    expect(
      notifier,
      contains("kAndroidNotificationSmallIcon = '@drawable/ic_stat_fushi'"),
    );
    expect(
      RegExp(
        r'AndroidInitializationSettings\(\s*kAndroidNotificationSmallIcon',
      ).hasMatch(notifier),
      isTrue,
    );
  });

  test('悬浮球常驻通知：点按直达查剪贴板，打开 Fushi 是按钮', () {
    final String svc = File(
      '$javaRoot/app/fushi/reader/FloatingBallService.java',
    ).readAsStringSync();
    final int start = svc.indexOf('protected Notification buildNotification()');
    expect(start, greaterThan(0));
    final String body = svc.substring(start);
    final int contentIntent = body.indexOf('builder.setContentIntent(');
    expect(contentIntent, greaterThan(0));
    final String content = body.substring(
      contentIntent,
      body.indexOf(';', contentIntent),
    );
    expect(content, contains('PendingIntent.getActivity('));
    expect(content, contains('REQUEST_NOTIFICATION_CLIPBOARD'));
    expect(content, isNot(contains('getService')));
    final String beforeContent = body.substring(0, contentIntent);
    expect(
      beforeContent,
      contains('new Intent(this, PopupDictFlutterActivity.class)'),
    );
    expect(
      beforeContent,
      contains('PopupDictFlutterActivity.EXTRA_READ_CLIPBOARD, true'),
    );
    expect(body, contains('labelFor(ACTION_OPEN_APP), openPending'));
    expect(body, contains('.setContentText(hint)'));
    // 正文文案由 Dart 下发（原生不维护多语言）。
    final String host = File(
      'lib/src/floating_ball/app_floating_ball_host.dart',
    ).readAsStringSync();
    expect(
      host,
      contains("'notification_hint': t.floating_ball_notification_tap_hint"),
    );
    expect(svc, contains('LABEL_NOTIFICATION_HINT = "notification_hint"'));
  });
}
