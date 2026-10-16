// 跟随已配对设备自动登录 Fushi 账户（所有者 2026-10-16 拍板：自动、无按钮、无确认弹窗——
// 已配对本身就是信任凭据）。协议与安全门见引擎
// `packages/fushi_engine/lib/sync/interconnect_leaderboard_link.dart` 文件头。
//
// - host 侧 [AppLeaderboardLinkHost]：本机已登录账户时，用**本机**设备钥匙签名调服务端
//   `POST /v1/me/devices` 代对端绑定它交来的公钥。
// - client 侧 [LeaderboardPairedLogin]：本机没有账户、这个 Profile 在本机从没登录过、
//   开关「跟随已配对设备自动登录」开着时，后台向已配对的 host 发自己的公钥；成功落档，
//   失败只记日志并退避（不能每次同步都打服务端）。
//
// 私钥、恢复码绝不经互联传输：请求里只有公钥 + 持有证明，应答里只有账户公开资料与服务地址。

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi_engine/leaderboard/leaderboard_client.dart';
import 'package:fushi_engine/leaderboard/leaderboard_device_link.dart';
import 'package:fushi_engine/leaderboard/leaderboard_models.dart';
import 'package:fushi_engine/sync/interconnect_leaderboard_link.dart';
import 'package:http/http.dart' as http;

import 'package:fushi/src/leaderboard/leaderboard_service.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/sync/interconnect_post_transport.dart';
import 'package:fushi/src/sync/sync_backend.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';

/// host 侧：把对端交来的公钥挂到本机当前 Profile 的账户上。
class AppLeaderboardLinkHost implements InterconnectLeaderboardLinkHost {
  AppLeaderboardLinkHost({
    required Future<bool> Function() enabled,
    required Future<bool> Function(String peerToken) isOwnerDevicePeer,
    required LeaderboardService? Function() service,
  }) : _enabled = enabled,
       _isOwnerDevicePeer = isOwnerDevicePeer,
       _service = service;

  final Future<bool> Function() _enabled;
  final Future<bool> Function(String peerToken) _isOwnerDevicePeer;

  /// 当前 Profile 的排行榜服务；app 还没起完（拿不到 Riverpod 容器）时为 null。
  final LeaderboardService? Function() _service;

  @override
  Future<bool> isInterconnectLeaderboardLinkEnabled() => _enabled();

  @override
  Future<bool> isOwnerDevicePeer(String peerToken) =>
      _isOwnerDevicePeer(peerToken);

  @override
  Future<InterconnectLeaderboardLinkResult> linkLeaderboardDevice(
    LeaderboardDeviceLinkRequest request,
  ) async {
    final LeaderboardService? service = _service();
    if (service == null) {
      throw const InterconnectLeaderboardLinkException(
        409,
        InterconnectLeaderboardLinkError.noAccount,
      );
    }
    final ({LeaderboardSelf self, String? serverUrl})? linked;
    try {
      linked = await service.linkPairedDevice(request);
    } on LeaderboardApiException catch (e) {
      // 旧版服务端没有 POST /v1/me/devices（Worker 对未知写路由回 404）。
      if (e.status == 404) {
        throw const InterconnectLeaderboardLinkException(
          502,
          InterconnectLeaderboardLinkError.serverUnsupported,
        );
      }
      if (e.status >= 500) {
        throw const InterconnectLeaderboardLinkException(
          502,
          InterconnectLeaderboardLinkError.serverUnavailable,
        );
      }
      // too_many_devices / key_taken / stale_time / rate_limited …：透传服务端错误码。
      throw InterconnectLeaderboardLinkException(409, e.code);
    } on TimeoutException {
      throw const InterconnectLeaderboardLinkException(
        502,
        InterconnectLeaderboardLinkError.serverUnavailable,
      );
    } on SocketException {
      throw const InterconnectLeaderboardLinkException(
        502,
        InterconnectLeaderboardLinkError.serverUnavailable,
      );
    } on http.ClientException {
      throw const InterconnectLeaderboardLinkException(
        502,
        InterconnectLeaderboardLinkError.serverUnavailable,
      );
    }
    if (linked == null) {
      throw const InterconnectLeaderboardLinkException(
        409,
        InterconnectLeaderboardLinkError.noAccount,
      );
    }
    return InterconnectLeaderboardLinkResult(
      account: linked.self.toJson(),
      serverUrl: linked.serverUrl,
    );
  }
}

/// 自动登录成功：[peerName] 是配对记录里的对端设备名（可能为 null），[self] 是落档的账户。
typedef LeaderboardPairedLoginSuccess = ({
  String? peerName,
  LeaderboardSelf self,
});

/// 首次失败后的退避起点；之后每次 ×3，封顶 [kLeaderboardPairedLoginMaxBackoff]。
const Duration kLeaderboardPairedLoginBaseBackoff = Duration(minutes: 5);

/// 退避上限；「重试也不会好」的错误（满 10 台、服务端旧版、限流）直接跳到这一档。
const Duration kLeaderboardPairedLoginMaxBackoff = Duration(hours: 24);

