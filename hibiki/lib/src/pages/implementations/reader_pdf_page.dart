import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:pdfrx/pdfrx.dart';

import 'package:hibiki_core/hibiki_core.dart';
import 'package:hibiki/media.dart';
import 'package:hibiki/models.dart';
import 'package:hibiki/src/pdf/pdf_engine.dart';
import 'package:hibiki/utils.dart';

/// PDF 阅读器页面（Phase 1）：用 pdfrx 的 [PdfViewer] 真渲染 PDF 页面、上下滚动翻页。
///
/// 本期只做「打开 + 阅读」——不接点选查词（Phase 2）、页码进度保存（Phase 3）、制卡
/// （Phase 4）。这些后续 Phase 在此页内叠加，与 EPUB 的 [ReaderHibikiPage] 平行。
///
/// PDF 的绝对路径由 `EpubBooks` 行还原：`p.join(extractDir, epubPath)`（导入器
/// [PdfImporter] 把 PDF 拷进书目录并把文件名写进 `epubPath`）。
class ReaderPdfPage extends ConsumerStatefulWidget {
  const ReaderPdfPage({
    super.key,
    this.item,
    required this.bookKey,
  });

  final MediaItem? item;
  final String bookKey;

  @override
  ConsumerState<ReaderPdfPage> createState() => _ReaderPdfPageState();
}

class _ReaderPdfPageState extends ConsumerState<ReaderPdfPage> {
  /// 解析 PDF 绝对路径（含 pdfrx 引擎初始化）。null = 书行缺失或磁盘文件不存在。
  late final Future<String?> _pdfPathFuture = _resolvePdfPath();

  Future<String?> _resolvePdfPath() async {
    await PdfEngine.ensureInitialized();
    final HibikiDatabase db = ref.read(appProvider).database;
    final EpubBookRow? row = await db.getEpubBook(widget.bookKey);
    if (row == null) return null;
    final String path = p.join(row.extractDir, row.epubPath);
    if (!File(path).existsSync()) return null;
    return path;
  }

  @override
  Widget build(BuildContext context) {
    final String title = widget.item?.title ?? '';
    return Scaffold(
      appBar: AppBar(
        title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
      body: FutureBuilder<String?>(
        future: _pdfPathFuture,
        builder: (BuildContext context, AsyncSnapshot<String?> snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          final String? path = snapshot.data;
          if (path == null) {
            return Center(child: Text(t.book_file_not_found));
          }
          return PdfViewer.file(
            path,
            params: const PdfViewerParams(
              // Phase 1 只读浏览：默认上下滚动分页，留白背景。查词/进度后续 Phase 叠加。
              backgroundColor: Color(0xFF3A3A3A),
            ),
          );
        },
      ),
    );
  }
}
