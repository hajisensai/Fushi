import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/focus/webview_key_bridge.dart';
import 'package:fushi/src/pages/implementations/dictionary_popup_input_bridge.dart';

/// BUG-1071 复诉（关闭词典的快捷键与鼠标键在弹窗上仍然没反应）的**行为级**守卫。
///
/// 为什么必须真跑 JS：这次修复的全部要害都在 JS 的判定逻辑里——组合键该不该吞、
/// 改键后旧键该不该失效、鼠标侧键回传什么、老宿主的空格语义有没有被顺手改坏。
/// 源码扫描只能证明字符串里出现过某个片段，这几条一条都锁不住（把 `indexOf` 写反
/// 都照样绿）。故用与 BUG-1012 同款的 node harness：Dart 生成脚本 → node 真执行 →
/// 合成事件断言转发结果。无 node 时显式 skip（不伪装成通过）。
void main() {
  test(
    'BUG-1071: popup input bridge forwards the right keys/buttons (executes JS via node)',
    () async {
      final String? nodeExe = _resolveNode();
      if (nodeExe == null) {
        markTestSkipped(
            'node not found on PATH; skipping JS behavior execution');
        return;
      }

      final File harness =
          File('test/focus/webview_key_bridge_behavior_test.js');
      expect(harness.existsSync(), isTrue,
          reason: 'behavior harness ${harness.path} must exist');

      // 生成各用例的真实脚本——与生产注入走的是同一个生成函数，不是手抄的副本。
      //
      // 本用例验证的是**弹窗内 JS 桥**的行为，故显式声明「指针归 WebView」
      // （`hostOwnsPointer: false`）。不写死这一条的话，脚本里有没有鼠标监听会随
      // 跑测试的机器变（Windows 上指针归宿主、桥不装鼠标监听），同一份守卫在本机和
      // Linux CI 上测的就不是同一件事——Windows 直接红，CI 绿（BUG-1269 复诉）。
      // Windows 那条路由宿主侧的 dictionary_popup_pointer_input_test 覆盖。
      final Map<String, String> scripts = <String, String>{
        'escapeAndMouseBack': dictionaryPopupInputBridgeScript(
          const DictionaryPopupInputSpec(
            keyTokens: <String>['Escape'],
            mouseButtons: <int>[3],
          ),
          hostOwnsPointer: false,
        ),
        'ctrlKeyD': dictionaryPopupInputBridgeScript(
          const DictionaryPopupInputSpec(keyTokens: <String>['Ctrl+KeyD']),
          hostOwnsPointer: false,
        ),
        'emptySpec': dictionaryPopupInputBridgeScript(
          const DictionaryPopupInputSpec(),
          hostOwnsPointer: false,
        ),
        'legacySpace': webViewKeyBridgeScript(
          handlerName: 'onSpaceKey',
          keys: const <String>[' '],
        ),
      };

      final Directory tmp =
          Directory.systemTemp.createTempSync('hibiki_bridge_behavior_');
      addTearDown(() {
        if (tmp.existsSync()) tmp.deleteSync(recursive: true);
      });
      final File payload =
          File('${tmp.path}${Platform.pathSeparator}bridge.json')
            ..writeAsStringSync(jsonEncode(scripts));

      final ProcessResult result = await Process.run(
        nodeExe,
        <String>[harness.path, payload.path],
        workingDirectory: Directory.current.path,
      );

      expect(
        result.exitCode,
        0,
        reason: 'popup input bridge behavior test failed.\n'
            'stdout:\n${result.stdout}\nstderr:\n${result.stderr}',
      );
      expect(result.stdout.toString(), contains('all assertions passed'),
          reason: 'behavior harness must reach its success marker');
    },
  );
}

String? _resolveNode() {
  final String exe = Platform.isWindows ? 'node.exe' : 'node';
  final ProcessResult probe = Platform.isWindows
      ? Process.runSync('where', <String>[exe])
      : Process.runSync('which', <String>[exe]);
  if (probe.exitCode != 0) return null;
  final String first = probe.stdout
      .toString()
      .split(RegExp(r'[\r\n]+'))
      .map((String line) => line.trim())
      .firstWhere((String line) => line.isNotEmpty, orElse: () => '');
  return first.isEmpty ? null : first;
}
