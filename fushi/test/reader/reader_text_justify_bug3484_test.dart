import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi/src/reader/reader_content_styles.dart';
import 'package:fushi/src/reader/reader_settings.dart';

/// BUG-3484：「两端对齐」开关开时，正文必须真的两端对齐。
///
/// 旧实现开关开时只是「不注入 `text-align: start`」，从不注入 `justify`，对齐全看书自带
/// CSS——Standard Ebooks 的 EPUB 不给正文段落写 text-align，于是始终左对齐、行尾参差。
/// 判据：`text-align: justify !important` 只挂在 `body` 上靠继承下放（书里显式写了
/// center / right / left 的元素是自身声明，优先于继承值，不被误伤）；不得出现在 `p` /
/// 通配等会压过书内显式对齐的选择器上。三种 view mode × 横竖排都要成立。
Future<ReaderSettings> _settings({
  required String viewMode,
  required String writingMode,
  required bool justify,
}) async {
  final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
  addTearDown(db.close);
  final ReaderSettings settings = ReaderSettings(db);
  await settings.refreshFromDb();
  await settings.setViewMode(viewMode);
  await settings.setWritingMode(writingMode);
  await settings.setEnableTextJustification(justify);
  return settings;
}

/// 取出所有选择器恰为 `body` 的规则体（不含 `html, body` 等组合选择器）。
List<String> _bodyRuleBodies(String css) {
  final RegExp rule = RegExp(r'(?:^|\n)body \{\n([\s\S]*?)\n\}');
  return rule.allMatches(css).map((RegExpMatch m) => m.group(1)!).toList();
}

void main() {
  const List<String> viewModes = <String>['paginated', 'continuous', 'vn'];
  const List<String> writingModes = <String>['horizontal-tb', 'vertical-rl'];

  for (final String viewMode in viewModes) {
    for (final String writingMode in writingModes) {
      group('BUG-3484 $viewMode / $writingMode', () {
        test('开关开：body 注入 text-align: justify，且只在 body 上', () async {
          final String css = ReaderContentStyles.css(
            settings: await _settings(
              viewMode: viewMode,
              writingMode: writingMode,
              justify: true,
            ),
          );
          final Iterable<String> bodies = _bodyRuleBodies(css);
          expect(
            bodies.where(
              (String b) => b.contains('text-align: justify !important;'),
            ),
            hasLength(1),
            reason: '正文两端对齐必须由阅读器主动注入在 body 规则里，不能靠书自带 CSS',
          );
          expect(
            RegExp('text-align:\\s*justify').allMatches(css),
            hasLength(1),
            reason:
                'justify 只能挂 body 靠继承；挂到 p / 通配会压过书里显式的'
                ' center / right（标题、署名、诗行）',
          );
          expect(css, isNot(contains('text-align: start')));
        });

        test('开关关：行为不变（start + 悬挂标点 + 行首禁则 normal，无 justify）', () async {
          final String css = ReaderContentStyles.css(
            settings: await _settings(
              viewMode: viewMode,
              writingMode: writingMode,
              justify: false,
            ),
          );
          final String body = _bodyRuleBodies(
            css,
          ).firstWhere((String b) => b.contains('text-align: start'));
          expect(body, contains('text-align: start !important;'));
          expect(body, contains('hanging-punctuation: allow-end !important;'));
          expect(body, contains('line-break: normal !important;'));
          expect(css, isNot(contains('justify !important')));
        });
      });
    }
  }
}
