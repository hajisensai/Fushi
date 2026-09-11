// 漫画章节 / mokuro 卷下载队列（v103）：在线漫画「先下载再读」的持久化任务表，
// 单 worker 串行取任务。表语义见 tables.dart 的 MangaDownloadJobs。
part of 'database.dart';

mixin _FushiDbMangaDownload on _$FushiDatabase {
  /// 按主键 upsert 一条任务。同章重复入队（job_id 由 kind/bookKey/chapterKey
  /// 派生）落到同一行，调用方不必先查再写。
  Future<void> upsertMangaDownloadJob(MangaDownloadJobsCompanion job) =>
      into(mangaDownloadJobs).insertOnConflictUpdate(job);

  Future<MangaDownloadJobRow?> getMangaDownloadJob(String jobId) =>
      (select(mangaDownloadJobs)..where((t) => t.jobId.equals(jobId)))
          .getSingleOrNull();

  /// 按身份三元组找任务（唯一索引 `(kind, book_key, chapter_key)` 保证至多一行）。
  Future<MangaDownloadJobRow?> findMangaDownloadJob({
    required String kind,
    required String bookKey,
    required String chapterKey,
  }) =>
      (select(mangaDownloadJobs)
            ..where((t) =>
                t.kind.equals(kind) &
                t.bookKey.equals(bookKey) &
                t.chapterKey.equals(chapterKey)))
          .getSingleOrNull();

  /// 列表，按创建时刻升序（再按 job_id 兜稳定序）。[statuses] 为空 = 不过滤。
  Future<List<MangaDownloadJobRow>> listMangaDownloadJobs({
    Set<String> statuses = const <String>{},
  }) {
    final SimpleSelectStatement<$MangaDownloadJobsTable, MangaDownloadJobRow>
        query = select(mangaDownloadJobs);
    if (statuses.isNotEmpty) {
      query.where((t) => t.status.isIn(statuses));
    }
    query.orderBy(<OrderingTerm Function($MangaDownloadJobsTable)>[
      (t) => OrderingTerm(expression: t.createdAt),
      (t) => OrderingTerm(expression: t.jobId),
    ]);
    return query.get();
  }

  /// 「任务表变了」的信号流（不带行）。长驻页面订阅必须用它而不是裸
  /// `select(...).watch()`：drift 的 QueryStream 取消时会排一个 `Timer.run`，
  /// widget 测试里页面 dispose 后它仍 pending（BUG-834）。
  Stream<void> watchMangaDownloadJobs() {
    late final StreamController<void> controller;
    StreamSubscription<void>? updatesSub;
    controller = StreamController<void>(
      onListen: () {
        updatesSub = tableUpdates(
          TableUpdateQuery
              .onAllTables(<ResultSetImplementation<dynamic, dynamic>>[
            mangaDownloadJobs,
          ]),
        ).listen((_) {
          if (!controller.isClosed) controller.add(null);
        });
      },
      onCancel: () async {
        await updatesSub?.cancel();
      },
    );
    return controller.stream;
  }

  /// 写进度。返回受影响行数（0 = 任务已不存在，调用方据此停止汇报）。
  Future<int> updateMangaDownloadJobProgress(
    String jobId, {
    required int pagesDone,
    required int pagesTotal,
    required int updatedAt,
  }) =>
      (update(mangaDownloadJobs)..where((t) => t.jobId.equals(jobId))).write(
        MangaDownloadJobsCompanion(
          pagesDone: Value<int>(pagesDone),
          pagesTotal: Value<int>(pagesTotal),
          updatedAt: Value<int>(updatedAt),
        ),
      );

  /// 改状态。[lastError] 传 `null` 表示不动该列；要清空传 [clearLastError]。
  /// [completedAt] / [attemptCount] 同理只在给出时写。
  Future<int> updateMangaDownloadJobStatus(
    String jobId, {
    required String status,
    required int updatedAt,
    String? lastError,
    bool clearLastError = false,
    int? completedAt,
    int? attemptCount,
  }) =>
      (update(mangaDownloadJobs)..where((t) => t.jobId.equals(jobId))).write(
        MangaDownloadJobsCompanion(
          status: Value<String>(status),
          updatedAt: Value<int>(updatedAt),
          lastError: clearLastError
              ? const Value<String?>(null)
              : (lastError == null
                  ? const Value<String?>.absent()
                  : Value<String?>(lastError)),
          completedAt: completedAt == null
              ? const Value<int?>.absent()
              : Value<int?>(completedAt),
          attemptCount: attemptCount == null
              ? const Value<int>.absent()
              : Value<int>(attemptCount),
        ),
      );

  Future<int> deleteMangaDownloadJob(String jobId) =>
      (delete(mangaDownloadJobs)..where((t) => t.jobId.equals(jobId))).go();

  /// 启动时把上次进程死亡留下的 `running` 复位成 `queued`，让 worker 续跑。
  /// 进度列不动：worker 重跑时按磁盘上已落地的页决定从哪续。
  Future<int> resetRunningMangaDownloadJobs({required int updatedAt}) =>
      (update(mangaDownloadJobs)
            ..where((t) => t.status.equals(MangaDownloadJobStatus.running)))
          .write(MangaDownloadJobsCompanion(
        status: const Value<String>(MangaDownloadJobStatus.queued),
        updatedAt: Value<int>(updatedAt),
      ));

  /// 事务内取最早的 `queued` 任务置为 `running` 并返回置后的行；队列空返回 null。
  /// 单 worker 场景下事务只是防「取到与置状态之间被另一条 upsert 改掉」。
  Future<MangaDownloadJobRow?> claimNextQueuedMangaDownloadJob({
    required int updatedAt,
  }) =>
      transaction(() async {
        final MangaDownloadJobRow? next = await (select(mangaDownloadJobs)
              ..where((t) => t.status.equals(MangaDownloadJobStatus.queued))
              ..orderBy(<OrderingTerm Function($MangaDownloadJobsTable)>[
                (t) => OrderingTerm(expression: t.createdAt),
                (t) => OrderingTerm(expression: t.jobId),
              ])
              ..limit(1))
            .getSingleOrNull();
        if (next == null) return null;
        final int changed = await (update(mangaDownloadJobs)
              ..where((t) =>
                  t.jobId.equals(next.jobId) &
                  t.status.equals(MangaDownloadJobStatus.queued)))
            .write(MangaDownloadJobsCompanion(
          status: const Value<String>(MangaDownloadJobStatus.running),
          updatedAt: Value<int>(updatedAt),
        ));
        if (changed == 0) return null;
        return next.copyWith(
          status: MangaDownloadJobStatus.running,
          updatedAt: updatedAt,
        );
      });
}
