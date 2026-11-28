import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart' show Value;
import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;

import 'package:fushi_engine/foundation/engine_log.dart';
import 'package:fushi_engine/media/cover_file_writer.dart';
import 'package:fushi_engine/media/metadata/image_download.dart';
import 'package:fushi_engine/media/video/video_storage.dart';

/// 单本书 / 漫画 / 字幕书 / 游戏的刮削资料与附加图（schema v161 的
/// `item_scrape_meta` / `item_images`）的唯一写入口。
///
/// 书籍刮削门面（Bangumi / DLsite，以及之后的 AniList / openBD / NDL / 楽天）、
/// 游戏元数据刮削、控制通道的 `library scrape-meta set` 都只经这里写：
/// - [writeMeta]：整行写入 / 覆盖文字资料（刮削口径：v177 字段锁住的字段保留旧值）；
/// - [setManualFields]：用户手填（写值并上锁；清空 = 解锁交还刮削，BUG-5111）；
/// - [mergeMeta] / [restoreMeta]：脚本合并写 / 撤销快照原样写回；
/// - 附加图（backdrop / logo）原子落盘到 `video_covers/items/` 并登记，换图时旧文件
///   随即回收。分两种口径（v183 来源锁，`item_images.user_chosen`），没有不表态的
///   写入口——调用方必须说清自己是刮削还是用户：
///   - **刮削写入** [writeScrapedImageFromFile] / [writeScrapedImageFromUrl] /
///     [writeScrapedSharedImageFromFile] / [clearScrapedImage]：元数据刮削写回、
///     「获取各卷封面与横幅」的系列横幅（及其旧数据搬家与撤销）、游戏刮削等一切
///     自动来源只走这一组。这一种图里已有用户亲手选的，就原样保留、什么都不写
///     （返回 null / false），也不白下载；
///   - **用户写入** [setUserImageFromFile] / [setUserImageFromUrl] /
///     [clearUserImage]：「横幅…」面板、AI / 控制通道的明确写入。总是生效，写入的
///     图上锁；移除 = 解锁，交还给下一次刮削（与 [setManualFields] 清空即解锁同一
///     口径）；
///   - [backupImage] / [restoreImage]：撤销快照（AI 写操作必须可撤销），来源锁与
///     共用文件身份原样写回。
/// - [writeScrapedSharedImageFromFile]：同一张图贴到多个条目（「获取各卷封面与横幅」
///   的系列横幅，BUG-5609），文件只存一份；它与 [clearScrapedImage] 可带条件
///   `when`，在格锁里原子地「判断当前那张 → 写 / 清」；
/// - 附加图的全部写入 / 回收按「格锁 → 文件锁」串行（见 [_locked]）：来源锁的判断、
///   `when` 的检查与写入、引用判断与删文件之间都插不进别的写入；
/// - [applyScrape]：资料 + 可选横版图的组合（刮削源一次响应），图走刮削口径。
///
/// 删除宿主时 DB 行在删书 / 删字幕书 / 删游戏的事务里清掉（fushi_core 的
/// `deleteEpubBook` / `deleteSrtBookByUid` / `deleteGalgame`），文件由删除路径
/// 之后调 [reclaimUnreferencedFiles] 回收——目录只归 item_images 所有，扫「不被
/// 任何行引用」即可，任何删除入口（含同步删除传播）漏调也只是晚回收，不会误删。
class ItemScrapeStore {
  ItemScrapeStore(
    this._db, {
    Directory? imagesDirectory,
    Future<File> Function(String url)? downloadImage,
    DateTime Function() now = DateTime.now,
  }) : _imagesDirectory = imagesDirectory,
       _download = downloadImage ?? downloadImageToTempFile,
       _now = now;

  final FushiDatabase _db;
  final Directory? _imagesDirectory;
  final Future<File> Function(String url) _download;
  final DateTime Function() _now;

  /// 手动 / 脚本写入的 [ItemScrapeDetails.source]。
  static const String manualSource = 'manual';

  Future<Directory> _dir() async =>
      _imagesDirectory ?? await VideoStorage.itemImagesDir();

  /// 写入 / 整行覆盖 [key] 的文字资料（刮削写回的口径）。
  ///
  /// v177 字段锁：已有行上锁住的字段（用户手填过的）保留旧值，锁随行保留；
  /// [details] 自带的 [ItemScrapeDetails.lockedFields] 不参与（刮削结果不改锁）。
  /// [overrideLocked] = true 时（脚本 / AI 的明确整行替换）锁住的字段也写新值，
  /// 锁照旧保留——之后的刮削仍不覆盖它。
  Future<void> writeMeta(
    ItemScrapeKey key,
    ItemScrapeDetails details, {
    bool overrideLocked = false,
  }) async {
    final ItemScrapeMetaRow? old = await _db.getItemScrapeMeta(
      key.mediaType,
      key.entryKey,
    );
    final ItemScrapeDetails previous = old == null
        ? const ItemScrapeDetails(source: manualSource)
        : ItemScrapeDetails.fromRow(old);
    await _write(
      key,
      overrideLocked
          ? details.withLockedFields(previous.lockedFields)
          : details.keepingLockedOf(previous),
    );
  }

