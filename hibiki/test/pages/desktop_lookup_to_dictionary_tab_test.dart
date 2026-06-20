import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'reader_hibiki_page_source_corpus.dart';

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

  test('home_page no longer owns desktop clipboard lookup lifecycle', () {
    final String src = read('lib/src/pages/implementations/home_page.dart');
    expect(src.contains('DesktopLookupOverlay'), isFalse,
        reason: '不再用叠加式 overlay；命中改走切 tab 路径');
    expect(src.contains('DesktopLookupService.instance.addListener'), isFalse,
        reason: '桌面剪贴板查词只能在查词页启用，HomePage 根节点不能常驻监听');
    expect(src.contains('_onDesktopLookupPending'), isFalse,
        reason: '不在查词 tab 时不应消费剪贴板命中并自动切 tab');
    expect(src.contains('externalQuery'), isFalse,
        reason: '查词页现在直接消费 DesktopLookupService.pendingText');
    expect(src.contains('service 唤前台'), isFalse,
        reason: '不能再假设 service 发现剪贴板文本时已唤前台');
  });

  test('HomeDictionaryPage owns desktop lookup service only while mounted', () {
    final String src =
        read('lib/src/pages/implementations/home_dictionary_page.dart');
    expect(src.contains('DesktopLookupService.instance.start'), isTrue,
        reason: '进入查词页时才允许启动桌面剪贴板/热键监听');
    expect(src.contains('DesktopLookupService.instance.stop'), isTrue,
        reason: '离开查词页时必须停止桌面剪贴板/热键监听');
    expect(src.contains('DesktopLookupService.instance.addListener'), isTrue,
        reason: '查词页直接消费剪贴板/热键命中');
    expect(src.contains('DesktopLookupService.instance.removeListener'), isTrue,
        reason: '查词页 dispose 时必须移除监听');
    expect(src.contains('desktopClipboardEnabled'), isTrue,
        reason: '服务启停仍受用户设置控制');
    // _search 支持 autoRead 覆盖（默认 null = 沿用 autoReadOnLookup，向后兼容）。
    expect(src.contains('bool? autoRead'), isTrue,
        reason: '_search 必须支持 autoRead 覆盖参数');
    // 外部查词路径显式不朗读（用户要求「不自动读」）。
    expect(src.contains('autoRead: false'), isTrue,
        reason: '剪贴板/热键查词路径必须显式 autoRead: false，不自动发音');
    expect(src.contains('bringPendingLookupToFront'), isTrue,
        reason: '只有查词页实际消费外部查询、准备搜索时才可唤窗口前台');
    expect(src.contains('pendingRequest'), isTrue,
        reason: '查词页必须消费带来源/前台策略的请求，而不是裸 pendingText');
    // autoRead 默认仍沿用 autoReadOnLookup（不破坏正常输入查词的朗读行为）。
    expect(
        src.contains(
            'autoRead ?? ReaderHibikiSource.instance.autoReadOnLookup'),
        isTrue,
        reason: '默认必须沿用 autoReadOnLookup，向后兼容正常查词的朗读');
  });

  test('settings expose three desktop window modes with updated copy', () {
    final String schema = read('lib/src/settings/settings_schema_lookup.dart');
    final String en = read('lib/i18n/strings.i18n.json');
    final String zh = read('lib/i18n/strings_zh-CN.i18n.json');

    expect(schema.contains('lookup.desktop_clipboard_window_mode'), isTrue,
        reason: '桌面剪贴板查词必须提供窗口模式三段选择');
    expect(schema.contains('DesktopClipboardWindowMode.normal'), isTrue,
        reason: '必须可选择不置顶模式');
    expect(schema.contains('DesktopClipboardWindowMode.lookup'), isTrue,
        reason: '必须可选择仅查词期间置顶模式');
    expect(schema.contains('DesktopClipboardWindowMode.always'), isTrue,
        reason: '必须可选择始终置顶模式');
    expect(en.contains('Only watches the clipboard and global hotkey'), isTrue,
        reason: '英文文案必须说明只在查词页监听');
    expect(zh.contains('仅在查词界面监听剪贴板和全局热键'), isTrue,
        reason: '中文文案必须说明只在查词界面启用桌面剪贴板查词');
    expect(zh.contains('"desktop_clipboard_window_mode": "窗口置顶策略"'), isTrue);
    expect(
        zh.contains('"desktop_clipboard_window_mode_normal": "不置顶"'), isTrue);
    expect(
        zh.contains('"desktop_clipboard_window_mode_lookup": "仅查词期间"'), isTrue);
    expect(
        zh.contains('"desktop_clipboard_window_mode_always": "始终置顶"'), isTrue);
  });

  // TODO-376 返工守卫 A：HomeDictionaryPage 挂载时**无条件**消费一次已存在的
  // pending（不被 desktopClipboardEnabled 门控）。否则「悬浮字幕点词开 + 剪贴板监听
  // 关」的默认用户：点词在切 tab 前设 pending，挂载时若只在剪贴板分支消费 → pending
  // 卡死、查词静默丢失（复核退回高问题 1）。运行时回归见
  // home_dictionary_pending_on_mount_test.dart；这里锁源码接线不变式。
  test('HomeDictionaryPage drains existing pending on mount unconditionally',
      () {
    final String src =
        read('lib/src/pages/implementations/home_dictionary_page.dart');
    // 挂载即排一帧无条件消费已存在 pending（在 initState 里，且不在
    // _startDesktopLookupIfEnabled 的 desktopClipboardEnabled 门控内）。
    final int initStart = src.indexOf('void initState()');
    final int initEnd =
        src.indexOf('Future<void> _startDesktopLookupIfEnabled');
    expect(initStart, isNonNegative);
    expect(initEnd, isNonNegative);
    final String initBody = src.substring(initStart, initEnd);
    expect(initBody.contains('addPostFrameCallback'), isTrue,
        reason: 'initState 必须排一帧消费已存在的 pending');
    expect(initBody.contains('_onDesktopLookupPending()'), isTrue,
        reason: 'initState 的 post-frame 必须无条件消费 pending（不受剪贴板开关门控）');
    // start 分支内不得再调消费（消费已下放到 initState 无条件路径），避免回到
    // 「只有剪贴板开启才消费」的旧门控。
    final int startStart = initEnd;
    final int startEnd = src.indexOf('void _onDesktopLookupPending');
    expect(startEnd, isNonNegative);
    final String startBody = src.substring(startStart, startEnd);
    expect(startBody.contains('_onDesktopLookupPending()'), isFalse,
        reason:
            '消费不能门控在 desktopClipboardEnabled 分支（_startDesktopLookupIfEnabled）里');
  });

  // TODO-376 返工守卫 B：桌面悬浮字幕点词是**显式**手势，由 reader 经
  // AppModel.requestHomeDictionaryTab 请求主窗切到查词 tab；HomePage 监听这个**专用**
  // 信号切 tab，而不是常驻监听 DesktopLookupService（后者由查词页生命周期独占）。
  test('floating-lyric tap routes via explicit home-dictionary-tab request',
      () {
    final String reader = readReaderPageSource();
    final String home = read('lib/src/pages/implementations/home_page.dart');
    final String model = read('lib/src/models/app_model.dart');

    expect(model.contains('requestHomeDictionaryTab'), isTrue,
        reason: 'AppModel 必须暴露显式「打开查词 tab」请求原语');
    expect(reader.contains('appModel.requestHomeDictionaryTab()'), isTrue,
        reason: '悬浮字幕点词必须请求切到查词 tab，让查词页挂载消费 pending');
    expect(home.contains('homeDictionaryTabRequest'), isTrue,
        reason: 'HomePage 监听显式 tab 请求信号切 tab');
    // HomePage 切 tab 走专用信号，不得监听 DesktopLookupService（守卫已在上方钉）。
    expect(home.contains('DesktopLookupService.instance.addListener'), isFalse);
  });

  test('DesktopLookupService 只排队命中词，不在剪贴板回调里抢前台', () {
    final String src = read('lib/src/sync/desktop_lookup_service.dart');
    final int clipboardStart =
        src.indexOf('Future<void> _handleClipboardChange');
    final int hotKeyStart = src.indexOf('Future<void> _onHotKey');
    final int readStart = src.indexOf('Future<String?> _readClipboardText');
    expect(clipboardStart, isNonNegative);
    expect(hotKeyStart, isNonNegative);
    expect(readStart, isNonNegative);
    final String clipboardBody = src.substring(clipboardStart, hotKeyStart);
    final String hotKeyBody = src.substring(hotKeyStart, readStart);
    expect(clipboardBody.contains('submitText(text)'), isTrue,
        reason: '剪贴板命中仍要排队查词请求');
    expect(hotKeyBody.contains('_queueLookupRequest'), isTrue,
        reason: '热键命中仍要排队查词请求');
    expect(clipboardBody.contains('bringPendingLookupToFront'), isFalse,
        reason: '剪贴板变化不能在 UI 尚未消费/搜索前抢前台');
    expect(hotKeyBody.contains('bringPendingLookupToFront'), isFalse,
        reason: '热键也走同一消费路径，避免未开始搜索就抢前台');
  });
}
