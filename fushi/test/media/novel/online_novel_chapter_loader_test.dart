import 'dart:async';
import 'dart:io';

import 'package:fushi/src/media/novel/online/online_novel_chapter_loader.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// 每一章的取章由测试手动放行，用来钉排队顺序。
class _GatedLoader extends SerialOnlineNovelChapterLoader {
  _GatedLoader(this.extractDir, {this.limit});

  @override
  final String extractDir;
  final int? limit;

  @override
  int? get chapterLimit => limit;

  /// 开始取的章，按开始顺序。
  final List<int> started = <int>[];
  final Map<int, Completer<OnlineNovelChapterLoaded?>> _gates =
      <int, Completer<OnlineNovelChapterLoaded?>>{};

  Completer<OnlineNovelChapterLoaded?> _gate(int index) =>
      _gates.putIfAbsent(index, () => Completer<OnlineNovelChapterLoaded?>());

  void release(int index) => _gate(
    index,
  ).complete(OnlineNovelChapterLoaded(index: index, characters: index * 10));

  void fail(int index) => _gate(index).completeError(StateError('boom $index'));

  @override
  Future<OnlineNovelChapterLoaded?> loadChapter(int index) {
    started.add(index);
    return _gate(index).future;
  }

  Future<OnlineNovelChapterLoaded?> foreground(int index) =>
      ensureChapter(index);

  Future<OnlineNovelChapterLoaded?> prefetch(int index) =>
      ensureChapter(index, background: true);

  @override
  Future<OnlineNovelChapterLoaded?> ensureLoaded(String filePath) {
    final int? index = chapterIndexForFile(filePath);
    if (index == null) return Future<OnlineNovelChapterLoaded?>.value();
    return ensureChapter(index);
  }

  Future<void> write(File target, List<int> bytes) =>
      writeAtomically(target, bytes);
}

/// 让已排上的微任务 / 事件跑完（队列推进到下一处真正的等待）。
Future<void> _settle() => Future<void>.delayed(Duration.zero);

