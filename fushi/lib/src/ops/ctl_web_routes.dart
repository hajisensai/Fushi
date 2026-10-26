import 'dart:async';

import 'package:flutter/widgets.dart' show NavigatorState;
import 'package:fushi_cli/fushi_cli.dart';
import 'package:fushi_web_core/fushi_web_core.dart';

import 'package:fushi/src/models/module_id.dart';
import 'package:fushi/src/ops/op_context.dart';
import 'package:fushi/src/pages/implementations/fushi_web_browser_page.dart'
    show openFushiWebBrowser;
import 'package:fushi/src/pages/implementations/web_browser/pages/web_browser_page_common.dart'
    show WebBrowserClearRange;
import 'package:fushi/src/web_adblock/web_adblock_service.dart';
import 'package:fushi/src/web_browser/data/web_browser_store.dart';
import 'package:fushi/src/web_browser/data/web_browser_store_provider.dart';
import 'package:fushi/src/web_browser/web_browser_sites.dart';

/// 内置浏览器（书签 / 历史 / 打开网址）与网页广告拦截的控制通道路由（spec
/// `docs/specs/2026-10-26-ai-operations-agent-design.md` §2.2 / §8 P2）。每条路由调用
/// UI 按钮背后的同一个方法，不另写业务逻辑：
///
/// - 书签 / 历史：书签页 / 历史页 / 「清除浏览数据」页直接调的 [WebBrowserStore]
///   （`bookmarks` / `addBookmark` / `addFolder` / `updateBookmark` / `deleteBookmark` /
///   `history` / `deleteHistory` / `clearHistory`），清除时间范围用页面同一个
///   [WebBrowserClearRange]；
/// - 打开网址：入口页地址栏的 [resolveWebBrowserInput]（不像网址就按当前搜索引擎搜）
///   + [openFushiWebBrowser]（全屏浏览页）。只导航，不读网页内容；
/// - 广告拦截：「系统 › 网页广告拦截」分组背后的 [WebAdblockService]（总开关
///   `setEnabled`、订阅列表 `setListEnabled`、「立即更新」`updateNow`、白名单
///   `setAllowlist`）。app 只有内置目录里的列表可订阅、没有自定义规则 / 自定义列表地址，
///   这里同样不给；白名单的「加一个 / 删一个站点」是在白名单原文上增删一项后整份
///   `setAllowlist`（解析与归一化仍在 Rust 核心）。
///
/// CLI 侧是 `fushi_cli web …`（`packages/fushi_cli/lib/src/commands/web_commands.dart`）。
List<CtlRoute> buildWebCtlRoutes(OpContext context) => buildWebCtlRoutesFor(
  store: () => context.ref.read(webBrowserStoreProvider),
  webEnabled: () => context.appModel.moduleVisibility.isEnabled(ModuleId.web),
  adblock: () =>
      ServiceWebAdblockPort(context.ref.read(webAdblockServiceProvider)),
  resolveInput: (String input) => resolveWebBrowserInput(
    input,
    readWebBrowserSearchProvider(context.appModel.prefsRepo),
  ),
  openUrl: (Uri url) async {
    if (context.navigator == null) {
      throw const CtlFailure.conflict('主界面还没就绪');
    }
    await context.focusMainWindow();
    final NavigatorState? navigator = context.navigator;
    if (navigator == null || !navigator.mounted) {
      throw const CtlFailure.conflict('主界面还没就绪');
    }
    unawaited(openFushiWebBrowser(navigator.context, url));
  },
);

/// 路由根。
const String kWebCtlRoot = '/api/admin/web';

/// 清历史的时间范围 wire 名 → 页面同一个 [WebBrowserClearRange]。
const Map<String, WebBrowserClearRange> kWebCtlClearRanges =
    <String, WebBrowserClearRange>{
      'hour': WebBrowserClearRange.lastHour,
      'day': WebBrowserClearRange.lastDay,
      'week': WebBrowserClearRange.lastWeek,
      'month': WebBrowserClearRange.lastMonth,
      'all': WebBrowserClearRange.allTime,
    };

