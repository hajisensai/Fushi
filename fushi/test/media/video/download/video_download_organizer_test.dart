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

  test('episodic organizer routes unnumbered specials to Extras (BUG-1785)',
      () async {
    final Directory root = await Directory.systemTemp.createTemp(
      'fushi-organizer-extras-',
    );
    addTearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });
    const String releaseRoot = '[VCB-Studio] Hibike! Euphonium 2 [Ma10p_1080p]';
    final VideoOrganizationPlan plan = const VideoDownloadOrganizer().plan(
      VideoOrganizationRequest(
        torrentId: 'hash',
        title: '響け！ユーフォニアム 2',
        year: 2016,
        kind: VideoOrganizationKind.episodic,
        defaultSeasonNumber: 2,
        sourceRoot: root.path,
        pathMapping: VideoDownloadPathMapping(
          remoteRoot: '/library',
          localRoot: root.path,
        ),
      ),
      <TorrentFileEntry>[
        const TorrentFileEntry(
          name: '$releaseRoot/'
              '[VCB-Studio] Hibike! Euphonium 2 [01][Ma10p_1080p][x265_flac].mkv',
          size: 900,
          progress: 1,
          index: 0,
        ),
        // 内置引擎在 Windows 上报反斜杠路径（用户原始报错原样）。
        const TorrentFileEntry(
          name: '$releaseRoot\\Previews\\'
              '[VCB-Studio] Hibike! Euphonium 2 [WEB Preview02][Ma10p_1080p][x265_flac].mkv',
          size: 30,
          progress: 1,
          index: 1,
        ),
        const TorrentFileEntry(
          name: '$releaseRoot/SPs/'
              '[VCB-Studio] Hibike! Euphonium 2 [NCOP][Ma10p_1080p][x265_flac].mkv',
          size: 40,
          progress: 1,
          index: 2,
        ),
      ],
    );

    final Map<int, VideoOrganizationFilePlan> byIndex =
        <int, VideoOrganizationFilePlan>{
      for (final VideoOrganizationFilePlan file in plan.files)
        file.backendFileIndex: file,
    };
    expect(
      byIndex[0]!.targetRelativePath,
      '響け！ユーフォニアム 2 (2016)/Season 02/'
      '響け！ユーフォニアム 2 (2016) - S02E01.mkv',
    );
    expect(byIndex[0]!.episodeNumber, 1);
    expect(
      byIndex[1]!.targetRelativePath,
      '響け！ユーフォニアム 2 (2016)/Extras/Previews/'
      '[VCB-Studio] Hibike! Euphonium 2 [WEB Preview02][Ma10p_1080p][x265_flac].mkv',
    );
    expect(byIndex[1]!.episodeNumber, isNull);
    expect(
      byIndex[2]!.targetRelativePath,
      '響け！ユーフォニアム 2 (2016)/Extras/SPs/'
      '[VCB-Studio] Hibike! Euphonium 2 [NCOP][Ma10p_1080p][x265_flac].mkv',
    );
  });

  test(
      'numbered specials in an EXTRA directory never claim episode targets '
      '(BUG-1865)', () async {
    final Directory root = await Directory.systemTemp.createTemp(
      'fushi-organizer-numbered-extras-',
    );
    addTearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });
    // 用户原始种子（Moozzi2 Hibike! Euphonium S3 - TV + SP）的真实文件名：
    // EXTRA 里有 6 个以 `- 05` 结尾的特典，硬按文件名解集号时它们与真正的第 5
    // 集抢同一个 `Season 03/… - S03E05.mkv`，整批整理直接失败。
    const String releaseRoot =
        '[Moozzi2] Hibike! Euphonium S3 [ x265-10Bit Ver. ] - TV + SP';
    const String suffix = '(BD 1920x1080 x265-10Bit Flac).mkv';
    final VideoOrganizationPlan plan = const VideoDownloadOrganizer().plan(
      VideoOrganizationRequest(
        torrentId: 'hash',
        title: '響け！ユーフォニアム３',
        year: 2024,
        kind: VideoOrganizationKind.episodic,
        defaultSeasonNumber: 3,
        sourceRoot: root.path,
        pathMapping: VideoDownloadPathMapping(
          remoteRoot: '/library',
          localRoot: root.path,
        ),
      ),
      <TorrentFileEntry>[
        const TorrentFileEntry(
          name: '$releaseRoot/EXTRA/[Moozzi2] Hibike! Euphonium S3 '
              '[SP05] Making Video Collection - 05 $suffix',
          size: 30,
          progress: 1,
          index: 11,
        ),
        const TorrentFileEntry(
          name: '$releaseRoot/EXTRA/[Moozzi2] Hibike! Euphonium S3 '
              '[SP08] Extra Episode - 05 $suffix',
          size: 31,
          progress: 1,
          index: 16,
        ),
        const TorrentFileEntry(
          name: '$releaseRoot/EXTRA/[Moozzi2] Hibike! Euphonium S3 '
              '[SP00] Menu - 05 [ Ver.01 ] $suffix',
          size: 32,
          progress: 1,
          index: 26,
        ),
        const TorrentFileEntry(
          name: '$releaseRoot/EXTRA/[Moozzi2] Hibike! Euphonium S3 '
              '[SP01] NCOP $suffix',
          size: 33,
          progress: 1,
          index: 13,
        ),
        const TorrentFileEntry(
          name: '$releaseRoot/[Moozzi2] Hibike! Euphonium S3 - 05 '
              '(BD 1920x1080 x265-10Bit FLACx3).mkv',
          size: 900,
          progress: 1,
          index: 64,
        ),
      ],
    );

    final Map<int, VideoOrganizationFilePlan> byIndex =
        <int, VideoOrganizationFilePlan>{
      for (final VideoOrganizationFilePlan file in plan.files)
        file.backendFileIndex: file,
    };
    // 唯一的正片拿到 Season 目标，且拿到的是它自己的集号。
    expect(
      byIndex[64]!.targetRelativePath,
      '響け！ユーフォニアム３ (2024)/Season 03/'
      '響け！ユーフォニアム３ (2024) - S03E05.mkv',
    );
    expect(byIndex[64]!.episodeNumber, 5);
    // 特典一律镜像进 Extras/EXTRA/，且**不带集号**——带了就意味着它还在参与
    // 集号命名空间，撞号只是迟早的事。
    for (final int index in <int>[11, 16, 26, 13]) {
      expect(
        byIndex[index]!.targetRelativePath,
        startsWith('響け！ユーフォニアム３ (2024)/Extras/EXTRA/'),
        reason: 'index $index 应进 Extras',
      );
      expect(byIndex[index]!.episodeNumber, isNull, reason: 'index $index');
    }
    // Season 目录下有且只有正片一个文件。
    expect(
      plan.files
          .where(
            (VideoOrganizationFilePlan file) =>
                file.targetRelativePath.contains('/Season '),
          )
          .map((VideoOrganizationFilePlan file) => file.backendFileIndex),
      <int>[64],
    );
  });

  test(
      'numbered specials in SPs/Previews directories stay out of Season '
      '(BUG-1865)', () async {
    final Directory root = await Directory.systemTemp.createTemp(
      'fushi-organizer-vcb-extras-',
    );
    addTearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });
    // 第二个真实种子（VCB-Studio Hibike! Euphonium 2）：编号写在方括号里
    // （`[SP05]` `[Menu05]` `[WEB Preview05]`），与正片 `[05]` 同形。
    const String releaseRoot = '[VCB-Studio] Hibike! Euphonium 2 [Ma10p_1080p]';
    final VideoOrganizationPlan plan = const VideoDownloadOrganizer().plan(
      VideoOrganizationRequest(
        torrentId: 'hash',
        title: '響け！ユーフォニアム 2',
        year: 2016,
        kind: VideoOrganizationKind.episodic,
        defaultSeasonNumber: 2,
        sourceRoot: root.path,
        pathMapping: VideoDownloadPathMapping(
          remoteRoot: '/library',
          localRoot: root.path,
        ),
      ),
      <TorrentFileEntry>[
        const TorrentFileEntry(
          name: '$releaseRoot/'
              '[VCB-Studio] Hibike! Euphonium 2 [05][Ma10p_1080p][x265_flac_2aac].mkv',
          size: 900,
          progress: 1,
          index: 0,
        ),
        const TorrentFileEntry(
          name: '$releaseRoot\\SPs\\'
              '[VCB-Studio] Hibike! Euphonium 2 [SP05][Ma10p_1080p][x265_flac].mkv',
          size: 40,
          progress: 1,
          index: 1,
        ),
        const TorrentFileEntry(
          name: '$releaseRoot/SPs/'
              '[VCB-Studio] Hibike! Euphonium 2 [Menu05][Ma10p_1080p][x265_flac].mkv',
          size: 41,
          progress: 1,
          index: 2,
        ),
        const TorrentFileEntry(
          name: '$releaseRoot/Previews/'
              '[VCB-Studio] Hibike! Euphonium 2 [WEB Preview05][Ma10p_1080p][x265_flac].mkv',
          size: 42,
          progress: 1,
          index: 3,
        ),
      ],
    );

    final Map<int, VideoOrganizationFilePlan> byIndex =
        <int, VideoOrganizationFilePlan>{
      for (final VideoOrganizationFilePlan file in plan.files)
        file.backendFileIndex: file,
    };
    expect(
      byIndex[0]!.targetRelativePath,
      '響け！ユーフォニアム 2 (2016)/Season 02/'
      '響け！ユーフォニアム 2 (2016) - S02E05.mkv',
    );
    expect(
      byIndex[1]!.targetRelativePath,
      startsWith('響け！ユーフォニアム 2 (2016)/Extras/SPs/'),
    );
    expect(
      byIndex[2]!.targetRelativePath,
      startsWith('響け！ユーフォニアム 2 (2016)/Extras/SPs/'),
    );
    expect(
      byIndex[3]!.targetRelativePath,
      startsWith('響け！ユーフォニアム 2 (2016)/Extras/Previews/'),
    );
  });

  test('a Season subdirectory is not mistaken for an extras directory', () {
    // 特典判定只认词表里的目录名。`Season 1/` 这类真·正片目录不在表里，必须
    // 继续走集号解析——否则整季种子会被整批扫进 Extras，比撞号还糟。
    final VideoOrganizationPlan plan = const VideoDownloadOrganizer().plan(
      VideoOrganizationRequest(
        torrentId: 'hash',
        title: 'Show',
        kind: VideoOrganizationKind.episodic,
        sourceRoot: _localRoot,
        pathMapping: VideoDownloadPathMapping(
          remoteRoot: '/library',
          localRoot: _localRoot,
        ),
      ),
      <TorrentFileEntry>[
        const TorrentFileEntry(
          name: 'Show Complete/Season 1/Show - 01.mkv',
          size: 100,
          progress: 1,
          index: 0,
        ),
        const TorrentFileEntry(
          name: 'Show Complete/Extras/Show NCOP.mkv',
          size: 10,
          progress: 1,
          index: 1,
        ),
      ],
    );

    expect(
      plan.files.first.targetRelativePath,
      'Show/Season 01/Show - S01E01.mkv',
    );
    expect(plan.files.first.episodeNumber, 1);
    expect(
      plan.files.last.targetRelativePath,
      'Show/Extras/Extras/Show NCOP.mkv',
    );
  });

  test('a genuine duplicate still fails, and names both source files', () {
    // 撞号检查保留给**真**冲突（同一集两个文件）。修 BUG-1865 是把假冲突消掉，
    // 不是把冲突检查拆掉；消息必须点名两个源文件，否则用户无从判断删哪个。
    expect(
      () => const VideoDownloadOrganizer().plan(
        VideoOrganizationRequest(
          torrentId: 'hash',
          title: 'Show',
          kind: VideoOrganizationKind.episodic,
          sourceRoot: _localRoot,
          pathMapping: VideoDownloadPathMapping(
            remoteRoot: '/library',
            localRoot: _localRoot,
          ),
        ),
        <TorrentFileEntry>[
          const TorrentFileEntry(
            name: 'Show/Show - 01 [v1].mkv',
            size: 100,
            progress: 1,
            index: 0,
          ),
          const TorrentFileEntry(
            name: 'Show/Show - 01 [v2].mkv',
            size: 110,
            progress: 1,
            index: 1,
          ),
        ],
      ),
      throwsA(
        isA<FormatException>().having(
          (FormatException error) => error.message,
          'message',
          allOf(
            contains('organization target collision'),
            contains('Show - 01 [v1].mkv'),
            contains('Show - 01 [v2].mkv'),
          ),
        ),
      ),
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
