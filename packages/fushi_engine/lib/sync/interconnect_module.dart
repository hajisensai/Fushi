/// 互联 host 的声明式端点表（设计 docs/specs/2026-11-23-interconnect-music-library-design.md §3.5，拍板
/// design-imusic-q0 选 a；架构重构 A1，docs/specs/2026-11-28-architecture-redesign.md）。
///
/// 以前给互联加一类功能要同时改三张手写表：服务器 `_handleRequest` 里的路径分支、`/api/capabilities` 里
/// 手拼的一行、免 Basic 的 `_kPublicRoutes`——漏一处就是 404 / 能力位撒谎 / 401。现在**一个功能 = 一个
/// [InterconnectHostModule]**：它声明自己的端点（[InterconnectRoute]：方法集、路径模式、信任级、handler）
/// 与能力位（[InterconnectCapability]）。[FushiSyncServer] 只对 [InterconnectModuleTable] 做三个循环：
/// 鉴权中间件按命中路由的 [InterconnectRoute.trust] 判豁免，分发按表找 handler，能力文档按表拼。
/// 表里没有的路径才落进 WebDAV 文件树（最后的兜底，不在表里、不参与冲突检测）。
library;

import 'dart:async';

import 'package:fushi_engine/sync/library_media_streams.dart';
import 'package:shelf/shelf.dart' as shelf;

/// 一个互联 host 功能。
///
/// 「此刻不提供」由能力值回 null 表达（能力位里不出现这个键），路由照样归本模块，由 handler 自己回 404——
/// 功能关着时它的路径仍被占住，不会掉进 WebDAV 文件树。
///
/// [routes] 与 [capabilities] 在 [InterconnectModuleTable] 构造时各读一次并校验；之后不再重读。
abstract class InterconnectHostModule {
  /// 模块名（只用于冲突报错与诊断，不上线）。
  String get name;

  /// 本模块的端点，按声明顺序匹配：同一模块里可以先写窄的（如免 Basic 的取流子路径）再写宽的子树。
  /// 不同模块的路径模式不得相交（[InterconnectModuleTable] 构造时就报错）。
  List<InterconnectRoute> get routes;

  /// 本模块写进 `/api/capabilities` 的能力位，按声明顺序。
  List<InterconnectCapability> get capabilities =>
      const <InterconnectCapability>[];

  /// 本模块经 [LibraryMediaStreams] 签发的流种类，以及「请求 → 字节来源」的解析器。服务器启动时逐个注册；
  /// 没有流的模块为空。
  Map<LibraryMediaStreamKind, LibraryMediaResolver> get streamResolvers =>
      const <LibraryMediaStreamKind, LibraryMediaResolver>{};

  /// host 停机时调用（中止在跑的任务等）。默认什么也不做。
  Future<void> dispose() async {}
}

/// 端点 handler：拿到的请求已按路由的 [InterconnectTrust] 放行。
typedef InterconnectHandler =
    Future<shelf.Response> Function(InterconnectRequest request);

/// 一条端点：方法集 × 路径模式 × 信任级 × handler。
final class InterconnectRoute {
  InterconnectRoute(
    this.path, {
    Set<String>? methods,
    required this.trust,
    required this.handler,
  }) : methods = methods == null ? null : Set<String>.unmodifiable(methods) {
    final Set<String>? m = this.methods;
    if (m != null) {
      if (m.isEmpty) {
        throw ArgumentError('互联路由的方法集不能为空（不限方法用 null）：$path');
      }
      for (final String verb in m) {
        if (verb != verb.toUpperCase()) {
          throw ArgumentError('互联路由的方法须大写：$verb（$path）');
        }
      }
    }
  }

  final InterconnectPath path;

  /// 受理的方法（大写）；null = 不限，handler 自己分方法。路径命中、方法不在集里时：不带凭据照常要 Basic，
  /// 带了凭据回 405。
  final Set<String>? methods;

  final InterconnectTrust trust;
  final InterconnectHandler handler;

