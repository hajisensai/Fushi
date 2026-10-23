import 'package:flutter_test/flutter_test.dart';

import 'package:fushi/src/web_browser/data/memory_web_browser_store.dart';
import 'package:fushi/src/web_browser/data/web_browser_store.dart';
import 'package:fushi/src/web_browser/features/web_browser_feature.dart';
import 'package:fushi/src/web_browser/tabs/web_browser_tab.dart';
import 'package:fushi/src/web_browser/tabs/web_browser_tabs_controller.dart';

class _RecordingFeature extends WebBrowserFeature {
  final List<String> events = <String>[];

  @override
  String get id => 'recording';

  @override
  void onTabActiveChanged(WebBrowserTab tab, {required bool active}) =>
      events.add('${active ? '+' : '-'}${tab.title}');

  @override
  void onTabClosed(WebBrowserTab tab) => events.add('x${tab.title}');
}

Uri _u(String s) => Uri.parse('https://$s/');

void main() {
  late MemoryWebBrowserStore store;
  late WebBrowserTabsController c;

  setUp(() {
    store = MemoryWebBrowserStore();
    c = WebBrowserTabsController(store: store, saveDebounce: Duration.zero);
  });

  tearDown(() => c.dispose());

  test('开标签页：默认激活、追加到末尾；后台打开不抢前台', () {
    final WebBrowserTab a = c.openTab(_u('a'), title: 'a');
    final WebBrowserTab b = c.openTab(_u('b'), title: 'b', activate: false);
    expect(c.tabs, <WebBrowserTab>[a, b]);
    expect(c.activeTab, a);
    expect(c.isLive(a), isTrue);
    expect(c.isLive(b), isTrue, reason: '后台打开的也立即建（新窗口交接）');
  });

  test('从 opener 打开的子页插在 opener 那串子页之后', () {
    final WebBrowserTab a = c.openTab(_u('a'));
    final WebBrowserTab z = c.openTab(_u('z'), activate: false);
    final WebBrowserTab c1 = c.openTab(_u('c1'), openerId: a.id);
    final WebBrowserTab c2 = c.openTab(_u('c2'), openerId: a.id);
    expect(c.tabs, <WebBrowserTab>[a, c1, c2, z]);
  });

  test('关前台标签页回到 opener；没有 opener 时去右邻，再去左邻', () {
    final WebBrowserTab a = c.openTab(_u('a'));
    final WebBrowserTab b = c.openTab(_u('b'));
    final WebBrowserTab child = c.openTab(_u('c'), openerId: a.id);
    expect(c.activeTab, child);
    c.closeTab(child);
    expect(c.activeTab, a, reason: '回到 opener');
    c.activate(a);
    c.closeTab(a);
    expect(c.activeTab, b, reason: '右邻');
    final WebBrowserTab d = c.openTab(_u('d'));
    c.closeTab(d);
    expect(c.activeTab, b, reason: '最后一个关掉去左邻');
  });

  test('最近关闭栈：非无痕进栈、无痕不进；重开放回原位', () async {
    final WebBrowserTab a = c.openTab(_u('a'), title: 'A');
    c.openTab(_u('b'));
    final WebBrowserTab secret = c.openTab(_u('s'), incognito: true);
    c.closeTab(secret);
    c.closeTab(a);
    await Future<void>.delayed(Duration.zero);
    final List<WebBrowserClosedTab> closed = await store.closedTabs();
    expect(closed.map((WebBrowserClosedTab t) => t.url), <Uri>[_u('a')]);

    final WebBrowserTab? reopened = await c.reopenClosedTab();
    expect(reopened?.url, _u('a'));
    expect(reopened?.title, 'A');
    expect(c.tabs.indexOf(reopened!), 0, reason: '放回原来的位置');
    expect(c.activeTab, reopened);
    expect(await c.reopenClosedTab(), isNull);
  });

  test('切换：上一个 / 下一个首尾循环；重排沿 ReorderableList 口径', () {
    final WebBrowserTab a = c.openTab(_u('a'));
    final WebBrowserTab b = c.openTab(_u('b'));
    final WebBrowserTab d = c.openTab(_u('d'));
    c.activateRelative(1);
    expect(c.activeTab, a);
    c.activateRelative(-1);
    expect(c.activeTab, d);
    c.reorder(0, 3);
    expect(c.tabs, <WebBrowserTab>[b, d, a]);
    c.reorder(2, 0);
    expect(c.tabs, <WebBrowserTab>[a, b, d]);
  });

  test('关闭其它标签页', () {
    c.openTab(_u('a'));
    final WebBrowserTab b = c.openTab(_u('b'));
    c.openTab(_u('d'));
    c.closeOtherTabs(b);
    expect(c.tabs, <WebBrowserTab>[b]);
    expect(c.activeTab, b);
  });

  test('活 WebView 上限：超出时回收最久没看的，前台永远活着', () {
    final WebBrowserTabsController small = WebBrowserTabsController(
      store: store,
      maxLiveTabs: 2,
      saveDebounce: Duration.zero,
    );
    addTearDown(small.dispose);
    final WebBrowserTab a = small.openTab(_u('a'));
    final WebBrowserTab b = small.openTab(_u('b'));
    expect(small.isLive(a) && small.isLive(b), isTrue);
    final WebBrowserTab d = small.openTab(_u('d'));
    expect(small.isLive(a), isFalse, reason: 'a 最久没看，被回收');
    expect(small.isLive(b) && small.isLive(d), isTrue);
    expect(a.url, _u('a'), reason: '回收后只留地址');
    small.activate(a);
    expect(small.isLive(a), isTrue, reason: '切回来重建');
    expect(small.isLive(b), isFalse);
  });

  test('没有地址的新标签页不建 WebView', () {
    final WebBrowserTab blank = c.openTab(null);
    expect(c.isLive(blank), isFalse);
    blank.update(url: _u('x'));
    expect(c.isLive(blank), isTrue);
  });

  test('会话：只存非无痕且有地址的；恢复后只有前台页是活的', () async {
    final WebBrowserTab a = c.openTab(_u('a'), title: 'A');
    c.openTab(_u('b'), title: 'B');
    c.openTab(_u('s'), incognito: true);
    c.openTab(null);
    c.activate(a);
    await c.flushSession();
    final WebBrowserSession? saved = await store.loadSession();
    expect(saved!.tabs.map((WebBrowserSessionTab t) => t.title), <String>[
      'A',
      'B',
    ]);
    expect(saved.activeTabId, a.id);

    final WebBrowserTabsController next = WebBrowserTabsController(
      store: store,
      saveDebounce: Duration.zero,
    );
    addTearDown(next.dispose);
    expect(await next.restoreSession(), 2);
    expect(next.tabs.map((WebBrowserTab t) => t.url), <Uri>[_u('a'), _u('b')]);
    expect(next.activeTab!.id, a.id);
    expect(next.isLive(next.activeTab!), isTrue);
    expect(next.isLive(next.tabs[1]), isFalse, reason: '其它页懒加载');
  });

  test('恢复会话排在已有标签页之前、同地址不重复、已有前台不变', () async {
    await store.saveSession(
      WebBrowserSession(
        tabs: <WebBrowserSessionTab>[
          WebBrowserSessionTab(id: 'r1', url: _u('a'), title: 'A'),
          WebBrowserSessionTab(id: 'r2', url: _u('x'), title: 'X'),
        ],
        activeTabId: 'r1',
      ),
    );
    final WebBrowserTab opened = c.openTab(_u('x'));
    expect(await c.restoreSession(), 1, reason: 'x 已开着，不再恢复一份');
    expect(c.tabs.map((WebBrowserTab t) => t.url), <Uri>[_u('a'), _u('x')]);
    expect(c.activeTab, opened);
  });

  test('标签页地址变化触发防抖写盘', () async {
    final WebBrowserTab a = c.openTab(_u('a'));
    await Future<void>.delayed(const Duration(milliseconds: 5));
    a.update(url: _u('a2'), title: 'A2');
    await Future<void>.delayed(const Duration(milliseconds: 5));
    final WebBrowserSession? saved = await store.loadSession();
    expect(saved!.tabs.single.url, _u('a2'));
  });

  test('关闭会话持久化时不读不写', () async {
    c.persistSession = false;
    c.openTab(_u('a'));
    await c.flushSession();
    expect(await store.loadSession(), isNull);
    expect(await c.restoreSession(), 0);
  });

  test('功能插件收到前台切换与关闭回调', () {
    final _RecordingFeature f = _RecordingFeature();
    final WebBrowserTabsController withF = WebBrowserTabsController(
      store: store,
      features: <WebBrowserFeature>[f],
      saveDebounce: Duration.zero,
    );
    addTearDown(withF.dispose);
    final WebBrowserTab a = withF.openTab(_u('a'), title: 'a');
    withF.openTab(_u('b'), title: 'b');
    withF.closeTab(a);
    expect(f.events, <String>['+a', '-a', '+b', 'xa']);
  });

  test('关掉前台标签页：先报不再是前台、再报关闭，然后新前台', () {
    final _RecordingFeature f = _RecordingFeature();
    final WebBrowserTabsController withF = WebBrowserTabsController(
      store: store,
      features: <WebBrowserFeature>[f],
      saveDebounce: Duration.zero,
    );
    addTearDown(withF.dispose);
    withF.openTab(_u('a'), title: 'a');
    final WebBrowserTab b = withF.openTab(_u('b'), title: 'b');
    f.events.clear();
    withF.closeTab(b);
    expect(f.events, <String>['-b', 'xb', '+a']);
  });
}