  /// 合并写：[patch] 里非 null 的字段覆盖已有行，其余保留（脚本「只改简介」用）。
  /// 这是明确的手动写入：[patch] 给出的值即使落在锁住的字段上也照写，锁保留。
  Future<void> mergeMeta(ItemScrapeKey key, ItemScrapeDetails patch) async {
    final ItemScrapeMetaRow? old = await _db.getItemScrapeMeta(
      key.mediaType,
      key.entryKey,
    );
    await _write(
      key,
      old == null
          ? patch.withLockedFields(const <ItemScrapeLockableField>{})
          : ItemScrapeDetails.fromRow(old).overlay(patch),
    );
  }

  /// 撤销快照原样写回（含 [ItemScrapeDetails.lockedFields]，不看库里现有的锁）。
  Future<void> restoreMeta(ItemScrapeKey key, ItemScrapeDetails details) =>
      _write(key, details);

  /// 用户手填 [values] 里的字段（BUG-5111：刮不到资料的书也能补简介）：
  /// 非空 = 写值并上锁，之后条目刮削不再覆盖；空 / 全空白 = 清值并解锁，交还给
  /// 下一次刮削回填。没有行时以 [manualSource] 新建；清空后整行只剩手动来源的
  /// 空壳时删掉该行（回到「未刮削」，不留空资料）。返回是否有改动。
  Future<bool> setManualFields(
    ItemScrapeKey key,
    Map<ItemScrapeLockableField, String?> values,
  ) async {
    if (values.isEmpty) return false;
    final ItemScrapeMetaRow? old = await _db.getItemScrapeMeta(
      key.mediaType,
      key.entryKey,
    );
    final ItemScrapeDetails previous = old == null
        ? const ItemScrapeDetails(source: manualSource)
        : ItemScrapeDetails.fromRow(old);
    ItemScrapeDetails next = previous;
    for (final MapEntry<ItemScrapeLockableField, String?> entry
        in values.entries) {
      next = next.withManualField(entry.key, _blankToNull(entry.value));
    }
    if (old != null &&
        next.summary == previous.summary &&
        _sameLocks(next.lockedFields, previous.lockedFields)) {
      return false;
    }
    if (next.isEmptyManualShell) {
      if (old == null) return false;
      await _db.deleteItemScrapeMeta(key.mediaType, key.entryKey);
      return true;
    }
    await _write(key, next);
    return true;
  }

  Future<void> _write(ItemScrapeKey key, ItemScrapeDetails details) =>
      _db.upsertItemScrapeMeta(details.toCompanion(key, _now()));

  /// 刮削源一次响应落库：文字资料 + 可选横版背景（[backdropUrl] 下载，或已在
  /// 本地的 [backdropFile]）。背景走刮削口径：用户选过横幅就保留用户的。背景下载
  /// 失败不回滚资料（资料本身已可用），失败原样抛给调用方决定是否提示。
  Future<void> applyScrape(
    ItemScrapeKey key,
    ItemScrapeDetails details, {
    String? backdropUrl,
    File? backdropFile,
  }) async {
    await writeMeta(key, details);
    if (backdropFile != null) {
      await writeScrapedImageFromFile(
        key,
        MediaImageKind.backdrop,
        backdropFile,
        sourceUrl: backdropUrl,
      );
    } else if (backdropUrl != null && backdropUrl.trim().isNotEmpty) {
      await writeScrapedImageFromUrl(
        key,
        MediaImageKind.backdrop,
        backdropUrl.trim(),
      );
    }
  }

  // ── 附加图：刮削口径（自动来源；用户选的图一律保留）────────────────

  /// [key] 的 [kind] 图是不是用户亲手选的（v183 来源锁）。只用来省掉注定被跳过的
  /// 下载；写入口的裁决在格锁里（[_replaceSlot]）。
  Future<bool> isUserChosen(ItemScrapeKey key, MediaImageKind kind) =>
      _db.hasUserChosenItemImage(key.mediaType, key.entryKey, kind);

  /// 刮削结果把本地图片 [source] 设为 [key] 的 [kind] 图（position 0，替换旧图）。
  /// 这一种图已是用户选的时什么都不写、返回 null；否则返回落盘路径。源不是完整可
  /// 解码图片时抛 [CoverImageInvalidException]，旧图不动。
  Future<String?> writeScrapedImageFromFile(
    ItemScrapeKey key,
    MediaImageKind kind,
    File source, {
    String? sourceUrl,
  }) async {
    final String dest = await _destFor(itemImageFileName(key, kind, source));
    return _replaceSlot(
      key,
      kind,
      dest: dest,
      scrape: true,
      sourceUrl: sourceUrl,
      materialize: () =>
          copyCoverFileAtomically(source: source, destPath: dest),
    );
  }

