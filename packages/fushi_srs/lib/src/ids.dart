/// 确定性 ID 规则（铁律 C，含第六轮审查第 7、8 条的修正）。
///
/// 凡是「多台设备可能各自独立创建出同一个东西」的实体，ID 一律由来源标识确定性派生（UUIDv5），
/// 合并后自然是同一行；用户在某台设备上主动新建的事件（复习日志、修改记录以外的新牌组等）用 UUIDv7。
///
/// **所有派生函数只依赖参数，不读本机状态**（铁律 C「算出来的 ID 和本机状态无关」）。
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// Fushi SRS 固定命名空间。冻结：改它等于让所有确定性 ID 重生成。
const String srsNamespace = '6f1c8a2e-4b7d-5e3f-9a10-2d4c6e8f0b13';

final Random _secureRandom = Random.secure();

Uint8List _uuidBytes(String uuid) {
  final String hex = uuid.replaceAll('-', '');
  if (hex.length != 32) {
    throw FormatException('not a uuid: $uuid');
  }
  final Uint8List out = Uint8List(16);
  for (int i = 0; i < 16; i++) {
    out[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

String _formatUuid(List<int> bytes) {
  final StringBuffer sb = StringBuffer();
  for (int i = 0; i < 16; i++) {
    if (i == 4 || i == 6 || i == 8 || i == 10) sb.write('-');
    sb.write(bytes[i].toRadixString(16).padLeft(2, '0'));
  }
  return sb.toString();
}

/// RFC 9562 UUIDv5（SHA-1，名字按 UTF-8）。
String uuidV5(String namespace, String name) {
  final List<int> digest = sha1.convert(<int>[
    ..._uuidBytes(namespace),
    ...utf8.encode(name),
  ]).bytes;
  final List<int> b = digest.sublist(0, 16);
  b[6] = (b[6] & 0x0f) | 0x50;
  b[8] = (b[8] & 0x3f) | 0x80;
  return _formatUuid(b);
}

/// RFC 9562 UUIDv7（毫秒时间戳 + 随机）。[nowMs] 注入便于测试。
String uuidV7({int? nowMs, Random? random}) {
  final int ms = nowMs ?? DateTime.now().millisecondsSinceEpoch;
  final Random r = random ?? _secureRandom;
  final List<int> b = List<int>.filled(16, 0);
  for (int i = 0; i < 6; i++) {
    b[i] = (ms >> (8 * (5 - i))) & 0xff;
  }
  for (int i = 6; i < 16; i++) {
    b[i] = r.nextInt(256);
  }
  b[6] = (b[6] & 0x0f) | 0x70;
  b[8] = (b[8] & 0x3f) | 0x80;
  return _formatUuid(b);
}

const int _max53 = 0x1FFFFFFFFFFFFF;

/// 由字符串确定性派生 53 位正整数（Anki 的数字 id / ankiNum）。
int hash53(String input) {
  final List<int> d = sha256.convert(utf8.encode(input)).bytes;
  int v = 0;
  for (int i = 0; i < 7; i++) {
    v = (v << 8) | d[i];
  }
  v &= _max53;
  return v == 0 ? 1 : v;
}

/// 新建时随机的 53 位正整数（Fushi 新建的笔记类型 / 字段 / 模板的 ankiNum）。
int randomAnkiNum({Random? random}) {
  final Random r = random ?? _secureRandom;
  int v = 0;
  for (int i = 0; i < 7; i++) {
    v = (v << 8) | r.nextInt(256);
  }
  v &= _max53;
  return v == 0 ? 1 : v;
}

const String _guidAlphabet =
    'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!#\$%&()*+,-./:;<=>?@[]^_`{|}~';

/// Anki 格式的随机 guid（base91，10 位）。Fushi 新建笔记时生成，之后永不改变。
String newNoteGuid({Random? random}) {
  final Random r = random ?? _secureRandom;
  return String.fromCharCodes(
    List<int>.generate(
      10,
      (_) => _guidAlphabet.codeUnitAt(r.nextInt(_guidAlphabet.length)),
    ),
  );
}

/// 铁律 C 的规则表。
abstract final class SrsIds {
  /// 笔记：noteId = UUIDv5(NS, profileUid/note/guid)。Fushi 自建与 Anki 导入同一条规则。
  static String note(String profileUid, String guid) =>
      uuidV5(srsNamespace, '$profileUid/note/$guid');

  /// 笔记类型：noteTypeId = UUIDv5(NS, profileUid/notetype/ankiNum)。
  /// 内置笔记类型也走这一条（第六轮审查第 8 条）：它们的 ankiNum 是固定常量 [builtinNoteTypeAnkiNum]，
  /// 导出到 Anki 再导回来，派生出的仍是同一个 ID。
  static String noteType(String profileUid, int ankiNum) =>
      uuidV5(srsNamespace, '$profileUid/notetype/$ankiNum');

  /// 字段：fieldId = UUIDv5(noteTypeId, field/ankiNum)。
  static String field(String noteTypeId, int ankiNum) =>
      uuidV5(noteTypeId, 'field/$ankiNum');

  /// 模板：templateId = UUIDv5(noteTypeId, template/ankiNum)。
  static String template(String noteTypeId, int ankiNum) =>
      uuidV5(noteTypeId, 'template/$ankiNum');

  /// 来源文件里某个字段没有 config.id 时的回退：**只按名字的纯函数**，不看本机已有项
  /// （第六轮审查第 7 条：「先按名字匹配本机已有项」会让 ID 依赖本机状态）。
  /// 之后这个字段带上 ankiNum 时，只把 ankiNum 记成它的别名属性，ID 不换。
  static String fieldByName(String noteTypeId, String name) =>
      uuidV5(noteTypeId, 'field-name/$name');

  /// 同上，模板按名字的回退。
  static String templateByName(String noteTypeId, String name) =>
      uuidV5(noteTypeId, 'template-name/$name');

  /// 卡片：cardId = UUIDv5(noteId, templateId/clozeOrd)。普通模板 clozeOrd = 0。
  static String card(String noteId, String templateId, int clozeOrd) =>
      uuidV5(noteId, '$templateId/$clozeOrd');

  /// 牌组：UUIDv5(NS, profileUid/deck/<规范全名>)，全名按「父::子」，每段去首尾空白。
  ///
  /// 两台设备离线各建（或各导入）同名牌组，合并后是同一个牌组（与 Anki 按名字合并牌组一致）。
  /// 改名不改 ID；之后有人再按旧名新建，会落到同一个 ID（行被复活并改回该名字），这是按名字认身份的代价。
  static String deck(String profileUid, String fullPath) =>
      uuidV5(srsNamespace, '$profileUid/deck/${normalizeDeckPath(fullPath)}');

  static String normalizeDeckPath(String fullPath) => fullPath
      .split('::')
      .map((String s) => s.trim())
      .where((String s) => s.isNotEmpty)
      .join('::');

  /// 内置默认牌组。
  static String builtinDefaultDeck(String profileUid) =>
      uuidV5(srsNamespace, '$profileUid/builtin-deck/default');

  /// 内置笔记类型（例如 'lapis'）的固定 ankiNum。
  static int builtinNoteTypeAnkiNum(String key) =>
      hash53('fushi/builtin-notetype/$key');

  /// 内置笔记类型字段的固定 ankiNum（<fieldKey> = LapisNoteType 的字段键）。
  static int builtinFieldAnkiNum(String noteTypeKey, String fieldKey) =>
      hash53('fushi/builtin-notetype/$noteTypeKey/field/$fieldKey');

  /// 内置笔记类型模板的固定 ankiNum。
  static int builtinTemplateAnkiNum(String noteTypeKey, String templateKey) =>
      hash53('fushi/builtin-notetype/$noteTypeKey/template/$templateKey');

  /// 从 Anki 导入的 revlog：UUIDv5(cardId, anki-revlog/<revlog id>)。
  static String importedRevlog(String cardId, int ankiRevlogId) =>
      uuidV5(cardId, 'anki-revlog/$ankiRevlogId');

  /// 导入锚点：UUIDv5(cardId, anki-anchor/<T>)。
  static String importAnchor(String cardId, int anchorMs) =>
      uuidV5(cardId, 'anki-anchor/$anchorMs');

  /// fushi-ext 导入到另一个 profile 时日志 ID 的重映射。
  /// **revokesId 必须用同一个函数一起重映射**（第六轮审查「小问题」），否则撤销关系断开。
  static String remappedLog(String newCardId, String originalLogId) =>
      uuidV5(newCardId, 'fushi-log/$originalLogId');

  /// 修改记录的 ID 由 dot 决定：同一个 (writerId, seq) 只可能是同一条记录。
  static String fieldEdit(String writerId, int seq) =>
      uuidV5(srsNamespace, 'edit/$writerId/$seq');

  /// 导出到 Anki 的笔记 / 卡片数字 id。
  static int ankiNumericId(String uuid) => hash53('anki-id/$uuid');
}
