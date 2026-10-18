import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'adblock_filter_list_service.dart';
import 'fushi_adblock_engine.dart';
import 'fushi_adblock_library.dart';

/// [AdblockEngineLoader.load] 的产物。
class AdblockEngineBundle {
  const AdblockEngineBundle({
    required this.engine,
    required this.lists,
    required this.fromEngineCache,
    this.contentBlockingRules,
  });

  /// 已就绪的引擎（调用方负责 dispose）。
  final FushiAdblockEngine engine;

  /// 每份列表这次的来源 / 错误。
  final List<AdblockListLoadResult> lists;

  /// true = 引擎直接从磁盘序列化缓存恢复（没有重新编译）。
  final bool fromEngineCache;

  /// 只在 `withContentBlockingRules: true` 时给出：WebKit 内容拦截规则。
  final List<Map<String, Object?>>? contentBlockingRules;
}

/// 过滤列表 → 引擎的装配：列表走 [AdblockFilterListService]（下载 / 缓存 / 过期），
/// 编译在后台 isolate 里做，结果序列化落盘（`<cacheDir>/engine/<key>.dat`），列表内容与
/// 原生库版本不变时下次直接反序列化，不再编译。
class AdblockEngineLoader {
  AdblockEngineLoader({required this.listService, FushiAdblockLibrary? library})
    : _library = library;

  final AdblockFilterListService listService;
  final FushiAdblockLibrary? _library;

  FushiAdblockLibrary? get _lib => _library ?? FushiAdblockLibrary.instance;

  Directory get _engineDir =>
      Directory('${listService.cacheDir.path}${Platform.pathSeparator}engine');

  /// 原生库是否可用（不可用时 [load] 返回 null）。
  bool get isAvailable => _lib != null;

  /// 加载 [lists] 并得到引擎。原生库不可用 / 所有列表都缺席时返回 null；不抛。
  Future<AdblockEngineBundle?> load(
    List<AdblockFilterList> lists, {
    bool forceRefresh = false,
    bool withContentBlockingRules = false,
  }) async {
    final FushiAdblockLibrary? lib = _lib;
    if (lib == null) return null;
    final List<AdblockListLoadResult> results = await listService.loadLists(
      lists,
      force: forceRefresh,
    );
    final List<AdblockListLoadResult> present = results
        .where((AdblockListLoadResult r) => r.text != null)
        .toList(growable: false);
    if (present.isEmpty) return null;

    final String key = engineCacheKey(lib.version(), present);
    final File engineFile = File(
      '${_engineDir.path}${Platform.pathSeparator}$key.dat',
    );
    final File rulesFile = File(
      '${_engineDir.path}${Platform.pathSeparator}$key.cb.json',
    );

    FushiAdblockEngine? engine;
    bool fromCache = false;
    if (engineFile.existsSync()) {
      try {
        engine = FushiAdblockEngine.deserialize(
          await engineFile.readAsBytes(),
          library: lib,
        );
        fromCache = true;
      } on AdblockEngineException {
        engine = null; // 格式变了 / 损坏：删掉重编。
        await _tryDelete(engineFile);
      }
    }

    final List<String> texts = present
        .map((AdblockListLoadResult r) => r.text!)
        .toList(growable: false);
    if (engine == null) {
      final Uint8List bytes = await compileInBackground(
        texts,
        libraryPath: lib.libraryPath,
      );
      engine = FushiAdblockEngine.deserialize(bytes, library: lib);
      await _engineDir.create(recursive: true);
      await _writeAtomic(engineFile, bytes);
      await _prune(keep: key);
    }

    List<Map<String, Object?>>? rules;
    if (withContentBlockingRules) {
      rules = await _readRules(rulesFile);
      if (rules == null) {
        rules = await contentBlockingRulesInBackground(
          texts,
          libraryPath: lib.libraryPath,
        );
        await _engineDir.create(recursive: true);
        await _writeAtomic(rulesFile, utf8.encode(jsonEncode(rules)));
      }
    }

    return AdblockEngineBundle(
      engine: engine,
      lists: results,
      fromEngineCache: fromCache,
      contentBlockingRules: rules,
    );
  }

