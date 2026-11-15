/// 反馈 Jq1_ujHa4t：PDF 互联内容通道的推送方向（client → host）。
///
/// 真实链路：client [SyncOrchestrator] → [InterconnectSyncBackend] HTTP →
/// [FushiSyncServer] → [LocalLibraryHostService.importBook]（按内容嗅探分流 PDF）。
/// 钉三件事：
/// * host 宣称能收 PDF（接了 PDF 导入器）→ 本机 PDF 原件原样推过去；
/// * host 收不了（无头服务端 / 老 host）→ 不推、不报错（能力边界），EPUB 照推；
/// * host 已有同名 PDF（清单 `hasPdfContent`）→ 不再重复推。
library;

import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/interconnect_sync_backend.dart';
import 'package:fushi/src/sync/sync_orchestrator.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/sync/fushi_sync_server.dart';
import 'package:fushi_engine/sync/local_library_host_service.dart';
import 'package:fushi_engine/sync/sync_asset_package_service.dart';
import 'package:fushi_engine/sync/ttu_filename.dart';
import 'package:path/path.dart' as p;

FushiDatabase _memDb() =>
    FushiDatabase.forTesting(DatabaseConnection(NativeDatabase.memory()));

final List<int> _pdfBytes = utf8.encode(
  '%PDF-1.7\n1 0 obj << /Type /Catalog >> endobj\n%%EOF\n',
);

/// 与 `PdfImporter` 落盘形态一致：`<extractDir>/document.pdf` + `format='pdf'`。
Future<void> _seedPdf({
  required FushiDatabase db,
  required String title,
  required String extractDir,
  List<int>? bytes,
}) async {
  Directory(extractDir).createSync(recursive: true);
  File(p.join(extractDir, 'document.pdf')).writeAsBytesSync(bytes ?? _pdfBytes);
  await db.insertEpubBook(
    EpubBooksCompanion.insert(
      bookKey: sanitizeTtuFilename(title),
      title: title,
      epubPath: 'document.pdf',
      extractDir: extractDir,
      chapterCount: 2,
      chaptersJson: '[]',
      importedAt: 1,
      format: Value(BookFormat.pdf.dbValue),
    ),
  );
}

Future<void> _seedEpub({
  required FushiDatabase db,
  required String title,
  required String extractDir,
}) async {
  Directory(extractDir).createSync(recursive: true);
  File(
    p.join(extractDir, 'mimetype'),
  ).writeAsStringSync('application/epub+zip');
  final Directory metaInf = Directory(p.join(extractDir, 'META-INF'))
    ..createSync();
  File(p.join(metaInf.path, 'container.xml')).writeAsStringSync(
    '<?xml version="1.0"?>'
    '<container version="1.0" xmlns="urn:oasis:schemas:container">'
    '<rootfiles><rootfile full-path="content.opf"'
    ' media-type="application/oebps-package+xml"/></rootfiles>'
    '</container>',
  );
  File(p.join(extractDir, 'content.opf')).writeAsStringSync(
    '<?xml version="1.0"?>'
    '<package xmlns="http://www.idpf.org/2007/opf" version="2.0">'
    '<metadata/><manifest/><spine/></package>',
  );
  await db.insertEpubBook(
    EpubBooksCompanion.insert(
      bookKey: title,
      title: title,
      epubPath: 'original.epub',
      extractDir: extractDir,
      chapterCount: 1,
      chaptersJson: '["ch1"]',
      importedAt: 1,
    ),
  );
}

Future<InterconnectSyncBackend> _clientBackend(
  String base,
  String token,
) async {
  final FushiDatabase db = _memDb();
  final SyncRepository repo = SyncRepository(db);
  await repo.setFushiClientUrls(<FushiClientUrl>[
    FushiClientUrl(url: base, enabled: true),
  ]);
  await repo.setFushiClientToken(token);
  final InterconnectSyncBackend backend = InterconnectSyncBackend.withProbe(
    (String u, String t) async => true,
  );
  await backend.restoreAuth(repo);
  await backend.authenticate(repo: repo);
  return backend;
}

