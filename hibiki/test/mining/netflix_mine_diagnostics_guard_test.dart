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
        // TODO-1331：HTTP/网络层失败（401/连接拒绝/404/4xx/5xx）不再静默 retry——
        // 经 hibikiMineHttpFailureReason 区分鉴权/连不上/服务端后弹 ✗ 原因，终结
        // 「你看日志却查不到条目」（BUG-603 只覆盖 server 回带诊断，未覆盖 HTTP 层）。
        expect(
            src.contains('function hibikiMineHttpFailureReason(resp)'), isTrue,
            reason: '$root 未实现 HTTP 层失败原因翻译（静默吞失败）');
        // 断言到「原因被传进 toast」为止，不含收尾的 `)`：hibikiToast 现在还接
        // (sticky, openSettings) 两个可选参数（401/4xx 的解法就在扩展设置页，故那两类
        // toast 可点直达）。钉整行字面量会把「给这条 toast 加参数」误判成「不弹 toast 了」。
        expect(
            src.contains(
                "window.hibikiToast('✗ ' + hibikiMineHttpFailureReason(resp)"),
            isTrue,
            reason: '$root HTTP 失败分支未弹 ✗ 原因 toast');
        expect(src.contains('鉴权失败(401)'), isTrue,
            reason: '$root 未区分 401 鉴权失败原因');
        expect(src.contains('Yomitan API server'), isTrue,
            reason: '$root 未提示连不上/端点错时去开 Yomitan API server');
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
