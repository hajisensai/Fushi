import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/torrent/torrent_backend.dart';
import 'package:fushi_engine/media/torrent/video_resource_provider.dart';
import 'package:fushi_engine/media/video/download/video_download_backend_identity.dart';
import 'package:fushi_engine/media/video/download/video_download_organizer.dart';
import 'package:fushi_engine/media/video/download/video_download_path_mapping.dart';
import 'package:fushi_engine/media/video/download/video_download_pipeline_service.dart';
import 'package:fushi_engine/media/video/download/video_resource_registry.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_provider.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_resolver.dart';
import 'package:fushi_engine/media/video/metadata/video_source_scrape_config.dart';
import 'package:fushi_engine/media/video/metadata/video_source_scrape_coordinator.dart';
import 'package:fushi_engine/media/video/video_sidecar.dart'
    show listSidecarSubtitles;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// 随视频发布的外挂字幕 / 外挂音轨跟视频一起整理（用户库实证：110 个 `.ass`、9 个
/// `.mka` 停在原发布目录，视频已改名搬走；留下的整片 `.mka` 被当成「歌」收进音乐库）。

final String _localRoot = Platform.isWindows
    ? r'C:\Media\Downloads'
    : '/Media/Downloads';

VideoOrganizationPlan _plan(
  List<String> names, {
  required String title,
  required int? year,
  required VideoOrganizationKind kind,
  bool legacy = false,
  int largestIndex = 0,
}) => const VideoDownloadOrganizer().plan(
  VideoOrganizationRequest(
    torrentId: 'hash',
    title: title,
    year: year,
    kind: kind,
    sourceRoot: _localRoot,
    pathMapping: VideoDownloadPathMapping(
      remoteRoot: '/library',
      localRoot: _localRoot,
    ),
    legacyUnderscoreNames: legacy,
  ),
  <TorrentFileEntry>[
    for (int i = 0; i < names.length; i++)
      TorrentFileEntry(
        name: names[i],
        size: i == largestIndex ? 1000 : 10,
        progress: 1,
        index: i,
      ),
  ],
);

/// 原路径 → 目标路径（只含计划里的文件）。
Map<String, String> _targets(VideoOrganizationPlan plan) => <String, String>{
  for (final VideoOrganizationFilePlan file in plan.files)
    file.originalRelativePath: file.targetRelativePath,
};