/// 广告拦截的命令面：设置分组用到的 [WebAdblockService] 那几个方法 + 内置目录
/// （测试注入假件，不碰原生库）。
abstract interface class WebAdblockCtlPort {
  /// 内置过滤列表目录（Rust 给）。
  List<AdblockCatalogEntry> get catalog;

  /// Rust 核心的最新快照；数据目录未就绪时是 [AdblockSnapshot.notOpened]。
  AdblockSnapshot get snapshot;

  Future<void> setEnabled(bool enabled);
  Future<void> setListEnabled(String id, bool enabled);
  void setAllowlist(String raw);
  Future<bool> updateNow();
}

/// 生产实现：委托给全应用共用的 [WebAdblockService]。
class ServiceWebAdblockPort implements WebAdblockCtlPort {
  ServiceWebAdblockPort(this.service);

  final WebAdblockService service;

  @override
  List<AdblockCatalogEntry> get catalog => AdblockCore.catalog();
  @override
  AdblockSnapshot get snapshot => service.snapshot;
  @override
  Future<void> setEnabled(bool enabled) => service.setEnabled(enabled);
  @override
  Future<void> setListEnabled(String id, bool enabled) =>
      service.setListEnabled(id, enabled);
  @override
  void setAllowlist(String raw) => service.setAllowlist(raw);
  @override
  Future<bool> updateNow() => service.updateNow();
}

/// 可注入依赖的路由表（测试换掉 store、广告拦截与开页面）。
List<CtlRoute> buildWebCtlRoutesFor({
  required WebBrowserStore Function() store,
  required bool Function() webEnabled,
  required WebAdblockCtlPort Function() adblock,
  required Uri? Function(String input) resolveInput,
  required Future<void> Function(Uri url) openUrl,
}) {
  final _WebCtl ctl = _WebCtl(
    store: store,
    webEnabled: webEnabled,
    adblock: adblock,
    resolveInput: resolveInput,
    openUrl: openUrl,
  );
  const String adblockRoot = '$kWebCtlRoot/adblock';
  return <CtlRoute>[
    CtlRoute.post('$kWebCtlRoot/open', ctl.open),
    CtlRoute.get('$kWebCtlRoot/history', ctl.history),
    CtlRoute.post('$kWebCtlRoot/history/clear', ctl.clearHistory),
    CtlRoute.get('$kWebCtlRoot/bookmarks', ctl.bookmarks),
    CtlRoute.post('$kWebCtlRoot/bookmarks', ctl.addBookmark),
    CtlRoute.put('$kWebCtlRoot/bookmarks/:id', ctl.updateBookmark),
    CtlRoute.delete('$kWebCtlRoot/bookmarks/:id', ctl.deleteBookmark),
    CtlRoute.get(adblockRoot, ctl.adblockStatus),
    CtlRoute.post('$adblockRoot/enabled', ctl.setAdblockEnabled),
    CtlRoute.post('$adblockRoot/lists/:id', ctl.setListEnabled),
    CtlRoute.post('$adblockRoot/update', ctl.updateLists),
    CtlRoute.put('$adblockRoot/allowlist', ctl.setAllowlist),
    CtlRoute.post('$adblockRoot/allowlist', ctl.allowSite),
    CtlRoute.delete('$adblockRoot/allowlist/:host', ctl.disallowSite),
  ];
}

/// 书签 / 文件夹的 JSON（[index] = 在同级里的顺序，0 起；撤销按它放回原位）。
Map<String, Object?> webCtlBookmarkJson(WebBrowserBookmark b, int index) =>
    <String, Object?>{
      'id': b.id,
      'title': b.title,
      'url': b.url?.toString(),
      'folder': b.isFolder,
      'parentId': b.parentId,
      'index': index,
      'createdAt': b.createdAt.millisecondsSinceEpoch,
    };

