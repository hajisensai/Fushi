import 'dart:convert';

/// 在线小说书（LNReader 插件，`EpubBooks.sourceMetadata` 里的描述符）的类型标记。
///
/// 描述符本体（插件 id / 作品路径 / 章节列表）归 app 侧
/// `LnReaderOnlineBookDescriptor` 解析；引擎只需要认出「这是一本在线书」，所以
/// 标记与判据放在这里，两侧共用同一个常量。
const String kLnReaderOnlineBookMarker = 'fushi-lnreader-online';

/// [sourceMetadata] 是否在线小说书的描述符。
///
/// 在线书的解压树只有取过的章是正文，其余是占位页；描述符在书行里，不随 EPUB
/// 内容包走。
/// 把它当普通 EPUB 打包外传（互联推送 / host 导出 / 云盘上传），对端收到的是一本
/// 永远补不全的书——没取过的章停在占位文案，也没有描述符可再取。所以所有 EPUB
/// 内容外传都先问这里，命中就跳过（与在线漫画的 `hasExportableMangaContent` 同一
/// 口径：元数据占位不等于可外传的内容）。
bool isLnReaderOnlineBookMetadata(String? sourceMetadata) {
  if (sourceMetadata == null ||
      !sourceMetadata.contains(kLnReaderOnlineBookMarker)) {
    return false;
  }
  try {
    final Object? decoded = jsonDecode(sourceMetadata);
    return decoded is Map<String, Object?> &&
        decoded['type'] == kLnReaderOnlineBookMarker;
  } on FormatException {
    return false;
  }
}
