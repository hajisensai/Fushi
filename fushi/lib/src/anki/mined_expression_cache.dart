import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:fushi_anki/fushi_anki.dart';
import 'package:path_provider/path_provider.dart';

import 'package:fushi/src/anki/anki_backup_word_reader.dart'
    show ankiFirstFieldKey;
import 'package:fushi/src/anki/delegating_anki_repository.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';

/// 反馈 JAEwvc6Lmr：离线已制卡缓存——Anki 里**已有**的词（按查重作用域分份）的本地副本。
///
/// 查词弹窗的 ✓ 原本完全来自每次实时问 Anki（AnkiDroid `checkForDuplicates` /
/// AnkiConnect `canAddNotesWithErrorDetail`），Anki 一连不上（AnkiDroid 后台进程被杀、
/// collection 打不开、AnkiConnect 没开），`isDuplicate` 就折成 `false`，所有 ✓ 消失；
/// 批量制卡的用户恰恰常在 Anki 不可达时查词。
///
/// 真值仍然是 Anki：本缓存只在**没问到**（[BaseAnkiRepository.probeDuplicate] 回
/// `null`）时才回答。问到了就用答案刷新对应条目；同一进程内某作用域第一次问到时，
/// 后台把整个作用域的第一字段整份拉回来替换（[BaseAnkiRepository.listMinedFirstFields]），
/// 补上「别处加的、以前加的、在 Anki 里删掉的」。
///
/// 匹配口径：两边都过 [ankiFirstFieldKey]（去 HTML 标签、解实体、trim），与 Anki 判重
/// 比较「去掉 HTML 的第一字段」一致；查词词头本是纯文本，过一遍不变。
///
/// 持久化：应用支持目录下每个作用域一份 JSON（`{scope, entries}`，文件名是作用域的
/// SHA-1）。词表动辄上万条，不进 SharedPreferences / Drift；读坏了按空表处理
/// （最坏是离线时少画 ✓，方向安全）。
class MinedExpressionCache {
  MinedExpressionCache({Future<Directory> Function()? directory})
    : _directory = directory ?? _defaultDirectory;

  static final MinedExpressionCache instance = MinedExpressionCache();

  /// 应用支持目录下的子目录名。
  static const String directoryName = 'anki_mined_expression_cache';

  static Future<Directory> _defaultDirectory() async {
    final Directory support = await getApplicationSupportDirectory();
    return Directory('${support.path}/$directoryName');
  }

  final Future<Directory> Function() _directory;

  /// 作用域 → 内存词表（已载入的）。
  final Map<String, Set<String>> _entries = <String, Set<String>>{};
  final Map<String, Future<Set<String>>> _loading =
      <String, Future<Set<String>>>{};

  /// 整份刷新进行中的作用域 → 刷新期间收到的实时答案。快照是刷新开始那一刻的
  /// Anki，这期间新制的卡 / 新问到的答案要叠回快照上，否则会被快照冲掉。
  final Map<String, Map<String, bool>> _liveDuringRefresh =
      <String, Map<String, bool>>{};

  /// 本进程里已经发起过整份刷新的作用域：每个作用域每次启动只整份刷新一次。
  final Set<String> _refreshClaimed = <String>{};

  /// 写盘串行化：同一文件的「写临时文件 → 改名」不能交错。
  Future<void> _writeTail = Future<void>.value();

  /// 缓存的判重键；空串 = 不参与缓存。
  static String keyOf(String expression) => ankiFirstFieldKey(expression);

  /// [scope] 的缓存里有没有这个词（离线时回答「已制卡」）。
  Future<bool> contains(String scope, String expression) async {
    final String key = keyOf(expression);
    if (key.isEmpty) return false;
    return (await _load(scope)).contains(key);
  }

  /// [scope] 的缓存条数（诊断与测试）。
  Future<int> count(String scope) async => (await _load(scope)).length;

  /// Anki 明确应答了 [expression] 在不在（[mined]），让缓存跟上。
  Future<void> recordAnswer(String scope, String expression, bool mined) async {
    final String key = keyOf(expression);
    if (key.isEmpty) return;
    await _load(scope);
    // 等载入期间 [completeRefresh] 可能已把词表整份换掉：必须改**当前**那份，
    // 而不是 await 之前拿到的旧引用，否则这条答案会落进被丢弃的旧集合里丢失。
    final Set<String> entries = _entries[scope]!;
    _liveDuringRefresh[scope]?[key] = mined;
    final bool changed = mined ? entries.add(key) : entries.remove(key);
    if (changed) await _persist(scope, entries);
  }