/// 这些错误码短时间内重试不会有不同结果：直接退避到上限。
const Set<String> _kLongBackoffCodes = <String>{
  'too_many_devices',
  'key_taken',
  'rate_limited',
  InterconnectLeaderboardLinkError.serverUnsupported,
};

/// client 侧：后台跟随已配对设备自动登录。一个实例对应一个 Profile 的排行榜服务；
/// 退避状态在内存里（进程重启后最多立即再试一次）。
class LeaderboardPairedLogin {
  LeaderboardPairedLogin({
    required LeaderboardService service,
    required SyncRepository repository,
    InterconnectPostTransport Function()? transport,
    int Function()? clockMs,
  }) : _service = service,
       _repo = repository,
       _transport =
           transport ?? (() => InterconnectPostTransport(repo: repository)),
       _clockMs = clockMs ?? _systemClockMs;

  final LeaderboardService _service;
  final SyncRepository _repo;
  final InterconnectPostTransport Function() _transport;
  final int Function() _clockMs;

  static int _systemClockMs() => DateTime.now().millisecondsSinceEpoch;

  int _failures = 0;
  int? _nextAttemptAt;
  Future<LeaderboardPairedLoginSuccess?>? _running;

  /// 下次允许尝试的时刻（测试 / 诊断用）。
  @visibleForTesting
  int? get nextAttemptAt => _nextAttemptAt;

  /// 条件满足就试一次；成功返回对端信息，其余（条件不满足 / 退避中 / 失败）返回 null。
  /// 失败只记日志、不抛。并发调用合并成同一次。
  Future<LeaderboardPairedLoginSuccess?> maybeRun() =>
      _running ??= _maybeRun().whenComplete(() => _running = null);

  Future<LeaderboardPairedLoginSuccess?> _maybeRun() async {
    try {
      final int now = _clockMs();
      final int? next = _nextAttemptAt;
      if (next != null && now < next) return null;
      if (!await _repo.isLeaderboardFollowPairedLoginEnabled()) return null;
      if (!await _service.canFollowPairedLogin()) return null;
      // 没有已启用的配对对端：不算失败，也不退避（只读了本地配置）。
      if (!(await _repo.getFushiClientUrls()).any(
        (FushiClientUrl u) => u.enabled,
      )) {
        return null;
      }
      return await _attempt();
    } catch (e, st) {
      ErrorLogService.instance.log('LeaderboardPairedLogin', e, st);
      _backoff(
        long:
            e is _PairedLoginFailed && e.codes.any(_kLongBackoffCodes.contains),
      );
      return null;
    }
  }

  Future<LeaderboardPairedLoginSuccess?> _attempt() async {
    final List<String> rejections = <String>[];
    FushiClientUrl? winner;
    final LeaderboardSelf? self = await _service.adoptFromPairedDevice((
      LeaderboardDeviceLinkRequest request,
    ) async {
      final InterconnectPostOutcome outcome;
      try {
        outcome = await _transport().post(
          path: kInterconnectLeaderboardLinkPath,
          body: request.toJson(),
          // host 还要再打一次排行榜服务（自身 30 秒超时）。
          timeout: const Duration(seconds: 45),
          authErrorMessage: 'Paired device login rejected',
          onRejectedResponse: (int status, Map<String, dynamic>? json) {
            final Object? code = json?['error'];
            rejections.add(code is String ? code : 'http_$status');
          },
        );
      } on SyncAuthError {
        throw const _PairedLoginFailed(<String>['paired_peer_rejected']);
      }
      final Map<String, dynamic>? json = outcome.json;
      if (json == null) {
        throw _PairedLoginFailed(
          outcome.allUnreachable ? const <String>['unreachable'] : rejections,
        );
      }
      winner = outcome.candidate;
      final InterconnectLeaderboardLinkResult result =
          InterconnectLeaderboardLinkResult.fromJson(json);
      return (account: result.account, serverUrl: result.serverUrl);
    });
    if (self == null) return null; // 本机在此期间已登录
    _failures = 0;
    _nextAttemptAt = null;
    return (peerName: winner?.deviceName, self: self);
  }

  void _backoff({required bool long}) {
    _failures++;
    final int base = kLeaderboardPairedLoginBaseBackoff.inMilliseconds;
    final int cap = kLeaderboardPairedLoginMaxBackoff.inMilliseconds;
    final int delay = long
        ? cap
        : math.min(cap, base * math.pow(3, _failures - 1).toInt());
    _nextAttemptAt = _clockMs() + delay;
  }
}

/// 一次自动登录失败的原因码（只进日志）。
class _PairedLoginFailed implements Exception {
  const _PairedLoginFailed(this.codes);

  final List<String> codes;

  @override
  String toString() => 'paired login failed: ${codes.join(', ')}';
}

/// 当前 Profile 的自动登录器（随 Profile 切换重建）。
final Provider<LeaderboardPairedLogin> leaderboardPairedLoginProvider =
    Provider<LeaderboardPairedLogin>((Ref ref) {
      final LeaderboardService service = ref.watch(leaderboardServiceProvider);
      final AppModel app = ref.read(appProvider);
      return LeaderboardPairedLogin(
        service: service,
        repository: SyncRepository(app.database),
      );
    });
