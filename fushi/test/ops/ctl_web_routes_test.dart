import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_cli/fushi_cli.dart';

import 'package:fushi/src/ops/ctl_web_routes.dart';
import 'package:fushi/src/web_browser/data/memory_web_browser_store.dart';
import 'package:fushi/src/web_browser/data/web_browser_store.dart';
import 'package:fushi/src/web_browser/web_browser_sites.dart';

import '../helpers/web_ctl_fakes.dart';

Matcher _status(int status) => throwsA(
  isA<CtlFailure>().having((CtlFailure f) => f.status, 'status', status),
);

void main() {
  late MemoryWebBrowserStore store;
  late FakeWebAdblock adblock;
  late List<CtlRoute> routes;
  late List<Uri> opened;
  bool enabled = true;

  setUp(() {
    enabled = true;
    store = MemoryWebBrowserStore();
    adblock = FakeWebAdblock();
    opened = <Uri>[];
    routes = buildWebCtlRoutesFor(
      store: () => store,
      webEnabled: () => enabled,
      adblock: () => adblock,
      resolveInput: (String input) =>
          parseWebBrowserAddress(input) ??
          Uri.https('search.example', '/', <String, String>{'q': input}),
      openUrl: (Uri url) async => opened.add(url),
    );
  });

  Future<Object?> call(
    String method,
    String pattern, {
    Map<String, String> params = const <String, String>{},
    Map<String, Object?> body = const <String, Object?>{},
    Map<String, String> query = const <String, String>{},
  }) {
    final CtlRoute route = routes.singleWhere(
      (CtlRoute r) => r.method == method && r.pattern == pattern,
    );
    String path = pattern;
    params.forEach((String k, String v) => path = path.replaceAll(':$k', v));
    return route.handler(
      CtlCall(
        method: method,
        path: path,
        params: params,
        body: body,
        query: query,
      ),
    );
  }

  Map<String, Object?> asMap(Object? v) => (v! as Map).cast<String, Object?>();
  List<Map<String, Object?>> rows(Object? v, String key) =>
      <Map<String, Object?>>[
        for (final Object? row in asMap(v)[key]! as List<Object?>) asMap(row),
      ];

  const String bookmarks = '$kWebCtlRoot/bookmarks';
  const String adblockRoot = '$kWebCtlRoot/adblock';

  test('路由都在 /api/admin/web 下、method + pattern 唯一', () {
    final Set<String> keys = <String>{};
    for (final CtlRoute r in routes) {
      expect(r.pattern, startsWith('$kWebCtlRoot/'));
      expect(keys.add('${r.method} ${r.pattern}'), isTrue);
    }
  });

  group('打开网址', () {
    test('像网址就打开网址，否则按搜索引擎搜', () async {
      final Map<String, Object?> r = asMap(
        await call(
          'POST',
          '$kWebCtlRoot/open',
          body: const <String, Object?>{'url': 'example.com'},
        ),
      );
      expect(r['opened'], isTrue);
      expect(opened.single.host, 'example.com');
      await call(
        'POST',
        '$kWebCtlRoot/open',
        body: const <String, Object?>{'url': '日本語 辞書'},
      );
      expect(opened.last.host, 'search.example');
      expect(opened.last.queryParameters['q'], '日本語 辞書');
    });

    test('缺 url → 400；浏览器模块关闭 → 422', () async {
      expect(call('POST', '$kWebCtlRoot/open'), _status(400));
      enabled = false;
      expect(
        call(
          'POST',
          '$kWebCtlRoot/open',
          body: const <String, Object?>{'url': 'example.com'},
        ),
        _status(422),
      );
    });
  });

  group('历史', () {
    setUp(() {
      final DateTime now = DateTime.now();
      store
        ..seedHistory(
          url: Uri.parse('https://old.example/'),
          title: 'Old',
          lastVisitedAt: now.subtract(const Duration(days: 3)),
        )
        ..seedHistory(
          url: Uri.parse('https://new.example/'),
          title: 'New',
          lastVisitedAt: now.subtract(const Duration(minutes: 5)),
        );
    });

    test('列表：最近在前、可搜索', () async {
      final List<Map<String, Object?>> all = rows(
        await call('GET', '$kWebCtlRoot/history'),
        'history',
      );
      expect(all.map((Map<String, Object?> r) => r['title']), <String>[
        'New',
        'Old',
      ]);
      final List<Map<String, Object?>> hit = rows(
        await call(
          'GET',
          '$kWebCtlRoot/history',
          query: const <String, String>{'search': 'old'},
        ),
        'history',
      );
      expect(hit.single['title'], 'Old');
      expect(
        call(
          'GET',
          '$kWebCtlRoot/history',
          query: const <String, String>{'limit': '0'},
        ),
        _status(400),
      );
    });

    test('清除：按时间范围（页面同一组范围），必须 confirm', () async {
      expect(
        call(
          'POST',
          '$kWebCtlRoot/history/clear',
          body: const <String, Object?>{'range': 'day'},
        ),
        _status(400),
      );
      await call(
        'POST',
        '$kWebCtlRoot/history/clear',
        body: const <String, Object?>{'range': 'day', 'confirm': true},
      );
      expect(
        (await store.history()).map((WebBrowserHistoryEntry e) => e.title),
        <String>['Old'],
      );
      await call(
        'POST',
        '$kWebCtlRoot/history/clear',
        body: const <String, Object?>{'range': 'all', 'confirm': true},
      );
      expect(await store.history(), isEmpty);
    });

    test('清除：按条删除；range / ids 二选一；未知范围 → 400', () async {
      final int oldId = (await store.history()).last.id;
      await call(
        'POST',
        '$kWebCtlRoot/history/clear',
        body: <String, Object?>{
          'ids': <String>['$oldId'],
          'confirm': true,
        },
      );
      expect(
        (await store.history()).map((WebBrowserHistoryEntry e) => e.title),
        <String>['New'],
      );
      expect(
        call(
          'POST',
          '$kWebCtlRoot/history/clear',
          body: const <String, Object?>{'confirm': true},
        ),
        _status(400),
      );
      expect(
        call(
          'POST',
          '$kWebCtlRoot/history/clear',
          body: const <String, Object?>{'range': 'year', 'confirm': true},
        ),
        _status(400),
      );
    });
  });

  group('书签', () {
    test('加书签 / 文件夹，列出一层与整棵树', () async {
      final Map<String, Object?> folder = asMap(
        await call(
          'POST',
          bookmarks,
          body: const <String, Object?>{'type': 'folder', 'title': 'Dir'},
        ),
      );
      expect(folder['folder'], isTrue);
      final Map<String, Object?> bm = asMap(
        await call(
          'POST',
          bookmarks,
          body: <String, Object?>{'url': 'example.com', 'parent': folder['id']},
        ),
      );
      // 标题留空用域名（与编辑表单同一口径）。
      expect(bm['title'], 'example.com');
      expect(bm['url'], 'https://example.com');
      expect(bm['parentId'], folder['id']);
      await call(
        'POST',
        bookmarks,
        body: const <String, Object?>{
          'url': 'https://b.example/',
          'title': 'B',
        },
      );
      final List<Map<String, Object?>> root = rows(
        await call('GET', bookmarks),
        'bookmarks',
      );
      expect(root.map((Map<String, Object?> r) => r['title']), <String>[
        'Dir',
        'B',
      ]);
      expect(root.map((Map<String, Object?> r) => r['index']), <int>[0, 1]);
      final List<Map<String, Object?>> inside = rows(
        await call(
          'GET',
          bookmarks,
          query: <String, String>{'folder': '${folder['id']}'},
        ),
        'bookmarks',
      );
      expect(inside.single['title'], 'example.com');
      final List<Map<String, Object?>> tree = rows(
        await call(
          'GET',
          bookmarks,
          query: const <String, String>{'recursive': 'true'},
        ),
        'bookmarks',
      );
      expect(tree.map((Map<String, Object?> r) => r['title']), <String>[
        'Dir',
        'example.com',
        'B',
      ]);
    });

    test('加：不是网址 / 文件夹缺标题 / 父目录不存在或不是文件夹 / 未知 type', () async {
      expect(
        call(
          'POST',
          bookmarks,
          body: const <String, Object?>{'url': 'not a url'},
        ),
        _status(400),
      );
      expect(
        call(
          'POST',
          bookmarks,
          body: const <String, Object?>{'type': 'folder'},
        ),
        _status(400),
      );
      expect(
        call(
          'POST',
          bookmarks,
          body: const <String, Object?>{'url': 'a.example', 'parent': 99},
        ),
        _status(404),
      );
      final int bmId = await store.addBookmark(
        title: 'A',
        url: Uri.parse('https://a.example/'),
      );
      expect(
        call(
          'POST',
          bookmarks,
          body: <String, Object?>{'url': 'b.example', 'parent': bmId},
        ),
        _status(400),
      );
      expect(
        call(
          'POST',
          bookmarks,
          body: const <String, Object?>{'type': 'tab', 'title': 'x'},
        ),
        _status(400),
      );
    });

    test('改：标题 / 网址 / 移动 / 排序；移进自己子孙 → 409', () async {
      final int dir = await store.addFolder(title: 'Dir');
      final int sub = await store.addFolder(title: 'Sub', parentId: dir);
      final int a = await store.addBookmark(
        title: 'A',
        url: Uri.parse('https://a.example/'),
      );
      final Map<String, Object?> edited = asMap(
        await call(
          'PUT',
          '$bookmarks/:id',
          params: <String, String>{'id': '$a'},
          body: const <String, Object?>{
            'title': 'A2',
            'url': 'https://a2.example/',
          },
        ),
      );
      expect(edited['title'], 'A2');
      expect(edited['url'], 'https://a2.example/');
      final Map<String, Object?> moved = asMap(
        await call(
          'PUT',
          '$bookmarks/:id',
          params: <String, String>{'id': '$a'},
          body: <String, Object?>{'parent': sub},
        ),
      );
      expect(moved['parentId'], sub);
      final Map<String, Object?> back = asMap(
        await call(
          'PUT',
          '$bookmarks/:id',
          params: <String, String>{'id': '$a'},
          body: const <String, Object?>{'root': true, 'index': 0},
        ),
      );
      expect(back['parentId'], isNull);
      expect(back['index'], 0);
      expect(
        call(
          'PUT',
          '$bookmarks/:id',
          params: <String, String>{'id': '$dir'},
          body: <String, Object?>{'parent': sub},
        ),
        _status(409),
      );
      expect(
        call(
          'PUT',
          '$bookmarks/:id',
          params: <String, String>{'id': '$dir'},
          body: const <String, Object?>{'url': 'https://x.example/'},
        ),
        _status(400),
      );
      expect(
        call('PUT', '$bookmarks/:id', params: <String, String>{'id': '$a'}),
        _status(400),
      );
      expect(
        call(
          'PUT',
          '$bookmarks/:id',
          params: const <String, String>{'id': '999'},
          body: const <String, Object?>{'title': 'x'},
        ),
        _status(404),
      );
    });

    test('删：书签直接删；非空文件夹要 confirm，连同子孙一起删', () async {
      final int dir = await store.addFolder(title: 'Dir');
      await store.addBookmark(
        title: 'In',
        url: Uri.parse('https://in.example/'),
        parentId: dir,
      );
      final int a = await store.addBookmark(
        title: 'A',
        url: Uri.parse('https://a.example/'),
      );
      await call(
        'DELETE',
        '$bookmarks/:id',
        params: <String, String>{'id': '$a'},
      );
      expect(
        call(
          'DELETE',
          '$bookmarks/:id',
          params: <String, String>{'id': '$dir'},
        ),
        _status(400),
      );
      final Map<String, Object?> r = asMap(
        await call(
          'DELETE',
          '$bookmarks/:id',
          params: <String, String>{'id': '$dir'},
          body: const <String, Object?>{'confirm': true},
        ),
      );
      expect(r['descendants'], 1);
      expect(await store.allBookmarks(), isEmpty);
      expect(await store.bookmarks(), isEmpty);
    });
  });

  group('广告拦截', () {
    test('状态：开关、列表与白名单主机', () async {
      adblock.allowlist = 'example.com, https://www.foo.org/path';
      final Map<String, Object?> s = asMap(await call('GET', adblockRoot));
      expect(s['enabled'], isTrue);
      expect(s['allowlistHosts'], <String>['example.com', 'www.foo.org']);
      expect(
        rows(s, 'lists').map((Map<String, Object?> l) => l['id']),
        <String>['easylist', 'easyprivacy'],
      );
    });

    test('核心未就绪 → 409', () async {
      adblock.opened = false;
      expect(call('GET', adblockRoot), _status(409));
    });

    test('总开关 / 订阅列表 / 立即更新', () async {
      await call(
        'POST',
        '$adblockRoot/enabled',
        body: const <String, Object?>{'enabled': false},
      );
      expect(adblock.enabled, isFalse);
      expect(call('POST', '$adblockRoot/enabled'), _status(400));
      final Map<String, Object?> list = asMap(
        await call(
          'POST',
          '$adblockRoot/lists/:id',
          params: const <String, String>{'id': 'easyprivacy'},
          body: const <String, Object?>{'enabled': true},
        ),
      );
      expect(list['enabled'], isTrue);
      expect(adblock.subscribed['easyprivacy'], isTrue);
      expect(
        call(
          'POST',
          '$adblockRoot/lists/:id',
          params: const <String, String>{'id': 'nope'},
          body: const <String, Object?>{'enabled': true},
        ),
        _status(404),
      );
      final Map<String, Object?> updated = asMap(
        await call('POST', '$adblockRoot/update'),
      );
      expect(updated['ok'], isTrue);
      expect(adblock.updates, 1);
    });

    test('白名单：整份设置 / 加一个（不重复）/ 删一个', () async {
      await call(
        'PUT',
        '$adblockRoot/allowlist',
        body: const <String, Object?>{'allowlist': 'a.com b.com'},
      );
      expect(adblock.allowlist, 'a.com b.com');
      await call(
        'POST',
        '$adblockRoot/allowlist',
        body: const <String, Object?>{'host': 'c.org'},
      );
      expect(adblock.allowlist, 'a.com b.com, c.org');
      // 已在白名单（写法不同的同一主机）：原文不动。
      await call(
        'POST',
        '$adblockRoot/allowlist',
        body: const <String, Object?>{'host': 'https://A.com/'},
      );
      expect(adblock.allowlist, 'a.com b.com, c.org');
      expect(
        call(
          'POST',
          '$adblockRoot/allowlist',
          body: const <String, Object?>{'host': 'a.com, d.com'},
        ),
        _status(400),
      );
      await call(
        'DELETE',
        '$adblockRoot/allowlist/:host',
        params: const <String, String>{'host': 'b.com'},
      );
      expect(FakeWebAdblock.parseHosts(adblock.allowlist), <String>[
        'a.com',
        'c.org',
      ]);
      expect(
        call(
          'DELETE',
          '$adblockRoot/allowlist/:host',
          params: const <String, String>{'host': 'zzz.com'},
        ),
        _status(404),
      );
    });

    test('白名单：Rust 解析不出站点 → 写回原文、400', () async {
      adblock.allowlist = 'a.com';
      expect(
        call(
          'POST',
          '$adblockRoot/allowlist',
          body: const <String, Object?>{'host': '*.'},
        ),
        _status(400),
      );
      expect(adblock.allowlist, 'a.com');
    });
  });
}
