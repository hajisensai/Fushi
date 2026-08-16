/// 用户词典（可视化编辑）的领域逻辑。
///
/// 数据结构决定一切：已导入词典是只读二进制（blobs.bin + 定容哈希表，mmap
/// 只读），不存在「就地改一条」的写路径。所以用户词典的真相源是偏好里的一份
/// 词条列表（[userDictionaryEntriesPrefKey]，JSON），可视化编辑器改的是这份
/// 列表；每次保存后把整份列表编译成标准 Yomitan zip，走**现有导入链**
/// （`AppModel.importDictionary` + `forceReplaceExisting`）整部重建并重挂。
/// 词典目录只是编译产物——编辑、备份、同步都只面对词条列表，二进制格式的
/// 特殊情况在这一层整个消失。
///
/// 词条 `rules` 恒为空串：用户手写的词头不参与去屈折规则匹配（`*` 会让
/// BUG-729 的活用误命中形状重现），查得到的就是用户写下的原形。
library;

import 'dart:convert';

import 'package:archive/archive.dart';

/// 用户词典在引擎/词典列表里的固定标题（同时是磁盘目录名与 Drift 元数据主
/// 键）。身份必须跨语言稳定，故为常量而非 i18n 文案；编辑器页标题才走 i18n。
const String userDictionaryTitle = 'User Dictionary';

/// 偏好键：用户词典词条列表（JSON 数组）。
const String userDictionaryEntriesPrefKey = 'user_dictionary_entries';

/// 一条用户词典词条。不可变；编辑 = 整条替换（列表按下标寻址，无独立 id——
/// 词条没有跨会话身份诉求，下标就够，引入 id 只会造出同步/去重特殊情况）。
class UserDictionaryEntry {
  const UserDictionaryEntry({
    required this.expression,
    this.reading = '',
    this.meaning = '',
  });

  factory UserDictionaryEntry.fromJson(Map<String, dynamic> json) {
    return UserDictionaryEntry(
      expression: (json['expression'] ?? '').toString(),
      reading: (json['reading'] ?? '').toString(),
      meaning: (json['meaning'] ?? '').toString(),
    );
  }

  /// 词头。
  final String expression;

  /// 读音（可空；空串在 Yomitan 语义下等同「与词头一致/无读音」）。
  final String reading;

  /// 释义。多行文本；编译时按行拆成 glossary 列表逐行渲染。
  final String meaning;

  Map<String, String> toJson() => <String, String>{
        'expression': expression,
        'reading': reading,
        'meaning': meaning,
      };
}

/// 从偏好原始串解码词条列表。空串/坏 JSON/形状不对一律回空列表（与
/// `customDictCSS` 同款容错——坏数据不该把编辑器炸掉，用户重新保存即自愈）。
List<UserDictionaryEntry> decodeUserDictionaryEntries(String raw) {
  if (raw.isEmpty) return <UserDictionaryEntry>[];
  try {
    final Object? decoded = jsonDecode(raw);
    if (decoded is! List) return <UserDictionaryEntry>[];
    return decoded
        .whereType<Map<String, dynamic>>()
        .map(UserDictionaryEntry.fromJson)
        .where((UserDictionaryEntry e) => e.expression.isNotEmpty)
        .toList();
  } on FormatException {
    return <UserDictionaryEntry>[];
  }
}

/// 编码词条列表为偏好原始串。空列表编码为空串（保持「从未用过」与「清空了」
/// 在偏好层同形，不留空数组残骸）。
String encodeUserDictionaryEntries(List<UserDictionaryEntry> entries) {
  if (entries.isEmpty) return '';
  return jsonEncode(
    entries.map((UserDictionaryEntry e) => e.toJson()).toList(),
  );
}

/// 释义多行文本 → Yomitan glossary 行列表。空白行剔除；全空时回退整段原文，
/// 保证词条只要存在就至少有一条 glossary（native 导入器对空 glossary 词条的
/// 行为不属于我们该依赖的契约）。
List<String> userDictionaryGlossaryLines(String meaning) {
  final List<String> lines = meaning
      .split('\n')
      .map((String line) => line.trim())
      .where((String line) => line.isNotEmpty)
      .toList();
  if (lines.isEmpty) return <String>[meaning];
  return lines;
}

/// 把整份词条列表编译成标准 Yomitan 词典 zip（index.json + term_bank_1.json）。
///
/// 输出喂给现有导入链（与文件导入按钮完全同源），native 侧格式探测、标题清洗、
/// 路径校验、发布、元数据持久化全部复用，不新增任何 native 写路径。
List<int> buildUserDictionaryZipBytes({
  required List<UserDictionaryEntry> entries,
  required String revision,
}) {
  final Map<String, Object> index = <String, Object>{
    'title': userDictionaryTitle,
    'format': 3,
    'revision': revision,
    'sequenced': false,
  };
  final List<List<Object>> terms = <List<Object>>[
    for (int i = 0; i < entries.length; i++)
      <Object>[
        entries[i].expression,
        entries[i].reading,
        '', // definitionTags
        '', // rules：空 = 不参与去屈折（见库注释）
        0, // score
        userDictionaryGlossaryLines(entries[i].meaning),
        i, // sequence
        '', // termTags
      ],
  ];
  final Archive archive = Archive()
    ..addFile(_jsonArchiveFile('index.json', index))
    ..addFile(_jsonArchiveFile('term_bank_1.json', terms));
  return ZipEncoder().encode(archive)!;
}

ArchiveFile _jsonArchiveFile(String name, Object json) {
  final List<int> bytes = utf8.encode(jsonEncode(json));
  return ArchiveFile(name, bytes.length, bytes);
}
