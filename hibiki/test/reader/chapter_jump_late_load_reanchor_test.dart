import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/reader/reader_pagination_scripts.dart';

/// BUG-568 / TODO-1229 案B + BUG-1140 第二轮 源码/生成产物守卫：
/// 恢复落点冻结快照 → 图片 late-load 语义重锚。
///
/// 恢复把「章内语义锚」换算成 scrollTop 的那一步依赖当下几何。锚之前若有尚未 load 的
/// 懒图（0×0），换算结果就少了那些图的高度；图片随后 load、几何后移，冻结的 scrollTop
/// 便指向别的内容（Chromium 只在 scrollTop=0 自愈），随后 onReaderScroll 还会把这个漂
/// 掉的读数落库。
///
/// 案B 初版只覆盖分页 shell 的章首(0)/章末(≥0.99) 粗粒度 progress。BUG-1140 第二轮把
/// `loading="lazy"` 提前写进 HTML 源码（webview.part.dart `markImagesLazy`），恢复从此
/// **必然**跑在图片 decode 之前，于是覆盖面必须扩到全部恢复入口：
///   - 中段 progress（旧存档无精确锚）
///   - 精确字符锚 restoreToCharOffset（退出重进 / 收藏跳转 / 有声书 seek 落中段）
///   - fragment 跳转（目录 / 内链）
///   - 连续 shell 的同名三条路径
///
/// 用户翻页 (paginate) 清资格（不把已翻走的位置拽回）；图片 load 回调命中资格时先失效
/// metrics 再按**同一个语义锚**重算落点（程序化滚动，不污染 TODO-798 userDriven 因果门）。
///
/// headless WebView 在 CI 跑不到，故锁死生成 JS 的关键编排结构不回退；真机法证由集成
/// owner / 用户复测。
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

  /// 取 [src] 中从 [start] 标记起、到下一个顶层方法名 [end] 之前的函数体。
  String bodyBetween(String src, String start, String end) {
    final int i = src.indexOf(start);
    expect(i, isNonNegative, reason: '生成脚本必须含 $start');
    final int j = src.indexOf(end, i);
    expect(j, greaterThan(i), reason: '$start 之后必须能找到 $end');
    return src.substring(i, j);
  }

  group('重锚资格：三种语义锚都登记（BUG-1140 第二轮）', () {
    test('分页 restoreProgress 登记 progress（含中段，不再只 0/0.99）', () {
      final String body = bodyBetween(
          paginated, 'restoreProgress: async function', 'restoreToCharOffset:');
      expect(
        norm(body)
            .contains('this.registerImageLateAnchor({progress: progress})'),
        isTrue,
        reason: '恢复跑在图片 decode 之前后，中段 progress 同样会被后 load 的图顶走',
      );
      // 负向：旧的「只登记 0/0.99」条件表达式必须已消失。
      expect(
        norm(paginated).contains(
            'this.__imgReanchorProgress = (progress <= 0 || progress >= 0.99)'),
        isFalse,
        reason: '旧的窄资格判定必须被 registerImageLateAnchor 取代',
      );
    });

    test('分页 restoreToCharOffset 精确锚登记 charOffset', () {
      final String body = bodyBetween(paginated,
          'restoreToCharOffset: async function', 'alignToFragmentTarget:');
      final String n = norm(body);
      expect(n.contains('this.scrollToCharOffset(charOffset);'), isTrue);
      expect(
        n.contains('this.registerImageLateAnchor({charOffset: charOffset})'),
        isTrue,
        reason: '字符锚是布局无关真相，图 load 后必须按同一个 charOffset 重算',
      );
      expect(n.contains('this.registerImageLateAnchor({progress: 0})'), isTrue,
          reason: '越界/<=0 回退章首的分支同样要登记（章首前导插图会下推正文）');
    });

    test('分页 jumpToFragment 登记 fragment 并复用同一份对齐换算', () {
      final String n = norm(paginated);
      expect(n.contains('alignToFragmentTarget: function(fragment)'), isTrue,
          reason: 'fragment 对齐必须抽成共享方法，重锚不得复制一份会漂开的算法');
      expect(
        n.contains('this.registerImageLateAnchor({fragment: fragment})'),
        isTrue,
      );
      expect(n.contains('if (!this.alignToFragmentTarget(fragment))'), isTrue,
          reason: 'jumpToFragment 必须走共享对齐方法');
    });

    test('连续 shell 三条恢复路径同样登记', () {
      final String n = norm(continuous);
      expect(n.contains('this.registerImageLateAnchor({progress: 0})'), isTrue,
          reason: '连续章首/越界回退登记');
      expect(
        n.contains('this.registerImageLateAnchor({progress: progress})'),
        isTrue,
        reason: '连续章末(≥0.99) 与中段登记',
      );
      expect(
        n.contains(
            'this.registerImageLateAnchor( {charOffset: charOffset, endCharOffset: endCharOffset})'),
        isTrue,
        reason: '连续精确锚必须连句尾锚一起登记（BUG-461 整句区间对齐）',
      );
      expect(
        n.contains('this.registerImageLateAnchor({fragment: fragment})'),
        isTrue,
      );
    });
  });

  group('用户翻页清资格', () {
    for (final MapEntry<String, String> e in <String, String>{
      '分页': 'paginated',
      '连续': 'continuous',
    }.entries) {
      test('${e.key} paginate 入口清资格', () {
        final String src = e.value == 'paginated' ? paginated : continuous;
        final String body = bodyBetween(
            src, 'paginate: function(direction)', 'getFirstVisibleCharOffset');
        expect(body.contains('this.clearImageLateAnchor();'), isTrue,
            reason: '用户翻页必须放弃图片 late-load 重锚资格');
      });
    }

    test('clearImageLateAnchor 清掉全部三种锚（不留半个活锚）', () {
      final String body = bodyBetween(
          paginated, 'clearImageLateAnchor: function', '_isContinuousShell:');
      for (final String field in <String>[
        '__imgReanchorProgress',
        '__imgReanchorCharOffset',
        '__imgReanchorCharOffsetEnd',
        '__imgReanchorFragment',
      ]) {
        expect(body.contains(field), isTrue, reason: '$field 必须被清');
      }
    });
  });

  group('图片 load 回调：失效 metrics + 按语义锚重算', () {
    test('load 回调先失效 metrics 再调 reapplyImageLateAnchor', () {
      final String n = norm(paginated);
      expect(n.contains('r.paginationMetrics = null'), isTrue);
      expect(n.contains('r.reapplyImageLateAnchor()'), isTrue,
          reason: '迟到图片 load 必须触发语义重锚，而不是只失效 metrics');
    });

    test('reapply 分派：char 锚优先 → fragment → progress', () {
      final String body = bodyBetween(
          paginated,
          'reapplyImageLateAnchor: function',
          'notifyRestoreComplete: function');
      final String n = norm(body);
      final int charIdx = n.indexOf('this.scrollToCharOffset(co)');
      final int fragIdx = n.indexOf('this.alignToFragmentTarget(');
      final int progIdx = n.indexOf('this.scrollToProgressPaged(rctx, p)');
      expect(charIdx, isNonNegative);
      expect(fragIdx, greaterThan(charIdx), reason: '精确字符锚必须优先于 fragment');
      expect(progIdx, greaterThan(fragIdx), reason: '粗粒度 progress 是最后的兜底');
      expect(n.contains('rctx.pageSize <= 0'), isTrue,
          reason: '重放前守卫 pageSize>0（避免未就绪 context 误锚）');
    });

    test('连续 / 分页分派用 scrollToChapterEnd 判别 shell（不能用共享方法）', () {
      final String body = bodyBetween(
          paginated, '_isContinuousShell: function', 'reapplyImageLateAnchor:');
      expect(body.contains("typeof this.scrollToChapterEnd === 'function'"),
          isTrue,
          reason:
              'scrollToProgressPaged 是 _sharedJs 两 shell 都有的，用它判别会让连续误走分页分支');
    });
  });
}
