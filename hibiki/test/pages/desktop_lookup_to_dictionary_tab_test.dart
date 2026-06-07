import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

/// 根因守卫：桌面剪贴板/热键查词不再 push 一个独立的全屏查词页（旧
/// [DesktopLookupOverlay] 方案），而是统一为「唤前台 → 切到首页『查词』tab → 预填词
/// 触发查询、不自动朗读」。理由：用户要求剪贴板/热键查词与首页查词同一套体验，
/// 不叠新页面、不自动读发音。
///
/// 该行为的运行时表面（HomeDictionaryPage 的查词结果区是 DictionaryPopupWebView +
/// 同坐标系嵌套弹窗的 Stack，且 AppModel 未初始化时 searchDictionary 触及 late 的
/// dictRepo）在 headless widget 测试里无法稳定渲染——与 BUG-054 同类，故本仓沿用
/// 源码扫描守卫锁住接线不变式（真机复测覆盖运行时）。
void main() {
  String read(String p) => File(p).readAsStringSync();

  test('旧的 desktop_lookup_overlay.dart 已删除（不再 push 独立查词页）', () {
    expect(
      File('lib/src/pages/implementations/desktop_lookup_overlay.dart')
          .existsSync(),
      isFalse,
      reason: '剪贴板/热键查词改走首页查词 tab，独立 overlay 页应整体移除',
    );
  });

  test('pages.dart 不再导出已删除的 desktop_lookup_overlay', () {
    final String src = read('lib/pages.dart');
    expect(src.contains('desktop_lookup_overlay'), isFalse,
        reason: 'overlay 文件已删，barrel 不能再导出它');
  });

  test('home_page 监听 DesktopLookupService 并切到查词 tab（而非挂 overlay）', () {
    final String src = read('lib/src/pages/implementations/home_page.dart');
    // 不再挂叠加式 overlay。
    expect(src.contains('DesktopLookupOverlay'), isFalse,
        reason: '不再用叠加式 overlay；命中改走切 tab 路径');
    // 桌面常驻根 State 监听 service（buildBody 按 tab 单建，查词页不在该 tab 时不存在，
    // 收不到 service 通知，必须由 home_page 接并切 tab）。
    expect(src.contains('DesktopLookupService.instance.addListener'), isTrue,
        reason: 'home_page 必须监听 DesktopLookupService 的命中通知');
    // 命中后切到「查词」tab。
    expect(src.contains('_selectTab(HomeTab.dictionaries)'), isTrue,
        reason: '剪贴板/热键命中后应切到首页查词 tab');
    // 命中后清 pending，避免重复触发同一段文本。
    expect(src.contains('clearPending'), isTrue,
        reason: '消费命中文本后必须 clearPending');
    // 通过 externalQuery 信号把词下传给查词页。
    expect(src.contains('externalQuery'), isTrue,
        reason: 'home_page 通过 externalQuery 信号把命中词下传给查词页');
  });

  test('HomeDictionaryPage 外部查词入口预填并触发查询、且不自动朗读', () {
    final String src =
        read('lib/src/pages/implementations/home_dictionary_page.dart');
    // 新增携词的外部查询入口。
    expect(src.contains('externalQuery'), isTrue,
        reason: '查词页必须有携词的外部查询入口（剪贴板/热键预填）');
    // _search 支持 autoRead 覆盖（默认 null = 沿用 autoReadOnLookup，向后兼容）。
    expect(src.contains('bool? autoRead'), isTrue,
        reason: '_search 必须支持 autoRead 覆盖参数');
    // 外部查词路径显式不朗读（用户要求「不自动读」）。
    expect(src.contains('autoRead: false'), isTrue,
        reason: '剪贴板/热键查词路径必须显式 autoRead: false，不自动发音');
    // autoRead 默认仍沿用 autoReadOnLookup（不破坏正常输入查词的朗读行为）。
    expect(
        src.contains(
            'autoRead ?? ReaderHibikiSource.instance.autoReadOnLookup'),
        isTrue,
        reason: '默认必须沿用 autoReadOnLookup，向后兼容正常查词的朗读');
  });
}
