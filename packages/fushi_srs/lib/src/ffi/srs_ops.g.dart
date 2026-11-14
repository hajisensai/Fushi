// GENERATED FILE - DO NOT EDIT.
// 由 native/fushi_fsrs/src/store/ops.rs 的命令表生成（判据与各项含义见那个文件的模块说明）。重新生成：在
// native/fushi_fsrs 下 `FUSHI_SRS_WRITE_OPS=1 cargo test --profile quick --lib store::ops`；不重新生成时那条测试
// 比对本文件，不一致就红。
//
// 内核命令（`SrsCore.sync2` / `ffsrs_store_sync2` 的 `op`）与它们的元数据：宿主进不进独占区、走哪条 worker 道、
// 改不改投影、要不要缓存配置、是不是浏览会话命令。Dart 侧不另抄任何一项。

/// 宿主发这条命令时进不进本副本的独占区（`SrsDbStore.sync2Command`）。
enum SrsOpLock {
  /// 进独占区。
  exclusive,

  /// 不进：纯计算，或只读已提交快照（结果不依赖写连接上还没提交的行，也不在别的写入的中途改本机状态）。
  free,

  /// 先带 `readOnly: true` 不进独占区发一次；回包 `needsWrite` 才进独占区再发（`plan`）。
  readFirst,
}

/// 走宿主内核 worker 池的哪条道（`SrsCoreLane`）。
enum SrsOpLane {
  /// 复习页的作答 / 排队 / 预览与本机手动排程：短、用户在等。
  interactive,

  /// 其余。
  bulk,

  /// 媒体文件的流式加解密与哈希。
  file,

  /// 内核读命令（只读连接池上并发）。
  query,
}

