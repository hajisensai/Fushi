// ignore_for_file: invalid_use_of_protected_member
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/anki/anki_view_model.dart';
import 'package:fushi/src/anki/ankimobile_repository.dart';
import 'package:fushi_anki/fushi_anki.dart';

// BUG-2150：iOS 上 AnkiMobile 的 `infoForAdding` 结果经系统剪贴板回传。此前
// 「没读到」只有一种表达——硬编码英文 "No AnkiMobile configuration was found on
// the clipboard."——把三种下一步动作完全不同的情形压成一句话：
//   ① AnkiMobile 根本没写（用户没在 AnkiMobile 里同意那次请求）；
//   ② 写了，但 iOS 不让读（「允许粘贴」被拒 / 此刻弹不出确认）；
//   ③ 真的空。
// 而真正的根因是**读得太早**：AnkiMobile 的 x-success 把 Fushi 拉回前台时，
// `application(_:open:)` 跑在 `.inactive` 阶段，那一刻读通用剪贴板必然拿到 nil。
// 原生侧的时序门由 ankimobile_ios_callback_static_test.dart 守；这里守 Dart 侧的
// 三态契约与文案本地化。


/// 只回「已跳转 AnkiMobile，去那边点同意」的假后端：真实 AnkiMobile 的
/// `fetchConfiguration` 就是这个形状——它不可能同步拿到结果。
class _AnkiMobileOpenedRepo extends BaseAnkiRepository {
  AnkiSettings _settings = const AnkiSettings();

  @override
  Future<AnkiSettings> loadSettings() async => _settings;

  @override
  Future<void> saveSettings(AnkiSettings s) async => _settings = s;

  @override
  Future<AnkiFetchResult> fetchConfiguration() async =>
      const AnkiFetchResult.error(
        'AnkiMobile opened. Approve the request, then return to Fushi.',
        code: AnkiErrorCode.ankiMobileOpened,
      );

  @override
  Future<bool> createNoteType(AnkiNoteTypeTemplate template) async => false;

  @override
  Future<bool> createDeck(String name) async => false;

  @override
  Future<MineOutcome> mineEntry({
    required String rawPayloadJson,
    required AnkiMiningContext context,
  }) async =>
      MineOutcome.failure('test stub');

  @override
  Future<bool> isDuplicate(String expression, String reading) async => false;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  AnkiMobileRepository repoReading(AnkiMobilePasteboardRead read) =>
      AnkiMobileRepository(
        openUrl: (_) async => true,
        readInfoForAddingJson: () async => read,
      );

  group('consumeInfoForAddingPasteboard 的三态各有自己的稳定码', () {
    test('系统不让读 → denied 码（不是「剪贴板上没有配置」）', () async {
      final result = await repoReading(
        const AnkiMobilePasteboardRead.denied(),
      ).consumeInfoForAddingPasteboard();

      expect(result, isA<AnkiFetchError>());
      expect(
        (result as AnkiFetchError).code,
        AnkiErrorCode.ankiMobilePasteboardDenied,
      );
    });

    test('AnkiMobile 没写 → empty 码', () async {
      final result = await repoReading(
        const AnkiMobilePasteboardRead.empty(),
      ).consumeInfoForAddingPasteboard();

      expect(result, isA<AnkiFetchError>());
      expect(
        (result as AnkiFetchError).code,
        AnkiErrorCode.ankiMobilePasteboardEmpty,
      );
    });

    test('两种失败不能再共用同一个码', () async {
      final denied = await repoReading(
        const AnkiMobilePasteboardRead.denied(),
      ).consumeInfoForAddingPasteboard() as AnkiFetchError;
      final empty = await repoReading(
        const AnkiMobilePasteboardRead.empty(),
      ).consumeInfoForAddingPasteboard() as AnkiFetchError;

      expect(denied.code, isNot(empty.code));
      expect(denied.message, isNot(empty.message));
    });

    test('ok 但 json 为空 → 按 empty 处理，不当成读到了', () async {
      final result = await repoReading(
        const AnkiMobilePasteboardRead(AnkiMobilePasteboardStatus.ok),
      ).consumeInfoForAddingPasteboard();

      expect(result, isA<AnkiFetchError>());
      expect(
        (result as AnkiFetchError).code,
        AnkiErrorCode.ankiMobilePasteboardEmpty,
      );
    });

    test('回传了 JSON 但里面没牌组 → no-decks 码', () async {
      final result = await repoReading(
        const AnkiMobilePasteboardRead.ok('{"decks":[],"notetypes":[]}'),
      ).consumeInfoForAddingPasteboard();

      expect(result, isA<AnkiFetchError>());
      expect((result as AnkiFetchError).code, AnkiErrorCode.ankiMobileNoDecks);
    });
  });

