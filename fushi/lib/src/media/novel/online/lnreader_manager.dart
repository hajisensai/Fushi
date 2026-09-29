import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'package:fushi/src/media/novel/online/lnreader_cloudflare.dart';
import 'package:fushi/src/media/novel/online/lnreader_models.dart';
import 'package:fushi/src/media/novel/online/lnreader_runtime.dart';

/// 官方 LNReader 插件仓库。上游 app 不内置任何仓库；本仓把它**内置**（恒在、
/// 排第一、不可删改），装上就能直接装官方扩展（2026-09-25 用户口径）。
const String kLnReaderOfficialStoreUrl =
    'https://raw.githubusercontent.com/LNReader/lnreader-plugins/plugins/v3.0.0/.dist/plugins.min.json';

/// 在用户仓库前补上内置仓库（去重）。
List<LnReaderStore> withBuiltinLnReaderStore(
  List<LnReaderStore> stores, {
  required String builtinUrl,
}) => <LnReaderStore>[
  LnReaderStore(indexUrl: builtinUrl, name: 'LNReader'),
  for (final LnReaderStore store in stores)
    if (store.indexUrl != builtinUrl) store,
];

/// 小说在线源（LNReader 插件）的仓库 / 安装 / 源设置管理器。
///
/// 与漫画 / 视频的 `MihonManager` 同一职责形态（仓库 → 目录 → 安装 → 在线源），
/// 但 LNReader 一个插件就是一个源、插件是纯 JS 没有签名，所以不共用那套 APK
/// 管线。状态不进 Drift：仓库与已装插件落 `state.json`，插件源码落
/// `plugins/<id>.js`，插件的 `@libs/storage` 落 `storage/<id>.json`——删掉整个
/// [rootDirectory] 就是彻底卸载，不留孤儿行，也不需要 schema 迁移。
class LnReaderManager extends ChangeNotifier {
  LnReaderManager({
    required this.rootDirectory,
    required this.runtime,
    required HttpClient Function() httpClientFactory,
    this.builtinStoreUrl = kLnReaderOfficialStoreUrl,
    this.refreshOnInitialise = false,
    this.cloudflare,
    int Function()? clock,
  }) : _httpClientFactory = httpClientFactory,
       _clock = clock ?? (() => DateTime.now().millisecondsSinceEpoch);

  final Directory rootDirectory;
  final LnReaderRuntime runtime;

  /// 与 [runtime] 的出站桥共用的 Cloudflare 放行状态；页面据此给出「站点验证」。
  /// null = 不支持验证（单测）。
  final LnReaderCloudflare? cloudflare;

  /// 内置仓库地址。生产恒为 [kLnReaderOfficialStoreUrl]；单测指向本地服务器。
  final String builtinStoreUrl;

  /// 初始化后是否立即后台刷新目录。只有真实 app 开（见 AppModel），别改成默认
  /// true——那会让每个构造 manager 的单测都去拉真实网络索引（与
  /// `MihonManager.seedDefaultStore` 同一纪律）。
  final bool refreshOnInitialise;
  final HttpClient Function() _httpClientFactory;
  final int Function() _clock;

  List<LnReaderStore> _stores = const <LnReaderStore>[];
  List<LnReaderRepoPlugin> _available = const <LnReaderRepoPlugin>[];
  List<LnReaderInstalledPlugin> _installed = const <LnReaderInstalledPlugin>[];
  final Set<String> _busy = <String>{};
  bool _loading = false;
  Future<void>? _initialising;
  bool _disposed = false;

  /// 已登记的仓库。
  List<LnReaderStore> get stores => _stores;

  /// 各仓库目录合并后的可装插件（同 id 后面的仓库覆盖前面，与上游 app 同口径）。
  /// 纯内存，进程重启后要刷新仓库才有。
  List<LnReaderRepoPlugin> get available => _available;

  /// 已装插件 = 在线源，按「置顶在前，其余按 sortOrder」排好。
  List<LnReaderInstalledPlugin> get installed => _installed;

  bool get loading => _loading;

  /// 测试直接给目录（widget 测试里 HttpClient 是恒 400 的模拟实现，刷不了仓库）。
  @visibleForTesting
  void debugSetAvailable(List<LnReaderRepoPlugin> plugins) {
    _available = plugins;
    _notify();
  }

