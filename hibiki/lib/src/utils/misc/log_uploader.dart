import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/src/utils/misc/log_upload_config.dart';

/// 上传结果状态。
enum LogUploadStatus {
  success,
  unauthorized,
  tooLarge,
  rateLimited,
  serverError,
  networkError,
}

/// 上传结果（成功时带服务端返回 id）。
class LogUploadOutcome {
  const LogUploadOutcome(this.kind, {this.id});
  final LogUploadStatus kind;
  final String? id;
}

/// 把日志正文截断到 [kMaxLogUploadBytes] 字节内（保留尾部最近内容），
/// 截断时在头部插入标记。返回的字符串 UTF-8 字节数严格 <= 上限。
///
/// 关键：尾部切点可能落在某个多字节字符（如日文/emoji）的中间。直接
/// `allowMalformed` 解码会把残缺续字节替换成 U+FFFD（3 字节），令结果
/// 反而超出预算。这里改为把切点向后推进到下一个合法 UTF-8 首字节
/// （跳过开头的续字节 0b10xxxxxx），保证只取完整字符、不产生替换符，
/// 从而硬兑现「字节数 <= 上限」契约。
String _capLogBytes(String log) {
  final List<int> bytes = utf8.encode(log);
  if (bytes.length <= kMaxLogUploadBytes) return log;
  const String marker = '[truncated] 日志过大，仅上传最近部分\n';
  final int budget = kMaxLogUploadBytes - utf8.encode(marker).length;
  int start = bytes.length - budget;
  // 续字节高 2 位是 10；向后推进到字符边界（最多跳过 3 个续字节）。
  while (start < bytes.length && (bytes[start] & 0xC0) == 0x80) {
    start++;
  }
  final String tailStr = utf8.decode(bytes.sublist(start));
  return marker + tailStr;
}

/// 执行一次日志上传（纯逻辑，便于用 MockClient 测试）。
/// 不弹 UI；调用方据返回的 [LogUploadOutcome] 决定提示。
Future<LogUploadOutcome> performLogUpload({
  required String log,
  required String kind,
  required String endpoint,
  required String token,
  required String appVersion,
  required String platform,
  required String device,
  required String tsIso,
  http.Client? client,
}) async {
  final http.Client c = client ?? http.Client();
  try {
    final String body = jsonEncode(<String, dynamic>{
      'kind': kind,
      'app_version': appVersion,
      'platform': platform,
      'device': device,
      'ts': tsIso,
      'log': _capLogBytes(log),
    });
    final http.Response resp = await c.post(
      Uri.parse(endpoint),
      headers: <String, String>{
        'Content-Type': 'application/json; charset=utf-8',
        'X-Upload-Token': token,
      },
      body: body,
    );
    switch (resp.statusCode) {
      case 200:
        String? id;
        try {
          final Object? decoded = jsonDecode(resp.body);
          if (decoded is Map && decoded['id'] is String) {
            id = decoded['id'] as String;
          }
        } catch (_) {}
        return LogUploadOutcome(LogUploadStatus.success, id: id);
      case 401:
      case 403:
        return const LogUploadOutcome(LogUploadStatus.unauthorized);
      case 413:
        return const LogUploadOutcome(LogUploadStatus.tooLarge);
      case 429:
        return const LogUploadOutcome(LogUploadStatus.rateLimited);
      default:
        return const LogUploadOutcome(LogUploadStatus.serverError);
    }
  } catch (_) {
    return const LogUploadOutcome(LogUploadStatus.networkError);
  } finally {
    if (client == null) c.close();
  }
}

/// 收集设备/版本元信息（平台 + OS 版本字符串，无需额外插件）。
Future<({String appVersion, String platform, String device})>
    _collectMeta() async {
  String appVersion = 'unknown';
  try {
    final PackageInfo info = await PackageInfo.fromPlatform();
    appVersion = '${info.version}+${info.buildNumber}';
  } catch (_) {}
  return (
    appVersion: appVersion,
    platform: Platform.operatingSystem,
    device: Platform.operatingSystemVersion,
  );
}

/// 日志上传隐私同意标志的持久化键。
const String kLogUploadConsentKey = 'log_upload_privacy_consent';

/// 确保已获得上传隐私同意：已记住则直接返回 true；否则弹一次性同意对话框，
/// 用户同意则持久化并返回 true，取消返回 false。可独立 widget 测试。
Future<bool> ensureLogUploadConsent(BuildContext context) async {
  final SharedPreferences prefs = await SharedPreferences.getInstance();
  if (prefs.getBool(kLogUploadConsentKey) ?? false) return true;
  if (!context.mounted) return false;
  final bool? agreed = await showAdaptiveDialog<bool>(
    context: context,
    builder: (BuildContext ctx) => AlertDialog.adaptive(
      title: Text(t.log_upload_consent_title),
      content: Text(t.log_upload_consent_body),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: Text(t.cancel),
        ),
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(true),
          child: Text(t.log_upload_consent_agree),
        ),
      ],
    ),
  );
  if (agreed == true) {
    await prefs.setBool(kLogUploadConsentKey, true);
    return true;
  }
  return false;
}

/// UI 入口：收集元信息 → 上传 → 按结果弹 SnackBar。
Future<void> uploadLogToServer({
  required BuildContext context,
  required String log,
  required String kind,
}) async {
  void notify(String message) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  // 首次上传前征得隐私同意（记住选择）；取消则不上传。
  if (!await ensureLogUploadConsent(context)) return;

  notify(t.log_upload_in_progress);
  final meta = await _collectMeta();
  final LogUploadOutcome out = await performLogUpload(
    log: log,
    kind: kind,
    endpoint: kLogUploadEndpoint,
    token: kLogUploadToken,
    appVersion: meta.appVersion,
    platform: meta.platform,
    device: meta.device,
    tsIso: DateTime.now().toUtc().toIso8601String(),
  );

  switch (out.kind) {
    case LogUploadStatus.success:
      notify(out.id == null
          ? t.log_upload_success
          : '${t.log_upload_success} (${out.id})');
    case LogUploadStatus.tooLarge:
      notify(t.log_upload_too_large);
    default:
      notify(t.log_upload_failed);
  }
}