  /// 刮削结果的 [url] 下载后同 [writeScrapedImageFromFile]。这一种图已是用户选的
  /// 时不下载、返回 null（下载失败抛 [ImageDownloadException]）。
  Future<String?> writeScrapedImageFromUrl(
    ItemScrapeKey key,
    MediaImageKind kind,
    String url,
  ) async {
    if (await isUserChosen(key, kind)) return null;
    return _withDownload(
      url,
      (File tmp) => writeScrapedImageFromFile(key, kind, tmp, sourceUrl: url),
    );
  }

  /// 同 [writeScrapedImageFromFile]，但文件按 [sourceUrl] 在条目间共用（BUG-5609）：
  /// 同一张系列横幅贴到一整套几十卷时只存一份
  /// `<mediaType>_shared_<url 摘要>_<kind>`，每卷各一行指向它。文件已在就不再复制
  /// （同一来源同一张图；也不在 Windows 上覆盖一张正被背景带读着的文件）。回收口径
  /// 不变：换图 / 清图时只有不再被任何行引用的文件才删，共用文件随最后一行一起回收。
  ///
  /// 共用文件名只由刮削口径产生（单条目写入是 [itemImageFileName]，用户的图还带
  /// `_user` 后缀），调用方据 [isItemSharedImageRow] 认「这一行是批量贴上去的那张」，
  /// 不靠 `source_url` 单独判断（别的来源可能恰好是同一个 URL）。用户选的图因此
  /// 永远不会被认成批量贴的。
  ///
  /// 返回 null = 没写：这一种图已是用户选的（来源锁），或 [when] 不通过。[when]：
  /// 条件写——拿着本格（[key] 的 [kind]）的锁读当前那行，返回 false 就不写；检查
  /// 与写入之间不会插进别的写入（「书没有背景图才贴」这类判断必须用它，不能先
  /// [firstImage] 再写）。用户选的图在 [when] 之前就让路，[when] 看不到它。写了返回
  /// 落盘路径。
  Future<String?> writeScrapedSharedImageFromFile(
    ItemScrapeKey key,
    MediaImageKind kind,
    File source, {
    required String sourceUrl,
    bool Function(ItemImageRow? current)? when,
  }) async {
    final String dest = await _destFor(
      itemSharedImageFileName(key.mediaType, kind, sourceUrl, source),
    );
    return _replaceSlot(
      key,
      kind,
      dest: dest,
      scrape: true,
      sourceUrl: sourceUrl,
      when: when,
      materialize: () => _materializeShared(source, dest),
    );
  }

  /// 刮削侧清掉 [key] 的 [kind] 图（行 + 文件）：刮削写回的撤销、「获取」撤掉自己
  /// 贴的横幅。用户选的图保留、返回 false；[when] 同
  /// [writeScrapedSharedImageFromFile]（拿着本格的锁判断当前那行，返回 false 就
  /// 不清）。清了（含本来就空）返回 true。
  Future<bool> clearScrapedImage(
    ItemScrapeKey key,
    MediaImageKind kind, {
    bool Function(ItemImageRow? current)? when,
  }) async =>
      await _replaceSlot(key, kind, dest: null, scrape: true, when: when) !=
      null;

  // ── 附加图：用户口径（明确的用户 / AI / 控制通道操作）──────────────────

  /// 用户把本地图片 [source] 设为 [key] 的 [kind] 图（position 0，替换旧图，包括
  /// 用户之前选的和批量贴的共用图），并上锁：之后的刮削不再覆盖。落盘文件名带
  /// `_user`（[itemImageFileName]），永远不是共用文件名。返回落盘路径。源不是完整
  /// 可解码图片时抛 [CoverImageInvalidException]，旧图不动。
  Future<String> setUserImageFromFile(
    ItemScrapeKey key,
    MediaImageKind kind,
    File source, {
    String? sourceUrl,
  }) async {
    final String dest = await _destFor(
      itemImageFileName(key, kind, source, userChosen: true),
    );
    final String? written = await _replaceSlot(
      key,
      kind,
      dest: dest,
      scrape: false,
      userChosen: true,
      sourceUrl: sourceUrl,
      materialize: () =>
          copyCoverFileAtomically(source: source, destPath: dest),
    );
    return written!;
  }

