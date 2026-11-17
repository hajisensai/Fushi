import 'dart:convert';
import 'dart:io';

import 'package:fushi_core/fushi_core.dart' show fnv1a32Hex, fushiDebugPrint;
import 'package:path/path.dart' as p;

abstract final class AudiobookStorage {
  static const Set<String> audioExtensions = {
    '.mp3',
    '.m4a',
    '.m4b',
    '.aac',
    '.ogg',
    '.opus',
    '.flac',
    '.wav',
    '.wma',
    '.ac3',
    '.eac3',
    '.aiff',
    '.aif',
    '.mp4',
  };

  /// 复制进持久目录时要转成 FLAC 的扩展名。AIFF 是无损 PCM，桌面与 iOS 的播放器
  /// 都认，但 Android 有声书播放器（just_audio → ExoPlayer）没有 AIFF 解析器，原样
  /// 复制的书导入 / 同步到 Android 就播不出来。转成同样无损的 FLAC，落盘的音频在
  /// 哪一端都能播。
  static const Set<String> flacTranscodedExtensions = <String>{'.aiff', '.aif'};

  /// AIFF → FLAC 编码装配点（`(source, flacPath)`，失败抛异常，返回时 flacPath 是
  /// 完整文件）。ffmpeg 在 `fushi_engine`，本包够不着：app 与服务端启动时各装一次
  /// （`installAudiobookFlacTranscoder()`）。
  ///
  /// null = 未装配 → 复制 AIFF 时抛 [StateError]。不退回原样复制：那样产出的书在
  /// Android 上播不了，而且没有任何报错。
  static Future<void> Function(String source, String flacPath)? flacTranscoder;

  /// [audioExtensions] 的去点形式（file picker 的 `allowedExtensions` 用）。
  /// 两个导入对话框原各持同一派生副本，收敛到源集合旁的单一真相。
  static final Set<String> audioExtensionsNoDot = audioExtensions
      .map((String ext) => ext.replaceFirst('.', ''))
      .toSet();

  static bool isAudioFile(String path) =>
      audioExtensions.contains(p.extension(path).toLowerCase());

  /// TODO-1236：app 层注入的 documents 根解析器（默认平台 Documents）。
  ///
  /// 本包是 `fushi` 的上游依赖（`fushi_audio` 不依赖 `fushi`），故**无法**导入 app
  /// 层的 `AppPaths`。为让有声书持久写入随桌面「自定义数据根」走（否则新导入会落回平台
  /// Documents，与 TODO-1226 迁移白名单里的 `audiobooks` 分家），app 启动期
  /// (`AppModel._prepareRuntimeDirectories`) 把此钩子接到 `AppPaths.documentsRootDirectory`
  /// ——单一真相源、自动跟随数据根、不在本包重复 SharedPreferences 解析逻辑。
  ///
  /// 平台默认值（`getApplicationDocumentsDirectory()`）由重文件
  /// `audiobook_storage_platform.dart` 的 `installAudiobookStoragePlatform()`
  /// 以 `??=` 装入——本文件是纯 Dart（无头服务端消费），不能直连 平台目录插件。
  /// 两处都未装配（纯 Dart 单测 / 服务端漏装配）时 [_documentsRoot] 抛 [StateError]，
  /// 而不是静默落到某个猜出来的目录。
  static Future<Directory> Function()? documentsRootResolver;

  /// `fushi_audio` 包内 documents 根的**单一解析点**。
  static Future<Directory> _documentsRoot() =>
      (documentsRootResolver ?? _unassignedDocumentsRoot)();

  static Future<Directory>
  _unassignedDocumentsRoot() => Future<Directory>.error(
    StateError(
      'AudiobookStorage.documentsRootResolver 未装配：Flutter app 调 '
      'installAudiobookStoragePlatform() / AppModel 注入 AppPaths；服务端在 CLI 入口注入。',
    ),
  );