void main() {
  late Directory root;

  setUp(() {
    root = Directory.systemTemp.createTempSync('online_novel_loader_');
  });

  tearDown(() {
    root.deleteSync(recursive: true);
  });

  String chapterFile(int index) =>
      p.join(root.path, 'OEBPS', 'chapter-${index + 1}.xhtml');

  test('章节文件 ↔ 章号：只认 OEBPS/chapter-<n>.xhtml，越过章数上限的不认', () {
    final _GatedLoader bounded = _GatedLoader(root.path, limit: 3);
    expect(bounded.chapterIndexForFile(chapterFile(0)), 0);
    expect(bounded.chapterIndexForFile(chapterFile(2)), 2);
    expect(bounded.chapterIndexForFile(chapterFile(3)), isNull);
    expect(
      bounded.chapterIndexForFile(p.join(root.path, 'OEBPS', 'nav.xhtml')),
      isNull,
    );
    expect(
      bounded.chapterIndexForFile(
        p.join(root.path, 'OEBPS', 'chapter-0.xhtml'),
      ),
      isNull,
    );
    expect(
      bounded.chapterIndexForFile(
        p.join(root.path, 'elsewhere', 'chapter-1.xhtml'),
      ),
      isNull,
    );
    // 不设上限（网页小说：末尾的「下一章」占位在快照之外）。
    expect(_GatedLoader(root.path).chapterIndexForFile(chapterFile(40)), 40);
  });

  test('同一章并发只取一次；不同章按到达顺序串行', () async {
    final _GatedLoader loader = _GatedLoader(root.path);
    final Future<OnlineNovelChapterLoaded?> a = loader.foreground(0);
    final Future<OnlineNovelChapterLoaded?> again = loader.foreground(0);
    final Future<OnlineNovelChapterLoaded?> b = loader.foreground(1);
    await _settle();
    expect(loader.started, <int>[0], reason: '第 0 章没取完，第 1 章不开始');

    loader.release(0);
    expect((await a)?.characters, 0);
    expect(identical(await a, await again), isTrue);
    await _settle();
    expect(loader.started, <int>[0, 1]);

    loader.release(1);
    expect((await b)?.index, 1);
    await loader.whenIdle();
    // 取完的章不留在单飞表里：再请求会再问一次实现（由它判定是否已是正文）。
    final Future<OnlineNovelChapterLoaded?> third = loader.foreground(0);
    await _settle();
    expect(loader.started, <int>[0, 1, 0]);
    expect(await third, isNotNull);
  });

  test('一章取章失败只让等它的调用方失败，队列继续往下取', () async {
    final _GatedLoader loader = _GatedLoader(root.path);
    final Future<OnlineNovelChapterLoaded?> a = loader.foreground(0);
    final Future<OnlineNovelChapterLoaded?> b = loader.foreground(1);
    await _settle();
    loader.fail(0);
    await expectLater(a, throwsA(isA<StateError>()));
    await _settle();
    expect(loader.started, <int>[0, 1]);
    loader.release(1);
    expect(await b, isNotNull);
  });

  test('还没开始的后台预取给前台请求让位；已经开始的预取照常取完', () async {
    final _GatedLoader loader = _GatedLoader(root.path);
    // 第 5 章的预取已经开取；第 6、7 章的预取还在排队。
    final Future<OnlineNovelChapterLoaded?> running = loader.prefetch(5);
    final Future<OnlineNovelChapterLoaded?> queuedA = loader.prefetch(6);
    final Future<OnlineNovelChapterLoaded?> queuedB = loader.prefetch(7);
    await _settle();
    expect(loader.started, <int>[5]);

    // 用户从目录跳到第 20 章，又立刻跳到第 30 章。
    final Future<OnlineNovelChapterLoaded?> jump = loader.foreground(20);
    final Future<OnlineNovelChapterLoaded?> jumpAgain = loader.foreground(30);
    await _settle();
    expect(loader.started, <int>[5], reason: '在取的预取不被打断，也不并发取');

    loader.release(5);
    expect(await running, isNotNull, reason: '已开始的预取结果照常交付');
    await _settle();
    expect(loader.started, <int>[5, 20], reason: '前台请求排到排队预取前面');

    loader.release(20);
    expect((await jump)?.index, 20);
    await _settle();
    expect(loader.started, <int>[5, 20, 30], reason: '前台之间仍按到达顺序');

    loader.release(30);
    expect((await jumpAgain)?.index, 30);
    await _settle();
    expect(loader.started, <int>[5, 20, 30, 6], reason: '前台清空后预取按原顺序继续');
    loader.release(6);
    loader.release(7);
    expect((await queuedA)?.index, 6);
    expect((await queuedB)?.index, 7);
    await loader.whenIdle();
    expect(loader.started, <int>[5, 20, 30, 6, 7]);
  });

  test('前台请求到一章正在排队的预取：共用那一次，并把它提到前台顺位', () async {
    final _GatedLoader loader = _GatedLoader(root.path);
    final Future<OnlineNovelChapterLoaded?> running = loader.foreground(0);
    final Future<OnlineNovelChapterLoaded?> queuedA = loader.prefetch(1);
    final Future<OnlineNovelChapterLoaded?> queuedB = loader.prefetch(2);
    await _settle();

    // 用户翻到第 2 章（它的预取排在第 1 章的预取后面）。
    final Future<OnlineNovelChapterLoaded?> wanted = loader.foreground(2);
    loader.release(0);
    await running;
    await _settle();
    expect(loader.started, <int>[0, 2]);

    loader.release(2);
    expect(identical(await wanted, await queuedB), isTrue);
    loader.release(1);
    expect(await queuedA, isNotNull);
    await loader.whenIdle();
    expect(loader.started, <int>[0, 2, 1]);
  });

  test('dispose：还没开始的取章不再发起，在取的那一章照常取完，之后的请求一律 null', () async {
    final _GatedLoader loader = _GatedLoader(root.path);
    final Future<OnlineNovelChapterLoaded?> running = loader.foreground(0);
    final Future<OnlineNovelChapterLoaded?> queuedPrefetch = loader.prefetch(1);
    final Future<OnlineNovelChapterLoaded?> queuedForeground = loader
        .foreground(2);
    await _settle();
    expect(loader.started, <int>[0]);

    loader.dispose();
    expect(await queuedPrefetch, isNull);
    expect(await queuedForeground, isNull);

    loader.release(0);
    expect(await running, isNotNull, reason: '在取的那一章不被丢弃');
    await loader.whenIdle();
    expect(loader.started, <int>[0], reason: '排队的两章从未开取');

    expect(await loader.foreground(3), isNull);
    expect(await loader.ensureLoaded(chapterFile(4)), isNull);
    await loader.whenIdle();
    expect(loader.started, <int>[0]);
  });

  test('原子写：两个加载器实例同时写同一个文件不互踩，不留临时文件', () async {
    final _GatedLoader first = _GatedLoader(root.path);
    final _GatedLoader second = _GatedLoader(root.path);
    final File target = File(chapterFile(0));
    final List<int> a = List<int>.filled(256 * 1024, 0x41);
    final List<int> b = List<int>.filled(256 * 1024, 0x42);

    await Future.wait(<Future<void>>[
      first.write(target, a),
      second.write(target, b),
    ]);

    final List<int> written = target.readAsBytesSync();
    expect(written.length, a.length);
    expect(written.toSet().length, 1, reason: '读到的是其中一次完整的写入，不是两次的拼接');
    expect(
      target.parent.listSync().map((FileSystemEntity e) => p.basename(e.path)),
      <String>['chapter-1.xhtml'],
    );
  });
}
