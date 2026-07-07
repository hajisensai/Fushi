import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// TODO-1303 源码扫描守卫（不依赖真浏览器）：浏览器扩展 content.js 的
/// `hibikiClassifyMineResp` 必须读取服务端回带的诊断（`message`/`detail`）并在末尾弹
/// toast 显因，且把「卡建了但音频落空」的部分成功（success + message）与真成功区分。
/// 两份镜像（随 app 打包的 assets/ 与真源 tools/）都守；逐字节一致另由
/// `test/build/browser_extension_dict_media_mirror_guard_test.dart` 保证，这里再断言一次。
void main() {
  const Map<String, String> mirrors = <String, String>{
    'assets': 'assets/browser_extension',
    'tools': '../tools/browser-extension',
  };

  group('TODO-1303 扩展制卡诊断 toast + audioWarning 区分守卫', () {
    mirrors.forEach((String name, String root) {
      test('[$name] hibikiClassifyMineResp 读诊断 + 弹原因 toast', () {
        final String src = File('$root/content.js').readAsStringSync();
        // 读服务端诊断字段（message 优先，detail 兜底）。
        expect(src.contains('d.message || d.detail'), isTrue,
            reason: '$root classify 未读取 message/detail 诊断');
        // 失败弹 toast 显因。
        expect(src.contains("window.hibikiToast('✗ '"), isTrue,
            reason: '$root 失败未弹原因 toast');
        // 部分成功：success + message（音频落空）弹 ⚠ 警告但仍算 done。
        expect(src.contains("window.hibikiToast('⚠ '"), isTrue,
            reason: '$root success+音频警告未弹 ⚠ toast');
        expect(src.contains("r === 'success' && reason"), isTrue,
            reason: '$root 未把 success+message 的部分成功与真成功区分');
        // 三态返回契约不变。
        expect(src.contains("return 'done';"), isTrue);
        expect(src.contains("return 'unconfigured';"), isTrue);
        expect(src.contains("return 'retry';"), isTrue);
      });
    });

    test('两镜像 content.js 逐字节一致', () {
      final List<int> assets =
          File('assets/browser_extension/content.js').readAsBytesSync();
      final List<int> tools =
          File('../tools/browser-extension/content.js').readAsBytesSync();
      expect(assets, tools,
          reason: 'assets/ 与 tools/ content.js 漂移，两镜像必须逐字节一致');
    });
  });
}
