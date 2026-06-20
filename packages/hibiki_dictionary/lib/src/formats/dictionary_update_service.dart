import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;

/// TODO-609：在线 revision 比对手动更新词典——纯 Dart 层（零 C++/FFI/schema）。
///
/// C++ importer 把完整 yomitan index.json（含 revision/isUpdatable/indexUrl/
/// downloadUrl，见 native/.../yomitan_parser.hpp:8 + importer.cpp:1146 的
/// `glz::write_json(index, ...)`）写回 `<resourceDir>/<词典名>/index.json`。本函数
/// 在导入成功后读回该文件，把来源信息提取成 [Dictionary.metadata] 用的弱类型 Map
/// （只填**存在且非空**的字段），从而无需任何 Drift schema 迁移即可持久化来源。
///
/// 健壮性：坏 JSON / 缺文件 / 顶层非对象 → 返回空 Map（绝不抛、不崩）。旧词典或
/// 本地导入词典 metadata 因此为空 → [Dictionary.isUpdatable] 三条件不满足 → 不可更新。
Map<String, String> readSourceMetadataFromIndex(Directory finalDir) {
  final File indexFile = File(path.join(finalDir.path, 'index.json'));
  if (!indexFile.existsSync()) return <String, String>{};

  final dynamic decoded;
  try {
    decoded = jsonDecode(indexFile.readAsStringSync());
  } catch (_) {
    return <String, String>{};
  }
  if (decoded is! Map) return <String, String>{};

  final Map<String, String> out = <String, String>{};

  void putString(String key) {
    final dynamic v = decoded[key];
    if (v is String) {
      final String trimmed = v.trim();
      if (trimmed.isNotEmpty) out[key] = trimmed;
    }
  }

  putString('revision');
  putString('indexUrl');
  putString('downloadUrl');

  // isUpdatable 是 bool；落成字符串 'true'/'false' 与 Dictionary.isUpdatable 的
  // `metadata['isUpdatable'] == 'true'` 判据对齐。缺字段则不落 key。
  final dynamic updatable = decoded['isUpdatable'];
  if (updatable is bool) {
    out['isUpdatable'] = updatable ? 'true' : 'false';
  }

  return out;
}

/// TODO-609：在线更新检查——拉远端 index.json 比 revision。
class DictionaryUpdateService {
  const DictionaryUpdateService();
}
