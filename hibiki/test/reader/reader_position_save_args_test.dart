import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/pages/implementations/reader_hibiki_page.dart'
    show readerPositionSaveArgs;
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_core/fushi_core.dart';

/// BUG-285 / BUG-162（渐进重建 phase2）：`_persistPosition` 落库参数归一化凿成
/// 纯函数 [readerPositionSaveArgs] 后的真行为测——替换旧的
/// `charOffset: charOffset >= 0 ? charOffset : null` 字符串扫描守卫（那种守卫在
/// 写法等价重构时假红、逻辑搬走时真空绿）。
///
/// 三层不变量：
///  1. 纯函数语义：-1/负值 → null（瞬态不覆写精确锚）、>=0 原样、进度定点量化。
///  2. 端到端往返：页面归一化 → repo.save → repo.load → 页面恢复端映射
///     （`saved.charOffset ?? -1` / `normCharOffset / 10000`）是不动点。
///  3. BUG-285 全链：同 section 的 -1 瞬态经归一化+repo 后不吃掉既有精确锚。
void main() {
  group('readerPositionSaveArgs 纯函数语义', () {
    test('charOffset >= 0 原样写精确锚', () {
      expect(
        readerPositionSaveArgs(progress: 0.5, charOffset: 777),
        (normCharOffset: 5000, charOffset: 777),
      );
      expect(
        readerPositionSaveArgs(progress: 0.0, charOffset: 0),
        (normCharOffset: 0, charOffset: 0),
      );
    });

    test('charOffset < 0（瞬态）必须映射 null，不许透传（BUG-285）', () {
      expect(
        readerPositionSaveArgs(progress: 0.25, charOffset: -1).charOffset,
        isNull,
      );
      expect(
        readerPositionSaveArgs(progress: 0.25, charOffset: -42).charOffset,
        isNull,
      );
    });

    test('进度按 0..10000 round 定点量化，端点无损', () {
      expect(
          readerPositionSaveArgs(progress: 0.0, charOffset: -1).normCharOffset,
          0);
      expect(
          readerPositionSaveArgs(progress: 1.0, charOffset: -1).normCharOffset,
          10000);
      expect(
          readerPositionSaveArgs(progress: 0.33335, charOffset: -1)
              .normCharOffset,
          3334);
    });

    test('往返误差不超过半个量化步长（1/20000）', () {
      for (final double p in <double>[0.0, 0.1234, 0.5, 0.66667, 0.9999, 1.0]) {
        final int quantized =
            readerPositionSaveArgs(progress: p, charOffset: -1).normCharOffset;
        final double restored = quantized / 10000.0;
        expect((restored - p).abs(), lessThanOrEqualTo(0.00005),
            reason: 'progress=$p 量化往返漂移超界');
      }
    });
  });

  group('端到端往返（归一化 → 真 repo → 恢复端映射）', () {
    late HibikiDatabase db;
    late ReaderPositionRepository repo;

    setUp(() {
      db = HibikiDatabase.forTesting(NativeDatabase.memory());
      repo = ReaderPositionRepository(db);
    });

    tearDown(() async {
      await db.close();
    });

    Future<void> saveVia({
      required String bookKey,
      required int section,
      required double progress,
      required int charOffset,
    }) async {
      final ({int normCharOffset, int? charOffset}) args =
          readerPositionSaveArgs(progress: progress, charOffset: charOffset);
      await repo.save(
        bookKey: bookKey,
        sectionIndex: section,
        normCharOffset: args.normCharOffset,
        charOffset: args.charOffset,
      );
    }

    test('精确锚往返不动点：save(p, c>=0) → load → (c, p±量化)', () async {
      await saveVia(
          bookKey: 'rt-book', section: 3, progress: 0.5, charOffset: 777);
      final ReaderPosition? saved = await repo.findByBookKey('rt-book');
      expect(saved, isNotNull);
      // 页面恢复端映射（_initBookInner）：charOffset ?? -1、normCharOffset/10000。
      expect(saved!.charOffset ?? -1, 777);
      expect(saved.sectionIndex, 3);
      expect(saved.normCharOffset / 10000.0, closeTo(0.5, 0.00005));
    });

    test('BUG-285 全链：同 section 原地 -1 瞬态不吃掉既有精确锚', () async {
      await saveVia(
          bookKey: 'rt-book', section: 3, progress: 0.5, charOffset: 777);
      // 重排/竖排边缘采样的瞬态：charOffset=-1，位置未移动（分数不变）。
      await saveVia(
          bookKey: 'rt-book', section: 3, progress: 0.5, charOffset: -1);
      final ReaderPosition? saved = await repo.findByBookKey('rt-book');
      expect(saved!.charOffset ?? -1, 777,
          reason: '同 section 原地瞬态 -1 → null → repo 保留既有精确锚');
      expect(saved.normCharOffset, 5000);
    });

    test('TODO-1292 全链：同 section 分数移动且无新精确锚 → 旧锚失效回退分数', () async {
      await saveVia(
          bookKey: 'rt-book', section: 3, progress: 0.5, charOffset: 777);
      // 位置真的推进了（0.5→0.6）但当帧测不到精确偏移：旧锚已陈旧，必须失效——
      // 否则恢复优先精确锚会跳回旧位置（「退出图1重进图2」的根因）。
      await saveVia(
          bookKey: 'rt-book', section: 3, progress: 0.6, charOffset: -1);
      final ReaderPosition? saved = await repo.findByBookKey('rt-book');
      expect(saved!.charOffset ?? -1, -1,
          reason: '精确锚绝不能比分数陈旧：分数移动+无新锚 ⇒ 旧锚失效');
      expect(saved.normCharOffset, 6000, reason: '分数进度照常前移，恢复回退分数粒度');
    });

    test('跨 section 后旧精确锚失效（repo 侧决策经归一化漏斗仍生效）', () async {
      await saveVia(
          bookKey: 'rt-book', section: 3, progress: 0.5, charOffset: 777);
      await saveVia(
          bookKey: 'rt-book', section: 4, progress: 0.1, charOffset: -1);
      final ReaderPosition? saved = await repo.findByBookKey('rt-book');
      expect(saved!.sectionIndex, 4);
      expect(saved.charOffset ?? -1, -1, reason: '跨 section 精确锚必须失效，恢复端回退分数粒度');
    });
  });
}
