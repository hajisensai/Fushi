import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 源码守卫：视频播放页只保留**一条**顶栏（BUG-102）。
///
/// 根因：[_buildScaffold] 既给 Scaffold 配了 `appBar: AppBar(...)`，media_kit 的
/// controls 又自带「视频内顶栏」（topButtonBar）——两条顶栏内容重复、互相挤占，对
/// 用户毫无意义。修复是删掉 Scaffold AppBar，把返回/标题/剧集导航并入视频内顶栏，
/// 与播放控制一起随鼠标/触摸显隐。
///
/// 静态扫描守卫：按平台分流的真实 controls 渲染在 widget 测试里依赖 host 平台、
/// 难稳定复现移动/全屏分支（与 [video_mobile_controls_static_test] 同理）。
void main() {
  final File page = File(
    'lib/src/pages/implementations/video_hibiki_page.dart',
  );

  late String src;
  setUpAll(() {
    expect(page.existsSync(), isTrue, reason: '视频页源文件应存在');
    src = page.readAsStringSync();
  });

  test('Scaffold 不再配 AppBar（删掉外层顶栏）', () {
    expect(
      src.contains('appBar: AppBar('),
      isFalse,
      reason: '播放页不应再有 Scaffold AppBar，否则与视频内顶栏重复成两条顶栏',
    );
  });

  test('返回按钮进入视频内顶栏（桌面+移动两套主题各一）', () {
    // 删了 AppBar 自带的返回箭头后，返回必须改由视频内顶栏提供，且全屏可达。
    expect(
      'onPressed: () => Navigator.of(context).maybePop()'
          .allMatches(src)
          .length,
      greaterThanOrEqualTo(2),
      reason: '桌面与移动两套 controls 主题的顶栏都应有返回按钮',
    );
  });

  test('标题进入视频内顶栏（响应式，全屏可刷新）', () {
    // 顶栏左侧显示书名/集名（原 AppBar 的 title 迁移到这里）。标题改用
    // ValueListenableBuilder 监听 _titleNotifier，全屏独立路由不随页面 setState 重建
    // 时也能刷新（BUG-120）；桌面 + 移动两套主题各一处。
    expect(
      'valueListenable: _titleNotifier'.allMatches(src).length,
      greaterThanOrEqualTo(2),
      reason: '桌面与移动顶栏都应用 ValueListenableBuilder 显示响应式标题（BUG-120）',
    );
  });
}