  bool isBusy(String pluginId) => _busy.contains(pluginId);

  File get _stateFile => File(p.join(rootDirectory.path, 'state.json'));

  File pluginFile(String pluginId) =>
      File(p.join(rootDirectory.path, 'plugins', '${_safeName(pluginId)}.js'));

  File _storageFile(String pluginId) => File(
    p.join(rootDirectory.path, 'storage', '${_safeName(pluginId)}.json'),
  );

  /// 插件 id 是仓库给的任意字符串；落盘文件名只留安全字符，杜绝 `../`。
  static String _safeName(String id) =>
      id.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_').replaceAll('..', '_');

  /// 读盘；幂等，页面进来就调。随后后台刷新目录（内置官方仓库恒在，所以
  /// 进页就有官方扩展可装）。
  Future<void> initialise() => _initialising ??= _initialise();

  Future<void> _initialise() async {
    await rootDirectory.create(recursive: true);
    final Map<String, Object?> state = await _readState();
    _stores =
        withBuiltinLnReaderStore(builtinUrl: builtinStoreUrl, <LnReaderStore>[
          if (state['stores'] is List)
            for (final Object? raw in state['stores'] as List)
              if (LnReaderStore.tryFromJson(raw) case final LnReaderStore store)
                store,
        ]);
    _installed = _sorted(<LnReaderInstalledPlugin>[
      if (state['installed'] is List)
        for (final Object? raw in state['installed'] as List)
          if (LnReaderInstalledPlugin.tryFromJson(raw)
              case final LnReaderInstalledPlugin plugin)
            plugin,
    ]);
    _notify();
    if (refreshOnInitialise) unawaited(refreshStores());
  }

  /// 内置仓库不可删、不可改（2026-09-25 用户口径：「lnreader 官方扩展也内置」）。
  bool isBuiltinStore(LnReaderStore store) => store.indexUrl == builtinStoreUrl;

  Future<Map<String, Object?>> _readState() async {
    try {
      if (!await _stateFile.exists()) return <String, Object?>{};
      final Object? decoded = jsonDecode(await _stateFile.readAsString());
      return decoded is Map
          ? decoded.map(
              (Object? key, Object? value) =>
                  MapEntry<String, Object?>(key.toString(), value),
            )
          : <String, Object?>{};
    } on Object {
      // 坏文件不该让整个小说源功能进不去；按空状态起，下次写盘覆盖。
      return <String, Object?>{};
    }
  }

  Future<void> _writeState() async {
    await rootDirectory.create(recursive: true);
    await _writeAtomically(
      _stateFile,
      const JsonEncoder.withIndent('  ').convert(<String, Object?>{
        // 内置仓库不落盘：它的地址跟着 app 版本走（上游换 tag 时随版本更新）。
        'stores': <Object?>[
          for (final LnReaderStore store in _stores)
            if (!isBuiltinStore(store)) store.toJson(),
        ],
        'installed': <Object?>[
          for (final LnReaderInstalledPlugin plugin in _installed)
            plugin.toJson(),
        ],
      }),
    );
  }

  /// 每个目标文件一条写入链：同一文件的写按调用顺序串行（审查 B3）。
  ///
  /// 插件连续 `storage.set` 几个键、用户快速连点启用 / 排序，都会并发触发整份
  /// 快照写盘。共用一个 `.part` 时几路写互相覆盖、互相 rename，实测 50 轮里 24 轮
  /// 落下坏 JSON——而读取把坏 JSON 当空状态，结果是所有已装插件、用户仓库或插件
  /// 登录态整份丢失。串行后最后发起的那次写一定最后落盘。
  final Map<String, Future<void>> _writeChains = <String, Future<void>>{};
  int _tempSeq = 0;

  Future<void> _writeAtomically(File target, String contents) {
    final String key = target.path;
    final Future<void> previous = _writeChains[key] ?? Future<void>.value();
    final Future<void> next = () async {
      try {
        await previous;
      } on Object {
        // 前一次写的失败已经交给它自己的调用方；这里只保证顺序，不影响本次写。
      }
      await _writeFile(target, contents);
    }();
    _writeChains[key] = next;
    unawaited(
      next.then<void>((_) {}, onError: (Object _) {}).whenComplete(() {
        if (identical(_writeChains[key], next)) _writeChains.remove(key);
      }),
    );
    return next;
  }

