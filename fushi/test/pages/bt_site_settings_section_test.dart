/// 「BT 站」设置区：添加时自动识别、识别失败只给中性提示且不写入、编辑时只有
/// 改地址 / 明文 HTTP 才重新识别、删除要确认、启停写穿 store。全程假 store，
/// 不碰网络。
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/pages/implementations/bt_site_settings_section.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_engine/media/torrent/bt_site_config.dart';
import 'package:fushi_engine/media/torrent/bt_site_probe.dart';
import 'package:material_ui/material_ui.dart';

class _FakeStore implements BtSiteSettingsStore {
  _FakeStore([List<BtSiteConfig> initial = const <BtSiteConfig>[]])
    : sites = List<BtSiteConfig>.of(initial);

  List<BtSiteConfig> sites;
  final List<List<BtSiteConfig>> saves = <List<BtSiteConfig>>[];
  final List<(String, bool)> detectCalls = <(String, bool)>[];
  final List<String> searchCalls = <String>[];

  /// 下一次识别的结果；null = 用 [_success]。
  Future<BtSiteProbeResult> Function(String url)? onDetect;
  Future<int?> Function(BtSiteConfig site)? onSearch;

  static BtSiteProbeResult _success(String url) => BtSiteProbeResult(
    format: BtSiteFormat.nyaa,
    baseUrl: Uri.parse(url),
    nyaaCategories: const <BtSiteDomain, String>{BtSiteDomain.anime: '1_0'},
  );

  @override
  List<BtSiteConfig> load() => sites;

  @override
  Future<void> save(List<BtSiteConfig> next) async {
    sites = List<BtSiteConfig>.of(next);
    saves.add(sites);
  }

  @override
  Future<BtSiteProbeResult> detect(
    String url, {
    required bool allowInsecureHttp,
  }) {
    detectCalls.add((url, allowInsecureHttp));
    return onDetect?.call(url) ??
        Future<BtSiteProbeResult>.value(_success(url));
  }

  @override
  Future<int?> testSearch(BtSiteConfig site) {
    searchCalls.add(site.id);
    return onSearch?.call(site) ?? Future<int?>.value(7);
  }
}

BtSiteConfig _site({
  String id = 'site1',
  String name = '',
  String url = 'https://bt.example.com/rss/passkey-SECRET',
  Set<BtSiteDomain> domains = const <BtSiteDomain>{BtSiteDomain.anime},
  bool enabled = true,
}) => BtSiteConfig(
  id: id,
  name: name,
  baseUrl: Uri.parse(url),
  format: BtSiteFormat.nyaa,
  domains: domains,
  nyaaCategories: const <BtSiteDomain, String>{BtSiteDomain.anime: '1_0'},
  enabled: enabled,
);

Widget _harness(_FakeStore store) => ProviderScope(
  child: MaterialApp(
    theme: ThemeData(useMaterial3: true),
    home: Scaffold(
      body: SizedBox(
        width: 640,
        child: SingleChildScrollView(
          child: BtSiteSettingsSection(store: store),
        ),
      ),
    ),
  ),
);

Finder _field(String key) => find.descendant(
  of: find.byKey(ValueKey<String>(key)),
  matching: find.byType(EditableText),
);

