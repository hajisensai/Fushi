import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/tags/tag_picker_sheet.dart';
import 'package:fushi_core/fushi_core.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => LocaleSettings.setLocale(AppLocale.zhCn));
  for (final bool added in <bool>[true, false]) {
    test('tag feedback uses changed host kinds, added=$added', () {
      String message(List<MediaKind?> kinds) =>
          tagBatchFeedback(name: '学习', changedKinds: kinds, added: added);
      expect(
        message(<MediaKind?>[MediaKind.video, MediaKind.video]),
        added ? '已为 2 个视频添加标签「学习」。' : '已从 2 个视频移除标签「学习」。',
      );
      expect(
        message(<MediaKind?>[MediaKind.epub, MediaKind.srt]),
        added ? '已为 2 本书添加标签「学习」。' : '已从 2 本书移除标签「学习」。',
      );
      for (final List<MediaKind?> kinds in <List<MediaKind?>>[
        <MediaKind?>[MediaKind.video, MediaKind.epub],
        <MediaKind?>[MediaKind.game, MediaKind.game],
        <MediaKind?>[null, null],
        <MediaKind?>[MediaKind.video, null],
      ]) {
        expect(message(kinds), added ? '已为 2 项添加标签「学习」。' : '已从 2 项移除标签「学习」。');
      }
    });
  }
}
