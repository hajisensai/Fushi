import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// 复用同款字符级注释剥除器，避免文档/行/块注释里的示例文字污染静态守卫。
import '../sync/desktop_lookup_foreground_guard_static_test.dart'
    show stripDartComments;

/// BUG-1076 静态守卫（最强可落地层：`ensureInjector` 首行 `if (!Platform.isWindows)`
/// 早退，CI 测试宿主进不了真实路径；后台更新又依赖真实网络，故以源码守卫锁死修复结构）。
///
/// 根因结构：旧实现把 helper 自动更新绑在「点启动游戏」那一刻（`_maybeAutoUpdate`），
/// 被迫给 sha 侧车探测设 6s 自残上限——直连 GitHub 时好时坏的网络下必然超时 →
/// `remoteSha = null` → 永远静默放弃，helper 停在旧版。修复：更新时机挪到 app 启动
/// 后台（`updateInstalledHelpersInBackground`，宽松预算、全静默），游戏启动路径在安装
/// 完整时零网络。
void main() {
  const String installer = 'lib/src/mining/galgame_helper_installer.dart';
  const String mainDart = 'lib/main.dart';

  String readStripped(String path) =>
      stripDartComments(File(path).readAsStringSync());

  /// 截取某方法体源码片段：先按括号计数越过参数列表，再从其后的第一个 `{` 做花括号计数。
  String methodBody(String source, String signatureNeedle) {
    final int sigIdx = source.indexOf(signatureNeedle);
    expect(sigIdx, greaterThanOrEqualTo(0), reason: '找不到方法签名：$signatureNeedle');
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

  group('游戏启动路径零网络（6s 自残上限不得回归）', () {
    test('installer 不得再出现 6s 超时或 _maybeAutoUpdate', () {
      final String src = readStripped(installer);
      expect(src.contains(RegExp(r'seconds:\s*6\s*\)')), isFalse,
          reason: '6s 是旧实现在游戏启动关键路径上抢跑的自残上限（弱网必然放弃更新）。'
              '更新已挪到 app 启动后台，任何 6s 硬超时都不该回来。');
      expect(src.contains('_maybeAutoUpdate'), isFalse,
          reason: '启动时刻的自动更新已整体删除，由后台静默更新取代。');
    });

    test('ensureInjector 本体不做任何网络探测', () {
      final String body = methodBody(
        readStripped(installer),
        'Future<bool> ensureInjector(',
      );
      expect(body.contains('HttpClient('), isFalse,
          reason: '安装完整时游戏启动路径必须零网络。');
      expect(body.contains('_fetchSha256('), isFalse);
      expect(body.contains('.timeout('), isFalse);
    });

    test('ensureInjector 检查文件前先过换入串行门', () {
      final String body = methodBody(
        readStripped(installer),
        'Future<bool> ensureInjector(',
      );
      expect(body.contains('await _extractionGate'), isTrue,
          reason: '后台换入与启动路径必须串行，否则可能读到半换入状态。');
    });
  });

  group('后台静默更新：无 UI、宽松预算、经换入串行门', () {
    test('后台路径不得引用任何 UI（对话框 / toast / BuildContext）', () {
      final String src = readStripped(installer);
      for (final String signature in <String>[
        'static Future<void> updateInstalledHelpersInBackground(',
        'Future<void> _updateArchSilently(',
      ]) {
        final String body = methodBody(src, signature);
        expect(body.contains('BuildContext'), isFalse,
            reason: '$signature 必须全静默，不依赖 UI。');
        expect(body.contains('showAppDialog'), isFalse);
        expect(body.contains('HibikiToast'), isFalse);
        expect(body.contains('Navigator'), isFalse);
      }
    });

    test('sha 侧车预算 ≥ 30s（直连 + 5 镜像要有轮询余量）', () {
      final RegExpMatch? m = RegExp(
        r'kGalgameHelperBackgroundShaTimeout\s*=\s*Duration\(seconds:\s*(\d+)\)',
      ).firstMatch(readStripped(installer));
      expect(m, isNotNull, reason: '后台 sha 预算必须是命名常量，供本守卫审计。');
      expect(int.parse(m!.group(1)!), greaterThanOrEqualTo(30));
    });

    test('安装核心走 staging 换入（不得就地覆盖安装目录）并串行化', () {
      final String body = methodBody(
        readStripped(installer),
        'Future<void> _installCore(',
      );
      expect(body.contains('galgameHelperSwapInstall('), isTrue,
          reason: '被映射 DLL 覆盖写会半途失败留混版本（BUG-1076 ④），必须换入式安装。');
      expect(body.contains('_serializeExtraction'), isTrue,
          reason: '换入必须挂到 _extractionGate 上与启动路径串行。');
    });
  });

  group('main.dart 挂载', () {
    test('app 启动块必须以 unawaited 挂后台更新', () {
      final String src = readStripped(mainDart);
      expect(
        src.contains(RegExp(r'unawaited\(\s*GalgameHelperInstaller\s*'
            r'\.updateInstalledHelpersInBackground\(\)\s*\)')),
        isTrue,
        reason: '更新时机 = app 启动后台；不挂载则 helper 永远没有更新入口。',
      );
    });
  });
}
