// TODO-1274 网络来源（SFTP/FTP）的每来源凭据存储。
//
// 🔴 凭据红线：网络来源的密码/私钥**绝不**写入 MediaSources.configJson，而是以
// base64 单独落 Preferences 表，键为 `media_source_secret_<sourceId>`，与来源行一一
// 对应（删除来源时同步清除，见 MediaSourcesDialog._remove）。安全模型与 SyncRepository
// 一致（gcloud/aws-cli 等桌面 CLI 同款）：依赖操作系统对用户数据目录的文件权限保护，
// base64 只是避免明文肉眼可读，不是加密。真 secure storage 是后续增强点。

import 'dart:convert';

import 'package:hibiki_core/hibiki_core.dart';

/// 单个网络来源解析出的凭据（运行时值对象，不持久化整体）。
class MediaSourceSecret {
  const MediaSourceSecret({this.password, this.privateKey});

  /// 登录密码；无为 null。
  final String? password;

  /// SFTP 私钥 PEM；无为 null。
  final String? privateKey;

  /// 二者皆空 = 无凭据。
  bool get isEmpty =>
      (password == null || password!.isEmpty) &&
      (privateKey == null || privateKey!.isEmpty);
}

/// 网络来源凭据的读写存储：以 base64 落 Preferences，按 sourceId 命名空间隔离。
class MediaSourceCredentialStore {
  MediaSourceCredentialStore(this._db);

  final HibikiDatabase _db;

  /// 某来源的凭据 Preferences 键。公开供守卫测试断言命名空间稳定。
  static String prefKeyForSource(int sourceId) =>
      'media_source_secret_$sourceId';

  /// 保存/更新某来源的凭据；password/privateKey 都空时删除该键（等价清凭据）。
  Future<void> saveSecret(
    int sourceId, {
    String? password,
    String? privateKey,
  }) async {
    final String key = prefKeyForSource(sourceId);
    final bool hasPass = password != null && password.isNotEmpty;
    final bool hasKey = privateKey != null && privateKey.isNotEmpty;
    if (!hasPass && !hasKey) {
      await _db.deletePref(key);
      return;
    }
    final Map<String, String> payload = <String, String>{
      if (hasPass) 'password': password,
      if (hasKey) 'privateKey': privateKey,
    };
    final String encoded = base64Encode(utf8.encode(jsonEncode(payload)));
    await _db.setPref(key, encoded);
  }

  /// 读取某来源的凭据；无/损坏都回退空凭据（不抛）。
  Future<MediaSourceSecret> readSecret(int sourceId) async {
    final String? encoded = await _db.getPref(prefKeyForSource(sourceId));
    if (encoded == null || encoded.isEmpty) {
      return const MediaSourceSecret();
    }
    try {
      final Object? decoded = jsonDecode(utf8.decode(base64Decode(encoded)));
      if (decoded is Map) {
        return MediaSourceSecret(
          password: decoded['password'] as String?,
          privateKey: decoded['privateKey'] as String?,
        );
      }
    } catch (_) {
      // 损坏的 base64/JSON：回退空凭据。
    }
    return const MediaSourceSecret();
  }

  /// 删除某来源的凭据（移除来源时调用，幂等）。
  Future<void> deleteSecret(int sourceId) =>
      _db.deletePref(prefKeyForSource(sourceId));
}
