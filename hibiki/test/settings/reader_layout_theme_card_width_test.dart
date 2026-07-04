import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/settings/material_settings_renderer.dart';
import 'package:hibiki/src/utils/components/hibiki_design_tokens.dart';
import 'package:hibiki/src/utils/components/settings_shared.dart';

/// Guards BUG-546 (TODO-1135): in the reader quick-settings 「布局与显示」 sub-page
/// the theme selector card sits in the same Column as the layout schema section.
/// The schema section is rendered by [MaterialSettingsRenderer.buildDetailContent],
/// whose body carries an extra horizontal inset; the theme card used to be a bare
/// [AdaptiveSettingsSection] with no such inset, so it stretched wider and its
/// left/right edges did not line up with the config rows below.
///
/// Root fix: both the detail body padding and the theme card wrapper now derive
/// their horizontal insets from the single source
/// [MaterialSettingsRenderer.detailHorizontalInsets]. Two layers:
///   1. Behavioral — a card wrapped in the shared insets lines up pixel-exact with
///      a card padded by the exact expression buildDetailContent applies.
///   2. Source-scan — buildDetailContent and the theme section both go through the
///      shared helper (binds the fix; red if either drifts to a hardcoded pad).
void main() {
  testWidgets(
      'theme card wrapped in shared insets aligns with detail-body content edges',
      (WidgetTester tester) async {
    const Key themeCardKey = Key('theme-card');
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
            // that body with the exact same horizontal expression, and the theme
            // card path with the wrapper the fix installs. Both wrap the same
            // AdaptiveSettingsSection, so equal edges ⇒ equal width.
            return Scaffold(
              body: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    // Theme card path: wrapper the fix installs.
                    Padding(
                      padding: shared,
                      child: const AdaptiveSettingsSection(
                        children: <Widget>[
                          SizedBox(key: themeCardKey, height: 40),
                        ],
                      ),
                    ),
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
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    final Rect themeRect = tester.getRect(find.byKey(themeCardKey));
    final Rect bodyRect = tester.getRect(find.byKey(bodyCardKey));

    expect(shared.left, greaterThan(0),
        reason: 'Material detail body must have a real left inset to match');
    expect(themeRect.left, moreOrLessEquals(bodyRect.left, epsilon: 0.5),
        reason: 'theme card left edge must line up with detail-body content');
    expect(themeRect.right, moreOrLessEquals(bodyRect.right, epsilon: 0.5),
        reason: 'theme card right edge must line up with detail-body content');
    expect(themeRect.width, moreOrLessEquals(bodyRect.width, epsilon: 0.5),
        reason: 'theme card and config rows must be equal width (BUG-546)');
  });

  test('buildDetailContent and theme section share detailHorizontalInsets', () {
    final String renderer =
        File('lib/src/settings/material_settings_renderer.dart')
            .readAsStringSync();
    // Single source of truth exists and buildDetailContent derives its horizontal
    // padding from it (not a fresh hardcoded fromLTRB).
    expect(renderer, contains('static EdgeInsets detailHorizontalInsets('),
        reason: '横向缩进必须有唯一真相源 detailHorizontalInsets');
    expect(renderer, contains('detailHorizontalInsets(tokens)'),
        reason: 'buildDetailContent 必须从共享 helper 取横向缩进');
    expect(renderer, contains('horizontal.left'),
        reason: 'buildDetailContent 的 padding 左值来自共享 helper');
    expect(renderer, contains('horizontal.right'),
        reason: 'buildDetailContent 的 padding 右值来自共享 helper');

    final String sheet =
        File('lib/src/media/audiobook/reader_quick_settings_sheet.dart')
            .readAsStringSync();
    // Theme selector section wraps in the SAME shared insets (Material only).
    expect(sheet, contains('MaterialSettingsRenderer.detailHorizontalInsets('),
        reason: '主题选择器卡必须用同一 helper 取横向缩进，与配置行等宽（BUG-546）');
  });
}
