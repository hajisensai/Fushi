import 'package:flutter/foundation.dart' show ValueNotifier;
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/web_browser/features/page_visibility/web_browser_page_visibility_feature.dart';
import 'package:fushi/src/web_browser/features/play_in_fushi/play_in_fushi_feature.dart';
import 'package:fushi/src/web_browser/tabs/web_browser_tab.dart';

class _FakeController extends Fake implements InAppWebViewController {
  _FakeController(this.name);
  final String name;
}

/// 记下每个控制器收到的步骤：`hold`（按住并记下在播的，[kWebBrowserCoverHoldMediaScript]）/
/// `rehold`（只按住不记，[kWebBrowserHoldMediaScript]）/ `release`（解除并续播记下的，
/// [kWebBrowserCoverReleaseMediaScript]）/ `hide` / `show`。
class _Recorder {
  final List<String> log = <String>[];

  /// 设了就让对应步骤抛一次（模拟页面正在导航）。
  String? failOnce;

  void _record(String entry) {
    log.add(entry);
    if (failOnce == entry) {
      failOnce = null;
      throw StateError('step failed: $entry');
    }
  }

  Future<void> setHidden(
    InAppWebViewController c, {
    required bool hidden,
  }) async {
    _record('${(c as _FakeController).name}:${hidden ? 'hide' : 'show'}');
  }

  Future<void> runScript(InAppWebViewController c, String source) async {
    final String step = source == kWebBrowserCoverHoldMediaScript
        ? 'hold'
        : source == kWebBrowserHoldMediaScript
        ? 'rehold'
        : source == kWebBrowserCoverReleaseMediaScript
        ? 'release'
        : 'other';
    _record('${(c as _FakeController).name}:$step');
  }
}

