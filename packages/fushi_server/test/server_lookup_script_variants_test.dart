import 'package:fushi_server/src/dictionary_host.dart';
import 'package:test/test.dart';

/// 服务端「这次查词要不要简繁互查」的判据：请求方发来结论就照办；没发（浏览器扩展 /
/// 旧客户端）时，服务端开关（默认关）打开且请求语言是中文才开。
void main() {
  group('serverLookupUsesChineseScriptVariants', () {
    test('请求方发来结论 ⇒ 照办，服务端开关与语言都不改变它', () {
      for (final bool serverToggle in <bool>[true, false]) {
        for (final String? language in <String?>[null, 'zh', 'ja']) {
          expect(
            serverLookupUsesChineseScriptVariants(
              requested: true,
              language: language,
              serverToggle: serverToggle,
            ),
            isTrue,
          );
          expect(
            serverLookupUsesChineseScriptVariants(
              requested: false,
              language: language,
              serverToggle: serverToggle,
            ),
            isFalse,
          );
        }
      }
    });

    test('没发结论 + 服务端开关关（默认）⇒ 一律不开', () {
      for (final String? language in <String?>[null, 'zh', 'zh-Hant', 'ja']) {
        expect(
          serverLookupUsesChineseScriptVariants(
            requested: null,
            language: language,
            serverToggle: false,
          ),
          isFalse,
        );
      }
    });

    test('没发结论 + 服务端开关开 ⇒ 只在中文语言时开', () {
      expect(
        serverLookupUsesChineseScriptVariants(
          requested: null,
          language: 'zh-TW',
          serverToggle: true,
        ),
        isTrue,
      );
      expect(
        serverLookupUsesChineseScriptVariants(
          requested: null,
          language: 'ja',
          serverToggle: true,
        ),
        isFalse,
      );
      expect(
        serverLookupUsesChineseScriptVariants(
          requested: null,
          language: null,
          serverToggle: true,
        ),
        isFalse,
      );
    });
  });
}