void main() {
  group('整理计划带走配对的外挂件', () {
    test('剧集：同目录 .chs.ass / .cht.ass 跟视频改名进 Season 目录，播放器认得出', () {
      const String dir =
          '[SweetSub&VCB-Studio] Oniichan ha Oshimai! [Ma10p_1080p]';
      const String ep1 =
          '$dir/[SweetSub&VCB-Studio] Oniichan ha Oshimai! '
          '[01][Ma10p_1080p][x265_flac_2ac3]';
      const String ep2 =
          '$dir/[SweetSub&VCB-Studio] Oniichan ha Oshimai! '
          '[02][Ma10p_1080p][x265_flac_2ac3]';
      final VideoOrganizationPlan plan = _plan(
        <String>[
          '$ep1.mkv',
          '$ep1.chs.ass',
          '$ep1.cht.ass',
          '$ep2.mkv',
          '$ep2.chs.ass',
          '$dir/Scans/01.png',
          '$dir/CDs/01.flac',
          '$dir/ReadMe.txt',
        ],
        title: 'お兄ちゃんはおしまい！',
        year: 2023,
        kind: VideoOrganizationKind.episodic,
      );
      final Map<String, String> targets = _targets(plan);
      const String season = 'お兄ちゃんはおしまい！ (2023)/Season 01';
      expect(targets['$ep1.mkv'], '$season/お兄ちゃんはおしまい！ (2023) - S01E01.mkv');
      expect(
        targets['$ep1.chs.ass'],
        '$season/お兄ちゃんはおしまい！ (2023) - S01E01.chs.ass',
      );
      expect(
        targets['$ep1.cht.ass'],
        '$season/お兄ちゃんはおしまい！ (2023) - S01E01.cht.ass',
      );
      expect(
        targets['$ep2.chs.ass'],
        '$season/お兄ちゃんはおしまい！ (2023) - S01E02.chs.ass',
      );
      // 扫图 / CD / 说明文件不配对，不进计划（原地不动）。
      expect(targets.containsKey('$dir/Scans/01.png'), isFalse);
      expect(targets.containsKey('$dir/CDs/01.flac'), isFalse);
      expect(targets.containsKey('$dir/ReadMe.txt'), isFalse);

      final VideoOrganizationFilePlan chs = plan.files.singleWhere(
        (VideoOrganizationFilePlan f) =>
            f.originalRelativePath == '$ep1.chs.ass',
      );
      expect(chs.companion, VideoReleaseCompanionKind.subtitle);
      expect(chs.companionOfBackendFileIndex, 0);
      expect(chs.episodeNumber, isNull);
      // 落位名必须能被播放器的外挂字幕发现规则认回这一集。
      expect(
        listSidecarSubtitles('お兄ちゃんはおしまい！ (2023) - S01E01', <String>[
          'お兄ちゃんはおしまい！ (2023) - S01E01.mkv',
          'お兄ちゃんはおしまい！ (2023) - S01E01.chs.ass',
          'お兄ちゃんはおしまい！ (2023) - S01E01.cht.ass',
        ]),
        hasLength(2),
      );
      // 外挂件排在全部视频之后（视频先落位）。
      final int lastVideo = plan.files.lastIndexWhere(
        (VideoOrganizationFilePlan f) => f.companion == null,
      );
      final int firstCompanion = plan.files.indexWhere(
        (VideoOrganizationFilePlan f) => f.companion != null,
      );
      expect(firstCompanion, greaterThan(lastVideo));
    });

    test('电影：子目录 Audio 5.1 / Audio Guide 的外挂音轨落到正片旁、改成「主干.」开头', () {
      const String dir =
          '[Beatrice-Raws] Tenki no Ko [BDRip 1920x1080 HEVC TrueHD]';
      const String stem = dir;
      final VideoOrganizationPlan plan = _plan(
        <String>[
          '$dir/$stem.mkv',
          '$dir/Audio 5.1/${stem}_Eng_Audio_5.1.mka',
          '$dir/Audio 5.1/${stem}_Jpn_Audio_5.1.mka',
          '$dir/Audio Guide/$stem.Audio Guide.mka',
          '$dir/Scans/01.jpg',
        ],
        title: '天気の子',
        year: 2019,
        kind: VideoOrganizationKind.movie,
      );
      final Map<String, String> targets = _targets(plan);
      expect(targets['$dir/$stem.mkv'], '天気の子 (2019)/天気の子 (2019).mkv');
      expect(
        targets['$dir/Audio 5.1/${stem}_Eng_Audio_5.1.mka'],
        '天気の子 (2019)/天気の子 (2019).Eng_Audio_5.1.mka',
      );
      expect(
        targets['$dir/Audio 5.1/${stem}_Jpn_Audio_5.1.mka'],
        '天気の子 (2019)/天気の子 (2019).Jpn_Audio_5.1.mka',
      );
      expect(
        targets['$dir/Audio Guide/$stem.Audio Guide.mka'],
        '天気の子 (2019)/天気の子 (2019).Audio Guide.mka',
      );
      expect(targets.containsKey('$dir/Scans/01.jpg'), isFalse);
      expect(
        plan.files
            .where((VideoOrganizationFilePlan f) => f.companion != null)
            .map((VideoOrganizationFilePlan f) => f.companion)
            .toSet(),
        <VideoReleaseCompanionKind>{VideoReleaseCompanionKind.audio},
      );
    });

    test('电影：同目录同名主干的整片 .mka 跟正片走', () {
      const String stem =
          '[VCB-Studio] Doraemon Nobita no Getsumen Tansaki '
          '[Ma10p_1080p][x265_flac]';
      final Map<String, String> targets = _targets(
        _plan(
          <String>['$stem/$stem.mkv', '$stem/$stem.mka'],
          title: 'ドラえもん のび太の月面探査記',
          year: 2019,
          kind: VideoOrganizationKind.movie,
        ),
      );
      expect(
        targets['$stem/$stem.mka'],
        'ドラえもん のび太の月面探査記 (2019)/ドラえもん のび太の月面探査記 (2019).mka',
      );
    });

    test('纯数字主干：同目录照常配对，子目录里的同号音频不误配', () {
      final Map<String, String> targets = _targets(
        _plan(
          <String>[
            'Show/01.mkv',
            'Show/02.mkv',
            'Show/01.ass',
            'Show/CDs/01.flac',
            'Show/CDs/02.flac',
            'Show/Audio/01.mka',
          ],
          title: 'Show',
          year: 2020,
          kind: VideoOrganizationKind.episodic,
        ),
      );
      expect(
        targets['Show/01.ass'],
        'Show (2020)/Season 01/Show (2020) - S01E01.ass',
      );
      expect(targets.containsKey('Show/CDs/01.flac'), isFalse);
      expect(targets.containsKey('Show/CDs/02.flac'), isFalse);
      expect(targets.containsKey('Show/Audio/01.mka'), isFalse);
    });

    test('特典视频的外挂字幕跟着进 Extras；主干后不是分隔符的不配', () {
      final Map<String, String> targets = _targets(
        _plan(
          <String>[
            'Pack/Show - 01.mkv',
            'Pack/Show - 01.ja.srt',
            'Pack/SPs/Show NCOP.mkv',
            'Pack/SPs/Show NCOP.ja.ass',
            'Pack/SPs/Show NCOP2.mkv',
            'Pack/SPs/Show NCOP2.ass',
          ],
          title: 'Show',
          year: 2020,
          kind: VideoOrganizationKind.episodic,
        ),
      );
      expect(
        targets['Pack/Show - 01.ja.srt'],
        'Show (2020)/Season 01/Show (2020) - S01E01.ja.srt',
      );
      expect(
        targets['Pack/SPs/Show NCOP.ja.ass'],
        'Show (2020)/Extras/SPs/Show NCOP.ja.ass',
      );
      expect(
        targets['Pack/SPs/Show NCOP2.ass'],
        'Show (2020)/Extras/SPs/Show NCOP2.ass',
      );
    });

    test('后缀不合播放器规则的文字字幕折成单段标记；legacy 任务沿用 _ 替身', () {
      Map<String, String> targetsFor({required bool legacy}) => _targets(
        _plan(
          <String>[
            '[G] Re Zero - 03 [1080p].mkv',
            '[G] Re Zero - 03 [1080p].sc&jp.ass',
            '[G] Re Zero - 03 [1080p].sc.forced.ass',
            '[G] Re Zero - 03 [1080p].sup',
          ],
          title: 'Re:Zero',
          year: 2016,
          kind: VideoOrganizationKind.episodic,
          legacy: legacy,
        ),
      );
      final Map<String, String> current = targetsFor(legacy: false);
      expect(
        current['[G] Re Zero - 03 [1080p].sc&jp.ass'],
        'Re：Zero (2016)/Season 01/Re：Zero (2016) - S01E03.sc_jp.ass',
      );
      expect(
        current['[G] Re Zero - 03 [1080p].sc.forced.ass'],
        'Re：Zero (2016)/Season 01/Re：Zero (2016) - S01E03.sc_forced.ass',
      );
      expect(
        current['[G] Re Zero - 03 [1080p].sup'],
        'Re：Zero (2016)/Season 01/Re：Zero (2016) - S01E03.sup',
      );
      expect(
        targetsFor(legacy: true)['[G] Re Zero - 03 [1080p].sc&jp.ass'],
        'Re_Zero (2016)/Season 01/Re_Zero (2016) - S01E03.sc_jp.ass',
      );
    });

    test('崩溃重放：视频与外挂件都已在目标名，重算得到同一组路径（不再改名）', () {
      final VideoOrganizationPlan plan = _plan(
        <String>[
          'Show (2026)/Season 01/Show (2026) - S01E01.mkv',
          'Show (2026)/Season 01/Show (2026) - S01E01.chs.ass',
        ],
        title: 'Show',
        year: 2026,
        kind: VideoOrganizationKind.episodic,
      );
      for (final VideoOrganizationFilePlan file in plan.files) {
        expect(file.targetRelativePath, file.originalRelativePath);
      }
      expect(plan.files, hasLength(2));
    });

    test('撞名的外挂件原地不动，不让整条任务失败', () {
      final List<VideoCompanionMove> moves = planVideoReleaseCompanions(
        videos: const <VideoCompanionAnchor>[
          VideoCompanionAnchor(
            backendFileIndex: 0,
            sourceRelativePath: 'R/ep01.mkv',
            targetRelativePath: 'W/Season 01/W - S01E01.mkv',
          ),
        ],
        candidates: const <VideoCompanionCandidate>[
          VideoCompanionCandidate(
            backendFileIndex: 1,
            relativePath: 'R/ep01.chs&jp.ass',
          ),
          VideoCompanionCandidate(
            backendFileIndex: 2,
            relativePath: 'R/ep01.chs_jp.ass',
          ),
          VideoCompanionCandidate(
            backendFileIndex: 3,
            relativePath: 'R/ep01.mka',
          ),
        ],
        reservedTargets: const <String>['W/Season 01/W - S01E01.mka'],
      );
      // 排序后 `chs&jp` 先占 `.chs_jp.ass`，`chs_jp` 撞名留在原地；`.mka` 撞上已占
      // 目标，同样不动。
      expect(moves.map((VideoCompanionMove m) => m.backendFileIndex), <int>[1]);
    });
  });

  group('存量补搬（流水线启动时）', () {
    test('已完成任务遗留在原发布目录的配对外挂件经后端改名补搬，幂等；CD 不动', () async {
      final List<List<String>> relocated = <List<String>>[];
      final _Env env = await _Env.create(
        onRelocated: (List<String> from) async => relocated.add(from),
      );
      addTearDown(env.close);
      const String rel = '[Grp] Show [1080p]';
      const String videoOriginal = '$rel/[Grp] Show [01][1080p].mkv';
      const String videoTarget =
          'Show (2026)/Season 01/Show (2026) - S01E01.mkv';
      final List<String> names = <String>[
        videoTarget,
        '$rel/[Grp] Show [01][1080p].chs.ass',
        '$rel/Audio/[Grp] Show [01][1080p]_Eng.mka',
        '$rel/CDs/01.flac',
      ];
      for (final String name in names) {
        await env.write(name);
      }
      env.backend.names.addAll(<int, String>{
        for (int i = 0; i < names.length; i++) i: names[i],
      });
      await env.insertJob('job-1');
      await env.insertFile(
        'job-1',
        index: 0,
        original: videoOriginal,
        current: videoTarget,
        target: videoTarget,
        kind: 'video',
      );
      for (int i = 1; i < names.length; i++) {
        await env.insertFile(
          'job-1',
          index: i,
          original: names[i],
          current: names[i],
        );
      }

      expect(await env.service.relocateStrandedReleaseCompanions(), 2);
      final Map<int, VideoDownloadJobFileRow> rows = await env.rows('job-1');
      const String season = 'Show (2026)/Season 01';
      expect(
        rows[1]!.currentRelativePath,
        '$season/Show (2026) - S01E01.chs.ass',
      );
      expect(
        rows[1]!.targetRelativePath,
        '$season/Show (2026) - S01E01.chs.ass',
      );
      expect(
        rows[1]!.finalAbsolutePath,
        p.join(
          env.root.path,
          'Show (2026)',
          'Season 01',
          'Show (2026) - S01E01.chs.ass',
        ),
      );
      expect(rows[1]!.kind, videoDownloadCompanionFileKind);
      expect(rows[1]!.status, VideoDownloadJobFileStatus.organized);
      expect(
        rows[2]!.currentRelativePath,
        '$season/Show (2026) - S01E01.Eng.mka',
      );
      expect(
        File(
          p.join(
            env.root.path,
            'Show (2026)',
            'Season 01',
            'Show (2026) - S01E01.Eng.mka',
          ),
        ).existsSync(),
        isTrue,
      );
      expect(rows[3]!.currentRelativePath, '$rel/CDs/01.flac');
      expect(rows[3]!.targetRelativePath, isNull);
      expect(env.backend.renameCalls, 2);
      // 搬走前的本机路径报给宿主（误收进音乐库的整片外挂音轨要按它对账）。
      expect(
        relocated.single,
        unorderedEquals(<String>[
          p.join(env.root.path, rel, '[Grp] Show [01][1080p].chs.ass'),
          p.join(env.root.path, rel, 'Audio', '[Grp] Show [01][1080p]_Eng.mka'),
        ]),
      );

      // 再跑一次：没有可搬的了，后端也不再碰，也不再通知。
      expect(await env.service.relocateStrandedReleaseCompanions(), 0);
      expect(env.backend.renameCalls, 2);
      expect(relocated, hasLength(1));
    });

    test('上一轮后端已改名、没来得及写库：只补写文件行', () async {
      final _Env env = await _Env.create();
      addTearDown(env.close);
      const String videoTarget =
          'Show (2026)/Season 01/Show (2026) - S01E01.mkv';
      const String companionTarget =
          'Show (2026)/Season 01/Show (2026) - S01E01.ja.srt';
      await env.write(videoTarget);
      await env.write(companionTarget);
      env.backend.names.addAll(<int, String>{
        0: videoTarget,
        1: companionTarget,
      });
      await env.insertJob('job-2');
      await env.insertFile(
        'job-2',
        index: 0,
        original: 'R/ep01.mkv',
        current: videoTarget,
        target: videoTarget,
        kind: 'video',
      );
      await env.insertFile(
        'job-2',
        index: 1,
        original: 'R/ep01.ja.srt',
        current: 'R/ep01.ja.srt',
      );

      expect(await env.service.relocateStrandedReleaseCompanions(), 1);
      expect(env.backend.renameCalls, 0);
      expect(
        (await env.rows('job-2'))[1]!.currentRelativePath,
        companionTarget,
      );
    });

    test('整理在视频改名后、外挂件改名前崩溃：行上留着旧意图，照样补搬', () async {
      final _Env env = await _Env.create();
      addTearDown(env.close);
      const String videoTarget =
          'Show (2026)/Season 01/Show (2026) - S01E01.mkv';
      const String companionOriginal = 'R/ep01.chs.ass';
      const String companionTarget =
          'Show (2026)/Season 01/Show (2026) - S01E01.chs.ass';
      await env.write(videoTarget);
      await env.write(companionOriginal);
      env.backend.names.addAll(<int, String>{
        0: videoTarget,
        1: companionOriginal,
      });
      await env.insertJob('crashed');
      await env.insertFile(
        'crashed',
        index: 0,
        original: 'R/ep01.mkv',
        current: videoTarget,
        target: videoTarget,
        kind: 'video',
      );
      // `_persistOrganizationIntent` 已写下外挂件的目标与 kind，改名没来得及做。
      await env.insertFile(
        'crashed',
        index: 1,
        original: companionOriginal,
        current: companionOriginal,
        target: companionTarget,
        kind: videoDownloadCompanionFileKind,
      );

      expect(await env.service.relocateStrandedReleaseCompanions(), 1);
      expect(env.backend.renameCalls, 1);
      final VideoDownloadJobFileRow row = (await env.rows('crashed'))[1]!;
      expect(row.currentRelativePath, companionTarget);
      expect(
        File(
          p.joinAll(<String>[env.root.path, ...companionTarget.split('/')]),
        ).existsSync(),
        isTrue,
      );
      expect(await env.service.relocateStrandedReleaseCompanions(), 0);
    });

    test('视频已从磁盘删除 / 任务已无后端会话：跳过，不硬搬', () async {
      final _Env env = await _Env.create();
      addTearDown(env.close);
      const String videoTarget =
          'Show (2026)/Season 01/Show (2026) - S01E01.mkv';
      await env.write('R/ep01.ass');
      env.backend.names.addAll(<int, String>{0: videoTarget, 1: 'R/ep01.ass'});
      await env.insertJob('gone-video');
      await env.insertFile(
        'gone-video',
        index: 0,
        original: 'R/ep01.mkv',
        current: videoTarget,
        target: videoTarget,
        kind: 'video',
      );
      await env.insertFile(
        'gone-video',
        index: 1,
        original: 'R/ep01.ass',
        current: 'R/ep01.ass',
      );
      await env.insertJob('no-backend', torrentReleased: true);
      await env.insertFile(
        'no-backend',
        index: 0,
        original: 'R/ep01.mkv',
        current: videoTarget,
        target: videoTarget,
        kind: 'video',
      );
      await env.insertFile(
        'no-backend',
        index: 1,
        original: 'R/ep01.ass',
        current: 'R/ep01.ass',
      );
      // 视频从没写到磁盘上（已被用户删除）；第二条的种子已摘（无后端会话）。

      expect(await env.service.relocateStrandedReleaseCompanions(), 0);
      expect(env.backend.renameCalls, 0);
      expect((await env.rows('gone-video'))[1]!.targetRelativePath, isNull);
      expect((await env.rows('no-backend'))[1]!.targetRelativePath, isNull);
    });
  });
}

