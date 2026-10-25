import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/backup_merge_engine.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;

import 'temp_dir_cleanup.dart';

/// v129 作品图谱的备份合并导入：端点里的合集 id / 游戏 id 是 src 库的本地身份，
/// 必须经合集自然键 / 游戏身份表重映射；合并是整行 LWW（含否决墓碑），重复导入
/// 幂等，本机落不了地的合集端点跳过。
void main() {
  Future<String> buildSrcDb(
    Future<void> Function(FushiDatabase src) seed,
  ) async {
    final Directory srcDir = await Directory.systemTemp.createTemp('ml_src_');
    addTearDown(() => cleanupTempDir(srcDir));
    final FushiDatabase src = FushiDatabase(srcDir.path);
    await seed(src);
    await src.close();
    return p.join(srcDir.path, 'fushi.db');
  }

  Future<void> attachAndMerge(FushiDatabase target, String srcDbPath) async {
    final String safe = srcDbPath.replaceAll(r'\', '/').replaceAll("'", "''");
    await target.customStatement("ATTACH DATABASE '$safe' AS mergesrc");
    await BackupMergeEngine(target).merge();
    await target.customStatement('DETACH DATABASE mergesrc');
  }

  test('合集 id 按自然键重映射；墓碑 LWW；备份独有合集落地后重映射；重复导入幂等', () async {
    late int srcAnime;
    final String srcDbPath = await buildSrcDb((FushiDatabase src) async {
      await src.createMediaCollection('Filler');
      srcAnime = await src.createMediaCollection('Clannad');
      final int srcOnly = await src.createMediaCollection('Only In Backup');
      await src.upsertManualMediaLink(
        relation: MediaLinkRelation.adaptation,
        from: (kind: MediaLinkKind.book, key: 'clannad-novel'),
        to: (kind: MediaLinkKind.videoCollection, key: '$srcAnime'),
        at: 100,
      );
      await src.upsertManualMediaLink(
        relation: MediaLinkRelation.sameWork,
        from: (kind: MediaLinkKind.book, key: 'x'),
        to: (kind: MediaLinkKind.videoCollection, key: '$srcOnly'),
        at: 100,
      );
      // 备份里是更新的否决墓碑：本机那条更旧的建议应被压成墓碑。
      await src.proposeMediaLink(
        relation: MediaLinkRelation.sameWork,
        from: (kind: MediaLinkKind.book, key: 'b'),
        to: (kind: MediaLinkKind.videoEpisode, key: 'video/b'),
        source: MediaLinkSource.ai,
        at: 50,
      );
      await src.removeMediaLink(
        mediaLinkIdFor(
          MediaLinkRelation.sameWork,
          (kind: MediaLinkKind.book, key: 'b'),
          (kind: MediaLinkKind.videoEpisode, key: 'video/b'),
        ),
        at: 60,
      );
    });

    final FushiDatabase target = FushiDatabase.forTesting(
      NativeDatabase.memory(),
    );
    addTearDown(target.close);
    final int targetAnime = await target.createMediaCollection('Clannad');
    expect(targetAnime, isNot(srcAnime), reason: '两库同名合集 id 不同，才测得到重映射');
    await target.proposeMediaLink(
      relation: MediaLinkRelation.sameWork,
      from: (kind: MediaLinkKind.book, key: 'b'),
      to: (kind: MediaLinkKind.videoEpisode, key: 'video/b'),
      source: MediaLinkSource.ai,
      at: 40,
    );

    await attachAndMerge(target, srcDbPath);
    Future<void> verify() async {
      final List<MediaLinkRow> anime = await target.mediaLinksForEndpoint(
        MediaLinkKind.videoCollection,
        '$targetAnime',
      );
      expect(anime, hasLength(1));
      expect(anime.single.fromKey, 'clannad-novel');
      expect(anime.single.isUserConfirmed, isTrue);
      // 备份独有的合集先被 _mergeMediaCollections 按自然键建进本机，连接随后
      // 重映射到本机新 id（不是照抄 src 的 id）。
      final MediaCollectionRow? onlyInBackup = await target
          .getMediaCollectionByNaturalKey('Only In Backup', 'collection');
      expect(onlyInBackup, isNotNull);
      final List<MediaLinkRow> x = await target.mediaLinksForEndpoint(
        MediaLinkKind.book,
        'x',
      );
      expect(x, hasLength(1));
      expect(x.single.toKey, '${onlyInBackup!.id}');
      expect(
        await target.mediaLinksForEndpoint(MediaLinkKind.book, 'b'),
        isEmpty,
        reason: '备份里更新的否决墓碑压过本机旧建议',
      );
    }

    await verify();
    final int rows = (await target.allMediaLinks()).length;
    await attachAndMerge(target, srcDbPath);
    await verify();
    expect(await target.allMediaLinks(), hasLength(rows), reason: '重复导入幂等');
  });
}
