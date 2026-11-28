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
  /// 不同模块的路径模式不得相交；同一模块里，一条路由声明的每个方法都必须到得了——被前面的路由整条盖住
  /// （宽的写在了窄的前面）即报错。两样都在 [InterconnectModuleTable] 构造时查。
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

  /// [other] 能匹配的路径本模式是否**全部**匹配（模块内遮蔽检测用）。只在能证明时回 true：
  /// [InterconnectPath.where] 的谓词不透明，除「同一棵子树、同一个谓词」外一律当作盖不住别人。
  bool covers(InterconnectPath other);

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
  bool covers(InterconnectPath other) =>
      other is InterconnectExactPath && other.path == path;

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
  bool covers(InterconnectPath other) => switch (other) {
    InterconnectExactPath(:final String path) => matches(path),
    InterconnectSubtreePath(prefix: final String theirs) => matches(theirs),
    // under 匹配「以 `theirs`（带尾 `/`）开头」的一切，含 `theirs` 本身。
    InterconnectUnderPath(prefix: final String theirs) => theirs.startsWith(
      '$prefix/',
    ),
    InterconnectWherePath(:final String within) => matches(within),
  };

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
  bool covers(InterconnectPath other) => switch (other) {
    InterconnectExactPath(:final String path) => matches(path),
    // 子树 / where 的根自己也是它们能匹配的路径，所以根就得在本前缀之下。
    InterconnectSubtreePath(prefix: final String theirs) => matches(theirs),
    InterconnectUnderPath(prefix: final String theirs) => matches(theirs),
    InterconnectWherePath(:final String within) => matches(within),
  };

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
  bool covers(InterconnectPath other) => switch (other) {
    InterconnectExactPath(:final String path) => matches(path),
    InterconnectWherePath(within: final String theirs, test: final theirTest) =>
      identical(theirTest, test) && interconnectPathUnder(theirs, within),
    InterconnectSubtreePath() || InterconnectUnderPath() => false,
  };

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
/// 只有 [InterconnectTrust.credential] 要求 Basic；其余几种都是「不带 Authorization 也能进 handler」的面。
/// 类型只保证「免 Basic 必须显式选一种信任级」：[InterconnectTrust.queryTicketOrCredential] 的门由中间件
/// 执行，而 [pairingBootstrap] / [reachabilityProbe] / [InterconnectTrust.urlTicket] 的门仍在各自的 handler
/// 里（[InterconnectUrlTicketTrust.ticket] 只是说明文字，不是校验器）——这三种**不是**结构保证。把票据
/// 校验收进路由声明要连判门顺序一起动，属于下一阶段 A2（统一判门）；在那之前由
/// `interconnect_module_layer_test.dart` 的「免 Basic 的面」名单卡住：多开一个免 Basic 的面即红。
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

  @override
  String toString() => 'credential';
}

final class InterconnectPairingBootstrapTrust extends InterconnectTrust {
  const InterconnectPairingBootstrapTrust._();

  @override
  String toString() => 'pairingBootstrap';
}

final class InterconnectProbeTrust extends InterconnectTrust {
  const InterconnectProbeTrust._();

  @override
  String toString() => 'reachabilityProbe';
}

final class InterconnectUrlTicketTrust extends InterconnectTrust {
  const InterconnectUrlTicketTrust(this.ticket);

  /// 校验的是哪种票据（流 token、原盘会话 token、查词音频 id……）。
  final String ticket;

  @override
  String toString() => 'urlTicket($ticket)';
}

final class InterconnectQueryTicketTrust extends InterconnectTrust {
  const InterconnectQueryTicketTrust(this.validate);

  final Future<bool> Function(shelf.Request request) validate;

  @override
  String toString() => 'queryTicketOrCredential';
}

/// `/api/capabilities` 里的一项能力声明：**一次求值**，写进一个或多个键。值每次请求现算；null = 此刻不
/// 提供（键不出现）——与回 `false` 是两种不同的线上形态，按键原样保留。
///
/// 线上要求「同有同无」的几个键（新旧两代能力名、同一实现的几种形态）必须写成一项（[InterconnectCapability.keys]
/// / [InterconnectCapability.members]），不要各写一项各求一次值：那样两次求值之间状态一变，回包里就只剩其中
/// 一个。[InterconnectModuleTable.capabilities] 另外保证整份文档的求值在同一个同步段里发起。
final class InterconnectCapability {
  /// 顶层键。
  InterconnectCapability(String key, this.value)
    : group = null,
      keys = List<String>.unmodifiable(<String>[key]);

  /// 同一次求值写进多个顶层键（按 [keys] 的顺序相邻出现）。
  InterconnectCapability.keys(Iterable<String> keys, this.value)
    : group = null,
      keys = _nonEmptyKeys(keys);

  /// [group] 分组（如 `liveLibrary`）里的一个键。
  InterconnectCapability.member(
    InterconnectCapabilityGroup this.group,
    String key,
    this.value,
  ) : keys = List<String>.unmodifiable(<String>[key]);

  /// 同一次求值写进 [group] 分组里的多个键（线上位置由分组的成员序决定）。
  InterconnectCapability.members(
    InterconnectCapabilityGroup this.group,
    Iterable<String> keys,
    this.value,
  ) : keys = _nonEmptyKeys(keys);

