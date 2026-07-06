import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/reader/reader_pagination_scripts.dart';

/// BUG-568 / TODO-1229 案B 源码/生成产物守卫：跳章落点冻结快照 → 图片 late-load 重锚。
///
/// backward 跳章走 restoreProgress(0.99) 落 contentLastPageScroll（restore 瞬间布局），
/// 章首懒加载 block 图 load 后整章几何后移 → 冻结 scrollTop 错一行（Chromium 只在
/// scrollTop=0 自愈）。旧图片 load 回调只失效 paginationMetrics 不重锚。
///
/// 修复：paginated restoreProgress 记录章首(0)/章末(≥0.99)重锚资格 __imgReanchorProgress；
/// 用户翻页 paginate 入口清资格（不把已翻走的位置拽回）；图片 load 回调命中资格时用
/// 刚失效的 metrics 重建几何后重放 scrollToProgressPaged 语义重锚（程序化滚动，不污染
/// TODO-798 userDriven 因果门）。
///
/// headless WebView 在 CI 跑不到，故锁死生成 JS 的关键编排结构不回退；真机 4 截图
/// 法证由集成 owner / 用户复测。
void main() {
  late String paginated;
  late String continuous;

  setUpAll(() {
    paginated = ReaderPaginationScripts.shellScript(
      initialProgress: 0.99,
      initialCharOffset: -1,
    );
    continuous = ReaderPaginationScripts.shellScript(
      continuousMode: true,
      initialProgress: 0.99,
      initialCharOffset: -1,
    );
  });

  String norm(String s) => s.replaceAll(RegExp(r'\s+'), ' ');

  group('案B：restoreProgress 记录章首/章末重锚资格', () {
    test('分页 restoreProgress 按 progress 是否 0/≥0.99 设 __imgReanchorProgress',
        () {
      final String n = norm(paginated);
      expect(
        n.contains(
            'this.__imgReanchorProgress = (progress <= 0 || progress >= 0.99) ? progress : null;'),
        isTrue,
        reason: '仅章首(0)/章末(≥0.99)粗粒度落点登记重锚资格，中段/精确锚不登记',
      );
    });
  });

  group('案B：用户翻页清资格', () {
    test('分页 paginate 入口把 __imgReanchorProgress 清 null', () {
      // paginate 入口那句紧跟 getScrollContext，锁死清资格出现在 paginator 主体前。
      final int clearIdx =
          paginated.indexOf('this.__imgReanchorProgress = null;');
      expect(clearIdx, isNonNegative, reason: '用户翻页必须放弃图片 late-load 重锚资格');
      final int paginateIdx =
          paginated.indexOf('paginate: function(direction)');
      expect(paginateIdx, isNonNegative);
      // 清资格位于 paginate 函数体开头（其后紧跟 getScrollContext / pageSize 判定）。
      final String body = paginated.substring(
        paginateIdx,
        paginated.indexOf('getFirstVisibleCharOffset', paginateIdx),
      );
      expect(body.contains('this.__imgReanchorProgress = null;'), isTrue,
          reason: 'paginate 函数体内必须清资格');
    });
  });

  group('案B：图片 load 回调命中资格时重放语义重锚', () {
    test('load 回调先失效 metrics 再按资格重放 scrollToProgressPaged', () {
      final String n = norm(paginated);
      // 失效 metrics（保留 TODO-1074 行为）
      expect(n.contains('r.paginationMetrics = null'), isTrue);
      // 命中资格判定 + 重放
      expect(
        n.contains('r.__imgReanchorProgress != null'),
        isTrue,
        reason: '仅在最近落点是章首/章末且用户未翻页时重锚',
      );
      expect(
        n.contains('r.scrollToProgressPaged(rctx, r.__imgReanchorProgress)'),
        isTrue,
        reason: '用刚失效的 metrics 重建几何后重放语义重锚',
      );
    });

    test('重放前守卫 pageSize>0（避免未就绪 context 误锚）', () {
      final String n = norm(paginated);
      expect(n.contains('rctx.pageSize > 0'), isTrue);
    });
  });

  group('案B：连续 shell 不误触（不同 restore/ paginate 路径）', () {
    test('连续 shell 的 restoreProgress 不登记 __imgReanchorProgress', () {
      // 连续版 restoreProgress 走 scrollToChapterStart / scrollToProgressContinuous，
      // 从不设 __imgReanchorProgress → 共享的图片 load 回调在连续模式 no-op。
      expect(
        norm(continuous).contains(
            'this.__imgReanchorProgress = (progress <= 0 || progress >= 0.99)'),
        isFalse,
        reason: '案B 仅分页跳章语义，连续模式不登记资格',
      );
    });
  });
}