  Future<void> _writeFile(File target, String contents) async {
    await target.parent.create(recursive: true);
    // 串行之外再给临时文件唯一名：即便将来有别的写入口绕过链，也不会互踩。
    final File temp = File('${target.path}.${++_tempSeq}.part');
    try {
      await temp.writeAsString(contents, flush: true);
      await temp.rename(target.path);
    } on Object {
      if (await temp.exists()) await temp.delete();
      rethrow;
    }
  }

  static List<LnReaderInstalledPlugin> _sorted(
    List<LnReaderInstalledPlugin> plugins,
  ) =>
      List<LnReaderInstalledPlugin>.of(plugins)
        ..sort((LnReaderInstalledPlugin a, LnReaderInstalledPlugin b) {
          if (a.pinned != b.pinned) return a.pinned ? -1 : 1;
          final int order = a.sortOrder.compareTo(b.sortOrder);
          return order != 0 ? order : a.name.compareTo(b.name);
        });

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  // ── 仓库 ────────────────────────────────────────────────────────────────

  /// 规范化并校验仓库地址；非 http(s) 返回 null。
  static String? normaliseStoreUrl(String raw) {
    final String value = raw.trim();
    final Uri? uri = Uri.tryParse(value);
    if (uri == null || uri.host.isEmpty) return null;
    if (uri.scheme != 'https' && uri.scheme != 'http') return null;
    return uri.toString();
  }

  Future<void> addStore(String rawUrl) async {
    final String? url = normaliseStoreUrl(rawUrl);
    if (url == null) throw FormatException('Invalid repository URL', rawUrl);
    if (_stores.any((LnReaderStore store) => store.indexUrl == url)) return;
    _stores = <LnReaderStore>[
      ..._stores,
      LnReaderStore(indexUrl: url, name: lnReaderStoreDisplayName(url)),
    ];
    await _writeState();
    _notify();
    await refreshStores();
  }

  Future<void> editStore(LnReaderStore store, String rawUrl) async {
    if (isBuiltinStore(store)) return;
    final String? url = normaliseStoreUrl(rawUrl);
    if (url == null) throw FormatException('Invalid repository URL', rawUrl);
    _stores = <LnReaderStore>[
      for (final LnReaderStore existing in _stores)
        if (existing.indexUrl == store.indexUrl)
          LnReaderStore(indexUrl: url, name: lnReaderStoreDisplayName(url))
        else
          existing,
    ];
    await _writeState();
    _notify();
    await refreshStores();
  }

  Future<void> removeStore(LnReaderStore store) async {
    if (isBuiltinStore(store)) return;
    _stores = <LnReaderStore>[
      for (final LnReaderStore existing in _stores)
        if (existing.indexUrl != store.indexUrl) existing,
    ];
    _available = <LnReaderRepoPlugin>[
      for (final LnReaderRepoPlugin plugin in _available)
        if (plugin.storeUrl != store.indexUrl) plugin,
    ];
    await _writeState();
    _notify();
  }

  /// 重新拉取所有仓库索引。单个仓库失败只记在该仓库上，不影响其它仓库。
  Future<void> refreshStores() async {
    if (_loading) return;
    _loading = true;
    _notify();
    try {
      final List<LnReaderStore> stores = <LnReaderStore>[];
      final List<LnReaderRepoPlugin> merged = <LnReaderRepoPlugin>[];
      for (final LnReaderStore store in _stores) {
        try {
          final List<LnReaderRepoPlugin> plugins = parseLnReaderIndex(
            await _getText(store.indexUrl),
            storeUrl: store.indexUrl,
          );
          merged.addAll(plugins);
          stores.add(store.withError(null));
        } on Object catch (error) {
          stores.add(store.withError('$error'));
        }
      }
      final Map<String, LnReaderRepoPlugin> byId =
          <String, LnReaderRepoPlugin>{};
      for (final LnReaderRepoPlugin plugin in merged) {
        // 已装插件只认它来源仓库的条目：否则任意第三方仓库发一个同 id、版本号
        // 更高的条目就会顶掉它，「全部更新」静默把官方插件换成第三方代码。
        final LnReaderInstalledPlugin? installed = installedById(plugin.id);
        final LnReaderRepoPlugin? kept = byId[plugin.id];
        if (installed != null &&
            kept != null &&
            kept.storeUrl == installed.storeUrl &&
            plugin.storeUrl != installed.storeUrl) {
          continue;
        }
        byId.remove(plugin.id);
        byId[plugin.id] = plugin;
      }
      _stores = stores;
      _available = byId.values.toList(growable: false);
    } finally {
      _loading = false;
      _notify();
    }
  }

