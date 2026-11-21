/// iOS「文件」App 里的 Fushi 导入收件箱（拍板台 nLXhu0d7gV，反馈 nLXhu0d7gV）。
///
/// ## 为什么是「收件箱」而不是「把 Documents 当常驻来源」
///
/// iOS 只能整份共享 Documents（`UIFileSharingEnabled` / `LSSupportsOpeningDocumentsInPlace`），
/// 所以书库先搬出了 Documents（`AppPaths.iosDocumentsRoot`），Documents 只剩收件箱一个
/// 用途。用户在「文件」App 里把文件拖进 `Fushi › Video`（Books / Manga 同理），回到 Fushi
/// 点「从『文件』App 导入」，走「导入文件夹（仅此一次）」同一条扫描-导入管线
/// （`importLocalFolderOnceAt`）。两类域的取法不同（[ImportInbox.movesIntoDataRoot]）：
///
///  - **视频**：库条目**原地引用**文件，所以收件箱里本域认的文件 / 子目录先被**移**（同卷
///    rename，零额外空间）进数据根内的 `inbox_imports/video/<批次>/`，再对批次目录扫描。
///    移进数据根而不是原地引用收件箱，有两个结构性原因：
///     - **容器漂移**：iOS 每次更新换容器 UUID，库里的绝对路径靠 `SandboxRelocation` 按
///       数据根白名单重基；Documents 不在数据根里，原地引用的视频每次更新都会悬空（正是本
///       反馈前半段「过半天就要重新导入」的同类问题）。`inbox_imports` 在白名单里。
///     - **库条目不被「文件」App 删改**：库里的文件只在 app 私有区，用户整理收件箱不会让
///       库条目指向丢失的文件。删视频库条目时一并回收（`pickerImportCopyDirectories`）。
///
///    批次扫描成功后写 [ImportInbox.importedMarkerName] 标记；没有标记的批次（扫描失败、
///    扫描途中 app 被杀）在下次点导入时先续导（[ImportInbox.unfinishedBatches]），文件不会
///    卡在用户看不见的地方。
///  - **书 / 漫画**：导入器把内容**复制 / 解压**进 app 自己的书库，库条目不引用原件。直接
///    对收件箱子目录原地扫描，原件留在「文件」App 里由用户自己处置——移进数据根只会让原件
///    在用户看不见、存储页删不掉的地方与书库各占一份。重复点导入时已在库的书 / 卷按导入
///    器的重复判据跳过。
///
/// 分类子目录由页面决定（与 `addLocalFolderAsSource` 「媒体种类由当前页面决定，不从文件
/// 内容猜」同一纪律）：书页导 `Books`、视频页导 `Video`、漫画页导 `Manga`。视频页不认的
/// 文件原样留在收件箱，用户看得见没被收走。
///
/// **iTunes 文件共享**（拍板台 kmfCiXlIU_）：iTunes 只看得见 Documents 最外层、进不了
/// 分类子目录。根上本页认的散文件不静默收走，点导入时列出来让用户确认，确认后先移进本页
/// 的分类子目录再走上面的流程（[ImportInbox.pendingRootFiles] / [ImportInbox.adoptRootFiles]）。
library;

import 'dart:io';

import 'package:path/path.dart' as p;

import 'package:fushi_engine/media/media_extensions.dart'
    show isAudioOnlyMediaPath, kVideoExtensions;
import 'package:fushi_engine/media/manga/manga_importer.dart'
    show kMangaImageExtensions;
import 'package:fushi/src/media/drag_drop/drop_classification.dart'
    show
        kDragAudioExtensions,
        kDragBookExtensions,
        kDragPlaylistExtensions,
        kDragSubtitleExtensions;
import 'package:fushi/src/media/import/import_carrier.dart'
    show kMangaCarrierFileExtensions;
import 'package:fushi/src/storage/directory_move.dart'
    show moveDirectoryMerging;

/// 一次从收件箱收走的批次。
class ImportInboxBatch {
  const ImportInboxBatch({
    required this.directory,
    required this.movedEntries,
    required this.failures,
  });

  /// 数据根内的批次目录（`inbox_imports/<域>/<批次>/`），交给一次性扫描。
  final Directory directory;

  /// 移进批次目录的顶层条目名。
  final List<String> movedEntries;

  /// 移不动的条目（`名字: 原因`）。它们留在收件箱里，下次再收。
  final List<String> failures;
}

class ImportInbox {
  const ImportInbox._();

