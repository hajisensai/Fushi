import 'dart:convert';

/// 合集 wire 身份。互联在线漫画沿用描述符中的原始远端书键；本地哈希只用于存储。
/// 不解释其它运行时或无效描述符，避免把普通书错误映射到远端条目。
String collectionBookWireKey({
  required String bookKey,
  String? sourceMetadata,
}) {
  if (sourceMetadata == null) return bookKey;
  try {
    final Object? value = jsonDecode(sourceMetadata);
    if (value is! Map<String, dynamic> ||
        value['type'] != 'hibiki-online-manga' ||
        (value['version'] != 2 && value['version'] != 3) ||
        value['runtime'] != 'interconnect' ||
        value['extensionPackage'] != 'fushi.interconnect' ||
        value['sourceId'] != 'library') {
      return bookKey;
    }
    final Object? series = value['series'];
    if (series is Map<String, dynamic>) {
      final Object? key = series['key'];
      if (key is String && key.isNotEmpty) return key;
    }
  } on FormatException {
    // 旧的非 JSON 来源元数据仍按本地 bookKey 发布。
  }
  return bookKey;
}
