import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/settings/material_settings_renderer.dart';
import 'package:hibiki/src/utils/components/hibiki_design_tokens.dart';
import 'package:hibiki/src/utils/components/settings_shared.dart';

/// Guards BUG-573 (TODO-1234): in the reader quick-settings 「布局与显示」 sub-page
/// (and its lyrics-mode twin) the 「编辑书籍 CSS」 entry row sits in the same Column
/// as the layout schema section. The schema section is rendered by
/// [MaterialSettingsRenderer.buildDetailContent], whose body carries an extra
/// horizontal inset; the CSS row used to be a bare [AdaptiveSettingsSection] with no
/// such inset, so it stretched wider and its left/right edges did not line up with
/// the config rows above. Same shape as the theme-card fix (BUG-545/546).
///
/// Root fix: the CSS row is now wrapped by `_buildBookCssEditorSection`, which adds
/// the shared [MaterialSettingsRenderer.detailHorizontalInsets] on Material (skips on
/// Cupertino, whose buildDetailContent has no horizontal inset). Two layers:
///   1. Behavioral — a card wrapped in the shared insets lines up pixel-exact with a
///      card padded by the exact expression buildDetailContent applies.
///   2. Source-scan — both call sites go through `_buildBookCssEditorSection` and it
///      derives its inset from the shared helper (red if either drifts back to a bare
///      section or a hardcoded pad).
void main() {
  testWidgets(
      'css editor row wrapped in shared insets aligns with detail-body content edges',
      (WidgetTester tester) async {
    const Key cssRowKey = Key('css-row');
    const Key bodyCardKey = Key('body-card');

    late EdgeInsets shared;
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(useMaterial3: true),
        home: Builder(
          builder: (BuildContext context) {
            final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
            shared = MaterialSettingsRenderer.detailHorizontalInsets(tokens);
            // buildDetailContent applies fromLTRB(horizontal.left, gap,
            // horizontal.right, ...) around its schema sections. We stand in for
            // that body with the exact same horizontal expression, and the CSS row
            // path with the wrapper `_buildBookCssEditorSection` installs. Both wrap
            // the same AdaptiveSettingsSection, so equal edges => equal width.
            return Scaffold(
              body: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    // Detail-body path: buildDetailContent's horizontal padding.
                    Padding(
                      padding: EdgeInsets.only(
                        left: shared.left,
                        right: shared.right,
                      ),
                      child: const AdaptiveSettingsSection(
                        children: <Widget>[
                          SizedBox(key: bodyCardKey, height: 40),
                        ],
                      ),
                    ),
                    // CSS row path: wrapper `_buildBookCssEditorSection` installs.
                    Padding(
                      padding: shared,
                      child: const AdaptiveSettingsSection(
                        children: <Widget>[
                          SizedBox(key: cssRowKey, height: 40),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    final Rect cssRect = tester.getRect(find.byKey(cssRowKey));
    final Rect bodyRect = tester.getRect(find.byKey(bodyCardKey));

    expect(shared.left, greaterThan(0),
        reason: 'Material detail body must have a real left inset to match');
    expect(cssRect.left, moreOrLessEquals(bodyRect.left, epsilon: 0.5),
        reason: 'css row left edge must line up with detail-body content');
    expect(cssRect.right, moreOrLessEquals(bodyRect.right, epsilon: 0.5),
        reason: 'css row right edge must line up with detail-body content');
    expect(cssRect.width, moreOrLessEquals(bodyRect.width, epsilon: 0.5),
        reason: 'css row and config rows above must be equal width (BUG-573)');
  });

  test(
      'book-css editor section wraps in shared insets and is the only call path',
      () {
    final String sheet =
        File('lib/src/media/audiobook/reader_quick_settings_sheet.dart')
            .readAsStringSync();

    // The CSS section wrapper exists and derives its inset from the shared helper.
    expect(sheet, contains('Widget _buildBookCssEditorSection()'),
        reason: 'CSS 入口条必须有统一 section 包装器 _buildBookCssEditorSection');
    expect(sheet, contains('MaterialSettingsRenderer.detailHorizontalInsets('),
        reason: 'CSS 入口条 section 必须用同一 helper 取横向缩进，与配置行等宽（BUG-573）');

    // Both layout sub-pages route through the wrapper, none re-wrap the raw row in a
    // bare AdaptiveSettingsSection (which would drop the inset and go wider again).
    final int wrapperCalls =
        '_buildBookCssEditorSection()'.allMatches(sheet).length;
    expect(wrapperCalls, greaterThanOrEqualTo(2),
        reason: '普通布局子页与歌词模式子页都必须经 _buildBookCssEditorSection');
    final int bareRowSections =
        '<Widget>[_buildBookCssEditorRow()]'.allMatches(sheet).length;
    expect(bareRowSections, equals(1),
        reason: 'CSS 入口条只能在 _buildBookCssEditorSection 内包一次；调用点不得再裸放 '
            'AdaptiveSettingsSection（会丢缩进、比配置行宽）');
  });
}
