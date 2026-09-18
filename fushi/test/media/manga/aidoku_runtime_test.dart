/// Aidoku 运行时**协议层**的纯解析契约。
///
/// 子进程（macOS）与 MethodChannel（iOS）两个宿主已先后整条移除，原本驱动假 exe
/// 的用例随之删除；这里只剩与宿主无关的 JSON 解析，以及「没有宿主」这条事实。
import 'package:flutter_test/flutter_test.dart';

import 'package:fushi/src/media/manga/aidoku/aidoku_runtime.dart';

void main() {
  test('parses manifest listings', () {
    final AidokuPackageInspection inspection = AidokuPackageInspection.fromJson(
      <String, Object?>{
        'manifest': <String, Object?>{
          'info': <String, Object?>{'id': 'ja.test'},
          'listings': <Object?>[
            <String, Object?>{'id': '/latest/', 'name': 'Latest'},
          ],
        },
        'runtime': <String, Object?>{},
      },
    );

    expect(inspection.listings, hasLength(1));
    expect(inspection.listings.single.id, '/latest/');
  });

  test('no platform has an Aidoku runtime host', () {
    expect(AidokuRuntimeFactory.isSupported, isFalse);
    expect(
      AidokuRuntimeFactory.create,
      throwsA(
        isA<AidokuRuntimeException>().having(
          (AidokuRuntimeException error) => error.code,
          'code',
          'UNSUPPORTED_PLATFORM',
        ),
      ),
    );
  });
}