  /// 本进程第一次为 [scope] 申请整份刷新时返回 `true`（之后恒 `false`）。
  bool claimRefresh(String scope) => _refreshClaimed.add(scope);

  /// 开始整份刷新：从此刻起的实时答案会被记下，等快照到了叠回去。
  void beginRefresh(String scope) {
    _liveDuringRefresh[scope] = <String, bool>{};
  }

  /// 放弃这次整份刷新（后端不支持、作用域中途变了、拉取失败）。缓存保持原样。
  void abortRefresh(String scope) {
    _liveDuringRefresh.remove(scope);
  }

  /// 用 Anki 的整份第一字段替换 [scope] 的缓存，再叠上刷新期间收到的实时答案。
  /// 返回替换后的条数。写盘失败照抛：调用方据此记错误日志，而不是以为刷新成功了。
  Future<int> completeRefresh(
    String scope,
    Iterable<String> firstFields,
  ) async {
    // 先载入、再同步地「收走实时答案 → 换词表」：两步之间不能有 await，否则这段空隙里
    // 到达的实时答案既不在 live 里、也会写进马上被替换掉的旧词表，直接丢失。
    await _load(scope);
    final Map<String, bool> live =
        _liveDuringRefresh.remove(scope) ?? const <String, bool>{};
    final Set<String> next = <String>{};
    for (final String field in firstFields) {
      final String key = keyOf(field);
      if (key.isNotEmpty) next.add(key);
    }
    live.forEach((String key, bool mined) {
      if (mined) {
        next.add(key);
      } else {
        next.remove(key);
      }
    });
    _entries[scope] = next;
    await _persist(scope, next, throwOnFailure: true);
    return next.length;
  }

  /// 丢掉内存状态，下次访问重新从磁盘读（测试用：单例跨用例复用）。
  @visibleForTesting
  void resetForTesting() {
    _entries.clear();
    _loading.clear();
    _liveDuringRefresh.clear();
    _refreshClaimed.clear();
  }

  Future<Set<String>> _load(String scope) {
    final Set<String>? loaded = _entries[scope];
    if (loaded != null) return Future<Set<String>>.value(loaded);
    return _loading.putIfAbsent(scope, () async {
      final Set<String> entries = await _read(scope);
      // 读盘期间 completeRefresh 可能已经放进了更新的词表。
      return _entries.putIfAbsent(scope, () => entries);
    });
  }

  Future<File> _fileFor(String scope) async {
    final Directory dir = await _directory();
    final String name = sha1.convert(utf8.encode(scope)).toString();
    return File('${dir.path}/$name.json');
  }

  /// 读不到 / 读坏了 / 文件名撞了别的作用域，一律按空表（见类注释）。
  Future<Set<String>> _read(String scope) async {
    try {
      final File file = await _fileFor(scope);
      if (!await file.exists()) return <String>{};
      final Object? json = jsonDecode(await file.readAsString());
      if (json is! Map || json['scope'] != scope) return <String>{};
      final Object? list = json['entries'];
      if (list is! List) return <String>{};
      return <String>{
        for (final Object? item in list)
          if (item is String && item.isNotEmpty) item,
      };
    } catch (e, stack) {
      ErrorLogService.instance.log('MinedExpressionCache.read', e, stack);
      return <String>{};
    }
  }

  /// 先写临时文件再改名：写到一半被杀时旧文件还在。
  Future<void> _persist(
    String scope,
    Set<String> entries, {
    bool throwOnFailure = false,
  }) {
    final String payload = jsonEncode(<String, Object>{
      'scope': scope,
      'entries': entries.toList(),
    });
    final Completer<void> done = Completer<void>();
    _writeTail = _writeTail.then((_) async {
      try {
        final File file = await _fileFor(scope);
        await file.parent.create(recursive: true);
        final File tmp = File('${file.path}.tmp');
        await tmp.writeAsString(payload, flush: true);
        await tmp.rename(file.path);
        done.complete();
      } catch (e, stack) {
        // 内存词表已经更新，本次会话照常回答；只是下次启动可能还是旧的。
        ErrorLogService.instance.log('MinedExpressionCache.persist', e, stack);
        if (throwOnFailure) {
          done.completeError(e, stack);
        } else {
          done.complete();
        }
      }
    });
    return done.future;
  }
}

