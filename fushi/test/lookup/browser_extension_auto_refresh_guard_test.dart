import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-726 生产接线守卫（源码扫描）：浏览器扩展「app 升级 → 磁盘副本刷新 → 扩展自
/// reload」链路的三段接线缺一不可。历史事故：BUG-621/688 把扩展弹窗 parity/主题修好
/// 入库，但已解压副本只在用户手动跑「安装扩展」助手时写入 → app 升级后用户浏览器里
/// 的扩展永远停在安装当天的旧版，修复到不了浏览器，弹窗与 app 内持续漂移。
void main() {
  group('BUG-726 extension auto-refresh wiring', () {
    test('AppModel.initialise fires refreshBrowserExtensionCopy', () {
      final String src =
          File('lib/src/models/app_model.dart').readAsStringSync();
      // 启动路径必须挂上磁盘副本刷新（fire-and-forget，不阻塞 init）。
      // 用格式无关的正则（dart format 会在 unawaited( 后换行）。
      expect(
          RegExp('unawaited\\(\\s*refreshBrowserExtensionCopy\\(\\)')
              .hasMatch(src),
          isTrue,
          reason: '启动时必须刷新已解压的扩展副本，否则 app 升级永远到不了用户浏览器');
      // 刷新实现必须走「装过才刷」的条件重解压，而不是无条件落盘。
      expect(src, contains('refreshBundledBrowserExtensionIfStale('));
      // yomitan-api server 必须下发内置扩展指纹（extensionBuild 自更新信号）。
      expect(src,
          contains('extensionBuildProvider: () => _browserExtensionBuild'));
    });

    test('installer refresh is conditional on an existing install', () {
      final String src = File('lib/src/lookup/browser_extension_installer.dart')
          .readAsStringSync();
      final int fn =
          src.indexOf('Future<bool> refreshBundledBrowserExtensionIfStale');
      expect(fn, greaterThanOrEqualTo(0));
      final String body = src.substring(fn);
      // 副本目录不存在（用户从没装过）→ 绝不落盘：不能给没装扩展的用户凭空写文件。
      expect(body, contains('if (!dest.existsSync()) return false;'),
          reason: '刷新只针对已安装副本；未安装用户不落盘');
    });

    test('background.js self-reload is guarded (loop / recording / legacy)',
        () {
      final String src =
          File('assets/browser_extension/background.js').readAsStringSync();
      // 查词响应回完后才检查自更新（reload 杀 SW，不能挡响应）。
      // 守的两条时序不变式，都框死在 lookup 这一个 else-if 分支里（别的分支各有
      // 自己的 sendResponse，全文件 indexOf 会串台）：
      //   ① 响应体必须在 sendResponse 之前 await 读完并解析进 data —— 先回
      //      sendResponse 再 await 网络流，消息通道已关闭、且 maybeSelfReload 的
      //      chrome.runtime.reload() 随时可能把 SW 杀掉，页面侧永远拿不到数据；
      //   ② maybeSelfReload 必须排在 sendResponse 之后 —— reload 杀 SW，挡在
      //      响应前面就是「查一次词弹窗永远不出」。
      // 锚点不再钉死单行字面量：PR #804 的性能埋点把响应体读取拆成
      // `await r.text()` + JSON.parse（为量 responseBodyMs / outerJsonParseMs），
      // 契约本身没变，故改用「分支内的相对顺序」判据。
      const String lookupBranchHead = "} else if (msg.type === 'lookup') {";
      final int lookupBranch = src.indexOf(lookupBranchHead);
      expect(lookupBranch, greaterThanOrEqualTo(0),
          reason: 'background.js 缺 lookup 消息分支');
      final int nextBranch =
          src.indexOf('} else if (msg.type === ', lookupBranch + 1);
      expect(nextBranch, greaterThan(lookupBranch),
          reason: 'lookup 分支边界无法定位（后面必须还有别的 msg.type 分支）');
      final String lookupBody = src.substring(lookupBranch, nextBranch);
      final int bodyRead =
          lookupBody.indexOf(RegExp(r'await r\.(text|json)\('));
      final int respond = lookupBody.indexOf('sendResponse(');
      final int reloadCall = lookupBody.indexOf('maybeSelfReload(data);');
      expect(bodyRead, greaterThanOrEqualTo(0),
          reason: 'lookup 处理必须 await 读出响应体（r.text()/r.json()）');
      expect(respond, greaterThan(bodyRead),
          reason: 'lookup 处理必须先取响应数据再回 sendResponse');
      expect(reloadCall, greaterThan(respond),
          reason: 'maybeSelfReload 必须在 lookup 的 sendResponse 之后');
      // 回给页面的必须是解析好的对象，不是还没读的 Response/裸文本。
      expect(
          RegExp(r'JSON\.parse\(raw\)|const data = r\.ok \? await r\.json\(\)')
              .hasMatch(lookupBody),
          isTrue,
          reason: 'lookup 分支必须把响应体解析成 data 后再下发');
      // 三重防护：任一侧缺指纹不动 / 已为该指纹 reload 过不再重试 / 录制中跳过。
      // BUG-1079 后防护收敛进 self-update.js 的纯函数 decide()（node 测试覆盖
      // 15 例），background.js 只消费其决策——守卫改为断言状态机本体 + 消费接线。
      final String selfUpdate =
          File('assets/browser_extension/self-update.js').readAsStringSync();
      expect(selfUpdate,
          contains('if (!remote || !local) return { action: actions.none };'));
      expect(selfUpdate,
          contains('if (recording) return { action: actions.none };'));
      expect(selfUpdate, contains('if (reloadedFor === remote)'));
      expect(src, contains('FUSHI_SELF_UPDATE'),
          reason: 'background.js 必须消费 self-update 状态机的决策');
      expect(src, contains('fushiReloadedForBuild'));
      final int fn = src.indexOf('async function maybeSelfReload');
      expect(fn, greaterThanOrEqualTo(0));
      final int reload = src.indexOf('chrome.runtime.reload()', fn);
      expect(reload, greaterThan(fn),
          reason: 'maybeSelfReload 内必须真正调用 chrome.runtime.reload()');
      final String body = src.substring(fn, reload);
      expect(body, contains('isOffscreenRecording()'),
          reason: 'Netflix 逐句回放录制中禁止 reload（会杀掉 offscreen 录制）');
    });

    test('mirror copy of background.js stays byte-identical', () {
      // 双镜像契约（TODO-1000）：assets/ 与 tools/ 必须逐字节一致。installer_test 已
      // 全量互比；这里单独点名 background.js，让本守卫失败信息直指自更新改动没同步镜像。
      final List<int> bundled =
          File('assets/browser_extension/background.js').readAsBytesSync();
      final List<int> source =
          File('../tools/browser-extension/background.js').readAsBytesSync();
      expect(bundled, source, reason: '改 background.js 必须同步两个镜像');
    });
  });
}
