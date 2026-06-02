import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/utils/misc/platform_utils.dart';

void main() {
  test('settings detail pane is widened for desktop balance (760 -> 960)', () {
    expect(
      desktopContentMaxWidth(
        WindowSizeClass.expanded,
        DesktopContentKind.settings,
      ),
      960,
    );
  });

  test('compact returns null (no cap) for settings', () {
    expect(
      desktopContentMaxWidth(
        WindowSizeClass.compact,
        DesktopContentKind.settings,
      ),
      isNull,
    );
  });
}