/// 广告拦截快照的 JSON。
Map<String, Object?> webCtlAdblockJson(AdblockSnapshot s) => <String, Object?>{
  'enabled': s.enabled,
  'status': s.status.name,
  'syncing': s.syncing,
  'active': s.isActive,
  'ruleCount': s.ruleCount,
  'lastUpdatedAt': ?s.lastUpdatedAt?.millisecondsSinceEpoch,
  'lastSyncOk': ?s.lastSyncOk,
  'error': ?s.error,
  'allowlist': s.allowlist,
  'allowlistHosts': s.allowlistHosts,
  'lists': <Map<String, Object?>>[
    for (final AdblockListState l in s.lists)
      <String, Object?>{
        'id': l.id,
        'title': l.title,
        'host': l.host,
        'enabled': l.enabled,
        'cached': l.cached,
        'stale': l.stale,
        'ruleCount': l.ruleCount,
        'fetchedAt': ?l.fetchedAt?.millisecondsSinceEpoch,
        'lastError': ?l.lastError,
      },
  ],
};

class _WebCtl {
  _WebCtl({
    required this.store,
    required this.webEnabled,
    required this.adblock,
    required this.resolveInput,
    required this.openUrl,
  });

  final WebBrowserStore Function() store;
  final bool Function() webEnabled;
  final WebAdblockCtlPort Function() adblock;
  final Uri? Function(String input) resolveInput;
  final Future<void> Function(Uri url) openUrl;

  void _requireWeb() {
    if (!webEnabled()) {
      throw const CtlFailure.rejected('「浏览器」模块已关闭（设置 › 功能模块）');
    }
  }

  void _requireConfirm(CtlCall call, String what) {
    if (call.optBool('confirm') != true) {
      throw CtlFailure.badRequest('$what 需要 confirm=true');
    }
  }

  // ── 打开网址 ─────────────────────────────────────────────────────────

  /// `web open <网址|搜索词>`：与入口页地址栏同一判据，在全屏浏览页打开。
  Future<Object?> open(CtlCall call) async {
    _requireWeb();
    final String input = call.requireString('url');
    final Uri? url = resolveInput(input);
    if (url == null) throw CtlFailure.badRequest('打不开「$input」');
    await openUrl(url);
    return <String, Object?>{
      'opened': true,
      'url': url.toString(),
      'page': 'web_browser',
    };
  }

  // ── 历史 ─────────────────────────────────────────────────────────────

  /// `web history [关键词]`：最近访问倒序。
  Future<Object?> history(CtlCall call) async {
    _requireWeb();
    final int limit = call.optInt('limit') ?? 50;
    final int offset = call.optInt('offset') ?? 0;
    if (limit <= 0 || offset < 0) {
      throw const CtlFailure.badRequest('limit 必须为正、offset 不能为负');
    }
    final List<WebBrowserHistoryEntry> rows = await store().history(
      query: call.optString('search') ?? '',
      limit: limit,
      offset: offset,
    );
    return <String, Object?>{
      'history': <Map<String, Object?>>[
        for (final WebBrowserHistoryEntry e in rows)
          <String, Object?>{
            'id': e.id,
            'title': e.title,
            'url': e.url.toString(),
            'lastVisitedAt': e.lastVisitedAt.millisecondsSinceEpoch,
            'visitCount': e.visitCount,
          },
      ],
    };
  }

  /// `web history-clear --range <…> | --id <…> --yes`：历史页「清除历史」/ 多选删除
  /// 的同一组 store 方法。删掉的历史找不回来。
  Future<Object?> clearHistory(CtlCall call) async {
    _requireWeb();
    final String? rangeName = call.optString('range');
    final List<String> rawIds = call.stringList('ids');
    if ((rangeName == null) == rawIds.isEmpty) {
      throw const CtlFailure.badRequest('range 与 ids 二选一');
    }
    _requireConfirm(call, '清除浏览历史');
    if (rangeName != null) {
      final WebBrowserClearRange? range = kWebCtlClearRanges[rangeName];
      if (range == null) {
        throw CtlFailure.badRequest(
          'range 只能是 ${kWebCtlClearRanges.keys.join(' / ')}，收到「$rangeName」',
        );
      }
      await store().clearHistory(since: range.sinceFrom(DateTime.now()));
      return <String, Object?>{'cleared': true, 'range': rangeName};
    }
    final List<int> ids = <int>[
      for (final String raw in rawIds)
        int.tryParse(raw) ?? (throw CtlFailure.badRequest('历史 id 必须是整数：$raw')),
    ];
    await store().deleteHistory(ids);
    return <String, Object?>{'cleared': true, 'ids': ids};
  }

