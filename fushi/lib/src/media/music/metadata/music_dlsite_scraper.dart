/// 音声 / ASMR 专辑的 DLsite 资料（拍板台 NCzkl6oLnf）app 侧装配：专辑 → 作品编号
/// （`musicAlbumDlsiteWorkId`）→ DLsite product.json + 评分端点 → 原始快照落
/// `music_metadata_raw_snapshots` → 专辑没有封面时补 DLsite 主图。
///
/// 只认作品编号（文件夹 / 专辑名 / 目录编号里带的 `RJ…`），不按名模糊搜。
/// 出站经 `DlsiteClient`（全应用代理装配、跨实例 700 ms 节流）。
library;

import 'dart:io';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/storage/app_paths.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/metadata/dlsite/dlsite_client.dart';
import 'package:fushi_engine/media/metadata/image_download.dart';
import 'package:fushi_engine/media/music/metadata/music_dlsite_album.dart';
import 'package:fushi_engine/media/music/metadata/music_metadata_models.dart';
import 'package:path/path.dart' as p;

/// 按请求区域造 DLsite 客户端（测试注入假客户端）。
typedef MusicDlsiteClientFactory = DlsiteClient Function(String locale);

/// 一张专辑的 DLsite 状态：认出的编号 + 已取到的快照（没取过为 null）。
class MusicDlsiteAlbumInfo {
  const MusicDlsiteAlbumInfo({required this.id, this.snapshot, this.fetchedAt});

  final DlsiteWorkId id;
  final MusicDlsiteSnapshot? snapshot;

  /// 快照写入时刻（毫秒）。
  final int? fetchedAt;

  bool get fetched => snapshot != null;
}

/// 曲库批量取 DLsite 资料的统计。
class MusicDlsiteLibraryReport {
  /// 认出编号、这次需要取的专辑数。
  int total = 0;

  /// 取到作品资料的。
  int matched = 0;

  /// DLsite 上查无此作的。
  int notFound = 0;

  /// 网络 / 结构错误的。
  int failed = 0;

  Map<String, Object?> toJson() => <String, Object?>{
    'total': total,
    'matched': matched,
    'notFound': notFound,
    'failed': failed,
  };
}

/// 界面语言对应的 DLsite 请求区域。
String musicDlsiteLocaleForApp() {
  final AppLocale l = LocaleSettings.currentLocale;
  return dlsiteLocaleFor(l.languageCode, countryCode: l.countryCode);
}

class MusicDlsiteScraper {
  MusicDlsiteScraper({
    required FushiDatabase? Function() database,
    String Function()? locale,
    MusicDlsiteClientFactory? clientFactory,
    Future<File> Function(String url)? downloadImage,
    Future<Directory> Function()? coverDirectory,
    int Function()? clock,
  }) : _database = database,
       _locale = locale ?? musicDlsiteLocaleForApp,
       _clientFactory =
           clientFactory ?? ((String l) => DlsiteClient(locale: l)),
       _download = downloadImage ?? downloadImageToTempFile,
       _coverDirectory = coverDirectory ?? AppPaths.musicCoversDirectory,
       _clock = clock ?? (() => DateTime.now().millisecondsSinceEpoch);

  final FushiDatabase? Function() _database;
  final String Function() _locale;
  final MusicDlsiteClientFactory _clientFactory;
  final Future<File> Function(String url) _download;
  final Future<Directory> Function() _coverDirectory;
  final int Function() _clock;

  static final String _provider = MusicMetadataProviderKind.dlsite.wire;

  /// 专辑对应的作品编号（专辑不在 / 认不出为 null）。
  Future<DlsiteWorkId?> workIdForAlbum(String albumUid) async {
    final FushiDatabase? db = _database();
    if (db == null) return null;
    final MusicAlbumRow? album = await db.getMusicAlbum(albumUid);
    if (album == null) return null;
    return _workIdOf(album, await db.listMusicTracks(albumUid: albumUid));
  }

  DlsiteWorkId? _workIdOf(MusicAlbumRow album, List<MusicTrackRow> tracks) =>
      musicAlbumDlsiteWorkId(
        title: album.title,
        catalogNo: album.catalogNo,
        trackPaths: <String>[for (final MusicTrackRow t in tracks) t.path],
      );