  /// 单文件音频时长探测（毫秒）装配点；探测失败返回 0。平台实现（just_audio 一次性
  /// [AudioPlayer]）由 `installAudiobookStoragePlatform()` 装入。
  ///
  /// null = 未装配 → [probeAudioDurationsMs] 全 0，与插件不可用时逐文件 catch 返回 0
  /// 的既有降级**行为一致**（调用方据 0 判定无法可靠分文件）。
  static Future<int> Function(String path)? audioDurationProbeMs;

  /// TODO-811: 逐个探测音频文件时长（毫秒），下标与 [paths] 对齐。某个文件探测失败
  /// （损坏/解码不支持）返回 0（调用方据此判定无法可靠分文件）。多文件单时间轴有声书
  /// 导入时用这些边界给 cue 重新分配 [AudioCue.audioFileIndex]（见
  /// [reindexCuesByFileBoundaries]）。探测走 [audioDurationProbeMs]。
  static Future<List<int>> probeAudioDurationsMs(List<String> paths) async {
    // 每个文件一次平台播放器 构造→探头→释放 往返（Android 上 100~500 ms）；
    // 60 章的 m4b 串行就是半分钟卡在「保存中」。有界并行（同时 4 个），
    // 结果按下标回填保持与 [paths] 对齐。
    final List<int> out = List<int>.filled(paths.length, 0);
    int next = 0;
    Future<void> worker() async {
      while (next < paths.length) {
        final int i = next++;
        out[i] = await _probeOneDurationMs(paths[i]);
      }
    }

    final int workers = paths.length < probeDurationConcurrency
        ? paths.length
        : probeDurationConcurrency;
    await Future.wait<void>(
      List<Future<void>>.generate(workers, (_) => worker()),
    );
    return out;
  }

  /// [probeAudioDurationsMs] 的并行度。
  static const int probeDurationConcurrency = 4;

  static Future<int> _probeOneDurationMs(String path) {
    final Future<int> Function(String path)? probe = audioDurationProbeMs;
    if (probe == null) {
      return Future<int>.value(0);
    }
    return probe(path);
  }

  /// FNV-1a 32 位（UTF-8 逐字节），委托 fushi_core 单一真相源；输出与历史手写
  /// 副本逐字节一致（金标锁在 fushi_core 的 stable_hash_test.dart）——哈希已
  /// 固化进 `<docs>/audiobooks/<hash>/` 持久目录名，不得漂移。
  static String _stableHash(String input) => fnv1a32Hex(utf8.encode(input));

