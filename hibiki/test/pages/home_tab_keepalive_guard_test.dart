import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 根因守卫（远端视频/书「每次进 tab 重新加载」）：
///
/// 症状——切到书架 / 视频 tab 每次都重新联网拉远端列表 + 封面。真根因是顶层 tab 的
/// [HomePage.buildBody] 曾用 `switch(_visibleTab)` 每次返回**新页面 widget**、无
/// `IndexedStack` / 保活，切走再切回 → 旧页面 State 销毁重建 → `initState` 重跑
/// `listRemoteVideos()` / `listRemoteBooks()`（二者都**无持久缓存**，每次实打实打网络，
/// 远端封面只走进程内 ImageCache）。
///
/// 修复——让**书架 + 视频 + 游戏**保活（State 常驻、用 `Offstage` 隐藏未选中者），
/// 切回沿用已加载列表/封面/滚动位置；游戏保活则保证 Hook 会话不因切 tab 停止。
/// 其余 tab（词典 / 设置）**故意不保活**、
/// 按需重建，以保留其依赖 initState 挂载的语义——尤其 HomeDictionaryPage 靠切到查词
/// tab 时 re-mount 消费桌面悬浮字幕 pending 查词（TODO-376，见
/// desktop_lookup_to_dictionary_tab_test.dart）。
///
/// HomePage 的运行时表面在 headless widget 测试里无法稳定挂载（AppModel 未初始化、
/// late dictRepo；同 desktop_lookup_to_dictionary_tab_test.dart 的说明），故这里用源码
/// 扫描锁住保活不变式；保活机制本身的行为验证见 home_tab_keepalive_mechanism_test.dart。
void main() {
  final String src =
      File('lib/src/pages/implementations/home_page.dart').readAsStringSync();

  test('保活集合包含书架、视频和游戏', () {
    final int start = src.indexOf('_keepAliveTabs');
    expect(start, isNonNegative,
        reason: 'buildBody 必须声明保活 tab 集合 _keepAliveTabs');
    // 取声明处到其初始化字面量结束的一小段，验证集合内容。
    final int braceOpen = src.indexOf('{', start);
    final int braceClose = src.indexOf('}', braceOpen);
    expect(braceOpen, isNonNegative);
    expect(braceClose, greaterThan(braceOpen));
    final String literal = src.substring(braceOpen, braceClose);
    expect(literal.contains('HomeTab.books'), isTrue,
        reason: '书架 tab 必须保活（远端书列表 + 封面无持久缓存）');
    expect(literal.contains('HomeTab.video'), isTrue,
        reason: '视频 tab 必须保活（远端视频列表 + 封面无持久缓存）');
    expect(literal.contains('HomeTab.games'), isTrue,
        reason: '游戏 tab 必须保活（切换导航不能 dispose 正在进行的 Hook 会话）');
    expect(literal.contains('HomeTab.dictionaries'), isFalse,
        reason: '查词 tab 不得保活：靠 re-mount 消费桌面悬浮字幕 pending（TODO-376）');
    expect(literal.contains('HomeTab.settings'), isFalse,
        reason: '设置 tab 不得保活：保留其 initState 挂载语义（现状不变）');
  });

  test('buildBody 用 Offstage 保活而非 switch 每次重建', () {
    expect(src.contains('Widget buildBody()'), isTrue);
    // 保活 tab 用 Offstage 隐藏（State 常驻）；未访问不预建；隐藏时关 TickerMode。
    expect(src.contains('Offstage('), isTrue,
        reason: '保活 tab 必须用 Offstage 隐藏未选中者以保 State 存活');
    expect(src.contains('_visitedKeepAliveTabs'), isTrue,
        reason: '保活 tab 必须惰性构建（访问过才建），避免启动即预拉未访问 tab 的远端');
    expect(src.contains('offstage: visible != tab'), isTrue,
        reason: '仅当前可见的保活 tab 露出，其余 Offstage 隐藏但不销毁');
  });

  test('非保活 tab 仍按需构建（切走即销毁，保留挂载语义）', () {
    // 非保活分支：只在选中时构建、切走即销毁（KeyedSubtree gate）。
    expect(src.contains('if (!_keepAliveTabs.contains(visible))'), isTrue,
        reason: '非保活 tab 只在可见时构建，保持每次切入重新 initState');
  });

  test('BUG-992/818: 保活的书架/视频页必须监听 tab 信号，切回时自动重拉远端', () {
    // 保活 → initState 只跑一次 → 远端列表不会因切回而重拉（本文件顶注释所述）。
    // 补偿：切回自己的 tab 时重拉远端一次，否则别的设备新增/首载失败的远端条目要
    // 用户手动下拉才出来（BUG-992 书架 / BUG-994 视频）。
    //
    // 视频侧（BUG-994）：homeShellTabNotifier 监听三件套已收口到
    // BaseModuleTabPageState（shellTab / onTabActivated，审计 Phase 3.6），视频页
    // 只声明覆写；守卫改锁「基类接线（含 dispose 防泄漏）+ 页面覆写」两半。
    final String moduleTabSrc =
        File('lib/src/pages/base_module_tab_page.dart').readAsStringSync();
    final String videoSrc =
        File('lib/src/pages/implementations/home_video_page.dart')
            .readAsStringSync();
    final String bookSrc =
        File('lib/src/pages/implementations/reader_hibiki_history_page.dart')
            .readAsStringSync();

    expect(moduleTabSrc.contains('homeShellTabNotifier.addListener'), isTrue,
        reason: 'BUG-994：模块 tab 基类必须监听 tab 信号');
    expect(moduleTabSrc.contains('homeShellTabNotifier.removeListener'), isTrue,
        reason: 'BUG-994：模块 tab 基类 dispose 必须移除监听（防泄漏）');
    expect(RegExp(r'HomeTab get shellTab => HomeTab\.video').hasMatch(videoSrc),
        isTrue,
        reason: 'BUG-994：视频页必须声明 shellTab = HomeTab.video（切回才重拉）');
    expect(videoSrc.contains('void onTabActivated()'), isTrue,
        reason: 'BUG-994：视频页必须覆写 onTabActivated 重拉远端');

    expect(bookSrc.contains('homeShellTabNotifier.addListener'), isTrue,
        reason: 'BUG-992：书架页必须监听 tab 信号');
    expect(bookSrc.contains('homeShellTabNotifier.removeListener'), isTrue,
        reason: 'BUG-992：书架页 dispose 必须移除监听（防泄漏）');
    expect(RegExp(r'HomeTab\.books').hasMatch(bookSrc), isTrue,
        reason: 'BUG-992：切回书架 tab（HomeTab.books）才重拉');
  });

  test('BUG-995: 视频页概览+继续观看在只有远端视频时也显示并计入远端', () {
    final String videoSrc =
        File('lib/src/pages/implementations/home_video_page.dart')
            .readAsStringSync();
    // 概览门控必须含 remoteVideos（否则无本地视频时整块消失）。
    expect(
        videoSrc.contains('all.isNotEmpty || remoteVideos.isNotEmpty'), isTrue,
        reason: 'BUG-995：概览门控必须并入 remoteVideos');
    // _buildOverviewSection 必须接收 remoteVideos 并把它们并进概览 entries。
    expect(
        RegExp(r'_buildOverviewSection\(\s*[\s\S]*?List<RemoteVideoInfo>')
            .hasMatch(videoSrc),
        isTrue,
        reason: 'BUG-995：_buildOverviewSection 必须接收 remoteVideos 计入总数/继续观看');
    // 远端续播卡必须存在（TODO-2486 起 hero 变体换形为「继续观看」行的远端卡，
    // 远端续播仍走 _openRemote——只看远端视频时也有续播入口）。
    expect(videoSrc.contains('_buildContinueRemoteCard'), isTrue,
        reason: 'BUG-995：只看远端视频时「继续观看」行必须有远端续播卡');
  });
}