  // ── 书签 ─────────────────────────────────────────────────────────────

  /// 全部书签与文件夹（深度优先，每项带同级顺序 index）。
  Future<List<Map<String, Object?>>> _tree(int? parentId) async {
    final List<Map<String, Object?>> out = <Map<String, Object?>>[];
    final List<WebBrowserBookmark> level = await store().bookmarks(
      parentId: parentId,
    );
    for (int i = 0; i < level.length; i++) {
      out.add(webCtlBookmarkJson(level[i], i));
      if (level[i].isFolder) out.addAll(await _tree(level[i].id));
    }
    return out;
  }

  /// 按 id 找一项（store 没有按 id 取的接口：在树里找）。
  Future<Map<String, Object?>?> _find(int id) async {
    for (final Map<String, Object?> row in await _tree(null)) {
      if (row['id'] == id) return row;
    }
    return null;
  }

  int _idParam(CtlCall call) {
    final int? id = int.tryParse(call.params['id'] ?? '');
    if (id == null) {
      throw CtlFailure.badRequest('书签 id 必须是整数：${call.params['id']}');
    }
    return id;
  }

  /// 目标父文件夹：null = 根目录；不存在 / 不是文件夹都是错误。
  Future<int?> _parentFolder(int? parentId) async {
    if (parentId == null) return null;
    final Map<String, Object?>? parent = await _find(parentId);
    if (parent == null) throw CtlFailure.notFound('没有文件夹 $parentId');
    if (parent['folder'] != true) {
      throw CtlFailure.badRequest('$parentId 是书签不是文件夹');
    }
    return parentId;
  }

  Uri _parseUrl(String raw) =>
      parseWebBrowserAddress(raw) ?? (throw CtlFailure.badRequest('不是网址：$raw'));

  /// `web bookmarks [--folder <id>] [--all]`：书签页同一份数据（文件夹与书签混排）。
  Future<Object?> bookmarks(CtlCall call) async {
    _requireWeb();
    if (call.optBool('recursive') == true) {
      return <String, Object?>{'bookmarks': await _tree(null)};
    }
    final int? folder = await _parentFolder(call.optInt('folder'));
    final List<WebBrowserBookmark> level = await store().bookmarks(
      parentId: folder,
    );
    return <String, Object?>{
      'folder': folder,
      'bookmarks': <Map<String, Object?>>[
        for (int i = 0; i < level.length; i++) webCtlBookmarkJson(level[i], i),
      ],
    };
  }

  /// `web bookmark-add <网址> [--title] [--folder]` / `web folder-add <名称>`：书签页
  /// 「新建文件夹」与浏览页「加书签」的 `addFolder` / `addBookmark`（排到目标目录末尾）。
  Future<Object?> addBookmark(CtlCall call) async {
    _requireWeb();
    final String type = call.optString('type') ?? 'bookmark';
    if (type != 'bookmark' && type != 'folder') {
      throw CtlFailure.badRequest('type 只能是 bookmark / folder，收到「$type」');
    }
    final bool folder = type == 'folder';
    final int? parentId = await _parentFolder(call.optInt('parent'));
    final String? title = call.optString('title');
    final int id;
    if (folder) {
      if (title == null) throw const CtlFailure.badRequest('新建文件夹需要 title');
      id = await store().addFolder(title: title, parentId: parentId);
    } else {
      final Uri url = _parseUrl(call.requireString('url'));
      // 与书签编辑表单同一口径：标题留空用域名。
      id = await store().addBookmark(
        title: title ?? url.host,
        url: url,
        parentId: parentId,
      );
    }
    return (await _find(id)) ?? <String, Object?>{'id': id};
  }

