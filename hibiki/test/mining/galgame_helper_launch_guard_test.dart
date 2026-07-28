import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// 复用同款字符级注释剥除器，避免文档/行/块注释里的示例文字污染静态守卫。
import '../sync/desktop_lookup_foreground_guard_static_test.dart'
    show stripDartComments;

/// galgame 引擎-hook 启动路径的静态守卫（用户报「点击『下载引擎组件』不立即弹窗、
/// 且多次点击叠出多个弹窗」）。
///
/// 两个根因、两组守卫——本层是当前**最强可落地层**：`GalgameHelperInstaller.ensureInjector`
/// 首行 `if (!Platform.isWindows) return false`，非 Windows 测试宿主（CI/本机 test）根本进不了
/// 对话框流程；下载确认对话框又依赖真实网络探测。因此以源码守卫锁死修复结构，防回归。
///
/// 根因 A（点了不弹）：旧实现在弹确认对话框**之前** `await _probeSize()`——一个 10s 连接
///   超时、逐镜像回退的 HTTP HEAD——弱网/GFW 下点击后要等好几秒对话框才出现。修复：对话框
///   立即弹出（大小先填「未知」），探测在后台并发回填。
/// 根因 B（多次点击多弹窗）：两个调用点（游戏库卡片、texthooker 引擎-hook 按钮）的启动方法
///   都没有再入守卫，等待期间重复点击各自开一条启动流程，叠出多个确认对话框。修复：各加一个
///   实例 bool 再入守卫。
void main() {
  /// 读文件并剥注释（只对真实代码跑守卫，文档/行/块注释里的示例文字不算数）。
  String readStripped(String path) =>
      stripDartComments(File(path).readAsStringSync());

  /// 截取某方法体（含花括号）的源码片段。先按括号计数越过参数列表——命名参数 `{ }` 也在
  /// 括号内，不会被误当成方法体起始花括号——再从参数列表右括号之后的第一个 `{` 起做花括号计数。
  String methodBody(String source, String signatureNeedle) {
    final int sigIdx = source.indexOf(signatureNeedle);
    expect(sigIdx, greaterThanOrEqualTo(0), reason: '找不到方法签名：$signatureNeedle');
    // 1) 越过参数列表：从签名首个 '(' 起做括号计数，找到匹配右括号。
    final int parenOpen = source.indexOf('(', sigIdx);
    expect(parenOpen, greaterThanOrEqualTo(0));
    int parenDepth = 0;
    int parenClose = -1;
    for (int i = parenOpen; i < source.length; i++) {
      final String c = source[i];
      if (c == '(') parenDepth++;
      if (c == ')') {
        parenDepth--;
        if (parenDepth == 0) {
          parenClose = i;
          break;
        }
      }
    }
    expect(parenClose, greaterThanOrEqualTo(0),
        reason: '$signatureNeedle 参数列表括号未闭合');
    // 2) 方法体起始花括号 = 参数列表右括号之后第一个 '{'（越过 async / async* 等修饰词）。
    final int braceStart = source.indexOf('{', parenClose);
    expect(braceStart, greaterThanOrEqualTo(0));
    int depth = 0;
    for (int i = braceStart; i < source.length; i++) {
      final String c = source[i];
      if (c == '{') depth++;
      if (c == '}') {
        depth--;
        if (depth == 0) return source.substring(braceStart, i + 1);
      }
    }
    fail('方法 $signatureNeedle 花括号未闭合');
  }

  // 原「根因 A：确认对话框立即弹出，大小探测在后台并发回填」整组已随 BUG-1196 删除：
  // helper 随主包发布，安装路径不联网、不下载、也就没有确认框与大小探测了。
  // 「不得联网」的守卫在 galgame_helper_no_network_guard_test.dart。

  group('根因 B：启动方法有再入守卫，重复点击不叠出多个下载对话框', () {
    void expectReentrancyGuard({
      required String path,
      required String signature,
      required String flag,
    }) {
      final String body = methodBody(readStripped(path), signature);
      expect(
        body.contains(RegExp('if\\s*\\(\\s*$flag\\s*\\)\\s*return')),
        isTrue,
        reason: '$signature 缺再入守卫：应在进入时 `if ($flag) return;`。',
      );
      expect(body.contains('$flag = true'), isTrue,
          reason: '$signature 应置位 $flag = true。');
      expect(body.contains('$flag = false'), isTrue,
          reason: '$signature 应在 finally 复位 $flag = false。');
      expect(body.contains('finally'), isTrue,
          reason: '$signature 守卫复位必须在 finally，避免异常/提前 return 卡死。');
    }

    test('games_library_page._launchGame 有 _launching 守卫', () {
      expectReentrancyGuard(
        path: 'lib/src/pages/implementations/games_library_page.dart',
        signature: 'Future<void> _launchGame(GalgameEntry game)',
        flag: '_launching',
      );
    });

    test('texthooker_page._launchGalgameEngineHook 有 _launchingGalHook 守卫', () {
      expectReentrancyGuard(
        path: 'lib/src/pages/implementations/texthooker_page.dart',
        signature: 'Future<void> _launchGalgameEngineHook()',
        flag: '_launchingGalHook',
      );
    });
  });
}
