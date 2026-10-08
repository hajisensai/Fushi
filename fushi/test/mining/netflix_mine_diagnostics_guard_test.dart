import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// TODO-1303 源码扫描守卫（不依赖真浏览器）：浏览器扩展 content.js 的
/// `fushiClassifyMineResp` 必须读取服务端回带的诊断（`message`/`detail`）并在末尾弹
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
      // 分类判据住在 mine-outcome.js（content script 的 Netflix 回放与 service worker 的
      // YouTube 批量共用一份）；content.js 只把判据给出的 notice 弹成 toast。行为本身由
      // tools/browser-extension/mine-outcome.test.js 在 node 里真跑，这里守接线与文案。
      test('[$name] 制卡结果分类读诊断 + 弹原因 toast', () {
        final String outcome =
            File('$root/mine-outcome.js').readAsStringSync();
        // 读服务端诊断字段（message 优先，detail 兜底）。
        expect(outcome.contains('d.message || d.detail'), isTrue,
            reason: '$root 分类器未读取 message/detail 诊断');
        // 部分成功：success + message（音频落空）给 ⚠ 警告但仍算 done。
        expect(outcome.contains("r === 'success' && reason"), isTrue,
            reason: '$root 未把 success+message 的部分成功与真成功区分');
        expect(outcome.contains("'⚠ ' + reason"), isTrue,
            reason: '$root success+音频警告未给 ⚠ 提示');
        // TODO-1331：HTTP/网络层失败（401/连接拒绝/404/4xx/5xx）不再静默 retry——
        // 经 fushiMineHttpFailureReason 区分鉴权/连不上/服务端后给 ✗ 原因，终结
        // 「你看日志却查不到条目」（BUG-603 只覆盖 server 回带诊断，未覆盖 HTTP 层）。
        expect(
            outcome.contains(
                "notice: '✗ ' + fushiMineHttpFailureReason(resp, t)"),
            isTrue,
            reason: '$root HTTP 失败分支未给 ✗ 原因');
        expect(outcome.contains("t('mine_err_401')"), isTrue,
            reason: '$root 未区分 401 鉴权失败原因');
        // 三态契约不变。
        expect(outcome.contains("cls: 'done'"), isTrue);
        expect(outcome.contains("cls: 'unconfigured'"), isTrue);
        expect(outcome.contains("cls: 'retry'"), isTrue);
        // content.js 用这份判据，并把原因弹出来（401/4xx 可点直达设置）。
        final String src = File('$root/content.js').readAsStringSync();
        expect(src.contains('window.fushiMineOutcome(resp, fushiTr)'), isTrue,
            reason: '$root content.js 未走共享分类器');
        expect(
            src.contains(
                'window.fushiToast(o.notice, false, o.settingsFixable)'),
            isTrue,
            reason: '$root content.js 未把分类原因弹成 toast');
        // 文案已进 i18n 字典（locales/en.js 为源，各语言 json 同键集）。
        final String en = File('$root/locales/en.js').readAsStringSync();
        expect(en.contains('Authentication failed (401)'), isTrue,
            reason: '$root 字典缺 401 鉴权失败原因文案');
        expect(en.contains('Yomitan API server'), isTrue,
            reason: '$root 未提示连不上/端点错时去开 Yomitan API server');
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