  final InterconnectCapabilityGroup? group;

  /// 本项写进的键；同一次求值的结果原样写进每一个。
  final List<String> keys;
  final FutureOr<Object?> Function() value;

  static List<String> _nonEmptyKeys(Iterable<String> keys) {
    final List<String> out = List<String>.unmodifiable(keys);
    if (out.isEmpty) throw ArgumentError('互联能力声明至少要有一个键');
    return out;
  }
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
      for (final (int index, InterconnectRoute r) in routes.indexed) {
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
        _checkReachable(m, routes, index);
      }
      _routes.add((m, routes));
      final List<InterconnectCapability> caps =
          List<InterconnectCapability>.unmodifiable(m.capabilities);
      for (final InterconnectCapability c in caps) {
        final InterconnectCapabilityGroup? g = c.group;
        for (final String key in c.keys) {
          if (g == null) {
            if (!topKeys.add(key)) {
              throw ArgumentError('互联能力键重复：$key（${m.name}）');
            }
            continue;
          }
          if (!g.members.contains(key)) {
            throw ArgumentError('能力分组 ${g.key} 没有声明成员 $key（${m.name}）');
          }
          final Map<String, String> owners = groupOwners.putIfAbsent(
            g,
            () => <String, String>{},
          );
          final String? previous = owners[key];
          if (previous != null) {
            throw ArgumentError(
              '能力分组 ${g.key}.$key 重复提供：$previous 与 ${m.name}',
            );
          }
          owners[key] = m.name;
        }
      }
      _capabilities.addAll(caps);
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
  final List<InterconnectCapability> _capabilities = <InterconnectCapability>[];

  /// 表里的全部路由，按模块注册顺序、模块内按声明顺序（诊断与从表派生的守卫用）。
  Iterable<(InterconnectHostModule, InterconnectRoute)> get routes sync* {
    for (final (InterconnectHostModule m, List<InterconnectRoute> routes)
        in _routes) {
      for (final InterconnectRoute r in routes) {
        yield (m, r);
      }
    }
  }

  /// 模块内遮蔽：[routes] 的第 [index] 条声明的每个方法都必须到得了。同一模块按声明顺序匹配，前面一条
  /// 路径模式盖住它（[InterconnectPath.covers]）又受理同一方法的路由会先命中——那个方法在本条上就是死的，
  /// 它声明的信任级、方法集、handler 都不生效（把免 Basic 的取流子路径写到宽子树后面，取流就悄悄变成
  /// 要 Basic）。「先窄后宽」「同路径、前一条只收部分方法、后一条不限方法兜底」都合法。
  static void _checkReachable(
    InterconnectHostModule m,
    List<InterconnectRoute> routes,
    int index,
  ) {
    final InterconnectRoute later = routes[index];
    for (final InterconnectRoute earlier in routes.take(index)) {
      if (!earlier.path.covers(later.path)) continue;
      final Set<String>? earlierMethods = earlier.methods;
      final Set<String>? laterMethods = later.methods;
      final String dead;
      if (earlierMethods == null) {
        dead = laterMethods == null ? '全部方法' : laterMethods.join(' / ');
      } else if (laterMethods == null) {
        // 后一条不限方法：它收的是前一条没受理的那些方法。
        continue;
      } else {
        final Set<String> shadowed = laterMethods.intersection(earlierMethods);
        if (shadowed.isEmpty) continue;
        dead = shadowed.join(' / ');
      }
      throw ArgumentError(
        '互联模块 ${m.name} 的路由 ${later.path} 被前面的 ${earlier.path} 遮住（$dead 永远到不了）：'
        '窄的路由要写在宽的前面',
      );
    }
  }

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
  /// 组内按 [InterconnectCapabilityGroup.members] 排。值为 null 的键不出现。全部值在同一个同步段里发起
  /// 求值（见函数体），一项声明只求值一次。
  Future<Map<String, Object?>> capabilities() async {
    final Map<String, Object?> out = <String, Object?>{};
    final Map<InterconnectCapabilityGroup, Map<String, Object?>> groups =
        <InterconnectCapabilityGroup, Map<String, Object?>>{};
    // 所有能力值在同一个同步段里发起求值，中间不让出事件循环：同步的值函数看到的是同一时刻的 host
    // 状态。逐项 `await` 会在每两项之间让出一次，两项读同一个开关时可能读到一前一后两个值。
    final List<FutureOr<Object?>> evaluating = <FutureOr<Object?>>[
      for (final InterconnectCapability c in _capabilities) c.value(),
    ];
    final List<Object?> values = await Future.wait(<Future<Object?>>[
      for (final FutureOr<Object?> v in evaluating) Future<Object?>.value(v),
    ]);
    for (final (int i, InterconnectCapability c) in _capabilities.indexed) {
      final Object? value = values[i];
      final InterconnectCapabilityGroup? g = c.group;
      if (g == null) {
        if (value != null) {
          for (final String key in c.keys) {
            out[key] = value;
          }
        }
        continue;
      }
      final Map<String, Object?> members = groups.putIfAbsent(g, () {
        final Map<String, Object?> fresh = <String, Object?>{};
        out[g.key] = fresh;
        return fresh;
      });
      if (value != null) {
        for (final String key in c.keys) {
          members[key] = value;
        }
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
