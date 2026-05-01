import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/models.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AppModel creator routing', () {
    test('opens the creator when silent export is disabled', () {
      expect(
        AppModel.shouldOpenCreatorRoute(
          silentExport: false,
          isExportable: true,
        ),
        isTrue,
      );
    });

    test('does not open the creator for exportable silent exports', () {
      expect(
        AppModel.shouldOpenCreatorRoute(
          silentExport: true,
          isExportable: true,
        ),
        isFalse,
      );
    });

    test('opens the creator when silent export has no exportable content', () {
      expect(
        AppModel.shouldOpenCreatorRoute(
          silentExport: true,
          isExportable: false,
        ),
        isTrue,
      );
    });
  });
}