/// 一条内核命令。[wire] 是请求里的 `op`。
enum SrsOp {
  profileUids('profile_uids', global: true),
  readLib('read_lib', global: true, lock: SrsOpLock.free, lane: SrsOpLane.query),
  orphanSweepDone('orphan_sweep_done', global: true),
  profileMergeMark('profile_merge_mark', global: true),
  profileMergeCommit('profile_merge_commit', global: true),
  metaSetEdit('meta_set_edit', global: true),
  walCheckpoint('wal_checkpoint', global: true),
  bulkCache('bulk_cache', global: true),
  ingestYield('ingest_yield', global: true),
  refreshKeys('refresh_keys', global: true),
  identity('identity'),
  deviceInfo('device_info'),
  deviceHint('device_hint'),
  locationSealed('location_sealed'),
  locationSeal('location_seal'),
  channelSettle('channel_settle'),
  openV1('open_v1'),
  plan('plan', lock: SrsOpLock.readFirst),
  ingestBegin('ingest_begin'),
  ingestBatch('ingest_batch', projecting: true, caches: true),
  ingestPrepare('ingest_prepare'),
  ingestCommit('ingest_commit', projecting: true, caches: true),
  ingestFinish('ingest_finish', projecting: true, caches: true),
  ingestEnd('ingest_end'),
  replayPending('replay_pending', projecting: true, caches: true),
  status('status', lock: SrsOpLock.free),
  legacyDots('legacy_dots'),
  conflicts('conflicts', lock: SrsOpLock.free),
  checkpoints('checkpoints', lock: SrsOpLock.free),
  history('history', lock: SrsOpLock.free),
  study('study', lane: SrsOpLane.interactive),
  read('read', lock: SrsOpLock.free, lane: SrsOpLane.query),
  cardColumns('card_columns'),
  statsReport('stats_report'),
  statsRecall('stats_recall'),
  statsRows('stats_rows'),
  statsRelease('stats_release'),
  ankiResolve('anki_resolve'),
  ankiNotesInfo('anki_notes_info'),
  lineages('lineages'),
  preview('preview', lane: SrsOpLane.interactive),
  browseQuery('browse_query', browse: true),
  browseRows('browse_rows', browse: true),
  browseIds('browse_ids', browse: true),
  browseTargets('browse_targets', browse: true),
  browseClose('browse_close', browse: true),
  ankiFind('anki_find', browse: true),
  ankiDupes('anki_dupes', browse: true),
  ankiTags('anki_tags', browse: true),
  browseStats('browse_stats', browse: true),
  browseCounts('browse_counts', browse: true),
  browseSources('browse_sources', browse: true),
  outbox('outbox'),
  outboxAck('outbox_ack'),
  head('head'),
  relayOutbox('relay_outbox'),
  obsolete('obsolete'),
  obsoleteFormer('obsolete_former'),
  obsoleteAck('obsolete_ack'),
  relayAck('relay_ack'),
  mediaKnown('media_known', lock: SrsOpLock.free),
  mediaGcQueue('media_gc_queue'),
  mediaLiveRefs('media_live_refs', caches: true),
  localState('local_state'),
  localStateEnsure('local_state_ensure'),
  localAnchor('local_anchor'),
  profileFootprint('profile_footprint'),
  profilePurge('profile_purge'),
  bindingGet('binding_get'),
  bindingSet('binding_set'),
  deriveKey('derive_key', lock: SrsOpLock.free),
  seal('seal', lock: SrsOpLock.free),
  open('open', lock: SrsOpLock.free),
  sealFile('seal_file', lock: SrsOpLock.free, lane: SrsOpLane.file),
  openFile('open_file', lock: SrsOpLock.free, lane: SrsOpLane.file),
  refreshCaches('refresh_caches', caches: true),
  rebuildCaches('rebuild_caches', caches: true),
  cacheConfigSet('cache_config_set', caches: true),
  apply('apply', settlesChannel: true, projecting: true, caches: true, lane: SrsOpLane.interactive),
  importDrafts('import_drafts', settlesChannel: true, projecting: true, caches: true),
  change('change', settlesChannel: true, projecting: true, caches: true),
  noteFieldsIf('note_fields_if', settlesChannel: true, projecting: true, caches: true),
  mergeNotes('merge_notes', settlesChannel: true, projecting: true, caches: true),
  sched('sched', settlesChannel: true, projecting: true, caches: true, lane: SrsOpLane.interactive),
  deckDelete('deck_delete', settlesChannel: true, projecting: true, caches: true),
  undoCheck('undo_check', settlesChannel: true, lane: SrsOpLane.interactive),
  retire('retire', settlesChannel: true, projecting: true, caches: true),
  dedup('dedup', settlesChannel: true, projecting: true, caches: true),
  migrate('migrate', settlesChannel: true),
  replayAll('replay_all', settlesChannel: true),
  ingest('ingest', settlesChannel: true, projecting: true, caches: true),
  rotate('rotate', settlesChannel: true),
  export('export', settlesChannel: true),
  import('import', settlesChannel: true, projecting: true, caches: true),
  digest('digest', settlesChannel: true, lock: SrsOpLock.free),
  digestBuckets('digest_buckets', settlesChannel: true, lock: SrsOpLock.free),
  digestHeal('digest_heal', settlesChannel: true, projecting: true, caches: true),
  mediaRecord('media_record', settlesChannel: true),
  mediaHash('media_hash', settlesChannel: true, lock: SrsOpLock.free, lane: SrsOpLane.file),
  mediaScan('media_scan', settlesChannel: true),
  mediaLanded('media_landed', settlesChannel: true),
  mediaBindUnbound('media_bind_unbound', settlesChannel: true),
  mediaDoomed('media_doomed', settlesChannel: true),
  resolve('resolve', settlesChannel: true, projecting: true, caches: true),
  trust('trust', settlesChannel: true, projecting: true, caches: true),
  purge('purge', settlesChannel: true, projecting: true, caches: true),
  checkpoint('checkpoint', settlesChannel: true, projecting: true, caches: true),
  planRestore('plan_restore', settlesChannel: true),
  restore('restore', settlesChannel: true, projecting: true, caches: true),
  backfillDupeNorms('backfill_dupe_norms', settlesChannel: true, caches: true),
  backfillTagSources('backfill_tag_sources', settlesChannel: true),
  backfillSourceKeys('backfill_source_keys', settlesChannel: true),
  editsRewriteRepr('edits_rewrite_repr', settlesChannel: true, caches: true),
  mediaGcCollect('media_gc_collect', settlesChannel: true, caches: true);

  const SrsOp(
    this.wire, {
    this.global = false,
    this.settlesChannel = false,
    this.projecting = false,
    this.caches = false,
    this.browse = false,
    this.lock = SrsOpLock.exclusive,
    this.lane = SrsOpLane.bulk,
  });

  /// 请求里的 `op`。
  final String wire;

  /// 不针对单个 profile（请求不带 `profile`）。
  final bool global;

  /// 新设备收段通道没做完时，内核先把它做完再执行这条命令。
  final bool settlesChannel;

  /// 改投影（回包带 `marks`）：只能在本副本的独占区里发，回包要按顺序接进副本的内存。
  final bool projecting;

  /// 要缓存配置（请求带 `caches`）。
  final bool caches;

  /// 浏览会话命令（只读）：浏览入口与远程复习只放行这一组。
  final bool browse;

  /// 宿主进不进独占区。
  final SrsOpLock lock;

  /// 走哪条 worker 道。
  final SrsOpLane lane;

  /// [wire] 对应的命令；不是内核命令 = null。
  static SrsOp? byWire(Object? wire) => _byWire[wire];

  static final Map<Object?, SrsOp> _byWire = <Object?, SrsOp>{
    for (final SrsOp o in values) o.wire: o,
  };
}
