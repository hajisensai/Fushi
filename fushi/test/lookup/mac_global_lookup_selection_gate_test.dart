import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  String read(String path) {
    final File file = File(path);
    expect(
      file.existsSync(),
      isTrue,
      reason: 'expected file at ${file.absolute.path}',
    );
    return file.readAsStringSync().replaceAll('\r\n', '\n');
  }

  test('macOS global hotkey gates capture on Accessibility permission', () {
    final String controller = read(
      'lib/src/lookup/global_lookup_controller.dart',
    );
    expect(controller, contains('Platform.isMacOS'));
    expect(controller, contains('_ensureMacAccessibilityForSelection()'));
    expect(
      controller,
      contains('SelectionCapture.requestAccessibilityTrust()'),
    );
    // 闸门必须排在捕获之前：授权面板一旦成为前台窗口，这时去捕获读到的是面板
    // 自己的文本。钉顺序而不是钉注释原文——注释润色不该让守卫变红，把判据写反
    // 才该变红。
    final int gate = controller.indexOf(
      '_ensureMacAccessibilityForSelection()',
    );
    final int capture = controller.indexOf(
      'SelectionCapture.captureForegroundSelection(',
    );
    expect(gate, greaterThanOrEqualTo(0));
    expect(capture, greaterThan(gate));

    // 未授权时不能只 return false：这条链路的失败形态是「按了键什么都没发生」，
    // 只写 glog 临时诊断文件等于静默吞掉（TODO-1086 已为热键注册失败立过同一条
    // 规矩）。授权面板只开一次，但每次触发都要记一条用户可见的错误。
    final int fnAt = controller.indexOf(
      'Future<bool> _ensureMacAccessibilityForSelection()',
    );
    expect(fnAt, greaterThanOrEqualTo(0));
    final String body = controller.substring(
      fnAt,
      controller.indexOf('\n  }', fnAt),
    );
    expect(
      body,
      contains('ErrorLogService.instance.log('),
      reason: '未授权必须进用户可见的错误日志，不能静默 return false',
    );
    expect(
      RegExp(r'_macAccessibilityPrompted\s*=\s*true').allMatches(body).length,
      1,
      reason: '授权面板只开一次（再开也只是把同一个系统设置页翻到前台）',
    );
  });

  test('macOS copy fallback restores the complete pasteboard on every exit', () {
    final String capture = read('macos/Runner/SelectionCaptureMac.swift');
    expect(capture, contains('func restorePasteboard()'));
    // 去掉缩进再比：失败路径与成功路径都必须先还原剪贴板再返回，但 swift-format
    // 调缩进不该让守卫变红。
    final String flat = capture.replaceAll(RegExp(r'[ \t]+'), ' ');
    expect(flat, contains('restorePasteboard()\n return nil'));
    expect(flat, contains('restorePasteboard()\n return text'));
    expect(
      capture,
      contains('pasteboard.writeObjects(items)'),
      reason:
          'a failed global lookup must not destroy a copied image or rich text',
    );
  });
}
