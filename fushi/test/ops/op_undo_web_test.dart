import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_cli/fushi_cli.dart';

import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/module_id.dart';
import 'package:fushi/src/ops/ctl_web_routes.dart';
import 'package:fushi/src/ops/op_context.dart';
import 'package:fushi/src/ops/op_describe_kit.dart';
import 'package:fushi/src/ops/op_descriptions_web.dart';
import 'package:fushi/src/web_browser/data/memory_web_browser_store.dart';
import 'package:fushi/src/web_browser/data/web_browser_store.dart';
import 'package:fushi/src/web_browser/web_browser_sites.dart';

import '../helpers/test_platform_services.dart';
import '../helpers/web_ctl_fakes.dart';

/// 浏览器域可撤销操作的往返测试（spec §11）：书签增 / 改 / 删（含整棵文件夹重建）、
/// 广告拦截总开关 / 订阅列表 / 白名单（整份 / 加 / 删），各一条「执行 → 撤销 → 状态一致」，
/// 再加「执行后手动改过 → superseded、不覆盖」。以模型身份经 [OpInvoker] 调用，撤销载荷
/// 先过一遍 JSON。

class _TestAppModel extends AppModel {
  _TestAppModel() : super(testPlatformServices());

  @override
  bool moduleEnabled(ModuleId module) => true;
}

class _Ref implements WidgetRef {
  _Ref(this.model);

  final AppModel model;

  @override
  T read<T>(ProviderListenable<T> provider) => model as T;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('测试不该用到 ${invocation.memberName}');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MemoryWebBrowserStore store;
  late FakeWebAdblock adblock;
  late OpCatalog catalog;
  late OpInvoker invoker;
  late List<CtlRoute> routes;

  setUp(() {
    store = MemoryWebBrowserStore();
    adblock = FakeWebAdblock();
    routes = buildWebCtlRoutesFor(
      store: () => store,
      webEnabled: () => true,
      adblock: () => adblock,
      resolveInput: parseWebBrowserAddress,
      openUrl: (Uri url) async {},
    );
    final OpContext context = OpContext(ref: _Ref(_TestAppModel()));
    catalog = OpCatalog.build(
      routes,
      describeWebOps(OpDescribeKit(context, routes)),
    );
    invoker = OpInvoker(catalog);
  });

  Future<OpInvocation> run(String id, [Map<String, Object?>? args]) {
    final FushiOp op = catalog[id]!;
    return invoker.invoke(
      id,
      args ?? const <String, Object?>{},
      caller: OpCaller.model,
      captureUndo: true,
      grantedGates: <String>{
        for (final OpParam g in op.spec.gateParams) g.name,
      },
    );
  }

  Future<OpUndoStatus> undo(OpInvocation invocation) async {
    final Map<String, Object?> payload =
        jsonDecode(jsonEncode(invocation.undo!.payload))
            as Map<String, Object?>;
    return (await catalog[invocation.op.id]!.undo!.revert(payload)).status;
  }

  Map<String, Object?> resultMap(OpInvocation i) =>
      (i.result! as Map).cast<String, Object?>();

  /// 整棵书签树的（标题, 父标题, 网址）投影，按树序。
  Future<List<String>> tree([int? parentId, String parent = '/']) async {
    final List<String> out = <String>[];
    for (final WebBrowserBookmark b in await store.bookmarks(
      parentId: parentId,
    )) {
      out.add('$parent${b.title}${b.url == null ? '/' : ' <${b.url}>'}');
      if (b.isFolder) out.addAll(await tree(b.id, '$parent${b.title}/'));
    }
    return out;
  }

  test('目录里浏览器域每条路由都有描述，读写分级与撤销声明一致', () {
    expect(catalog.ops, hasLength(routes.length));
    for (final FushiOp op in catalog.ops) {
      if (op.risk == OpRisk.write) expect(op.undo, isNotNull, reason: op.id);
      if (op.risk != OpRisk.write) expect(op.undo, isNull, reason: op.id);
    }
    final FushiOp clear = catalog['web.history.clear']!;
    expect(clear.risk, OpRisk.irreversible);
    expect(clear.spec.gateParams.map((OpParam p) => p.name), <String>[
      'confirm',
    ]);
    expect(catalog['web.open']!.risk, OpRisk.read);
    expect(catalog['web.adblock.update']!.risk, OpRisk.read);
  });

