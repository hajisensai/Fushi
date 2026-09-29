import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/novel/online/lnreader_models.dart';
import 'package:fushi/src/media/novel/online/lnreader_runtime.dart';

/// 审查 B2：WebView 闲置销毁 / renderer 死亡后，新一代宿主里一个插件都没有；
/// 浏览页翻页 / 搜索、详情页、下载都直接调插件方法、不经 `ensureLoaded`。账本
/// 必须记住源码并在下一次调用时自动重装，否则这些页面不退出就一直
/// `Plugin not loaded`。真 WebView 在测试宿主跑不起来，所以账本抽成纯 Dart 类
/// 单独钉，运行时里「每个插件方法都经 `_invokePlugin`」由源码守卫钉。
void main() {
  LnReaderPluginInfo info(String id) =>
      LnReaderPluginInfo.fromJson(<Object?, Object?>{'id': id, 'name': id});

  test('宿主换代后，不经 ensureLoaded 的插件调用也会用记住的源码重装', () async {
    final LnReaderPluginLedger ledger = LnReaderPluginLedger();
    int sourceReads = 0;
    final List<String> loadedCode = <String>[];
    Future<LnReaderPluginSource> source() async {
      sourceReads++;
      return (code: 'code-$sourceReads', storage: <String, Object?>{});
    }

    Future<LnReaderPluginInfo> load(LnReaderPluginSource s) async {
      loadedCode.add(s.code);
      return info('p');
    }

    // 首次：页面经 ensureLoaded 给源码。
    await ledger.ensure('p', source: source, load: load);
    // 同一代再调：不重复装。
    await ledger.ensure('p', load: load);
    expect(loadedCode, <String>['code-1']);

    // 闲置销毁 / renderer 死亡。
    ledger.hostGone();
    expect(ledger.infoOf('p'), isNull);

    // 翻页 / 搜索：没有再给源码，也必须重装。
    final LnReaderPluginInfo? again = await ledger.ensure('p', load: load);
    expect(again, isNotNull);
    expect(loadedCode, <String>['code-1', 'code-2']);
  });

  test('装载途中宿主被拆：旧一代的结果不记成新一代已装载', () async {
    final LnReaderPluginLedger ledger = LnReaderPluginLedger();
    final Completer<LnReaderPluginInfo> slow = Completer<LnReaderPluginInfo>();
    int loads = 0;
    Future<LnReaderPluginInfo> load(LnReaderPluginSource _) {
      loads++;
      return loads == 1
          ? slow.future
          : Future<LnReaderPluginInfo>.value(info('p'));
    }

    Future<LnReaderPluginSource> source() async =>
        (code: 'c', storage: <String, Object?>{});

    final Future<LnReaderPluginInfo?> first = ledger.ensure(
      'p',
      source: source,
      load: load,
    );
    await Future<void>.delayed(Duration.zero);
    ledger.hostGone();
    slow.complete(info('p'));
    await first;
    expect(ledger.infoOf('p'), isNull, reason: '装进的是已被拆掉的那一代宿主');

    await ledger.ensure('p', load: load);
    expect(loads, 2, reason: '新一代必须真正重装');
  });

  test('forget 连源码一起忘掉：卸载后的插件不会被自动重装', () async {
    final LnReaderPluginLedger ledger = LnReaderPluginLedger();
    int loads = 0;
    Future<LnReaderPluginInfo> load(LnReaderPluginSource _) async {
      loads++;
      return info('p');
    }

    await ledger.ensure(
      'p',
      source: () async => (code: 'c', storage: <String, Object?>{}),
      load: load,
    );
    ledger.forget('p');
    ledger.hostGone();
    expect(await ledger.ensure('p', load: load), isNull);
    expect(loads, 1);
  });

  group('源码守卫：WebView 运行时的接线', () {
    late String src;
    setUpAll(() {
      src = File(
        'lib/src/media/novel/online/lnreader_runtime.dart',
      ).readAsStringSync().replaceAll('\r\n', '\n');
    });

    test('带 pluginId 的宿主方法都经 _invokePlugin（重建后自动重装）', () {
      for (final String method in <String>[
        'popular',
        'search',
        'novel',
        'page',
        'chapter',
        'resolveUrl',
      ]) {
        expect(
          src.contains("_invoke('$method'"),
          isFalse,
          reason: '$method 直接 _invoke 会绕过账本，WebView 重建后 Plugin not loaded',
        );
        expect(src, contains("_invokePlugin('$method'"));
      }
    });

    // 审查 B1：插件是任意第三方 JS，页面不封网络它就能绕过宿主桥（代理 + 本机
    // 地址拦截）直接用 WebView 原生 fetch / XHR / WebSocket 打本机服务。
    test('宿主页带 CSP：除脚本外一律 none', () {
      expect(lnReaderHostCsp, startsWith("default-src 'none';"));
      expect(lnReaderHostCsp, isNot(contains('connect-src')));
      expect(
        src,
        contains(
          r'<meta http-equiv="Content-Security-Policy" content="$lnReaderHostCsp">',
        ),
      );
    });
  });
}
