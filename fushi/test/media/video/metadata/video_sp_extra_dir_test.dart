// BUG-5035：发布组 BDRip 的 `SP` / `SPs` 特典目录要判成本地特典，不能当独立剧集进
// 刮削计划（否则按解析出的标题「SP」误绑到无关剧，反馈 gtpgyff3l7）。
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/source_library/source_library_row.dart';
import 'package:fushi_engine/media/video/metadata/video_local_extra_classifier.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_models.dart';
import 'package:fushi_engine/media/video/metadata/video_source_work_planner.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// 当前平台分隔符的绝对路径（分类器按 `p.split` 切目录段）。
String _nativePath(List<String> segments) =>
    p.joinAll(<String>[if (Platform.isWindows) r'D:\' else '/', ...segments]);

const String _movieDir =
    '[DBD-Raws][摄影机不要停！][正片+特典映像][1080P][BDRip][HEVC-10bit][FLAC]';

void main() {
  test('SP / SPs release directories classify as local extras', () {
    for (final String dir in <String>['SP', 'SPs', 'sps']) {
      expect(
        classifyLocalVideoExtra(
          _nativePath(<String>[
            'Movies',
            _movieDir,
            dir,
            '[DBD-Raws][One Cut of the Dead][SP][01][1080P][BDRip]'
                '[HEVC-10bit][FLAC].mkv',
          ]),
        )?.kind,
        VideoMetadataExtraKind.extra,
        reason: dir,
      );
    }
    // 只认整段目录名：标题里带 SP 字样的作品目录、文件名里的 `[SP]` 标签不算。
    expect(
      classifyLocalVideoExtra(
        _nativePath(<String>['Shows', 'SPY x FAMILY', 'SPY x FAMILY - 01.mkv']),
      ),
      isNull,
    );
    expect(
      classifyLocalVideoExtra(
        _nativePath(<String>['Movies', _movieDir, 'One Cut of the Dead.mkv']),
      ),
      isNull,
    );
  });

  test('planner keeps SP directory episodes out of the scrape plan', () async {
    final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final String root = _nativePath(<String>['Movies']);
    final int sourceId = await db.insertMediaSource(
      MediaSourcesCompanion.insert(
        label: 'Movies',
        mediaKind: 'video',
        rootPath: root,
        createdAt: 1,
      ),
    );
    final String moviePath = _nativePath(<String>[
      'Movies',
      _movieDir,
      '[DBD-Raws][One Cut of the Dead][1080P][BDRip][HEVC-10bit][FLAC].mkv',
    ]);
    await db.upsertVideoBook(
      VideoBooksCompanion(
        bookUid: const Value<String>('movie'),
        title: const Value<String>('One Cut of the Dead'),
        videoPath: Value<String>(moviePath),
        sourceId: Value<int?>(sourceId),
      ),
    );
    for (int i = 1; i <= 4; i++) {
      final String n = i.toString().padLeft(2, '0');
      await db.upsertVideoBook(
        VideoBooksCompanion(
          bookUid: Value<String>('sp-$n'),
          title: Value<String>('SP $n'),
          videoPath: Value<String>(
            _nativePath(<String>[
              'Movies',
              _movieDir,
              'SP',
              '[DBD-Raws][One Cut of the Dead][SP][$n][1080P][BDRip]'
                  '[HEVC-10bit][FLAC].mkv',
            ]),
          ),
          sourceId: Value<int?>(sourceId),
        ),
      );
    }
    final SourceLibraryRow source = (await db.getMediaSourceById(sourceId))!;

    final List<VideoSourceScrapeWork> works = await VideoSourceWorkPlanner(
      db,
    ).plan(source);

    final List<String> plannedUids = <String>[
      for (final VideoSourceScrapeWork work in works)
        for (final VideoBookRow member in work.members) member.bookUid,
    ];
    expect(plannedUids, <String>['movie']);
  });
}
