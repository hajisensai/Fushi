// host 侧「我的设备」标记与已验签设备钥匙指纹（app 与无头服务端共用一份实现）。
//
// 「我的设备」是跟随本机 Fushi 账户自动登录（`interconnect_leaderboard_link.dart`）的门：
// 只有被 host 主人标记过的已配对 peer 才能让本机账户代绑它的设备钥匙。标记只给配对时
// **设备钥匙验签通过**的 peer（自报的 deviceId 谁都能冒报，设备私钥签名冒不了，
// PR #2258 审查）。
//
// 两份数据都落 `preferences` 表（键名冻结，app 与服务端同一张表、同一编码——同一个数据根
// 被桌面 Fushi 打开时标记照样认得出来）。都是**设备本地**数据：描述的是本机配对表里的
// peer，app 的备份 / Profile 快照把这两个键列在设备本地清单里。

import 'dart:convert';

import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/sync/fushi_sync_server.dart';

/// 「我的设备」peerId 集合：JSON 字符串数组（排序），元素是 `fushi_paired_peers.peerId`。
/// 每次（重新）配对落库都按本次会话的结论**显式**重写这台 peer 的标记，吊销时删掉。
const String kInterconnectOwnerDevicePeersPref =
    'interconnect_owner_device_peers';

/// 配对时验签通过的互联设备公钥指纹：JSON 对象 `{peerId: fingerprint}`（键排序，见
/// `pairing/interconnect_device_key.dart`）。每次（重新）配对按本次是否验签通过显式重写。
const String kInterconnectPeerDeviceKeysPref = 'interconnect_peer_device_keys';

/// 「我的设备」与设备钥匙指纹的读写（无状态：每次现读 DB）。
class InterconnectOwnerDeviceStore {
  const InterconnectOwnerDeviceStore(this._db);

  final FushiDatabase _db;

  /// 被标记为「我的设备」的已配对 peer（peerId 集合）。
  Future<Set<String>> ownerDevicePeerIds() async {
    final String? raw = await _db.getPref(kInterconnectOwnerDevicePeersPref);
    if (raw == null || raw.isEmpty) return <String>{};
    try {
      final Object? decoded = jsonDecode(raw);
      if (decoded is! List) return <String>{};
      return <String>{
        for (final Object? e in decoded)
          if (e is String) e,
      };
    } on FormatException {
      return <String>{};
    }
  }

  /// 标记 / 取消一台已配对 peer 为「我的设备」。返回最终是否为「我的设备」。
  ///
  /// 标记要求这台 peer 配对时证明过设备钥匙（[deviceKeyFingerprints] 里有它）；
  /// 没证明过的（旧版 client / 没上报设备钥匙）标不上，返回 false。
  Future<bool> setOwnerDevicePeer(String peerId, bool owner) async {
    bool effective = owner;
    if (effective && !(await deviceKeyFingerprints()).containsKey(peerId)) {
      effective = false;
    }
    final Set<String> ids = await ownerDevicePeerIds();
    final bool changed = effective ? ids.add(peerId) : ids.remove(peerId);
    if (!changed) return effective;
    if (ids.isEmpty) {
      await _db.deletePref(kInterconnectOwnerDevicePeersPref);
    } else {
      await _db.setPref(
        kInterconnectOwnerDevicePeersPref,
        jsonEncode(ids.toList()..sort()),
      );
    }
    return effective;
  }

  /// 配对时验签通过的设备公钥指纹（peerId → fingerprint）。
  Future<Map<String, String>> deviceKeyFingerprints() async {
    final String? raw = await _db.getPref(kInterconnectPeerDeviceKeysPref);
    if (raw == null || raw.isEmpty) return <String, String>{};
    try {
      final Object? decoded = jsonDecode(raw);
      if (decoded is! Map) return <String, String>{};
      return <String, String>{
        for (final MapEntry<Object?, Object?> e in decoded.entries)
          if (e.key is String && e.value is String)
            e.key! as String: e.value! as String,
      };
    } on FormatException {
      return <String, String>{};
    }
  }

  /// 记下 / 清掉一台 peer 的已验签设备公钥指纹（null = 本次配对没证明设备钥匙）。
  Future<void> setDeviceKeyFingerprint(
    String peerId,
    String? fingerprint,
  ) async {
    final Map<String, String> keys = await deviceKeyFingerprints();
    if (keys[peerId] == fingerprint) return;
    if (fingerprint == null) {
      keys.remove(peerId);
    } else {
      keys[peerId] = fingerprint;
    }
    if (keys.isEmpty) {
      await _db.deletePref(kInterconnectPeerDeviceKeysPref);
    } else {
      final List<String> ids = keys.keys.toList()..sort();
      await _db.setPref(
        kInterconnectPeerDeviceKeysPref,
        jsonEncode(<String, String>{
          for (final String id in ids) id: keys[id]!,
        }),
      );
    }
  }

  /// 一次配对落库后按**本次会话**的结论显式重写这台 peer：先记指纹（没证明设备钥匙 =
  /// 清掉），再写标记——不沿用这台 peerId 以前的任何标记（PR #2258 审查问题 1）。
  Future<void> recordPairing(FushiPairedPeerRegistration registration) async {
    await setDeviceKeyFingerprint(
      registration.peerId,
      registration.deviceKeyFingerprint,
    );
    await setOwnerDevicePeer(registration.peerId, registration.ownerDevice);
  }

  /// 吊销一台 peer 时清掉它的标记与指纹。
  Future<void> forgetPeer(String peerId) async {
    await setOwnerDevicePeer(peerId, false);
    await setDeviceKeyFingerprint(peerId, null);
  }

  /// 持 [token] 的已配对 peer 是否被标记为「我的设备」（token 不属于任何现存 peer = false）。
  /// 同时要求这台 peer 有已验签的设备钥匙记录：标记集合里的 peerId 不能单独生效。
  Future<bool> isOwnerDevicePeerToken(String token) async {
    final Set<String> owners = await ownerDevicePeerIds();
    if (owners.isEmpty) return false;
    final Map<String, String> keys = await deviceKeyFingerprints();
    for (final FushiPairedPeerRow peer in await _db.getPairedPeers()) {
      if (peer.token == token) {
        return owners.contains(peer.peerId) && keys.containsKey(peer.peerId);
      }
    }
    return false;
  }
}
