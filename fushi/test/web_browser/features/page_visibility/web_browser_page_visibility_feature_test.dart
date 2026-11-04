import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/web_browser/features/page_visibility/web_browser_page_visibility_feature.dart';
import 'package:fushi/src/web_browser/features/play_in_fushi/play_in_fushi_feature.dart';
import 'package:fushi/src/web_browser/tabs/web_browser_tab.dart';

class _FakeController extends Fake implements InAppWebViewController {
  _FakeController(this.name);
  final String name;
}

/// 记下每个控制器收到的步骤：`hold` / `release` / `hide` / `show`。
class _Recorder {
  final List<String> log = <String>[];

  Future<void> setHidden(
    InAppWebViewController c, {
    required bool hidden,
  }) async {
    log.add('${(c as _FakeController).name}:${hidden ? 'hide' : 'show'}');
  }

  Future<void> runScript(InAppWebViewController c, String source) async {
    final String step = source == kWebBrowserHoldMediaScript
        ? 'hold'
        : source == kWebBrowserReleaseMediaScript
        ? 'release'
        : 'other';
    log.add('${(c as _FakeController).name}:$step');
  }
}

void main() {
  late _Recorder rec;
  late WebBrowserPageVisibilityFeature feature;
  final WebBrowserTab a = WebBrowserTab(
    id: 'a',
    url: Uri.parse('https://www.netflix.com/browse'),
  );
  final WebBrowserTab b = WebBrowserTab(
    id: 'b',
    url: Uri.parse('https://example.com/'),
  );
  final _FakeController ca = _FakeController('a');
  final _FakeController cb = _FakeController('b');

  setUp(() {
    rec = _Recorder();
    feature = WebBrowserPageVisibilityFeature(
      setHidden: rec.setHidden,
      runScript: rec.runScript,
    );
  });

  Future<void> settle() => pumpEventQueue();

  test('前台标签页建好时什么都不做（页面本来就看得见）', () async {
    feature.onTabActiveChanged(a, active: true);
    feature.onWebViewCreated(a, ca);
    await settle();
    expect(rec.log, isEmpty);
  });

  test('浏览页被整页路由盖住：先按住媒体再隐藏；露出时先恢复再解除', () async {
    feature.onTabActiveChanged(a, active: true);
    feature.onWebViewCreated(a, ca);
    await settle();

    feature.onPageCoveredChanged(covered: true);
    await settle();
    expect(rec.log, <String>['a:hold', 'a:hide']);

    rec.log.clear();
    feature.onPageCoveredChanged(covered: false);
    await settle();
    expect(rec.log, <String>['a:show', 'a:release']);
  });

  test('盖住时后台标签页也保持隐藏，露出后只有前台页恢复', () async {
    feature.onTabActiveChanged(a, active: true);
    feature.onWebViewCreated(a, ca);
    // b 是会话恢复出来的后台标签页：一建好就隐藏。
    feature.onWebViewCreated(b, cb);
    await settle();
    expect(rec.log, <String>['b:hold', 'b:hide']);

    rec.log.clear();
    feature.onPageCoveredChanged(covered: true);
    await settle();
    expect(rec.log, <String>['a:hold', 'a:hide']);

    rec.log.clear();
    feature.onPageCoveredChanged(covered: false);
    await settle();
    expect(rec.log, <String>['a:show', 'a:release']);
  });

  test('切换前台标签页：旧前台页隐藏，新前台页恢复', () async {
    feature.onTabActiveChanged(a, active: true);
    feature.onWebViewCreated(a, ca);
    feature.onWebViewCreated(b, cb);
    await settle();
    rec.log.clear();

    feature.onTabActiveChanged(a, active: false);
    feature.onTabActiveChanged(b, active: true);
    await settle();
    expect(rec.log, containsAllInOrder(<String>['a:hold', 'a:hide']));
    expect(rec.log, containsAllInOrder(<String>['b:show', 'b:release']));
    expect(rec.log, hasLength(4));
    expect(feature.shouldHide('a'), isTrue);
    expect(feature.shouldHide('b'), isFalse);
  });

  test('看不见期间整页换了文档：新文档重新按住；看得见时加载完不动', () async {
    feature.onTabActiveChanged(a, active: true);
    feature.onWebViewCreated(a, ca);
    feature.onPageCoveredChanged(covered: true);
    await settle();
    rec.log.clear();

    await feature.onLoadStop(a, ca, a.url);
    await settle();
    expect(rec.log, <String>['a:hold', 'a:hide']);

    feature.onPageCoveredChanged(covered: false);
    await settle();
    rec.log.clear();
    await feature.onLoadStop(a, ca, a.url);
    await settle();
    expect(rec.log, isEmpty);
  });

  test('盖住又马上露出：按顺序落地，最终看得见', () async {
    feature.onTabActiveChanged(a, active: true);
    feature.onWebViewCreated(a, ca);
    feature.onPageCoveredChanged(covered: true);
    feature.onPageCoveredChanged(covered: false);
    await settle();
    // 两次变化都在第一步落地前到达：落地时目标已经是「看得见」，什么都不用做。
    expect(rec.log, isEmpty);
    expect(feature.shouldHide('a'), isFalse);
  });

  test('单步失败不挡后续步骤', () async {
    final List<String> log = <String>[];
    final WebBrowserPageVisibilityFeature f = WebBrowserPageVisibilityFeature(
      runScript: (InAppWebViewController c, String s) async =>
          throw StateError('navigating'),
      setHidden: (InAppWebViewController c, {required bool hidden}) async =>
          log.add(hidden ? 'hide' : 'show'),
    );
    f.onTabActiveChanged(a, active: true);
    f.onWebViewCreated(a, ca);
    f.onPageCoveredChanged(covered: true);
    await settle();
    expect(log, <String>['hide']);
  });

  test('关掉的标签页不再收到任何步骤', () async {
    feature.onTabActiveChanged(a, active: true);
    feature.onWebViewCreated(a, ca);
    feature.onTabClosed(a);
    feature.onPageCoveredChanged(covered: true);
    await settle();
    expect(rec.log, isEmpty);
  });
}
