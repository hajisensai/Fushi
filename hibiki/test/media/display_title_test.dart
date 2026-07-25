import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/media.dart';
import 'package:hibiki/src/media/display_title.dart';
import 'package:hibiki/src/mining/galgame_library.dart';
import 'package:hibiki/src/mining/metadata/galgame_metadata_draft.dart';
import 'package:hibiki/src/mining/metadata/galgame_metadata_merge.dart';
import 'package:hibiki_core/hibiki_core.dart';

/// P4 display-title 门面纯函数单测：三通道（item / bookKey / srtUid）分派、
/// `canEdit:false` 静默失效坑、game/stat-row 回退语义。
///
/// override 存储是 [MediaSource] 的同步偏好层（测试进程内存表），与
/// override_identity_test 同款 setup：写 override 用与编辑弹窗同一入口
/// [MediaSource.setOverrideTitleFromMediaItem]，teardown 清除防串号。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final ReaderHibikiSource source = ReaderHibikiSource.instance;

  /// 与 `_overrideTitleForIdentifier` 同款合成 item（canEdit:true 是坑位——
  /// false 时 getOverrideTitleFromMediaItem 静默返 null）。
  MediaItem itemFor(String mediaIdentifier, {bool canEdit = true}) {
    return MediaItem(
      mediaIdentifier: mediaIdentifier,
      title: 'RAW',
      mediaTypeIdentifier: source.mediaType.uniqueKey,
      mediaSourceIdentifier: source.uniqueKey,
      position: 0,
      duration: 1,
      canDelete: false,
      canEdit: canEdit,
    );
  }

  Future<void> setOverride(String mediaIdentifier, String? title) =>
      source.setOverrideTitleFromMediaItem(
        item: itemFor(mediaIdentifier),
        title: title,
      );

  group('displayTitleForBook', () {
    test('bookKey 通道：无 override 回退 raw，有 override 返回 override', () async {
      const String bookKey = 'p4_facade_book_a';
      final String id = ReaderHibikiSource.mediaIdentifierFor(bookKey);
      addTearDown(() => setOverride(id, null));

      expect(
        displayTitleForBook(bookKey: bookKey, rawTitle: '原名'),
        '原名',
      );
      await setOverride(id, '新名A');
      expect(
        displayTitleForBook(bookKey: bookKey, rawTitle: '原名'),
        '新名A',
      );
    });

    test('srtUid 通道：standalone SRT 身份独立解析', () async {
      const String uid = 'p4_facade_srt_a';
      final String id = ReaderHibikiSource.mediaIdentifierForSrtUid(uid);
      addTearDown(() => setOverride(id, null));

      expect(displayTitleForBook(srtUid: uid, rawTitle: '字幕书'), '字幕书');
      await setOverride(id, '新字幕名');
      expect(displayTitleForBook(srtUid: uid, rawTitle: '字幕书'), '新字幕名');
    });

    test('双通道分派：bookKey 非空压过 srtUid，bookKey 空串回落 srtUid', () async {
      const String bookKey = 'p4_facade_book_b';
      const String uid = 'p4_facade_srt_b';
      final String epubId = ReaderHibikiSource.mediaIdentifierFor(bookKey);
      final String srtId = ReaderHibikiSource.mediaIdentifierForSrtUid(uid);
      addTearDown(() => setOverride(epubId, null));
      addTearDown(() => setOverride(srtId, null));

      await setOverride(epubId, 'EPUB身份名');
      await setOverride(srtId, 'SRT身份名');
      // bookKey 非空 → EPUB 共享身份（BUG-1018 A3 / _srtBookMediaItem 同分派）。
      expect(
        displayTitleForBook(bookKey: bookKey, srtUid: uid, rawTitle: 'raw'),
        'EPUB身份名',
      );
      // bookKey 空串哨兵 → standalone SRT 身份。
      expect(
        displayTitleForBook(bookKey: '', srtUid: uid, rawTitle: 'raw'),
        'SRT身份名',
      );
    });

    test('item 通道：canEdit:false 静默拿不到 override（坑位守卫），true 正常', () async {
      const String bookKey = 'p4_facade_book_c';
      final String id = ReaderHibikiSource.mediaIdentifierFor(bookKey);
      addTearDown(() => setOverride(id, null));
      await setOverride(id, '新名C');

      expect(
        displayTitleForBook(item: itemFor(id), rawTitle: 'RAW'),
        '新名C',
      );
      // canEdit:false → getOverrideTitleFromMediaItem 静默返 null → 回落
      // item.title。合成 MediaItem 必须 canEdit:true 的契约由此锁死。
      expect(
        displayTitleForBook(item: itemFor(id, canEdit: false), rawTitle: 'RAW'),
        'RAW',
      );
    });

    test('三通道全空：原样返回 raw', () {
      expect(
        displayTitleForBook(bookKey: '', srtUid: '', rawTitle: '兜底'),
        '兜底',
      );
    });
  });

  group('displayTitleForVideo', () {
    test('显式 no-op：raw 列值即显示名（视频改名直写列）', () async {
      final HibikiDatabase db =
          HibikiDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      await db.upsertVideoBook(
        VideoBooksCompanion.insert(
          bookUid: 'p4_v1',
          title: '视频显示名',
          videoPath: '/tmp/p4.mp4',
        ),
      );
      final VideoBookRow row = (await db.getVideoBookByBookUid('p4_v1'))!;
      expect(displayTitleForVideo(row), '视频显示名');
    });
  });

  group('displayTitleForGame', () {
    GalgameEntry entry({
      String name = '本地名',
      GalgameCustomData customData = const GalgameCustomData(),
      GalgameMetadataDraft metadata = const GalgameMetadataDraft(),
    }) {
      return GalgameEntry(
        id: 'g1',
        name: name,
        exePath: r'C:\game\game.exe',
        workdir: r'C:\game',
        addedAt: DateTime.fromMillisecondsSinceEpoch(0),
        customData: customData,
        metadata: metadata,
      );
    }

    test('entry 为 null 回退 raw（活动快照原文）', () {
      expect(displayTitleForGame(entry: null, rawTitle: '快照名'), '快照名');
    });

    test('委托 displayName：customData.name > nameCn > name', () {
      expect(
        displayTitleForGame(
          entry: entry(
            customData: const GalgameCustomData(name: '用户改名'),
            metadata: const GalgameMetadataDraft(nameCn: '中文名'),
          ),
          rawTitle: 'raw',
        ),
        '用户改名',
      );
      expect(
        displayTitleForGame(
          entry: entry(metadata: const GalgameMetadataDraft(nameCn: '中文名')),
          rawTitle: 'raw',
        ),
        '中文名',
      );
      expect(displayTitleForGame(entry: entry(), rawTitle: 'raw'), '本地名');
    });
  });

  group('displayTitleForStatRow', () {
    test('反查不到 bookKey 原样返回；命中后走 bookKey override 通道', () async {
      const String bookKey = 'p4_facade_stat_a';
      final String id = ReaderHibikiSource.mediaIdentifierFor(bookKey);
      addTearDown(() => setOverride(id, null));
      final Map<String, String> byTitle = <String, String>{'统计原名': bookKey};

      expect(
        displayTitleForStatRow(rawTitle: '不在表里', bookKeyByTitle: byTitle),
        '不在表里',
      );
      expect(
        displayTitleForStatRow(rawTitle: '统计原名', bookKeyByTitle: byTitle),
        '统计原名',
      );
      await setOverride(id, '统计新名');
      expect(
        displayTitleForStatRow(rawTitle: '统计原名', bookKeyByTitle: byTitle),
        '统计新名',
      );
    });
  });
}
