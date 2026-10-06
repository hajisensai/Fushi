import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/video/jimaku_subtitle_provider.dart';
import 'package:fushi/src/media/video/subtitle/subtitle_archive_label.dart';
import 'package:fushi/src/media/video/subtitle/subtitle_batch.dart';
import 'package:fushi/src/pages/implementations/subtitle_search_panel.dart'
    show describeSubtitleFailure;
import 'package:fushi_engine/media/external_provider.dart';
import 'package:fushi_engine/media/video/discovery/video_discovery_provider.dart';
import 'package:fushi_engine/media/video/download/video_subtitle_registry.dart';
import 'package:fushi_engine/media/video/jimaku_client.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_models.dart';
import 'package:fushi_engine/media/video/subtitle/subtitle_archive.dart';
import 'package:fushi_engine/media/video/subtitle/video_subtitle_provider.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// BUG-3000 跟进：Jimaku 整季压缩包（zip 解包 / rar、7z 明确不支持）。
///
/// files 响应按 Jimaku 真实形状（`{url, name, size, last_modified}`）伪造，压缩包
/// 是内存里现编的 zip。
Uint8List _zip(Map<String, String> entries) {
  final Archive archive = Archive();
  entries.forEach((String name, String content) {
    final List<int> bytes = utf8.encode(content);
    archive.addFile(ArchiveFile(name, bytes.length, bytes));
  });
  return Uint8List.fromList(ZipEncoder().encode(archive)!);
}

String _srt(int episode) => '1\n00:00:01,000 --> 00:00:02,000\nep$episode\n';

const String _base = 'https://jimaku.cc';
const String _zipUrl = '$_base/entry/1234/download/Mirai Nikki (01-03).zip';
const String _rarUrl = '$_base/entry/1234/download/Mirai Nikki BD.rar';

Map<String, Object?> _file(String name, String url, int size) =>
    <String, Object?>{
      'url': url,
      'name': name,
      'size': size,
      'last_modified': '2023-05-06T07:08:09.000Z',
    };

/// 伪 Jimaku：带 `episode` 的 files 查询按服务端行为把整季包滤掉。
class _FakeJimaku {
  _FakeJimaku({required this.zipBytes});

  final Uint8List zipBytes;
  int zipDownloads = 0;
  final List<Uri> fileListings = <Uri>[];

  MockClient get client => MockClient((http.Request req) async {
    final String path = req.url.path;
    if (path == '/api/entries/search') {
      return http.Response(
        jsonEncode(<Object?>[
          <String, Object?>{
            'id': 1234,
            'name': 'Mirai Nikki',
            'english_name': 'The Future Diary',
            'anilist_id': 10620,
            'flags': <String, Object?>{'anime': true},
            'last_modified': '2023-05-06T07:08:09.000Z',
          },
        ]),
        200,
      );
    }
    if (path == '/api/entries/1234/files') {
      fileListings.add(req.url);
      if (req.url.queryParameters.containsKey('episode')) {
        return http.Response('[]', 200);
      }
      return http.Response(
        jsonEncode(<Object?>[
          _file('Mirai Nikki (01-03).zip', _zipUrl, zipBytes.length),
          _file('Mirai Nikki BD.rar', _rarUrl, 1000),
        ]),
        200,
      );
    }
    if (req.url.toString() == Uri.parse(_zipUrl).toString()) {
      zipDownloads++;
      return http.Response.bytes(zipBytes, 200);
    }
    if (req.url.toString() == Uri.parse(_rarUrl).toString()) {
      return http.Response.bytes(<int>[
        0x52,
        0x61,
        0x72,
        0x21,
        0x1A,
        0x07,
        0x00,
      ], 200);
    }
    return http.Response('not found', 404);
  });
}

