/// DLsite galgame 元数据 adapter（契约 §2.2）。
///
/// 协议与解析在引擎 [DlsiteClient]（app 与无头服务端共用），本类只把 [DlsiteWork] 映射成
/// [GalgameMetadataDraft]。DLsite 是同人 / 商业游戏的一手商店：编号（`RJ` / `VJ`）是作品的
/// 全局身份，下载包与安装目录基本都以它命名，所以「从路径认编号 → 直取」是本源最强的一路。
library;

import 'package:fushi/src/mining/galgame_library.dart';
import 'package:fushi/src/mining/metadata/galgame_metadata_adapter.dart';
import 'package:fushi/src/mining/metadata/galgame_metadata_draft.dart';
import 'package:fushi_engine/media/metadata/dlsite/dlsite_client.dart';
import 'package:fushi_engine/mining/metadata/galgame_metadata_source.dart';

/// 标签上限（与 VNDB 同量级，防一部作品几十个标签挤满详情页）。
const int kDlsiteMaxTags = 30;

class DlsiteMetadataAdapter extends GalgameMetadataAdapter {
  DlsiteMetadataAdapter({DlsiteClient? client})
    : _client = client ?? DlsiteClient(),
      _ownsClient = client == null;

  final DlsiteClient _client;
  final bool _ownsClient;

  @override
  GalgameMetadataSource get source => GalgameMetadataSource.dlsite;

  @override
  bool validateId(String id) => DlsiteWorkId.tryParse(id) != null;

  @override
  String externalUrl(String id) =>
      DlsiteWorkId.tryParse(id)?.pageUrl ??
      'https://www.dlsite.com/maniax/work/=/product_id/${id.trim()}.html';

  @override
  Future<GalgameMetadataDraft?> fetchById(String id) async {
    final DlsiteWorkId? workId = DlsiteWorkId.tryParse(id);
    if (workId == null) {
      throw GalgameMetadataException(
        'invalid DLsite work id: "$id"',
        source: source,
      );
    }
    final DlsiteWork? work;
    try {
      work = await _client.fetchWork(workId, withRating: true);
    } on DlsiteException catch (e) {
      throw GalgameMetadataException(
        e.message,
        source: source,
        statusCode: e.statusCode,
      );
    }
    return work == null ? null : dlsiteWorkToGalgameDraft(work);
  }

  @override
  Future<List<SourceCandidate>> searchByName(
    String name, {
    int limit = 10,
  }) async {
    final List<DlsiteSearchCandidate> found;
    try {
      found = await _client.search(
        name,
        categories: const <DlsiteWorkCategory>{DlsiteWorkCategory.game},
        limit: limit,
      );
    } on DlsiteException catch (e) {
      throw GalgameMetadataException(
        e.message,
        source: source,
        statusCode: e.statusCode,
      );
    }
    return <SourceCandidate>[
      for (final DlsiteSearchCandidate c in found)
        SourceCandidate(
          source: source,
          externalId: c.id.value,
          name: c.title,
          coverUrl: c.guessedCoverUrl,
          summary: summaryExcerpt(c.description),
        ),
    ];
  }

  @override
  void close() {
    if (_ownsClient) _client.close();
  }
}

/// 纯函数：DLsite 作品 → galgame draft。
///
/// 开发商取社团名；评分 5 分制 ×2 归一到 0-10；成人向 → `nsfw: true`，全年龄 / R-15 →
/// `false`（DLsite 的分级是明确的，不同于「源没给」的 null）。
GalgameMetadataDraft dlsiteWorkToGalgameDraft(DlsiteWork work) {
  final DlsiteAgeCategory? age = work.ageCategory;
  final double? score = work.rating?.scoreOutOfTen;
  return GalgameMetadataDraft(
    name: work.title,
    allTitles: draftStringList(<Object?>[work.title, work.seriesName]),
    summary: draftString(work.description),
    tags: work.genres.take(kDlsiteMaxTags).toList(growable: false),
    developer: draftString(work.circle),
    releaseDate: _isoDate(work.releaseDate),
    score: score == null ? null : (score * 100).roundToDouble() / 100,
    nsfw: age?.isAdult,
    coverUrl: work.coverUrl,
    externalId: work.id.value,
  );
}

/// 从游戏条目认出 DLsite 编号：先看显示名，再看 exe 路径（安装目录多以编号命名）。
DlsiteWorkId? dlsiteWorkIdOfGalgame(GalgameEntry game) =>
    DlsiteWorkId.findIn(game.displayName) ?? DlsiteWorkId.findIn(game.exePath);

String? _isoDate(DateTime? d) {
  if (d == null) return null;
  String two(int n) => n.toString().padLeft(2, '0');
  return '${d.year.toString().padLeft(4, '0')}-${two(d.month)}-${two(d.day)}';
}
