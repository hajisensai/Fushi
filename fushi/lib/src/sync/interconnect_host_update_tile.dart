/// 互联 client 侧的「主机版本」行（反馈 Pp8XPyve0N）：显示已配对 host 的 app 版本、
/// 是否有新版本，提供「更新主机」按钮并跟踪 host 的更新进度，host 重启后自动重连并
/// 报出新版本号。
///
/// 远程调用经 [HostUpdateRemote] 注入（生产 = [InterconnectHostUpdateRemote]），
/// 行本身只管状态与展示，widget 测试可直接喂假 remote。
library;

import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:fushi_engine/sync/host_update/host_update_protocol.dart';

import 'package:fushi/src/sync/interconnect_sync_backend.dart';
import 'package:fushi/src/sync/sync_error_messages.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi/src/updates/host_self_update_service.dart'
    show kHostUpdateErrorCancelled, kHostUpdateErrorInstallPermission;
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/utils.dart';

/// 主机版本行要用到的两次远程调用。
abstract interface class HostUpdateRemote {
  /// host 的版本与更新状态；null = host 不提供远程更新（老 host / 无头服务端）。
  Future<HostUpdateStatus?> status({bool refresh = false});

  /// 让 host 开始更新（[nonce] 来自刚拿到的 [status]）。
  Future<HostUpdateStatus> trigger(String nonce);
}

/// 生产实现：打当前已配对 host 的 `/api/host/update`。
class InterconnectHostUpdateRemote implements HostUpdateRemote {
  InterconnectHostUpdateRemote(this._repo);

  final SyncRepository _repo;

  @override
  Future<HostUpdateStatus?> status({bool refresh = false}) =>
      InterconnectSyncBackend.instance.getRemoteHostUpdateStatus(
        repo: _repo,
        refresh: refresh,
      );

  @override
  Future<HostUpdateStatus> trigger(String nonce) => InterconnectSyncBackend
      .instance
      .triggerRemoteHostUpdate(repo: _repo, nonce: nonce);
}

/// 主机拒绝原因 → 给用户的一句话。
String hostUpdateDenialText(HostUpdateDenial denial) => switch (denial) {
  HostUpdateDenial.disabled => t.interconnect_host_update_reason_disabled,
  HostUpdateDenial.unsupported => t.interconnect_host_update_reason_unsupported,
  HostUpdateDenial.zone => t.interconnect_host_update_reason_zone,
  HostUpdateDenial.peerTokenRequired =>
    t.interconnect_host_update_reason_pairing,
  HostUpdateDenial.invalidNonce => t.interconnect_host_update_reason_retry,
  HostUpdateDenial.busy => t.interconnect_host_update_reason_busy,
  HostUpdateDenial.noUpdate => t.interconnect_host_update_reason_no_update,
};

/// host 状态 → 副标题（纯函数，便于单测）。
String hostUpdateStatusText(HostUpdateStatus status) {
  final String? latest = status.latestVersion;
  switch (status.phase) {
    case HostUpdatePhase.downloading:
      final int percent = ((status.progress ?? 0) * 100).clamp(0, 100).round();
      return t.interconnect_host_update_downloading(percent: percent);
    case HostUpdatePhase.installing:
      return t.interconnect_host_update_installing;
    case HostUpdatePhase.awaitingHostConfirmation:
      return status.error == kHostUpdateErrorInstallPermission
          ? t.interconnect_host_update_awaiting_permission
          : t.interconnect_host_update_awaiting_confirm;
    case HostUpdatePhase.failed:
      if (status.error == kHostUpdateErrorCancelled) {
        return t.interconnect_host_update_cancelled;
      }
      return t.interconnect_host_update_failed(message: status.error ?? '');
    case HostUpdatePhase.idle:
      break;
  }
  if (!status.supported) return t.interconnect_host_update_reason_unsupported;
  if (latest == null) {
    return t.interconnect_host_update_up_to_date(
      version: status.currentVersion,
    );
  }
  final String available = t.interconnect_host_update_available(
    current: status.currentVersion,
    latest: latest,
  );
  return status.remoteUpdateAllowed
      ? available
      : '$available\n${t.interconnect_host_update_reason_disabled}';
}