  group('fetchConfiguration', () {
    test('已跳转 AnkiMobile 是中间态，带 opened 码而非无码英文', () async {
      final repo = AnkiMobileRepository(
        openUrl: (_) async => true,
        readInfoForAddingJson: () async =>
            const AnkiMobilePasteboardRead.empty(),
      );

      final result = await repo.fetchConfiguration();

      expect(result, isA<AnkiFetchError>());
      expect((result as AnkiFetchError).code, AnkiErrorCode.ankiMobileOpened);
    });

    test('打不开 anki:// → unavailable 码', () async {
      final repo = AnkiMobileRepository(
        openUrl: (_) async => false,
        readInfoForAddingJson: () async =>
            const AnkiMobilePasteboardRead.empty(),
      );

      final result = await repo.fetchConfiguration();

      expect(result, isA<AnkiFetchError>());
      expect(
        (result as AnkiFetchError).code,
        AnkiErrorCode.ankiMobileUnavailable,
      );
    });

    // BUG-558 定下的编码规则对整个类成立：query 一律百分号编码。此前
    // infoForAdding 这条 URL 是同一个类里的第二套编码（`Uri.replace`
    // (queryParameters:) 把空格编成 `+`）——现在只剩一套。
    test('infoForAdding 的 x-success 走百分号编码', () async {
      final launched = <Uri>[];
      final repo = AnkiMobileRepository(
        openUrl: (uri) async {
          launched.add(uri);
          return true;
        },
        readInfoForAddingJson: () async =>
            const AnkiMobilePasteboardRead.empty(),
      );

      await repo.fetchConfiguration();

      expect(launched, hasLength(1));
      final Uri uri = launched.single;
      expect(uri.scheme, 'anki');
      expect(uri.path, '/infoForAdding');
      expect(uri.query, isNot(contains('+')));
      expect(uri.query, 'x-success=fushi%3A%2F%2FankiFetch');
      expect(uri.queryParameters['x-success'], fushiAnkiFetchCallback);
    });
  });

  // BUG-2150 的 UI 尾巴：配置回传是跨 app 异步完成的，`fetchConfiguration()` 只能先
  // 把「已跳转，去 AnkiMobile 点同意」写进 errorMessage。回调成功时若不清掉它，设置页
  // 会在牌组已经装好之后仍挂着「请去同意」——在用户眼里就是「又失败了一次」。
  group('回传成功后的中间态清理', () {
    setUp(() => LocaleSettings.setLocale(AppLocale.en));

    test('applyFetchedConfiguration 清掉「去 AnkiMobile 点同意」', () async {
      final AnkiViewModel vm = AnkiViewModel(_AnkiMobileOpenedRepo());
      await vm.fetchConfiguration();
      expect(vm.state.errorMessage, isNotNull);
      expect(vm.state.errorMessage, t.anki_ankimobile_opened);

      await vm.applyFetchedConfiguration();

      expect(vm.state.errorMessage, isNull);
      expect(vm.state.isFetching, isFalse);
    });
  });

  group('文案本地化', () {
    tearDown(() => LocaleSettings.setLocale(AppLocale.en));

    test('五个 AnkiMobile 码在中文 UI 下都不再吐英文原文', () {
      LocaleSettings.setLocale(AppLocale.zhCn);

      const Map<String, String> rawEnglish = <String, String>{
        AnkiErrorCode.ankiMobileOpened:
            'AnkiMobile opened. Approve the request, then return to Fushi.',
        AnkiErrorCode.ankiMobilePasteboardEmpty:
            'No AnkiMobile configuration was found on the clipboard.',
        AnkiErrorCode.ankiMobilePasteboardDenied:
            'iOS blocked reading the clipboard.',
        AnkiErrorCode.ankiMobileNoDecks:
            'AnkiMobile returned no decks or note types.',
        AnkiErrorCode.ankiMobileUnavailable:
            'Could not open AnkiMobile. Install AnkiMobile and try again.',
      };

      final Set<String> localized = <String>{};
      for (final MapEntry<String, String> entry in rawEnglish.entries) {
        final String text = AnkiViewModel.localizeAnkiFetchError(
          entry.value,
          entry.key,
        );
        expect(text, isNot(entry.value), reason: '${entry.key} 仍在透传英文原文');
        localized.add(text);
      }
      // 五条互不相同——否则「区分三态」在 UI 上等于没做。
      expect(localized, hasLength(rawEnglish.length));
    });

    test('empty / denied 在英文下也是两句不同的、可操作的话', () {
      LocaleSettings.setLocale(AppLocale.en);

      expect(
        t.anki_error_ankimobile_pasteboard_empty,
        isNot(t.anki_error_ankimobile_pasteboard_denied),
      );
      // 旧文案只说「剪贴板上没有」，不说该做什么。两条都必须给下一步动作。
      expect(t.anki_error_ankimobile_pasteboard_empty, contains('AnkiMobile'));
      expect(t.anki_error_ankimobile_pasteboard_denied, contains('Paste'));
    });
  });
}
