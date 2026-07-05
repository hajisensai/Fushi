import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// TODO-1176 守卫：浏览器扩展查词弹窗制卡按钮与 app 内统一——真查重（`+`→`✓`）。
/// 源码扫描，不依赖真机/真浏览器，守住 bridge-shim 的 `duplicateCheck` 不再被桩成恒
/// `false`（那正是扩展弹窗恒显示「+」的根因），而是经 background.js 转发到 server
/// `/api/duplicate`（Anki findNotes / findDuplicateNotes）取真实布尔。两份扩展镜像
/// （随 app 打包的 assets/ 与真源 tools/）都守，且必须逐字节一致。
void main() {
  // flutter test 的 cwd 是 hibiki 包根。两份镜像分别在 assets/ 与 ../tools/。
  final File assetsBridge = File('assets/browser_extension/bridge-shim.js');
  final File toolsBridge = File('../tools/browser-extension/bridge-shim.js');
  final File assetsBackground = File('assets/browser_extension/background.js');
  final File toolsBackground = File('../tools/browser-extension/background.js');

  group('TODO-1176 扩展制卡按钮真查重守卫', () {
    for (final File bridge in <File>[assetsBridge, toolsBridge]) {
      group('bridge-shim.js ${bridge.path}', () {
        test('文件存在', () {
          expect(bridge.existsSync(), isTrue, reason: 'missing ${bridge.path}');
        });

        test('duplicateCheck 不再桩成恒 false', () {
          final String src = bridge.readAsStringSync();
          // 旧桩唯一特征：duplicateCheck 直接 return Promise.resolve(false)。
          // 其它 case 回 Promise.resolve(null)，故此串是恒 false 桩的唯一标记。
          expect(src.contains('Promise.resolve(false)'), isFalse,
              reason: '${bridge.path} 的 duplicateCheck 仍是恒 false 桩');
        });

        test('duplicateCheck 经 chrome.runtime 转发到 duplicate 消息', () {
          final String src = bridge.readAsStringSync();
          expect(src.contains("case 'duplicateCheck':"), isTrue,
              reason: '${bridge.path} 缺 duplicateCheck 分支');
          expect(src.contains('chrome.runtime.sendMessage'), isTrue,
              reason:
                  '${bridge.path} duplicateCheck 未走 chrome.runtime.sendMessage');
          expect(src.contains("type: 'duplicate'"), isTrue,
              reason: '${bridge.path} 未发 duplicate 消息类型');
          expect(src.contains('return false;'), isTrue,
              reason: '${bridge.path} duplicateCheck 缺 fail-soft false 回落');
        });
      });
    }

    for (final File bg in <File>[assetsBackground, toolsBackground]) {
      test('background.js ${bg.path} 有 /api/duplicate fetch 分支', () {
        final String src = bg.readAsStringSync();
        expect(src.contains("msg.type === 'duplicate'"), isTrue,
            reason: '${bg.path} 缺 duplicate 消息处理分支');
        expect(src.contains("fetch(base + '/api/duplicate'"), isTrue,
            reason: '${bg.path} 未 fetch server /api/duplicate');
        expect(src.contains('authHeader(token)'), isTrue,
            reason: '${bg.path} /api/duplicate 未带 Basic auth');
      });
    }

    test('bridge-shim.js 两份镜像逐字节一致', () {
      expect(assetsBridge.readAsBytesSync(), toolsBridge.readAsBytesSync(),
          reason: 'bridge-shim.js 两份镜像不一致');
    });

    test('background.js 两份镜像逐字节一致', () {
      expect(
          assetsBackground.readAsBytesSync(), toolsBackground.readAsBytesSync(),
          reason: 'background.js 两份镜像不一致');
    });
  });
}
