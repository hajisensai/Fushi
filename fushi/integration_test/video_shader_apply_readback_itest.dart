// 真机集成测试（Windows 桌面 + media_kit 原生 libmpv）：证实 BUG-759 根因与修复。
//
// 直接建 media_kit Player，用两个真实临时 .glsl 走 applyShadersToPlayer 下发着色器，再
// getProperty('glsl-shaders') 回读 libmpv 实际生效的着色器链：
//   ① 修复后（change-list append）：回读非空、含两个路径 → 着色器真进渲染管线。
//   ② 对照被证伪的旧法（setProperty('glsl-shaders-append', ...)）：回读为空 → 复现
//      「Anime4K 开了跟没开一样」的空下发根因（media_kit 丢弃 mpv 返回码、静默失败）。
//
// 运行：fushi/ 下 `.\tool\run_windows_itest.ps1 integration_test\video_shader_apply_readback_itest.dart`
// 不联网、不需测试视频——glsl-shaders 是 mpv ctx 级属性，无需 open 文件即可读写。
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path/path.dart' as p;

import 'package:fushi/src/media/video/video_shader_manager.dart';

/// 最小合法 mpv 用户着色器（MAIN 直通，能被 mpv 解析/编译）。
const String _kPassthroughShader = '//!HOOK MAIN\n'
    '//!BIND HOOKED\n'
    'vec4 hook() { return HOOKED_tex(HOOKED_pos); }\n';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'applyShadersToPlayer 经 change-list 真写穿 glsl-shaders（旧 append property 空下发）',
    (WidgetTester tester) async {
      MediaKit.ensureInitialized();

      final Directory dir =
          Directory.systemTemp.createTempSync('shader_readback_');
      final File a = File(p.join(dir.path, 'A_Restore.glsl'))
        ..writeAsStringSync(_kPassthroughShader);
      final File b = File(p.join(dir.path, 'B_Upscale.glsl'))
        ..writeAsStringSync(_kPassthroughShader);
      final List<String> paths = <String>[a.path, b.path];

      final Player player = Player();
      try {
        final dynamic native = player.platform;
        expect(native, isNotNull, reason: '桌面应为 libmpv NativePlayer');

        // ── ① 修复路径：applyShadersToPlayer → change-list append → 回读非空 ──
        await applyShadersToPlayer(player, paths);
        final String afterFix =
            await native.getProperty('glsl-shaders') as String;
        debugPrint('[shader-readback] after change-list apply: "$afterFix"');
        expect(afterFix.contains('A_Restore.glsl'), isTrue,
            reason: 'change-list append 后 glsl-shaders 必须含第一个着色器路径');
        expect(afterFix.contains('B_Upscale.glsl'), isTrue,
            reason: 'change-list append 后 glsl-shaders 必须含第二个着色器路径');

        // ── ② 对照被证伪的旧法：clr 后用 glsl-shaders-append property → 回读空 ──
        await native
            .command(<String>['change-list', 'glsl-shaders', 'clr', '']);
        for (final String path in paths) {
          // 这正是 BUG-759 的旧写法：作为 property 名非法，mpv 返回
          // PROPERTY_NOT_FOUND，media_kit 丢弃返回码、静默失败。
          await native.setProperty('glsl-shaders-append', path);
        }
        final String afterOld =
            await native.getProperty('glsl-shaders') as String;
        debugPrint(
            '[shader-readback] after legacy append property: "$afterOld"');
        expect(afterOld.trim(), isEmpty,
            reason: 'glsl-shaders-append 作为 property 空下发——复现 BUG-759 根因');
      } finally {
        await player.dispose();
        try {
          dir.deleteSync(recursive: true);
        } catch (_) {}
      }
    },
    skip: !Platform.isWindows /* needs Windows desktop + media_kit native */,
  );
}
