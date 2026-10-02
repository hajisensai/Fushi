import 'dart:convert';
import 'dart:io';

import 'package:fushi_engine/leaderboard/leaderboard_sync.dart';
import 'package:path/path.dart' as p;

import 'package:fushi/src/utils/misc/error_log_service.dart';

/// 本机排行榜账户（每 Profile 一份）。
///
/// [recoveryCode] 含设备私钥，等同密码：只落 `<数据目录>/leaderboard/profile_<id>.json`
/// ——**不进偏好表、不进备份、不进日志**（备份只按白名单打包，不含本目录）。
class LeaderboardLocalAccount {
  const LeaderboardLocalAccount({
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

  /// **服务端**账户 id（`LeaderboardSelf.account.id`）。换设备邮箱登录后它不等于
  /// 本机钥匙推出来的设备 id。
  final String accountId;

  /// 用户同意公开（注册 / 登录 / 导入恢复码时勾选，或之后打开上传开关时确认）的时刻
  /// （毫秒）；null = 没同意过，此时 [uploadEnabled] 必为 false。
  final int? consentAt;

  /// 上传开关：关掉后不再上报书架（账户仍在）。
  final bool uploadEnabled;

  /// 覆盖默认服务地址（自建 / 测试）；null = 默认地址。
  final String? serverUrl;

  final LeaderboardSyncState syncState;

  /// 上次**成功**同步的时刻（毫秒）。
  final int? lastSyncAt;

  /// 存量 EPUB 的 ISBN 回填跑过的时刻（毫秒）；null = 还没跑过。
  final int? isbnBackfilledAt;

  /// 上次同步被服务端拒绝：本账户的上传设备是另一台（409
  /// `upload_owned_by_other_device`）。为 true 时后台同步停止，UI 提示「由本设备接管」。
  final bool uploadBlockedByOtherDevice;

  LeaderboardLocalAccount copyWith({
    int? consentAt,
    bool? uploadEnabled,
    LeaderboardSyncState? syncState,
    int? lastSyncAt,
    int? isbnBackfilledAt,
    bool? uploadBlockedByOtherDevice,
  }) => LeaderboardLocalAccount(
    recoveryCode: recoveryCode,
    accountId: accountId,
    consentAt: consentAt ?? this.consentAt,
    uploadEnabled: uploadEnabled ?? this.uploadEnabled,
    serverUrl: serverUrl,
    syncState: syncState ?? this.syncState,
    lastSyncAt: lastSyncAt ?? this.lastSyncAt,
    isbnBackfilledAt: isbnBackfilledAt ?? this.isbnBackfilledAt,
    uploadBlockedByOtherDevice:
        uploadBlockedByOtherDevice ?? this.uploadBlockedByOtherDevice,
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
  /// 走 reset 全量对账），账户本身照常可用。
  factory LeaderboardLocalAccount.fromJson(Map<String, Object?> j) {
    final Object? v = j['version'];
    final Object? code = j['recoveryCode'];
    final Object? account = j['accountId'];
    final Object? consent = j['consentAt'];
    if (v != version ||
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
    return LeaderboardLocalAccount(
      recoveryCode: code,
      accountId: account,
      consentAt: (consent as num?)?.toInt(),
      // 没同意过就不能开着上传（旧文件都带 consentAt，行为不变）。
      uploadEnabled: consent != null && j['uploadEnabled'] != false,
      serverUrl: server is String && server.isNotEmpty ? server : null,
      syncState: sync,
      lastSyncAt: (j['lastSyncAt'] as num?)?.toInt(),
      isbnBackfilledAt: (j['isbnBackfilledAt'] as num?)?.toInt(),
      uploadBlockedByOtherDevice: j['uploadBlockedByOtherDevice'] == true,
    );
  }
}

/// 一个 Profile 的账户文件：`<supportRoot>/leaderboard/profile_<profileId>.json`。
class LeaderboardStore {
  LeaderboardStore({required this.supportRoot, required this.profileId});

  final Directory supportRoot;
  final int profileId;

  File get file =>
      File(p.join(supportRoot.path, 'leaderboard', 'profile_$profileId.json'));

  static final RegExp _fileName = RegExp(r'^profile_(\d+)\.json$');

  /// 本机正在上传的 Profile：账户文件存在、同意上传、没被别的设备顶掉。用来选同机
  /// 代表 Profile（`leaderboardUnattributedOwner`，BUG-2870）。
  static Future<Set<int>> uploadingProfileIds(Directory supportRoot) async {
    final Directory dir = Directory(p.join(supportRoot.path, 'leaderboard'));
    if (!await dir.exists()) return <int>{};
    final Set<int> out = <int>{};
    for (final FileSystemEntity e in dir.listSync()) {
      final RegExpMatch? m = _fileName.firstMatch(p.basename(e.path));
      if (e is! File || m == null) continue;
      final int id = int.parse(m.group(1)!);
      final LeaderboardLocalAccount? a = await LeaderboardStore(
        supportRoot: supportRoot,
        profileId: id,
      ).read();
      if (a != null && a.uploadEnabled && !a.uploadBlockedByOtherDevice) {
        out.add(id);
      }
    }
    return out;
  }

  /// 读账户；文件不存在返回 null。文件坏了（不是 JSON / 形状不对）同样返回 null
  /// ——视为未开启——并记一条**不含文件内容**的日志（内容里有私钥）。
  Future<LeaderboardLocalAccount?> read() async {
    final File f = file;
    if (!await f.exists()) return null;
    try {
      final Object? decoded = jsonDecode(await f.readAsString());
      if (decoded is! Map<Object?, Object?>) {
        throw const FormatException('not a JSON object');
      }
      return LeaderboardLocalAccount.fromJson(decoded.cast<String, Object?>());
    } on Object catch (e, st) {
      // 刻意只记类型：jsonDecode 的 FormatException 会带上源文本（= 私钥）。
      ErrorLogService.instance.log(
        'LeaderboardStore.read',
        'corrupt leaderboard account file for profile $profileId '
            '(${e.runtimeType}); treated as not enabled',
        st,
      );
      return null;
    }
  }

  /// 原子写：先写同目录临时文件并 flush，再 rename 覆盖（读者永远看到完整旧文件或
  /// 完整新文件）。POSIX 上收紧到 0600。
  Future<void> write(LeaderboardLocalAccount account) async {
    final File target = file;
    await target.parent.create(recursive: true);
    final File tmp = File('${target.path}.tmp');
    await tmp.writeAsString(jsonEncode(account.toJson()), flush: true);
    await _restrictToOwner(tmp.path);
    await tmp.rename(target.path);
  }

  /// 删除本机账户文件（服务端账户不受影响）。
  Future<void> delete() async {
    final File f = file;
    if (await f.exists()) await f.delete();
    final File tmp = File('${f.path}.tmp');
    if (await tmp.exists()) await tmp.delete();
  }

  static Future<void> _restrictToOwner(String path) async {
    // Windows 靠 app 私有目录 + NTFS ACL；移动端的应用数据目录本就只有本 app 可读，
    // 且沙箱里起不了子进程。
    if (Platform.isWindows || Platform.isAndroid || Platform.isIOS) return;
    try {
      await Process.run('chmod', <String>['600', path]);
    } on ProcessException {
      // 没有 chmod（非 POSIX 环境）：文件仍在 app 私有目录里，不阻断功能。
    }
  }
}