  /// 下载 [url] 后同 [setUserImageFromFile]（下载失败抛 [ImageDownloadException]）。
  Future<String> setUserImageFromUrl(
    ItemScrapeKey key,
    MediaImageKind kind,
    String url,
  ) => _withDownload(
    url,
    (File tmp) => setUserImageFromFile(key, kind, tmp, sourceUrl: url),
  );

  /// 用户移除 [key] 的 [kind] 图（行 + 文件，用户选的也清）。移除即解锁：下一次
  /// 刮削可以再写入。
  Future<void> clearUserImage(ItemScrapeKey key, MediaImageKind kind) async {
    await _replaceSlot(key, kind, dest: null, scrape: false);
  }

  /// [key] 的 [kind] 图里 position 最小的那行；没有为 null。
  Future<ItemImageRow?> firstImage(
    ItemScrapeKey key,
    MediaImageKind kind,
  ) async => _first(await _rowsOf(key, kind));

  // ── 撤销快照 ──────────────────────────────────────────────────────

  /// 把 [key] 的 [kind] 图（position 0，写入口只写这一张）复制进 [backupDir]，
  /// 返回撤销时 [restoreImage] 要的快照；没有这种图或文件已不在时返回 null。
  /// 文件名 = 原文件名前缀写入时刻，同一条目多次备份不互相覆盖。在格锁里读行、
  /// 复制文件，期间那张图不会被换掉 / 回收。
  Future<ItemImageBackup?> backupImage(
    ItemScrapeKey key,
    MediaImageKind kind,
    Directory backupDir,
  ) => _locked(_slotLock(key, kind), () async {
    final ItemImageRow? row = _first(await _rowsOf(key, kind));
    if (row == null) return null;
    final File file = File(row.path);
    if (!await file.exists()) return null;
    await backupDir.create(recursive: true);
    final String dest = p.join(
      backupDir.path,
      '${_now().microsecondsSinceEpoch}_${p.basename(row.path)}',
    );
    await file.copy(dest);
    return ItemImageBackup(
      path: dest,
      sourceUrl: row.sourceUrl,
      userChosen: row.userChosen,
      shared: isItemSharedImageRow(row),
    );
  });

  /// 撤销写回：[backup] 为 null（执行前没有这种图）= 清掉（[clearUserImage]）；
  /// 否则把备份原样写回，来源锁也回到执行前（之前是刮削来的图就仍是刮削来源），
  /// 之前是批量贴的共用图就写回同一个共用文件（「获取」仍认得它是自己贴的）。
  /// 备份文件写回后删掉。
  Future<void> restoreImage(
    ItemScrapeKey key,
    MediaImageKind kind,
    ItemImageBackup? backup,
  ) async {
    if (backup == null) {
      await clearUserImage(key, kind);
      return;
    }
    final File file = File(backup.path);
    final String? sharedUrl = backup.shared && !backup.userChosen
        ? backup.sourceUrl
        : null;
    final String dest = await _destFor(
      sharedUrl != null
          ? itemSharedImageFileName(key.mediaType, kind, sharedUrl, file)
          : itemImageFileName(key, kind, file, userChosen: backup.userChosen),
    );
    await _replaceSlot(
      key,
      kind,
      dest: dest,
      scrape: false,
      userChosen: backup.userChosen,
      sourceUrl: backup.sourceUrl,
      materialize: sharedUrl != null
          ? () => _materializeShared(file, dest)
          : () => copyCoverFileAtomically(source: file, destPath: dest),
    );
    try {
      if (await file.exists()) await file.delete();
    } on FileSystemException {
      // 备份目录有保留期清理兜底。
    }
  }

  /// 附加图目录里名为 [name] 的落盘路径（目录不在先建）。
  Future<String> _destFor(String name) async {
    final Directory dir = await _dir();
    await dir.create(recursive: true);
    return p.join(dir.path, name);
  }

  /// 共用文件就位：已在就不再复制（见 [writeScrapedSharedImageFromFile]）。
  static Future<void> _materializeShared(File source, String dest) async {
    if (await File(dest).exists()) return;
    await copyCoverFileAtomically(source: source, destPath: dest);
  }

  Future<T> _withDownload<T>(
    String url,
    Future<T> Function(File tmp) body,
  ) async {
    final File tmp = await _download(url);
    try {
      return await body(tmp);
    } finally {
      try {
        if (await tmp.exists()) await tmp.delete();
      } on FileSystemException {
        // 临时文件，删不掉由系统清理。
      }
    }
  }

  Future<List<ItemImageRow>> _rowsOf(
    ItemScrapeKey key,
    MediaImageKind kind,
  ) async => <ItemImageRow>[
    for (final ItemImageRow row in await _db.getItemImages(
      key.mediaType,
      key.entryKey,
    ))
      if (row.kind == kind.dbValue) row,
  ];