  static Future<Directory> ensurePersistDir(String bookUid) async {
    final Directory docs = await _documentsRoot();
    final String hash = _stableHash(bookUid);
    final Directory oldDir = Directory(
      p.join(docs.path, 'audiobooks', bookUid.hashCode.toRadixString(16)),
    );
    final Directory dir = Directory(p.join(docs.path, 'audiobooks', hash));
    if (!dir.existsSync() && oldDir.existsSync()) {
      oldDir.renameSync(dir.path);
    }
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }
    return dir;
  }

  /// [persistDir] 里给 [baseName] 找一个不冲突的落点。
  ///
  /// Avoid silently overwriting a same-basename file already persisted in
  /// this batch (e.g. disc1/01.m4a vs disc2/01.m4a from a split audiobook).
  /// Append a counter on collision so the positional audioFileIndex maps to
  /// distinct files instead of both entries pointing at the last writer.
  static String _freeDestIn(Directory persistDir, String baseName) {
    if (baseName.contains('..')) {
      throw ArgumentError('Invalid filename: $baseName');
    }
    String dest = p.join(persistDir.path, baseName);
    if (!p.isWithin(p.canonicalize(persistDir.path), p.canonicalize(dest))) {
      throw ArgumentError('Path traversal detected: $dest');
    }
    if (File(dest).existsSync()) {
      final String ext = p.extension(baseName);
      final String stem = p.basenameWithoutExtension(baseName);
      int counter = 1;
      do {
        dest = p.join(persistDir.path, '$stem _$counter$ext');
        counter++;
      } while (File(dest).existsSync());
    }
    return dest;
  }

  /// 持久根下的暂存目录 `<documents>/audiobooks/.staging/`：调用方要交给
  /// [adoptFile] 接管的临时文件（如从服务器下载的字幕）一律先落这里。
  ///
  /// 与各书的持久目录 `<documents>/audiobooks/<hash>/` 同在持久根下，结构上保证
  /// 同卷，[adoptFile] 因此只需一次 rename——不会落到系统 Temp（Windows 在 C 盘，
  /// 用户把数据根设到别的盘时就跨卷了）再靠「复制 + 删源」兜底。放在 `audiobooks/`
  /// 里而不是 documents 根下另起一个目录：老安装的 documents 根是整个用户
  /// `Documents`，不该往里加新顶层项；点开头的名字也不会与 [ensurePersistDir] 的
  /// 十六进制哈希目录撞名。暂存文件只在一次导入进行中存在：接管后搬走，导入失败由
  /// 调用方删掉，平时这里是空的。
  static Future<Directory> stagingDir() async {
    final Directory docs = await _documentsRoot();
    final Directory dir = Directory(
      p.join(docs.path, 'audiobooks', stagingDirName),
    );
    await dir.create(recursive: true);
    return dir;
  }

  /// [stagingDir] 的目录名（持久根 `audiobooks/` 下）。
  static const String stagingDirName = '.staging';

  /// 把调用方放在 [stagingDir] 里的**临时文件** [src] 收进 [persistDir]（不转码），
  /// 返回落点。
  ///
  /// 与 [persistFileWithProgress]（复制、源文件归调用方）不同，这里持久化步骤接管
  /// 源文件的生命周期：同卷 rename，源文件就此不在原处，调用方不用在 finally 里
  /// 清理，也就不会出现「清理失败盖掉已成功的导入结果」。没有跨卷「复制再删源」
  /// 的分支：暂存目录与持久目录同在 documents 根下，rename 失败（文件被占用等）
  /// 照常抛，由调用方的导入回滚收尾（`importStandaloneSubtitleBook` 会撤掉已落的
  /// 正文 EPUB 与持久目录）。
  static Future<String> adoptFile(File src, Directory persistDir) async {
    if (p.isWithin(p.canonicalize(persistDir.path), p.canonicalize(src.path))) {
      return src.path;
    }
    final String dest = _freeDestIn(persistDir, p.basename(src.path));
    return (await src.rename(dest)).path;
  }

  static Future<String> persistFileWithProgress(
    File src,
    Directory persistDir, {
    void Function(int copied, int total)? onProgress,
  }) async {
    if (p.isWithin(p.canonicalize(persistDir.path), p.canonicalize(src.path))) {
      return src.path;
    }
    final bool transcode = flacTranscodedExtensions.contains(
      p.extension(src.path).toLowerCase(),
    );
    final String baseName = transcode
        ? '${p.basenameWithoutExtension(src.path)}.flac'
        : p.basename(src.path);
    final String dest = _freeDestIn(persistDir, baseName);
    final int totalBytes = await src.length();
    if (transcode) return _transcodeToFlac(src, dest, totalBytes, onProgress);

    // 逐块 `await` 写：打不开落点 / 写到一半磁盘满都在这一句上直接抛给调用方。
    // `IOSink` 的写错误走的是 `done`，`add` 不报、`flush` 在落点打不开时不返回（macOS 实测）
    // （BUG-4791：拷贝失败必须以异常收场，调用方才撤得回去）。
    RandomAccessFile? out;
    bool complete = false;
    try {
      out = await File(dest).open(mode: FileMode.write);
      int copied = 0;
      await for (final List<int> chunk in src.openRead()) {
        await out.writeFrom(chunk);
        copied += chunk.length;
        onProgress?.call(copied, totalBytes);
      }
      await out.flush();
      complete = true;
    } finally {
      try {
        await out?.close();
      } finally {
        if (!complete) {
          final File destFile = File(dest);
          if (destFile.existsSync()) destFile.deleteSync();
        }
      }
    }

    final int destLen = await File(dest).length();
    if (destLen != totalBytes) {
      File(dest).deleteSync();
      throw StateError(
        'Copy verification failed: expected $totalBytes bytes, got $destLen',
      );
    }

    fushiDebugPrint(
      '[fushi-import] persisted ${src.path} → $dest '
      '(${(totalBytes / 1024 / 1024).toStringAsFixed(1)} MB)',
    );
    return dest;
  }

  /// [persistFileWithProgress] 的 AIFF 分支：编码成 [dest]（FLAC）。进度按源文件
  /// 字节报（编码前 0、完成后满），与复制分支的累计口径一致。
  static Future<String> _transcodeToFlac(
    File src,
    String dest,
    int totalBytes,
    void Function(int copied, int total)? onProgress,
  ) async {
    final Future<void> Function(String, String)? transcoder = flacTranscoder;
    if (transcoder == null) {
      throw StateError(
        'AudiobookStorage.flacTranscoder is not installed; '
        'cannot persist ${p.basename(src.path)}',
      );
    }
    onProgress?.call(0, totalBytes);
    await transcoder(src.path, dest);
    final File out = File(dest);
    if (!out.existsSync() || out.lengthSync() == 0) {
      throw StateError('FLAC transcode produced no output: $dest');
    }
    onProgress?.call(totalBytes, totalBytes);
    fushiDebugPrint('[fushi-import] transcoded ${src.path} → $dest');
    return dest;
  }

  /// 已经落进 app 目录、但没经过 [syncAudioFiles] 的音频（同步包 / 互联下载解出来
  /// 的，发送端可能是「引用原文件」导入的 AIFF 书）就地规整：AIFF 转成同目录的
  /// FLAC 并删掉原件，其余原样。返回与 [paths] 一一对应的新路径，顺序不变（cue 的
  /// `audioFileIndex` 就是下标）。FLAC 名与列表里别的轨撞名时加序号，不覆盖别的轨。
  static Future<List<String>> transcodePersistedAiff(List<String> paths) async {
    final Set<String> taken = paths.map(p.canonicalize).toSet();
    final List<String> out = <String>[];
    for (final String path in paths) {
      if (!flacTranscodedExtensions.contains(p.extension(path).toLowerCase())) {
        out.add(path);
        continue;
      }
      final String dest = _freeFlacName(path, taken);
      taken.add(p.canonicalize(dest));
      // 目录里同名的旧 FLAC 只可能是这本书上一次导入的残留（目录按书分）。
      final File stale = File(dest);
      if (stale.existsSync()) stale.deleteSync();
      await _transcodeToFlac(File(path), dest, 0, null);
      File(path).deleteSync();
      out.add(dest);
    }
    return out;
  }

  /// [aiffPath] 同目录下第一个不在 [taken] 里的 `<stem>.flac` / `<stem> _N.flac`。
  static String _freeFlacName(String aiffPath, Set<String> taken) {
    final String dir = p.dirname(aiffPath);
    final String stem = p.basenameWithoutExtension(aiffPath);
    String dest = p.join(dir, '$stem.flac');
    for (int n = 1; taken.contains(p.canonicalize(dest)); n++) {
      dest = p.join(dir, '$stem _$n.flac');
    }
    return dest;
  }

  /// TODO-935 ①A：判断 [filePath] 是否「引用原文件」(reference)，即**不在** app
  /// 内部有声书持久目录 `<appDoc>/audiobooks/` 之下。
  ///
  /// 复制导入的文件恒落 [ensurePersistDir] 派生的 `<appDoc>/audiobooks/<hash>/`，
  /// 故「引用 vs 已复制」无需额外持久化标记，纯由路径与持久根的从属关系派生
  /// （消除特殊情况、零 schema 改动、旧已复制书自动判为已复制）。
  ///
  /// [persistRoot] 为 `<appDoc>/audiobooks` 绝对路径；测试可注入假根。生产取
  /// [audiobooksRootDir]。空路径返回 false（无法判定时按「已复制」保守处理，
  /// 避免误触发删源守卫）。
  static bool isReferencedPath({
    required String filePath,
    required String persistRoot,
  }) {
    if (filePath.isEmpty || persistRoot.isEmpty) return false;
    final String canonicalFile = p.canonicalize(filePath);
    final String canonicalRoot = p.canonicalize(persistRoot);
    if (p.equals(canonicalFile, canonicalRoot)) return false;
    return !p.isWithin(canonicalRoot, canonicalFile);
  }

  /// `<appDoc>/audiobooks` 的绝对路径（复制导入的统一持久根）。
  static Future<String> audiobooksRootDir() async {
    final Directory docs = await _documentsRoot();
    return p.join(docs.path, 'audiobooks');
  }

  /// 任一 [paths] 落在持久根之外即视为「引用导入」。空列表返回 false。
  static bool anyReferenced({
    required List<String> paths,
    required String persistRoot,
  }) => paths.any(
    (String path) => isReferencedPath(filePath: path, persistRoot: persistRoot),
  );

  /// TODO-935 ①A 断链检测：返回 [paths] 中在磁盘上不存在的路径子集（保持原序）。
  /// [exists] 默认查真实文件系统，测试可注入假谓词。空列表返回空列表。
  static List<String> missingPaths(
    List<String> paths, {
    bool Function(String path)? exists,
  }) {
    final bool Function(String) probe =
        exists ?? (String path) => File(path).existsSync();
    return paths.where((String path) => !probe(path)).toList();
  }

  /// [paths] 中是否存在任一断链文件（引用导入后原文件被移动/删除）。
  static bool hasMissingPaths(
    List<String> paths, {
    bool Function(String path)? exists,
  }) => missingPaths(paths, exists: exists).isNotEmpty;

  /// 两组音频路径是否是**同一套音频**（BUG-1679 的进度作废判据）。
  /// 有序比较：顺序就是 `AudioCue.audioFileIndex` 的含义，换序即换时间轴。
  static bool sameAudioPathList(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  /// 把 [persistDir] 同步成**恰好** [sources] 这一组音频，返回落地后的路径
  /// （顺序与 [sources] 一一对应，可直接落 `audioPaths`）。
  ///
  /// 这是持久目录音频的**唯一**写入原语，故意不暴露「清目录」和「复制」两步。
  /// BUG-1678：拆成两步就必然有人写成「先清后拷」，而源文件本身可能就落在
  /// [persistDir] 内——重新导入时「沿用现有音频」正是把已持久化的路径原样喂回
  /// 来的。先清就是先把源文件删掉，随后复制循环再去读它抛 [FileSystemException]
  /// 中止：用户的音频没了、库里还指着已不存在的路径（症状「换完字幕音频再也不
  /// 响」）。同步语义让「全换新 / 全沿用 / 混合」三种情况走同一条无分支路径，
  /// 且天然幂等——喂同一组进去是空操作。
  ///
  /// 整组替换是**全有或全无**的（BUG-4791）。顺序固定为：
  ///   1. 新文件先全部拷进 `<persistDir>/.incoming/`（旧文件原样不动）；
  ///   2. 被换下的旧音频挪进 `<persistDir>/.retired/`（同卷 rename，不删）；
  ///   3. 新文件从暂存挪到正式名字（旧文件已让出名字，不会被挤成 `<stem> _1`）；
  ///   4. 跑 [commit]——调用方的写库；
  ///   5. 删掉 `.retired/`。
  /// 1～4 任何一步抛错都原路撤回：新文件删掉、旧文件挪回原名，目录与调用前一致，
  /// 库也还没动（[commit] 自己要么全写要么不写——调用方包事务）。旧实现是「先删旧
  /// 再逐个拷」，拷到一半失败（磁盘满 / 源盘掉线 / AIFF 转码失败）时旧音频已经
  /// 删光、库里还指着它们。代价是过渡期磁盘上同时有新旧两份。
  ///
  /// [commit]：把返回的路径写进库的那一步，入参就是本方法的返回值。给了它，旧音频
  /// 就是在写库**之后**才真正删除的；不给则 3 之后直接进 5（调用方随后自己写库，
  /// 写库失败时旧音频已经没了——新建一本书、目录本来就是空的调用方才可以不给）。
  ///
  /// 上一次同步在 2～5 之间被杀进程时留下的 `.incoming/` / `.retired/` 在下一次
  /// 同步开头收拾：暂存的新文件丢弃，被挪走的旧文件名字还空着的挪回原处。
  ///
  /// [copy] 为 false 时是引用导入（仅桌面）：不拷贝，直接返回原始绝对路径，持久
  /// 目录里的旧副本照样走 2 / 4 / 5（写库之后才删）。
  /// [onProgress] 报的是**整批**字节进度；[onFile] 在每个文件开始复制时报 basename。
  static Future<List<String>> syncAudioFiles(
    Directory persistDir,
    List<String> sources, {
    bool copy = true,
    void Function(int copiedBytes, int totalBytes)? onProgress,
    void Function(String name)? onFile,
    Future<void> Function(List<String> persisted)? commit,
  }) async {
    final Directory incoming = Directory(
      p.join(persistDir.path, incomingDirName),
    );
    final Directory retired = Directory(
      p.join(persistDir.path, retiredDirName),
    );
    await _recoverInterruptedSwap(persistDir, incoming, retired);

    // 已经在目录里的源文件是零拷贝，全程不动。
    final List<bool> inPlace = <bool>[
      for (final String path in sources) _isInside(persistDir, path),
    ];
    final Set<String> keep = <String>{
      for (int i = 0; i < sources.length; i++)
        if (inPlace[i]) p.canonicalize(sources[i]),
    };

    // 只有需要真复制的文件计入总量。源文件读不到在这里就抛，磁盘还没动。
    int totalBytes = 0;
    if (copy) {
      for (int i = 0; i < sources.length; i++) {
        if (inPlace[i]) continue;
        totalBytes += await File(sources[i]).length();
      }
    }

    final List<String> promoted = <String>[];
    final List<({String from, String to})> retiredMoves =
        <({String from, String to})>[];
    final List<String> persisted;
    try {
      // 1. 新文件进暂存目录。
      final List<String?> staged = List<String?>.filled(sources.length, null);
      if (copy) {
        int copiedBytes = 0;
        for (int i = 0; i < sources.length; i++) {
          final String path = sources[i];
          onFile?.call(p.basename(path));
          if (!inPlace[i]) {
            await incoming.create(recursive: true);
            final File src = File(path);
            final int base = copiedBytes;
            staged[i] = await persistFileWithProgress(
              src,
              incoming,
              onProgress: (int copied, int total) =>
                  onProgress?.call(base + copied, totalBytes),
            );
            copiedBytes += await src.length();
          }
          onProgress?.call(copiedBytes, totalBytes);
        }
      }

      // 2. 被换下的旧音频让出名字（不删）。
      if (persistDir.existsSync()) {
        for (final FileSystemEntity f in persistDir.listSync()) {
          if (f is! File || !isAudioFile(f.path)) continue;
          if (keep.contains(p.canonicalize(f.path))) continue;
          await retired.create(recursive: true);
          final String to = _freeDestIn(retired, p.basename(f.path));
          await f.rename(to);
          retiredMoves.add((from: f.path, to: to));
        }
      }

      // 3. 新文件落到正式名字。
      final List<String> landed = <String>[];
      for (int i = 0; i < sources.length; i++) {
        final String? stagedPath = staged[i];
        if (stagedPath == null) {
          landed.add(sources[i]);
          continue;
        }
        final String dest = _freeDestIn(persistDir, p.basename(stagedPath));
        await File(stagedPath).rename(dest);
        promoted.add(dest);
        landed.add(dest);
      }
      persisted = landed;

      // 4. 调用方写库。
      await commit?.call(List<String>.unmodifiable(persisted));
    } catch (_) {
      await _rollBackSwap(
        promoted: promoted,
        retiredMoves: retiredMoves,
        incoming: incoming,
        retired: retired,
      );
      rethrow;
    }

    // 5. 库已指向新文件：旧的、以及空掉的暂存目录可以删了。删不掉只记日志——
    // 换音频已经成立，留一个下次同步会收拾的目录不该让它报失败。
    await _deleteSwapDir(incoming);
    await _deleteSwapDir(retired);
    return persisted;
  }

  /// [syncAudioFiles] 的暂存目录名（各书持久目录下）：拷贝中的新音频。
  static const String incomingDirName = '.incoming';

  /// [syncAudioFiles] 的回收目录名（各书持久目录下）：已让出名字、等写库后删除的
  /// 旧音频。
  static const String retiredDirName = '.retired';

  static bool _isInside(Directory dir, String path) =>
      p.isWithin(p.canonicalize(dir.path), p.canonicalize(path));

  /// 撤回一次没走完的 [syncAudioFiles]：删掉已落到正式名字的新文件，把挪走的旧
  /// 文件挪回原名，丢掉暂存目录。每一步各自尽力：撤回途中再出错只记日志，抛给
  /// 调用方的仍是最初那个错误。
  static Future<void> _rollBackSwap({
    required List<String> promoted,
    required List<({String from, String to})> retiredMoves,
    required Directory incoming,
    required Directory retired,
  }) async {
    for (final String path in promoted) {
      try {
        final File f = File(path);
        if (f.existsSync()) await f.delete();
      } catch (e) {
        fushiDebugPrint('[fushi-import] swap rollback: drop $path failed: $e');
      }
    }
    for (final ({String from, String to}) move in retiredMoves.reversed) {
      try {
        await File(move.to).rename(move.from);
      } catch (e) {
        fushiDebugPrint(
          '[fushi-import] swap rollback: restore ${move.from} failed: $e',
        );
      }
    }
    await _deleteSwapDir(incoming);
    // 旧文件都挪回去了才删回收目录；有挪不回去的就留着，下一次同步开头再试。
    if (retired.existsSync() && retired.listSync().isEmpty) {
      await _deleteSwapDir(retired);
    }
  }

  /// 上一次 [syncAudioFiles] 中途被杀进程留下的暂存 / 回收目录：暂存的新文件从未
  /// 写进库，丢弃；回收目录里的旧文件，原名还空着的挪回去（库多半还指着它），
  /// 原名已被占的（新文件已落位）丢弃。
  static Future<void> _recoverInterruptedSwap(
    Directory persistDir,
    Directory incoming,
    Directory retired,
  ) async {
    if (incoming.existsSync()) await incoming.delete(recursive: true);
    if (!retired.existsSync()) return;
    for (final FileSystemEntity f in retired.listSync()) {
      if (f is! File) continue;
      final String home = p.join(persistDir.path, p.basename(f.path));
      if (File(home).existsSync()) continue;
      await f.rename(home);
    }
    await retired.delete(recursive: true);
  }

  static Future<void> _deleteSwapDir(Directory dir) async {
    try {
      if (dir.existsSync()) await dir.delete(recursive: true);
    } catch (e) {
      fushiDebugPrint('[fushi-import] swap cleanup: ${dir.path} failed: $e');
    }
  }

  static Future<void> deletePersistDir(String bookUid) async {
    final Directory docs = await _documentsRoot();
    final String hash = _stableHash(bookUid);
    final Directory dir = Directory(p.join(docs.path, 'audiobooks', hash));
    if (dir.existsSync()) {
      await dir.delete(recursive: true);
      fushiDebugPrint('[fushi-import] deleted persist dir: ${dir.path}');
    }
    final Directory oldDir = Directory(
      p.join(docs.path, 'audiobooks', bookUid.hashCode.toRadixString(16)),
    );
    if (oldDir.existsSync()) {
      await oldDir.delete(recursive: true);
      fushiDebugPrint(
        '[fushi-import] deleted legacy persist dir: ${oldDir.path}',
      );
    }
  }
}
