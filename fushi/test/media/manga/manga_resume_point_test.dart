import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fushi/src/media/manga/library/manga_resume_point.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_entry.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi_core/fushi_core.dart';

/// 在线漫画「重新打开时回到哪里」两种口径（反馈 dj8EDpVFVX：重新打开总是回到
/// 进度而不是最后读的地方，希望能像读书一样回到最后阅读位置）。
///
/// 默认（furthestProgress）必须逐字保持旧行为；lastPosition 只在「读完过的章」
/// 上与之分歧。
void main() {
  // 源按新→旧返回：下标 0 = 第 3 话（最新），2 = 第 1 话（最旧）。
  final OnlineMangaLibraryEntry entry = OnlineMangaLibraryEntry(
    runtime: OnlineMangaRuntimeKind.mihon,
    extensionPackage: 'org.example',
    sourceId: '1',
    series: const OnlineMangaSeries(
      key: '/s',
      title: 'Fixture',
      raw: <String, Object?>{},
    ),
    chapters: const <OnlineMangaChapter>[
      OnlineMangaChapter(key: '/c/3', name: '3', raw: <String, Object?>{}),
      OnlineMangaChapter(key: '/c/2', name: '2', raw: <String, Object?>{}),
      OnlineMangaChapter(key: '/c/1', name: '1', raw: <String, Object?>{}),
    ],
  );

  MangaChapterStateRow state(
    String key, {
    required int updatedAt,
    int lastPage = 0,
    int? pageCount = 20,
    int? readAt,
  }) => MangaChapterStateRow(
    bookUid: 'u',
    chapterKey: key,
    lastPage: lastPage,
    lastFraction: -1,
    pageCount: pageCount,
    readAt: readAt,
    updatedAt: updatedAt,
  );

  group('偏好键', () {
    test('默认值是旧行为（最远进度），未知值回落默认', () {
      expect(kMangaResumeTargetDefault, MangaResumeTarget.furthestProgress.key);
      expect(
        MangaResumeTargetKey.fromKey(kMangaResumeTargetDefault),
        MangaResumeTarget.furthestProgress,
      );
      expect(
        MangaResumeTargetKey.fromKey('last'),
        MangaResumeTarget.lastPosition,
      );
      expect(
        MangaResumeTargetKey.fromKey('garbage'),
        MangaResumeTarget.furthestProgress,
      );
      for (final MangaResumeTarget target in MangaResumeTarget.values) {
        expect(MangaResumeTargetKey.fromKey(target.key), target);
      }
    });

    test('偏好写穿 DB，换一个仓库实例读回同值', () async {
      final FushiDatabase db = FushiDatabase.forTesting(
        NativeDatabase.memory(),
      );
      addTearDown(db.close);
      final PreferencesRepository prefs = PreferencesRepository(db);
      await prefs.loadFromDb();
      expect(prefs.mangaResumeTarget, kMangaResumeTargetDefault);
      expect(prefs.mangaChapterListNewestFirst, isTrue, reason: '旧行为：新→旧');

      await prefs.setMangaResumeTarget(MangaResumeTarget.lastPosition.key);
      await prefs.setMangaChapterListNewestFirst(false);

      final PreferencesRepository reloaded = PreferencesRepository(db);
      await reloaded.loadFromDb();
      expect(reloaded.mangaResumeTarget, 'last');
      expect(reloaded.mangaChapterListNewestFirst, isFalse);
    });
  });

  group('继续阅读落到哪一章', () {
    test('一次没读过：两种口径都回到最旧那话', () {
      for (final MangaResumeTarget target in MangaResumeTarget.values) {
        expect(
          continueMangaChapterIndex(
            entry,
            const <String, MangaChapterStateRow>{},
            target: target,
          ),
          2,
        );
      }
    });

    test('最近读的那章没读完：两种口径都回到它', () {
      final Map<String, MangaChapterStateRow> states =
          <String, MangaChapterStateRow>{
            '/c/1': state('/c/1', updatedAt: 10, lastPage: 5),
          };
      for (final MangaResumeTarget target in MangaResumeTarget.values) {
        expect(continueMangaChapterIndex(entry, states, target: target), 2);
      }
    });

    test('重读一章以前读完过的旧章停在中间：最远进度跳过它，最后位置回到它', () {
      // 第 1 话以前读完（readAt 一经写入就一直留着），现在重读停在第 8 页；
      // 第 3 话很早以前读过。
      final Map<String, MangaChapterStateRow> states =
          <String, MangaChapterStateRow>{
            '/c/3': state('/c/3', updatedAt: 5, lastPage: 19, readAt: 5),
            '/c/1': state('/c/1', updatedAt: 50, lastPage: 7, readAt: 1),
          };
      expect(
        continueMangaChapterIndex(
          entry,
          states,
          target: MangaResumeTarget.furthestProgress,
        ),
        1,
        reason: '旧行为：读完过就前进一话',
      );
      expect(
        continueMangaChapterIndex(
          entry,
          states,
          target: MangaResumeTarget.lastPosition,
        ),
        2,
        reason: '最后阅读位置：回到停下的那一章',
      );
    });

    test('停在一章末尾：两种口径都前进一话；最新一话读完则停在原地', () {
      final Map<String, MangaChapterStateRow> atEnd =
          <String, MangaChapterStateRow>{
            '/c/2': state('/c/2', updatedAt: 9, lastPage: 19, readAt: 9),
          };
      final Map<String, MangaChapterStateRow> newestDone =
          <String, MangaChapterStateRow>{
            '/c/3': state('/c/3', updatedAt: 9, lastPage: 19, readAt: 9),
          };
      for (final MangaResumeTarget target in MangaResumeTarget.values) {
        expect(continueMangaChapterIndex(entry, atEnd, target: target), 0);
        expect(continueMangaChapterIndex(entry, newestDone, target: target), 0);
      }
    });

    test('「标记已读」批量写的行没有页信息：两种口径都按读完算', () {
      final Map<String, MangaChapterStateRow> states =
          <String, MangaChapterStateRow>{
            '/c/1': state('/c/1', updatedAt: 9, pageCount: null, readAt: 9),
          };
      for (final MangaResumeTarget target in MangaResumeTarget.values) {
        expect(continueMangaChapterIndex(entry, states, target: target), 1);
      }
    });
  });

  // BUG-3246：首页「继续」等直接开书（没点名章）以前用 currentChapterIndex（最后一次
  // 选的章），与作品页「继续阅读」的偏好判据分叉——读完第 2 话退出，作品页继续去第 3
  // 话、直接开书却回到第 2 话第 1 页。
  group('阅读器开书落到哪一章', () {
    final OnlineMangaLibraryEntry selected2 = entry.copyWith(
      currentChapterIndex: 1,
    );
    final Map<String, MangaChapterStateRow> finished2 =
        <String, MangaChapterStateRow>{
          '/c/1': state('/c/1', updatedAt: 1, lastPage: 19, readAt: 1),
          '/c/2': state('/c/2', updatedAt: 2, lastPage: 19, readAt: 2),
        };

    test('没点名：与作品页「继续阅读」同一判据，不看最后一次选的章', () {
      for (final MangaResumeTarget target in MangaResumeTarget.values) {
        expect(
          mangaReaderOpenChapterIndex(selected2, finished2, target: target),
          continueMangaChapterIndex(selected2, finished2, target: target),
          reason: target.name,
        );
        expect(
          mangaReaderOpenChapterIndex(selected2, finished2, target: target),
          0,
          reason: '${target.name}：第 2 话读完了，前进到第 3 话',
        );
      }
    });

    test('点名了（作品页点某一章）：就是那一章，哪怕它读完过', () {
      for (final MangaResumeTarget target in MangaResumeTarget.values) {
        expect(
          mangaReaderOpenChapterIndex(
            selected2,
            finished2,
            requested: 2,
            target: target,
          ),
          2,
        );
      }
    });

    test('点名的下标越界：退回偏好判据', () {
      expect(
        mangaReaderOpenChapterIndex(selected2, finished2, requested: 9),
        0,
      );
      expect(
        mangaReaderOpenChapterIndex(selected2, finished2, requested: -1),
        0,
      );
    });
  });

  group('一章从第几页开始', () {
    test('没有进度 / 没翻过页：第 1 页', () {
      for (final MangaResumeTarget target in MangaResumeTarget.values) {
        expect(resolveMangaChapterResumePoint(null, target: target), 0);
        expect(
          resolveMangaChapterResumePoint(
            state('/c/1', updatedAt: 1),
            target: target,
          ),
          0,
        );
      }
    });

    test('没读完：两种口径都回到停下的那页', () {
      final MangaChapterStateRow partial = state(
        '/c/1',
        updatedAt: 1,
        lastPage: 6,
      );
      for (final MangaResumeTarget target in MangaResumeTarget.values) {
        expect(resolveMangaChapterResumePoint(partial, target: target), 6);
      }
    });

    test('读完过、重读停在中间：最远进度从头，最后位置回到那页', () {
      final MangaChapterStateRow reread = state(
        '/c/1',
        updatedAt: 1,
        lastPage: 6,
        readAt: 1,
      );
      expect(
        resolveMangaChapterResumePoint(
          reread,
          target: MangaResumeTarget.furthestProgress,
        ),
        0,
      );
      expect(
        resolveMangaChapterResumePoint(
          reread,
          target: MangaResumeTarget.lastPosition,
        ),
        6,
      );
    });

    test('停在最后一页：两种口径都从头（不落在章末卡片上）', () {
      final MangaChapterStateRow done = state(
        '/c/1',
        updatedAt: 1,
        lastPage: 19,
        readAt: 1,
      );
      for (final MangaResumeTarget target in MangaResumeTarget.values) {
        expect(resolveMangaChapterResumePoint(done, target: target), 0);
      }
    });
  });
}