class InterconnectHostUpdateTile extends StatefulWidget {
  const InterconnectHostUpdateTile({
    super.key,
    required this.remote,
    this.pollInterval = const Duration(seconds: 2),
    this.reconnectWindow = const Duration(minutes: 5),
    this.now,
  });

  final HostUpdateRemote remote;

  /// 触发后多久问一次 host 进度。
  final Duration pollInterval;

  /// host 断线（重启中）后最多等多久重新连上——从**断线那一刻**算起，与之前下载了
  /// 多久无关（慢网下载可以远超这个窗口）。
  final Duration reconnectWindow;

  /// 时钟（测试缝；null = [DateTime.now]）。
  final DateTime Function()? now;

  @override
  State<InterconnectHostUpdateTile> createState() =>
      _InterconnectHostUpdateTileState();
}

class _InterconnectHostUpdateTileState
    extends State<InterconnectHostUpdateTile> {
  HostUpdateStatus? _status;
  bool _loading = true;
  bool _hostLacksFeature = false;
  String? _message;

  /// 触发更新那一刻 host 的版本；非 null = 正在跟踪这一轮更新。
  String? _trackingFrom;

  /// 跟踪期间第一次连不上 host 的时刻；非 null = host 正在重启（[_reconnecting]），
  /// 重连窗口从这里起算，任何一次问到 host 就清掉。
  DateTime? _disconnectedSince;
  bool get _reconnecting => _disconnectedSince != null;
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    unawaited(_load(refresh: true));
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _load({bool refresh = false}) async {
    try {
      final HostUpdateStatus? status = await widget.remote.status(
        refresh: refresh,
      );
      if (!mounted) return;
      setState(() {
        _status = status;
        _hostLacksFeature = status == null;
        _message = null;
      });
    } on HostUpdateRejected catch (e) {
      if (!mounted) return;
      setState(() => _message = hostUpdateDenialText(e.denial));
    } catch (e, stack) {
      ErrorLogService.instance.log('Interconnect.hostUpdate', e, stack);
      if (!mounted) return;
      setState(() => _message = friendlySyncErrorDetail(e));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _trigger() async {
    final HostUpdateStatus? current = _status;
    final String? latest = current?.latestVersion;
    if (current == null || latest == null || _trackingFrom != null) return;
    final bool confirmed = await showFushiConfirmDialog(
      context: context,
      title: t.interconnect_host_update_confirm_title,
      message: t.interconnect_host_update_confirm_body(version: latest),
      confirmLabel: t.interconnect_host_update_action,
      icon: FushiIcons.server,
    );
    if (!confirmed || !mounted) return;
    setState(() => _loading = true);
    try {
      // nonce 单次有效且短 TTL：触发前现取一张，别用页面打开时拿到的那张。
      final HostUpdateStatus? fresh = await widget.remote.status();
      final String? nonce = fresh?.nonce;
      if (fresh == null || nonce == null) {
        throw const HostUpdateRejected(HostUpdateDenial.unsupported);
      }
      final HostUpdateStatus started = await widget.remote.trigger(nonce);
      if (!mounted) return;
      setState(() {
        _status = started;
        _message = null;
        _trackingFrom = started.currentVersion;
        _disconnectedSince = null;
      });
      _poll?.cancel();
      _poll = Timer.periodic(widget.pollInterval, (_) => _pollOnce());
    } on HostUpdateRejected catch (e) {
      if (mounted) setState(() => _message = hostUpdateDenialText(e.denial));
    } catch (e) {
      ErrorLogService.instance.logDiagnostic('Interconnect.hostUpdate', e);
      if (mounted) {
        setState(
          () => _message = t.interconnect_host_update_failed(
            message: friendlySyncErrorDetail(e),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  bool _polling = false;

  DateTime _now() => (widget.now ?? DateTime.now)();

  Future<void> _pollOnce() async {
    final String? from = _trackingFrom;
    if (from == null || _polling) return;
    _polling = true;
    try {
      final HostUpdateStatus? status = await widget.remote.status();
      if (!mounted || status == null) return;
      if (status.currentVersion != from) {
        // host 重启回来、版本变了：这一轮结束。
        _stopTracking(
          t.interconnect_host_update_done(version: status.currentVersion),
        );
        setState(() => _status = status);
        return;
      }
      setState(() {
        _status = status;
        _disconnectedSince = null;
      });
      // 失败：本轮结束。等 host 上的人确认安装（Android）：host 这边已经没有在跑的
      // 东西了，结果取决于 host 上的人——不再每 2 秒问一次，按钮放回来；安装框被
      // 取消 / 没人点时，再点一次「更新主机」即可重新弹出安装确认。
      if (status.phase == HostUpdatePhase.failed ||
          status.phase == HostUpdatePhase.awaitingHostConfirmation) {
        _stopTracking(null);
      }
    } catch (_) {
      // 桌面 host 由安装器接班后进程退出：连接失败 = 正在重启，继续等它回来。
      if (!mounted) return;
      final DateTime now = _now();
      final DateTime since = _disconnectedSince ?? now;
      if (now.difference(since) > widget.reconnectWindow) {
        _stopTracking(t.interconnect_host_update_reconnect_timeout);
        return;
      }
      setState(() => _disconnectedSince = since);
    } finally {
      _polling = false;
    }
  }

  void _stopTracking(String? message) {
    _poll?.cancel();
    _poll = null;
    setState(() {
      _trackingFrom = null;
      _disconnectedSince = null;
      _message = message;
    });
  }

  String _subtitle() {
    if (_reconnecting) return t.interconnect_host_update_restarting;
    final String? message = _message;
    final HostUpdateStatus? status = _status;
    if (message != null) {
      return status == null
          ? message
          : '${hostUpdateStatusText(status)}\n$message';
    }
    if (_hostLacksFeature) return t.interconnect_host_update_reason_unavailable;
    if (status == null) return t.interconnect_host_update_checking;
    return hostUpdateStatusText(status);
  }

  bool get _busy =>
      _loading || _trackingFrom != null || (_status?.phase.isBusy ?? false);

  @override
  Widget build(BuildContext context) {
    final HostUpdateStatus? status = _status;
    final bool canTrigger = !_busy && (status?.canTrigger ?? false);
    final double? progress = status?.phase == HostUpdatePhase.downloading
        ? status?.progress
        : null;
    final Widget trailing = _busy
        ? SizedBox(
            key: const ValueKey<String>('busy'),
            width: 20,
            height: 20,
            child: FushiCircularProgressIndicator(
              strokeWidth: 2,
              value: progress,
            ),
          )
        : FushiFilledButton.tonal(
            key: const ValueKey<String>('action'),
            onPressed: canTrigger ? _trigger : null,
            child: Text(t.interconnect_host_update_action),
          );
    return AdaptiveSettingsRow(
      title: t.interconnect_host_update_title,
      subtitle: _subtitle(),
      icon: FushiIcons.server,
      controlBelow: true,
      // 行级 onTap 让本行成为焦点目标（方向键 / 手柄 A 可触发），同配置搬运行。
      // 能更新时触发更新，否则重新问一次 host。
      onTap: _busy
          ? null
          : (canTrigger ? _trigger : () => _load(refresh: true)),
      trailing: AnimatedSwitcher(
        duration: fushiMotionDuration(context, FushiMotion.short),
        child: trailing,
      ),
    );
  }
}
