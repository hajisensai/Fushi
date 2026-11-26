import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/dictionary/dictionary_file_health.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/dictionary_repository.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';
import 'package:path/path.dart' as p;

import '../helpers/test_platform_services.dart';

/// BUG-5462：词典元数据还在、`dictionaryResources/<名>` 下的文件没了（或读不到）时，
/// 装载链路只是静默不装，查词只剩「未找到」。契约：
///  * 判定区分「不在」与「暂时读不到」（资源根列不出来 = 读不到，不当成删除）；
///  * 判定**从不删任何东西**；
///  * 查词空态 / 不全时给出如实的说明。
void _writeDictFiles(String dir, {bool index = true, bool blobs = true}) {
  Directory(dir).createSync(recursive: true);
  if (index) File(p.join(dir, 'index.json')).writeAsStringSync('{}');
  if (blobs) File(p.join(dir, 'blobs.bin')).writeAsBytesSync(<int>[0]);
  File(p.join(dir, 'key.index')).writeAsBytesSync(<int>[0]);
}

Dictionary _dict(String name, int order, {bool hidden = false}) => Dictionary(
  name: name,
  formatKey: 'yomichan',
  order: order,
  type: DictionaryType.term,
  // 两个启动期自愈都标成「已做过」：本测试只看文件状态，不让它们去写库。
  metadata: const <String, String>{
    kDictTypeProbeKey: kDictTypeProbeVersion,
    kDictSourceProbeKey: '1',
  },
  hiddenLanguages: hidden
      ? <String>[JapaneseLanguage.instance.languageCode]
      : const <String>[],
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => LocaleSettings.setLocale(AppLocale.en));
  tearDown(
    () => DictionaryFileHealthMonitor.instance.value =
        DictionaryFileHealth.healthy,
  );

  group('classifyDictionaryFiles', () {
    test('资源根可读：目录不在 / 缺必需文件 = 不在；探测读失败 = 读不到', () {
      expect(
        classifyDictionaryFiles(
          rootReadable: true,
          dirExists: true,
          filesComplete: true,
        ),
        isNull,
      );
      expect(
        classifyDictionaryFiles(
          rootReadable: true,
          dirExists: false,
          filesComplete: false,
        ),
        DictionaryFileIssue.missing,
      );
      expect(
        classifyDictionaryFiles(
          rootReadable: true,
          dirExists: true,
          filesComplete: false,
        ),
        DictionaryFileIssue.missing,
      );
      expect(
        classifyDictionaryFiles(
          rootReadable: true,
          dirExists: true,
          filesComplete: false,
          probeError: 'FileSystemException: Permission denied, errno = 13',
        ),
        DictionaryFileIssue.unreadable,
      );
      expect(
        classifyDictionaryFiles(
          rootReadable: true,
          dirExists: true,
          filesComplete: false,
          probeError: 'directory missing: /x',
        ),
        DictionaryFileIssue.missing,
      );
    });

    test('资源根列不出来（外部存储未挂载 / 没权限）：一律是读不到，不判成不在', () {
      expect(
        classifyDictionaryFiles(
          rootReadable: false,
          dirExists: false,
          filesComplete: false,
        ),
        DictionaryFileIssue.unreadable,
      );
      expect(
        classifyDictionaryFiles(
          rootReadable: false,
          dirExists: true,
          filesComplete: false,
          probeError: 'directory missing: /x',
        ),
        DictionaryFileIssue.unreadable,
      );
    });
  });

  group('磁盘判据', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('dict_health_'));
    tearDown(() {
      try {
        tmp.deleteSync(recursive: true);
      } on FileSystemException {
        // Windows 偶发占用。
      }
    });

    test('必需文件：index.json + 记录文件 + 索引（新旧两种都认）', () async {
      final String full = p.join(tmp.path, 'full');
      _writeDictFiles(full);
      expect(await dictionaryFilesComplete(full), isTrue);
      expect(dictionaryFilesCompleteSync(full), isTrue);

      final String legacy = p.join(tmp.path, 'legacy');
      Directory(legacy).createSync();
      File(p.join(legacy, 'index.json')).writeAsStringSync('{}');
      File(p.join(legacy, 'blobs3.bin')).writeAsBytesSync(<int>[0]);
      File(p.join(legacy, 'hash.table')).writeAsBytesSync(<int>[0]);
      expect(await dictionaryFilesComplete(legacy), isTrue);

      final String noBlobs = p.join(tmp.path, 'noBlobs');
      _writeDictFiles(noBlobs, blobs: false);
      expect(await dictionaryFilesComplete(noBlobs), isFalse);
      expect(dictionaryFilesCompleteSync(noBlobs), isFalse);

      final String empty = p.join(tmp.path, 'empty');
      Directory(empty).createSync();
      expect(await dictionaryFilesComplete(empty), isFalse);
    });

    test('资源根可读性：不存在即不可读', () async {
      expect(await dictionaryResourceRootReadable(tmp), isTrue);
      expect(
        await dictionaryResourceRootReadable(
          Directory(p.join(tmp.path, 'gone')),
        ),
        isFalse,
      );
    });
  });

  group('查词说明', () {
    test('没有影响查词的问题：不说话（隐藏词典的文件问题只在词典管理里标）', () {
      expect(dictionaryLookupFileNotice(DictionaryFileHealth.healthy), isNull);
      expect(
        dictionaryLookupFileNotice(
          const DictionaryFileHealth(
            issues: <String, DictionaryFileIssue>{
              'Hidden': DictionaryFileIssue.missing,
            },
            lookupTermTotal: 2,
          ),
        ),
        isNull,
      );
    });

    test('全部 / 部分 / 只是读不到：各说各的', () {
      expect(
        dictionaryLookupFileNotice(
          const DictionaryFileHealth(
            issues: <String, DictionaryFileIssue>{
              'A': DictionaryFileIssue.missing,
              'B': DictionaryFileIssue.unreadable,
            },
            lookupTermTotal: 2,
            lookupTermMissing: 1,
            lookupTermUnreadable: 1,
          ),
        ),
        t.dictionary_files_lookup_all_missing,
      );
      expect(
        dictionaryLookupFileNotice(
          const DictionaryFileHealth(
            issues: <String, DictionaryFileIssue>{
              'A': DictionaryFileIssue.unreadable,
            },
            lookupTermTotal: 1,
            lookupTermUnreadable: 1,
          ),
        ),
        t.dictionary_files_lookup_all_unreadable,
      );
      expect(
        dictionaryLookupFileNotice(
          const DictionaryFileHealth(
            issues: <String, DictionaryFileIssue>{
              'A': DictionaryFileIssue.missing,
              'B': DictionaryFileIssue.missing,
            },
            lookupTermTotal: 5,
            lookupTermMissing: 2,
          ),
        ),
        t.dictionary_files_lookup_some_missing(n: 2),
      );
      expect(
        dictionaryLookupFileNotice(
          const DictionaryFileHealth(
            issues: <String, DictionaryFileIssue>{
              'A': DictionaryFileIssue.unreadable,
            },
            lookupTermTotal: 5,
            lookupTermUnreadable: 1,
          ),
        ),
        t.dictionary_files_lookup_some_unreadable(n: 1),
      );
    });

    test('诊断文本按名字排序、逐字稳定（取证环按文本判变化）', () {
      const DictionaryFileHealth a = DictionaryFileHealth(
        issues: <String, DictionaryFileIssue>{
          'Zeta': DictionaryFileIssue.missing,
          'Alpha': DictionaryFileIssue.missing,
        },
        lookupTermTotal: 2,
        lookupTermMissing: 2,
      );
      const DictionaryFileHealth b = DictionaryFileHealth(
        issues: <String, DictionaryFileIssue>{
          'Alpha': DictionaryFileIssue.missing,
          'Zeta': DictionaryFileIssue.missing,
        },
        lookupTermTotal: 2,
        lookupTermMissing: 2,
      );
      expect(a, b);
      expect(a.describe(resourceRoot: '/r'), b.describe(resourceRoot: '/r'));
      expect(
        a.describe(resourceRoot: '/r'),
        contains('missing(2): Alpha, Zeta'),
      );
    });
  });

  group('AppModel 装载路径（真异步排期：exists + 物化探测 + 分桶）', () {
    late FushiDatabase db;
    late DictionaryRepository dictRepo;
    late Directory tmp;
    late AppModel app;

    Future<void> pumpApp(Directory resourceRoot) async {
      final PreferencesRepository prefsRepo = PreferencesRepository(db);
      await prefsRepo.loadFromDb();
      app = AppModel(testPlatformServices())
        ..wireLocalAudioForTesting(prefsRepo: prefsRepo, databaseDirectory: tmp)
        ..wireDatabaseForTesting(db, dictionaryRepository: dictRepo)
        ..wireDictionaryResourceDirectoryForTesting(resourceRoot);
      FushiDicts.dropPendingForTest();
    }

    setUp(() async {
      tmp = Directory.systemTemp.createTempSync('dict_health_app_');
      db = FushiDatabase.forTesting(NativeDatabase.memory());
      dictRepo = DictionaryRepository(db);
      await dictRepo.loadFromDb();
      await dictRepo.persistDictionary(_dict('JP', 0));
      await dictRepo.persistDictionary(_dict('GONE', 1));
      await dictRepo.persistDictionary(_dict('HALF', 2));
      await dictRepo.persistDictionary(_dict('OFF', 3, hidden: true));
      await dictRepo.loadFromDb();
      final String? prevCacheDir = FushiDicts.unionFilterCacheDirectory;
      FushiDicts.unionFilterCacheDirectory = p.join(tmp.path, 'cache');
      addTearDown(() {
        FushiDicts.dropPendingForTest();
        FushiDicts.unionFilterCacheDirectory = prevCacheDir;
      });
    });

    tearDown(() async {
      dictRepo.dispose();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      await db.close();
      try {
        tmp.deleteSync(recursive: true);
      } on FileSystemException {
        // Windows 偶发占用。
      }
    });

    test('不在 / 缺文件被标出，隐藏词典也标但不算进查词影响；什么都不删', () async {
      final Directory root = Directory(p.join(tmp.path, 'dicts'));
      _writeDictFiles(p.join(root.path, 'JP'));
      _writeDictFiles(p.join(root.path, 'HALF'), blobs: false);
      await pumpApp(root);

      await app.debugRescheduleDictsForLookupViewForTest();
      final DictionaryFileHealth health =
          DictionaryFileHealthMonitor.instance.value;
      expect(health.issues, <String, DictionaryFileIssue>{
        'GONE': DictionaryFileIssue.missing,
        'HALF': DictionaryFileIssue.missing,
        'OFF': DictionaryFileIssue.missing,
      });
      expect(health.lookupTermTotal, 3);
      expect(health.lookupTermMissing, 2);
      expect(health.affectsAllLookups, isFalse);
      expect(
        dictionaryLookupFileNotice(health),
        t.dictionary_files_lookup_some_missing(n: 2),
      );
      // 只判定、不删：元数据行与磁盘上的残缺目录都原样还在。
      expect(dictRepo.dictionaries.map((Dictionary d) => d.name), <String>[
        'JP',
        'GONE',
        'HALF',
        'OFF',
      ]);
      expect(Directory(p.join(root.path, 'HALF')).existsSync(), isTrue);

      // 文件回来（重新导入落盘）后下一次排期撤掉标记。
      _writeDictFiles(p.join(root.path, 'GONE'));
      _writeDictFiles(p.join(root.path, 'HALF'));
      _writeDictFiles(p.join(root.path, 'OFF'));
      await app.debugRescheduleDictsForLookupViewForTest();
      expect(DictionaryFileHealthMonitor.instance.value.isHealthy, isTrue);
    });

    test('资源根整个读不到：全部判「暂时读不到」，查词说明不说「不在」', () async {
      await pumpApp(Directory(p.join(tmp.path, 'unmounted')));
      await app.debugRescheduleDictsForLookupViewForTest();
      final DictionaryFileHealth health =
          DictionaryFileHealthMonitor.instance.value;
      expect(health.issues.values.toSet(), <DictionaryFileIssue>{
        DictionaryFileIssue.unreadable,
      });
      expect(health.issues, hasLength(4));
      expect(health.affectsAllLookups, isTrue);
      expect(
        dictionaryLookupFileNotice(health),
        t.dictionary_files_lookup_all_unreadable,
      );
      expect(dictRepo.dictionaries, hasLength(4), reason: '读不到不等于删除');
    });
  });

  test('源码守卫：三处查词空态与首页词典页都读同一份文件状态说明', () {
    for (final String file in <String>[
      'lib/src/pages/implementations/dictionary_popup_layer.dart',
      'lib/src/pages/implementations/popup_settings_injection.dart',
      'lib/src/pages/implementations/home_dictionary_page.dart',
    ]) {
      expect(
        File(file).readAsStringSync(),
        contains('dictionaryLookupFileNotice('),
        reason: '$file 的「未找到」要说明词典文件不在 / 读不到',
      );
    }
  });
}
