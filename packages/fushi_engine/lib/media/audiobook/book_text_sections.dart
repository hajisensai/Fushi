import 'package:fushi_audio/fushi_audio_core.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/audiobook/audiobook_alignment_service.dart'
    show loadEpubSectionsInBackground;

/// 把一本 PDF 书的文本层按页切成匹配器的 [EpubSection]（第 i 页 = section i）。
///
/// PDF 文本层只能经 PDFium（Flutter 插件 pdfrx）读取，引擎不依赖插件，所以由宿主在
/// 启动时注入（app 的 `installEngineHostBindings`）。未注入（`fushi_server` 等无
/// PDFium 的宿主）= 拿不到 PDF 文本：字幕照常落库、只是没有正文高亮定位。
typedef PdfTextSectionsLoader =
    Future<List<EpubSection>> Function(EpubBookRow row);

/// 宿主注入的 PDF 文本层读取器，见 [PdfTextSectionsLoader]。
PdfTextSectionsLoader? pdfTextSectionsLoader;

/// 有声书对齐「拿哪段正文去匹配字幕」的**唯一分派点**：按 [EpubBookRow.format] 取。
///
/// - EPUB：解压书目录逐章纯文本（[loadEpubSectionsInBackground]），section = 章。
/// - PDF：文本层逐页全文（[pdfTextSectionsLoader]），section = 页（0 起）。匹配结果
///   编码进 `AudioCue.textFragmentId` 的 `s=` 就是页码，PDF 阅读器据此跨页跟随、按
///   该页文本层把归一化偏移换回字符矩形高亮。
/// - 漫画：没有可对齐的正文（漫画阅读器不播有声书），恒空。
///
/// 导入对话框、重匹配、ctl 挂字幕与 `alignAndPersistAudiobook` 都只调本函数，不再
/// 各自把 `extractDir` 当 EPUB 目录解析——PDF 行的 `extractDir` 里只有一份
/// `document.pdf`，按 EPUB 解析恒为 0 章。
Future<List<EpubSection>> loadBookTextSectionsForRow(EpubBookRow row) {
  switch (BookFormat.parseOrEpub(row.format)) {
    case BookFormat.epub:
      return loadEpubSectionsInBackground(row.extractDir);
    case BookFormat.pdf:
      final PdfTextSectionsLoader? loader = pdfTextSectionsLoader;
      if (loader == null) {
        return Future<List<EpubSection>>.value(const <EpubSection>[]);
      }
      return loader(row);
    case BookFormat.manga:
      return Future<List<EpubSection>>.value(const <EpubSection>[]);
  }
}

/// 按 bookKey 读书行后走 [loadBookTextSectionsForRow]；书架上没有这本书 = 无正文。
Future<List<EpubSection>> loadBookTextSections(
  FushiDatabase db,
  String bookKey,
) async {
  final EpubBookRow? row = await db.getEpubBook(bookKey);
  if (row == null) return const <EpubSection>[];
  return loadBookTextSectionsForRow(row);
}
