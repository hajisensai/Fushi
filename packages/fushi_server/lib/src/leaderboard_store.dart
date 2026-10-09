/// 无头服务端的排行榜本机账户（每 Profile 一份）。
///
/// 文件格式与落点和 app 的 `LeaderboardStore` / `LeaderboardLocalAccount`
/// （`fushi/lib/src/leaderboard/leaderboard_store.dart`，Flutter 包内，服务端 import
/// 不到）逐字段一致：`<support>/leaderboard/profile_<id>.json`，version 1。服务端的
/// `support` 目录就是 DB 所在目录（与 app 的 `databaseDirectory` 同义），所以同一份
/// 数据根被桌面 Fushi 打开时账户照样认得出来；改字段必须两边同步。
///
/// `recoveryCode` 含设备私钥，等同密码：只落这一个文件（POSIX 上 0600），**不进偏好表、
/// 不进日志**；读坏文件时只记类型、绝不回显内容。
library;

import 'dart:convert';
import 'dart:io';

import 'package:fushi_engine/leaderboard/leaderboard_sync.dart';
import 'package:path/path.dart' as p;

/// 本机排行榜账户（字段语义见 app 侧同名类）。
class ServerLeaderboardAccount {
  const ServerLeaderboardAccount({
    required this.recoveryCode,
    required this.accountId,
    this.consentAt,
    this.uploadEnabled = true,
    this.serverUrl,
    this.syncState = LeaderboardSyncState.empty,
    this.lastSyncAt,
    this.isbnBackfilledAt,
    this.uploadBlockedByOtherDevice = false,
  });

  static const int version = 1;

  /// `FUSHI1-…` 恢复码（设备钥匙私钥）。
  final String recoveryCode;

  /// **服务端**账户 id（`LeaderboardSelf.account.id`）。
  final String accountId;

  /// 同意公开上传的时刻（毫秒）；null = 没同意过，此时 [uploadEnabled] 必为 false。
  final int? consentAt;
  final bool uploadEnabled;

  /// 覆盖默认服务地址；null = 默认地址。
  final String? serverUrl;
  final LeaderboardSyncState syncState;

  /// 上次**成功**同步的时刻（毫秒）。
  final int? lastSyncAt;

  /// 存量 EPUB 的 ISBN 回填跑过的时刻（毫秒）。
  final int? isbnBackfilledAt;

  /// 上次同步被拒：本账户的上传设备是另一台。
  final bool uploadBlockedByOtherDevice;

  ServerLeaderboardAccount copyWith({
    int? consentAt,
    bool? uploadEnabled,
    LeaderboardSyncState? syncState,
    int? lastSyncAt,
    int? isbnBackfilledAt,
    bool? uploadBlockedByOtherDevice,
  }) => ServerLeaderboardAccount(
    recoveryCode: recoveryCode,
    accountId: accountId,
    consentAt: consentAt ?? this.consentAt,
    uploadEnabled: uploadEnabled ?? this.uploadEnabled,
    serverUrl: serverUrl,
    syncState: syncState ?? this.syncState,
    lastSyncAt: lastSyncAt ?? this.lastSyncAt,
    isbnBackfilledAt: isbnBackfilledAt ?? this.isbnBackfilledAt,
    uploadBlockedByOtherDevice: uploadBlockedByOtherDevice ?? this.uploadBlockedByOtherDevice,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'version': version,
    'recoveryCode': recoveryCode,
    'accountId': accountId,
    'consentAt': consentAt,
    'uploadEnabled': uploadEnabled,
    if (serverUrl != null) 'serverUrl': serverUrl,
    'syncState': syncState.toJson(),
    'lastSyncAt': lastSyncAt,
    'isbnBackfilledAt': isbnBackfilledAt,
    'uploadBlockedByOtherDevice': uploadBlockedByOtherDevice,
  };