const VideoDownloadBackendIdentity _identity = VideoDownloadBackendIdentity(
  kind: 'embedded',
  profileId: 'embedded',
  fingerprint: 'installation-fingerprint',
);

class _Env {
  _Env._(this.database, this.root, this.sourceId, this.backend, this.service);

  final FushiDatabase database;
  final Directory root;
  final int sourceId;
  final _RenamingBackend backend;
  final VideoDownloadPipelineService service;

  static Future<_Env> create({
    Future<void> Function(List<String> movedFrom)? onRelocated,
  }) async {
    final FushiDatabase database = FushiDatabase.forTesting(
      NativeDatabase.memory(),
    );
    final Directory root = await Directory.systemTemp.createTemp(
      'fushi-release-companions-',
    );
    final int sourceId = await database.insertMediaSource(
      MediaSourcesCompanion.insert(
        label: 'Managed videos',
        mediaKind: 'video',
        rootPath: root.path,
        createdAt: 1,
      ),
    );
    final _RenamingBackend backend = _RenamingBackend(root);
    final VideoDownloadPipelineService service = VideoDownloadPipelineService(
      database: database,
      resourceRegistry: VideoResourceRegistry(const <VideoResourceProvider>[]),
      backendResolver: (_) async =>
          VideoDownloadBackendBinding(backend: backend, identity: _identity),
      scrapeCoordinator: VideoSourceScrapeCoordinator(
        database: database,
        config: const VideoSourceScrapeGlobalConfig(),
        registry: VideoMetadataProviderRegistry(
          const <VideoMetadataProvider>[],
        ),
      ),
      workerId: 'companion-test-worker',
      onReleaseCompanionsRelocated: onRelocated,
    );
    return _Env._(database, root, sourceId, backend, service);
  }

