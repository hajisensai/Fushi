/// 互联 host 的统一模块层（设计 docs/specs/2026-11-23-interconnect-music-library-design.md §3.5，拍板
/// design-imusic-q0 选 a）。
///
/// 以前给互联加一类功能要同时改五处：服务器手写的前缀分发链、`/api/capabilities` 里手写的一行、
/// 免 Basic 表、各自一套流票、客户端 `InterconnectSyncBackend` 里一组方法——漏一处就是 404 / 能力位
/// 撒谎 / 401。现在**一个功能 = 一个 [InterconnectHostModule]**：自己声明路由前缀、能力键与能力值、
/// 要签发的流种类；[FushiSyncServer] 对 [InterconnectModuleTable] 循环分发、循环拼能力位，流票统一走
/// [LibraryMediaStreams]（`library_media_streams.dart`）。新功能只写模块、在 app 与服务端的装配点各
/// 注册一行，不再动服务器本体。
library;

import 'dart:async';

import 'package:fushi_engine/sync/library_media_streams.dart';
import 'package:shelf/shelf.dart' as shelf;

/// 一个互联 host 功能。
///
/// 「此刻不提供」用 [capability] 回 null 表达（能力位里不出现这个键），路由照样归本模块，由
/// [handle] 自己回 404——这样功能关着时它的前缀仍被占住，不会掉进 WebDAV 文件树（以前手写链里
/// 每段都是「null → 404」，迁移后行为一字不差）。
abstract class InterconnectHostModule {
  /// `/api/capabilities` 里的顶层键（如 `jobs`、`music`）。
  String get capabilityKey;

  /// 能力值；null = 本 host 此刻不提供（键不出现）。每次 `/api/capabilities` 现算。
  Future<Object?> capability();

  /// 本模块拥有的路径前缀（带前导 `/`、不带尾 `/`）。路径等于前缀或以「前缀 + `/`」开头即归本模块；
  /// 前缀之间冲突（相同或互为前缀）在 [InterconnectModuleTable] 构造时就报错。
  List<String> get routePrefixes;

  /// 处理一个已过 Basic 鉴权的请求。
  Future<shelf.Response> handle(InterconnectRequest request);

  /// 本模块经 [LibraryMediaStreams] 签发的流种类，以及「id → 文件」的解析器。服务器启动时逐个注册；
  /// 没有流的模块为空。
  Map<LibraryMediaStreamKind, LibraryMediaFileResolver> get streamResolvers =>
      const <LibraryMediaStreamKind, LibraryMediaFileResolver>{};

  /// host 停机时调用（中止在跑的任务等）。默认什么也不做。
  Future<void> dispose() async {}
}

/// 交给模块的请求：鉴权与身份一次算好，模块不再各自调服务器的私有函数。
class InterconnectRequest {
  InterconnectRequest({
    required this.raw,
    required this.path,
    required this.credentialFingerprint,
    required this.basicPassword,
    required Future<bool> Function() isPairedPeer,
    required this.hostId,
    required this.streams,
  }) : _isPairedPeer = isPairedPeer;

  /// 原始 shelf 请求（读 body / query / header）。
  final shelf.Request raw;

  /// 规范化路径（带前导 `/`、已解码）。
  final String path;

  /// 本请求 Basic 凭据的指纹（`_credentialFingerprint`）；没有 / 解不出时 null。派生凭据（流票等）据此
  /// 记签发者，凭据被吊销即连带作废（BUG-4393）。
  final String? credentialFingerprint;

  /// Basic 的口令原文；没有时 null。只在「认得出是哪台已配对设备」时有意义，见 [pairedPeerToken]。
  final String? basicPassword;

  final Future<bool> Function() _isPairedPeer;
  Future<bool>? _pairedPeer;

  /// 本 host 的稳定身份；未设时 null。
  final String? hostId;

  /// 统一流票。
  final LibraryMediaStreams streams;

  String get method => raw.method;

  /// 凭据是不是某台已配对设备自己的专属口令（不是共享 token / legacy 行）。结果在本请求内缓存。
  Future<bool> isPairedPeer() => _pairedPeer ??= _isPairedPeer();

  /// 已配对设备的专属口令；不是已配对设备时 null。
  Future<String?> pairedPeerToken() async =>
      await isPairedPeer() ? basicPassword : null;
}

/// 模块表：分发、能力位都是对它的循环。
class InterconnectModuleTable {
  InterconnectModuleTable(Iterable<InterconnectHostModule> modules)
    : modules = List<InterconnectHostModule>.unmodifiable(modules) {
    final Set<String> keys = <String>{};
    final List<(String, InterconnectHostModule)> prefixes =
        <(String, InterconnectHostModule)>[];
    for (final InterconnectHostModule m in this.modules) {
      if (!keys.add(m.capabilityKey)) {
        throw ArgumentError('互联模块能力键重复：${m.capabilityKey}');
      }
      for (final String prefix in m.routePrefixes) {
        if (!prefix.startsWith('/') || prefix.endsWith('/')) {
          throw ArgumentError('互联模块路由前缀须以 / 开头、不以 / 结尾：$prefix');
        }
        for (final (String other, InterconnectHostModule owner) in prefixes) {
          if (interconnectPathUnder(prefix, other) ||
              interconnectPathUnder(other, prefix)) {
            throw ArgumentError(
              '互联模块路由前缀冲突：$prefix（${m.capabilityKey}）与 '
              '$other（${owner.capabilityKey}）',
            );
          }
        }
        prefixes.add((prefix, m));
      }
    }
  }

  final List<InterconnectHostModule> modules;

  /// [path] 归哪个模块；没有时 null。前缀互不包含，所以至多一个命中。
  InterconnectHostModule? match(String path) {
    for (final InterconnectHostModule m in modules) {
      for (final String prefix in m.routePrefixes) {
        if (interconnectPathUnder(path, prefix)) return m;
      }
    }
    return null;
  }

  /// 按注册顺序现算能力位（null 的不出现）。顺序即 JSON 键序——迁移前后的 `/api/capabilities` 逐字节
  /// 相同靠这一点。
  Future<Map<String, Object?>> capabilities() async {
    final Map<String, Object?> out = <String, Object?>{};
    for (final InterconnectHostModule m in modules) {
      final Object? value = await m.capability();
      if (value != null) out[m.capabilityKey] = value;
    }
    return out;
  }

  Future<void> disposeAll() async {
    for (final InterconnectHostModule m in modules) {
      await m.dispose();
    }
  }
}

/// [path] 等于 [prefix] 或在它下面（`prefix/…`）。
bool interconnectPathUnder(String path, String prefix) =>
    path == prefix || path.startsWith('$prefix/');