  /// `web bookmark-edit <id> [--title] [--url] [--folder|--root] [--index]`：书签页「编辑」
  /// 「移动到」「上移 / 下移」背后的 `updateBookmark`（只改给了的字段）。
  Future<Object?> updateBookmark(CtlCall call) async {
    _requireWeb();
    final int id = _idParam(call);
    final Map<String, Object?>? current = await _find(id);
    if (current == null) throw CtlFailure.notFound('没有书签 $id');
    final String? title = call.optString('title');
    final String? rawUrl = call.optString('url');
    final bool toRoot = call.optBool('root') ?? false;
    final int? parent = call.optInt('parent');
    final int? index = call.optInt('index');
    if (toRoot && parent != null) {
      throw const CtlFailure.badRequest('parent 与 root 只能给一个');
    }
    if (title == null &&
        rawUrl == null &&
        !toRoot &&
        parent == null &&
        index == null) {
      throw const CtlFailure.badRequest(
        '没有要改的字段（title / url / parent / root / index）',
      );
    }
    if (rawUrl != null && current['folder'] == true) {
      throw const CtlFailure.badRequest('文件夹没有网址');
    }
    if (index != null && index < 0) {
      throw const CtlFailure.badRequest('index 不能为负');
    }
    if (parent != null) {
      await _parentFolder(parent);
      // store 对「移进自己或子孙」静默忽略：这里先说清楚。
      int? cursor = parent;
      while (cursor != null) {
        if (cursor == id) {
          throw const CtlFailure.conflict('不能把文件夹移进它自己或它的子文件夹');
        }
        cursor = (await _find(cursor))?['parentId'] as int?;
      }
    }
    await store().updateBookmark(
      id,
      title: title,
      url: rawUrl == null ? null : _parseUrl(rawUrl),
      parentId: parent,
      position: index,
      moveToRoot: toRoot,
    );
    return (await _find(id)) ?? <String, Object?>{'id': id};
  }

  /// `web bookmark-rm <id>`：书签页「删除」的 `deleteBookmark`（文件夹连同其下全部内容；
  /// 非空文件夹与页面一样要先确认）。
  Future<Object?> deleteBookmark(CtlCall call) async {
    _requireWeb();
    final int id = _idParam(call);
    final Map<String, Object?>? current = await _find(id);
    if (current == null) throw CtlFailure.notFound('没有书签 $id');
    int descendants = 0;
    if (current['folder'] == true) {
      descendants = (await _tree(id)).length;
      if (descendants > 0) {
        _requireConfirm(call, '删除非空文件夹（连同其下 $descendants 项）');
      }
    }
    await store().deleteBookmark(id);
    return <String, Object?>{
      'deleted': true,
      ...current,
      'descendants': descendants,
    };
  }

  // ── 广告拦截 ─────────────────────────────────────────────────────────

  WebAdblockCtlPort _adblock() {
    final WebAdblockCtlPort port = adblock();
    if (identical(port.snapshot, AdblockSnapshot.notOpened)) {
      throw const CtlFailure.conflict('广告拦截还没就绪（app 还在初始化）');
    }
    return port;
  }

  /// `web adblock`：总开关、引擎状态、订阅列表与白名单。
  Future<Object?> adblockStatus(CtlCall call) async =>
      webCtlAdblockJson(_adblock().snapshot);

  bool _requireBool(CtlCall call, String name) =>
      call.optBool(name) ?? (throw CtlFailure.badRequest('$name 缺失'));

  /// `web adblock-on` / `web adblock-off`：设置页总开关（打开时顺带同步一次列表）。
  Future<Object?> setAdblockEnabled(CtlCall call) async {
    final bool enabled = _requireBool(call, 'enabled');
    final WebAdblockCtlPort port = _adblock();
    await port.setEnabled(enabled);
    return webCtlAdblockJson(port.snapshot);
  }