  static ItemImageRow? _first(List<ItemImageRow> rows) {
    ItemImageRow? first;
    for (final ItemImageRow row in rows) {
      if (first == null || row.position < first.position) first = row;
    }
    return first;
  }

  /// 回收附加图目录里不再被任何 item_images 行引用的文件（宿主删除后调用）。
  /// 返回实删数；目录不存在为 0。失败只记日志，不抛断删除流程。
  Future<int> reclaimUnreferencedFiles() async {
    try {
      final Directory dir = await _dir();
      if (!await dir.exists()) return 0;
      final Set<String> referenced = <String>{
        for (final ItemImageRow row in await _db.getAllItemImages()) row.path,
      };
      final List<String> candidates = <String>[
        await for (final FileSystemEntity e in dir.list())
          if (e is File &&
              !p.basename(e.path).contains('.tmp.') &&
              !referenced.contains(e.path))
            e.path,
      ];
      int removed = 0;
      // 逐个在文件锁里复查再删：扫描之后有写入把它重新用上（共用文件被另一卷贴上）
      // 就留着。
      for (final String path in candidates) {
        if (await _deleteIfUnreferenced(path, dir)) removed++;
      }
      return removed;
    } catch (e, stack) {
      engineLog.log('itemScrape.reclaim', e, stack);
      return 0;
    }
  }

  // ── 附加图的串行化（BUG-5609 审查）──
  //
  // 两类键，同一张进程级锁表（多个 [ItemScrapeStore] 实例写同一张表、同一个目录）：
  // - 格锁 `slot:<mediaType>:<entryKey>:<kind>`：一个条目一种图的全部写入
  //   （换图 / 清图 / 条件写）在它里面完成，[when] 的检查与写入之间插不进别的写入；
  // - 文件锁 `file:<路径>`：「确保文件在 + 登记引用它的行」与「确认无行引用 + 删
  //   文件」互斥，共用文件不会在「已决定复用、行还没插」的空当被回收（否则行指向
  //   一个不存在的文件）。
  // 加锁顺序固定为格锁 → 文件锁，文件锁之间从不嵌套（先放开目标文件锁再回收被
  // 换下的文件），所以不会死锁。

  static final Map<String, Future<void>> _locks = <String, Future<void>>{};

  static Future<T> _locked<T>(String lock, Future<T> Function() body) async {
    final Future<void> previous = _locks[lock] ?? Future<void>.value();
    final Completer<void> release = Completer<void>();
    final Future<void> mine = release.future;
    _locks[lock] = mine;
    try {
      await previous;
      return await body();
    } finally {
      release.complete();
      if (identical(_locks[lock], mine)) _locks.remove(lock);
    }
  }

  static String _slotLock(ItemScrapeKey key, MediaImageKind kind) =>
      'slot:${key.mediaType.dbValue}:${key.entryKey}:${kind.dbValue}';

  static String _fileLock(String path) => 'file:${p.canonicalize(path)}';

  /// 本格（[key] 的 [kind]）换成 [dest] 一张（[materialize] 负责让文件就位）或清空
  /// （[dest] 为 null），再回收被换下且不再被引用的文件。
  ///
  /// [scrape] = 刮削口径（v183 来源锁）：本格已有用户选的图就整格让路、返回 null。
  /// 在格锁里、[when] 与落盘之前判，所以进程内任何刮削写入（含批量贴横幅的条件写、
  /// 旧数据搬家、撤销写回）都插不进用户写入的前后之间；登记仍走
  /// `replaceScrapedItemImagesOfKind`，事务里再判一次，挡住格锁管不到的写入（别的
  /// 进程、直接写库），那时只按引用回收刚落下的文件。用户口径新行的来源锁记为
  /// [userChosen]。
  ///
  /// [when] 不通过也返回 null；否则返回 [dest]（清空时返回空串，只表示「做了」）。
  Future<String?> _replaceSlot(
    ItemScrapeKey key,
    MediaImageKind kind, {
    required String? dest,
    required bool scrape,
    bool userChosen = false,
    String? sourceUrl,
    Future<void> Function()? materialize,
    bool Function(ItemImageRow? current)? when,
  }) => _locked(_slotLock(key, kind), () async {
    final List<ItemImageRow> rows = await _rowsOf(key, kind);
    if (scrape && rows.any((ItemImageRow r) => r.userChosen)) return null;
    if (when != null && !when(_first(rows))) return null;
    final List<({String path, String? sourceUrl})> images =
        <({String path, String? sourceUrl})>[
          if (dest != null) (path: dest, sourceUrl: sourceUrl),
        ];
    Future<List<String>?> replace() => scrape
        ? _db.replaceScrapedItemImagesOfKind(
            mediaType: key.mediaType,
            entryKey: key.entryKey,
            kind: kind,
            images: images,
          )
        : _db.replaceItemImagesOfKind(
            mediaType: key.mediaType,
            entryKey: key.entryKey,
            kind: kind,
            images: images,
            userChosen: userChosen,
          );
    final List<String>? dropped = dest == null
        ? await replace()
        : await _locked(_fileLock(dest), () async {
            await materialize?.call();
            return replace();
          });
    if (dropped == null) {
      if (dest != null) await _deleteIfUnreferenced(dest, await _dir());
      return null;
    }
    if (dropped.isNotEmpty) {
      final Directory dir = await _dir();
      for (final String path in dropped) {
        await _deleteIfUnreferenced(path, dir);
      }
    }
    return dest ?? '';
  });

