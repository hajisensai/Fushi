import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-865 source-scan guard: app 外查词面（剪贴板 / 悬浮 / 选区弹窗）的制卡跑在
/// `popupMain` 副 FlutterEngine（`PopupEngineHolder`）里。AnkiDroid 制卡走
/// `AnkiRepository` 的 `app.fushi.reader/anki` MethodChannel，而该 channel 原先只在
/// `MainActivity.configureFlutterEngine` 的主 engine 注册。副 engine 未注册 →
/// `invokeMethod('addNote')` 抛 `MissingPluginException`，被 `mineEntry` 外层 catch
/// 包成 toast「导出卡片失败：AnkiDroid: unexpected error: MissingPluginException(...)」。
/// 诱因是 BUG-774 解禁了 app 外查词面的制卡「＋」按钮。
///
/// 根因修复：副 engine 的唯一插件注册点 `FloatingDictPluginRegistrant.registerWith`
/// 接收一个 `Context`，并用 `applicationContext` 注册一份
/// `new AnkiChannelHandler(context, null)`（AnkiDroid ContentProvider 制卡是进程+权限
/// 作用域，Context 足够；权限弹窗须在主 app 完成，故 activity 传 null）。
///
/// 真机 MethodChannel 注册跑在 Android 原生层（这里跑不了），故守 *注册机制*：若
/// registrant 不再注册 anki channel、或 `PopupEngineHolder` 不再向 registrant 传
/// Context，副 engine 制卡会再次抛 MissingPluginException，本测试转红。
void main() {
  // Tests run with CWD = `hibiki/`.
  final File registrant = File(
    'android/app/src/main/java/app/fushi/reader/FloatingDictPluginRegistrant.java',
  );
  final File popupEngine = File(
    'android/app/src/main/java/app/fushi/reader/PopupEngineHolder.kt',
  );
  final File ankiHandler = File(
    'android/app/src/main/java/app/fushi/reader/AnkiChannelHandler.java',
  );

  test('secondary-engine files exist', () {
    expect(registrant.existsSync(), isTrue);
    expect(popupEngine.existsSync(), isTrue);
    expect(ankiHandler.existsSync(), isTrue);
  });

  test('FloatingDictPluginRegistrant registers the anki channel', () {
    final String src = registrant.readAsStringSync();
    final String compact = src.replaceAll(RegExp(r'\s+'), ' ');

    // registerWith 必须接收一个 Context（供 anki channel 用 applicationContext 注册）。
    expect(
      RegExp(r'registerWith\([^)]*FlutterEngine[^)]*Context[^)]*\)')
          .hasMatch(compact),
      isTrue,
      reason: 'BUG-865: registerWith 必须带 Context 参数，否则无法在副 engine 注册 '
          'anki channel（AnkiChannelHandler 需要 Context）。',
    );

    // 必须在此注册 AnkiChannelHandler，否则 popupMain 副 engine 制卡抛
    // MissingPluginException。
    expect(
      RegExp(r'new\s+AnkiChannelHandler\([^)]*\)\s*\.register\(')
          .hasMatch(compact),
      isTrue,
      reason: 'BUG-865: 副 engine 必须注册 app.fushi.reader/anki channel，'
          '否则 app 外查词面制卡 invokeMethod(addNote) 抛 MissingPluginException。',
    );
  });

  test('PopupEngineHolder passes a Context into the registrant', () {
    final String src = popupEngine.readAsStringSync();
    final String compact = src.replaceAll(RegExp(r'\s+'), ' ');

    expect(
      RegExp(r'FloatingDictPluginRegistrant\.registerWith\([^)]*context[^)]*\)')
          .hasMatch(compact),
      isTrue,
      reason: 'BUG-865: PopupEngineHolder 必须把 Context（applicationContext）传给 '
          'registerWith，否则 anki channel 无法在 popupMain 副 engine 注册。',
    );
  });

  test('AnkiChannelHandler has a Context-based constructor for the sub-engine',
      () {
    final String src = ankiHandler.readAsStringSync();
    final String compact = src.replaceAll(RegExp(r'\s+'), ' ');

    // 构造器必须能接受 (Context, @Nullable Activity)，让副 engine 用 applicationContext
    // 注册且 activity 传 null（ContentProvider 制卡只需 Context）。
    expect(
      RegExp(r'AnkiChannelHandler\(\s*@NonNull\s+Context\s+context,\s*@Nullable\s+Activity\s+activity\s*\)')
          .hasMatch(compact),
      isTrue,
      reason: 'BUG-865: AnkiChannelHandler 需要一个 (Context, @Nullable Activity) '
          '构造器；否则副 engine 无 Activity 时无法注册 anki channel。',
    );

    // 权限弹窗路径必须对 activity==null 优雅降级（不能对 null 调 requestPermission）。
    expect(
      compact.contains('if (activity != null)'),
      isTrue,
      reason: 'BUG-865: activity==null（副 engine）时权限弹窗须跳过，否则 '
          'ActivityCompat.requestPermissions 对 null NPE。',
    );
  });
}
