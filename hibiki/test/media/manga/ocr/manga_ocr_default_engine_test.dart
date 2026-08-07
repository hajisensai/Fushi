/// 漫画整卷 OCR 的**出厂默认引擎** = Google Lens。
///
/// 默认值是纯数据、编译期无痕：写错成 `auto` 只表现为「用户不改设置就永远跑不出
/// 满意的识别结果」，没有任何编译/运行期信号。这里把三件事一起钉死：
/// - ① 未写过偏好的新装机读到 `google_lens`（默认值本身）；
/// - ② 该字符串能被 [MangaOcrEnginePreferenceKey.fromKey] 认出——`fromKey` 的
///   `default:` 分支会把任何拼错的键静默吞成 `auto`，只测 ① 抓不到这类错字；
/// - ③ 显式偏好优先于能力探测：即使本地 ONNX 已就绪，解析结果仍是 Lens。
///
/// 隐私边界不变式（`auto` 永不跨到 Lens）由 `manga_ocr_engine_test.dart` 守；
/// 默认改成 Lens 后真正的上传闸门是 `ensureGoogleLensDisclosure` 的逐设备同意弹窗。
library;

import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/manga/ocr/manga_ocr_engine.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi_core/fushi_core.dart';

HibikiDatabase _testDb() {
  return HibikiDatabase.forTesting(
    DatabaseConnection(NativeDatabase.memory()),
  );
}

void main() {
  group('漫画 OCR 默认引擎', () {
    late HibikiDatabase db;
    late PreferencesRepository repo;

    setUp(() async {
      db = _testDb();
      repo = PreferencesRepository(db);
      await repo.loadFromDb();
    });

    tearDown(() async {
      await db.close();
    });

    test('新装机默认 = google_lens', () {
      expect(repo.mangaOcrEnginePreference, 'google_lens');
    });

    test('默认字符串能被 fromKey 认出（不落到 auto 的兜底分支）', () {
      expect(
        MangaOcrEnginePreferenceKey.fromKey(repo.mangaOcrEnginePreference),
        MangaOcrEnginePreference.googleLens,
      );
    });

    test('用户改回 auto 后跨 reload 持久化（离线用户能彻底退出 Lens）', () async {
      await repo.setMangaOcrEnginePreference(
        MangaOcrEnginePreference.auto.key,
      );
      final PreferencesRepository reloaded = PreferencesRepository(db);
      await reloaded.loadFromDb();
      expect(reloaded.mangaOcrEnginePreference, 'auto');
    });

    test('默认偏好即使本地 ONNX 就绪也解析成 Lens（显式优先于探测）', () {
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
      expect(engine, MangaOcrEngineId.googleLens);
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