  /// 收件箱只在 iOS 上存在：桌面 / 安卓的选择器与文件夹来源本来就拿得到用户真实路径，
  /// 用不着一个 app 自己的投递目录。全仓库只在这里判平台。
  static bool get isSupported => Platform.isIOS;

  /// 媒体种类（`SourceLibraryKind.dbValue`）→ 收件箱子目录名。
  ///
  /// 目录名不翻译：它是用户在「文件」App 里看到、也可能自己建的文件夹，换系统语言就换名
  /// 会让已经放进去的文件「消失」。
  ///
  /// 视频是 `Video` 而不是 `Videos`：iOS 的 APFS 默认不分大小写，`Videos` 与书库白名单
  /// 里的旧扁平布局目录 `videos`（`AppPaths.fushiOwnedDocumentsEntries`）是**同一个**目录。
  /// 收件箱子目录名与白名单大小写无关地互不相交，由测试钉死。
  ///
  /// 没有 `Games`（拍板台 kmfCiXlIU_ 问过）：iOS 上游戏模块只是串流接收端
  /// （`GamesModuleForm.streamClient`，游戏装在配对的 Windows 主机上、远程启动后串流），
  /// 本机没有任何游戏导入管线，游戏来源也只认 Windows exe；建一个 `Games` 文件夹只会
  /// 让用户把文件放进一个永远导入不了的地方。音乐也不单列：视频页的 `Video` 收纯音频并
  /// 交给音乐库（见 [acceptsFile]）。
  static const Map<String, String> kindFolderNames = <String, String>{
    'book': 'Books',
    'video': 'Video',
    'manga': 'Manga',
  };

  /// [mediaKind] 是否要先把文件移进数据根（`inbox_imports/<域>/<批次>/`）再扫描。
  ///
  /// 只有视频：库条目原地引用文件。书 / 漫画的导入器把内容复制进书库，原件不再被引用，
  /// 移进数据根只会制造一份用户看不见、也删不掉的重复（见文件头）。
  static bool movesIntoDataRoot(String mediaKind) => mediaKind == 'video';

  /// 收件箱里 [mediaKind] 的分类子目录（不保证存在）；不支持的种类返回 null。
  static Directory? kindFolder(Directory inbox, String mediaKind) {
    final String? folder = folderNameFor(mediaKind);
    return folder == null ? null : Directory(p.join(inbox.path, folder));
  }

  /// 批次扫描完成标记（批次目录下的隐藏文件）。没有它的批次是「收走了但还没导入成功」。
  static const String importedMarkerName = '.fushi_inbox_imported';

  /// 标记 [batch] 已导入成功：之后不再续导。
  static Future<void> markBatchImported(Directory batch) async {
    if (!await batch.exists()) return;
    await File(p.join(batch.path, importedMarkerName)).writeAsString('');
  }

  /// `<stagingRoot>/<域>/` 下还没导入成功的批次（无 [importedMarkerName]），按名字排序。
  ///
  /// 空批次目录（只剩隐藏项）顺手删掉，不当成待续导。
  static Future<List<Directory>> unfinishedBatches({
    required Directory stagingRoot,
    required String mediaKind,
  }) async {
    final Directory kindStaging = Directory(
      p.join(stagingRoot.path, mediaKind),
    );
    if (!await kindStaging.exists()) return const <Directory>[];
    final List<Directory> out = <Directory>[];
    await for (final FileSystemEntity e in kindStaging.list(
      followLinks: false,
    )) {
      if (e is! Directory) continue;
      if (await File(p.join(e.path, importedMarkerName)).exists()) continue;
      final bool hasContent = await e
          .list(followLinks: false)
          .any((FileSystemEntity c) => !p.basename(c.path).startsWith('.'));
      if (!hasContent) {
        await e.delete(recursive: true);
        continue;
      }
      out.add(e);
    }
    out.sort((Directory a, Directory b) => a.path.compareTo(b.path));
    return out;
  }

  /// [mediaKind] 的收件箱子目录名；不支持的种类返回 null。
  static String? folderNameFor(String mediaKind) => kindFolderNames[mediaKind];

  /// 在 [inbox] 下建好所有分类子目录（已存在的不动）。
  static Future<void> ensureKindFolders(Directory inbox) async {
    for (final String name in kindFolderNames.values) {
      await Directory(p.join(inbox.path, name)).create(recursive: true);
    }
  }

  /// 小写、去点后的扩展名。
  static String _extensionOf(String path) {
    final String ext = p.extension(path).toLowerCase();
    return ext.startsWith('.') ? ext.substring(1) : ext;
  }

