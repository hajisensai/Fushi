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
      expect(body, contains('if (!dir.existsSync()) continue;'),
          reason: '刷新只针对已安装副本；未安装用户不落盘');
    });

    // Hibiki → Fushi 改名：解压目录从 `hibiki-browser-extension` 改成
    // `fushi-browser-extension`。浏览器的「加载已解压的扩展程序」按**绝对路径**记住
    // 扩展，老用户的 Chrome/Edge 仍指着旧目录 —— 只改新名而不再维护旧目录，等于对
    // 这批用户复发 BUG-726（他们的扩展副本永远停在改名当天的版本）。
    // 守两条：① 旧名仍被 prepare 与 refresh 双路径覆盖；② 旧目录只在已存在时维护，
    // 绝不主动新建（否则新用户凭空多出一个没人加载的僵尸目录）。
    test('legacy extension dir keeps being refreshed after the rename', () {
      final String src = File('lib/src/lookup/browser_extension_installer.dart')
          .readAsStringSync();
      expect(
          src,
          contains(
              "const String _kExtensionDirName = 'fushi-browser-extension';"),
          reason: '新安装必须落在改名后的 fushi-browser-extension');
      expect(
          src,
          contains(
              "const String _kLegacyExtensionDirName = 'hibiki-browser-extension';"),
          reason: '旧目录名是老用户浏览器记着的绝对路径，不能删');

      // ① prepare 路径：解压时一并覆盖旧目录（存在才写）。
      // 函数体起点锚在 `) async {` 之后：这两个函数都带命名参数表，裸 indexOf('\n}')
      // 会先命中参数表的收尾 `}) async {`，截出的「函数体」只有参数列表、断言恒假。
      expect(
          _functionBody(src, 'Future<String> prepareBundledBrowserExtension'),
          contains('_legacyExtensionDestDir()'),
          reason: '安装助手必须同时刷新老用户仍在加载的旧目录');
      expect(
          _functionBody(src, 'Future<String> prepareBundledBrowserExtension'),
          contains('legacy.existsSync()'),
          reason: '旧目录只维护、不新建');

      // ② refresh 路径：启动刷新的候选目录里必须有旧目录。
      expect(
          _functionBody(
              src, 'Future<bool> refreshBundledBrowserExtensionIfStale'),
          contains('_legacyExtensionDestDir()'),
          reason: '启动刷新必须覆盖旧目录，否则老用户复发 BUG-726');

      // 旧目录的取址函数本身不得 create（只解析路径）。
      expect(_functionBody(src, 'Future<Directory> _legacyExtensionDestDir'),
          isNot(contains('create(')),
          reason: '取址函数不得建目录；新建只能由「已存在」分支驱动');
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

/// 从 [src] 里截出以 [signature] 开头的顶层函数体（`) async {` 之后到行首 `}`）。
/// 不能用裸 `indexOf('\n}')` 从签名处起算：带命名参数表的函数会先命中参数表收尾的
/// `}) async {`，截出的字符串只有参数列表，任何 contains 断言都恒假（空转守卫）。
String _functionBody(String src, String signature) {
  final int fn = src.indexOf(signature);
  if (fn < 0) fail('找不到函数签名: $signature');
  final int bodyStart = src.indexOf(') async {', fn);
  if (bodyStart < 0) fail('函数体起点定位失败（签名后无 `) async {`）: $signature');
  final int end = src.indexOf('\n}', bodyStart);
  if (end < 0) fail('函数体终点定位失败（无行首 `}`）: $signature');
  return src.substring(bodyStart, end);
}