  Future<String> _getText(String url) async {
    final HttpClient client = _httpClientFactory();
    try {
      final HttpClientRequest request = await client.getUrl(Uri.parse(url));
      final HttpClientResponse response = await request.close().timeout(
        const Duration(seconds: 30),
      );
      final String body = await response
          .transform(utf8.decoder)
          .join()
          .timeout(const Duration(seconds: 60));
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw HttpException('HTTP ${response.statusCode}', uri: Uri.parse(url));
      }
      return body;
    } finally {
      client.close(force: true);
    }
  }

  // ── 安装 ────────────────────────────────────────────────────────────────

  LnReaderInstalledPlugin? installedById(String pluginId) {
    for (final LnReaderInstalledPlugin plugin in _installed) {
      if (plugin.id == pluginId) return plugin;
    }
    return null;
  }

  /// 目录里的版本比已装的新，且来自已装插件的来源仓库——别的仓库里同 id 的
  /// 条目不是它的更新（插件没有签名，来源仓库是唯一的身份绑定）。
  bool hasUpdate(LnReaderRepoPlugin plugin) {
    final LnReaderInstalledPlugin? installed = installedById(plugin.id);
    return installed != null &&
        plugin.storeUrl == installed.storeUrl &&
        compareLnReaderVersions(plugin.version, installed.version) > 0;
  }

  /// 安装或更新：下载 JS → 原子落盘 → 登记（保留已有的启停 / 排序 / 置顶）。
  Future<void> install(LnReaderRepoPlugin plugin) async {
    if (!_busy.add(plugin.id)) return;
    _notify();
    try {
      final String code = await _getText(plugin.url);
      if (!code.contains('exports')) {
        throw FormatException('Not an LNReader plugin', plugin.url);
      }
      await _writeAtomically(pluginFile(plugin.id), code);
      final LnReaderInstalledPlugin? existing = installedById(plugin.id);
      final int nextOrder = _installed.isEmpty
          ? 0
          : _installed
                    .map((LnReaderInstalledPlugin e) => e.sortOrder)
                    .reduce((int a, int b) => a > b ? a : b) +
                1;
      _installed = _sorted(<LnReaderInstalledPlugin>[
        for (final LnReaderInstalledPlugin other in _installed)
          if (other.id != plugin.id) other,
        existing?.copyWith(metadata: plugin) ??
            LnReaderInstalledPlugin.fromRepo(
              plugin,
              sortOrder: nextOrder,
              installedAt: _clock(),
            ),
      ]);
      await _writeState();
      await runtime.forget(plugin.id);
    } finally {
      _busy.remove(plugin.id);
      _notify();
    }
  }

  Future<void> uninstall(LnReaderInstalledPlugin plugin) async {
    _installed = <LnReaderInstalledPlugin>[
      for (final LnReaderInstalledPlugin other in _installed)
        if (other.id != plugin.id) other,
    ];
    await _writeState();
    _notify();
    await runtime.forget(plugin.id);
    for (final File file in <File>[
      pluginFile(plugin.id),
      _storageFile(plugin.id),
    ]) {
      if (await file.exists()) await file.delete();
    }
  }

  Future<void> setEnabled(LnReaderInstalledPlugin plugin, bool enabled) =>
      _update(
        plugin.id,
        (LnReaderInstalledPlugin p) => p.copyWith(enabled: enabled),
      );

  Future<void> setPinned(LnReaderInstalledPlugin plugin, bool pinned) =>
      _update(
        plugin.id,
        (LnReaderInstalledPlugin p) => p.copyWith(pinned: pinned),
      );

  /// 与相邻源交换位置（[delta] = -1 上移 / +1 下移）。
  Future<void> move(LnReaderInstalledPlugin plugin, int delta) async {
    final int index = _installed.indexWhere(
      (LnReaderInstalledPlugin e) => e.id == plugin.id,
    );
    final int target = index + delta;
    if (index < 0 || target < 0 || target >= _installed.length) return;
    final List<LnReaderInstalledPlugin> reordered =
        List<LnReaderInstalledPlugin>.of(_installed);
    final LnReaderInstalledPlugin moved = reordered.removeAt(index);
    reordered.insert(target, moved);
    // 置顶组与普通组各自连续编号，交换跨组时仍按置顶优先排。
    _installed = _sorted(<LnReaderInstalledPlugin>[
      for (int i = 0; i < reordered.length; i++)
        reordered[i].copyWith(sortOrder: i),
    ]);
    await _writeState();
    _notify();
  }

  /// 清掉插件的 `@libs/storage`（登录态 / 缓存的 token 等），并让运行时重新装载。
  Future<void> clearData(LnReaderInstalledPlugin plugin) async {
    final File file = _storageFile(plugin.id);
    if (await file.exists()) await file.delete();
    await runtime.forget(plugin.id);
  }

  Future<void> _update(
    String pluginId,
    LnReaderInstalledPlugin Function(LnReaderInstalledPlugin plugin) change,
  ) async {
    _installed = _sorted(<LnReaderInstalledPlugin>[
      for (final LnReaderInstalledPlugin plugin in _installed)
        if (plugin.id == pluginId) change(plugin) else plugin,
    ]);
    await _writeState();
    _notify();
  }

  // ── 运行时接线 ──────────────────────────────────────────────────────────

  /// 装载已安装插件，返回其元数据（筛选器 / 封面请求头等）。
  Future<LnReaderPluginInfo> load(LnReaderInstalledPlugin plugin) =>
      runtime.ensureLoaded(plugin.id, () async {
        final File file = pluginFile(plugin.id);
        if (!await file.exists()) {
          throw LnReaderPluginException('Plugin file missing: ${plugin.id}');
        }
        return (
          code: await file.readAsString(),
          storage: await _readStorage(plugin.id),
        );
      });

  Future<Map<String, Object?>> _readStorage(String pluginId) async {
    try {
      final File file = _storageFile(pluginId);
      if (!await file.exists()) return <String, Object?>{};
      final Object? decoded = jsonDecode(await file.readAsString());
      return decoded is Map
          ? decoded.map(
              (Object? key, Object? value) =>
                  MapEntry<String, Object?>(key.toString(), value),
            )
          : <String, Object?>{};
    } on Object {
      return <String, Object?>{};
    }
  }

  /// 运行时回调：插件写了 `@libs/storage`。
  Future<void> persistStorage(
    String pluginId,
    Map<String, Object?> data,
  ) async {
    await _writeAtomically(_storageFile(pluginId), jsonEncode(data));
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(runtime.dispose());
    super.dispose();
  }
}