  /// 专辑的编号与已缓存的快照；认不出编号为 null。不发请求。
  Future<MusicDlsiteAlbumInfo?> albumInfo(String albumUid) async {
    final FushiDatabase? db = _database();
    if (db == null) return null;
    final DlsiteWorkId? id = await workIdForAlbum(albumUid);
    if (id == null) return null;
    return _cached(db, id);
  }

  /// 作品 [id] 已缓存的快照（没取过时 `snapshot` 为 null）。不发请求。
  Future<MusicDlsiteAlbumInfo?> cachedInfo(DlsiteWorkId id) async {
    final FushiDatabase? db = _database();
    return db == null ? null : _cached(db, id);
  }

  Future<MusicDlsiteAlbumInfo> _cached(
    FushiDatabase db,
    DlsiteWorkId id,
  ) async {
    final MusicMetadataRawSnapshotRow? row = await db.getMusicRawSnapshot(
      provider: _provider,
      snapshotKind: kMusicDlsiteSnapshotKind,
      externalId: id.value,
    );
    if (row == null) return MusicDlsiteAlbumInfo(id: id);
    return MusicDlsiteAlbumInfo(
      id: id,
      snapshot: decodeMusicDlsiteSnapshot(row.rawJson, id),
      fetchedAt: row.fetchedAt,
    );
  }

  /// 取（或重取）一张专辑的 DLsite 资料并落库。认不出编号返回 null；网络 / 结构错误
  /// 抛 [DlsiteException]（调用方提示）。
  Future<MusicDlsiteAlbumInfo?> scrapeAlbum(String albumUid) async {
    final FushiDatabase? db = _database();
    if (db == null) return null;
    final MusicAlbumRow? album = await db.getMusicAlbum(albumUid);
    if (album == null) return null;
    final List<MusicTrackRow> tracks = await db.listMusicTracks(
      albumUid: albumUid,
    );
    final DlsiteWorkId? id = _workIdOf(album, tracks);
    if (id == null) return null;
    return _scrape(db, album, tracks, id);
  }

  Future<MusicDlsiteAlbumInfo> _scrape(
    FushiDatabase db,
    MusicAlbumRow album,
    List<MusicTrackRow> tracks,
    DlsiteWorkId id,
  ) async {
    final String locale = _locale();
    final DlsiteClient client = _clientFactory(locale);
    final String product;
    String? rating;
    try {
      product = await client.fetchProductBody(id);
      // 查无此作就不打评分端点；评分端点失败不影响主数据。
      if (parseDlsiteProductJson(product, id) != null) {
        try {
          rating = await client.fetchRatingBody(id);
        } on DlsiteException {
          rating = null;
        }
      }
    } finally {
      client.close();
    }
    final int now = _clock();
    await db.upsertMusicRawSnapshot(
      MusicMetadataRawSnapshotsCompanion.insert(
        provider: _provider,
        snapshotKind: kMusicDlsiteSnapshotKind,
        externalId: id.value,
        rawJson: encodeMusicDlsiteSnapshot(
          productBody: product,
          ratingBody: rating,
          locale: locale,
        ),
        fetchedAt: now,
      ),
    );
    final MusicDlsiteAlbumInfo info = await _cached(db, id);
    final String? coverUrl = info.snapshot?.work?.coverUrl;
    if (coverUrl != null) {
      await _maybeSetCover(db, album, tracks, id, coverUrl);
    }
    return info;
  }

  /// 专辑没有目录封面、曲目也没有内嵌封面、封面没上锁 → 用 DLsite 主图。
  /// 目录图 / 内嵌图是用户自己文件里的，优先级更高，不覆盖。
  Future<void> _maybeSetCover(
    FushiDatabase db,
    MusicAlbumRow album,
    List<MusicTrackRow> tracks,
    DlsiteWorkId id,
    String coverUrl,
  ) async {
    if (album.coverPath != null) return;
    if (tracks.any((MusicTrackRow t) => t.hasEmbeddedCover)) return;
    final Set<String> locks = await db.listMusicLockedFields(
      entityKind: 'album',
      entityUid: album.albumUid,
    );
    if (locks.contains('cover')) return;
    File? tmp;
    try {
      tmp = await _download(coverUrl);
      final Directory dir = await _coverDirectory();
      if (!dir.existsSync()) await dir.create(recursive: true);
      String ext = p.extension(tmp.path).toLowerCase();
      if (!const <String>{'.jpg', '.jpeg', '.png', '.webp'}.contains(ext)) {
        ext = '.jpg';
      }
      final File target = File(p.join(dir.path, 'dlsite_${id.value}$ext'));
      await tmp.copy(target.path);
      await db.setMusicAlbumScrapedCover(
        albumUid: album.albumUid,
        coverPath: target.path,
        updatedAt: _clock(),
      );
    } on Exception {
      // 封面下不来不影响资料；下次刷新再试。
      return;
    } finally {
      if (tmp != null && tmp.existsSync()) {
        try {
          tmp.deleteSync();
        } on FileSystemException {
          // 临时文件删不掉留给系统清理。
        }
      }
    }
  }