  /// `web adblock-list <id> --on|--off`：订阅 / 取消订阅一份内置列表。与设置页开关一样
  /// 不等后台同步（订阅集立刻变，引擎随后跟上）。
  Future<Object?> setListEnabled(CtlCall call) async {
    final String id = call.params['id'] ?? '';
    final bool enabled = _requireBool(call, 'enabled');
    final WebAdblockCtlPort port = _adblock();
    if (!port.catalog.any((AdblockCatalogEntry e) => e.id == id)) {
      throw CtlFailure.notFound(
        '没有过滤列表「$id」（可选：'
        '${port.catalog.map((AdblockCatalogEntry e) => e.id).join(' / ')}）',
      );
    }
    unawaited(port.setListEnabled(id, enabled));
    return <String, Object?>{
      'id': id,
      'enabled': port.snapshot.isListEnabled(id),
      'adblock': webCtlAdblockJson(port.snapshot),
    };
  }

  /// `web adblock-update`：「立即更新」——强制联网核对全部订阅列表。
  Future<Object?> updateLists(CtlCall call) async {
    final WebAdblockCtlPort port = _adblock();
    final bool ok = await port.updateNow();
    return <String, Object?>{'ok': ok, ...webCtlAdblockJson(port.snapshot)};
  }

  /// `web adblock-allow --set <原文>`：设置页白名单输入框（整份原文）。
  Future<Object?> setAllowlist(CtlCall call) async {
    final Object? raw = call.body['allowlist'] ?? call.query['allowlist'];
    if (raw == null) throw const CtlFailure.badRequest('allowlist 缺失');
    final WebAdblockCtlPort port = _adblock();
    port.setAllowlist('$raw'.trim());
    return webCtlAdblockJson(port.snapshot);
  }

  /// `web adblock-allow <站点>`：白名单加一个站点（原文末尾追加，Rust 解析归一化）。
  Future<Object?> allowSite(CtlCall call) async {
    final String host = call.requireString('host');
    if (host.contains(RegExp(r'[\s,;，、]'))) {
      throw CtlFailure.badRequest('一次只加一个站点：$host');
    }
    final WebAdblockCtlPort port = _adblock();
    final AdblockSnapshot before = port.snapshot;
    // 已在白名单（含写法不同的同一主机）：不动原文。
    if (before.allowlistHosts.contains(_norm(host))) {
      return webCtlAdblockJson(before);
    }
    final String raw = before.allowlist.trim();
    port.setAllowlist(raw.isEmpty ? host : '$raw, $host');
    final AdblockSnapshot after = port.snapshot;
    if (!after.allowlistHosts.contains(_norm(host))) {
      // Rust 没解析出这个站点（输入不是主机名）：写回原文，不留半截改动。
      port.setAllowlist(before.allowlist);
      throw CtlFailure.badRequest('不是站点：$host');
    }
    return webCtlAdblockJson(after);
  }

  /// `web adblock-disallow <站点>`：从白名单删一个站点（按 Rust 解析出的主机名删，
  /// 剩下的主机名重写成原文）。
  Future<Object?> disallowSite(CtlCall call) async {
    final String host = _norm(call.params['host'] ?? '');
    final WebAdblockCtlPort port = _adblock();
    final List<String> hosts = port.snapshot.allowlistHosts;
    if (!hosts.contains(host)) {
      throw CtlFailure.notFound('白名单里没有 $host');
    }
    port.setAllowlist(hosts.where((String h) => h != host).join(', '));
    return webCtlAdblockJson(port.snapshot);
  }

  /// 与 Rust 白名单解析同口径的单个站点归一化（小写、去协议 / 路径 / 端口 / `*.` 前缀），
  /// 只用来比对，不落盘。
  static String _norm(String raw) {
    String t = raw.trim().toLowerCase();
    final int scheme = t.indexOf('://');
    if (scheme >= 0) t = t.substring(scheme + 3);
    final int at = t.lastIndexOf('@');
    if (at >= 0) t = t.substring(at + 1);
    for (final String stop in <String>['/', '?', '#', ':']) {
      final int i = t.indexOf(stop);
      if (i >= 0) t = t.substring(0, i);
    }
    while (t.startsWith('*.') || t.startsWith('.')) {
      t = t.substring(t.startsWith('*.') ? 2 : 1);
    }
    return t;
  }
}