  /// 在 [path] 的文件锁里确认没有任何行引用它（且落在 [dir] 内）才删。返回是否删了。
  Future<bool> _deleteIfUnreferenced(String path, Directory dir) => _locked(
    _fileLock(path),
    () async {
      final int removed = await VideoStorage.deleteOwnedImageFiles(
        deletedPaths: <String>[path],
        stillReferencedPaths: <String>[
          for (final ItemImageRow row in await _db.getAllItemImages()) row.path,
        ],
        ownedDir: dir,
      );
      return removed > 0;
    },
  );
}

/// item_scrape_meta / item_images 的宿主身份（同合集成员的 (mediaType, entryKey)：
/// epub=EpubBooks.uid / srt=SrtBooks.uid / game=Galgames.id）。
class ItemScrapeKey {
  ItemScrapeKey(this.mediaType, this.entryKey) {
    if (!kItemScrapeMediaKinds.contains(mediaType)) {
      throw ArgumentError.value(mediaType, 'mediaType');
    }
    if (entryKey.isEmpty) throw ArgumentError.value(entryKey, 'entryKey');
  }

  final MediaKind mediaType;
  final String entryKey;

  @override
  bool operator ==(Object other) =>
      other is ItemScrapeKey &&
      other.mediaType == mediaType &&
      other.entryKey == entryKey;

  @override
  int get hashCode => Object.hash(mediaType, entryKey);

  @override
  String toString() => '${mediaType.dbValue}:$entryKey';
}

/// [ItemScrapeStore.backupImage] 的撤销快照：备份文件、原来的来源 URL、来源锁，以及
/// 原来是不是批量贴的共用图（[isItemSharedImageRow]；写回时回到同一个共用文件）。
class ItemImageBackup {
  const ItemImageBackup({
    required this.path,
    required this.userChosen,
    this.sourceUrl,
    this.shared = false,
  });

  factory ItemImageBackup.fromJson(Map<String, Object?> json) =>
      ItemImageBackup(
        path: json['path']! as String,
        sourceUrl: json['sourceUrl'] as String?,
        userChosen: json['userChosen'] == true,
        shared: json['shared'] == true,
      );

  /// 备份文件的绝对路径（在调用方给的撤销备份目录里）。
  final String path;
  final String? sourceUrl;
  final bool userChosen;
  final bool shared;

  Map<String, Object?> toJson() => <String, Object?>{
    'path': path,
    'sourceUrl': ?sourceUrl,
    'userChosen': userChosen,
    if (shared) 'shared': true,
  };
}

/// `item_scrape_meta.locked_fields` 里可锁的字段（v177，BUG-5111）。wire 值 =
/// [name]，只增不改名；未知值解析时静默忽略。
enum ItemScrapeLockableField {
  /// 简介。
  summary;

  static ItemScrapeLockableField? tryParse(String raw) {
    for (final ItemScrapeLockableField f in values) {
      if (f.name == raw) return f;
    }
    return null;
  }
}

/// `locked_fields` 列 → 字段集合（NULL / 空 / 未知值 = 不锁）。
Set<ItemScrapeLockableField> parseItemScrapeLockedFields(String? raw) {
  if (raw == null || raw.trim().isEmpty) {
    return const <ItemScrapeLockableField>{};
  }
  return <ItemScrapeLockableField>{
    for (final String part in raw.split(','))
      if (ItemScrapeLockableField.tryParse(part.trim())
          case final ItemScrapeLockableField f)
        f,
  };
}

/// 字段集合 → `locked_fields` 列（按枚举声明序；空 = NULL，唯一的「无锁」形态）。
String? encodeItemScrapeLockedFields(Set<ItemScrapeLockableField> fields) {
  if (fields.isEmpty) return null;
  return <String>[
    for (final ItemScrapeLockableField f in ItemScrapeLockableField.values)
      if (fields.contains(f)) f.name,
  ].join(',');
}

bool _sameLocks(
  Set<ItemScrapeLockableField> a,
  Set<ItemScrapeLockableField> b,
) => a.length == b.length && a.containsAll(b);

