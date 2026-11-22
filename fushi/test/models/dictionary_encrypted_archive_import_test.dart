// 加密词典包（PR #4143 收尾）：native 词典导入器（fushidicts）只读未加密 zip，加密 zip
// 与 7z / rar 必须先经导入链路唯一的解包点 ArchiveUnpacker 解开（口令对话框在那里），
// 再按整合包同一条路逐本导入。这里走真实 importFromFile → 解包点 → 拆包 / 打包，只把
// 末端逐本的 native 导入换成产物检查。
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/models/dictionary_import_manager.dart';
import 'package:fushi/src/models/dictionary_repository.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';
import 'package:fushi_engine/utils/archive/archive_unpacker.dart';
import 'package:path/path.dart' as p;

const String _password = 'fushi-pw';

/// 每本进入 native 导入的词典：标题 → (zip 内文件集合, forceReplaceExisting)。
typedef _NativeInput = ({Set<String> files, bool force});

class _InspectManager extends DictionaryImportManager {
  _InspectManager({
    required super.dictRepo,
    required super.resourceDirectory,
    required super.archiveUnpacker,
    required this.archivePath,
  }) : super(formats: const <String, DictionaryFormat>{});

  final String archivePath;
  final Map<String, _NativeInput> nativeInputs = <String, _NativeInput>{};

  @override
  Future<void> importFromFile({
    required File file,
    required ValueNotifier<String> progressNotifier,
    required Function() onImportSuccess,
    required bool lowMemoryMode,
    List<File> cssFiles = const <File>[],
    List<Directory> fontDirs = const <Directory>[],
    VoidCallback? onMemoryError,
    bool forceReplaceExisting = false,
    Map<String, String>? sourceOverride,
    Dictionary? replaceTarget,
  }) async {
    if (p.equals(file.path, archivePath)) {
      await super.importFromFile(
        file: file,
        progressNotifier: progressNotifier,
        onImportSuccess: onImportSuccess,
        lowMemoryMode: lowMemoryMode,
        forceReplaceExisting: forceReplaceExisting,
      );
      return;
    }
    final Archive archive = ZipDecoder().decodeBytes(file.readAsBytesSync());
    final ArchiveFile? index = archive.findFile('index.json');
    final String title = index == null
        ? '<no index> ${p.basename(file.path)}'
        : (jsonDecode(utf8.decode(index.content as List<int>))
                  as Map<String, dynamic>)['title']
              as String;
    nativeInputs[title] = (
      files: <String>{
        for (final ArchiveFile entry in archive)
          if (entry.isFile) entry.name.replaceAll(r'\', '/'),
      },
      force: forceReplaceExisting,
    );
  }
}

/// 依次作答的口令来源（null = 取消）。
final class _AnswerPasswords implements ArchivePasswordProvider {
  _AnswerPasswords(this.answers);

  final List<String?> answers;
  int asked = 0;

  @override
  Future<ArchivePasswordAnswer?> ask(ArchivePasswordRequest request) async {
    asked++;
    final String? answer = answers.isEmpty ? null : answers.removeAt(0);
    return answer == null ? null : ArchivePasswordAnswer(answer);
  }

  @override
  Future<void> forget(String fingerprint) async {}

  @override
  Future<void> remember(String fingerprint, String password) async {}

  @override
  Future<String?> remembered(String fingerprint) async => null;
}

String _index(String title) => '{"title":"$title","revision":"1","format":3}';

String _bank(String term) => '[["$term","","","",0,["$term entry"],0,""]]';

typedef _Run = ({
  _InspectManager manager,
  _AnswerPasswords passwords,
  Directory resources,
});

Future<_Run> _setUp(
  Map<String, String> entries, {
  required List<String?> answers,
}) async {
  final Directory scratch = Directory.systemTemp.createTempSync(
    'fushi-dict-encrypted-',
  );
  addTearDown(() => scratch.deleteSync(recursive: true));
  final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
  addTearDown(db.close);
  final DictionaryRepository repo = DictionaryRepository(db);
  addTearDown(repo.dispose);
  final Archive source = Archive();
  for (final MapEntry<String, String> entry in entries.entries) {
    final List<int> bytes = utf8.encode(entry.value);
    source.addFile(ArchiveFile(entry.key, bytes.length, bytes));
  }
  final File archive = File(p.join(scratch.path, 'locked.zip'))
    ..writeAsBytesSync(ZipEncoder(password: _password).encode(source)!);
  final Directory resources = Directory(p.join(scratch.path, 'resources'))
    ..createSync();
  final _AnswerPasswords passwords = _AnswerPasswords(answers);
  return (
    manager: _InspectManager(
      dictRepo: repo,
      resourceDirectory: resources,
      archiveUnpacker: ArchiveUnpacker(passwords: passwords),
      archivePath: archive.path,
    ),
    passwords: passwords,
    resources: resources,
  );
}

Future<void> _import(_InspectManager manager, {bool force = false}) {
  final ValueNotifier<String> progress = ValueNotifier<String>('');
  addTearDown(progress.dispose);
  return manager.importFromFile(
    file: File(manager.archivePath),
    progressNotifier: progress,
    onImportSuccess: () {},
    lowMemoryMode: false,
    forceReplaceExisting: force,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    LocaleSettings.setLocale(AppLocale.en);
    const MethodChannel toast = MethodChannel('PonnamKarthik/fluttertoast');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(toast, (MethodCall _) async => true);
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(toast, null),
    );
  });

  test('加密的单本 Yomitan 包：问口令解开，打成一本交 native，更新语义原样带过去', () async {
    final _Run run = await _setUp(
      <String, String>{
        'index.json': _index('Locked'),
        'term_bank_1.json': _bank('locked'),
      },
      answers: <String?>['wrong', _password],
    );

    await _import(run.manager, force: true);

    expect(run.passwords.asked, 2, reason: '错口令要重问一次');
    expect(run.manager.nativeInputs.keys, <String>['Locked']);
    expect(run.manager.nativeInputs['Locked']!.files, <String>{
      'index.json',
      'term_bank_1.json',
    });
    expect(
      run.manager.nativeInputs['Locked']!.force,
      isTrue,
      reason: '解出来只有一本时，强制重导 / 替换目标这类更新语义必须带给那一本',
    );
    expect(
      Directory(p.join(run.resources.path, 'import_multi_temp')).existsSync(),
      isFalse,
      reason: '解包工作目录在 finally 里清掉',
    );
  });

  test('加密的整合包：解开后逐本导入', () async {
    final _Run run = await _setUp(
      <String, String>{
        'a/index.json': _index('A'),
        'a/term_bank_1.json': _bank('a'),
        'b/index.json': _index('B'),
        'b/term_bank_1.json': _bank('b'),
      },
      answers: <String?>[_password],
    );

    await _import(run.manager);

    expect(run.manager.nativeInputs.keys.toSet(), <String>{'A', 'B'});
    for (final _NativeInput input in run.manager.nativeInputs.values) {
      expect(input.files, <String>{'index.json', 'term_bank_1.json'});
    }
  });

  test('取消口令框：按解包失败抛给调用方，什么都不导入', () async {
    final _Run run = await _setUp(
      <String, String>{
        'index.json': _index('Locked'),
        'term_bank_1.json': _bank('locked'),
      },
      answers: <String?>[null],
    );

    await expectLater(
      _import(run.manager),
      throwsA(
        isA<ArchiveUnpackException>().having(
          (ArchiveUnpackException e) => e.failure,
          'failure',
          ArchiveUnpackFailure.passwordCancelled,
        ),
      ),
    );
    expect(run.manager.nativeInputs, isEmpty);
  });
}
