import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/torrent/torrent_backend.dart';
import 'package:fushi/src/media/video/download/video_download_organizer.dart';
import 'package:fushi/src/media/video/download/video_download_path_mapping.dart';
import 'package:path/path.dart' as p;

/// 本机侧根目录，按**当前平台**给。
///
/// [VideoDownloadPathMapping] 的本机侧走 `p.normalize(p.absolute(...))` + `p.join`
/// （平台上下文），远端侧才统一 `/`。原来这条用例把本机根硬编码成 `C:\Media\Downloads`：
/// Linux CI 上它不是绝对路径，`p.absolute` 会给它前置 CWD 变成
/// `/…/cwd/C:\Media\Downloads`，拼出来的结果与期望值必然不等——「本机 Windows 绿、
/// CI 必红」。本机路径按平台原生给才是这个类的真实用法，所以修的是用例的平台假设。
final String _localRoot =
    Platform.isWindows ? r'C:\Media\Downloads' : '/Media/Downloads';

void main() {
  test('remote/local path mapping is bidirectional and prefix-safe', () {
    final VideoDownloadPathMapping mapping = VideoDownloadPathMapping(
      remoteRoot: '/srv/downloads/',
      localRoot: _localRoot,
      localCaseSensitive: false,
    );

    expect(
      mapping.remoteToLocal('/srv/downloads/Show/E01.mkv'),
      p.normalize(p.joinAll(<String>[_localRoot, 'Show', 'E01.mkv'])),
    );
    // 大小写不敏感回程：把**根**整段转小写、目录段保持原样，两个平台都真的在考
    // `localCaseSensitive: false`（Windows 上仍是原来那条 `c:\media\downloads\…`）。
    expect(
      mapping.localToRemote(
        p.joinAll(<String>[_localRoot.toLowerCase(), 'Show', 'E01.mkv']),
      ),
      '/srv/downloads/Show/E01.mkv',
    );
    expect(mapping.remoteToLocal('/srv/downloads-other/E01.mkv'), isNull);
  });

  test('episodic organizer uses managed naming and backend-only mutation',
      () async {
    final Directory root = await Directory.systemTemp.createTemp(
      'fushi-organizer-',
    );
    addTearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });
    final _FakeBackend backend = _FakeBackend(<TorrentFileEntry>[
      // 种子内路径用 `/`：这是 qBittorrent `torrents/files` 真实返回的形态（与本机
      // 平台无关）。原来写成反斜杠，只有 Windows 的 `p.basename` 认得，Linux 上取
      // basename 会把整串当文件名——用例因此带上了不该有的平台依赖。
      const TorrentFileEntry(
        name: 'Original/Show.S02E03.mkv',
        size: 100,
        progress: 1,
        index: 4,
      ),
    ]);
    final List<VideoOrganizationFilePlan> committed =
        <VideoOrganizationFilePlan>[];

    final VideoOrganizationResult result =
        await const VideoDownloadOrganizer().organize(
      backend: backend,
      request: VideoOrganizationRequest(
        torrentId: 'hash',
        title: 'Show: Name',
        year: 2024,
        kind: VideoOrganizationKind.episodic,
        sourceRoot: root.path,
        pathMapping: VideoDownloadPathMapping(
          remoteRoot: '/library',
          localRoot: root.path,
        ),
      ),
      onFileCommitted: (VideoOrganizationFilePlan value) async {
        committed.add(value);
      },
    );

    expect(result.ok, isTrue, reason: result.error);
    expect(
      result.files.single.targetRelativePath,
      'Show_ Name (2024)/Season 02/Show_ Name (2024) - S02E03.mkv',
    );
    expect(backend.operations, <String>[
      'rename:4:Show_ Name (2024)/Season 02/Show_ Name (2024) - S02E03.mkv',
      'move:/library',
    ]);
    expect(committed, hasLength(1));
  });

  test('movie organizer chooses the largest video and keeps extras distinct',
      () async {
    final Directory root = await Directory.systemTemp.createTemp(
      'fushi-organizer-movie-',
    );
    addTearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });
    final VideoOrganizationPlan plan = const VideoDownloadOrganizer().plan(
      VideoOrganizationRequest(
        torrentId: 'hash',
        title: 'Movie',
        year: 1999,
        kind: VideoOrganizationKind.movie,
        sourceRoot: root.path,
        pathMapping: VideoDownloadPathMapping(
          remoteRoot: '/library',
          localRoot: root.path,
        ),
      ),
      <TorrentFileEntry>[
        const TorrentFileEntry(
          name: 'feature.mkv',
          size: 200,
          progress: 1,
          index: 0,
        ),
        const TorrentFileEntry(
          name: 'trailer.mp4',
          size: 20,
          progress: 1,
          index: 1,
        ),
      ],
    );

    expect(
      plan.files
          .map((VideoOrganizationFilePlan file) => file.targetRelativePath),
      <String>[
        'Movie (1999)/Movie (1999).mkv',
        'Movie (1999)/Extras/trailer.mp4',
      ],
    );
  });

  test('unparseable episodic filename blocks before backend mutation',
      () async {
    final Directory root = await Directory.systemTemp.createTemp(
      'fushi-organizer-block-',
    );
    addTearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });
    final _FakeBackend backend = _FakeBackend(<TorrentFileEntry>[
      const TorrentFileEntry(
        name: 'unknown.mkv',
        size: 100,
        progress: 1,
        index: 0,
      ),
    ]);

    final VideoOrganizationResult result =
        await const VideoDownloadOrganizer().organize(
      backend: backend,
      request: VideoOrganizationRequest(
        torrentId: 'hash',
        title: 'Show',
        kind: VideoOrganizationKind.episodic,
        sourceRoot: root.path,
        pathMapping: VideoDownloadPathMapping(
          remoteRoot: '/library',
          localRoot: root.path,
        ),
      ),
    );

    expect(result.ok, isFalse);
    expect(result.error, contains('episode number'));
    expect(backend.operations, isEmpty);
  });
}

class _FakeBackend implements TorrentBackend {
  _FakeBackend(this.files);

  final List<TorrentFileEntry> files;
  final List<String> operations = <String>[];

  @override
  Future<bool> addTorrent(
    String magnetOrUrl, {
    required String category,
    bool sequential = false,
    bool firstLastPiecePrio = false,
  }) async =>
      true;

  @override
  void close() {}

  @override
  Future<List<TorrentFileEntry>> listFiles(String torrentId) async => files;

  @override
  Future<List<TorrentSnapshot>> listTorrents({String? category}) async =>
      const <TorrentSnapshot>[];

  @override
  Future<TorrentStorageResult> moveStorage(
    String torrentId,
    String newSavePath,
  ) async {
    operations.add('move:$newSavePath');
    return TorrentStorageResult(ok: true, path: newSavePath);
  }

  @override
  Future<bool> prepareCategory(String category) async => true;

  @override
  Future<String?> probeConnection() async => 'fake';

  @override
  Future<TorrentStorageResult> renameFile(
    String torrentId,
    int fileIndex,
    String newPath,
  ) async {
    operations.add('rename:$fileIndex:$newPath');
    return TorrentStorageResult(ok: true, path: newPath);
  }
}
