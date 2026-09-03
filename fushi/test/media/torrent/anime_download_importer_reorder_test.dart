import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/torrent/anime_download_importer.dart';
import 'package:fushi/src/media/torrent/anime_download_plan.dart';
import 'package:fushi/src/media/torrent/anime_download_service.dart'
    show AnimeDownloadImportOutcome;
import 'package:fushi_core/fushi_core.dart';

/// BUG-1896：播放器「选集」横排缩略图乱序（用户报 `13 | 01 02 | 07 08 | 05 | 03 04 06`）。
///
/// 根因是番剧下载入库**只排本批**：`sortVideoPathsByEpisode` 给本次完成的路径排序，
/// 但 `importSplitPlaylist` 对已存在的合集是尾插（`_nextCollectionSortIndex` 取 max+1），
/// 于是每批下载成为「批内升序、整段追加到表尾」的区块，跨批次顺序 = 下载完成先后。
/// 而卡片角标是渲染时从文件名现算的**真集号**，两条通道打架，才会出现「角标写着 13
/// 的卡排在第一位」。
///
/// 仓库里本来就有确定性修序原语 `reorderDownloadedCollectionEpisodes`（下载中心
/// pipeline 一直在调），番剧下载这条路漏了。本测试守的是**接线**，不是原语本身：
/// 直接跑真实的 `buildAnimeDownloadImporter` 回调，断言入库后合集成员顺序 = 集号顺序。
/// 把 importer 里那一行 reorder 删掉，两个用例都会红。
FushiDatabase _memDb() => FushiDatabase.forTesting(NativeDatabase.memory());

AnimeDownloadPlan _plan({required String series}) => AnimeDownloadPlan(
      id: 'infohash-$series',
      createdAtMs: 0,
      seriesTitle: series,
      torrentTitle: series,
      magnet: 'magnet:?xt=urn:btih:infohash-$series',
      qbCategory: 'anime',
      // coverUrl 留空：封面是 best-effort 旁路，本用例只关心成员顺序。
    );

Future<List<String>> _memberKeys(FushiDatabase db, int collectionId) async {
  final List<MediaCollectionItemRow> members = await db.getCollectionItems(
    collectionId,
  );
  return members
      .where(
        (MediaCollectionItemRow m) => m.mediaType == MediaKind.video.dbValue,
      )
      .map((MediaCollectionItemRow m) => m.entryKey)
      .toList();
}

void main() {
  test('单批乱序完成：入库后合集成员按集号有序（不是任务完成先后）', () async {
    final FushiDatabase db = _memDb();
    addTearDown(db.close);

    final importer = buildAnimeDownloadImporter(db);
    // 独立任务的完成顺序天然是乱的 —— 这正是用户截图里 13 排第一位的来源。
    final AnimeDownloadImportOutcome? outcome =
        await importer(_plan(series: 'Re Zero S4'), <String>[
      '/dl/Re Zero S4 - S04E13.mkv',
      '/dl/Re Zero S4 - S04E01.mkv',
      '/dl/Re Zero S4 - S04E07.mkv',
      '/dl/Re Zero S4 - S04E02.mkv',
    ]);

    expect(outcome, isNotNull, reason: '入库应成功');
    expect(
        await _memberKeys(db, outcome!.collectionId),
        <String>[
          'video/Re Zero S4 - S04E01',
          'video/Re Zero S4 - S04E02',
          'video/Re Zero S4 - S04E07',
          'video/Re Zero S4 - S04E13',
        ],
        reason: '合集成员顺序必须是集号序');
  });

  test('分批到达：后到的低集号必须插回正确位置，而不是追加到表尾（BUG-1896 的真实形状）', () async {
    final FushiDatabase db = _memDb();
    addTearDown(db.close);

    final importer = buildAnimeDownloadImporter(db);
    final AnimeDownloadPlan plan = _plan(series: 'Re Zero S4');

    // 第一批：13 先下完。
    final AnimeDownloadImportOutcome? first = await importer(plan, <String>[
      '/dl/Re Zero S4 - S04E13.mkv',
    ]);
    expect(first, isNotNull);

    // 第二批：01 / 02 后下完。合集按自然键复用，成员是尾插 —— 修复前这里会得到
    // [13, 01, 02]，也就是用户截图里那个「批次内升序、批次间断裂」的形状。
    final AnimeDownloadImportOutcome? second = await importer(plan, <String>[
      '/dl/Re Zero S4 - S04E02.mkv',
      '/dl/Re Zero S4 - S04E01.mkv',
    ]);
    expect(second, isNotNull);
    expect(second!.collectionId, first!.collectionId, reason: '同名系列必须复用同一个合集');

    expect(
      await _memberKeys(db, second.collectionId),
      <String>[
        'video/Re Zero S4 - S04E01',
        'video/Re Zero S4 - S04E02',
        'video/Re Zero S4 - S04E13',
      ],
      reason: '每次入库都要重排**整个合集**，否则跨批次顺序 = 下载完成先后',
    );
  });
}
