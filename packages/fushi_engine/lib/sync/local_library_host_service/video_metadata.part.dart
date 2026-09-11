part of '../local_library_host_service.dart';

/// 视频刮削元数据域（`docs/specs/2026-09-12-interconnect-scrape-metadata.md`）：
/// 7c 列出 host 作品、7a 代客户端搜候选 / 重刮、7b 接收客户端代刮结果落库。
///
/// 落库只有一条路：`VideoMetadataDatabaseStore.apply`（字段锁、旧投影、成员集号
/// 绑定全在那里），本文件不写任何元数据表。
mixin _LocalLibraryHostVideoMetadata on _LocalLibraryHostBase {
  // ── 7c：列出 ──────────────────────────────────────────────────────────────

  @override
  Future<List<VideoMetadataWorkEntry>> listVideoMetadata({int? since}) async {
    final List<VideoMetadataWorkEntry> entries = <VideoMetadataWorkEntry>[];
    for (final VideoMetadataWorkRow row
        in await _db.getAllVideoMetadataWorks()) {
      if (since != null && row.updatedAt <= since) continue;
      final VideoMetadataWorkEntry? entry = await _entryForWorkRow(row);
      if (entry != null) entries.add(entry);
    }
    return entries;
  }

  /// 作品行 → wire 条目；键解析不到（悬空合集 / 无 bookUid）或装载失败（无任何
  /// 身份行的残缺作品）→ null，跳过而不是让整份清单 500。
  Future<VideoMetadataWorkEntry?> _entryForWorkRow(
    VideoMetadataWorkRow row,
  ) async {
    final VideoMetadataWorkKey? key = await metadataWorkKeyOf(_db, row);
    if (key == null) return null;
    final VideoMetadataWork work;
    try {
      work = await loadVideoMetadataWork(_db, row);
    } on StateError catch (e, stack) {
      engineLog.log('sync.videoMetadata.load', e, stack);
      return null;
    }
    return VideoMetadataWorkEntry(
      key: key,
      updatedAt: row.updatedAt,
      lockedFields: <String>[
        for (final VideoMetadataLockableField f
            in parseLockedFields(row.lockedFields))
          f.name,
      ],
      lookup: await lookupOfWork(_db, row.id),
      work: work,
    );
  }

  Future<VideoMetadataWorkEntry?> _entryForTarget(
    VideoSourceScrapeWork target,
  ) async {
    final VideoMetadataWorkRow? row = target.collection == null
        ? await _db.getVideoMetadataWorkByBook(target.members.single.bookUid)
        : await _db.getVideoMetadataWorkByCollection(target.collection!.id);
    return row == null ? null : _entryForWorkRow(row);
  }

  // ── 7a：在 host 上搜候选 / 重刮 ───────────────────────────────────────────

  @override
  Future<List<VideoMetadataCandidateEntry>> searchVideoMetadataCandidates({
    required VideoMetadataWorkKey key,
    required String query,
  }) async {
    final VideoSourceScrapeTaskController? controller =
        await _scrapeController?.call();
    if (controller == null) return const <VideoMetadataCandidateEntry>[];
    final _PlannedUnitResolution resolved = await _plannedUnitForKey(key);
    final VideoPendingScrapeWork? unit = resolved.unit;
    // 多单元时候选搜索只需要作品形态，取第一个单元的来源设置即可；真正写身份的
    // scrape 才要求唯一。
    final VideoPendingScrapeWork? seed = unit ?? resolved.ambiguous.firstOrNull;
    if (seed == null) return const <VideoMetadataCandidateEntry>[];
    final List<VideoSourceScrapeConfirmationCandidate> candidates =
        await controller.searchManualCandidates(
      source: seed.source,
      workTitle: seed.work.title,
      workStableKey: seed.work.stableKey,
      query: query,
    );
    return <VideoMetadataCandidateEntry>[
      for (final VideoSourceScrapeConfirmationCandidate c in candidates)
        VideoMetadataCandidateEntry(lookup: c.lookup, work: c.work),
    ];
  }

  @override
  Future<VideoMetadataWriteResult> scrapeVideoMetadata({
    required VideoMetadataWorkKey key,
    required VideoMetadataLookup lookup,
  }) async {
    final VideoSourceScrapeTaskController? controller =
        await _scrapeController?.call();
    if (controller == null) {
      return const VideoMetadataWriteResult.conflict(
        VideoMetadataConflict.notPlanned,
      );
    }
    final _PlannedUnitResolution resolved = await _plannedUnitForKey(key);
    if (resolved.ambiguous.isNotEmpty) {
      return VideoMetadataWriteResult.conflict(
        VideoMetadataConflict.ambiguousWork,
        ambiguousWorks: <VideoMetadataWorkKey>[
          for (final VideoPendingScrapeWork u in resolved.ambiguous)
            VideoMetadataWorkKey.book(u.work.members.single.bookUid),
        ],
      );
    }
    final VideoPendingScrapeWork? unit = resolved.unit;
    if (unit == null) {
      return const VideoMetadataWriteResult.conflict(
        VideoMetadataConflict.notPlanned,
      );
    }
    await controller.rescrapeWorkWithLookup(
      source: unit.source,
      workTitle: unit.work.title,
      workStableKey: unit.work.stableKey,
      lookup: lookup,
    );
    final VideoMetadataWorkEntry? entry = await _entryForTarget(unit.work);
    if (entry == null) {
      // 刮完却没有作品行 = 刮削链自己判失败（候选被类型门拒等），如实报未落库。
      return const VideoMetadataWriteResult.conflict(
        VideoMetadataConflict.notPlanned,
      );
    }
    return VideoMetadataWriteResult.ok(entry);
  }

  /// 自然键 → 计划器里的作品单元。
  ///
  /// 合集键走 `planScrapeWorksForCollection`（BUG-2433：可能是一个合集级单元，
  /// 也可能是 N 个成员级单元）；单条目键在全部本地视频来源的计划里找
  /// `book:<uid>`。
  Future<_PlannedUnitResolution> _plannedUnitForKey(
    VideoMetadataWorkKey key,
  ) async {
    if (key.isCollection) {
      final MediaCollectionRow? collection =
          await _db.getMediaCollectionByNaturalKey(
        key.collectionName!,
        key.collectionType!,
      );
      if (collection == null) return const _PlannedUnitResolution.none();
      final List<VideoPendingScrapeWork> planned =
          await planScrapeWorksForCollection(_db, collection.id);
      if (planned.isEmpty) return const _PlannedUnitResolution.none();
      if (planned.length == 1) {
        return _PlannedUnitResolution.single(planned.single);
      }
      return _PlannedUnitResolution.ambiguous(planned);
    }
    final String stableKey = 'book:${key.bookUid}';
    final List<SourceLibraryRow> sources =
        (await _db.getMediaSourcesByKind('video'))
            .where((SourceLibraryRow s) => s.transport == 'local')
            .toList(growable: false);
    for (final SourceLibraryRow source in sources) {
      for (final VideoSourceScrapeWork work
          in await VideoSourceWorkPlanner(_db).plan(source)) {
        if (work.stableKey == stableKey) {
          return _PlannedUnitResolution.single(
            VideoPendingScrapeWork(source: source, work: work),
          );
        }
      }
    }
    return const _PlannedUnitResolution.none();
  }

  // ── 7b：接收客户端代刮结果 ────────────────────────────────────────────────

  @override
  Future<VideoMetadataWriteResult> putVideoMetadata({
    required VideoMetadataWorkKey key,
    required VideoMetadataLookup lookup,
    required VideoMetadataWork work,
    bool replaceIdentity = false,
  }) async {
    final VideoSourceScrapeWork? target =
        await resolveMetadataWorkTarget(_db, key);
    if (target == null) {
      return const VideoMetadataWriteResult.conflict(
        VideoMetadataConflict.notPlanned,
      );
    }
    final VideoMetadataDatabaseStore store = VideoMetadataDatabaseStore(_db);
    // 手动指定的 MAL/TMDB ID 不得静默换源：host 已有主身份且与入站不同，必须由
    // 客户端用户明确说「换」。
    final VideoMetadataLookup? current = await store.confirmedLookup(target);
    if (current != null &&
        !replaceIdentity &&
        (current.provider != lookup.provider ||
            current.externalId != lookup.externalId)) {
      return VideoMetadataWriteResult.conflict(
        VideoMetadataConflict.identity,
        currentLookup: current,
      );
    }
    await _runExclusive(() async {
      await store.apply(target, withLookupIdentity(work, lookup));
    });
    final VideoMetadataWorkEntry? entry = await _entryForTarget(target);
    if (entry == null) {
      return const VideoMetadataWriteResult.conflict(
        VideoMetadataConflict.notPlanned,
      );
    }
    return VideoMetadataWriteResult.ok(entry);
  }
}

/// [_LocalLibraryHostVideoMetadata._plannedUnitForKey] 的三态结果。
class _PlannedUnitResolution {
  const _PlannedUnitResolution.none()
      : unit = null,
        ambiguous = const <VideoPendingScrapeWork>[];
  const _PlannedUnitResolution.single(VideoPendingScrapeWork this.unit)
      : ambiguous = const <VideoPendingScrapeWork>[];
  const _PlannedUnitResolution.ambiguous(this.ambiguous) : unit = null;

  final VideoPendingScrapeWork? unit;
  final List<VideoPendingScrapeWork> ambiguous;
}