  /// 在后台 isolate 编译并序列化（大列表编译几百毫秒，不能卡 UI isolate）。
  static Future<Uint8List> compileInBackground(
    List<String> texts, {
    String? libraryPath,
  }) {
    return Isolate.run<Uint8List>(() {
      final FushiAdblockLibrary? lib = FushiAdblockLibrary.tryLoad(
        libraryPath: libraryPath,
      );
      if (lib == null) {
        throw StateError('fushi_adblock native library is not available');
      }
      final FushiAdblockEngine engine = FushiAdblockEngine.load(
        texts,
        library: lib,
      );
      try {
        return engine.serialize();
      } finally {
        engine.dispose();
      }
    });
  }

  /// 在后台 isolate 里把列表转成 WebKit 内容拦截规则。
  static Future<List<Map<String, Object?>>> contentBlockingRulesInBackground(
    List<String> texts, {
    String? libraryPath,
  }) {
    return Isolate.run<List<Map<String, Object?>>>(() {
      final FushiAdblockLibrary? lib = FushiAdblockLibrary.tryLoad(
        libraryPath: libraryPath,
      );
      if (lib == null) {
        throw StateError('fushi_adblock native library is not available');
      }
      return FushiAdblockEngine.contentBlockingRules(texts, library: lib);
    });
  }

  /// 缓存键：原生库版本 + 每份列表的 id / 长度 / 内容哈希（FNV-1a 32）。列表内容或
  /// adblock-rust 版本（序列化格式不保证跨版本兼容）任一变化即换键重编。
  static String engineCacheKey(
    String nativeVersion,
    List<AdblockListLoadResult> present,
  ) {
    final StringBuffer sb = StringBuffer('v$nativeVersion');
    for (final AdblockListLoadResult r in present) {
      final String text = r.text ?? '';
      sb
        ..write('|')
        ..write(r.list.id)
        ..write(':')
        ..write(text.length)
        ..write(':')
        ..write(_fnv1a32(text).toRadixString(16));
    }
    return _fnv1a32(sb.toString()).toRadixString(16).padLeft(8, '0');
  }

  static int _fnv1a32(String s) {
    int hash = 0x811c9dc5;
    for (int i = 0; i < s.length; i++) {
      hash ^= s.codeUnitAt(i);
      hash = (hash * 0x01000193) & 0xffffffff;
    }
    return hash;
  }

  Future<List<Map<String, Object?>>?> _readRules(File f) async {
    if (!f.existsSync()) return null;
    try {
      final Object? decoded = jsonDecode(await f.readAsString());
      if (decoded is! List) return null;
      return decoded.whereType<Map<String, Object?>>().toList(growable: false);
    } on FormatException {
      return null;
    } on FileSystemException {
      return null;
    }
  }

  Future<void> _prune({required String keep}) async {
    if (!_engineDir.existsSync()) return;
    // listSync 而不是 await for(list())：后者在 widget 测试的 fake-async 区里收不到完成事件。
    for (final FileSystemEntity e in _engineDir.listSync()) {
      if (e is! File) continue;
      final String name = e.uri.pathSegments.last;
      if (!name.startsWith('$keep.')) await _tryDelete(e);
    }
  }

  static Future<void> _tryDelete(File f) async {
    try {
      if (f.existsSync()) await f.delete();
    } on FileSystemException {
      // 被占用等：下次再清。
    }
  }

  static Future<void> _writeAtomic(File target, List<int> bytes) async {
    await target.parent.create(recursive: true);
    final File tmp = File('${target.path}.tmp');
    await tmp.writeAsBytes(bytes, flush: true);
    if (target.existsSync()) await target.delete();
    await tmp.rename(target.path);
  }
}