  Future<void> write(String relative) async {
    final File file = File(
      p.joinAll(<String>[root.path, ...relative.split('/')]),
    );
    await file.parent.create(recursive: true);
    await file.writeAsString(relative);
  }

  Future<void> insertJob(String jobId, {bool torrentReleased = false}) {
    const String hash = '0123456789abcdef0123456789abcdef01234567';
    return database.upsertVideoDownloadJob(
      VideoDownloadJobsCompanion.insert(
        jobId: jobId,
        resourceProvider: 'nyaa:test-instance',
        selectedResourceId: 'release-$jobId',
        torrentHash: Value<String?>(torrentReleased ? null : hash),
        backendTaskId: Value<String?>(torrentReleased ? null : hash),
        mediaKind: 'tv',
        title: 'Show',
        year: const Value<int?>(2026),
        season: const Value<int?>(1),
        backendKind: _identity.kind,
        backendProfileId: Value<String?>(_identity.profileId),
        fingerprint: _identity.fingerprint,
        targetSourceId: Value<int?>(sourceId),
        organizationPolicy: const Value<String>('library'),
        lifecycle: const Value<String>(VideoDownloadJobLifecycle.completed),
        stage: const Value<String>(VideoDownloadJobStage.scrape),
        createdAt: 1,
        updatedAt: 1,
      ),
    );
  }

