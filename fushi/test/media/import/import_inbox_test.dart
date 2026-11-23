import 'dart:io';

import 'package:test/test.dart';
import 'package:path/path.dart' as p;

import 'package:fushi/src/media/import/import_inbox.dart';
import 'package:fushi_engine/media/video/video_sidecar.dart'
    show listSidecarSubtitles;

/// 拍板台 nLXhu0d7gV：iOS「文件」App 收件箱——收走本域认的文件 / 目录，留下不认的。
void main() {
  late Directory sandbox;
  late Directory inbox;
  late Directory staging;

  File touch(String path) => File(path)
    ..createSync(recursive: true)
    ..writeAsStringSync('x');

  setUp(() {
    sandbox = Directory.systemTemp.createTempSync('import_inbox_');
    inbox = Directory(p.join(sandbox.path, 'Documents'))..createSync();
    staging = Directory(p.join(sandbox.path, 'data', 'inbox_imports'));
  });

  tearDown(() {
    if (sandbox.existsSync()) sandbox.deleteSync(recursive: true);
  });

  test('ensureKindFolders 建出三个分类子目录与预留的 Games，重复调用不炸', () async {
    await ImportInbox.ensureKindFolders(inbox);
    await ImportInbox.ensureKindFolders(inbox);
    expect(
      ImportInbox.allFolderNames,
      unorderedEquals(<String>['Books', 'Video', 'Manga', 'Games']),
    );
    for (final String name in ImportInbox.allFolderNames) {
      expect(Directory(p.join(inbox.path, name)).existsSync(), isTrue);
    }
  });

  test('acceptsFile 按页面种类取导入实际认的扩展名', () {
    expect(ImportInbox.acceptsFile('video', 'a/EP01.MKV'), isTrue);
    expect(ImportInbox.acceptsFile('video', 'a/EP01.ass'), isTrue);
    expect(ImportInbox.acceptsFile('video', 'a/list.m3u8'), isTrue);
    expect(
      ImportInbox.acceptsFile('video', 'a/song.flac'),
      isTrue,
      reason: '视频来源扫到的纯音频交给音乐库，与「导入文件夹」同一结果',
    );
    expect(ImportInbox.acceptsFile('video', 'a/book.epub'), isFalse);
    expect(ImportInbox.acceptsFile('book', 'a/book.epub'), isTrue);
    expect(ImportInbox.acceptsFile('book', 'a/book.m4b'), isTrue);
    expect(ImportInbox.acceptsFile('book', 'a/EP01.mkv'), isFalse);
    expect(ImportInbox.acceptsFile('manga', 'a/vol1.cbz'), isTrue);
    expect(ImportInbox.acceptsFile('manga', 'a/vol1.mokuro'), isTrue);
    expect(ImportInbox.acceptsFile('manga', 'a/p001.webp'), isTrue);
    expect(ImportInbox.acceptsFile('manga', 'a/notes.docx'), isFalse);
    expect(
      ImportInbox.acceptsFile('music', 'a/song.flac'),
      isFalse,
      reason: '没有收件箱子目录的种类一律不收',
    );
    expect(ImportInbox.acceptsFile('video', 'a/noext'), isFalse);
  });

  test('takeBatch 收走认的文件与子目录，不认的 / 隐藏项留在收件箱', () async {
    final String video = p.join(inbox.path, 'Video');
    touch(p.join(video, 'EP01.mkv'));
    touch(p.join(video, 'EP01.ja.srt'));
    touch(p.join(video, 'Season 2', 'EP01.mkv'));
    touch(p.join(video, 'notes.docx'));
    touch(p.join(video, '.DS_Store'));

    final ImportInboxBatch? batch = await ImportInbox.takeBatch(
      inbox: inbox,
      stagingRoot: staging,
      mediaKind: 'video',
      now: DateTime(2026, 11, 16, 9, 5, 7),
    );

    expect(batch, isNotNull);
    expect(batch!.failures, isEmpty);
    expect(
      batch.movedEntries,
      unorderedEquals(<String>['EP01.mkv', 'EP01.ja.srt', 'Season 2']),
    );
    expect(
      p.equals(
        batch.directory.path,
        p.join(staging.path, 'video', '20261116-090507'),
      ),
      isTrue,
    );
    expect(File(p.join(batch.directory.path, 'EP01.mkv')).existsSync(), isTrue);
    expect(
      File(p.join(batch.directory.path, 'EP01.ja.srt')).existsSync(),
      isTrue,
    );
    expect(
      File(p.join(batch.directory.path, 'Season 2', 'EP01.mkv')).existsSync(),
      isTrue,
    );
    // 收件箱里：认的被移走，不认的与隐藏项原样留着。
    expect(File(p.join(video, 'EP01.mkv')).existsSync(), isFalse);
    expect(Directory(p.join(video, 'Season 2')).existsSync(), isFalse);
    expect(File(p.join(video, 'notes.docx')).existsSync(), isTrue);
    expect(File(p.join(video, '.DS_Store')).existsSync(), isTrue);

    // 再收一次：只剩不认的 → 没有批次。
    expect(
      await ImportInbox.takeBatch(
        inbox: inbox,
        stagingRoot: staging,
        mediaKind: 'video',
      ),
      isNull,
    );
  });

  test('子目录不存在 / 为空 → 没有批次，也不建空批次目录', () async {
    expect(
      await ImportInbox.takeBatch(
        inbox: inbox,
        stagingRoot: staging,
        mediaKind: 'book',
      ),
      isNull,
    );
    Directory(p.join(inbox.path, 'Books')).createSync();
    expect(
      await ImportInbox.takeBatch(
        inbox: inbox,
        stagingRoot: staging,
        mediaKind: 'book',
      ),
      isNull,
    );
    expect(staging.existsSync(), isFalse);
  });

  test('只有视频移进数据根；书 / 漫画原地扫收件箱（导入器已复制进书库，移走只会多占一份）', () {
    expect(ImportInbox.movesIntoDataRoot('video'), isTrue);
    expect(ImportInbox.movesIntoDataRoot('book'), isFalse);
    expect(ImportInbox.movesIntoDataRoot('manga'), isFalse);
    expect(
      ImportInbox.kindFolder(inbox, 'book')!.path,
      p.join(inbox.path, 'Books'),
    );
    expect(ImportInbox.kindFolder(inbox, 'music'), isNull);
  });

  test('没打完成标记的批次是待续导；打了标记的不再续导；空批次顺手删掉', () async {
    touch(p.join(inbox.path, 'Video', 'EP01.mkv'));
    final ImportInboxBatch? done = await ImportInbox.takeBatch(
      inbox: inbox,
      stagingRoot: staging,
      mediaKind: 'video',
      now: DateTime(2026, 11, 16, 9),
    );
    touch(p.join(inbox.path, 'Video', 'EP02.mkv'));
    final ImportInboxBatch? failed = await ImportInbox.takeBatch(
      inbox: inbox,
      stagingRoot: staging,
      mediaKind: 'video',
      now: DateTime(2026, 11, 16, 10),
    );
    final Directory empty = Directory(
      p.join(staging.path, 'video', '20261116-110000'),
    )..createSync(recursive: true);
    File(p.join(empty.path, '.DS_Store')).writeAsStringSync('');

    await ImportInbox.markBatchImported(done!.directory);
    expect(
      File(
        p.join(done.directory.path, ImportInbox.importedMarkerName),
      ).existsSync(),
      isTrue,
    );

    final List<Directory> unfinished = await ImportInbox.unfinishedBatches(
      stagingRoot: staging,
      mediaKind: 'video',
    );
    expect(unfinished.map((Directory d) => d.path), <String>[
      failed!.directory.path,
    ]);
    expect(empty.existsSync(), isFalse);
    expect(
      await ImportInbox.unfinishedBatches(
        stagingRoot: staging,
        mediaKind: 'manga',
      ),
      isEmpty,
    );
  });

  group('收件箱导入的页面流程（源码守卫）', () {
    final String view = File(
      'lib/src/pages/implementations/media_sources_view.dart',
    ).readAsStringSync();

    String bodyOf(String signature) {
      final int start = view.indexOf(signature);
      expect(start, isNot(-1), reason: '找不到 $signature');
      // 方法体到第一个两格缩进的右花括号为止。
      final int end = view.indexOf('\n  }\n', start);
      return view.substring(start, end == -1 ? view.length : end);
    }

    test('视频：批次移走后不因页面卸载半途返回，成功才打标记，先续导遗留批次', () {
      final String body = bodyOf('Future<void> _importInboxIntoDataRoot(');
      final int take = body.indexOf('ImportInbox.takeBatch(');
      expect(take, isNot(-1));
      expect(
        body.substring(take).contains('mounted'),
        isFalse,
        reason: '文件已经移出收件箱，此时返回就会让批次卡在用户看不见的地方',
      );
      expect(body, contains('ImportInbox.unfinishedBatches('));
      expect(body, contains('summary.error == null'));
      expect(body, contains('ImportInbox.markBatchImported('));
    });

    test('书 / 漫画原地扫收件箱子目录，不移文件', () {
      final String body = bodyOf('Future<void> _importInboxInPlace(');
      expect(body, isNot(contains('takeBatch')));
      expect(body, contains('ImportInbox.kindFolder('));
    });

    test('重入保护：入口同步置忙，且计入 isBusy', () {
      final String entry = bodyOf('Future<void> importFromInbox()');
      final int check = entry.indexOf('if (isBusy) return;');
      final int set = entry.indexOf('_inboxImporting = true');
      expect(check, isNot(-1));
      expect(set, greaterThan(check));
      expect(
        entry.substring(check, set).contains('await'),
        isFalse,
        reason: '检查与置忙之间有 await 就挡不住连点',
      );
      expect(view, contains('_inboxImporting ||'));
    });
  });

  test('同一秒内收两批：批次目录不合并（否则一次性扫描会把上一批再扫一遍）', () async {
    final DateTime now = DateTime(2026, 11, 16, 9, 5, 7);
    touch(p.join(inbox.path, 'Manga', 'vol1.cbz'));
    final ImportInboxBatch? first = await ImportInbox.takeBatch(
      inbox: inbox,
      stagingRoot: staging,
      mediaKind: 'manga',
      now: now,
    );
    touch(p.join(inbox.path, 'Manga', 'vol2.cbz'));
    final ImportInboxBatch? second = await ImportInbox.takeBatch(
      inbox: inbox,
      stagingRoot: staging,
      mediaKind: 'manga',
      now: now,
    );

    expect(first!.directory.path, isNot(second!.directory.path));
    expect(second.movedEntries, <String>['vol2.cbz']);
    expect(
      first.directory.listSync().map(
        (FileSystemEntity e) => p.basename(e.path),
      ),
      <String>['vol1.cbz'],
    );
  });

  // 拍板台 kmfCiXlIU_：iTunes 文件共享只看得见 Documents 最外层。
  group('收件箱根上的散文件（iTunes）', () {
    test('Games 只是预留目录：不映射任何媒体种类（iOS 游戏模块只是串流接收端）', () {
      expect(ImportInbox.folderNameFor('game'), isNull);
      expect(
        ImportInbox.kindFolderNames.keys,
        unorderedEquals(<String>['book', 'video', 'manga']),
      );
      expect(ImportInbox.reservedFolderNames, <String>['Games']);
      expect(
        ImportInbox.kindFolderNames.values,
        isNot(contains('Games')),
        reason: 'Games 不进收件箱管线，放进去的文件不会被任何页面收走',
      );
    });

    test('预留的 Games 目录里的文件哪个页面都不收、也不动', () async {
      await ImportInbox.ensureKindFolders(inbox);
      final File game = touch(p.join(inbox.path, 'Games', 'clip.mp4'));
      final File book = touch(p.join(inbox.path, 'Games', 'novel.epub'));
      for (final String kind in <String>['book', 'video', 'manga', 'game']) {
        expect(
          await ImportInbox.pendingEntries(inbox: inbox, mediaKind: kind),
          isEmpty,
          reason: kind,
        );
        expect(
          await ImportInbox.pendingRootFiles(inbox: inbox, mediaKind: kind),
          isEmpty,
          reason: '根上的 Games 是目录，不当散文件收：$kind',
        );
        expect(
          await ImportInbox.takeBatch(
            inbox: inbox,
            stagingRoot: staging,
            mediaKind: kind,
          ),
          isNull,
          reason: kind,
        );
      }
      expect(game.existsSync(), isTrue);
      expect(book.existsSync(), isTrue);
    });

    test('pendingRootFiles 只列本页认的根上文件，不碰目录 / 隐藏项 / 分类子目录', () async {
      await ImportInbox.ensureKindFolders(inbox);
      touch(p.join(inbox.path, 'Pokemon EP01.mkv'));
      touch(p.join(inbox.path, 'Pokemon EP01.srt'));
      touch(p.join(inbox.path, 'novel.epub'));
      touch(p.join(inbox.path, '.DS_Store'));
      touch(p.join(inbox.path, 'Season 2', 'EP01.mkv'));
      touch(p.join(inbox.path, 'Video', 'EP02.mkv'));

      List<String> names(List<File> files) => <String>[
        for (final File f in files) p.basename(f.path),
      ];
      expect(
        names(
          await ImportInbox.pendingRootFiles(inbox: inbox, mediaKind: 'video'),
        ),
        <String>['Pokemon EP01.mkv', 'Pokemon EP01.srt'],
      );
      expect(
        names(
          await ImportInbox.pendingRootFiles(inbox: inbox, mediaKind: 'book'),
        ),
        <String>['Pokemon EP01.srt', 'novel.epub'],
        reason: '字幕几个页面都认：归属由当前页面 + 用户确认决定，不靠扩展名猜',
      );
      expect(
        await ImportInbox.pendingRootFiles(inbox: inbox, mediaKind: 'game'),
        isEmpty,
      );
    });

    test('adoptRootFiles 移进本页分类子目录，重名不覆盖', () async {
      await ImportInbox.ensureKindFolders(inbox);
      touch(p.join(inbox.path, 'Video', 'EP01.mkv')).writeAsStringSync('old');
      touch(p.join(inbox.path, 'EP01.mkv')).writeAsStringSync('new');
      touch(p.join(inbox.path, 'EP02.mkv'));

      final List<File> root = await ImportInbox.pendingRootFiles(
        inbox: inbox,
        mediaKind: 'video',
      );
      final List<String> failures = await ImportInbox.adoptRootFiles(
        inbox: inbox,
        mediaKind: 'video',
        files: root,
      );

      expect(failures, isEmpty);
      final String video = p.join(inbox.path, 'Video');
      expect(File(p.join(video, 'EP01.mkv')).readAsStringSync(), 'old');
      expect(File(p.join(video, 'EP01 (2).mkv')).readAsStringSync(), 'new');
      expect(File(p.join(video, 'EP02.mkv')).existsSync(), isTrue);
      expect(
        await ImportInbox.pendingRootFiles(inbox: inbox, mediaKind: 'video'),
        isEmpty,
      );
      expect(
        (await ImportInbox.pendingEntries(
          inbox: inbox,
          mediaKind: 'video',
        )).map((FileSystemEntity e) => p.basename(e.path)),
        <String>['EP01 (2).mkv', 'EP01.mkv', 'EP02.mkv'],
        reason: '移进分类子目录后与「文件」App 放进去的文件同路导入',
      );
    });

    // HBK-AUDIT-019：外挂字幕靠与视频同 stem 配对（pickSidecar），逐个文件避重名会把
    // 同组拆成不同 stem——新视频丢字幕、旧视频反而配上新字幕。
    Future<List<String>> adoptAll() async => ImportInbox.adoptRootFiles(
      inbox: inbox,
      mediaKind: 'video',
      files: await ImportInbox.pendingRootFiles(
        inbox: inbox,
        mediaKind: 'video',
      ),
    );
    String videoDirContent(String name) =>
        File(p.join(inbox.path, 'Video', name)).readAsStringSync();

    test('只有视频撞名时，同 stem 的外挂字幕跟着视频一起改名', () async {
      await ImportInbox.ensureKindFolders(inbox);
      touch(p.join(inbox.path, 'Video', 'EP01.mkv')).writeAsStringSync('old');
      touch(p.join(inbox.path, 'EP01.mkv')).writeAsStringSync('new');
      touch(p.join(inbox.path, 'EP01.srt')).writeAsStringSync('new-srt');
      touch(p.join(inbox.path, 'ep01.ja.ass')).writeAsStringSync('new-ja');

      expect(await adoptAll(), isEmpty);
      expect(videoDirContent('EP01.mkv'), 'old');
      expect(videoDirContent('EP01 (2).mkv'), 'new');
      expect(videoDirContent('EP01 (2).srt'), 'new-srt');
      expect(videoDirContent('EP01 (2).ja.ass'), 'new-ja');
      expect(
        File(p.join(inbox.path, 'Video', 'EP01.srt')).existsSync(),
        isFalse,
        reason: '新字幕不能落到旧视频的 stem 上被旧视频配走',
      );
    });

    test('只有字幕撞名时，视频也换 stem，不去配旧字幕', () async {
      await ImportInbox.ensureKindFolders(inbox);
      touch(p.join(inbox.path, 'Video', 'EP01.srt')).writeAsStringSync('old');
      touch(p.join(inbox.path, 'EP01.mkv')).writeAsStringSync('new');
      touch(p.join(inbox.path, 'EP01.srt')).writeAsStringSync('new-srt');

      expect(await adoptAll(), isEmpty);
      expect(videoDirContent('EP01.srt'), 'old');
      expect(videoDirContent('EP01 (2).mkv'), 'new');
      expect(videoDirContent('EP01 (2).srt'), 'new-srt');
      expect(
        File(p.join(inbox.path, 'Video', 'EP01.mkv')).existsSync(),
        isFalse,
      );
    });

    test('不撞名的组与不相干文件原名搬入；stem 互为前缀时字幕归最长主干，不必改名', () async {
      await ImportInbox.ensureKindFolders(inbox);
      touch(p.join(inbox.path, 'Video', 'EP02.mkv')).writeAsStringSync('old');
      touch(p.join(inbox.path, 'EP01.mkv'));
      touch(p.join(inbox.path, 'EP01.v2.mkv')).writeAsStringSync('v2');
      touch(p.join(inbox.path, 'EP01.v2.srt')).writeAsStringSync('v2-srt');
      touch(p.join(inbox.path, 'EP02.mkv')).writeAsStringSync('new');
      touch(p.join(inbox.path, 'EP03.srt')).writeAsStringSync('lone');

      expect(await adoptAll(), isEmpty);
      final String video = p.join(inbox.path, 'Video');
      final List<String> names = Directory(video).listSync().map((
        FileSystemEntity e,
      ) {
        return p.basename(e.path);
      }).toList()..sort();
      expect(names, <String>[
        'EP01.mkv',
        'EP01.v2.mkv',
        'EP01.v2.srt',
        'EP02 (2).mkv',
        'EP02.mkv',
        'EP03.srt',
      ]);
      // `EP01.v2.srt` 字面上也配得上 `EP01`（`.v2` 像语言标记），但按最长主干认领归
      // `EP01.v2.mkv`：播放器给 `EP01.mkv` 列字幕时不会列它，两组都保留原名。
      expect(listSidecarSubtitles('EP01', names), isEmpty);
      expect(listSidecarSubtitles('EP01.v2', names), <String>['EP01.v2.srt']);
      expect(videoDirContent('EP01.v2.mkv'), 'v2');
      expect(videoDirContent('EP01.v2.srt'), 'v2-srt');
      expect(videoDirContent('EP02 (2).mkv'), 'new');
      expect(videoDirContent('EP03.srt'), 'lone');
    });

    // 复审 HBK-AUDIT-019：只看「同名」不够——配对按 stem 不分扩展名，旧视频换了容器
    // （EP01.mp4）或字幕带语言标记（EP01.ja.srt）时名字都不撞，配对照样交叉。
    test('stem 相同、扩展名不同的旧视频带着自己的字幕时，新组整组改名', () async {
      await ImportInbox.ensureKindFolders(inbox);
      touch(p.join(inbox.path, 'Video', 'EP01.mp4')).writeAsStringSync('old');
      touch(
        p.join(inbox.path, 'Video', 'EP01.ja.srt'),
      ).writeAsStringSync('old-ja');
      touch(p.join(inbox.path, 'EP01.mkv')).writeAsStringSync('new');
      touch(p.join(inbox.path, 'EP01.srt')).writeAsStringSync('new-srt');

      expect(await adoptAll(), isEmpty);
      expect(videoDirContent('EP01 (2).mkv'), 'new');
      expect(videoDirContent('EP01 (2).srt'), 'new-srt');
      expect(
        File(p.join(inbox.path, 'Video', 'EP01.mkv')).existsSync(),
        isFalse,
        reason: '新视频落在 EP01 上会按 .ja.srt 优先配走旧视频的字幕',
      );
      expect(videoDirContent('EP01.ja.srt'), 'old-ja');
    });

    test('新字幕会配上 stem 相同的旧视频（扩展名不同）时，新组整组改名', () async {
      await ImportInbox.ensureKindFolders(inbox);
      touch(p.join(inbox.path, 'Video', 'EP01.mp4')).writeAsStringSync('old');
      touch(p.join(inbox.path, 'EP01.mkv')).writeAsStringSync('new');
      touch(p.join(inbox.path, 'EP01.ja.ass')).writeAsStringSync('new-ja');

      expect(await adoptAll(), isEmpty);
      expect(videoDirContent('EP01 (2).mkv'), 'new');
      expect(videoDirContent('EP01 (2).ja.ass'), 'new-ja');
      expect(
        File(p.join(inbox.path, 'Video', 'EP01.ja.ass')).existsSync(),
        isFalse,
        reason: '旧视频不能配上新字幕',
      );
    });

    test('只有字幕的组接上已有视频、视频接上孤立字幕：不改名', () async {
      await ImportInbox.ensureKindFolders(inbox);
      touch(p.join(inbox.path, 'Video', 'EP01.mkv')).writeAsStringSync('old');
      touch(
        p.join(inbox.path, 'Video', 'EP02.srt'),
      ).writeAsStringSync('orphan');
      touch(p.join(inbox.path, 'EP01.ja.srt')).writeAsStringSync('add-sub');
      touch(p.join(inbox.path, 'EP02.mkv')).writeAsStringSync('new');

      expect(await adoptAll(), isEmpty);
      expect(videoDirContent('EP01.ja.srt'), 'add-sub');
      expect(videoDirContent('EP02.mkv'), 'new');
      expect(videoDirContent('EP02.srt'), 'orphan');
    });
  });
}
