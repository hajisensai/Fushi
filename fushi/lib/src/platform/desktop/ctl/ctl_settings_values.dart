/// settings 域控制通道的纯函数：参数解析 / 机密判定 / 统计摘要聚合。
///
/// 与路由文件分开是为了能直接单测（不需要 AppModel / WidgetRef）。这里**不做**
/// 任何业务写入，也不定义统计窗口（窗口只在 `StatWindow`，由路由文件传谓词进来）。
library;

import 'package:fushi_cli/fushi_cli.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/stats/stat_facts.dart';
import 'package:fushi_engine/stats/study_sessions.dart';

import 'package:fushi/src/models/module_id.dart';
import 'package:fushi/src/sync/pref_redaction_policy.dart';

/// 机密值在应答里的占位。
const String kCtlRedactedValue = '******';

/// 设置项值类型（应答里的 `type` 字段）。
abstract final class CtlSettingType {
  static const String boolean = 'bool';
  static const String choice = 'choice';
  static const String number = 'number';
  static const String text = 'text';
  static const String secret = 'secret';
}

/// 一个文本设置项是否机密：schema 声明了 `secret`，或者条目 id（整串或最后一段，
/// 设置 id 的尾段多数就是它写的 pref 键）命中 [PrefRedactionPolicy]——与备份 /
/// Profile 分享出境同一条判据，CLI 读不出它拦下的任何值。
bool isCtlSecretSetting(String id, {required bool declaredSecret}) {
  if (declaredSecret) return true;
  if (PrefRedactionPolicy.isDeviceLocalOrCredential(id)) return true;
  final int dot = id.lastIndexOf('.');
  if (dot < 0) return false;
  return PrefRedactionPolicy.isDeviceLocalOrCredential(id.substring(dot + 1));
}

/// 机密值对外展示：有值打码、空值原样空串（让人知道「没设」）。
String redactCtlSecret(String value) => value.isEmpty ? '' : kCtlRedactedValue;

/// 布尔设置值：true/false/1/0/on/off/yes/no。
bool parseCtlSettingBool(String raw) {
  switch (raw.trim().toLowerCase()) {
    case 'true' || '1' || 'on' || 'yes':
      return true;
    case 'false' || '0' || 'off' || 'no':
      return false;
  }
  throw CtlFailure.badRequest('值必须是布尔（true / false），收到「$raw」');
}

/// 数值设置值：解析 + 整数约束 + 范围校验（越界给 400，不静默夹取）。
num parseCtlSettingNumber(
  String raw, {
  required bool integer,
  num? min,
  num? max,
}) {
  final String text = raw.trim();
  final num? parsed = integer ? int.tryParse(text) : num.tryParse(text);
  if (parsed == null || (parsed is double && !parsed.isFinite)) {
    throw CtlFailure.badRequest('值必须是${integer ? '整数' : '数字'}，收到「$raw」');
  }
  if (min != null && parsed < min) {
    throw CtlFailure.badRequest('值 $parsed 小于下限 $min');
  }
  if (max != null && parsed > max) {
    throw CtlFailure.badRequest('值 $parsed 大于上限 $max');
  }
  return parsed;
}

/// 分段 / 单选项值在 CLI 上的名字：枚举取 `.name`，其余取 `toString()`。
String ctlSettingOptionToken(Object value) =>
    value is Enum ? value.name : '$value';

/// 在单选项里找 [raw]：先精确匹配 token，再大小写无关匹配 token，最后匹配展示
/// 标签。找不到给 400 并列出可选值。
int indexOfCtlSettingOption(
  String raw, {
  required List<String> tokens,
  required List<String> labels,
}) {
  final String needle = raw.trim();
  int index = tokens.indexOf(needle);
  if (index >= 0) return index;
  final String lower = needle.toLowerCase();
  index = tokens.indexWhere((String token) => token.toLowerCase() == lower);
  if (index >= 0) return index;
  index = labels.indexWhere((String label) => label.toLowerCase() == lower);
  if (index >= 0) return index;
  throw CtlFailure.badRequest('「$raw」不是可选值；可选：${tokens.join(' | ')}');
}

/// 模块 id：接受枚举名（大小写无关，`browserExtension` / `browser-extension` /
/// `browser_extension` 都行）或持久化键（`module_downloads_enabled`）。
ModuleId? parseCtlModuleId(String raw) {
  final String needle = raw.trim();
  final String folded = needle.replaceAll(RegExp(r'[-_]'), '').toLowerCase();
  for (final ModuleId id in ModuleId.values) {
    if (id.prefKey == needle) return id;
    if (id.name.toLowerCase() == folded) return id;
  }
  return null;
}

/// `--kind` → 活动域值（`StatFact.mediaKind`）。null = 全部域。
///
/// 事实表只有 book / video / game 三域；听书计入阅读域（有声书同步阅读写的是
/// 同一本书的段），没有独立的「listen」口径，故给 400 而不是另算一套。
String? ctlStatMediaKindOf(String? raw) {
  switch (raw?.trim().toLowerCase()) {
    case null || '' || 'all':
      return null;
    case 'read' || 'book':
      return kActivityMediaBook;
    case 'watch' || 'video':
      return kActivityMediaVideo;
    case 'game':
      return kActivityMediaGame;
    case 'listen':
      throw const CtlFailure.badRequest('统计事实表没有独立的听书域：听书计入阅读（--kind read）');
  }
  throw CtlFailure.badRequest('--kind 只能是 read / watch / game，收到「$raw」');
}