  bool accepts(String upperMethod) => methods?.contains(upperMethod) ?? true;
}

/// 路由的路径模式。路径一律是规范化路径（带前导 `/`、已解码）。
sealed class InterconnectPath {
  const InterconnectPath();

  /// 只匹配 [path] 本身。
  const factory InterconnectPath.exact(String path) = InterconnectExactPath;

  /// [prefix] 本身及其下（`prefix/…`）。[prefix] 不以 `/` 结尾。
  const factory InterconnectPath.subtree(String prefix) =
      InterconnectSubtreePath;

  /// 以 [prefix] 开头的路径（[prefix] 以 `/` 结尾，所以 `prefix` 去掉尾 `/` 的那条路径**不**归它——
  /// 它照旧落进 WebDAV 树）。
  const factory InterconnectPath.under(String prefix) = InterconnectUnderPath;

  /// [within] 子树里满足 [test] 的路径（如「视频 id 后跟 `/stream`」）。冲突检测按整棵 [within] 子树算。
  const factory InterconnectPath.where(
    String within,
    bool Function(String path) test,
  ) = InterconnectWherePath;

  bool matches(String path);

  /// 本模式可能匹配的路径都落在这棵子树里（冲突检测用）；只匹配单条路径的模式为 null。
  String? get region;

  void _validate();
}

final class InterconnectExactPath extends InterconnectPath {
  const InterconnectExactPath(this.path);

  final String path;

  @override
  bool matches(String candidate) => candidate == path;

  @override
  String? get region => null;

  @override
  void _validate() {
    if (!path.startsWith('/') || (path.length > 1 && path.endsWith('/'))) {
      throw ArgumentError('互联路由路径须以 / 开头、不以 / 结尾：$path');
    }
  }

  @override
  String toString() => path;
}

final class InterconnectSubtreePath extends InterconnectPath {
  const InterconnectSubtreePath(this.prefix);

  final String prefix;

  @override
  bool matches(String candidate) => interconnectPathUnder(candidate, prefix);

  @override
  String get region => prefix;

  @override
  void _validate() {
    if (!prefix.startsWith('/') || prefix.endsWith('/')) {
      throw ArgumentError('互联路由前缀须以 / 开头、不以 / 结尾：$prefix');
    }
  }

  @override
  String toString() => '$prefix/**';
}

final class InterconnectUnderPath extends InterconnectPath {
  const InterconnectUnderPath(this.prefix);

  final String prefix;

  @override
  bool matches(String candidate) => candidate.startsWith(prefix);

  @override
  String get region => prefix.substring(0, prefix.length - 1);

  @override
  void _validate() {
    if (!prefix.startsWith('/') || !prefix.endsWith('/') || prefix == '/') {
      throw ArgumentError('互联路由的 under 前缀须以 / 开头并以 / 结尾：$prefix');
    }
  }

  @override
  String toString() => '$prefix*';
}

final class InterconnectWherePath extends InterconnectPath {
  const InterconnectWherePath(this.within, this.test);

  final String within;
  final bool Function(String path) test;

  @override
  bool matches(String candidate) =>
      interconnectPathUnder(candidate, within) && test(candidate);

  @override
  String get region => within;

  @override
  void _validate() {
    if (!within.startsWith('/') || within.endsWith('/')) {
      throw ArgumentError('互联路由的 where 子树须以 / 开头、不以 / 结尾：$within');
    }
  }

  @override
  String toString() => '$within/**?';
}

/// 两个模式会不会匹配到同一条路径（跨模块冲突检测；保守：子树相交即算）。
bool _pathsOverlap(InterconnectPath a, InterconnectPath b) {
  if (a is InterconnectExactPath) return b.matches(a.path);
  if (b is InterconnectExactPath) return a.matches(b.path);
  final String ra = a.region!;
  final String rb = b.region!;
  return interconnectPathUnder(ra, rb) || interconnectPathUnder(rb, ra);
}

