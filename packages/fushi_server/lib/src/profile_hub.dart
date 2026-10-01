/// 服务端的互联「配置文件」（Profile）寄存处：已配对设备把配置方案推上来寄存，另一台
/// 设备再从这里拉走——服务端是常开的中转站，不是配置的消费者。
///
/// 为什么不像 app 那样落 `profiles` / `profile_settings` 表：
/// * 服务端没有阅读器 / 制卡 / 快捷键，没有任何一条配置要 apply 到自己身上；
/// * `profiles` 表在服务端**有副作用**：统计分区键 `resolveActiveProfileId` 在表空时
///   取 0、表非空时退到最早建的 Profile，`AggregateSyncService` 还按 Profile 名↔id
///   映射互联统计——往里塞一行「寄存的配置」会让此后 host 上的统计悄悄换分区，
///   之前盖 0 的历史对读取面隐身。
/// 所以寄存物是 `<support>/interconnect_profiles/<id>.fushiprofile.json` 文件，内容就是
/// 规范化后的分享 JSON（可直接当 `.fushiprofile.json` 在 app「配置管理」里导入）。
///
/// 解析 / 校验 / 准入判据 / 信封格式全部走引擎 `profile_document.dart`（与 app
/// `ProfileRepository` 同一份实现）。**不做出境剔凭据**：寄存物只可能来自对端的
/// 分享导出（发送侧已按 `PrefRedactionPolicy` 剔过），服务端从不把自己的偏好快照成
/// Profile，所以这条通道带不出服务端的任何凭据。
library;

import 'dart:io';

import 'package:fushi_engine/profile/profile_document.dart';
import 'package:fushi_engine/sync/interconnect_profile_transfer.dart';
import 'package:path/path.dart' as p;

/// 一份寄存的配置方案（给 WebUI 列表）。
class ServerProfileSummary {
  const ServerProfileSummary({
    required this.id,
    required this.name,
    required this.receivedAt,
    required this.settingCount,
    required this.shared,
  });

  final int id;
  final String name;

  /// 收到（写盘）时刻，毫秒。
  final int receivedAt;
  final int settingCount;

  /// 是否就是对端 GET 时交出去的那一份（见 [ServerProfileHub.sharedProfileId]）。
  final bool shared;

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'name': name,
    'receivedAt': receivedAt,
    'settingCount': settingCount,
    'shared': shared,
  };
}

class ServerProfileHub {
  ServerProfileHub({
    required this.directory,
    required Future<String?> Function() readPinnedId,
    required Future<void> Function(String? id) writePinnedId,
  }) : _readPinnedId = readPinnedId,
       _writePinnedId = writePinnedId;

  /// 偏好键：WebUI 手动指定「对端拉取时交出哪一份」。缺省 = 最近收到的那份。
  static const String pinnedPrefKey = 'server_interconnect_profile_shared_id';

  static const String _suffix = '.fushiprofile.json';

  final Directory directory;
  final Future<String?> Function() _readPinnedId;
  final Future<void> Function(String? id) _writePinnedId;

  Future<void> _tail = Future<void>.value();

  /// 寄存 / 删除 / 指定三类写操作串行（算唯一名与分配 id 都是 check-then-act）。
  Future<T> _serial<T>(Future<T> Function() body) {
    final Future<T> run = _tail.then((_) => body());
    _tail = run.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return run;
  }

  File _fileFor(int id) => File(p.join(directory.path, '$id$_suffix'));

  /// 目录里现有的寄存 id（升序；文件名不合规的一律不认）。
  Future<List<int>> _ids() async {
    if (!await directory.exists()) return <int>[];
    final List<int> ids = <int>[];
    await for (final FileSystemEntity e in directory.list()) {
      if (e is! File) continue;
      final String name = p.basename(e.path);
      if (!name.endsWith(_suffix)) continue;
      final int? id = int.tryParse(
        name.substring(0, name.length - _suffix.length),
      );
      if (id != null && id > 0) ids.add(id);
    }
    ids.sort();
    return ids;
  }

