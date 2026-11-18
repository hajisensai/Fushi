import 'dart:io';

import 'package:test/test.dart';

import '../helpers/source_guard.dart';

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
/// 查词与复习后来也保活（BUG-4849：不保活时每次切入整页重挂，查词页还要
/// 每次冷建一个查词 WebView）。它们原先靠「切入即重挂」做的事改成显式的「切入时
/// 做」，由下面「保活的查词 / 复习页……」那条守卫钉住——尤其 HomeDictionaryPage
/// 消费桌面悬浮字幕 pending 查词（TODO-376）。设置与网页仍按需重建。
///
/// HomePage 的运行时表面在 headless widget 测试里无法稳定挂载（AppModel 未初始化、
/// late dictRepo；同 desktop_lookup_to_dictionary_tab_test.dart 的说明），故这里用源码
/// 扫描锁住保活不变式；保活机制本身的行为验证见 home_tab_keepalive_mechanism_test.dart。
void main() {
  final String src = File(
    'lib/src/pages/implementations/home_page.dart',
  ).readAsStringSync();

  test('保活集合包含书架、视频和游戏', () {
    final int start = src.indexOf('_keepAliveTabs');
    expect(
      start,
      isNonNegative,
      reason: 'buildBody 必须声明保活 tab 集合 _keepAliveTabs',
    );
    // 取声明处到其初始化字面量结束的一小段，验证集合内容。
    final int braceOpen = src.indexOf('{', start);
    final int braceClose = src.indexOf('}', braceOpen);
    expect(braceOpen, isNonNegative);
    expect(braceClose, greaterThan(braceOpen));
    final String literal = src.substring(braceOpen, braceClose);
    expect(
      literal.contains('HomeTab.books'),
      isTrue,
      reason: '书架 tab 必须保活（远端书列表 + 封面无持久缓存）',
    );
    expect(
      literal.contains('HomeTab.video'),
      isTrue,
      reason: '视频 tab 必须保活（远端视频列表 + 封面无持久缓存）',
    );
    expect(
      literal.contains('HomeTab.games'),
      isTrue,
      reason: '游戏 tab 必须保活（切换导航不能 dispose 正在进行的 Hook 会话）',
    );
    expect(
      literal.contains('HomeTab.browse'),
      isTrue,
      reason:
          '浏览 tab 必须保活（来源 / 发现页签挂载即对全部来源联网，'
          '切回不能丢搜索与结果再重拉；PR #1707 审查）',
    );
    expect(
      literal.contains('HomeTab.home'),
      isTrue,
      reason:
          '首页 dashboard 必须保活（2026-10 切 tab 卡顿：不保活时每次切回都整页'
          '重挂载、重跑整批统计聚合、重放进场动画）',
    );
    expect(
      literal.contains('HomeTab.dictionaries'),
      isTrue,
      reason:
          '查词 tab 必须保活（BUG-4849：不保活时每次切入整页重挂，并冷建 / '
          '销毁一个预热用的查词 WebView）',
    );
    expect(
      literal.contains('HomeTab.srs'),
      isTrue,
      reason: '复习 tab 必须保活（BUG-4849：不保活时每次切入整页重挂）',
    );
    expect(
      literal.contains('HomeTab.settings'),
      isFalse,
      reason: '设置 tab 不得保活：每次进入从根页开始，保留其 initState 挂载语义',
    );
  });

  test('保活的查词 / 复习页把「切入即重挂」做的事改成显式的「切入时做」', () {
    final String dictSrc = File(
      'lib/src/pages/implementations/home_dictionary_page.dart',
    ).readAsStringSync();
    final String srsSrc = File(
      'lib/src/pages/implementations/srs/srs_deck_list_page.dart',
    ).readAsStringSync();

    // 查词页：藏着时不消费待查词 / 聚焦请求（与「还没挂载」同义），由藏转显后再消费。
    final int pending = dictSrc.indexOf('void _onDesktopLookupPending() {');
    expect(pending, isNonNegative);
    expect(
      dictSrc
          .substring(pending, dictSrc.indexOf('clearPending()', pending))
          .contains('if (!_sectionVisible) return;'),
      isTrue,
      reason:
          'TODO-376：藏着的保活查词页不得消费待查词——否则用户在别的 tab 上时词被'
          '看不见的页面吞掉，切过来什么都没有',
    );
    final int focus = dictSrc.indexOf('void _consumeFocusRequest() {');
    expect(focus, isNonNegative);
    expect(
      dictSrc
          .substring(focus, dictSrc.indexOf('signal.value = null;', focus))
          .contains('if (!_sectionVisible) return;'),
      isTrue,
      reason: '藏着时聚焦会被外层 ExcludeFocus 吞掉，请求必须留到变成可见之后',
    );
    final int deps = dictSrc.indexOf('void didChangeDependencies() {');
    expect(deps, isNonNegative);
    final String depsBody = dictSrc.substring(
      deps,
      dictSrc.indexOf('void _schedulePopupOverlayRebuild()', deps),
    );
    expect(
      depsBody.contains('SectionVisibility.of(context)') &&
          depsBody.contains('_onDesktopLookupPending();') &&
          depsBody.contains('_consumeFocusRequest();'),
      isTrue,
      reason: '由藏转显必须补消费待查词与聚焦请求（原先靠重新挂载在 initState 里做）',
    );

    // 复习页：切回时刷新已配对主机（原先靠每次挂载在 initState 里做）。
    expect(
      srsSrc.contains('homeShellTabNotifier.addListener(_onShellTabActivated)'),
      isTrue,
      reason: '复习页必须监听 tab 信号',
    );
    expect(
      srsSrc.contains(
        'homeShellTabNotifier.removeListener(_onShellTabActivated)',
      ),
      isTrue,
      reason: '复习页 dispose 必须移除监听（防泄漏）',
    );
    expect(
      srsSrc.contains('SectionPopScope('),
      isTrue,
      reason: '藏着的保活复习页不得拦系统返回',
    );
  });

  test('buildBody 用 Offstage 保活而非 switch 每次重建', () {
    expect(src.contains('Widget buildBody()'), isTrue);
    // 保活 tab 用 Offstage 隐藏（State 常驻）；未访问不预建；隐藏时关 TickerMode。
    expect(
      src.contains('Offstage('),
      isTrue,
      reason: '保活 tab 必须用 Offstage 隐藏未选中者以保 State 存活',
    );
    expect(
      src.contains('_visitedKeepAliveTabs'),
      isTrue,
      reason: '保活 tab 必须惰性构建（访问过才建），避免启动即预拉未访问 tab 的远端',
    );
    expect(
      src.contains('offstage: visible != tab'),
      isTrue,
      reason: '仅当前可见的保活 tab 露出，其余 Offstage 隐藏但不销毁',
    );
  });

  test('隐藏的保活 tab 复用被藏起时构建的那份 widget（切 tab 不重建看不见的页）', () {
    // 2026-10 切 tab 卡顿：buildBody 每次 new 页面 widget，Offstage 里看不见的
    // 视频页 / 首页也跟着整页 build。隐藏 tab 必须走缓存，可见 tab 才重建。
    expect(
      src.contains('_keepAliveTabContent(tab, visible: visible == tab)'),
      isTrue,
      reason: '保活 tab 内容必须经 _keepAliveTabContent 按可见性取缓存',
    );
    expect(
      src.contains('_hiddenTabContent[tab] ??= _buildTabContent(tab)'),
      isTrue,
      reason: '隐藏中的保活 tab 必须复用同一个 widget 实例，Flutter 才会跳过子树',
    );
    expect(
      src.contains('_hiddenTabContent.remove(tab)'),
      isTrue,
      reason: '重新可见时必须丢掉缓存、按最新状态重建',
    );
  });

  test('非保活 tab 仍按需构建（切走即销毁，保留挂载语义）', () {
    // 非保活分支：只在选中时构建、切走即销毁（KeyedSubtree gate）。
    expect(
      src.contains('if (!_keepAliveTabs.contains(visible))'),
      isTrue,
      reason: '非保活 tab 只在可见时构建，保持每次切入重新 initState',
    );
  });

  test('BUG-992/818: 保活的书架/视频页必须监听 tab 信号，切回时自动重拉远端', () {
    // 保活 → initState 只跑一次 → 远端列表不会因切回而重拉（本文件顶注释所述）。
    // 补偿：切回自己的 tab 时重拉远端一次，否则别的设备新增/首载失败的远端条目要
    // 用户手动下拉才出来（BUG-992 书架 / BUG-994 视频）。
    //
    // 视频侧（BUG-994）：homeShellTabNotifier 监听三件套已收口到
    // BaseModuleTabPageState（shellTab / onTabActivated，审计 Phase 3.6），视频页
    // 只声明覆写；守卫改锁「基类接线（含 dispose 防泄漏）+ 页面覆写」两半。
    final String moduleTabSrc = File(
      'lib/src/pages/base_module_tab_page.dart',
    ).readAsStringSync();
    final String videoSrc = File(
      'lib/src/pages/implementations/home_video_page.dart',
    ).readAsStringSync();
    final String bookSrc = File(
      'lib/src/pages/implementations/reader_fushi_history_page.dart',
    ).readAsStringSync();

    expect(
      moduleTabSrc.contains('homeShellTabNotifier.addListener'),
      isTrue,
      reason: 'BUG-994：模块 tab 基类必须监听 tab 信号',
    );
    expect(
      moduleTabSrc.contains('homeShellTabNotifier.removeListener'),
      isTrue,
      reason: 'BUG-994：模块 tab 基类 dispose 必须移除监听（防泄漏）',
    );
    expect(
      RegExp(r'HomeTab get shellTab => HomeTab\.video').hasMatch(videoSrc),
      isTrue,
      reason: 'BUG-994：视频页必须声明 shellTab = HomeTab.video（切回才重拉）',
    );
    expect(
      videoSrc.contains('void onTabActivated()'),
      isTrue,
      reason: 'BUG-994：视频页必须覆写 onTabActivated 重拉远端',
    );

    expect(
      bookSrc.contains('homeShellTabNotifier.addListener'),
      isTrue,
      reason: 'BUG-992：书架页必须监听 tab 信号',
    );
    expect(
      bookSrc.contains('homeShellTabNotifier.removeListener'),
      isTrue,
      reason: 'BUG-992：书架页 dispose 必须移除监听（防泄漏）',
    );
    expect(
      RegExp(r'HomeTab\.books').hasMatch(bookSrc),
      isTrue,
      reason: 'BUG-992：切回书架 tab（HomeTab.books）才重拉',
    );
  });

  test('BUG-995: 视频页概览+继续观看在只有远端视频时也显示并计入远端', () {
    final String videoSrc = File(
      'lib/src/pages/implementations/home_video_page.dart',
    ).readAsStringSync();
    // 概览门控必须含远端条目（否则无本地视频时整块消失）。反馈 ZjKzpkfZ1N
    // （13bf9d1b01）起首页分区吃未过滤的远端全量 `homeRemote`（首页没有筛选入口，
    // 不能被别的分区选中的标签筛空），门控随之改成并入 homeRemote。
    expect(
      videoSrc.contains('all.isNotEmpty || homeRemote.isNotEmpty'),
      isTrue,
      reason: 'BUG-995：概览门控必须并入远端条目（homeRemote）',
    );
    expect(
      RegExp(
        r'final List<RemoteVideoInfo> homeRemote = <RemoteVideoInfo>\[\s*'
        r'for \(final RemoteVideoInfo v in _visibleRemoteVideos\(',
      ).hasMatch(videoSrc),
      isTrue,
      reason: 'BUG-995：homeRemote 必须取自远端可见条目（_visibleRemoteVideos）',
    );
    // _buildOverviewSection 必须接收 remoteVideos 并把它们并进概览 entries。
    expect(
      RegExp(
        r'_buildOverviewSection\(\s*[\s\S]*?List<RemoteVideoInfo>',
      ).hasMatch(videoSrc),
      isTrue,
      reason: 'BUG-995：_buildOverviewSection 必须接收 remoteVideos 计入总数/继续观看',
    );
    // 远端续播卡必须存在（2026-10-28 起继续观看全在首屏 FushiContinueSpotlight，
    // 远端条目经 _continueRemoteHero 进首屏、点卡走 _openRemote——只看远端视频时
    // 也有续播入口）。
    final int remoteHero = videoSrc.indexOf(
      '_HomeHeroData _continueRemoteHero(',
    );
    expect(remoteHero, greaterThan(0), reason: 'BUG-995：只看远端视频时首屏继续观看必须有远端续播卡');
    expect(
      videoSrc
          .substring(remoteHero, videoSrc.indexOf('\n  }\n', remoteHero))
          .contains('_openRemote('),
      isTrue,
      reason: 'BUG-995：远端续播卡点按走 _openRemote（流播）',
    );
  });
  test('书架与首页藏着时不重建（BUG-4848）：带 SectionDeferredBuild，State 不直接依赖可见性', () {
    final String shelfSrc = File(
      'lib/src/pages/implementations/reader_fushi_history_page.dart',
    ).readAsStringSync();
    final String dashSrc = File(
      'lib/src/pages/implementations/home_dashboard_page.dart',
    ).readAsStringSync();
    final String shelfParts = Directory(
      'lib/src/pages/implementations/reader_history',
    ).listSync().whereType<File>().map((File f) => f.readAsStringSync()).join();

    expect(
      RegExp(
        r'class ReaderFushiHistoryPage extends HistoryReaderPage\s+'
        r'with SectionDeferredBuild \{',
      ).hasMatch(shelfSrc),
      isTrue,
      reason:
          '书架（书 / 漫画两个实例）藏着时不得跟着共享 provider 重建：首页切回时'
          '失效书列表，两个藏着的书架各整页重建四次，回首页卡 100 ms',
    );
    expect(
      dashSrc.contains(
        'class HomeDashboardPage extends BaseModuleTabPage '
        'with SectionDeferredBuild {',
      ),
      isTrue,
      reason: '首页藏着时同理：书架切回时失效同一对 provider',
    );
    // SectionDeferredBuild 的前提：可见性翻转不触发这两页的 State 重建，它们的
    // build 产物就不能直接读可见性（要读就放进子 widget）。
    for (final MapEntry<String, String> src in <String, String>{
      '书架': shelfSrc + shelfParts,
      '首页': dashSrc,
    }.entries) {
      expect(
        src.value.contains('SectionVisibility.of(context)'),
        isFalse,
        reason:
            '${src.key}的 State 不得直接依赖 SectionVisibility：混了 '
            'SectionDeferredBuild 之后可见性翻转不会让它重建，读到的是旧值',
      );
    }
    // 只看代码行：注释里会提到被替掉的旧写法。
    final String dashCode = maskComments(dashSrc);
    expect(
      dashCode.contains('TickerMode.valuesOf(context)') ||
          dashCode.contains('TickerMode.of(context)'),
      isFalse,
      reason:
          '首页用 TickerMode.getValuesNotifier 订阅开关：直接依赖 TickerMode 会让'
          '它每次切走 / 切回都被记一笔构建欠账，切回那一帧白白整页重建',
    );
  });
}