  group('书签', () {
    test('加书签 → 撤销删掉它；加后被改名 → superseded、不删', () async {
      final OpInvocation added = await run(
        'web.bookmark.add',
        <String, Object?>{'url': 'https://a.example/', 'title': 'A'},
      );
      expect(await tree(), <String>['/A <https://a.example/>']);
      expect(await undo(added), OpUndoStatus.done);
      expect(await tree(), isEmpty);

      final OpInvocation again = await run(
        'web.bookmark.add',
        <String, Object?>{'type': 'folder', 'title': 'Dir'},
      );
      await store.updateBookmark(
        resultMap(again)['id']! as int,
        title: 'Renamed',
      );
      expect(await undo(again), OpUndoStatus.superseded);
      expect(await tree(), <String>['/Renamed/']);
    });

    test('改名 + 移动 + 排序 → 撤销回原标题、原目录、原位置', () async {
      final int dir = await store.addFolder(title: 'Dir');
      final int a = await store.addBookmark(
        title: 'A',
        url: Uri.parse('https://a.example/'),
      );
      await store.addBookmark(title: 'B', url: Uri.parse('https://b.example/'));
      final List<String> before = await tree();
      final OpInvocation edited = await run(
        'web.bookmark.update',
        <String, Object?>{'id': '$a', 'title': 'A2', 'parent': dir},
      );
      expect(await tree(), <String>[
        '/Dir/',
        '/Dir/A2 <https://a.example/>',
        '/B <https://b.example/>',
      ]);
      expect(await undo(edited), OpUndoStatus.done);
      expect(await tree(), before);

      final OpInvocation edited2 = await run(
        'web.bookmark.update',
        <String, Object?>{'id': '$a', 'title': 'A3'},
      );
      await store.updateBookmark(a, title: 'Mine');
      expect(await undo(edited2), OpUndoStatus.superseded);
      expect(await tree(), contains('/Mine <https://a.example/>'));
    });

    test('删非空文件夹 → 撤销按原顺序重建整棵子树、放回原位', () async {
      await store.addBookmark(title: 'X', url: Uri.parse('https://x.example/'));
      final int dir = await store.addFolder(title: 'Dir');
      await store.addBookmark(
        title: 'In1',
        url: Uri.parse('https://in1.example/'),
        parentId: dir,
      );
      final int sub = await store.addFolder(title: 'Sub', parentId: dir);
      await store.addBookmark(
        title: 'Deep',
        url: Uri.parse('https://deep.example/'),
        parentId: sub,
      );
      await store.addBookmark(title: 'Y', url: Uri.parse('https://y.example/'));
      final List<String> before = await tree();
      final OpInvocation deleted = await run(
        'web.bookmark.delete',
        <String, Object?>{'id': '$dir'},
      );
      expect(await tree(), <String>[
        '/X <https://x.example/>',
        '/Y <https://y.example/>',
      ]);
      expect(await undo(deleted), OpUndoStatus.done);
      expect(await tree(), before);
    });

    test('删书签后同一网址又被加回 → superseded、不重复建', () async {
      final int a = await store.addBookmark(
        title: 'A',
        url: Uri.parse('https://a.example/'),
      );
      final OpInvocation deleted = await run(
        'web.bookmark.delete',
        <String, Object?>{'id': '$a'},
      );
      await store.addBookmark(
        title: 'A again',
        url: Uri.parse('https://a.example/'),
      );
      expect(await undo(deleted), OpUndoStatus.superseded);
      expect(await tree(), <String>['/A again <https://a.example/>']);
    });
  });

  group('广告拦截', () {
    test('总开关 → 撤销；之后被手动改回 → superseded', () async {
      final OpInvocation off = await run(
        'web.adblock.enable',
        <String, Object?>{'enabled': false},
      );
      expect(adblock.enabled, isFalse);
      expect(await undo(off), OpUndoStatus.done);
      expect(adblock.enabled, isTrue);

      final OpInvocation off2 = await run(
        'web.adblock.enable',
        <String, Object?>{'enabled': false},
      );
      adblock.enabled = true;
      expect(await undo(off2), OpUndoStatus.superseded);
      expect(adblock.enabled, isTrue);
    });

    test('订阅列表 → 撤销恢复原订阅', () async {
      final OpInvocation sub = await run(
        'web.adblock.list.set',
        <String, Object?>{'id': 'easyprivacy', 'enabled': true},
      );
      expect(adblock.subscribed['easyprivacy'], isTrue);
      expect(await undo(sub), OpUndoStatus.done);
      expect(adblock.subscribed['easyprivacy'], isFalse);
    });

    test('白名单加 / 删 / 整份 → 撤销写回原文；之后被手改 → superseded', () async {
      adblock.allowlist = 'a.com; b.com';
      final OpInvocation added = await run(
        'web.adblock.allowlist.add',
        <String, Object?>{'host': 'c.org'},
      );
      expect(adblock.allowlist, 'a.com; b.com, c.org');
      expect(await undo(added), OpUndoStatus.done);
      expect(adblock.allowlist, 'a.com; b.com');

      final OpInvocation removed = await run(
        'web.adblock.allowlist.remove',
        <String, Object?>{'host': 'a.com'},
      );
      expect(FakeWebAdblock.parseHosts(adblock.allowlist), <String>['b.com']);
      expect(await undo(removed), OpUndoStatus.done);
      expect(adblock.allowlist, 'a.com; b.com');

      final OpInvocation set = await run(
        'web.adblock.allowlist.set',
        <String, Object?>{'allowlist': 'x.net'},
      );
      expect(adblock.allowlist, 'x.net');
      adblock.allowlist = 'x.net, mine.org';
      expect(await undo(set), OpUndoStatus.superseded);
      expect(adblock.allowlist, 'x.net, mine.org');
    });
  });
}