void main() {
  late Directory work;
  late FushiDatabase hostDb;
  late FushiSyncServer server;
  late String base;
  late List<(String, List<int>)> pdfImports;
  const String token = 'jq1-ujha4t-token';

  /// [acceptsPdf] = host 有没有接 PDF 导入器（app host 有，无头服务端没有）。
  Future<void> startHost({required bool acceptsPdf}) async {
    pdfImports = <(String, List<int>)>[];
    final LocalLibraryHostService libSvc = LocalLibraryHostService(
      db: hostDb,
      dictionaryResourceRoot: Directory(work.path),
      packages: SyncAssetPackageService(db: hostDb),
      refreshDictionaryCache: () async {},
      runExclusive: (Future<void> Function() body) => body(),
      importBookFromFile: (File f) async {
        final String title = p.basenameWithoutExtension(f.path);
        await _seedEpub(
          db: hostDb,
          title: title,
          extractDir: p.join(work.path, 'host_$title'),
        );
        return sanitizeTtuFilename(title);
      },
      importPdfBookFromFile: acceptsPdf
          ? (File f, String title) async {
              final List<int> bytes = f.readAsBytesSync();
              pdfImports.add((title, bytes));
              await _seedPdf(
                db: hostDb,
                title: title,
                extractDir: p.join(work.path, 'host_pdf_$title'),
                bytes: bytes,
              );
              return sanitizeTtuFilename(title);
            }
          : null,
    );
    server = FushiSyncServer(
      syncDataDir: p.join(work.path, 'server_data'),
      port: 0,
      token: token,
      allowLan: false,
      libraryService: libSvc,
    );
    await server.start();
    base = 'http://127.0.0.1:${server.port}';
  }

  setUp(() async {
    work = await Directory.systemTemp.createTemp('jq1_ujha4t_');
    hostDb = _memDb();
  });

  tearDown(() async {
    await server.stop();
    await hostDb.close();
    if (work.existsSync()) await work.delete(recursive: true);
  });

  Future<SyncRunReport> runClient(FushiDatabase localDb) async {
    final Directory tmp = Directory(p.join(work.path, 'tmp_run'))
      ..createSync(recursive: true);
    final InterconnectSyncBackend backend = await _clientBackend(base, token);
    return SyncOrchestrator(
      db: localDb,
      backend: backend,
      dictionaryResourceRoot: tmp,
      audioDatabaseRoot: tmp,
      tempDir: tmp,
      syncStats: false,
      syncAudioBookPosition: false,
      syncContent: true,
      syncMangaContent: true,
      syncAudioBookFiles: false,
      syncDictionary: false,
    ).run();
  }

  test('host 能收 PDF：本机 PDF 原件原样推过去，host 落成 PDF 书', () async {
    await startHost(acceptsPdf: true);
    final FushiDatabase localDb = _memDb();
    addTearDown(localDb.close);
    await _seedPdf(
      db: localDb,
      title: 'スキャン本',
      extractDir: p.join(work.path, 'local_pdf'),
    );

    final SyncRunReport report = await runClient(localDb);

    expect(report.errors, isEmpty, reason: '${report.errors}');
    expect(pdfImports, hasLength(1));
    expect(
      pdfImports.single.$1,
      'スキャン本',
      reason: '标题 = URL 书名，host bookKey 由它派生',
    );
    expect(pdfImports.single.$2, _pdfBytes, reason: '推的是原件字节，不是重打包的 EPUB');
    final EpubBookRow? hostRow = await hostDb.getEpubBook(
      sanitizeTtuFilename('スキャン本'),
    );
    expect(hostRow?.format, BookFormat.pdf.dbValue);
    // 本机原件不能被当临时文件删掉。
    expect(
      File(p.join(work.path, 'local_pdf', 'document.pdf')).existsSync(),
      isTrue,
    );
  });

  test('host 已有同名 PDF：不重复推', () async {
    await startHost(acceptsPdf: true);
    await _seedPdf(
      db: hostDb,
      title: 'Shared',
      extractDir: p.join(work.path, 'host_shared'),
    );
    final FushiDatabase localDb = _memDb();
    addTearDown(localDb.close);
    await _seedPdf(
      db: localDb,
      title: 'Shared',
      extractDir: p.join(work.path, 'local_shared'),
    );

    final SyncRunReport report = await runClient(localDb);

    expect(report.errors, isEmpty, reason: '${report.errors}');
    expect(pdfImports, isEmpty, reason: 'host 清单的 hasPdfContent 必须算「远端已有」');
  });

  test('host 收不了 PDF（无头服务端 / 老 host）：PDF 留在本机、不报错，EPUB 照推', () async {
    await startHost(acceptsPdf: false);
    final FushiDatabase localDb = _memDb();
    addTearDown(localDb.close);
    await _seedPdf(
      db: localDb,
      title: 'LocalOnlyPdf',
      extractDir: p.join(work.path, 'local_pdf_only'),
    );
    await _seedEpub(
      db: localDb,
      title: 'PlainEpub',
      extractDir: p.join(work.path, 'local_epub'),
    );

    final SyncRunReport report = await runClient(localDb);

    expect(report.errors, isEmpty, reason: '${report.errors}');
    expect(await hostDb.getEpubBook('LocalOnlyPdf'), isNull);
    expect(await hostDb.getEpubBook('PlainEpub'), isNotNull);
  });
}
