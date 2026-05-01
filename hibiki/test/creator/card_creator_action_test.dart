import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/creator.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('CardCreatorAction', () {
    test('does not open the creator page when silent export is enabled', () {
      expect(
        CardCreatorAction.shouldOpenCreator(silentExport: true),
        isFalse,
      );
    });

    test('opens the creator page when silent export is disabled', () {
      expect(
        CardCreatorAction.shouldOpenCreator(silentExport: false),
        isTrue,
      );
    });
  });
}