  Future<ProfileExport?> _read(int id) async {
    final File f = _fileFor(id);
    if (!await f.exists()) return null;
    try {
      return parseProfileDocument(await f.readAsString());
    } on ProfileImportException {
      // 目录被手改坏了：当它不存在，别让一个坏文件拖垮列表 / 拉取。
      return null;
    }
  }

  /// 对端 GET 时交出的那一份：WebUI 指定过且还在就用它，否则最近收到的一份；
  /// 一份都没有返回 null。
  Future<int?> sharedProfileId() async {
    final List<int> ids = await _ids();
    if (ids.isEmpty) return null;
    final int? pinned = int.tryParse(await _readPinnedId() ?? '');
    if (pinned != null && ids.contains(pinned)) return pinned;
    return ids.last;
  }

  Future<List<ServerProfileSummary>> list() async {
    final int? shared = await sharedProfileId();
    final List<ServerProfileSummary> out = <ServerProfileSummary>[];
    for (final int id in (await _ids()).reversed) {
      final ProfileExport? doc = await _read(id);
      if (doc == null) continue;
      out.add(
        ServerProfileSummary(
          id: id,
          name: doc.profileName,
          receivedAt: (await _fileFor(
            id,
          ).lastModified()).millisecondsSinceEpoch,
          settingCount: doc.settings.length,
          shared: id == shared,
        ),
      );
    }
    return out;
  }

  /// 对端 PUT：校验后作为**新**一份寄存（名字重复加 ` (2)` 后缀），返回寄存名。
  /// 载荷不合法抛 [FormatException]（wire 层回 400），此时磁盘零改动。
  Future<String> importJson(String json) {
    final ProfileExport doc;
    try {
      doc = parseProfileDocument(json);
    } on ProfileImportException catch (e) {
      throw FormatException(e.message);
    }
    return _serial(() async {
      final List<int> ids = await _ids();
      final Set<String> taken = <String>{};
      for (final int existing in ids) {
        final ProfileExport? stored = await _read(existing);
        if (stored != null) taken.add(stored.profileName);
      }
      final String name = uniqueProfileNameAmong(taken, doc.profileName);
      final int id = ids.isEmpty ? 1 : ids.last + 1;
      await directory.create(recursive: true);
      final String body = encodeProfileDocument(
        profileName: name,
        schemaVersion: doc.schemaVersion,
        settings: doc.settings.where(isAcceptedProfileSettingEntry).toList(),
      );
      // 先写临时文件再改名：半截文件不会被列表 / 拉取读到。
      final File tmp = File(p.join(directory.path, '$id$_suffix.tmp'));
      await tmp.writeAsString(body, flush: true);
      await tmp.rename(_fileFor(id).path);
      return name;
    });
  }

  /// 对端 GET：交出 [sharedProfileId] 那一份；一份都没有抛
  /// [InterconnectProfileUnavailableException]（wire 层回 409）。
  Future<String> exportShared() async {
    final int? id = await sharedProfileId();
    final ProfileExport? doc = id == null ? null : await _read(id);
    if (doc == null) {
      throw const InterconnectProfileUnavailableException(
        'No profile stored on this server yet — push one from a device first',
      );
    }
    return encodeProfileDocument(
      profileName: doc.profileName,
      schemaVersion: doc.schemaVersion,
      settings: doc.settings,
    );
  }

  /// WebUI：指定对端拉取时交出哪一份。id 不存在返回 false。
  Future<bool> pin(int id) => _serial(() async {
    if (await _read(id) == null) return false;
    await _writePinnedId('$id');
    return true;
  });

  /// WebUI：删掉一份寄存。删的正好是指定的那份时一并清掉指定（回到「最近收到」）。
  Future<bool> delete(int id) => _serial(() async {
    final File f = _fileFor(id);
    if (!await f.exists()) return false;
    await f.delete();
    if (int.tryParse(await _readPinnedId() ?? '') == id) {
      await _writePinnedId(null);
    }
    return true;
  });
}