/// 路由的信任级：鉴权中间件据此决定这条请求要不要先过 Basic。
///
/// 只有 [InterconnectTrust.credential] 要求 Basic；其余几种都是「不带 Authorization 也能进 handler」的面，
/// 各自写明门在哪里——新开一个免 Basic 的面必须选一种并给出它的门，写不出「随便放行」。
sealed class InterconnectTrust {
  const InterconnectTrust();

  /// 要求任一有效 Basic 凭据（host 共享 token / 已配对设备 / legacy 行）。更严的门（「仅已配对设备」
  /// 「仅我的设备」「必须 HTTPS」）目前仍由 handler 按各自的顺序判（统一判门是下一阶段 A2）。
  static const InterconnectTrust credential = InterconnectCredentialTrust._();

  /// 配对引导：client 还没有凭据，这正是它在取的东西。门是 handler 里的配对窗口 / PIN proof + host 人工确认。
  static const InterconnectTrust pairingBootstrap =
      InterconnectPairingBootstrapTrust._();

  /// 无凭据的只读可达性探测（配对前确认地址、取指纹做 TOFU）。handler 只许回公开信息。
  static const InterconnectTrust reachabilityProbe = InterconnectProbeTrust._();

  /// 播放器 / libmpv / 网页拿裸 URL 取的面：门是 URL 里的短时票据，由 handler 校验（[ticket] 写明是哪种票）。
  const factory InterconnectTrust.urlTicket(String ticket) =
      InterconnectUrlTicketTrust;

  /// query 里带有效凭据（[validate] 为真）就免 Basic，否则照常要 Basic。
  const factory InterconnectTrust.queryTicketOrCredential(
    Future<bool> Function(shelf.Request request) validate,
  ) = InterconnectQueryTicketTrust;
}

final class InterconnectCredentialTrust extends InterconnectTrust {
  const InterconnectCredentialTrust._();
}

final class InterconnectPairingBootstrapTrust extends InterconnectTrust {
  const InterconnectPairingBootstrapTrust._();
}

final class InterconnectProbeTrust extends InterconnectTrust {
  const InterconnectProbeTrust._();
}

final class InterconnectUrlTicketTrust extends InterconnectTrust {
  const InterconnectUrlTicketTrust(this.ticket);

  /// 校验的是哪种票据（流 token、原盘会话 token、查词音频 id……）。
  final String ticket;
}

final class InterconnectQueryTicketTrust extends InterconnectTrust {
  const InterconnectQueryTicketTrust(this.validate);

  final Future<bool> Function(shelf.Request request) validate;
}

/// `/api/capabilities` 里的一个能力位。值每次请求现算；null = 此刻不提供（键不出现）——与回 `false`
/// 是两种不同的线上形态，按键原样保留。
final class InterconnectCapability {
  /// 顶层键。
  const InterconnectCapability(this.key, this.value) : group = null;

  /// [group] 分组（如 `liveLibrary`）里的一个键。
  const InterconnectCapability.member(
    InterconnectCapabilityGroup this.group,
    this.key,
    this.value,
  );

  final InterconnectCapabilityGroup? group;
  final String key;
  final FutureOr<Object?> Function() value;
}

/// 由多个模块共同填写的能力分组（顶层一个对象）。[members] 就是线上键序；分组里的每个键必须恰好由一个
/// 模块提供（[InterconnectModuleTable] 构造时校验），分组整体出现在第一个提供者的位置上。
final class InterconnectCapabilityGroup {
  const InterconnectCapabilityGroup(this.key, this.members);

  final String key;
  final List<String> members;
}

/// 表查找的结果。
sealed class InterconnectRouteLookup {
  const InterconnectRouteLookup();
}

/// 命中一条路由。
final class InterconnectRouteHit extends InterconnectRouteLookup {
  const InterconnectRouteHit(this.module, this.route);

  final InterconnectHostModule module;
  final InterconnectRoute route;
}

