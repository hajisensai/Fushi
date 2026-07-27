import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_anki/hibiki_anki.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// `AnkiConnectRepository.runMediaDedup` 的**编排**测试。
///
/// 纯函数层已在 `anki_media_dedup_test.dart` 覆盖；这里测真正会删文件的那条
/// 路径：什么情况下删、什么情况下坚决不删、删完卡片还取不取得到媒体、失败
/// 路径有没有把 Anki 端改脏。
///
/// 手法：`AnkiConnectService` 的网络方法全部可覆写，且默认 HTTP client 是
/// **首次请求时**才构造的，所以子类覆写掉所有用到的方法就等于一个不触网的
/// 假 Anki；媒体目录用真的临时目录 + 真的文件，删除是真删。
class _FakeAnkiConnectService extends AnkiConnectService {
  _FakeAnkiConnectService({
    required this.mediaDirPath,
    required this.notes,
    this.templates = const <String, List<AnkiCardTemplate>>{},
    Map<String, String>? styling,
    this.onFindNotes,
  }) : styling = styling ?? <String, String>{};

  final String mediaDirPath;

  /// noteId → 字段表（真会被 [updateNoteFields] 改写）。
  final Map<int, Map<String, String>> notes;
  final Map<String, List<AnkiCardTemplate>> templates;
  final Map<String, String> styling;

  /// 在第一次 findNotes 时插一脚（用来模拟「扫描完到删除前文件被改动」）。
  final Future<void> Function()? onFindNotes;

  final List<String> deleted = <String>[];
  final List<String> stylingWrites = <String>[];
  final List<String> templateWrites = <String>[];
  bool _findNotesHookFired = false;

  late final Map<String, List<AnkiCardTemplate>> _templates =
      Map<String, List<AnkiCardTemplate>>.from(templates);

  @override
  Future<String> getMediaDirPath() async => mediaDirPath;

  @override
  Future<List<String>> getModelNames() async =>
      <String>{..._templates.keys, ...styling.keys}.toList()..sort();

  @override
  Future<List<AnkiCardTemplate>> modelTemplates(String modelName) async =>
      _templates[modelName] ?? const <AnkiCardTemplate>[];

  @override
  Future<String> modelStyling(String modelName) async =>
      styling[modelName] ?? '';

  /// 去重只用 `findNotes("<文件名>")`：朴素子串检索，和真 Anki 一样**不做**
  /// 文件名边界判断——正是这一点让「命中但改不动」的保守分支有意义。
  @override
  Future<List<int>> findNotesByQuery(String query) async {
    if (!_findNotesHookFired && onFindNotes != null) {
      _findNotesHookFired = true;
      await onFindNotes!();
    }
    final String needle = query.replaceAll('"', '');
    return notes.entries
        .where((MapEntry<int, Map<String, String>> e) =>
            e.value.values.any((String v) => v.contains(needle)))
        .map((MapEntry<int, Map<String, String>> e) => e.key)
        .toList()
      ..sort();
  }

  @override
  Future<Map<String, String>?> notesInfo(int noteId) async => notes[noteId];

  @override
  Future<void> updateNoteFields(int noteId, Map<String, String> fields) async {
    notes[noteId]!.addAll(fields);
  }

  @override
  Future<void> updateModelTemplates(
      String modelName, List<AnkiCardTemplate> tmpls) async {
    _templates[modelName] = tmpls;
    templateWrites.add(modelName);
  }

  @override
  Future<void> updateModelStyling(String modelName, String css) async {
    styling[modelName] = css;
    stylingWrites.add(modelName);
  }