/// 解析仓库索引（`plugins.min.json`：顶层数组）。不是数组直接抛——那不是
/// LNReader 仓库（最常见：填成了仓库主页地址）。
List<LnReaderRepoPlugin> parseLnReaderIndex(
  String body, {
  required String storeUrl,
}) {
  final Object? decoded = jsonDecode(body);
  if (decoded is! List) {
    throw const FormatException('Not an LNReader plugin index');
  }
  return <LnReaderRepoPlugin>[
    for (final Object? raw in decoded)
      if (LnReaderRepoPlugin.tryParse(raw, storeUrl: storeUrl)
          case final LnReaderRepoPlugin plugin)
        plugin,
  ];
}

/// 按点分数字段比较版本号（`1.10.0` > `1.9.3`）；非数字段按字符串比。
int compareLnReaderVersions(String a, String b) {
  final List<String> left = a.split('.');
  final List<String> right = b.split('.');
  final int length = left.length > right.length ? left.length : right.length;
  for (int i = 0; i < length; i++) {
    final String x = i < left.length ? left[i] : '0';
    final String y = i < right.length ? right[i] : '0';
    final int? nx = int.tryParse(x);
    final int? ny = int.tryParse(y);
    final int result = nx != null && ny != null
        ? nx.compareTo(ny)
        : x.compareTo(y);
    if (result != 0) return result;
  }
  return 0;
}