/// 路径归某个模块，但没有一条路由受理这个方法：带了凭据回 405。
final class InterconnectRouteMethodNotAllowed extends InterconnectRouteLookup {
  const InterconnectRouteMethodNotAllowed(this.module);

  final InterconnectHostModule module;
}

/// 表里没有这条路径：落进 WebDAV 文件树。
final class InterconnectRouteMiss extends InterconnectRouteLookup {
  const InterconnectRouteMiss._();
}

const InterconnectRouteMiss _miss = InterconnectRouteMiss._();

/// 模块表：鉴权豁免、分发、能力位都是对它的循环。
class InterconnectModuleTable {
  InterconnectModuleTable(Iterable<InterconnectHostModule> modules)
    : modules = List<InterconnectHostModule>.unmodifiable(modules) {
    final List<(InterconnectPath, InterconnectHostModule)> seen =
        <(InterconnectPath, InterconnectHostModule)>[];
    final Set<String> topKeys = <String>{};
    final Map<InterconnectCapabilityGroup, Map<String, String>> groupOwners =
        <InterconnectCapabilityGroup, Map<String, String>>{};
    final Set<String> names = <String>{};
    for (final InterconnectHostModule m in this.modules) {
      if (!names.add(m.name)) throw ArgumentError('互联模块名重复：${m.name}');
      final List<InterconnectRoute> routes =
          List<InterconnectRoute>.unmodifiable(m.routes);
      for (final InterconnectRoute r in routes) {
        r.path._validate();
        for (final (InterconnectPath other, InterconnectHostModule owner)
            in seen) {
          if (!identical(owner, m) && _pathsOverlap(r.path, other)) {
            throw ArgumentError(
              '互联模块路由冲突：${r.path}（${m.name}）与 $other（${owner.name}）',
            );
          }
        }
        seen.add((r.path, m));
      }
      _routes.add((m, routes));
      final List<InterconnectCapability> caps =
          List<InterconnectCapability>.unmodifiable(m.capabilities);
      for (final InterconnectCapability c in caps) {
        final InterconnectCapabilityGroup? g = c.group;
        if (g == null) {
          if (!topKeys.add(c.key)) {
            throw ArgumentError('互联能力键重复：${c.key}（${m.name}）');
          }
          continue;
        }
        if (!g.members.contains(c.key)) {
          throw ArgumentError('能力分组 ${g.key} 没有声明成员 ${c.key}（${m.name}）');
        }
        final Map<String, String> owners = groupOwners.putIfAbsent(
          g,
          () => <String, String>{},
        );
        final String? previous = owners[c.key];
        if (previous != null) {
          throw ArgumentError(
            '能力分组 ${g.key}.${c.key} 重复提供：$previous 与 ${m.name}',
          );
        }
        owners[c.key] = m.name;
      }
      _capabilities.add(caps);
    }
    for (final MapEntry<InterconnectCapabilityGroup, Map<String, String>> e
        in groupOwners.entries) {
      if (!topKeys.add(e.key.key)) {
        throw ArgumentError('互联能力键重复：分组 ${e.key.key} 与顶层键同名');
      }
      for (final String member in e.key.members) {
        if (!e.value.containsKey(member)) {
          throw ArgumentError('能力分组 ${e.key.key}.$member 没有模块提供');
        }
      }
    }
  }

  final List<InterconnectHostModule> modules;
  final List<(InterconnectHostModule, List<InterconnectRoute>)> _routes =
      <(InterconnectHostModule, List<InterconnectRoute>)>[];
  final List<List<InterconnectCapability>> _capabilities =
      <List<InterconnectCapability>>[];

  /// [path]（规范化路径）上的 [upperMethod] 请求归哪条路由。跨模块的模式互不相交，所以至多一个模块命中。
  InterconnectRouteLookup lookup(String path, String upperMethod) {
    for (final (InterconnectHostModule m, List<InterconnectRoute> routes)
        in _routes) {
      bool pathOwned = false;
      for (final InterconnectRoute r in routes) {
        if (!r.path.matches(path)) continue;
        pathOwned = true;
        if (r.accepts(upperMethod)) return InterconnectRouteHit(m, r);
      }
      if (pathOwned) return InterconnectRouteMethodNotAllowed(m);
    }
    return _miss;
  }

