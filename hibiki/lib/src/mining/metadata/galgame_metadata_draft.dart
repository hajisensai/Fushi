/// galgame 在线元数据的**统一中间表示**（契约 §2.1）与搜索候选项。
///
/// 各数据源 adapter 把自家 JSON 映射成 [GalgameMetadataDraft]，之后的合并（§2.4）、
/// 落库（`galgame_sources.dataJson`）、展示全部只认这一种形状——加数据源不影响下游。
library;

import 'dart:convert';

import 'package:fushi/src/mining/metadata/galgame_metadata_source.dart';

/// 单个数据源抓到的一份元数据快照。
///
/// 标量字段全部 nullable，「缺就是缺」；**列表字段用空表代替 null**（刻意偏离「全字段
/// nullable」：null 与空表在合并、展示、序列化里语义完全一致，留两种空状态只会逼下游到处
/// 写 `?? const []`）。
class GalgameMetadataDraft {
  const GalgameMetadataDraft({
    this.name,
    this.nameCn,
    this.aliases = const <String>[],
    this.allTitles = const <String>[],
    this.summary,
    this.tags = const <String>[],
    this.developer,
    this.releaseDate,
    this.score,
    this.rank,
    this.nsfw,
    this.averageHours,
    this.coverUrl,
    this.externalId,
  });

  /// 原名（bgm 的 `name` / vndb 的 main title）。
  final String? name;

  /// 中文名（bgm 的 `name_cn` / vndb `titles` 里 `lang == zh-Hans` 的那条）。
  final String? nameCn;

  /// 别名列表（去重保序）。
  final List<String> aliases;

  /// 全部已知标题（各语言官方标题），供搜索匹配用；去重保序。
  final List<String> allTitles;

  /// 简介原文（不做 markup 清洗，展示层自行处理）。
  final String? summary;

  /// 标签（已按源侧热度/评分排序并截断）。
  final List<String> tags;

  /// 开发商；多开发商用 `, ` 连接。
  final String? developer;

  /// 发行日期，`YYYY-MM-DD`；源侧只给到年或年月时不落（宁缺毋滥，排序列要能比较）。
  final String? releaseDate;

  /// 站点评分，**统一归一到 0-10**（vndb 原始 0-100 由 adapter 折算）。
  final double? score;

  /// 站点排名（目前只有 bgm 有）。
  final int? rank;

  /// 是否成人向；源侧未提供则为 null（不等于 false）。
  final bool? nsfw;

  /// 平均通关时长（小时，目前只有 vndb 有）。
  final double? averageHours;

  /// 封面图 URL。
  final String? coverUrl;

  /// 该源的外部 ID（bgm subject id / vndb `v12345`）。合并结果无单一外部 ID，为 null。
  final String? externalId;

  /// 是否一个字段都没有（adapter 拿到空壳响应时用于判定「等于没抓到」）。
  bool get isEmpty =>
      name == null &&
      nameCn == null &&
      aliases.isEmpty &&
      allTitles.isEmpty &&
      summary == null &&
      tags.isEmpty &&
      developer == null &&
      releaseDate == null &&
      score == null &&
      rank == null &&
      nsfw == null &&
      averageHours == null &&
      coverUrl == null;

  /// 序列化为 `galgame_sources.dataJson` 的内容。null 字段直接省略，避免存一堆 null。
  Map<String, Object?> toJson() {
    final Map<String, Object?> json = <String, Object?>{};
    void put(String key, Object? value) {
      if (value != null) {
        json[key] = value;
      }
    }

    put('name', name);
    put('nameCn', nameCn);
    if (aliases.isNotEmpty) json['aliases'] = aliases;
    if (allTitles.isNotEmpty) json['allTitles'] = allTitles;
    put('summary', summary);
    if (tags.isNotEmpty) json['tags'] = tags;
    put('developer', developer);
    put('releaseDate', releaseDate);
    put('score', score);
    put('rank', rank);
    put('nsfw', nsfw);
    put('averageHours', averageHours);
    put('coverUrl', coverUrl);
    put('externalId', externalId);
    return json;
  }

  /// 从持久化 map 容错解析：类型不对的字段一律降级为 null / 空表，**绝不抛**。
  static GalgameMetadataDraft fromJson(Map<Object?, Object?> json) {
    return GalgameMetadataDraft(
      name: draftString(json['name']),
      nameCn: draftString(json['nameCn']),
      aliases: draftStringList(json['aliases']),
      allTitles: draftStringList(json['allTitles']),
      summary: draftString(json['summary']),
      tags: draftStringList(json['tags']),
      developer: draftString(json['developer']),
      releaseDate: draftDate(json['releaseDate']),
      score: draftDouble(json['score']),
      rank: draftInt(json['rank']),
      nsfw: draftBool(json['nsfw']),
      averageHours: draftDouble(json['averageHours']),
      coverUrl: draftString(json['coverUrl']),
      externalId: draftString(json['externalId']),
    );
  }

