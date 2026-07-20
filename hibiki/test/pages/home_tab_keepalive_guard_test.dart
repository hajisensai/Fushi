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
}
