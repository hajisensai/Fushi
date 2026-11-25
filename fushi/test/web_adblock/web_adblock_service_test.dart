// WebAdblockService 端到端（真原生库：Rust 胖核心持有订阅 / 缓存 / 开关 / 白名单；假下载器
// 给字节）。原生库是硬依赖：找不到库（FUSHI_WEB_CORE_LIB 或本仓 native/fushi_web_core 的编译产物，
// 由 test/flutter_test_config.dart 定位）测试直接失败，不 skip。
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/web_adblock/web_adblock_capability.dart';
import 'package:fushi/src/web_adblock/web_adblock_service.dart';
import 'package:fushi/src/web_adblock/web_adblock_wiring.dart';
import 'package:fushi/src/web_adblock/web_content_rule_list.dart';
import 'package:fushi_web_core/fushi_web_core.dart';

const String _list = '''
||ads.example.com^
example.com##.ad-banner
##.generic-ad
''';

/// 直接用 Rust 核心把订阅集设成只有 [id]（不触发同步），再交给服务。
void _selectOnly(Directory dir, String id) {
  final AdblockCore core = AdblockCore.open(dir.path);
  for (final AdblockCatalogEntry e in AdblockCore.catalog()) {
    core.setListEnabled(e.id, e.id == id);
  }
  core.close();
}