  /// 从 JSON 字符串解析；空串 / 非法 JSON / 非对象 → 空 draft（与偏好层同款容错策略）。
  static GalgameMetadataDraft decode(String raw) {
    if (raw.trim().isEmpty) {
      return const GalgameMetadataDraft();
    }
    try {
      final Object? decoded = jsonDecode(raw);
      if (decoded is! Map) {
        return const GalgameMetadataDraft();
      }
      return fromJson(Map<Object?, Object?>.from(decoded));
    } catch (_) {
      return const GalgameMetadataDraft();
    }
  }

  /// 序列化成字符串（`galgame_sources.dataJson` 直接写这个）。
  String encode() => jsonEncode(toJson());

  @override
  String toString() =>
      'GalgameMetadataDraft(${externalId ?? '-'}: ${nameCn ?? name ?? '-'})';
}

/// 搜索结果里的一条候选（`GalgameSourcePickerDialog` 展示用）。
///
/// 只带**够用户选中**的信息；选中后由 `fetchById` 补全成完整 draft（契约 §2.5）。
class SourceCandidate {
  const SourceCandidate({
    required this.source,
    required this.externalId,
    this.name,
    this.nameCn,
    this.coverUrl,
    this.releaseDate,
    this.summary,
  });

  /// 候选来自哪个源。**契约 §2.1 未列此字段**，这里补上：mixed 搜索会把多个源的候选混进
  /// 同一个列表，没有来源就无法回查 adapter。
  final GalgameMetadataSource source;

  /// 该源的外部 ID，选中后据此 `fetchById`。
  final String externalId;

  /// 原名。
  final String? name;

  /// 中文名。
  final String? nameCn;

  /// 缩略封面 URL。
  final String? coverUrl;

  /// 发行日期 `YYYY-MM-DD`（不完整则为 null）。
  final String? releaseDate;

  /// 简介**摘要**（已截断，见 [summaryExcerpt]）。
  final String? summary;

  /// 列表主标题：中文名优先，其次原名，都没有就退回外部 ID。
  String get displayName => nameCn ?? name ?? externalId;

  @override
  String toString() =>
      'SourceCandidate(${source.key}:$externalId $displayName)';
}

/// 候选摘要最大字符数（按 rune 计，避免截断代理对）。
const int kSourceCandidateSummaryRunes = 200;

/// 把简介截成候选摘要：超长截断并加省略号；空 / 全空白 → null。纯函数。
String? summaryExcerpt(Object? value,
    {int maxRunes = kSourceCandidateSummaryRunes}) {
  final String? text = draftString(value);
  if (text == null) {
    return null;
  }
  final List<String> runes = text.runes.map(String.fromCharCode).toList();
  if (runes.length <= maxRunes) {
    return text;
  }
  return '${runes.take(maxRunes).join()}…';
}

/// 容错取非空字符串：非 String / 去空白后为空 → null。
String? draftString(Object? value) {
  if (value is! String) {
    return null;
  }
  final String trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}

/// 容错取字符串列表：非 List → 空表；元素取非空字符串并**去重保序**。
List<String> draftStringList(Object? value) {
  if (value is! List) {
    return const <String>[];
  }
  final List<String> out = <String>[];
  final Set<String> seen = <String>{};
  for (final Object? item in value) {
    final String? text = draftString(item);
    if (text != null && seen.add(text)) {
      out.add(text);
    }
  }
  return out;
}

/// 容错取 double（接受 num 或数字字符串），非有限值（NaN / Infinity）→ null。
double? draftDouble(Object? value) {
  double? parsed;
  if (value is num) {
    parsed = value.toDouble();
  } else if (value is String) {
    parsed = double.tryParse(value.trim());
  }
  if (parsed == null || !parsed.isFinite) {
    return null;
  }
  return parsed;
}

/// 容错取 int（接受 int / num / 数字字符串）。
int? draftInt(Object? value) {
  if (value is int) {
    return value;
  }
  if (value is num) {
    return value.isFinite ? value.toInt() : null;
  }
  if (value is String) {
    return int.tryParse(value.trim());
  }
  return null;
}

/// 容错取 bool（接受 bool / 0-1 / `'true'` `'false'`）。
bool? draftBool(Object? value) {
  if (value is bool) {
    return value;
  }
  if (value is num) {
    return value != 0;
  }
  if (value is String) {
    final String v = value.trim().toLowerCase();
    if (v == 'true' || v == '1') return true;
    if (v == 'false' || v == '0') return false;
  }
  return null;
}

/// 只认完整 `YYYY-MM-DD`（且月日在合法范围）：源侧常给 `2013`、`2013-05`、`TBA`、
/// `unknown`，这些不落列——`releaseDate` 要拿去做 SQL 排序，半截日期会排出鬼来。
String? draftDate(Object? value) {
  final String? raw = draftString(value);
  if (raw == null) {
    return null;
  }
  final RegExpMatch? m = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(raw);
  if (m == null) {
    return null;
  }
  final int month = int.parse(m.group(2)!);
  final int day = int.parse(m.group(3)!);
  if (month < 1 || month > 12 || day < 1 || day > 31) {
    return null;
  }
  return raw;
}