Future<void> _pump(WidgetTester tester, _FakeStore store) async {
  tester.view.physicalSize = const Size(900, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(_harness(store));
  await tester.pumpAndSettle();
}

Future<void> _tapKey(WidgetTester tester, String key) async {
  final Finder finder = find.byKey(ValueKey<String>(key));
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => LocaleSettings.setLocale(AppLocale.en));

  testWidgets('没有站点时显示空态提示', (WidgetTester tester) async {
    await _pump(tester, _FakeStore());
    expect(find.byKey(const ValueKey<String>('bt-site-empty')), findsOneWidget);
    expect(find.text(t.bt_site_empty_hint), findsOneWidget);
  });

  testWidgets('添加：显示识别中，识别成功才写入；列表只显示主机名不显示地址', (WidgetTester tester) async {
    final _FakeStore store = _FakeStore();
    final Completer<BtSiteProbeResult> probe = Completer<BtSiteProbeResult>();
    store.onDetect = (String url) => probe.future;
    await _pump(tester, store);

    await _tapKey(tester, 'bt-site-add');
    expect(find.text(t.bt_site_url_hint), findsOneWidget, reason: '占位地址');
    await tester.enterText(
      _field('bt-site-dialog-url'),
      'https://bt.example.com/rss/passkey-SECRET',
    );
    await tester.pump();
    await _tapKey(tester, 'bt-site-dialog-domain-anime');
    await tester.tap(find.byKey(const ValueKey<String>('bt-site-dialog-save')));
    await tester.pump();

    expect(
      find.byKey(const ValueKey<String>('bt-site-dialog-detecting')),
      findsOneWidget,
    );
    expect(find.text(t.bt_site_detecting_status), findsOneWidget);
    expect(store.saves, isEmpty, reason: '识别完成前不写入');

    probe.complete(
      BtSiteProbeResult(
        format: BtSiteFormat.nyaa,
        baseUrl: Uri.parse('https://bt.example.com/rss/passkey-SECRET'),
        nyaaCategories: const <BtSiteDomain, String>{BtSiteDomain.anime: '1_0'},
      ),
    );
    await tester.pumpAndSettle();

    expect(store.detectCalls, <(String, bool)>[
      ('https://bt.example.com/rss/passkey-SECRET', false),
    ]);
    expect(store.saves, hasLength(1));
    final BtSiteConfig saved = store.saves.single.single;
    expect(saved.name, isEmpty);
    expect(saved.domains, <BtSiteDomain>{BtSiteDomain.anime});
    expect(saved.enabled, isTrue);
    expect(find.text('bt.example.com'), findsOneWidget, reason: '名称默认主机名');
    expect(
      find.textContaining('SECRET'),
      findsNothing,
      reason: '地址可能带 passkey',
    );
    expect(find.text(t.bt_site_domain_anime), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('bt-site-empty')), findsNothing);
  });

  for (final (BtSiteProbeError error, String Function() message)
      in <(BtSiteProbeError, String Function())>[
        (BtSiteProbeError.unrecognized, () => t.bt_site_detect_failed_error),
        (BtSiteProbeError.timedOut, () => t.bt_site_detect_timeout_error),
        (BtSiteProbeError.invalidUrl, () => t.bt_site_url_invalid_error),
        (BtSiteProbeError.insecureHttp, () => t.bt_site_url_insecure_error),
      ]) {
    testWidgets('添加：识别失败（${error.name}）只给中性提示且不写入', (
      WidgetTester tester,
    ) async {
      final _FakeStore store = _FakeStore()
        ..onDetect = (String url) =>
            Future<BtSiteProbeResult>.error(BtSiteProbeException(error));
      await _pump(tester, store);

      await _tapKey(tester, 'bt-site-add');
      await tester.enterText(_field('bt-site-dialog-url'), 'bt.example.com');
      await tester.pump();
      await _tapKey(tester, 'bt-site-dialog-domain-movie');
      await _tapKey(tester, 'bt-site-dialog-save');

      expect(
        find.byKey(const ValueKey<String>('bt-site-dialog-error')),
        findsOneWidget,
      );
      expect(find.text(message()), findsOneWidget);
      expect(store.saves, isEmpty);
      expect(
        find.byKey(const ValueKey<String>('bt-site-dialog-save')),
        findsOneWidget,
        reason: '对话框留着让用户改地址再试',
      );
    });
  }

  testWidgets('添加：没选媒体域不识别、不写入', (WidgetTester tester) async {
    final _FakeStore store = _FakeStore();
    await _pump(tester, store);
    await _tapKey(tester, 'bt-site-add');
    await tester.enterText(_field('bt-site-dialog-url'), 'bt.example.com');
    await tester.pump();
    await _tapKey(tester, 'bt-site-dialog-save');

    expect(find.text(t.bt_site_domains_required_error), findsOneWidget);
    expect(store.detectCalls, isEmpty);
    expect(store.saves, isEmpty);
  });

  testWidgets('添加：明文 http 地址才出现「允许明文 HTTP」开关，并随识别传下去', (
    WidgetTester tester,
  ) async {
    final _FakeStore store = _FakeStore();
    await _pump(tester, store);
    await _tapKey(tester, 'bt-site-add');
    expect(
      find.byKey(const ValueKey<String>('bt-site-dialog-allow-http')),
      findsNothing,
    );
    await tester.enterText(_field('bt-site-dialog-url'), 'http://192.168.1.5');
    await tester.pump();
    await _tapKey(tester, 'bt-site-dialog-allow-http');
    await _tapKey(tester, 'bt-site-dialog-domain-anime');
    await _tapKey(tester, 'bt-site-dialog-save');

    expect(store.detectCalls.single.$2, isTrue);
    expect(store.saves.single.single.allowInsecureHttp, isTrue);
  });

  testWidgets('编辑：只改名称不重新识别；改地址重新识别', (WidgetTester tester) async {
    final _FakeStore store = _FakeStore(<BtSiteConfig>[_site()]);
    await _pump(tester, store);

    await _tapKey(tester, 'bt-site-site1-edit');
    expect(find.text(t.bt_site_edit_title), findsOneWidget);
    await tester.enterText(_field('bt-site-dialog-name'), 'My site');
    await tester.pump();
    await _tapKey(tester, 'bt-site-dialog-save');

    expect(store.detectCalls, isEmpty, reason: '只改名称不必重新识别');
    expect(store.sites.single.name, 'My site');
    expect(
      store.sites.single.baseUrl.toString(),
      'https://bt.example.com/rss/passkey-SECRET',
    );
    expect(find.text('My site'), findsOneWidget);

    await _tapKey(tester, 'bt-site-site1-edit');
    await tester.enterText(
      _field('bt-site-dialog-url'),
      'https://other.example.org',
    );
    await tester.pump();
    await _tapKey(tester, 'bt-site-dialog-save');

    expect(store.detectCalls.single.$1, 'https://other.example.org');
    expect(store.sites.single.id, 'site1', reason: '身份不变（订阅按它持久化）');
    expect(store.sites.single.name, 'My site');
    expect(store.sites.single.baseUrl.host, 'other.example.org');
  });

  testWidgets('删除要确认：取消不删，确认才删', (WidgetTester tester) async {
    final _FakeStore store = _FakeStore(<BtSiteConfig>[_site()]);
    await _pump(tester, store);

    await _tapKey(tester, 'bt-site-site1-delete');
    expect(find.text(t.bt_site_delete_confirm_title), findsOneWidget);
    await tester.tap(find.text(t.dialog_cancel));
    await tester.pumpAndSettle();
    expect(store.saves, isEmpty);
    expect(find.text('bt.example.com'), findsOneWidget);

    await _tapKey(tester, 'bt-site-site1-delete');
    await tester.tap(find.text(t.dialog_delete).last);
    await tester.pumpAndSettle();
    expect(store.sites, isEmpty);
    expect(find.byKey(const ValueKey<String>('bt-site-empty')), findsOneWidget);
  });

  testWidgets('启停开关写穿 store，不重新识别', (WidgetTester tester) async {
    final _FakeStore store = _FakeStore(<BtSiteConfig>[_site()]);
    await _pump(tester, store);

    await _tapKey(tester, 'bt-site-site1-enabled');
    expect(store.sites.single.enabled, isFalse);
    expect(store.detectCalls, isEmpty);

    await _tapKey(tester, 'bt-site-site1-enabled');
    expect(store.sites.single.enabled, isTrue);
  });

  testWidgets('勾选的域在该站没有生效时显示提示', (WidgetTester tester) async {
    final _FakeStore store = _FakeStore(<BtSiteConfig>[
      _site(
        domains: const <BtSiteDomain>{BtSiteDomain.anime, BtSiteDomain.manga},
      ),
    ]);
    await _pump(tester, store);
    expect(
      find.byKey(const ValueKey<String>('bt-site-site1-unmatched')),
      findsOneWidget,
    );
    expect(find.text(t.bt_site_domains_unmatched_status), findsOneWidget);
  });

  testWidgets('重新检测与测试搜索：结论落在行内', (WidgetTester tester) async {
    final _FakeStore store = _FakeStore(<BtSiteConfig>[_site()]);
    await _pump(tester, store);

    await _tapKey(tester, 'bt-site-site1-test');
    expect(store.searchCalls, <String>['site1']);
    expect(find.text(t.bt_site_test_search_result(n: 7)), findsOneWidget);

    await _tapKey(tester, 'bt-site-site1-redetect');
    expect(store.detectCalls.single, (
      'https://bt.example.com/rss/passkey-SECRET',
      false,
    ));
    expect(find.text(t.bt_site_redetect_done_status), findsOneWidget);
    expect(store.sites.single.id, 'site1');

    store.onDetect = (String url) => Future<BtSiteProbeResult>.error(
      const BtSiteProbeException(BtSiteProbeError.unrecognized),
    );
    await _tapKey(tester, 'bt-site-site1-redetect');
    expect(find.text(t.bt_site_detect_failed_error), findsOneWidget);
    expect(store.saves, hasLength(1), reason: '识别失败不改配置');
  });
}
