import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_audio/fushi_audio.dart'
    show kFavoriteSentenceTombstoneType;
import 'package:fushi_core/fushi_core.dart';

/// 命名统一 Phase 3.4 守卫：四个平行字符串值域的枚举化（活动事件 / 统计来源 /
/// Profile 绑定 / sync 删除墓碑）——落库串永不改变（Never break userspace）、
/// tryParse 容忍未知值、跨域映射表穷尽且冻结（模式照 media_kind_test /
/// media_kind_persistence_guard_test）。
void main() {
  group('ActivityMediaKind（activity_events.media_type）', () {
    test('dbValue 集合守卫：恰为 {book, video, game}，与常量逐字节一致', () {
      expect(
        ActivityMediaKind.values
            .map((ActivityMediaKind k) => k.dbValue)
            .toSet(),
        <String>{'book', 'video', 'game'},
      );
      expect(ActivityMediaKind.book.dbValue, kActivityMediaBook);
      expect(ActivityMediaKind.video.dbValue, kActivityMediaVideo);
      expect(ActivityMediaKind.game.dbValue, kActivityMediaGame);
      expect(kActivityMediaBook, 'book');
      expect(kActivityMediaVideo, 'video');
      expect(kActivityMediaGame, 'game');
    });

    test('tryParse：三个已知值命中，null/未知/它域串返 null 不抛', () {
      expect(ActivityMediaKind.tryParse('book'), ActivityMediaKind.book);
      expect(ActivityMediaKind.tryParse('video'), ActivityMediaKind.video);
      expect(ActivityMediaKind.tryParse('game'), ActivityMediaKind.game);
      expect(ActivityMediaKind.tryParse(null), isNull);
      expect(ActivityMediaKind.tryParse(''), isNull);
      // 'epub' 是合集/书架域的串，绝不误命中（book ≠ epub）。
      expect(ActivityMediaKind.tryParse('epub'), isNull);
      expect(ActivityMediaKind.tryParse('BOOK'), isNull, reason: '大小写敏感');
    });

    test('typed 写入落库串不变：addActivityEvent → DB 读回裸 book 串', () async {
      final FushiDatabase db =
          FushiDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      await db.addActivityEvent(
        eventType: kActivityRead,
        mediaType: ActivityMediaKind.book.dbValue,
        title: 'T',
        dateKey: '2026-07-27',
        timestampMs: 1,
      );
      final rows = await db.getRecentActivityEvents(limit: 10);
      expect(rows.single.mediaType, 'book');
    });
  });

  group('StatSourceKind（4 张统计表 source_type）', () {
    test('dbValue 集合守卫：恰为 {book, video}，与移入 core 的常量一致', () {
      expect(
        StatSourceKind.values.map((StatSourceKind k) => k.dbValue).toSet(),
        <String>{'book', 'video'},
      );
      expect(StatSourceKind.book.dbValue, kStatSourceBook);
      expect(StatSourceKind.video.dbValue, kStatSourceVideo);
      expect(kStatSourceBook, 'book');
      expect(kStatSourceVideo, 'video');
    });

    test('tryParse：两个已知值命中，null/未知/它域串返 null 不抛', () {
      expect(StatSourceKind.tryParse('book'), StatSourceKind.book);
      expect(StatSourceKind.tryParse('video'), StatSourceKind.video);
      expect(StatSourceKind.tryParse(null), isNull);
      expect(StatSourceKind.tryParse('epub'), isNull);
      expect(StatSourceKind.tryParse('game'), isNull,
          reason: '游戏不入 book/video 统计域');
    });
  });

  group('ProfileMediaKind（media_type_profiles.media_type）', () {
    test('dbValue 集合守卫：恰为 {epub, srtbook, audiobook, lyrics, video}', () {
      expect(
        ProfileMediaKind.values.map((ProfileMediaKind k) => k.dbValue).toSet(),
        <String>{'epub', 'srtbook', 'audiobook', 'lyrics', 'video'},
      );
      expect(ProfileMediaKind.epub.dbValue, 'epub');
      expect(ProfileMediaKind.srtbook.dbValue, 'srtbook');
      expect(ProfileMediaKind.audiobook.dbValue, 'audiobook');
      expect(ProfileMediaKind.lyrics.dbValue, 'lyrics');
      expect(ProfileMediaKind.video.dbValue, 'video');
    });

    test('tryParse：五个已知值命中，null/未知/它域串返 null 不抛', () {
      expect(ProfileMediaKind.tryParse('epub'), ProfileMediaKind.epub);
      expect(ProfileMediaKind.tryParse('srtbook'), ProfileMediaKind.srtbook);
      expect(
          ProfileMediaKind.tryParse('audiobook'), ProfileMediaKind.audiobook);
      expect(ProfileMediaKind.tryParse('lyrics'), ProfileMediaKind.lyrics);
      expect(ProfileMediaKind.tryParse('video'), ProfileMediaKind.video);
      expect(ProfileMediaKind.tryParse(null), isNull);
      // 'srt' 是合集/书架域的串（srtbook ≠ srt）、'book' 是活动/统计域的串。
      expect(ProfileMediaKind.tryParse('srt'), isNull);
      expect(ProfileMediaKind.tryParse('book'), isNull);
    });
  });

  group('SyncTombstoneKind（sync_deletion_tombstones.media_type）', () {
    test('dbValue 集合守卫：5 资产 + 2 收藏集合，恰为 7 值', () {
      expect(
        SyncTombstoneKind.values
            .map((SyncTombstoneKind k) => k.dbValue)
            .toSet(),
        <String>{
          'book',
          'audiobook',
          // BUG-1338（PR#666「从所有设备删除」死角根治）新增：字幕书自己的墓碑
          // 种类。它落库串是 'srtbook'，与 ProfileMediaKind 的同名串同形但分属
          // 两个值域，跨域换算仍走 media_kind_mappings。
          'srtbook',
          'video',
          'localaudio',
          'favoriteword',
          'favoritesentence',
        },
      );
      expect(SyncTombstoneKind.book.dbValue, 'book');
      expect(SyncTombstoneKind.audiobook.dbValue, 'audiobook');
      expect(SyncTombstoneKind.srtbook.dbValue, 'srtbook');
      expect(SyncTombstoneKind.video.dbValue, 'video');
      expect(SyncTombstoneKind.localaudio.dbValue, 'localaudio');
      expect(SyncTombstoneKind.favoriteword.dbValue, 'favoriteword');
      expect(SyncTombstoneKind.favoritesentence.dbValue, 'favoritesentence');
      // hibiki_audio 的墓碑常量与本枚举同串（两处真相一致性钉死）。
      expect(kFavoriteSentenceTombstoneType,
          SyncTombstoneKind.favoritesentence.dbValue);
    });

    test('tryParse：七个已知值命中，null/未知/它域串返 null 不抛', () {
      expect(SyncTombstoneKind.tryParse('book'), SyncTombstoneKind.book);
      expect(
          SyncTombstoneKind.tryParse('audiobook'), SyncTombstoneKind.audiobook);
      expect(SyncTombstoneKind.tryParse('srtbook'), SyncTombstoneKind.srtbook);
      expect(SyncTombstoneKind.tryParse('video'), SyncTombstoneKind.video);
      expect(SyncTombstoneKind.tryParse('localaudio'),
          SyncTombstoneKind.localaudio);
      expect(SyncTombstoneKind.tryParse('favoriteword'),
          SyncTombstoneKind.favoriteword);
      expect(SyncTombstoneKind.tryParse('favoritesentence'),
          SyncTombstoneKind.favoritesentence);
      expect(SyncTombstoneKind.tryParse(null), isNull);
      // 'epub' 是合集/书架域的串（book ≠ epub）。
      expect(SyncTombstoneKind.tryParse('epub'), isNull);
      expect(SyncTombstoneKind.tryParse('unknown-future'), isNull);
    });

    test('typed 写入落库串不变：writeSyncDeletionTombstone → DB 读回裸串', () async {
      final FushiDatabase db =
          FushiDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      await db.writeSyncDeletionTombstone(
          SyncTombstoneKind.localaudio.dbValue, 'Lib', 100);
      final rows = await db.getSyncDeletionTombstonesOfType('localaudio');
      expect(rows.single.mediaType, 'localaudio');
      expect(rows.single.itemKey, 'Lib');
    });
  });

  group('跨域映射表（media_kind_mappings.dart）', () {
    test('activityMediaKindOf 穷尽且冻结：epub/srt→book, video→video, game→game', () {
      // 穷尽：对每个 MediaKind 都有定义（switch 表达式由编译器保证，此处
      // 冻结具体映射对，防有人改表不过审）。
      expect(activityMediaKindOf(MediaKind.epub), ActivityMediaKind.book);
      expect(activityMediaKindOf(MediaKind.srt), ActivityMediaKind.book);
      expect(activityMediaKindOf(MediaKind.video), ActivityMediaKind.video);
      expect(activityMediaKindOf(MediaKind.game), ActivityMediaKind.game);
      expect(MediaKind.values.map(activityMediaKindOf).toSet(),
          ActivityMediaKind.values.toSet(),
          reason: '每个活动种类都至少有一个书架种类来源');
    });

    test('shelfKindsOfActivityMedia 穷尽、有序（epub 优先 srt 回退）且与正向映射互逆', () {
      expect(shelfKindsOfActivityMedia(ActivityMediaKind.book),
          <MediaKind>[MediaKind.epub, MediaKind.srt]);
      expect(shelfKindsOfActivityMedia(ActivityMediaKind.video),
          <MediaKind>[MediaKind.video]);
      expect(shelfKindsOfActivityMedia(ActivityMediaKind.game),
          <MediaKind>[MediaKind.game]);
      // 互逆：反向映射列出的每个书架种类，正向映射必须折回同一活动种类。
      for (final ActivityMediaKind a in ActivityMediaKind.values) {
        for (final MediaKind k in shelfKindsOfActivityMedia(a)) {
          expect(activityMediaKindOf(k), a);
        }
      }
      // 全覆盖：每个书架种类恰好出现在一个活动种类的反向列表里。
      final List<MediaKind> all = <MediaKind>[
        for (final ActivityMediaKind a in ActivityMediaKind.values)
          ...shelfKindsOfActivityMedia(a),
      ];
      expect(all.toSet(), MediaKind.values.toSet());
      expect(all.length, MediaKind.values.length, reason: '无重复归属');
    });

    test('statSourceKindOf 穷尽且冻结：epub/srt→book, video→video, game→null', () {
      expect(statSourceKindOf(MediaKind.epub), StatSourceKind.book);
      expect(statSourceKindOf(MediaKind.srt), StatSourceKind.book);
      expect(statSourceKindOf(MediaKind.video), StatSourceKind.video);
      expect(statSourceKindOf(MediaKind.game), isNull,
          reason: '游戏不入 book/video 统计');
    });
  });
}
