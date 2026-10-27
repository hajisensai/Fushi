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
/// 另外钉住悬浮球常驻通知：点按 = 打开 Fushi（用户 2026-10-21 拍板回退），
/// 「查剪贴板」是通知按钮（同 Google「点按翻译」），两者都必须是
/// `PendingIntent.getActivity` 直达——Android 12+ 禁止
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

  test('悬浮球常驻通知：点按 = 打开 Fushi，查剪贴板是直达按钮', () {
    final String svc = File(
      '$javaRoot/app/fushi/reader/FloatingBallService.java',
    ).readAsStringSync();
    final int start = svc.indexOf('protected Notification buildNotification()');
    expect(start, greaterThan(0));
    final String body = svc.substring(start);
    // 点通知本身 = 打开 Fushi（用户 2026-10-21 拍板回退，BUG-3656）：contentIntent
    // 只能有一处，且是启动 Intent 的 getActivity 直达。
    final int contentIntent = body.indexOf('builder.setContentIntent(');
    expect(contentIntent, greaterThan(0));
    expect(
      body.indexOf('builder.setContentIntent(', contentIntent + 1),
      -1,
      reason: '通知只该设置一次 contentIntent',
    );
    final String content = body.substring(
      contentIntent,
      body.indexOf(';', contentIntent),
    );
    expect(content, contains('PendingIntent.getActivity('));
    expect(content, contains('REQUEST_NOTIFICATION_OPEN_APP, launch'));
    expect(content, isNot(contains('getService')));
    expect(content, isNot(contains('clipboard')));
    final String beforeContent = body.substring(0, contentIntent);
    expect(
      beforeContent,
      contains('getLaunchIntentForPackage(getPackageName())'),
    );
    expect(beforeContent, isNot(contains('PopupDictFlutterActivity')));
    // 「查剪贴板」是通知按钮，同样 getActivity 直达查词窗（Android 12+ 禁通知蹦床）。
    final int clipboardIntent = body.indexOf(
      'new Intent(this, PopupDictFlutterActivity.class)',
    );
    expect(clipboardIntent, greaterThan(contentIntent));
    final String clipboardPart = body.substring(clipboardIntent);
    expect(
      clipboardPart,
      contains('PopupDictFlutterActivity.EXTRA_READ_CLIPBOARD, true'),
    );
    final int pendingAt = clipboardPart.indexOf('clipboardPending =');
    expect(pendingAt, greaterThan(0));
    final String pending = clipboardPart.substring(
      pendingAt,
      clipboardPart.indexOf(';', pendingAt),
    );
    expect(pending, contains('PendingIntent.getActivity('));
    expect(pending, contains('REQUEST_NOTIFICATION_CLIPBOARD, clipboard'));
    expect(pending, isNot(contains('getService')));
    expect(body, contains('labelFor(ACTION_CLIPBOARD), clipboardPending'));
    // 「打开 Fushi」不再是按钮；正文「点按即可查剪贴板」随语义回退一起删掉。
    expect(body, isNot(contains('labelFor(ACTION_OPEN_APP)')));
    expect(body, isNot(contains('setContentText(')));
    expect(svc, isNot(contains('LABEL_NOTIFICATION_HINT')));
    final String host = File(
      'lib/src/floating_ball/app_floating_ball_host.dart',
    ).readAsStringSync();
    expect(host, isNot(contains('notification_hint')));
  });

  test('悬浮球「点按悬浮球」动作：收起态点 = 直接执行（剪贴板 / 截屏识字），长按 = 展开', () {
    final String svc = File(
      '$javaRoot/app/fushi/reader/FloatingBallService.java',
    ).readAsStringSync();
    final String channel = File(
      '$javaRoot/app/fushi/reader/FloatingBallChannel.java',
    ).readAsStringSync();
    // Dart → 原生 → 落盘 → 服务重建时重放；旧版 bool 只在新键没写过时迁移成剪贴板。
    expect(channel, contains('call.argument("tapAction")'));
    expect(
      svc,
      contains(
        'editor.putString(PREF_TAP_ACTION, sanitizeTapAction(tapAction))',
      ),
    );
    expect(
      svc,
      contains(
        'tapAction = prefs.contains(PREF_TAP_ACTION)\n'
        '                ? sanitizeTapAction(prefs.getString(PREF_TAP_ACTION, ""))\n'
        '                : (prefs.getBoolean(PREF_TAP_CLIPBOARD, false) ? ACTION_CLIPBOARD : "");',
      ),
    );
    expect(
      svc,
      contains(
        'TAP_ACTIONS = Arrays.asList(ACTION_CLIPBOARD, ACTION_SCREEN_OCR, ACTION_AI)',
      ),
    );
    final int start = svc.indexOf('protected void setupDragListener()');
    final String touch = svc.substring(start, svc.indexOf('\n    }\n', start));
    // 按下时排长按（系统长按时长），拖动 / 抬手 / 取消都要撤掉，免得拖着拖着弹出按钮。
    expect(
      touch,
      contains(
        'postDelayed(longPressExpand,\n'
        '                                ViewConfiguration.getLongPressTimeout())',
      ),
    );
    expect(
      'mainHandler.removeCallbacks(longPressExpand);'.allMatches(touch).length,
      4,
    );
    // 抬手：长按已展开就不再当点击；设了动作且收起态 → 执行它，否则照旧展开 / 收起。
    expect(touch, contains('} else if (!longPressFired) {'));
    expect(
      touch,
      contains(
        'if (!tapAction.isEmpty() && !expandTarget) {\n'
        '                            runAction(tapAction);\n'
        '                        } else {\n'
        '                            toggle();',
      ),
    );
  });

  test('BUG-3678 应用外球认「显示按钮文字」与「打开 Fushi」开关', () {
    final String svc = File(
      '$javaRoot/app/fushi/reader/FloatingBallService.java',
    ).readAsStringSync();
    final String channel = File(
      '$javaRoot/app/fushi/reader/FloatingBallChannel.java',
    ).readAsStringSync();
    expect(channel, contains('call.argument("showLabels")'));
    expect(channel, contains('call.argument("showOpenApp")'));
    expect(
      svc,
      contains('showLabels = prefs.getBoolean(PREF_SHOW_LABELS, true)'),
    );
    expect(
      svc,
      contains('showOpenApp = prefs.getBoolean(PREF_SHOW_OPEN_APP, true)'),
    );
    // 标签胶囊只在开关开着时建（旧实现恒建，Dart 下发的 showLabels 被原生丢掉）。
    final int labelsStart = svc.indexOf(
      'private List<TextView> buildMenuLabels(',
    );
    final String labels = svc.substring(
      labelsStart,
      svc.indexOf('\n    }\n', labelsStart),
    );
    expect(labels, contains('boolean show = showLabels && '));
    final int idsStart = svc.indexOf('private List<String> menuIds()');
    final String ids = svc.substring(
      idsStart,
      svc.indexOf('\n    }\n', idsStart),
    );
    expect(ids, contains('if (showOpenApp) ids.add(ACTION_OPEN_APP);'));
    expect(ids, isNot(contains('\n        ids.add(ACTION_OPEN_APP);')));
  });
}
