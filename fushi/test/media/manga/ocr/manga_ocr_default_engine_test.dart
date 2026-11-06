/// 漫画整卷 OCR 的**出厂默认引擎** = 本机逐列 CTC 模型（`local_onnx`）。
///
/// 默认值是纯数据、编译期无痕：写错成 `auto` 只表现为「用户不改设置就永远跑不出
/// 满意的识别结果」，没有任何编译/运行期信号。这里把三件事一起钉死：
/// - ① 未写过偏好的新装机读到 `local_onnx`（默认值本身）；
/// - ② 该字符串能被 [MangaOcrEnginePreferenceKey.fromKey] 认出——`fromKey` 的
///   `default:` 分支会把任何拼错的键静默吞成 `auto`，只测 ① 抓不到这类错字；
/// - ③ 显式偏好优先于能力探测：即使 Lens 也就绪，解析结果仍是本地 CTC。
///
/// 隐私边界不变式（`auto` 永不跨到 Lens）由 `manga_ocr_engine_test.dart` 守；
/// 2026-10-21 用户拍板默认从 Lens 改回本地 CTC：出厂即离线、不上传。
library;

import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/manga/ocr/manga_ocr_engine.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi_core/fushi_core.dart';

FushiDatabase _testDb() {
  return FushiDatabase.forTesting(DatabaseConnection(NativeDatabase.memory()));
}

void main() {
  group('漫画 OCR 默认引擎', () {
    late FushiDatabase db;
    late PreferencesRepository repo;

    setUp(() async {
      db = _testDb();
      repo = PreferencesRepository(db);
      await repo.loadFromDb();
    });

    tearDown(() async {
      await db.close();
    });

    test('新装机默认 = local_onnx（CTC）', () {
      expect(repo.mangaOcrEnginePreference, 'local_onnx');
    });

    test('默认字符串能被 fromKey 认出（不落到 auto 的兜底分支）', () {
      expect(
        MangaOcrEnginePreferenceKey.fromKey(repo.mangaOcrEnginePreference),
        MangaOcrEnginePreference.localOnnx,
      );
    });

    test('用户改成 auto 后跨 reload 持久化', () async {
      await repo.setMangaOcrEnginePreference(MangaOcrEnginePreference.auto.key);
      final PreferencesRepository reloaded = PreferencesRepository(db);
      await reloaded.loadFromDb();
      expect(reloaded.mangaOcrEnginePreference, 'auto');
    });

    test('默认偏好即使 Lens 就绪也解析成本地 CTC（显式优先于探测）', () {
      final MangaOcrEngineId? engine = resolveMangaOcrEngine(
        preference: MangaOcrEnginePreferenceKey.fromKey(
          repo.mangaOcrEnginePreference,
        ),
        hasExistingMetadata: false,
        capabilities: const <MangaOcrEngineCapability>[
          MangaOcrEngineCapability(
            id: MangaOcrEngineId.localOnnx,
            supported: true,
            ready: true,
            requiresNetwork: false,
            uploadsImages: false,
            supportsIncremental: true,
          ),
          MangaOcrEngineCapability(
            id: MangaOcrEngineId.googleLens,
            supported: true,
            ready: true,
            requiresNetwork: true,
            uploadsImages: true,
            supportsIncremental: true,
          ),
        ],
      );
      expect(engine, MangaOcrEngineId.localOnnx);
    });

    test('已有 mokuro 元数据时默认引擎不触发任何 OCR', () {
      expect(
        resolveMangaOcrEngine(
          preference: MangaOcrEnginePreferenceKey.fromKey(
            repo.mangaOcrEnginePreference,
          ),
          hasExistingMetadata: true,
          capabilities: const <MangaOcrEngineCapability>[],
        ),
        isNull,
      );
    });
  });
}
