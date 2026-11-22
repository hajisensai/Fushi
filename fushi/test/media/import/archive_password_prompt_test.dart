// 加密归档口令来源（app 侧）：对话框交互、错口令提示、「记住密码」与安全存储的键。
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/import/archive_password_prompt.dart';
import 'package:fushi_engine/utils/archive/archive_passwords.dart';

final class _MemoryVault implements ArchivePasswordVault {
  final Map<String, String> values = <String, String>{};

  @override
  Future<void> delete(String key) async => values.remove(key);

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;

  @override
  Future<int> deleteWithPrefix(String prefix) async {
    final List<String> hit = values.keys
        .where((String key) => key.startsWith(prefix))
        .toList();
    hit.forEach(values.remove);
    return hit.length;
  }
}

final class _UnreadableVault extends _MemoryVault {
  @override
  Future<int> deleteWithPrefix(String prefix) =>
      Future<int>.error(StateError('no keyring'));
}

const String _fp =
    '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';

void main() {
  Future<BuildContext> pumpHost(WidgetTester tester) async {
    tester.view.physicalSize = const Size(420, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    late BuildContext hostContext;
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(useMaterial3: true),
        home: Scaffold(
          body: Builder(
            builder: (BuildContext context) {
              hostContext = context;
              return const SizedBox.expand();
            },
          ),
        ),
      ),
    );
    return hostContext;
  }

  testWidgets('空口令不能提交；输入后 Enter 提交并带「记住」', (WidgetTester tester) async {
    final BuildContext context = await pumpHost(tester);
    final Future<ArchivePasswordAnswer?> result = showArchivePasswordDialog(
      context: context,
      request: const ArchivePasswordRequest(
        archivePath: '/dl/秘密.7z',
        fingerprint: _fp,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('秘密.7z'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('archive-password-notice')),
      findsNothing,
    );
    final Finder unlock = find.text(t.archive_password_unlock);
    expect(unlock, findsOneWidget);
    // 空口令：确认键不响应。
    await tester.tap(unlock);
    await tester.pumpAndSettle();
    expect(find.byType(ArchivePasswordDialog), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'fushi-pw');
    await tester.tap(find.text(t.archive_password_remember));
    await tester.pump();
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    final ArchivePasswordAnswer? answer = await result;
    expect(answer?.password, 'fushi-pw');
    expect(answer?.remember, isTrue);
  });

  testWidgets('上次口令不对 / 记住的已失效：显示对应提示；取消返回 null', (WidgetTester tester) async {
    final BuildContext context = await pumpHost(tester);
    Future<ArchivePasswordAnswer?> result = showArchivePasswordDialog(
      context: context,
      request: const ArchivePasswordRequest(
        archivePath: '/dl/a.zip',
        fingerprint: _fp,
        attempt: 1,
        previousWrong: true,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text(t.archive_password_wrong), findsOneWidget);
    await tester.tap(find.text(t.dialog_cancel));
    await tester.pumpAndSettle();
    expect(await result, isNull);

    result = showArchivePasswordDialog(
      context: context,
      request: const ArchivePasswordRequest(
        archivePath: '/dl/a.zip',
        fingerprint: _fp,
        rememberedRejected: true,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text(t.archive_password_saved_rejected), findsOneWidget);
    await tester.tap(find.text(t.dialog_cancel));
    await tester.pumpAndSettle();
    expect(await result, isNull);
  });

  test('口令按归档指纹存进安全存储，键带版本前缀', () async {
    final _MemoryVault vault = _MemoryVault();
    final AppArchivePasswordProvider provider = AppArchivePasswordProvider(
      vault: vault,
      ask: (ArchivePasswordRequest request) async => null,
    );
    expect(await provider.remembered(_fp), isNull);
    await provider.remember(_fp, 'fushi-pw');
    expect(vault.values, <String, String>{
      'archive_password_v1_$_fp': 'fushi-pw',
    });
    expect(await provider.remembered(_fp), 'fushi-pw');
    await provider.forget(_fp);
    expect(vault.values, isEmpty);
  });

  test('清除全部只删压缩包口令的键，别的功能的键留着', () async {
    final _MemoryVault vault = _MemoryVault();
    final AppArchivePasswordProvider provider = AppArchivePasswordProvider(
      vault: vault,
      ask: (ArchivePasswordRequest request) async => null,
    );
    const String other =
        'fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210';
    await provider.remember(_fp, 'a');
    await provider.remember(other, 'b');
    vault.values['media_lock_passcode'] = 'keep';
    expect(await forgetAllArchivePasswords(vault: vault), 2);
    expect(vault.values, <String, String>{'media_lock_passcode': 'keep'});
    expect(await provider.remembered(_fp), isNull);
    expect(await forgetAllArchivePasswords(vault: vault), 0);
  });

  test('安全存储实现拒绝空前缀（否则会删掉同一存储里别的功能的键）', () async {
    await expectLater(
      const SecureArchivePasswordVault().deleteWithPrefix(''),
      throwsArgumentError,
    );
  });

  test('安全存储读不了时清除报错，不当作没有可删的', () async {
    await expectLater(
      forgetAllArchivePasswords(vault: _UnreadableVault()),
      throwsStateError,
    );
  });

  test('并发来问时一次只开一个对话框，按先后顺序', () async {
    final List<String> order = <String>[];
    int open = 0;
    int maxOpen = 0;
    final AppArchivePasswordProvider provider = AppArchivePasswordProvider(
      vault: _MemoryVault(),
      ask: (ArchivePasswordRequest request) async {
        open++;
        if (open > maxOpen) maxOpen = open;
        order.add(request.archivePath);
        await Future<void>.delayed(const Duration(milliseconds: 5));
        open--;
        return ArchivePasswordAnswer(request.archivePath);
      },
    );
    final List<ArchivePasswordAnswer?> answers = await Future.wait(
      <Future<ArchivePasswordAnswer?>>[
        for (final String path in <String>['a', 'b', 'c'])
          provider.ask(
            ArchivePasswordRequest(archivePath: path, fingerprint: _fp),
          ),
      ],
    );
    expect(maxOpen, 1);
    expect(order, <String>['a', 'b', 'c']);
    expect(answers.map((ArchivePasswordAnswer? a) => a?.password), <String>[
      'a',
      'b',
      'c',
    ]);
  });
}
