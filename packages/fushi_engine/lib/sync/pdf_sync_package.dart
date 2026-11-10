import 'dart:io';
import 'dart:typed_data';

import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;

/// PDF 书的互联内容通道（反馈 Jq1_ujHa4t：安卓经互联看不到 Windows 上导入的 PDF）。
///
/// **包 = PDF 原件本身**：PDF 导入时被原样拷进书目录（`<extractDir>/<epubPath>`，
/// 当代写入方恒为 `document.pdf`），没有解压树，也就不需要像 EPUB / 漫画那样重打包。
/// 与 EPUB / 漫画包走**同一个** books 传输端点，接收方按 [isPdfFile] 内容嗅探分流
/// （内容即真相，扩展名不参与判定），零新端点。
///
/// 向后兼容：清单里 PDF 的 `hasContent` 仍恒 false（旧 client 不认 PDF，看不到就
/// 不会拿 EpubImporter 去吃它），新 additive 字段 `hasPdfContent` 只有新 client 消费；
/// client → host 推 PDF 只在 host 于 `/api/capabilities` 显式声明能收时才发
/// （[kLiveLibraryPdfBooksCapability]）——无头服务端没有 PDF 渲染引擎、收不了。
const String kLiveLibraryPdfBooksCapability = 'pdfBooks';

/// PDF 文件头魔数。规范允许头部前有少量垃圾字节（在前 1024 字节内出现即可），
/// 各家阅读器都按这个宽限认。
const String _kPdfMagic = '%PDF-';

/// 头部魔数的搜索窗口（字节）。
const int _kPdfMagicWindow = 1024;

/// PDF 书主文件的绝对路径（`extractDir/epubPath`）——与 app 侧 `bookMainFilePath`
/// 的 PDF 分支同一口径（那里直接调本函数）。
String pdfBookFilePath(EpubBookRow row) => p.join(row.extractDir, row.epubPath);

/// 这本书能不能经互联通道导出为 PDF：格式是 PDF 且原件此刻在盘上（非空）。
/// 清单的 `hasPdfContent`、导出端点、client 推送与书架下载复用判据共用这一条。
bool hasExportablePdfContent(EpubBookRow row) {
  if (BookFormat.parseOrEpub(row.format) != BookFormat.pdf) return false;
  if (row.extractDir.isEmpty || row.epubPath.isEmpty) return false;
  try {
    final File file = File(pdfBookFilePath(row));
    return file.existsSync() && file.lengthSync() > 0;
  } on FileSystemException {
    return false;
  }
}

/// 嗅探 [file] 是不是 PDF（前 [_kPdfMagicWindow] 字节内出现 `%PDF-`）。
///
/// 只读头部一小段，不整文件进内存。读失败（文件不存在 / 无权限）返回 false，
/// 调用方按非 PDF 处理，由下游导入器的既有失败路径如实报错。
Future<bool> isPdfFile(File file) async {
  RandomAccessFile? raf;
  try {
    raf = await file.open();
    final Uint8List head = await raf.read(_kPdfMagicWindow);
    return containsPdfMagic(head);
  } on FileSystemException {
    return false;
  } finally {
    await raf?.close();
  }
}

/// [head] 里是否出现 PDF 魔数 `%PDF-`（纯函数，供 [isPdfFile] 与单测用）。
bool containsPdfMagic(List<int> head) {
  final List<int> magic = _kPdfMagic.codeUnits;
  final int last = head.length - magic.length;
  for (int i = 0; i <= last; i++) {
    bool hit = true;
    for (int j = 0; j < magic.length; j++) {
      if (head[i + j] != magic[j]) {
        hit = false;
        break;
      }
    }
    if (hit) return true;
  }
  return false;
}

/// 从 `/api/capabilities` 解码结果读 host 能否接收推来的 PDF 书
/// （`liveLibrary.pdfBooks`）。老 host / 无头服务端 / 形状不对一律 false。
bool interconnectHostAcceptsPdfBooks(Object? capabilities) {
  if (capabilities is! Map) return false;
  final Object? live = capabilities['liveLibrary'];
  if (live is! Map) return false;
  return live[kLiveLibraryPdfBooksCapability] == true;
}