  /// 按注册顺序现算能力文档。顶层键按模块注册顺序、模块内按声明顺序；分组出现在第一个提供者的位置，
  /// 组内按 [InterconnectCapabilityGroup.members] 排。值为 null 的键不出现。
  Future<Map<String, Object?>> capabilities() async {
    final Map<String, Object?> out = <String, Object?>{};
    final Map<InterconnectCapabilityGroup, Map<String, Object?>> groups =
        <InterconnectCapabilityGroup, Map<String, Object?>>{};
    for (final List<InterconnectCapability> caps in _capabilities) {
      for (final InterconnectCapability c in caps) {
        final Object? value = await c.value();
        final InterconnectCapabilityGroup? g = c.group;
        if (g == null) {
          if (value != null) out[c.key] = value;
          continue;
        }
        final Map<String, Object?> members = groups.putIfAbsent(g, () {
          final Map<String, Object?> fresh = <String, Object?>{};
          out[g.key] = fresh;
          return fresh;
        });
        if (value != null) members[c.key] = value;
      }
    }
    for (final MapEntry<InterconnectCapabilityGroup, Map<String, Object?>> e
        in groups.entries) {
      final Map<String, Object?> filled = e.value;
      out[e.key.key] = <String, Object?>{
        for (final String member in e.key.members)
          if (filled.containsKey(member)) member: filled[member],
      };
    }
    return out;
  }

  Future<void> disposeAll() async {
    for (final InterconnectHostModule m in modules) {
      await m.dispose();
    }
  }
}

/// 交给 handler 的请求：鉴权与身份一次算好，handler 不再各自调服务器的私有函数。
class InterconnectRequest {
  InterconnectRequest({
    required this.raw,
    required this.path,
    required String? Function() credentialFingerprint,
    required this.basicPassword,
    required Future<bool> Function() isPairedPeer,
    required this.hostId,
    required this.streams,
  }) : _credentialFingerprint = credentialFingerprint,
       _isPairedPeer = isPairedPeer;

  /// 原始 shelf 请求（读 body / query / header）。
  final shelf.Request raw;

  /// 规范化路径（带前导 `/`、已解码）。
  final String path;

  final String? Function() _credentialFingerprint;
  late final String? _fingerprint = _credentialFingerprint();

  /// 本请求 Basic 凭据的指纹（`_credentialFingerprint`）；没有 / 解不出时 null。派生凭据（流票等）据此
  /// 记签发者，凭据被吊销即连带作废（BUG-4393）。用到时才算。
  String? get credentialFingerprint => _fingerprint;

  /// Basic 的口令原文；没有时 null。只在「认得出是哪台已配对设备」时有意义，见 [pairedPeerToken]。
  final String? basicPassword;

  final Future<bool> Function() _isPairedPeer;
  Future<bool>? _pairedPeer;

  /// 本 host 的稳定身份；未设时 null。
  final String? hostId;

  /// 统一流票。
  final LibraryMediaStreams streams;

  String get method => raw.method;

  /// 大写的方法名（路由的方法集也是大写）。
  String get upperMethod => raw.method.toUpperCase();

  /// 凭据是不是某台已配对设备自己的专属口令（不是共享 token / legacy 行）。结果在本请求内缓存。
  Future<bool> isPairedPeer() => _pairedPeer ??= _isPairedPeer();

  /// 已配对设备的专属口令；不是已配对设备时 null。
  Future<String?> pairedPeerToken() async =>
      await isPairedPeer() ? basicPassword : null;
}

/// [path] 等于 [prefix] 或在它下面（`prefix/…`）。
bool interconnectPathUnder(String path, String prefix) =>
    path == prefix || path.startsWith('$prefix/');
