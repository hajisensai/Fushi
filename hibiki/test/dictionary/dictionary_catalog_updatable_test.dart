import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_dictionary/hibiki_dictionary.dart';

import 'package:hibiki/src/models/dictionary_import_manager.dart';

/// TODO-1075：修「词典自动更新永不启用」的初装 gate 空档。
///
/// 根因链：catalog 在线导入（`_downloadSelectedDictionaries`）以前只回填
/// `{downloadUrl: rec.url}`，可更新性完全依赖第三方词典包内 index.json 是否碰巧声明
/// `isUpdatable`/`indexUrl`——一旦包不声明（如 MarvNC/grammar），`Dictionary.isUpdatable`
/// 三条件与门恒 false → `maybeAutoUpdateDictionaries` 过滤掉所有词典 →
/// `shouldAutoUpdateDictionaries` 恒 false → 自动更新永不执行。而唯一会回填
/// `isUpdatable:'true'` 的手动更新路径只在词典**已可更新**后才可达（先有鸡才有蛋）。
///
/// 修复：把「可更新性」权威信号锚定在 catalog 来源真值——对存在**分离 index.json
/// 端点**的来源（yomidevs releases、wty），[RecommendedDictionary.indexUrl] 非 null，
/// 初装即回填 `isUpdatable:'true' + indexUrl + downloadUrl` 三件套，使这些词典**初装
/// 即 isUpdatable==true**，`shouldAutoUpdateDictionaries` 能返回 true（修复前恒 false）。
/// 无分离 index 端点的来源（MarvNC/Kuuuube/grammar/frequency）[indexUrl] 为 null →
/// 只回填 downloadUrl，isUpdatable 交回包内声明——不误标不可更新来源为可更新。
void main() {
  RecommendedDictionary? byPrefix(String prefix) {
    for (final RecommendedDictionary d in DictionaryDownloader.catalog) {
      if (d.matchPrefix == prefix) return d;
    }
    return null;
  }

  group('RecommendedDictionary.indexUrl 派生（分离 index 端点）', () {
    test('yomidevs releases：JMdict → sibling .json（.zip→.json）', () {
      final RecommendedDictionary? d = byPrefix('JMdict');
      expect(d, isNotNull);
      expect(
        d!.indexUrl,
        'https://github.com/yomidevs/jmdict-yomitan/releases/latest/download/JMdict_english.json',
      );
      expect(d.isCatalogUpdatable, isTrue);
    });

    test('yomidevs releases：KANJIDIC (English) → sibling .json', () {
      final RecommendedDictionary? d = byPrefix('KANJIDIC (English)');
      expect(d, isNotNull);
      expect(
        d!.indexUrl,
        'https://github.com/yomidevs/jmdict-yomitan/releases/latest/download/KANJIDIC_english.json',
      );
    });

    test('wty (HuggingFace)：wty-ja-en → 独立 index 路径 + ?download=true', () {
      final RecommendedDictionary? d = byPrefix('wty-ja-en');
      expect(d, isNotNull);
      expect(
        d!.indexUrl,
        'https://huggingface.co/datasets/daxida/wty-release/resolve/main/latest/index/wty-ja-en-index.json?download=true',
      );
      expect(d.isCatalogUpdatable, isTrue);
    });

    test('wty 动态语言条目也派生正确 index（wty-ja-zh）', () {
      final RecommendedDictionary? d = byPrefix('wty-ja-zh');
      expect(d, isNotNull);
      expect(
        d!.indexUrl,
        'https://huggingface.co/datasets/daxida/wty-release/resolve/main/latest/index/wty-ja-zh-index.json?download=true',
      );
    });

    test('无分离 index 端点的来源 → indexUrl null（不误标可更新）', () {
      // MarvNC git-raw、Kuuuube、grammar/frequency 打包等无独立 index 端点。
      final RecommendedDictionary? tkm = byPrefix('TheKanjiMap'); // MarvNC
      expect(tkm, isNotNull);
      expect(tkm!.indexUrl, isNull);
      expect(tkm.isCatalogUpdatable, isFalse);

      final RecommendedDictionary? grammar = byPrefix(
          'Nihongo-Bunkei-Jiten'); // HuangAntimony releases (非 yomidevs)
      expect(grammar, isNotNull);
      expect(grammar!.indexUrl, isNull);

      final RecommendedDictionary? bccwj = byPrefix('BCCWJ'); // Kuuuube
      expect(bccwj, isNotNull);
      expect(bccwj!.indexUrl, isNull);
    });
  });

  group('catalog 导入端到端：可更新源初装即 isUpdatable==true', () {
    // 模拟 _downloadSelectedDictionaries 对可更新源构造的 sourceOverride，再经
    // mergeSourceMetadata（导入实际走的合并）落成 Dictionary.metadata，断言三条件满足。
    Dictionary importedDict({
      required RecommendedDictionary rec,
      required Map<String, String> fromIndex,
    }) {
      final String? recIndexUrl = rec.indexUrl;
      final Map<String, String> sourceOverride = recIndexUrl != null
          ? <String, String>{
              'isUpdatable': 'true',
              'indexUrl': recIndexUrl,
              'downloadUrl': rec.url,
            }
          : <String, String>{'downloadUrl': rec.url};
      final Map<String, String> metadata =
          DictionaryImportManager.mergeSourceMetadata(
              fromIndex, sourceOverride);
      return Dictionary(
        name: rec.name,
        formatKey: 'yomichan',
        order: 0,
        metadata: metadata,
      );
    }

    test('可更新源（JMdict）即便包 index 不声明字段，初装也 isUpdatable==true', () {
      final RecommendedDictionary rec = byPrefix('JMdict')!;
      // 悲观场景：包内 index.json 只有 revision（无 isUpdatable/indexUrl）。
      final Dictionary d = importedDict(
        rec: rec,
        fromIndex: <String, String>{'revision': 'JMdict.2026-07-01'},
      );
      expect(d.isUpdatable, isTrue,
          reason: '修复前此处恒 false（初装 gate 空档）——修复后由 catalog 权威回填置真');
      expect(d.indexUrl, endsWith('JMdict_english.json'));
      expect(d.downloadUrl, rec.url);
      expect(d.revision, 'JMdict.2026-07-01');
    });

    test('可更新源导入后 shouldAutoUpdateDictionaries 能返回 true（修复前恒 false）', () {
      final Dictionary d = importedDict(
        rec: byPrefix('wty-ja-en')!,
        fromIndex: <String, String>{'revision': '2026.06.10'},
      );
      final List<Dictionary> installed = <Dictionary>[d];
      final bool hasUpdatable =
          installed.where((Dictionary x) => x.isUpdatable).isNotEmpty;
      expect(hasUpdatable, isTrue);
      expect(
        shouldAutoUpdateDictionaries(
          now: DateTime(2026, 7, 1),
          lastUpdate: null, // 从未更新 → 到期
          interval: DictionaryUpdateInterval.weekly,
          hasUpdatable: hasUpdatable,
          isBusy: false,
        ),
        isTrue,
        reason: '有可更新词典 + 从未更新 → 应触发自动更新；修复前 hasUpdatable 恒 false '
            '导致此处恒 false，功能死。',
      );
    });

    test(
        '无分离 index 端点的来源（TheKanjiMap）只回填 downloadUrl，'
        '包不声明 → isUpdatable==false（不误标）', () {
      final Dictionary d = importedDict(
        rec: byPrefix('TheKanjiMap')!,
        fromIndex: <String, String>{'revision': 'thekanjimap_x'},
      );
      expect(d.isUpdatable, isFalse,
          reason: '无独立 index 端点的来源不应被 catalog 标为可更新');
      expect(d.downloadUrl, isNotEmpty);
      expect(d.indexUrl, isEmpty);
    });

    test('无分离 index 端点但包**自声明** isUpdatable → 仍尊重包声明（不被压掉）', () {
      // 若某来源无 catalog indexUrl，但其包内 index.json 自带完整可更新三件套，
      // mergeSourceMetadata 保留包内字段（override 只带 downloadUrl）→ 仍可更新。
      final Dictionary d = importedDict(
        rec: byPrefix('TheKanjiMap')!,
        fromIndex: <String, String>{
          'revision': 'r',
          'isUpdatable': 'true',
          'indexUrl': 'https://example.com/tkm-index.json',
        },
      );
      expect(d.isUpdatable, isTrue);
      // downloadUrl 被 catalog url override（更新时据此重下载）。
      expect(d.downloadUrl, byPrefix('TheKanjiMap')!.url);
      expect(d.indexUrl, 'https://example.com/tkm-index.json');
    });
  });
}