  /// 账户字段坏了抛 [FormatException]；只有 `syncState` 坏了时退回空状态（下次同步
  /// 走 reset 全量对账）。与 app 侧解析规则一致。
  factory ServerLeaderboardAccount.fromJson(Map<String, Object?> j) {
    final Object? code = j['recoveryCode'];
    final Object? account = j['accountId'];
    final Object? consent = j['consentAt'];
    if (j['version'] != version ||
        code is! String ||
        code.isEmpty ||
        account is! String ||
        account.isEmpty ||
        (consent != null && consent is! num)) {
      throw const FormatException('not a leaderboard account file');
    }
    LeaderboardSyncState sync = LeaderboardSyncState.empty;
    final Object? rawSync = j['syncState'];
    if (rawSync is Map<Object?, Object?>) {
      try {
        sync = LeaderboardSyncState.fromJson(rawSync.cast<String, dynamic>());
      } on FormatException {
        sync = LeaderboardSyncState.empty;
      }
    }
    final Object? server = j['serverUrl'];
    return ServerLeaderboardAccount(
      recoveryCode: code,
      accountId: account,
      consentAt: (consent as num?)?.toInt(),
      uploadEnabled: consent != null && j['uploadEnabled'] != false,
      serverUrl: server is String && server.isNotEmpty ? server : null,
      syncState: sync,
      lastSyncAt: (j['lastSyncAt'] as num?)?.toInt(),
      isbnBackfilledAt: (j['isbnBackfilledAt'] as num?)?.toInt(),
      uploadBlockedByOtherDevice: j['uploadBlockedByOtherDevice'] == true,
    );
  }
}

/// 账户文件读不出来（坏 JSON / 形状不对）。[message] 不含文件内容（内容里有私钥）。
class ServerLeaderboardStoreException implements Exception {
  const ServerLeaderboardStoreException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 一个 Profile 的账户文件：`<support>/leaderboard/profile_<profileId>.json`。
class ServerLeaderboardStore {
  ServerLeaderboardStore({required this.supportRoot, required this.profileId});

  final Directory supportRoot;
  final int profileId;

  File get file => File(p.join(supportRoot.path, 'leaderboard', 'profile_$profileId.json'));

  static final RegExp _fileName = RegExp(r'^profile_(\d+)\.json$');

  /// 本机正在上传的 Profile（账户在、同意上传、没被别的设备顶掉），选同机代表 Profile
  /// 用（`leaderboardUnattributedOwner`，BUG-2870）。读不出的文件跳过。
  static Future<Set<int>> uploadingProfileIds(Directory supportRoot) async {
    final Directory dir = Directory(p.join(supportRoot.path, 'leaderboard'));
    if (!await dir.exists()) return <int>{};
    final Set<int> out = <int>{};
    for (final FileSystemEntity e in dir.listSync()) {
      final RegExpMatch? m = _fileName.firstMatch(p.basename(e.path));
      if (e is! File || m == null) continue;
      final int id = int.parse(m.group(1)!);
      try {
        final ServerLeaderboardAccount? a = await ServerLeaderboardStore(
          supportRoot: supportRoot,
          profileId: id,
        ).read();
        if (a != null && a.uploadEnabled && !a.uploadBlockedByOtherDevice) out.add(id);
      } on ServerLeaderboardStoreException {
        continue;
      }
    }
    return out;
  }

  /// 读账户；文件不存在返回 null。文件坏了抛 [ServerLeaderboardStoreException]
  /// ——命令行不像 app 那样静默当「未开启」：那样下一次 login 会把还能抢救的私钥覆盖掉。
  Future<ServerLeaderboardAccount?> read() async {
    final File f = file;
    if (!await f.exists()) return null;
    try {
      final Object? decoded = jsonDecode(await f.readAsString());
      if (decoded is! Map<Object?, Object?>) throw const FormatException('not a JSON object');
      return ServerLeaderboardAccount.fromJson(decoded.cast<String, Object?>());
    } on Object catch (e) {
      // 只报类型：jsonDecode 的 FormatException 会带上源文本（= 私钥）。
      throw ServerLeaderboardStoreException('排行榜账户文件损坏（${e.runtimeType}）: ${f.path}');
    }
  }

  /// 原子写：同目录临时文件 flush 后 rename 覆盖；POSIX 上先收紧到 0600，收紧失败
  /// 就不落盘（宁可报错也不留可读的私钥）。
  Future<void> write(ServerLeaderboardAccount account) async {
    final File target = file;
    await target.parent.create(recursive: true);
    final File tmp = File('${target.path}.tmp');
    await tmp.writeAsString(jsonEncode(account.toJson()), flush: true);
    if (!Platform.isWindows) {
      final ProcessResult r = await Process.run('chmod', <String>['600', tmp.path]);
      if (r.exitCode != 0) {
        await tmp.delete();
        throw FileSystemException('chmod 600 失败: ${r.stderr}', tmp.path);
      }
    }
    await tmp.rename(target.path);
  }

  /// 删除本机账户文件（服务端账户不受影响）。返回是否真的删了东西。
  Future<bool> delete() async {
    bool removed = false;
    final File f = file;
    if (await f.exists()) {
      await f.delete();
      removed = true;
    }
    final File tmp = File('${f.path}.tmp');
    if (await tmp.exists()) await tmp.delete();
    return removed;
  }
}