  static Set<String> _bare(Iterable<String> extensions) => <String>{
    for (final String e in extensions)
      (e.startsWith('.') ? e.substring(1) : e).toLowerCase(),
  };

  /// [mediaKind] 的扫描器会收的**文件**（目录另论，见 [shouldTake]）。
  ///
  /// 每个集合都取导入实际认的真相源，不另手写子集：
  ///  - book：书 / 字幕书与伴随字幕 / 有声书音频（同书页「支持格式」chip）；
  ///  - video：视频 / 播放列表 / 外挂字幕；纯音频也收——视频来源扫到纯音频交给音乐库
  ///    （`music_audio_intake.dart`），与视频页「导入文件夹」同一结果；
  ///  - manga：单卷载体（`.mokuro` / 压缩包 / PDF）与页图。
  static bool acceptsFile(String mediaKind, String path) {
    final String ext = _extensionOf(path);
    if (ext.isEmpty) return false;
    switch (mediaKind) {
      case 'book':
        return _bare(<String>[
          ...kDragBookExtensions,
          ...kDragSubtitleExtensions,
          ...kDragAudioExtensions,
        ]).contains(ext);
      case 'video':
        return _bare(<String>[
              ...kVideoExtensions,
              ...kDragPlaylistExtensions,
              ...kDragSubtitleExtensions,
            ]).contains(ext) ||
            isAudioOnlyMediaPath(path);
      case 'manga':
        return _bare(<String>[
          ...kMangaCarrierFileExtensions,
          ...kMangaImageExtensions,
        ]).contains(ext);
      default:
        return false;
    }
  }

  /// 收件箱子目录里的一个顶层条目要不要收走。
  ///
  /// - 隐藏项（`.` 开头：`.DS_Store`、「文件」App 的 `.Trash` 等）不碰；
  /// - 子目录整个收走（整季视频、页图文件夹、原盘目录都是目录形态，归属交给扫描器判）；
  /// - 文件看 [acceptsFile]。
  static bool shouldTake(String mediaKind, FileSystemEntity entity) {
    final String name = p.basename(entity.path);
    if (name.isEmpty || name.startsWith('.')) return false;
    if (entity is Directory) return true;
    if (entity is File) return acceptsFile(mediaKind, entity.path);
    return false;
  }

  /// 收件箱 [inbox] 里 [mediaKind] 子目录下待导入的顶层条目。子目录不存在时为空。
  static Future<List<FileSystemEntity>> pendingEntries({
    required Directory inbox,
    required String mediaKind,
  }) async {
    final String? folder = folderNameFor(mediaKind);
    if (folder == null) return const <FileSystemEntity>[];
    final Directory dir = Directory(p.join(inbox.path, folder));
    if (!await dir.exists()) return const <FileSystemEntity>[];
    final List<FileSystemEntity> out = <FileSystemEntity>[
      await for (final FileSystemEntity e in dir.list(followLinks: false))
        if (shouldTake(mediaKind, e)) e,
    ];
    out.sort(
      (FileSystemEntity a, FileSystemEntity b) => a.path.compareTo(b.path),
    );
    return out;
  }

  /// 收件箱**根**（Documents 最外层）里 [mediaKind] 认的散文件，按路径排序。
  ///
  /// 只为 iTunes 文件共享（拍板台 kmfCiXlIU_）：Windows / 旧 macOS 的 iTunes「文件共享」
  /// 只列出 Documents 最外层，进不了 `Books` / `Video` / `Manga` 子文件夹，只用 iTunes
  /// 的用户只能把文件丢在根上。这里**只列不收**：根上的文件属于哪一类仍由用户当前所在的
  /// 页面决定，且要用户在导入时确认后才由 [adoptRootFiles] 移进本页的分类子目录——不把
  /// 根当成常驻的导入目录静默扫走（根上还可能有别的 app 文件，且 `.srt` / `.pdf` /
  /// 音频这类扩展名几个页面都认，静默收走必然有页面收错）。
  ///
  /// 只收文件不收目录：根上的目录是分类子目录、旧版书库白名单项或用户自建的文件夹，
  /// 它们的归属没法凭名字判断；用「文件」App 的用户本来就能把目录放进分类子目录。
  static Future<List<File>> pendingRootFiles({
    required Directory inbox,
    required String mediaKind,
  }) async {
    if (folderNameFor(mediaKind) == null) return const <File>[];
    if (!await inbox.exists()) return const <File>[];
    final List<File> out = <File>[
      await for (final FileSystemEntity e in inbox.list(followLinks: false))
        if (e is File && shouldTake(mediaKind, e)) e,
    ];
    out.sort((File a, File b) => a.path.compareTo(b.path));
    return out;
  }

