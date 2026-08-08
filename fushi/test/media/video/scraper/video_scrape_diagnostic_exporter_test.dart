import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/scraper/video_scrape_diagnostic_exporter.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory temp;
  late Directory sourceRoot;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('scrape_diagnostics_');
    sourceRoot = Directory(p.join(temp.path, 'private-user', 'Anime'));
    await Directory(p.join(sourceRoot.path, 'Season 01'))
        .create(recursive: true);
  });

  tearDown(() async {
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  test('exports relative tree and original NFO without media or secrets',
      () async {
    final String videoPath =
        p.join(sourceRoot.path, 'Season 01', '[Group] Example S01E03.mkv');
    final String nfoPath =
        p.join(sourceRoot.path, 'Season 01', '[Group] Example S01E03.nfo');
    const List<int> malformedNfo = <int>[0xff, 0xfe, 0x00, 0x3c, 0x78, 0x6d];
    await File(videoPath).writeAsBytes(<int>[1, 2, 3, 4]);
    await File(nfoPath).writeAsBytes(malformedNfo);
    await File(p.join(sourceRoot.path, 'Season 01', 'subtitle.srt'))
        .writeAsString('subtitle bytes must not be copied');
    await File(p.join(sourceRoot.path, 'poster.jpg')).writeAsBytes(<int>[8, 9]);

    final MediaSourceRow source = MediaSourceRow(
      id: 7,
      label: 'Private Anime',
      mediaKind: 'video',
      transport: 'local',
      rootPath: sourceRoot.path,
      configJson: '{"api_key":"must-not-leak"}',
      mediaCount: 1,
      lastScannedAt: DateTime.utc(2026, 8, 9),
      lastScanError:
          'failed at ${sourceRoot.path}?api_key=super-secret&lang=zh',
      recursive: true,
      sortOrder: 0,
      createdAt: 1,
    );
    final VideoBookRow book = VideoBookRow(
      bookUid: 'book-1',
      title: 'Example',
      videoPath: videoPath,
      lastPositionMs: 0,
      currentEpisode: 0,
      delayMs: 0,
      sourceId: 7,
    );
    final VideoScrapeMetaRow metadata = VideoScrapeMetaRow(
      bookUid: 'book-1',
      source: 'tmdb',
      subjectId: '42',
      title: 'Example',
      detailUrl: 'https://example.test/42?api_key=another-secret',
      episodeNumber: 3,
      scrapedAt: DateTime.utc(2026, 8, 8),
    );
    final File output = File(p.join(temp.path, 'diagnostics.zip'));

    final VideoScrapeDiagnosticExportResult result =
        await const VideoScrapeDiagnosticExporter().export(
      source: source,
      books: <VideoBookRow>[book],
      scrapeMetadata: <VideoScrapeMetaRow>[metadata],
      outputFile: output,
      applicationVersion: '1.2.3+4',
      platform: 'windows',
      exportedAt: DateTime.utc(2026, 8, 9, 12),
    );

    expect(result.nfoCount, 1);
    final Archive archive =
        ZipDecoder().decodeBytes(await output.readAsBytes());
    final Set<String> names =
        archive.files.map((ArchiveFile f) => f.name).toSet();
    expect(
        names,
        containsAll(<String>{
          'README.txt',
          'manifest.json',
          'tree.json',
          'directory-tree.txt',
          'scrape-data.json',
          'nfo/Season 01/[Group] Example S01E03.nfo',
        }));
    expect(names.any((String name) => name.endsWith('.mkv')), isFalse);
    expect(names.any((String name) => name.endsWith('.srt')), isFalse);
    expect(names.any((String name) => name.endsWith('.jpg')), isFalse);
    expect(
      archive.findFile('nfo/Season 01/[Group] Example S01E03.nfo')!.content,
      malformedNfo,
    );

    final String manifest = _readText(archive, 'manifest.json');
    final String tree = _readText(archive, 'tree.json');
    final String scrapeData = _readText(archive, 'scrape-data.json');
    final String allStructuredText = '$manifest\n$tree\n$scrapeData';
    expect(allStructuredText, isNot(contains(sourceRoot.path)));
    expect(allStructuredText, isNot(contains('private-user')));
    expect(allStructuredText, isNot(contains('super-secret')));
    expect(allStructuredText, isNot(contains('another-secret')));
    expect(allStructuredText, isNot(contains('must-not-leak')));
    expect(manifest, contains('<source-root>'));
    expect(manifest, contains('api_key=<redacted>'));
    expect(tree, contains('Season 01/[Group] Example S01E03.mkv'));
    expect(scrapeData, contains('"episode": 3'));
    expect(scrapeData, contains('"scrapeStatus": "matched"'));
  });

  test('records NFO omitted by size limit', () async {
    await File(p.join(sourceRoot.path, 'large.nfo'))
        .writeAsBytes(List<int>.filled(16, 65));
    final File output = File(p.join(temp.path, 'limited.zip'));
    final MediaSourceRow source = MediaSourceRow(
      id: 1,
      label: 'Anime',
      mediaKind: 'video',
      transport: 'local',
      rootPath: sourceRoot.path,
      mediaCount: 0,
      recursive: true,
      sortOrder: 0,
      createdAt: 1,
    );

    final VideoScrapeDiagnosticExportResult result =
        await const VideoScrapeDiagnosticExporter(maxSingleNfoBytes: 8).export(
      source: source,
      books: const <VideoBookRow>[],
      scrapeMetadata: const <VideoScrapeMetaRow>[],
      outputFile: output,
      applicationVersion: 'test',
      platform: 'windows',
    );

    expect(result.nfoCount, 0);
    expect(result.omittedNfoCount, 1);
    final Archive archive =
        ZipDecoder().decodeBytes(await output.readAsBytes());
    expect(archive.findFile('nfo/large.nfo'), isNull);
    expect(_readText(archive, 'manifest.json'),
        contains('"nfoFilesOverLimit": 1'));
  });
}

String _readText(Archive archive, String name) {
  final ArchiveFile file = archive.findFile(name)!;
  return utf8.decode(file.content as List<int>);
}