  Future<void> insertFile(
    String jobId, {
    required int index,
    required String original,
    required String current,
    String? target,
    String kind = 'other',
  }) => database.upsertVideoDownloadJobFile(
    VideoDownloadJobFilesCompanion.insert(
      jobId: jobId,
      backendFileIndex: Value<int?>(index),
      originalRelativePath: original,
      currentRelativePath: current,
      targetRelativePath: Value<String?>(target),
      finalAbsolutePath: Value<String?>(
        target == null
            ? null
            : p.joinAll(<String>[root.path, ...target.split('/')]),
      ),
      kind: Value<String>(kind),
      status: Value<String>(
        target == null
            ? VideoDownloadJobFileStatus.downloaded
            : VideoDownloadJobFileStatus.organized,
      ),
      createdAt: 1,
      updatedAt: 1,
    ),
  );

  Future<Map<int, VideoDownloadJobFileRow>> rows(String jobId) async =>
      <int, VideoDownloadJobFileRow>{
        for (final VideoDownloadJobFileRow row
            in await database.getVideoDownloadJobFiles(jobId))
          row.backendFileIndex!: row,
      };

  Future<void> close() async {
    await service.dispose();
    await database.close();
    try {
      await root.delete(recursive: true);
    } on FileSystemException {
      // 临时目录清不掉不影响断言。
    }
  }
}