  /// 曲库里认得出编号、还没取过资料的专辑逐张取（串行，DLsite 客户端自带节流）。
  /// 同一部作品分在几张专辑里（分卷 / 特典）：资料只取一次，封面各自补。
  Future<MusicDlsiteLibraryReport> scrapeLibrary({
    bool Function()? cancelled,
  }) async {
    final MusicDlsiteLibraryReport report = MusicDlsiteLibraryReport();
    final FushiDatabase? db = _database();
    if (db == null) return report;
    final Map<DlsiteWorkId, List<_AlbumTracks>> todo =
        <DlsiteWorkId, List<_AlbumTracks>>{};
    for (final MusicAlbumRow album in await db.listMusicAlbums()) {
      final List<MusicTrackRow> tracks = await db.listMusicTracks(
        albumUid: album.albumUid,
      );
      final DlsiteWorkId? id = _workIdOf(album, tracks);
      if (id == null) continue;
      final List<_AlbumTracks>? pending = todo[id];
      if (pending != null) {
        pending.add((album: album, tracks: tracks));
        continue;
      }
      final MusicDlsiteAlbumInfo cached = await _cached(db, id);
      if (cached.fetched) {
        final String? coverUrl = cached.snapshot?.work?.coverUrl;
        if (coverUrl != null) {
          await _maybeSetCover(db, album, tracks, id, coverUrl);
        }
        continue;
      }
      todo[id] = <_AlbumTracks>[(album: album, tracks: tracks)];
    }
    report.total = todo.length;
    for (final MapEntry<DlsiteWorkId, List<_AlbumTracks>> job in todo.entries) {
      if (cancelled?.call() ?? false) break;
      final _AlbumTracks first = job.value.first;
      try {
        final MusicDlsiteAlbumInfo info = await _scrape(
          db,
          first.album,
          first.tracks,
          job.key,
        );
        final String? coverUrl = info.snapshot?.work?.coverUrl;
        if (info.snapshot?.work != null) {
          report.matched++;
        } else {
          report.notFound++;
        }
        if (coverUrl != null) {
          for (final _AlbumTracks other in job.value.skip(1)) {
            await _maybeSetCover(
              db,
              other.album,
              other.tracks,
              job.key,
              coverUrl,
            );
          }
        }
      } on DlsiteException {
        report.failed++;
      }
    }
    return report;
  }
}

typedef _AlbumTracks = ({MusicAlbumRow album, List<MusicTrackRow> tracks});

/// 控制通道输出的 JSON 形状（`music.album.dlsite`）。
Map<String, Object?> musicDlsiteInfoJson(MusicDlsiteAlbumInfo info) {
  final MusicDlsiteSnapshot? snap = info.snapshot;
  final DlsiteWork? w = snap?.work;
  return <String, Object?>{
    'workId': info.id.value,
    'pageUrl': info.id.pageUrl,
    'status': snap == null ? 'none' : (w == null ? 'not_found' : 'matched'),
    'fetchedAt': info.fetchedAt,
    if (snap?.locale != null) 'locale': snap!.locale,
    if (w != null) ...<String, Object?>{
      'title': w.title,
      'circle': w.circle,
      'voiceActors': w.voiceActors,
      'authors': w.authors,
      'scenarioWriters': w.scenarioWriters,
      'illustrators': w.illustrators,
      'musicians': w.musicians,
      'tags': w.genres,
      'workType': w.workTypeLabel ?? w.workType,
      'ageCategory': w.ageCategory?.name,
      'releaseDate': w.releaseDate?.toIso8601String().substring(0, 10),
      'rating': w.rating?.average,
      'ratingCount': w.rating?.count,
      'downloads': w.rating?.downloads,
      'coverUrl': w.coverUrl,
    },
  };
}
