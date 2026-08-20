// 网络来源库流媒体的播放期 HTTP 头解析（v1：WebDAV Basic 认证）。
//
// 凭据红线：密码只活在 SourceLibraryCredentialStore（Preferences），不落
// MediaSources.configJson，也**不复制进每行 VideoBooks.streamSpecJson**——按
// VideoBooks.sourceId 在打开时现解析：改密码一处生效，行级零副本，删来源
// （FK setNull）后自然退化为无认证直链。

import 'dart:convert';

import 'package:fushi_core/fushi_core.dart';

import 'package:fushi/src/media/source_library/source_library_credential_store.dart';
import 'package:fushi/src/media/source_library/source_library_row.dart';

/// 按 [sourceId] 解析打开该来源流媒体（视频流 / spec 里的字幕 URL）所需的
/// HTTP 头。
///
/// 无来源（手动导入 / 来源已删）、本地来源、或凭据为空 → 空 map（调用方展开
/// 合并零分支）。目前只有 WebDAV 来源产出 `Authorization: Basic`：用户名来自
/// configJson（白名单键）、密码来自凭据存储。
Future<Map<String, String>> resolveSourceStreamHeaders({
  required FushiDatabase db,
  required int? sourceId,
}) async {
  if (sourceId == null) return const <String, String>{};
  final SourceLibraryRow? source = await db.getMediaSourceById(sourceId);
  if (source == null || source.transport != 'webdav') {
    return const <String, String>{};
  }
  final Map<String, Object?> cfg = decodeSourceConfig(source.configJson);
  final String username = (cfg['username'] as String?) ?? '';
  final SourceLibrarySecret secret =
      await SourceLibraryCredentialStore(db).readSecret(source.id);
  final String password = secret.password ?? '';
  if (username.isEmpty && password.isEmpty) return const <String, String>{};
  final String token = base64Encode(utf8.encode('$username:$password'));
  return <String, String>{'Authorization': 'Basic $token'};
}
