import 'package:fushi_server/src/dictionary_host.dart';
import 'package:test/test.dart';

/// 服务端「这次查词要不要简繁互查」的判据：开关取请求方发来的值（没发 = 浏览器扩展 /
/// 旧客户端，取服务端开关，默认关），开着且请求语言是中文才开。
void main() {
  group('serverLookupUsesChineseScriptVariants', () {
    test('请求方开关开 ⇒ 代替服务端开关，中文才开', () {
      for (final bool serverToggle in <bool>[true, false]) {
        expect(
          serverLookupUsesChineseScriptVariants(
            requested: true,
            language: 'zh-TW',
            serverToggle: serverToggle,
          ),
          isTrue,
        );
        for (final String? language in <String?>[null, 'ja']) {
          expect(
            serverLookupUsesChineseScriptVariants(
              requested: true,
              language: language,
              serverToggle: serverToggle,
            ),
            isFalse,
            reason: '开关开也不动非中文 / 语言未知的查询（"$language"）',
          );
        }
      }
    });

    test('请求方开关关 ⇒ 即使服务端开着、语言是中文也不开', () {
      expect(
        serverLookupUsesChineseScriptVariants(
          requested: false,
          language: 'zh',
          serverToggle: true,
        ),
        isFalse,
      );
    });

    test('没发开关 + 服务端开关关（默认）⇒ 一律不开', () {
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

    test('没发开关 + 服务端开关开 ⇒ 只在中文语言时开', () {
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
