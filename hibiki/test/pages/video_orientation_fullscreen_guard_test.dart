import 'package:flutter_test/flutter_test.dart';

import 'video_hibiki_page_source_corpus.dart';

/// 源码守卫 (TODO-149 / BUG-221): 删除视频竖屏模式 + 双击暂停 + 返回手势直接退出。
///
/// 三个子问题同一病根: media_kit 全屏退出回调泄漏, 移动端弹回竖屏。
/// 子1: 自定义 _enterVideoNativeFullscreen / _exitVideoNativeFullscreen 替换 media_kit
///      默认回调 -- 移动端只 landscapeLeft/Right + 沉浸隐栏, 永不空列表; 桌面转调
///      media_kit 默认 (保留 全屏=OS窗口真全屏, 桌面不碰设备方向)。窗口侧 Video 与
///      自建全屏路由 Video 都接这俩回调。
/// 子2: _handleVideoPointerUp 双击按平台分流 -- 移动端双击 = playOrPause, 桌面保留全屏。
/// 子3: 移动端 _toggleVideoFullscreen no-op + 隐藏全屏按钮 -> 移动端永不进全屏路由
///      _pushNeutralizedVideoFullscreen -> 返回只命中页面 PopScope 一次退出。
///
/// 用静态扫描守卫: media_kit 跑不了 headless, 屏幕方向/系统栏/全屏路由/双击手势/系统返回
/// 手势都无法在 widget 测试里真实驱动 (与 _lockLandscapeForVideo/_restoreOrientationOnExit
/// /沉浸锁同范式)。
void main() {
  late String src;

  setUpAll(() {
    // TODO-590 batch11：桌面主题的 `toggleFullscreenOnDoublePress: false` 随
    // 两套 controls 主题搬到 controls_theme.part.dart，故改读合并语料；其余被守卫的
    // 方法（_handleVideoPointerUp / _enterVideoNativeFullscreen / _toggleVideoFullscreen
    // / _buildFullscreenButton / _handleBackOrExit）仍在主壳（语料最前段），
    // methodBody 大括号配对与字符串断言均不受影响。
    src = readVideoHibikiSource();
  });

  /// 取一个方法体 (含起始签名行到匹配的收尾大括号), 用大括号配对避免误截嵌套闭包。
  String methodBody(String source, String signature) {
    final int start = source.indexOf(signature);
    expect(start, greaterThanOrEqualTo(0), reason: '找不到方法签名: $signature');
    // 所有传入签名都以末尾 ' {' 结尾, 函数体起始 { 即签名最后一个字符,
    // 不能用 indexOf('{') -- 会误命中命名参数列表的 { (如 {required bool desktop})。
    final int braceStart = start + signature.length - 1;
    int depth = 0;
    for (int i = braceStart; i < source.length; i++) {
      final String ch = source[i];
      if (ch == '{') depth++;
      if (ch == '}') {
        depth--;
        if (depth == 0) return source.substring(start, i + 1);
      }
    }
    fail('方法体大括号未闭合: $signature');
  }

  group('子1: 全屏方向回调-移动端永不放开方向, 桌面保留原生全屏', () {
    test('两个回调存在且替换 media_kit 默认 (窗口侧+全屏路由 Video 都接)', () {
      expect(src.contains('Future<void> _enterVideoNativeFullscreen() async {'),
          isTrue,
          reason: '缺 _enterVideoNativeFullscreen');
      expect(src.contains('Future<void> _exitVideoNativeFullscreen() async {'),
          isTrue,
          reason: '缺 _exitVideoNativeFullscreen');
      expect(src.contains('onEnterFullscreen: _enterVideoNativeFullscreen,'),
          isTrue,
          reason: '窗口侧 Video 未接 _enterVideoNativeFullscreen');
      expect(
          src.contains('onExitFullscreen: _exitVideoNativeFullscreen,'), isTrue,
          reason: '窗口侧 Video 未接 _exitVideoNativeFullscreen');
      expect(src.contains('onEnterFullscreen: enterNativeFullscreen,'), isTrue,
          reason: '全屏路由 Video 未接 enterNativeFullscreen');
      expect(src.contains('onExitFullscreen: exitNativeFullscreen,'), isTrue,
          reason: '全屏路由 Video 未接 exitNativeFullscreen');
      expect(
        src.contains('final Future<void> Function() enterNativeFullscreen =\n'
            '        stateValue.widget.onEnterFullscreen;'),
        isTrue,
        reason: '全屏路由回调必须来自窗口侧 widget.onEnterFullscreen (同一套)',
      );
    });

    test('移动端进/退全屏只锁两个横屏, 永不空列表', () {
      for (final String sig in <String>[
        'Future<void> _enterVideoNativeFullscreen() async {',
        'Future<void> _exitVideoNativeFullscreen() async {',
      ]) {
        final String body = methodBody(src, sig);
        expect(
          body.contains('setPreferredOrientations(<DeviceOrientation>[])'),
          isFalse,
          reason: '$sig 不得用空列表放开全部方向 (病根: 退全屏弹回竖屏)',
        );
        expect(
          body.contains('DeviceOrientation.landscapeLeft') &&
              body.contains('DeviceOrientation.landscapeRight'),
          isTrue,
          reason: '$sig 移动端分支必须只允许两个横屏',
        );
        expect(body.contains('DeviceOrientation.portraitUp'), isFalse,
            reason: '$sig 不得允许竖屏 (删竖屏模式)');
        expect(body.contains('DeviceOrientation.portraitDown'), isFalse,
            reason: '$sig 不得允许倒置竖屏');
      }
    });

    test('桌面分支转调 media_kit 默认回调 (保留全屏=OS窗口真全屏, 不破坏桌面)', () {
      final String enterBody =
          methodBody(src, 'Future<void> _enterVideoNativeFullscreen() async {');
      final String exitBody =
          methodBody(src, 'Future<void> _exitVideoNativeFullscreen() async {');
      expect(
        enterBody.contains(
            'if (!isMobilePlatform) return defaultEnterNativeFullscreen();'),
        isTrue,
        reason: '进全屏桌面分支必须转调 defaultEnterNativeFullscreen (保留桌面真全屏)',
      );
      expect(
        exitBody.contains(
            'if (!isMobilePlatform) return defaultExitNativeFullscreen();'),
        isTrue,
        reason: '退全屏桌面分支必须转调 defaultExitNativeFullscreen (对称还原OS窗口)',
      );
      expect(enterBody.contains('if (!isMobilePlatform) return;'), isFalse,
          reason: '进全屏桌面分支不得 no-op (会丢桌面OS窗口真全屏)');
      expect(exitBody.contains('if (!isMobilePlatform) return;'), isFalse,
          reason: '退全屏桌面分支不得 no-op');
    });

    test('整个回调链不含真实的空列表 setPreferredOrientations (全文件守卫)', () {
      expect(
        src.contains('setPreferredOrientations(<DeviceOrientation>[])'),
        isFalse,
        reason: '视频页任何 setPreferredOrientations 都不得用空列表 (放开倒置/竖屏)',
      );
    });
  });

  group('子2: 双击按平台分流-移动端 playOrPause, 桌面全屏', () {
    test('移动端双击接 playOrPause (非全屏路由)', () {
      final String body =
          methodBody(src, 'void _handleVideoPointerUp(PointerUpEvent event) {');
      expect(
        body.contains('if (_isDesktopVideoControls) {') &&
            body.contains(
                'unawaited(_controller?.playOrPause() ?? Future<void>.value());'),
        isTrue,
        reason: '移动端双击必须 = playOrPause (不再进 media_kit 全屏路由弹回竖屏)',
      );
    });

    test('桌面双击保留全屏 toggle', () {
      final String body =
          methodBody(src, 'void _handleVideoPointerUp(PointerUpEvent event) {');
      final int desktopBranch = body.indexOf('if (_isDesktopVideoControls) {');
      expect(desktopBranch, greaterThanOrEqualTo(0));
      final int toggleIdx = body.indexOf(
          '_toggleVideoFullscreen(controlsContext)', desktopBranch);
      final int elseIdx = body.indexOf('} else {', desktopBranch);
      expect(toggleIdx, greaterThan(desktopBranch),
          reason: '桌面双击分支应保留 _toggleVideoFullscreen');
      expect(toggleIdx, lessThan(elseIdx),
          reason: '_toggleVideoFullscreen 必须在桌面分支内 (else 是移动端 playOrPause)');
    });

    test('media_kit 桌面主题禁用内置双击全屏 (toggleFullscreenOnDoublePress:false)', () {
      expect(src.contains('toggleFullscreenOnDoublePress: false'), isTrue,
          reason: '桌面主题必须禁用 media_kit 内置双击全屏 (避免与 app 双击重复触发)');
    });
  });

  group('子3: 移动端永不进全屏路由 - 系统返回只一段退出', () {
    test('_toggleVideoFullscreen 移动端 no-op (杜绝所有入口推进全屏路由)', () {
      final String body = methodBody(
          src, 'Future<void> _toggleVideoFullscreen(BuildContext context) {');
      expect(
        body.contains('if (isMobilePlatform) return Future<void>.value();'),
        isTrue,
        reason: '移动端 _toggleVideoFullscreen 必须 no-op (否则全屏路由进栈 两段式返回)',
      );
      final int gate =
          body.indexOf('if (isMobilePlatform) return Future<void>.value();');
      final int push = body.indexOf('_pushNeutralizedVideoFullscreen(context)');
      expect(gate, greaterThanOrEqualTo(0));
      expect(push, greaterThan(gate), reason: '移动端早返回必须排在进全屏路由之前');
    });

    test('移动端隐藏全屏按钮 (底栏无全屏入口, 永不进全屏路由)', () {
      final String body = methodBody(
          src, 'Widget _buildFullscreenButton({required bool desktop}) {');
      expect(
        body.contains('if (isMobilePlatform) return const SizedBox.shrink();'),
        isTrue,
        reason: '移动端全屏按钮必须隐藏 (与双击不进全屏/_toggleVideoFullscreen no-op 一致)',
      );
    });

    test('系统返回/Esc 退出经 _handleBackOrExit, 不依赖先退全屏', () {
      expect(src.contains('Future<void> _handleBackOrExit() async {'), isTrue,
          reason: '缺统一返回收口 _handleBackOrExit');
      final String body =
          methodBody(src, 'Future<void> _handleBackOrExit() async {');
      expect(body.contains('nav.pop()'), isTrue,
          reason: '_handleBackOrExit 应直接退页 (无全屏路由中间态)');
      expect(body.contains('_pushNeutralizedVideoFullscreen'), isFalse,
          reason: '返回收口不得反向进全屏路由');
    });
  });
}
