import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/sync/fushi_library_host_service.dart';
import 'package:fushi_engine/sync/fushi_sync_server.dart';
import 'package:fushi_engine/sync/local_library_host_service.dart';
import 'package:fushi_engine/sync/pdf_sync_package.dart';
import 'package:fushi_engine/sync/sync_asset_package_service.dart';
import 'package:path/path.dart' as p;

/// 反馈 Jq1_ujHa4t：安卓经互联看不到 Windows 上导入的 PDF。
///
/// 根因：host 清单对 PDF 没有任何内容位（`hasContent` 是 EPUB 判据，PDF 恒 false），
/// 导出端点对 PDF 直接 404，client 推送也把 PDF 静默跳过——PDF 在互联里整条没有
/// 内容通道。这里钉住新通道的每一段：清单内容位、导出字节、按内容嗅探的导入分流、
/// 能力位协商、wire 字段向后兼容。
void main() {
  // binding 会把 HttpClient 换成恒回 400 的假实现；能力位协商要打真的本机互联
  // server（liveLibraryOf），所以换回真实实现。
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  /// 最小的「看起来像 PDF」的字节：头部魔数 + 一点正文。导出 / 嗅探只认头部，不解析。
  final List<int> pdfBytes = utf8.encode(
    '%PDF-1.7\n%âã\n1 0 obj << /Type /Catalog >> endobj\n%%EOF\n',
  );

  group('pdf_sync_package 判据', () {
    test('containsPdfMagic：头部 / 前 1024 字节内有 %PDF- 才算', () {
      expect(containsPdfMagic(utf8.encode('%PDF-1.4 rest')), isTrue);
      // 规范容许头部前有少量垃圾字节。
      expect(containsPdfMagic(<int>[0xEF, 0xBB, 0xBF, ...pdfBytes]), isTrue);
      // zip（EPUB / 漫画包）头。
      expect(containsPdfMagic(<int>[0x50, 0x4B, 0x03, 0x04, 0, 0]), isFalse);
      // zip 前 1024 字节里的存储条目恰好含 `%PDF-`（如漫画包里未压缩的 json）：仍是 zip。
      expect(
        containsPdfMagic(<int>[
          0x50,
          0x4B,
          0x03,
          0x04,
          ...utf8.encode('%PDF-1.4'),
        ]),
        isFalse,
      );
      expect(containsPdfMagic(utf8.encode('%PDF')), isFalse);
      expect(containsPdfMagic(const <int>[]), isFalse);
    });

    test('isPdfFile：只看内容，不看扩展名；文件不存在为 false', () async {
      final Directory tmp = Directory.systemTemp.createTempSync('pdf_sniff');
      addTearDown(() => tmp.deleteSync(recursive: true));
      // 互联 books 端点的落点文件名恒是 `.epub`。
      final File disguised = File(p.join(tmp.path, 'book.epub'))
        ..writeAsBytesSync(pdfBytes);
      final File zip = File(p.join(tmp.path, 'real.epub'))
        ..writeAsBytesSync(<int>[0x50, 0x4B, 0x03, 0x04, 1, 2, 3]);
      expect(await isPdfFile(disguised), isTrue);
      expect(await isPdfFile(zip), isFalse);
      expect(await isPdfFile(File(p.join(tmp.path, 'missing.pdf'))), isFalse);
    });

    test('interconnectHostAcceptsPdfBooks：只认显式 true', () {
      expect(
        interconnectHostAcceptsPdfBooks(<String, Object?>{
          'liveLibrary': <String, Object?>{'pdfBooks': true},
        }),
        isTrue,
      );
      expect(
        interconnectHostAcceptsPdfBooks(<String, Object?>{
          'liveLibrary': <String, Object?>{'pdfBooks': false},
        }),
        isFalse,
      );
      // 老 host：无字段 / 无 capabilities 端点。
      expect(
        interconnectHostAcceptsPdfBooks(<String, Object?>{
          'liveLibrary': <String, Object?>{'books': true},
        }),
        isFalse,
      );
      expect(interconnectHostAcceptsPdfBooks(null), isFalse);
      expect(interconnectHostAcceptsPdfBooks('garbage'), isFalse);
    });
  });

  group('RemoteBookInfo.hasPdfContent wire', () {
    test('additive：只在 true 时写键，缺键回落 false', () {
      const RemoteBookInfo pdf = RemoteBookInfo(
        title: 'p',
        hasContent: false,
        format: 'pdf',
        hasPdfContent: true,
      );
      final Map<String, Object?> json = pdf.toJson();
      expect(json['hasPdfContent'], isTrue);
      expect(
        json['hasContent'],
        isFalse,
        reason: '旧 client 只认 hasContent，PDF 对它不可见',
      );
      final RemoteBookInfo back = RemoteBookInfo.fromJson(json);
      expect(back.hasPdfContent, isTrue);
      expect(back.hasBookShelfContent, isTrue);
      expect(back.format, 'pdf');

      const RemoteBookInfo epub = RemoteBookInfo(title: 'e', hasContent: true);
      expect(epub.toJson().containsKey('hasPdfContent'), isFalse);
      // 旧 host 的清单行没有这个键。
      final RemoteBookInfo legacy = RemoteBookInfo.fromJson(<String, Object?>{
        'title': 'old-pdf',
        'hasContent': false,
        'format': 'pdf',
      });
      expect(legacy.hasPdfContent, isFalse);
      expect(legacy.hasBookShelfContent, isFalse);
      expect(
        pdf.copyWith(hasPdfContent: false).hasPdfContent,
        isFalse,
        reason: 'copyWith 必须透传该字段',
      );
    });
  });

  group('LocalLibraryHostService PDF 通道', () {
    late FushiDatabase db;
    late Directory tmp;

    setUp(() {
      db = FushiDatabase.forTesting(NativeDatabase.memory());
      tmp = Directory.systemTemp.createTempSync('hbk_host_pdf');
    });

    tearDown(() async {
      await db.close();
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    LocalLibraryHostService service({
      Future<String?> Function(File epubFile)? importBook,
      Future<String?> Function(File pdfFile, String title)? importPdf,
    }) => LocalLibraryHostService(
      db: db,
      dictionaryResourceRoot: Directory.systemTemp,
      packages: SyncAssetPackageService(db: db),
      refreshDictionaryCache: () async {},
      runExclusive: (Future<void> Function() body) => body(),
      importBookFromFile: importBook,
      importPdfBookFromFile: importPdf,
    );

    /// 与 `PdfImporter` 落盘形态一致：`<extractDir>/document.pdf` + `format='pdf'`。
    Future<void> insertPdf(String bookKey, {bool writeFile = true}) async {
      final Directory dir = Directory(p.join(tmp.path, bookKey))
        ..createSync(recursive: true);
      if (writeFile) {
        File(p.join(dir.path, 'document.pdf')).writeAsBytesSync(pdfBytes);
      }
      await db.insertEpubBook(
        EpubBooksCompanion.insert(
          bookKey: bookKey,
          title: bookKey,
          epubPath: 'document.pdf',
          extractDir: dir.path,
          chapterCount: 3,
          chaptersJson: '[]',
          importedAt: DateTime.now().millisecondsSinceEpoch,
          format: Value(BookFormat.pdf.dbValue),
        ),
      );
    }

    test('清单：原件在盘的 PDF 标 hasPdfContent，原件缺失的不标', () async {
      await insertPdf('scan');
      await insertPdf('gone', writeFile: false);
      final List<RemoteBookInfo> books = await service().listBooks();
      final RemoteBookInfo scan = books.singleWhere(
        (RemoteBookInfo b) => b.title == 'scan',
      );
      final RemoteBookInfo gone = books.singleWhere(
        (RemoteBookInfo b) => b.title == 'gone',
      );
      expect(scan.format, 'pdf');
      expect(scan.hasPdfContent, isTrue);
      expect(scan.hasContent, isFalse, reason: 'hasContent 仍只表示 EPUB 内容树');
      expect(scan.hasMangaContent, isFalse);
      expect(gone.hasPdfContent, isFalse);
    });

    test('导出：交出原件字节的副本（.pdf），书目录里的原件不动', () async {
      await insertPdf('scan');
      final File original = File(p.join(tmp.path, 'scan', 'document.pdf'));
      final File out = await service().exportBook('scan');
      addTearDown(() {
        if (out.parent.existsSync()) out.parent.deleteSync(recursive: true);
      });
      expect(p.extension(out.path), '.pdf');
      expect(out.path, isNot(original.path));
      expect(out.readAsBytesSync(), pdfBytes);
      // 导出缓存过期会删返回的文件——删副本不能连累原件。
      out.deleteSync();
      expect(original.existsSync(), isTrue);
    });

    test('导出：原件缺失 → StateError（端点 404）', () async {
      await insertPdf('gone', writeFile: false);
      expect(() => service().exportBook('gone'), throwsStateError);
    });

    test('导入：推来的 PDF 按内容嗅探交 PDF 导入器，标题 = URL 书名', () async {
      final List<(String, String)> pdfCalls = <(String, String)>[];
      int epubCalls = 0;
      final LocalLibraryHostService svc = service(
        importBook: (File f) async {
          epubCalls++;
          return 'x';
        },
        importPdf: (File f, String title) async {
          pdfCalls.add((f.path, title));
          return title;
        },
      );
      expect(svc.acceptsPdfBooks, isTrue);
      final Directory inbox = Directory(p.join(tmp.path, 'inbox'))
        ..createSync();
      // 端点落点恒是 `<URL 书名>.epub`。
      final File pushed = File(p.join(inbox.path, 'スキャン本.epub'))
        ..writeAsBytesSync(pdfBytes);
      await svc.importBook(pushed);
      expect(epubCalls, 0, reason: 'PDF 绝不能交给 EPUB 导入器');
      expect(pdfCalls, hasLength(1));
      expect(pdfCalls.single.$2, 'スキャン本');
    });

    test('导入：非 PDF 仍走原 EPUB / 漫画回调', () async {
      int epubCalls = 0;
      int pdfCalls = 0;
      final LocalLibraryHostService svc = service(
        importBook: (File f) async {
          epubCalls++;
          return 'x';
        },
        importPdf: (File f, String title) async {
          pdfCalls++;
          return 'y';
        },
      );
      final File pushed = File(p.join(tmp.path, 'book.epub'))
        ..writeAsBytesSync(<int>[0x50, 0x4B, 0x03, 0x04, 1, 2, 3]);
      await svc.importBook(pushed);
      expect(epubCalls, 1);
      expect(pdfCalls, 0);
    });

    test('没接 PDF 导入器的 host（无头服务端）：不宣称能力，推来的 PDF 如实拒绝', () async {
      final LocalLibraryHostService svc = service(
        importBook: (File f) async => 'x',
      );
      expect(svc.acceptsPdfBooks, isFalse);
      final File pushed = File(p.join(tmp.path, 'scan.epub'))
        ..writeAsBytesSync(pdfBytes);
      expect(() => svc.importBook(pushed), throwsUnsupportedError);
    });
  });

  group('capabilities: liveLibrary.pdfBooks', () {
    const String token = 'tkn-pdf';

    Future<Map<String, Object?>> liveLibraryOf(
      FushiLibraryHostService library,
    ) async {
      final Directory tmp = Directory.systemTemp.createTempSync('hbk_pdf_srv');
      final FushiSyncServer server = FushiSyncServer(
        syncDataDir: tmp.path,
        port: 0,
        token: token,
        allowLan: false,
        libraryService: library,
      );
      await server.start();
      try {
        final HttpClient client = HttpClient();
        final HttpClientRequest req = await client.getUrl(
          Uri.parse('http://127.0.0.1:${server.port}/api/capabilities'),
        );
        req.headers.set(
          'authorization',
          'Basic ${base64Encode(utf8.encode('hibiki:$token'))}',
        );
        final HttpClientResponse res = await req.close();
        client.close();
        expect(res.statusCode, 200);
        final Map<String, Object?> json =
            (jsonDecode(await res.transform(utf8.decoder).join()) as Map)
                .cast<String, Object?>();
        return (json['liveLibrary']! as Map).cast<String, Object?>();
      } finally {
        await server.stop();
        try {
          tmp.deleteSync(recursive: true);
        } on FileSystemException {
          // best-effort
        }
      }
    }

    test('host 能收 PDF → true；不能收 / 没实现该能力 → false', () async {
      expect(
        (await liveLibraryOf(
          _PdfHost(accepts: true),
        ))[kLiveLibraryPdfBooksCapability],
        isTrue,
      );
      expect(
        (await liveLibraryOf(
          _PdfHost(accepts: false),
        ))[kLiveLibraryPdfBooksCapability],
        isFalse,
      );
      expect(
        (await liveLibraryOf(_PlainHost()))[kLiveLibraryPdfBooksCapability],
        isFalse,
      );
    });
  });
}

class _PdfHost extends Fake
    implements FushiLibraryHostService, PdfBookImportHost {
  _PdfHost({required this.accepts});

  final bool accepts;

  @override
  bool get acceptsPdfBooks => accepts;
}

/// 只实现主接口的 host：老版本 / 精简 host 的形状。
class _PlainHost extends Fake implements FushiLibraryHostService {}