  @override
  Future<void> deleteMediaFile(String filename) async {
    deleted.add(filename);
    final File f = File('$mediaDirPath${Platform.pathSeparator}$filename');
    if (f.existsSync()) f.deleteSync();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory mediaDir;

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    mediaDir = Directory.systemTemp.createTempSync('hibiki_dedup_test');
  });

  tearDown(() {
    if (mediaDir.existsSync()) mediaDir.deleteSync(recursive: true);
  });

  void writeMedia(String name, List<int> bytes) {
    File('${mediaDir.path}${Platform.pathSeparator}$name')
        .writeAsBytesSync(Uint8List.fromList(bytes));
  }

  bool mediaExists(String name) =>
      File('${mediaDir.path}${Platform.pathSeparator}$name').existsSync();

  /// 「卡片仍能取到媒体」的硬断言：把改写后的笔记字段 + 卡模板 + styling 全
  /// 拼起来，凡是还引用着 [allNames] 里某个文件名的，那个文件必须真的还在
  /// 媒体目录里。出现问号方框/放不出声就是这条挂掉。
  void expectEveryReferenceResolves(
    _FakeAnkiConnectService service,
    Iterable<String> allNames,
  ) {
    final StringBuffer buf = StringBuffer();
    for (final Map<String, String> fields in service.notes.values) {
      fields.values.forEach(buf.writeln);
    }
    for (final List<AnkiCardTemplate> tmpls in service._templates.values) {
      for (final AnkiCardTemplate tpl in tmpls) {
        buf
          ..writeln(tpl.front)
          ..writeln(tpl.back);
      }
    }
    service.styling.values.forEach(buf.writeln);
    final String all = buf.toString();
    for (final String name in allNames) {
      if (!textReferencesMediaName(all, name)) continue;
      expect(mediaExists(name), isTrue,
          reason: '仍被引用的媒体 $name 不在媒体目录里（卡片会显示问号方框）');
    }
  }

  test('真删：引用改指保留份、副本被删、每个引用仍能取到媒体', () async {
    writeMedia('a.jpg', <int>[1, 2, 3]);
    writeMedia('bbbb.jpg', <int>[1, 2, 3]);
    writeMedia('other.jpg', <int>[9, 9, 9]);
    final _FakeAnkiConnectService service = _FakeAnkiConnectService(
      mediaDirPath: mediaDir.path,
      notes: <int, Map<String, String>>{
        1: <String, String>{'Front': '<img src="bbbb.jpg">'},
        2: <String, String>{'Front': '<img src="other.jpg">'},
      },
    );
    final AnkiConnectRepository repo = AnkiConnectRepository(service: service);

    final AnkiMediaDedupReport? report = await repo.runMediaDedup();

    expect(report, isNotNull);
    expect(report!.deletions, hasLength(1));
    expect(report.deletions.single.filename, 'bbbb.jpg');
    expect(report.deletions.single.canonical, 'a.jpg');
    expect(report.deletions.single.bytes, 3);
    expect(report.bytesSaved, 3);
    expect(report.skipped, 0);
    expect(service.deleted, <String>['bbbb.jpg']);
    expect(mediaExists('bbbb.jpg'), isFalse);
    expect(mediaExists('a.jpg'), isTrue);
    expect(service.notes[1]!['Front'], '<img src="a.jpg">');
    expect(service.notes[2]!['Front'], '<img src="other.jpg">');
    expectEveryReferenceResolves(
        service, <String>['a.jpg', 'bbbb.jpg', 'other.jpg']);
  });

  test('大小相同但字节不同 → 不成组、绝不删', () async {
    writeMedia('a.jpg', <int>[1, 2, 3]);
    writeMedia('b.jpg', <int>[1, 2, 4]);
    final _FakeAnkiConnectService service = _FakeAnkiConnectService(
      mediaDirPath: mediaDir.path,
      notes: <int, Map<String, String>>{
        1: <String, String>{'Front': '<img src="a.jpg"><img src="b.jpg">'},
      },
    );
    final AnkiConnectRepository repo = AnkiConnectRepository(service: service);

    final AnkiMediaDedupReport? report = await repo.runMediaDedup();

    expect(report!.groupCount, 0);
    expect(report.deletions, isEmpty);
    expect(service.deleted, isEmpty);
    expect(mediaExists('a.jpg'), isTrue);
    expect(mediaExists('b.jpg'), isTrue);
    expectEveryReferenceResolves(service, <String>['a.jpg', 'b.jpg']);
  });

  test('计划之后、删除之前副本被改动 → 逐字节复核挡住删除', () async {
    writeMedia('a.jpg', <int>[1, 2, 3]);
    writeMedia('bbbb.jpg', <int>[1, 2, 3]);
    final _FakeAnkiConnectService service = _FakeAnkiConnectService(
      mediaDirPath: mediaDir.path,
      notes: <int, Map<String, String>>{
        1: <String, String>{'Front': '<img src="bbbb.jpg">'},
      },
      // 哈希已经算完，此刻把副本内容换掉：只有删除前的 memcmp 能发现。
      onFindNotes: () async => writeMedia('bbbb.jpg', <int>[7, 7, 7]),
    );
    final AnkiConnectRepository repo = AnkiConnectRepository(service: service);

    final AnkiMediaDedupReport? report = await repo.runMediaDedup();

    expect(report!.deletions, isEmpty);
    expect(report.skipped, 1);
    expect(service.deleted, isEmpty);
    expect(mediaExists('bbbb.jpg'), isTrue);
    // 笔记也没被改写（判定阶段就拦下了，一个字节都没写）。
    expect(service.notes[1]!['Front'], '<img src="bbbb.jpg">');
  });

  test('必修①：媒体文件内部的 url() 引用挡住删除（不静默删掉在用字体）', () async {
    // `_x.css` 里的 `url(font.woff2)` 既不在笔记字段、也不在卡模板/styling
    // 里——只扫那三处会判定「无引用」，把仍在用的字体删掉。
    writeMedia('_font.woff2', <int>[5, 5, 5, 5]);
    writeMedia('font.woff2', <int>[5, 5, 5, 5]);
    File('${mediaDir.path}${Platform.pathSeparator}_x.css')
        .writeAsStringSync('@font-face { src: url(font.woff2); }');
    final _FakeAnkiConnectService service = _FakeAnkiConnectService(
      mediaDirPath: mediaDir.path,
      notes: <int, Map<String, String>>{},
    );
    final AnkiConnectRepository repo = AnkiConnectRepository(service: service);

    final AnkiMediaDedupReport? report = await repo.runMediaDedup();

    // 组是成立的（字节确实相同），但 `_font.woff2` 是规范名、`font.woff2`
    // 还被 CSS 引用着 → 保守不删。
    expect(report!.groupCount, 1);
    expect(report.deletions, isEmpty);
    expect(report.skipped, 1);
    expect(service.deleted, isEmpty);
    expect(mediaExists('font.woff2'), isTrue);
    expect(mediaExists('_font.woff2'), isTrue);
  });

  test('必修②：跳过删除时模板/styling 一个字都不写，Lapis 指纹不漂', () async {
    writeMedia('a.jpg', <int>[1, 2, 3]);
    writeMedia('bbbb.jpg', <int>[1, 2, 3]);
    const String css = 'body { background: url(bbbb.jpg); }';
    final _FakeAnkiConnectService service = _FakeAnkiConnectService(
      mediaDirPath: mediaDir.path,
      // 检索命中却改不动（`xbbbb.jpg` 是更长的名字，边界安全改写不碰它）：
      // 引用清不干净 → 整份副本不删。
      notes: <int, Map<String, String>>{
        1: <String, String>{'Front': '<img src="xbbbb.jpg">'},
      },
      styling: <String, String>{LapisNoteType.modelName: css},
    );
    final AnkiConnectRepository repo = AnkiConnectRepository(service: service);
    final String shaBefore = lapisCssSha256(css);
    await repo.updateSettings(
        (AnkiSettings s) => s.copyWith(lapisAppliedCssSha: shaBefore));

    final AnkiMediaDedupReport? report = await repo.runMediaDedup();

    expect(report!.deletions, isEmpty);
    expect(report.skipped, 1);
    expect(service.stylingWrites, isEmpty);
    expect(service.templateWrites, isEmpty);
    expect(service.styling[LapisNoteType.modelName], css);
    // 指纹仍与 Anki 侧实际 CSS 一致 → 下次启动自动迁移照常判定，不会因为
    // 一次失败的去重而永久停手。
    final AnkiSettings after = await repo.loadSettings();
    expect(after.lapisAppliedCssSha, shaBefore);
    expect(lapisCssSha256(service.styling[LapisNoteType.modelName]!),
        after.lapisAppliedCssSha);
  });

  test('必修②：styling 真被改写时指纹跟着对齐（自动迁移不退化成 foreignEdit）', () async {
    writeMedia('a.jpg', <int>[1, 2, 3]);
    writeMedia('bbbb.jpg', <int>[1, 2, 3]);
    const String css = 'body { background: url(bbbb.jpg); }';
    final _FakeAnkiConnectService service = _FakeAnkiConnectService(
      mediaDirPath: mediaDir.path,
      notes: <int, Map<String, String>>{},
      styling: <String, String>{LapisNoteType.modelName: css},
    );
    final AnkiConnectRepository repo = AnkiConnectRepository(service: service);
    await repo.updateSettings((AnkiSettings s) =>
        s.copyWith(lapisAppliedCssSha: lapisCssSha256(css)));

    final AnkiMediaDedupReport? report = await repo.runMediaDedup();

    expect(report!.deletions, hasLength(1));
    expect(service.styling[LapisNoteType.modelName],
        'body { background: url(a.jpg); }');
    final AnkiSettings after = await repo.loadSettings();
    expect(after.lapisAppliedCssSha,
        lapisCssSha256(service.styling[LapisNoteType.modelName]!));
    expectEveryReferenceResolves(service, <String>['a.jpg', 'bbbb.jpg']);
  });

  test('必修②：本就是用户手改（指纹对不上）时不伪造指纹', () async {
    writeMedia('a.jpg', <int>[1, 2, 3]);
    writeMedia('bbbb.jpg', <int>[1, 2, 3]);
    final _FakeAnkiConnectService service = _FakeAnkiConnectService(
      mediaDirPath: mediaDir.path,
      notes: <int, Map<String, String>>{},
      styling: <String, String>{
        LapisNoteType.modelName: 'body { background: url(bbbb.jpg); }',
      },
    );
    final AnkiConnectRepository repo = AnkiConnectRepository(service: service);
    await repo.updateSettings(
        (AnkiSettings s) => s.copyWith(lapisAppliedCssSha: 'stale-sha'));

    await repo.runMediaDedup();

    final AnkiSettings after = await repo.loadSettings();
    expect(after.lapisAppliedCssSha, 'stale-sha');
  });

  test('干跑：一个文件/字段都不动，但给出完整删除清单', () async {
    writeMedia('a.jpg', <int>[1, 2, 3]);
    writeMedia('bbbb.jpg', <int>[1, 2, 3]);
    final _FakeAnkiConnectService service = _FakeAnkiConnectService(
      mediaDirPath: mediaDir.path,
      notes: <int, Map<String, String>>{
        1: <String, String>{'Front': '<img src="bbbb.jpg">'},
      },
    );
    final AnkiConnectRepository repo = AnkiConnectRepository(service: service);

    final AnkiMediaDedupReport? report = await repo.runMediaDedup(dryRun: true);

    expect(report!.dryRun, isTrue);
    expect(report.deletions, hasLength(1));
    expect(report.deletions.single.filename, 'bbbb.jpg');
    expect(report.deletions.single.canonical, 'a.jpg');
    expect(report.deletions.single.bytes, 3);
    expect(service.deleted, isEmpty);
    expect(service.stylingWrites, isEmpty);
    expect(service.templateWrites, isEmpty);
    expect(mediaExists('bbbb.jpg'), isTrue);
    expect(service.notes[1]!['Front'], '<img src="bbbb.jpg">');
  });

  test('媒体目录本机不存在（AnkiConnect 在远程） → 返回 null，不盲扫', () async {
    final Directory gone = Directory.systemTemp.createTempSync('hibiki_gone');
    gone.deleteSync();
    final _FakeAnkiConnectService service = _FakeAnkiConnectService(
      mediaDirPath: gone.path,
      notes: <int, Map<String, String>>{},
    );
    final AnkiConnectRepository repo = AnkiConnectRepository(service: service);

    expect(await repo.runMediaDedup(), isNull);
  });

  test('卡模板里的引用也改指保留份，改完仍取得到媒体', () async {
    writeMedia('_lib.js', <int>[8, 8]);
    writeMedia('lib.js', <int>[8, 8]);
    final _FakeAnkiConnectService service = _FakeAnkiConnectService(
      mediaDirPath: mediaDir.path,
      notes: <int, Map<String, String>>{},
      templates: <String, List<AnkiCardTemplate>>{
        'Basic': <AnkiCardTemplate>[
          const AnkiCardTemplate(
            name: 'Card 1',
            front: '<script src="lib.js"></script>',
            back: '{{FrontSide}}',
          ),
        ],
      },
    );
    final AnkiConnectRepository repo = AnkiConnectRepository(service: service);

    final AnkiMediaDedupReport? report = await repo.runMediaDedup();

    expect(report!.deletions.single.filename, 'lib.js');
    expect(report.modelsRewritten, 1);
    expect(service._templates['Basic']!.single.front,
        '<script src="_lib.js"></script>');
    expect(mediaExists('lib.js'), isFalse);
    expectEveryReferenceResolves(service, <String>['_lib.js', 'lib.js']);
  });

  test('journal 记下改写前的原值与删除条目（出事能还原）', () async {
    writeMedia('a.jpg', <int>[1, 2, 3]);
    writeMedia('bbbb.jpg', <int>[1, 2, 3]);
    final _FakeAnkiConnectService service = _FakeAnkiConnectService(
      mediaDirPath: mediaDir.path,
      notes: <int, Map<String, String>>{
        1: <String, String>{'Front': '<img src="bbbb.jpg">'},
      },
    );
    final AnkiConnectRepository repo = AnkiConnectRepository(service: service);
    final List<Map<String, dynamic>> journal = <Map<String, dynamic>>[];

    await repo.runMediaDedup(
        onJournal: (Map<String, dynamic> e) async => journal.add(e));

    final Map<String, dynamic> noteEntry = journal
        .firstWhere((Map<String, dynamic> e) => e['type'] == 'noteFields');
    expect(noteEntry['noteId'], 1);
    expect(
        noteEntry['before'], <String, String>{'Front': '<img src="bbbb.jpg">'});
    final Map<String, dynamic> deleteEntry =
        journal.firstWhere((Map<String, dynamic> e) => e['type'] == 'delete');
    expect(deleteEntry['filename'], 'bbbb.jpg');
    expect(deleteEntry['canonical'], 'a.jpg');
    expect(deleteEntry['bytes'], 3);
    // journal 必须在真改之前落：删除条目排在改写条目之后、且都在 journal 里。
    expect(journal.indexOf(noteEntry), lessThan(journal.indexOf(deleteEntry)));
  });
}