/// 把 Rust 落盘的 `state.json` 里各列表的取回时间改成 0（= 远超过期阈值），模拟隔了几天再启动。
void _makeListsStale(Directory dir) {
  final File state = File('${dir.path}${Platform.pathSeparator}state.json');
  final Map<String, Object?> json =
      jsonDecode(state.readAsStringSync()) as Map<String, Object?>;
  final Map<String, Object?> lists = json['lists']! as Map<String, Object?>;
  for (final Object? meta in lists.values) {
    (meta! as Map<String, Object?>)['fetchedAt'] = 0;
  }
  state.writeAsStringSync(jsonEncode(json));
}

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('fwc_svc_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  WebAdblockService service(
    List<Uri> fetched, {
    WebAdblockNetworkMode? mode,
    bool disposeOnTearDown = true,
    ContentRuleListInstaller? contentRuleLists,
  }) {
    final WebAdblockService s = WebAdblockService(
      dataDir: () => tmp,
      mode: mode ?? WebAdblockNetworkMode.perRequest,
      contentRuleLists: contentRuleLists ?? _RecordingRuleLists(),
      fetcher: (Uri url, {String? etag, String? lastModified}) async {
        fetched.add(url);
        return AdblockFetchResponse(
          statusCode: 200,
          body: Uint8List.fromList(utf8.encode(_list)),
        );
      },
    );
    if (disposeOnTearDown) addTearDown(s.dispose);
    return s;
  }

  test('settings commands go to Rust; snapshot is the only state', () async {
    final List<Uri> fetched = <Uri>[];
    final WebAdblockService s = service(fetched);
    int notified = 0;
    s.addListener(() => notified++);

    _selectOnly(tmp, 'easylist');
    expect(s.snapshot.status, AdblockEngineStatus.idle);
    await s.ensureLoaded();
    expect(s.snapshot.isListEnabled('easylist'), isTrue);
    expect(s.snapshot.isListEnabled('easyprivacy'), isFalse);
    expect(fetched, <Uri>[
      Uri.parse('https://easylist.to/easylist/easylist.txt'),
    ]);
    expect(s.snapshot.status, AdblockEngineStatus.ready);
    expect(s.isActive, isTrue);
    expect(s.snapshot.lastUpdatedAt, isNotNull);
    expect(notified, greaterThan(0));

    // 并发 ensureLoaded：缓存新鲜、引擎已是最新，不再联网。
    await Future.wait(<Future<void>>[s.ensureLoaded(), s.ensureLoaded()]);
    expect(fetched, hasLength(1));

    final WebAdblockWiring w = applyAdblockTo(
      InAppWebViewSettings(),
      policy: s,
      mode: WebAdblockNetworkMode.perRequest,
    )..onLoadStart(WebUri('https://news.test/'));
    WebResourceResponse? check() => w.interceptForAdblock(
      WebResourceRequest(
        url: WebUri('https://ads.example.com/a.js'),
        isForMainFrame: false,
      ),
    );
    expect(check(), isNotNull);

    s.setAllowlist('news.test');
    expect(s.snapshot.allowlistHosts, <String>['news.test']);
    expect(check(), isNull, reason: 'allowlist applies on the next request');
    s.setAllowlist('');
    await s.setEnabled(false);
    expect(s.snapshot.enabled, isFalse);
    expect(check(), isNull);
    await s.setEnabled(true);
    expect(check(), isNotNull);

    // 「立即更新」：强制联网核对。
    expect(await s.updateNow(), isTrue);
    expect(fetched, hasLength(2));
  });

  test(
    'state persists across service instances (Rust owns the disk)',
    () async {
      _selectOnly(tmp, 'easylist');
      final WebAdblockService first = service(
        <Uri>[],
        disposeOnTearDown: false,
      );
      await first.setListEnabled('adguard_japanese', true);
      await first.setListEnabled('easylist', false);
      first.setAllowlist('keep.test');
      first.dispose();

      final List<Uri> fetched = <Uri>[];
      final WebAdblockService second = service(fetched);
      expect(second.snapshot.allowlist, 'keep.test');
      expect(second.snapshot.isListEnabled('adguard_japanese'), isTrue);
      expect(second.snapshot.isListEnabled('easylist'), isFalse);
      await second.ensureLoaded();
      expect(fetched, isEmpty, reason: 'fresh cache from the first instance');
      expect(second.snapshot.status, AdblockEngineStatus.ready);
      expect(second.snapshot.fromCache, isTrue);
    },
  );

  test(
    'BUG-4737: cached engine blocks while stale lists are re-fetched',
    () async {
      _selectOnly(tmp, 'easylist');
      final WebAdblockService first = service(
        <Uri>[],
        disposeOnTearDown: false,
      );
      await first.ensureLoaded();
      first.dispose();
      _makeListsStale(tmp);

      // 下一次启动：列表过期要重新联网，下载卡住期间引擎也必须已就绪（用磁盘缓存）。
      final Completer<void> fetchStarted = Completer<void>();
      final Completer<void> releaseFetch = Completer<void>();
      final WebAdblockService second = WebAdblockService(
        dataDir: () => tmp,
        mode: WebAdblockNetworkMode.perRequest,
        contentRuleLists: _RecordingRuleLists(),
        fetcher: (Uri url, {String? etag, String? lastModified}) async {
          if (!fetchStarted.isCompleted) fetchStarted.complete();
          await releaseFetch.future;
          return AdblockFetchResponse(
            statusCode: 200,
            body: Uint8List.fromList(utf8.encode(_list)),
          );
        },
      );
      addTearDown(second.dispose);

      final Future<void> loading = second.ensureLoaded();
      await fetchStarted.future;
      final Uri page = Uri.parse('https://example.com/');
      expect(
        second.check('https://ads.example.com/a.js', pageUrl: page).shouldBlock,
        isTrue,
        reason: 'network refresh must not leave the page without an engine',
      );
      // 注意：此刻 snapshot.status 是 loading（isActive 是给设置页 / contentBlockers 用的状态
      // 位），但热路径只看内存里有没有引擎。
      expect(
        second.cosmeticPayload('https://example.com/', pageUrl: page),
        contains('.ad-banner'),
      );

      releaseFetch.complete();
      await loading;
      expect(second.snapshot.status, AdblockEngineStatus.ready);
    },
  );

  for (final String entry in <String>['updateNow', 'setListEnabled']) {
    test('BUG-4737: $entry from a cold service does not queue warm-up behind '
        'its network sync', () async {
      _selectOnly(tmp, 'easylist');
      final WebAdblockService first = service(
        <Uri>[],
        disposeOnTearDown: false,
      );
      await first.ensureLoaded();
      first.dispose();
      _makeListsStale(tmp);

      final Completer<void> fetchStarted = Completer<void>();
      final Completer<void> releaseFetch = Completer<void>();
      final WebAdblockService second = WebAdblockService(
        dataDir: () => tmp,
        mode: WebAdblockNetworkMode.perRequest,
        contentRuleLists: _RecordingRuleLists(),
        fetcher: (Uri url, {String? etag, String? lastModified}) async {
          if (!fetchStarted.isCompleted) fetchStarted.complete();
          await releaseFetch.future;
          return AdblockFetchResponse(
            statusCode: 200,
            body: Uint8List.fromList(utf8.encode(_list)),
          );
        },
      );
      addTearDown(second.dispose);

      // 设置页先点「立即更新」/ 切列表（服务还没暖过），再打开浏览器标签页。
      final Future<void> syncing = entry == 'updateNow'
          ? second.updateNow()
          : second.setListEnabled('easylist', true);
      await fetchStarted.future;
      bool warm = false;
      unawaited(second.ensureEngineWarm().then((_) => warm = true));
      await pumpEventQueue();
      expect(
        warm,
        isTrue,
        reason: 'tab warm-up must not wait for the network sync',
      );
      expect(
        second
            .check(
              'https://ads.example.com/a.js',
              pageUrl: Uri.parse('https://example.com/'),
            )
            .shouldBlock,
        isTrue,
      );

      releaseFetch.complete();
      await syncing;
    });
  }

  test('BUG-4737: content-blocker warm-up installs the cached rule list '
      'without network', () async {
    final _RecordingRuleLists native = _RecordingRuleLists();
    _selectOnly(tmp, 'easylist');
    final WebAdblockService first = service(
      <Uri>[],
      mode: WebAdblockNetworkMode.contentBlockers,
      contentRuleLists: native,
      disposeOnTearDown: false,
    );
    await first.ensureLoaded();
    first.dispose();
    _makeListsStale(tmp);

    final List<Uri> fetched = <Uri>[];
    final WebAdblockService second = service(
      fetched,
      mode: WebAdblockNetworkMode.contentBlockers,
      contentRuleLists: native,
    );
    await second.ensureEngineWarm();
    expect(fetched, isEmpty);
    // 标签页据此判断不必等联网就能建 WebView。
    expect(second.contentRuleListIdentifier, isNotNull);
  });

  test(
    'ensureEngineWarm completes without network when nothing is cached',
    () async {
      _selectOnly(tmp, 'easylist');
      final List<Uri> fetched = <Uri>[];
      final WebAdblockService s = service(fetched);
      await s.ensureEngineWarm();
      expect(fetched, isEmpty);
      expect(s.isActive, isFalse);
      await s.ensureLoaded();
      expect(s.isActive, isTrue);
    },
  );

  test(
    'content-blocker platforms: one rule set goes to native exactly once',
    () async {
      final _RecordingRuleLists native = _RecordingRuleLists();
      final WebAdblockService s = service(
        <Uri>[],
        mode: WebAdblockNetworkMode.contentBlockers,
        contentRuleLists: native,
      );
      _selectOnly(tmp, 'easylist');
      await s.ensureLoaded();

      final String? id = s.contentRuleListIdentifier;
      expect(id, isNotNull);
      expect(id, startsWith(kContentRuleListIdentifierPrefix));
      expect(native.activated, <String>[id!]);
      expect(native.compiled.keys, <String>[id], reason: '未命中才编译一次');
      // 原生拿到的是 Rust 导出的 WebKit 规则 JSON 原文，identifier 就是它的内容哈希。
      final Uint8List json = native.compiled[id]!;
      expect(contentRuleListIdentifierOf(json), id);
      final List<Object?> rules =
          jsonDecode(utf8.decode(json)) as List<Object?>;
      expect(rules, isNotEmpty);
      for (final Object? r in rules) {
        final Object? type =
            ((r! as Map<String, Object?>)['action']!
                as Map<String, Object?>)['type'];
        expect(type, anyOf('block', 'ignore-previous-rules'));
      }

      // 再同步（含强制联网，列表内容没变）：同一规则集不再下发。
      await s.ensureLoaded();
      expect(await s.updateNow(), isTrue);
      expect(native.activated, <String>[id]);
      expect(native.compiled, hasLength(1));

      // WebView 只带引用。
      final WebAdblockWiring w = applyAdblockTo(
        InAppWebViewSettings(),
        policy: s,
        mode: WebAdblockNetworkMode.contentBlockers,
      );
      expect(
        contentRuleListReferencedIdentifier(w.settings.contentBlockers),
        id,
      );
    },
  );

  test(
    'next launch reuses the persisted rule list without recompiling',
    () async {
      _selectOnly(tmp, 'easylist');
      final _RecordingRuleLists firstNative = _RecordingRuleLists();
      final WebAdblockService first = service(
        <Uri>[],
        mode: WebAdblockNetworkMode.contentBlockers,
        contentRuleLists: firstNative,
        disposeOnTearDown: false,
      );
      await first.ensureLoaded();
      final String id = first.contentRuleListIdentifier!;
      first.dispose();

      // 原生 store 已有这份（WKContentRuleListStore 跨启动持久化）。
      final _RecordingRuleLists secondNative = _RecordingRuleLists(
        stored: <String>{id},
      );
      final WebAdblockService second = service(
        <Uri>[],
        mode: WebAdblockNetworkMode.contentBlockers,
        contentRuleLists: secondNative,
      );
      await second.ensureLoaded();
      expect(second.contentRuleListIdentifier, id, reason: '内容寻址：同内容同 id');
      expect(secondNative.activated, <String>[id]);
      expect(secondNative.compiled, isEmpty);
    },
  );

  test('per-request platforms never touch the native rule list', () async {
    final _RecordingRuleLists native = _RecordingRuleLists();
    final WebAdblockService s = service(<Uri>[], contentRuleLists: native);
    _selectOnly(tmp, 'easylist');
    await s.ensureLoaded();
    expect(s.contentRuleListIdentifier, isNull);
    expect(native.activated, isEmpty);
    expect(native.compiled, isEmpty);
  });

  test('empty WebKit rule table yields no identifier', () {
    expect(contentRuleListIdentifierOf(utf8.encode(' [ ]\n')), isNull);
    expect(
      contentRuleListIdentifierOf(utf8.encode('[{}]')),
      startsWith(kContentRuleListIdentifierPrefix),
    );
    expect(
      contentRuleListIdentifierOf(utf8.encode('[{}]')),
      contentRuleListIdentifierOf(utf8.encode('[{}]')),
    );
  });
}

/// 记录原生规则表调用的假实现；[stored] 是原生 store 里已有的 identifier。
class _RecordingRuleLists implements ContentRuleListInstaller {
  _RecordingRuleLists({Set<String>? stored}) : stored = stored ?? <String>{};

  final Set<String> stored;
  final List<String> activated = <String>[];
  final Map<String, Uint8List> compiled = <String, Uint8List>{};

  @override
  Future<bool> activate(String identifier) async {
    activated.add(identifier);
    return stored.contains(identifier);
  }

  @override
  Future<void> compile(String identifier, Uint8List json) async {
    compiled[identifier] = json;
    stored.add(identifier);
  }
}