/// 按种子内相对路径真改磁盘上的文件（保存位置 = 来源根），模拟内置引擎的改名。
class _RenamingBackend implements TorrentBackend {
  _RenamingBackend(this.root);

  final Directory root;
  final Map<int, String> names = <int, String>{};
  int renameCalls = 0;

  String _abs(String relative) =>
      p.joinAll(<String>[root.path, ...relative.split('/')]);

  @override
  Future<List<TorrentFileEntry>> listFiles(String torrentId) async =>
      <TorrentFileEntry>[
        for (final MapEntry<int, String> e in names.entries)
          TorrentFileEntry(name: e.value, size: 1, progress: 1, index: e.key),
      ];

  @override
  Future<TorrentStorageResult> renameFile(
    String torrentId,
    int fileIndex,
    String newPath,
  ) async {
    renameCalls += 1;
    final String? from = names[fileIndex];
    if (from == null) return const TorrentStorageResult.failure('no such file');
    final File target = File(_abs(newPath));
    await target.parent.create(recursive: true);
    await File(_abs(from)).rename(target.path);
    names[fileIndex] = newPath;
    return TorrentStorageResult(ok: true, path: newPath);
  }

  @override
  Future<TorrentStorageResult> moveStorage(
    String torrentId,
    String newSavePath,
  ) async => TorrentStorageResult(ok: true, path: newSavePath);

  @override
  Future<bool> addTorrent(
    String magnetOrUrl, {
    required String category,
    String? savePath,
    bool sequential = false,
    bool firstLastPiecePrio = false,
  }) async => true;

  @override
  Future<List<TorrentSnapshot>> listTorrents({String? category}) async =>
      const <TorrentSnapshot>[];

  @override
  Future<bool> prepareCategory(String category) async => true;

  @override
  Future<String?> probeConnection() async => 'fake';

  @override
  void close() {}
}