  /// 把用户确认过的根上散文件 [files]（取自 [pendingRootFiles]）移进 [mediaKind] 的分类
  /// 子目录，之后走该页面原有的收件箱导入。返回移不动的条目（`名字: 原因`），它们留在
  /// 根上。分类子目录里已有同名文件时改名为 `名字 (2).扩展名`，不覆盖用户已放进去的文件。
  static Future<List<String>> adoptRootFiles({
    required Directory inbox,
    required String mediaKind,
    required List<File> files,
  }) async {
    final Directory? kindDir = kindFolder(inbox, mediaKind);
    if (kindDir == null || files.isEmpty) return const <String>[];
    await kindDir.create(recursive: true);
    final List<String> failures = <String>[];
    for (final File file in files) {
      final String name = p.basename(file.path);
      try {
        await _moveFile(file, await _freeFilePath(kindDir, name));
      } on FileSystemException catch (e) {
        failures.add('$name: $e');
      }
    }
    return failures;
  }

  /// [dir] 下不与已有条目重名的 [name]：重名时在扩展名前追加 ` (2)`、` (3)`…
  static Future<String> _freeFilePath(Directory dir, String name) async {
    String candidate = p.join(dir.path, name);
    final String stem = p.basenameWithoutExtension(name);
    final String ext = p.extension(name);
    int n = 2;
    while (await FileSystemEntity.type(candidate, followLinks: false) !=
        FileSystemEntityType.notFound) {
      candidate = p.join(dir.path, '$stem ($n)$ext');
      n++;
    }
    return candidate;
  }

  /// 批次目录名：本地时间到秒，同一秒内重复收时追加序号，保证不与已有批次合并
  /// （合并会让一次性扫描把上一批已导入的文件再扫一遍）。
  static Future<Directory> _freshBatchDirectory(
    Directory kindStaging,
    DateTime now,
  ) async {
    String two(int v) => v.toString().padLeft(2, '0');
    final String stamp =
        '${now.year}${two(now.month)}${two(now.day)}-'
        '${two(now.hour)}${two(now.minute)}${two(now.second)}';
    Directory candidate = Directory(p.join(kindStaging.path, stamp));
    int n = 1;
    while (await candidate.exists()) {
      candidate = Directory(p.join(kindStaging.path, '$stamp-$n'));
      n++;
    }
    return candidate;
  }

  /// 把收件箱里 [mediaKind] 的待导入条目移进 `<stagingRoot>/<域>/<批次>/`。
  ///
  /// 没有可收的条目返回 null（不建空批次目录）。单个条目移不动只记进
  /// [ImportInboxBatch.failures]，其余照收；一个都没移成功时删掉空批次目录并仍返回批次
  /// （调用方据 failures 报错）。
  static Future<ImportInboxBatch?> takeBatch({
    required Directory inbox,
    required Directory stagingRoot,
    required String mediaKind,
    DateTime? now,
  }) async {
    final List<FileSystemEntity> pending = await pendingEntries(
      inbox: inbox,
      mediaKind: mediaKind,
    );
    if (pending.isEmpty) return null;
    final Directory batch = await _freshBatchDirectory(
      Directory(p.join(stagingRoot.path, mediaKind)),
      now ?? DateTime.now(),
    );
    await batch.create(recursive: true);
    final List<String> moved = <String>[];
    final List<String> failures = <String>[];
    for (final FileSystemEntity entity in pending) {
      final String name = p.basename(entity.path);
      final String destination = p.join(batch.path, name);
      try {
        if (entity is Directory) {
          await moveDirectoryMerging(entity, Directory(destination));
        } else {
          await _moveFile(entity as File, destination);
        }
        moved.add(name);
      } on FileSystemException catch (e) {
        failures.add('$name: $e');
      }
    }
    if (moved.isEmpty && await batch.exists()) {
      await batch.delete(recursive: true);
    }
    return ImportInboxBatch(
      directory: batch,
      movedEntries: moved,
      failures: failures,
    );
  }

  /// 同卷 rename；跨卷（理论上收件箱与数据根同在 app 容器内，不会发生）退回复制后删源。
  static Future<void> _moveFile(File source, String destination) async {
    try {
      await source.rename(destination);
    } on FileSystemException {
      await source.copy(destination);
      await source.delete();
    }
  }
}
