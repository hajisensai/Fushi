import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Source guard: 「从本机 mpv 导入」支持手动指定 mpv 配置/着色器目录再搜索（用户诉求），
/// 并把所选目录持久化（appModel.videoMpvShaderDir）下次优先。锁调用点接线（FilePicker
/// 目录选择无 headless 测试；纯发现逻辑由 video_shader_manager_test.dart 覆盖）。
void main() {
  String read(String path) => File(path).readAsStringSync();

  test('着色器视图有「指定 mpv 目录并搜索」流程 + override 优先发现', () {
    final String src =
        read('lib/src/pages/implementations/video_shader_dialog.dart');
    expect(src.contains('_pickMpvDirAndSearch'), isTrue,
        reason: '需有手动指定 mpv 目录并搜索的流程');
    expect(src.contains('getDirectoryPath('), isTrue,
        reason: '用系统目录选择器让用户指定 mpv 目录');
    expect(src.contains('discoverLocalMpvShaders(overrideDir:'), isTrue,
        reason: '按用户指定目录(override)发现着色器');
    expect(src.contains('onMpvDirChanged'), isTrue, reason: '选定目录回调上报以持久化');
    // 自动找不到时转入手动指定（而不是只弹失败提示）。
    expect(src.contains('_pickMpvDirAndSearch(autoFallback: true)'), isTrue,
        reason: '自动找不到时引导手动指定目录');
  });

  test('设置面板 → 视频页把 mpv 目录初值/回调接到 appModel 持久化', () {
    // 阶段B：着色器管理视图的 builder 移入 video_settings_actions.dart——初值
    // 直接读 pref（context.appModel.videoMpvShaderDir），回调经 host
    // （onMpvShaderDirChanged）回视频页持久化；守卫改锁 actions + host + 页面。
    final String actions =
        read('lib/src/media/video/video_settings_actions.dart');
    expect(
        actions.contains('initialMpvDir: context.appModel.videoMpvShaderDir'),
        isTrue,
        reason: '初值取自持久化的 mpv 目录（actions builder 直接读 pref）');
    expect(actions.contains('onMpvShaderDirChanged'), isTrue,
        reason: '选定目录经 host 回调上报');

    final String host =
        read('lib/src/media/video/video_quick_settings_host.dart');
    expect(host.contains('onMpvShaderDirChanged'), isTrue,
        reason: 'host 能力槽声明 mpv 目录回调');

    final String page =
        read('lib/src/pages/implementations/video_hibiki_page.dart');
    expect(page.contains('appModel.setVideoMpvShaderDir('), isTrue,
        reason: '选定目录落库持久化（页面回调）');
  });

  test('着色器视图有「粘贴链接下载」流程（不必装 mpv）', () {
    final String src =
        read('lib/src/pages/implementations/video_shader_dialog.dart');
    expect(src.contains('_downloadFromUrl'), isTrue, reason: '需有粘贴链接下载流程');
    expect(src.contains('downloadShaderFromUrl('), isTrue,
        reason: '走 downloadShaderFromUrl（镜像+校验）');
    expect(src.contains('t.video_shader_download_url'), isTrue,
        reason: '有粘贴链接下载按钮');
  });
}