void main() {
  late _Recorder rec;
  late ValueNotifier<String?> remote;
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
    remote = ValueNotifier<String?>(null);
    feature = WebBrowserPageVisibilityFeature(
      remoteControlledTabId: remote,
      setHidden: rec.setHidden,
      runScript: rec.runScript,
    );
  });

  tearDown(() {
    feature.dispose();
    remote.dispose();
  });

  Future<void> settle() => pumpEventQueue();

  Future<void> load(WebBrowserTab tab, _FakeController c) async {
    feature.onWebViewCreated(tab, c);
    await feature.onLoadStop(tab, c, tab.url);
    await settle();
  }

  test('页面加载完、没被盖住：什么都不做', () async {
    await load(a, ca);
    expect(rec.log, isEmpty);
  });

  test('被播放页盖住：先按住媒体再隐藏；露出时先恢复再解除', () async {
    await load(a, ca);

    feature.onPlaybackCoverChanged(covered: true);
    await settle();
    expect(rec.log, <String>['a:hold', 'a:hide']);

    rec.log.clear();
    feature.onPlaybackCoverChanged(covered: false);
    await settle();
    expect(rec.log, <String>['a:show', 'a:release']);
  });

  test('只是切走的后台标签页不暂停、不挂起（与 Chrome 一致）', () async {
    await load(a, ca);
    await load(b, cb);
    feature.onTabActiveChanged(a, active: false);
    feature.onTabActiveChanged(b, active: true);
    await settle();
    expect(rec.log, isEmpty);
    expect(feature.shouldHide('a'), isFalse);
  });

  test('别的整页路由盖住（onPageCoveredChanged）不触发', () async {
    await load(a, ca);
    feature.onPageCoveredChanged(covered: true);
    await settle();
    expect(rec.log, isEmpty);
  });

  test('正被手机遥控的标签页被播放页盖住也不暂停', () async {
    await load(a, ca);
    await load(b, cb);
    remote.value = 'a';

    feature.onPlaybackCoverChanged(covered: true);
    await settle();
    expect(rec.log, <String>['b:hold', 'b:hide']);

    // 盖住期间遥控会话结束（换视频 / 没视频了）：那一页随即隐藏。
    rec.log.clear();
    remote.value = null;
    await settle();
    expect(rec.log, <String>['a:hold', 'a:hide']);
  });

  test('已隐藏的页开始被手机遥控：恢复它', () async {
    await load(a, ca);
    feature.onPlaybackCoverChanged(covered: true);
    await settle();
    rec.log.clear();

    remote.value = 'a';
    await settle();
    expect(rec.log, <String>['a:show', 'a:release']);
  });

  test('盖住期间整页换了文档：新文档重新按住，但不记续播（此刻在播的是盖住后才开播的）', () async {
    await load(a, ca);
    feature.onPlaybackCoverChanged(covered: true);
    await settle();
    rec.log.clear();

    await feature.onLoadStop(
      a,
      ca,
      Uri.parse('https://www.netflix.com/title/1'),
    );
    await settle();
    expect(rec.log, <String>['a:rehold', 'a:hide']);

    // 重新按住失败：重做时照样不记续播。
    rec.log.clear();
    rec.failOnce = 'a:rehold';
    await feature.onLoadStop(
      a,
      ca,
      Uri.parse('https://www.netflix.com/title/2'),
    );
    await settle();
    await feature.onLoadStop(
      a,
      ca,
      Uri.parse('https://www.netflix.com/title/2'),
    );
    await settle();
    expect(rec.log, <String>['a:rehold', 'a:hide', 'a:rehold', 'a:hide']);

    // 露出：照常解除（续播脚本只续按住前记下的，新文档里没有记录）。
    rec.log.clear();
    feature.onPlaybackCoverChanged(covered: false);
    await settle();
    expect(rec.log, <String>['a:show', 'a:release']);
  });

  test('续播脚本与交接按住分开：盖住按住会记录、露出会续播；交接的解除脚本不续播', () {
    // 盖住：先记录此刻在播的，再走与交接共用的按住。
    expect(
      kWebBrowserCoverHoldMediaScript,
      startsWith('(function(){var r=window.__fushiCoverResume'),
    );
    expect(
      kWebBrowserCoverHoldMediaScript,
      endsWith(kWebBrowserHoldMediaScript),
    );
    // 露出：先解除按住监听，再续播记下的。
    expect(
      kWebBrowserCoverReleaseMediaScript,
      startsWith(kWebBrowserReleaseMediaScript),
    );
    expect(kWebBrowserCoverReleaseMediaScript, contains('.play()'));
    // 交接（PlayInFushiFeature）那对脚本不碰续播记录。
    expect(kWebBrowserHoldMediaScript, isNot(contains('__fushiCoverResume')));
    expect(
      kWebBrowserReleaseMediaScript,
      isNot(contains('__fushiCoverResume')),
    );
    expect(kWebBrowserReleaseMediaScript, isNot(contains('.play()')));
  });

  test('WebView 建好但还没加载完：盖住时不去挂起它', () async {
    feature.onWebViewCreated(a, ca);
    feature.onPlaybackCoverChanged(covered: true);
    await settle();
    expect(rec.log, isEmpty);

    // 加载完才落地。盖住后才加载完的文档里在播的都是盖住期间开播的：只按住、不记续播。
    await feature.onLoadStop(a, ca, a.url);
    await settle();
    expect(rec.log, <String>['a:rehold', 'a:hide']);
  });

  test('快速盖住 / 露出：按顺序落地，最后停在看得见', () async {
    await load(a, ca);
    feature.onPlaybackCoverChanged(covered: true);
    feature.onPlaybackCoverChanged(covered: false);
    await settle();
    // 第一步落地时目标已经回到看得见：什么都不用做。
    expect(rec.log, isEmpty);
  });

  test('隐藏有一步失败：状态记为说不准，露出时照样恢复', () async {
    await load(a, ca);
    rec.failOnce = 'a:hide';
    feature.onPlaybackCoverChanged(covered: true);
    await settle();
    // 失败不挡后一步之前的已完成步骤。
    expect(rec.log, <String>['a:hold', 'a:hide']);

    rec.log.clear();
    feature.onPlaybackCoverChanged(covered: false);
    await settle();
    // 没把失败的隐藏记成「已隐藏」也没记成「看得见」：露出必须真的恢复并解除按住。
    expect(rec.log, <String>['a:show', 'a:release']);
  });

  test('隐藏失败后再次同步会重试（不当成已隐藏）', () async {
    await load(a, ca);
    rec.failOnce = 'a:hold';
    feature.onPlaybackCoverChanged(covered: true);
    await settle();
    rec.log.clear();

    // 下一次同步（例如页面加载完）重做整套隐藏（新文档：只按住、不记续播）。
    await feature.onLoadStop(a, ca, a.url);
    await settle();
    expect(rec.log, <String>['a:rehold', 'a:hide']);
  });

  test('WebView 被回收（标签页还在）：撒手死控制器，之后盖住 / 露出不再碰它', () async {
    await load(a, ca);
    expect(feature.tracks('a'), isTrue);

    feature.onWebViewDisposed(a);
    expect(feature.tracks('a'), isFalse);

    feature.onPlaybackCoverChanged(covered: true);
    feature.onPlaybackCoverChanged(covered: false);
    await settle();
    expect(rec.log, isEmpty);

    // 重建后的新 WebView 加载完照常管（盖住期间才加载完：只按住、不记续播）。
    final _FakeController ca2 = _FakeController('a2');
    feature.onPlaybackCoverChanged(covered: true);
    await load(a, ca2);
    expect(rec.log, <String>['a2:rehold', 'a2:hide']);
  });

  test('关闭标签页：撒手', () async {
    await load(a, ca);
    feature.onTabClosed(a);
    feature.onPlaybackCoverChanged(covered: true);
    await settle();
    expect(rec.log, isEmpty);
    expect(feature.tracks('a'), isFalse);
  });
}