/// 活动域值 → CLI 名字。
String ctlStatKindName(String mediaKind) => switch (mediaKind) {
  kActivityMediaBook => 'read',
  kActivityMediaVideo => 'watch',
  kActivityMediaGame => 'game',
  _ => mediaKind,
};

/// 人读时长：`1h05m` / `12m30s` / `45s`。
String formatCtlDuration(int ms) {
  final int totalSeconds = ms ~/ 1000;
  final int hours = totalSeconds ~/ 3600;
  final int minutes = (totalSeconds % 3600) ~/ 60;
  final int seconds = totalSeconds % 60;
  if (hours > 0) return '${hours}h${minutes.toString().padLeft(2, '0')}m';
  if (minutes > 0) return '${minutes}m${seconds.toString().padLeft(2, '0')}s';
  return '${seconds}s';
}

/// 一组日面事实的合计。
class CtlStatTotals {
  int ms = 0;
  int chars = 0;
  int pages = 0;
  final Set<String> days = <String>{};

  void add(StatFact fact) {
    ms += fact.ms;
    chars += fact.chars;
    pages += fact.pages;
    if (fact.ms > 0 || fact.chars > 0 || fact.pages > 0) days.add(fact.dateKey);
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'ms': ms,
    'duration': formatCtlDuration(ms),
    'chars': chars,
    'pages': pages,
    'activeDays': days.length,
  };
}

/// 统计摘要：只吃**日面**事实（`StatFacts.daily`，日面与小时面不得并起来求和），
/// 按 [inWindow]（由 `StatWindow` 给出的 dateKey 谓词）与 [mediaKind] 过滤后，
/// 出合计 / 按域 / 按条目前 [topN]。
Map<String, Object?> summarizeCtlStatFacts(
  Iterable<StatFact> daily, {
  required bool Function(String dateKey) inWindow,
  String? mediaKind,
  int topN = 10,
}) {
  final CtlStatTotals totals = CtlStatTotals();
  final Map<String, CtlStatTotals> byKind = <String, CtlStatTotals>{};
  final Map<String, CtlStatTotals> byMedia = <String, CtlStatTotals>{};
  final Map<String, StatFact> mediaSample = <String, StatFact>{};
  for (final StatFact fact in daily) {
    if (mediaKind != null && fact.mediaKind != mediaKind) continue;
    if (!inWindow(fact.dateKey)) continue;
    totals.add(fact);
    byKind.putIfAbsent(fact.mediaKind, CtlStatTotals.new).add(fact);
    final String mediaId = '${fact.mediaKind}\u0000${fact.identityKey}';
    byMedia.putIfAbsent(mediaId, CtlStatTotals.new).add(fact);
    mediaSample.putIfAbsent(mediaId, () => fact);
  }
  final List<MapEntry<String, CtlStatTotals>> ranked = byMedia.entries.toList()
    ..sort((
      MapEntry<String, CtlStatTotals> a,
      MapEntry<String, CtlStatTotals> b,
    ) {
      final int byMs = b.value.ms.compareTo(a.value.ms);
      return byMs != 0 ? byMs : b.value.chars.compareTo(a.value.chars);
    });
  return <String, Object?>{
    'totals': totals.toJson(),
    'byKind': <String, Object?>{
      for (final MapEntry<String, CtlStatTotals> e in byKind.entries)
        ctlStatKindName(e.key): e.value.toJson(),
    },
    'topMedia': <Map<String, Object?>>[
      for (final MapEntry<String, CtlStatTotals> e in ranked.take(topN))
        <String, Object?>{
          'kind': ctlStatKindName(mediaSample[e.key]!.mediaKind),
          'mediaKey': mediaSample[e.key]!.mediaKey,
          'title': mediaSample[e.key]!.title,
          ...e.value.toJson(),
        },
    ],
  };
}

/// 会话流的一行应答（`StatFacts.sessions` 派生视图，不另算）。
Map<String, Object?> ctlStudySessionJson(StudySession session) =>
    <String, Object?>{
      'kind': ctlStatKindName(session.mediaKind),
      'mediaKey': session.mediaKey,
      'title': session.title.isEmpty ? session.mediaKey : session.title,
      'format': session.format,
      'deviceId': session.deviceId,
      'startAt': session.startAt,
      'endAt': session.endAt,
      'start': _formatLocalMinute(session.startAt),
      'durationMs': session.durationMs,
      'duration': formatCtlDuration(session.durationMs),
      'chars': session.chars,
      'pages': session.pages,
    };

String _formatLocalMinute(int epochMs) {
  final DateTime t = DateTime.fromMillisecondsSinceEpoch(epochMs);
  String two(int v) => v.toString().padLeft(2, '0');
  return '${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}';
}
