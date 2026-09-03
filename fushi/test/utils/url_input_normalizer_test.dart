import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/manga/aidoku/aidoku_repository_client.dart';
import 'package:fushi/src/utils/net/url_input_normalizer.dart';

/// BUG-1804：中文/日文输入法把 URL 结构字符转成全角，导致合法仓库地址
/// 被判 INVALID_URL（前两例），或带着垃圾域名通过校验（第三例）。
void main() {
  group('normalizeUrlInput', () {
    const String expected =
        'https://github.com/keiyoushi/extensions/raw/repo/index.pb';

    test('半角地址原样通过', () {
      expect(normalizeUrlInput(expected), expected);
    });

    test('全角冒号折回半角', () {
      expect(
        normalizeUrlInput(
          'https：//github.com/keiyoushi/extensions/raw/repo/index.pb',
        ),
        expected,
      );
    });

    test('全角斜杠折回半角', () {
      expect(
        normalizeUrlInput(
          'https:／／github.com／keiyoushi／extensions／raw／repo／index.pb',
        ),
        expected,
      );
    });

    test('表意句号折回半角点', () {
      expect(
        normalizeUrlInput(
          'https://github。com/keiyoushi/extensions/raw/repo/index。pb',
        ),
        expected,
      );
    });

    test('全角句点（U+FF0E）折回半角点', () {
      expect(
        normalizeUrlInput(
          'https://github．com/keiyoushi/extensions/raw/repo/index．pb',
        ),
        expected,
      );
    });

    test('输入法混合产物一次归一化到位', () {
      expect(
        normalizeUrlInput(
          'ｈｔｔｐｓ：／／ｇｉｔｈｕｂ．ｃｏｍ／ｋｅｉｙｏｕｓｈｉ／'
          'ｅｘｔｅｎｓｉｏｎｓ／ｒａｗ／ｒｅｐｏ／ｉｎｄｅｘ．ｐｂ',
        ),
        expected,
      );
    });

    test('非 ASCII 空白被剔除', () {
      expect(
        normalizeUrlInput('　 https://example.org/repo.json '),
        'https://example.org/repo.json',
      );
      expect(
        normalizeUrlInput('https://example.org/﻿repo.json'),
        'https://example.org/repo.json',
      );
    });

    test('不动 path 里未编码的中文——那是 Uri 的职责，不是这里的', () {
      expect(
        normalizeUrlInput('https://example.org/漫画/index.json'),
        'https://example.org/漫画/index.json',
      );
    });

    test('不动 percent-encoding 与查询串', () {
      const String encoded =
          'https://example.org/a%20b/index.json?q=1&lang=zh-CN#frag';
      expect(normalizeUrlInput(encoded), encoded);
    });
  });

  group('归一化后 Uri 解析真的可用（BUG-1804 的原始失败判据）', () {
    /// 复刻 `MihonExtensionStoreClient._validatedUri` 的判据：
    /// `Uri.tryParse` 成功且 `hasAuthority`。
    bool passesStoreValidation(String raw) {
      final Uri? uri = Uri.tryParse(normalizeUrlInput(raw));
      return uri != null && uri.hasAuthority;
    }

    test('三种全角形态归一化后都能解析出正确 authority', () {
      const List<String> inputs = <String>[
        'https：//github.com/keiyoushi/extensions/raw/repo/index.pb',
        'https:／／github.com／keiyoushi／extensions／raw／repo／index.pb',
        'https://github．com/keiyoushi/extensions/raw/repo/index．pb',
      ];
      for (final String raw in inputs) {
        expect(passesStoreValidation(raw), isTrue, reason: raw);
        expect(
          Uri.parse(normalizeUrlInput(raw)).authority,
          'github.com',
          reason: raw,
        );
      }
    });

    test('不归一化则这三种全部失败——证明归一化是必需的，不是装饰', () {
      // 全角冒号：scheme 解析不出来。
      final Uri bad1 = Uri.parse(
        'https：//github.com/keiyoushi/extensions/raw/repo/index.pb',
      );
      expect(bad1.hasAuthority, isFalse);
      // 全角斜杠：authority 为空。
      final Uri bad2 = Uri.parse(
        'https:／／github.com／keiyoushi／extensions／raw／repo／index.pb',
      );
      expect(bad2.authority, isEmpty);
      // 全角句点：**通过** hasAuthority，但域名是垃圾——这条最阴险，
      // 事后补救型的「解析失败再归一化」根本抓不到它。
      final Uri bad3 = Uri.parse(
        'https://github．com/keiyoushi/extensions/raw/repo/index.pb',
      );
      expect(bad3.hasAuthority, isTrue);
      expect(bad3.authority, isNot('github.com'));
    });
  });

  group('Aidoku 仓库入口同族收敛', () {
    test('全角输入的 github 仓库地址能被正确归一化并映射', () {
      final Uri resolved = AidokuRepositoryClient.normalizeRepositoryUri(
        'https：//github.com/Skittyblock/aidoku-community-sources',
      );
      expect(resolved.host, 'skittyblock.github.io');
      expect(resolved.path, '/aidoku-community-sources/index.min.json');
    });

    test('全角句点不再产出垃圾 host', () {
      final Uri resolved = AidokuRepositoryClient.normalizeRepositoryUri(
        'https://example．org/repo/index.json',
      );
      expect(resolved.host, 'example.org');
    });
  });
}