/// 一次刮削 / 手动写入的文字资料（与媒体、来源无关的形状；各源各自折进来）。
class ItemScrapeDetails {
  const ItemScrapeDetails({
    required this.source,
    this.subjectId,
    this.title,
    this.originalTitle,
    this.summary,
    this.airDate,
    this.rating,
    this.ratingCount,
    this.tags = const <String>[],
    this.detailUrl,
    this.lockedFields = const <ItemScrapeLockableField>{},
  });

  factory ItemScrapeDetails.fromRow(ItemScrapeMetaRow row) => ItemScrapeDetails(
    source: row.source,
    subjectId: row.subjectId,
    title: row.title,
    originalTitle: row.originalTitle,
    summary: row.summary,
    airDate: row.airDate,
    rating: row.rating,
    ratingCount: row.ratingCount,
    tags: decodeItemScrapeTags(row.tagsJson),
    detailUrl: row.detailUrl,
    lockedFields: parseItemScrapeLockedFields(row.lockedFields),
  );

  /// 来源（书籍刮削源名 / 游戏元数据源 key / [ItemScrapeStore.manualSource]）。
  final String source;
  final String? subjectId;
  final String? title;
  final String? originalTitle;
  final String? summary;

  /// `YYYY-MM-DD` / `YYYY-MM` / `YYYY`。
  final String? airDate;

  /// 0~10。
  final double? rating;
  final int? ratingCount;

  /// 类型 / 标签名（按热度降序）。
  final List<String> tags;
  final String? detailUrl;

  /// 用户手填过、刮削不再覆盖的字段（v177）。
  final Set<ItemScrapeLockableField> lockedFields;

  /// 只有手动来源、没有任何资料也没有锁的空壳（清空手填后据此删行）。
  bool get isEmptyManualShell =>
      source == ItemScrapeStore.manualSource &&
      lockedFields.isEmpty &&
      _blankToNull(subjectId) == null &&
      _blankToNull(title) == null &&
      _blankToNull(originalTitle) == null &&
      _blankToNull(summary) == null &&
      _blankToNull(airDate) == null &&
      rating == null &&
      ratingCount == null &&
      tags.isEmpty &&
      _blankToNull(detailUrl) == null;

  ItemScrapeDetails _copy({
    required String? summary,
    required Set<ItemScrapeLockableField> lockedFields,
  }) => ItemScrapeDetails(
    source: source,
    subjectId: subjectId,
    title: title,
    originalTitle: originalTitle,
    summary: summary,
    airDate: airDate,
    rating: rating,
    ratingCount: ratingCount,
    tags: tags,
    detailUrl: detailUrl,
    lockedFields: lockedFields,
  );

  /// 换成 [locks] 这组锁，其余不变。
  ItemScrapeDetails withLockedFields(Set<ItemScrapeLockableField> locks) =>
      _copy(summary: summary, lockedFields: locks);

  /// 刮削口径的合并：[previous] 锁住的字段取它的旧值，锁沿用 [previous] 的。
  ItemScrapeDetails keepingLockedOf(ItemScrapeDetails previous) {
    final Set<ItemScrapeLockableField> locks = previous.lockedFields;
    return _copy(
      summary: locks.contains(ItemScrapeLockableField.summary)
          ? previous.summary
          : summary,
      lockedFields: locks,
    );
  }

  /// 手填 [field]：[value] 非 null = 写值并上锁；null = 清值并解锁。
  ItemScrapeDetails withManualField(
    ItemScrapeLockableField field,
    String? value,
  ) {
    final Set<ItemScrapeLockableField> locks = <ItemScrapeLockableField>{
      ...lockedFields,
    };
    if (value == null) {
      locks.remove(field);
    } else {
      locks.add(field);
    }
    return switch (field) {
      ItemScrapeLockableField.summary => _copy(
        summary: value,
        lockedFields: locks,
      ),
    };
  }

  /// [patch] 非 null / 非空的字段盖在本对象上（来源取 [patch] 的，锁沿用本对象的）。
  ItemScrapeDetails overlay(ItemScrapeDetails patch) => ItemScrapeDetails(
    source: patch.source,
    subjectId: patch.subjectId ?? subjectId,
    title: patch.title ?? title,
    originalTitle: patch.originalTitle ?? originalTitle,
    summary: patch.summary ?? summary,
    airDate: patch.airDate ?? airDate,
    rating: patch.rating ?? rating,
    ratingCount: patch.ratingCount ?? ratingCount,
    tags: patch.tags.isNotEmpty ? patch.tags : tags,
    detailUrl: patch.detailUrl ?? detailUrl,
    lockedFields: lockedFields,
  );