/// 把离线已制卡缓存接进制卡链路的装饰器（包在本机后端**最里层**，待发队列补发进
/// Anki 的卡也经过它落账）。
///
/// * [isDuplicate] = [probeDuplicate] 折成 bool（没问到、缓存也没有 → `false`）。
/// * [probeDuplicate]：后端问到了 → 用答案刷新缓存，并在本进程第一次问到时后台整份
///   刷新该作用域；没问到 → 用缓存回答。后端不做缓存（[minedCacheScope] 为 `null`，
///   如 AnkiMobile / 未配置笔记类型）时原样透传。
/// * [mineEntry]：Anki 确认进库（成功 / 判重复）就记进缓存；每张卡都切 app 的后端
///   （AnkiMobile）「成功」只代表拉起了 app，不记。
class MinedExpressionCacheAnkiRepository extends DelegatingAnkiRepository {
  MinedExpressionCacheAnkiRepository({
    required super.inner,
    MinedExpressionCache? cache,
  }) : _cache = cache ?? MinedExpressionCache.instance;

  final MinedExpressionCache _cache;

  /// 最近一次后台整份刷新（测试用：等它跑完再断言）。
  @visibleForTesting
  Future<void>? lastRefresh;

  @override
  Future<bool> isDuplicate(String expression, String reading) async =>
      (await probeDuplicate(expression, reading)) ?? false;

  @override
  Future<bool?> probeDuplicate(String expression, String reading) async {
    final bool? live = await inner.probeDuplicate(expression, reading);
    final String? scope = await inner.minedCacheScope();
    if (scope == null) return live;
    if (live == null) {
      // 没问到也不能硬答 `false`：缓存里有就画 ✓，没有就保持「没问到」。
      return await _cache.contains(scope, expression) ? true : null;
    }
    await _cache.recordAnswer(scope, expression, live);
    if (_cache.claimRefresh(scope)) {
      final Future<void> refresh = _refresh(scope);
      lastRefresh = refresh;
      unawaited(refresh);
    }
    return live;
  }

  @override
  Future<MineOutcome> mineEntry({
    required String rawPayloadJson,
    required AnkiMiningContext context,
  }) async {
    final MineOutcome outcome = await inner.mineEntry(
      rawPayloadJson: rawPayloadJson,
      context: context,
    );
    final bool inAnki =
        outcome.result == MineResult.success ||
        outcome.result == MineResult.duplicate;
    if (inAnki && !inner.switchesAppPerNote) {
      final String expression = _expressionOf(rawPayloadJson);
      final String? scope = await inner.minedCacheScope();
      if (scope != null && expression.isNotEmpty) {
        await _cache.recordAnswer(scope, expression, true);
      }
    }
    return outcome;
  }

  /// 后台整份刷新。永不抛：失败进错误日志、缓存保持原样（之前的词表仍可离线回答）。
  Future<void> _refresh(String scope) async {
    _cache.beginRefresh(scope);
    try {
      final List<String>? fields = await inner.listMinedFirstFields();
      // 拉取期间用户换了笔记类型 / 卡组 / 连接：这份快照属于旧作用域，不能写进去。
      if (fields == null || await inner.minedCacheScope() != scope) {
        _cache.abortRefresh(scope);
        return;
      }
      await _cache.completeRefresh(scope, fields);
    } catch (e, stack) {
      _cache.abortRefresh(scope);
      ErrorLogService.instance.log(
        'MinedExpressionCacheAnkiRepository.refresh',
        e,
        stack,
      );
    }
  }

  /// 制卡载荷里的词头（与查词时问 [isDuplicate] 的是同一个词）。
  static String _expressionOf(String rawPayloadJson) {
    try {
      final Object? json = jsonDecode(rawPayloadJson);
      if (json is Map) {
        final Object? expression = json['expression'];
        if (expression is String) return expression.trim();
      }
    } on FormatException {
      return '';
    }
    return '';
  }
}