VideoSubtitleSearchRequest _request({int? episode}) =>
    VideoSubtitleSearchRequest(
      media: VideoMediaReference(
        providerId: 'anilist',
        mediaId: '10620',
        mediaKind: VideoMetadataMediaKind.tv,
        discoveryCategory: VideoDiscoveryCategory.anime,
        title: 'Mirai Nikki',
        anilistId: 10620,
      ),
      episode: episode,
      languages: const <String>['ja'],
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => LocaleSettings.setLocale(AppLocale.zhCn));

  final Uint8List pack = _zip(<String, String>{
    '__MACOSX/._x.srt': 'junk',
    'Mirai Nikki/[Group] Mirai Nikki - 01.ja.srt': _srt(1),
    'Mirai Nikki/[Group] Mirai Nikki - 02.ja.srt': _srt(2),
    'Mirai Nikki/[Group] Mirai Nikki - 03.ja.srt': _srt(3),
    'readme.txt': 'notes',
  });

  JimakuVideoSubtitleProvider providerFor(_FakeJimaku fake) =>
      JimakuVideoSubtitleProvider(
        client: JimakuClient(apiKey: 'k', client: fake.client),
      );

  test('整季包出现在搜索结果里（带集号查时服务端会滤掉，再列全表补回）', () async {
    final _FakeJimaku fake = _FakeJimaku(zipBytes: pack);
    final ProviderBatchResult<VideoSubtitleCandidate> result =
        await providerFor(fake).search(_request(episode: 2));

    expect(result.failures, isEmpty);
    expect(
      <String, SubtitleArchiveFormat?>{
        for (final VideoSubtitleCandidate c in result.items)
          c.fileName: c.archiveFormat,
      },
      <String, SubtitleArchiveFormat?>{
        'Mirai Nikki (01-03).zip': SubtitleArchiveFormat.zip,
        'Mirai Nikki BD.rar': SubtitleArchiveFormat.rar,
      },
      reason: '包名不带语言标记也不能被 ja 过滤掉；RAR 照样列出（解不开但要让用户看见）',
    );
    for (final VideoSubtitleCandidate c in result.items) {
      expect(c.episode, isNull, reason: '`(01-03)` 不是第 1 集');
    }
    expect(fake.fileListings.first.queryParameters['episode'], '2');
    expect(fake.fileListings.last.queryParameters, isEmpty);
  });

  test('列表标注：zip 是「整季包」，RAR 直说暂不支持解包', () async {
    final _FakeJimaku fake = _FakeJimaku(zipBytes: pack);
    final List<VideoSubtitleCandidate> items = (await providerFor(
      fake,
    ).search(_request())).items;
    final Map<String, String?> labels = <String, String?>{
      for (final VideoSubtitleCandidate c in items)
        c.fileName: subtitleArchivePackLabel(c),
    };
    expect(
      labels['Mirai Nikki (01-03).zip'],
      t.video_subtitle_archive_pack(format: 'ZIP'),
    );
    expect(
      labels['Mirai Nikki BD.rar'],
      t.video_subtitle_archive_pack_unsupported(format: 'RAR'),
    );
  });

  test('单集：下载 zip 包后按请求集号从包内挑文件，并带回全部条目', () async {
    final _FakeJimaku fake = _FakeJimaku(zipBytes: pack);
    final JimakuVideoSubtitleProvider provider = providerFor(fake);
    final VideoSubtitleCandidate zip =
        (await provider.search(_request(episode: 2))).items.firstWhere(
          (VideoSubtitleCandidate c) => c.fileName.endsWith('.zip'),
        );

    final VideoSubtitleDownload download = await provider.download(zip);

    expect(download.fileName, '[Group] Mirai Nikki - 02.ja.srt');
    expect(utf8.decode(download.bytes), contains('ep2'));
    expect(download.language, 'ja');
    expect(download.archiveEntries, hasLength(3));
  });

  test('单集：包里没有这一集 → 明确失败，不拿第 1 集顶替', () async {
    final _FakeJimaku fake = _FakeJimaku(zipBytes: pack);
    final JimakuVideoSubtitleProvider provider = providerFor(fake);
    final VideoSubtitleCandidate zip =
        (await provider.search(_request(episode: 9))).items.firstWhere(
          (VideoSubtitleCandidate c) => c.fileName.endsWith('.zip'),
        );

    await expectLater(
      provider.download(zip),
      throwsA(
        isA<ExternalProviderFailure>()
            .having(
              (ExternalProviderFailure f) => f.kind,
              'kind',
              ExternalProviderFailureKind.notFound,
            )
            .having(
              (ExternalProviderFailure f) => f.operation,
              'operation',
              kSubtitleArchiveOperation,
            ),
      ),
    );
  });

  test('RAR 包下载给出「暂不支持解包」，不把压缩流当字幕落盘', () async {
    final _FakeJimaku fake = _FakeJimaku(zipBytes: pack);
    final JimakuVideoSubtitleProvider provider = providerFor(fake);
    final VideoSubtitleCandidate rar = (await provider.search(_request())).items
        .firstWhere((VideoSubtitleCandidate c) => c.fileName.endsWith('.rar'));

    Object? error;
    try {
      await provider.download(rar);
    } on Object catch (e) {
      error = e;
    }
    expect(error, isA<ExternalProviderFailure>());
    expect(
      describeSubtitleFailure(t.video_jimaku_download_failed, error),
      t.video_subtitle_error_archive_unsupported,
    );
  });

  test('合集：整季 zip 只下载一次，按集号逐集拆分落盘', () async {
    final _FakeJimaku fake = _FakeJimaku(zipBytes: pack);
    final JimakuVideoSubtitleProvider provider = providerFor(fake);
    final List<VideoSubtitleCandidate> candidates = (await provider.search(
      _request(),
    )).items;
    final Directory tmp = await Directory.systemTemp.createTemp(
      'jimaku_pack_batch',
    );
    addTearDown(() => tmp.delete(recursive: true));

    final List<SubtitleBatchItem> results = await runSubtitleBatch(
      registry: VideoSubtitleRegistry(<VideoSubtitleProvider>[provider]),
      candidates: candidates,
      targets: <SubtitleBatchTarget>[
        for (int i = 0; i < 4; i++)
          SubtitleBatchTarget(
            bookUid: 'video/ep${i + 1}',
            title: 'Mirai Nikki - 0${i + 1}',
            videoPath: '/v/[VCB-Studio] Mirai Nikki [0${i + 1}].mkv',
            sortIndex: i,
            isStream: false,
          ),
      ],
      saveDirectory: tmp.path,
      preferredLanguage: 'ja',
    );

    for (int i = 0; i < 3; i++) {
      expect(results[i].status, SubtitleBatchStatus.done);
      expect(
        File(results[i].subtitlePath!).readAsStringSync(),
        contains('ep${i + 1}'),
      );
      expect(results[i].language, 'ja');
    }
    expect(
      results[3].status,
      SubtitleBatchStatus.noMatch,
      reason: '包里没有第 4 集：不能把别的集发给它',
    );
    expect(fake.zipDownloads, 1, reason: '整季包只下一次，逐集从同一份解包结果里取');
  });
}