  ItemScrapeMetaCompanion toCompanion(ItemScrapeKey key, DateTime now) =>
      ItemScrapeMetaCompanion.insert(
        mediaType: key.mediaType.dbValue,
        entryKey: key.entryKey,
        source: source,
        subjectId: Value<String?>(_blankToNull(subjectId)),
        title: Value<String?>(_blankToNull(title)),
        originalTitle: Value<String?>(_blankToNull(originalTitle)),
        summary: Value<String?>(_blankToNull(summary)),
        airDate: Value<String?>(_blankToNull(airDate)),
        rating: Value<double?>(rating),
        ratingCount: Value<int?>(ratingCount),
        tagsJson: Value<String?>(encodeItemScrapeTags(tags)),
        detailUrl: Value<String?>(_blankToNull(detailUrl)),
        scrapedAt: now.millisecondsSinceEpoch,
        lockedFields: Value<String?>(
          encodeItemScrapeLockedFields(lockedFields),
        ),
      );
}

String? _blankToNull(String? s) =>
    (s == null || s.trim().isEmpty) ? null : s.trim();

/// 标签名列表 → 与 `CollectionScrapeMeta.tagsJson` 同形的 JSON（无热度时 count
/// 省略）；空为 null。
String? encodeItemScrapeTags(List<String> tags) {
  final List<String> names = <String>[
    for (final String t in tags)
      if (t.trim().isNotEmpty) t.trim(),
  ];
  if (names.isEmpty) return null;
  return jsonEncode(<Map<String, Object?>>[
    for (final String n in names) <String, Object?>{'name': n},
  ]);
}

/// [encodeItemScrapeTags] 的逆；解析失败为空表。
List<String> decodeItemScrapeTags(String? json) {
  if (json == null || json.isEmpty) return const <String>[];
  try {
    final Object? decoded = jsonDecode(json);
    if (decoded is! List<Object?>) return const <String>[];
    return <String>[
      for (final Object? tag in decoded)
        if (tag is Map<String, Object?> && tag['name'] is String)
          tag['name']! as String,
    ];
  } on FormatException {
    return const <String>[];
  }
}

/// 单条目附加图文件名：`<mediaType>_<entryKey 摘要>_<kind>[_user].<ext>`。entryKey
/// 取 sha1 前 16 位（游戏 id / uid 里可能有任意字符），扩展名跟源文件（没有按 jpg）。
/// 用户选的图带 `_user` 后缀（v183）：刮削落盘永远碰不到用户那份文件；它也永远不是
/// 共用文件名（[itemSharedImageFileName]），不会被「获取」认成自己贴的。
String itemImageFileName(
  ItemScrapeKey key,
  MediaImageKind kind,
  File source, {
  bool userChosen = false,
}) {
  final String digest = sha1
      .convert(utf8.encode(key.entryKey))
      .toString()
      .substring(0, 16);
  String ext = p.extension(source.path).toLowerCase();
  if (!const <String>{'.jpg', '.jpeg', '.png', '.webp', '.gif'}.contains(ext)) {
    ext = '.jpg';
  }
  final String origin = userChosen ? '_user' : '';
  return '${key.mediaType.dbValue}_${digest}_${kind.dbValue}$origin$ext';
}

/// 条目间共用的附加图文件名（[ItemScrapeStore.writeScrapedSharedImageFromFile]）：
/// `<mediaType>_shared_<sourceUrl 摘要>_<kind>.<ext>`，与 [itemImageFileName] 的
/// 单条目文件名不会相撞（摘要段是十六进制，不会是 `shared`）。
String itemSharedImageFileName(
  MediaKind mediaType,
  MediaImageKind kind,
  String sourceUrl,
  File source,
) {
  final String digest = sha1
      .convert(utf8.encode(sourceUrl))
      .toString()
      .substring(0, 16);
  String ext = p.extension(source.path).toLowerCase();
  if (!const <String>{'.jpg', '.jpeg', '.png', '.webp', '.gif'}.contains(ext)) {
    ext = '.jpg';
  }
  return '${mediaType.dbValue}_shared_${digest}_${kind.dbValue}$ext';
}

/// [row] 是不是 [ItemScrapeStore.writeScrapedSharedImageFromFile] 贴上去的共用图：路径就是
/// 它按 `source_url` 算出的共用文件名（扩展名不论）。批量贴图的调用方据此认领
/// 「这张是我贴的」——单条目写入（书籍刮削、用户手选）的文件名是 [itemImageFileName]，
/// 即使 `source_url` 恰好相同也不会被认成共用图。
bool isItemSharedImageRow(ItemImageRow row) {
  final String? url = row.sourceUrl;
  final MediaKind? mediaType = MediaKind.tryParse(row.mediaType);
  final MediaImageKind? kind = MediaImageKind.tryParse(row.kind);
  if (url == null || mediaType == null || kind == null) return false;
  return p.basenameWithoutExtension(row.path) ==
      p.basenameWithoutExtension(
        itemSharedImageFileName(mediaType, kind, url, File('x.jpg')),
      );
}
