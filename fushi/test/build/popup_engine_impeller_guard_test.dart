import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-2790：app 外查词窗（`:popup` 热引擎）第二次打开起只剩冻住的旧 WebView、
/// 释义滑不动。根因是 Flutter 引擎在 Impeller GLES 下的 Teardown 顺序缺陷
/// （Hybrid Composition 合并线程时 `~GPUSurfaceGLImpeller` 不清当前上下文，
/// flutter#174495）；兼容层是 `:popup` 引擎单独关 Impeller。引擎行为没法在 host
/// 上跑，这里钉住兼容层本身——撤掉它之前必须先满足 BUG 记录里的清理条件。
void main() {
  const String holder =
      'android/app/src/main/java/app/fushi/reader/PopupEngineHolder.kt';

  test(':popup 引擎以 --enable-impeller=false 创建', () {
    final String src = File(holder).readAsStringSync().replaceAll('\r\n', '\n');
    final int at = src.indexOf('val engine = FlutterEngine(');
    expect(at, isNot(-1), reason: '找不到 :popup 引擎的创建点');
    final String call = src.substring(at, src.indexOf(')\n', at) + 1);
    expect(
      call,
      contains('arrayOf("--enable-impeller=false")'),
      reason: '关掉它，热槽 WebView 一出现，第二次打开查词窗就每帧 EGL_BAD_ACCESS',
    );
    expect(src, contains('BUG-2790'), reason: '兼容层要带着根因与清理条件');
  });
}
