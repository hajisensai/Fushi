import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/reader/reader_pagination_scripts.dart';

/// TODO-1074 源码守卫：图片章加载/换章不再被「等所有 <img> decode 完」整页阻塞。
///
/// 根因 A（reader_pagination_scripts.dart `_sharedInitImages`）：旧实现给每个未完成的
/// <img> 挂 `img.onload` 才 resolve 其 Promise，`Promise.all(imagePromises).then(...)`
/// gate 住 `buildNodeOffsets` + restore + 揭开 FOUC cloak → 整章首屏/换章被最大图的
/// 全分辨率读盘+解码阻塞（文字章几乎无 <img> 故 Promise.all 立即 resolve，所以文字快
/// 图片慢）。
///
/// 修复：
///   1. 每个 <img> 加 `loading="lazy"`（视口外不预取）+ `decoding="async"`（解码离主线程）。
///   2. 未完成的图**立即不 gate** restore：`imagePromises` 恒为空数组，block-img 归类改由
///      每张图自己的 `load` 事件补做，并在补做后失效 paginationMetrics（与 TODO-627 同源）。
///
/// headless WebView 在 CI 跑不到，故源码/生成产物扫描锁死不回退；真机 profiling 占比由
/// 集成 owner / 用户复测。
void main() {
  late String paginated;
  late String continuous;

  setUpAll(() {
    paginated = ReaderPaginationScripts.shellScript(
      initialProgress: 0.0,
      initialCharOffset: 100,
    );
    continuous = ReaderPaginationScripts.shellScript(
      continuousMode: true,
      initialProgress: 0.0,
      initialCharOffset: 100,
    );
  });

  String norm(String s) => s.replaceAll(RegExp(r'\s+'), ' ');

  group('TODO-1074：<img> 懒加载 + 异步解码属性', () {
    test('分页 shell 给 <img> 加 loading="lazy"', () {
      expect(
        norm(paginated).contains("img.setAttribute('loading', 'lazy')"),
        isTrue,
        reason: '视口外图片必须 lazy，否则 window.load 仍被全部图片拖住',
      );
    });

    test('分页 shell 给 <img> 加 decoding="async"', () {
      expect(
        norm(paginated).contains("img.setAttribute('decoding', 'async')"),
        isTrue,
        reason: '异步解码让首帧不被大图全分辨率解码阻塞主线程',
      );
    });

    test('连续 shell 同样加 loading="lazy" 与 decoding="async"', () {
      final String n = norm(continuous);
      expect(n.contains("img.setAttribute('loading', 'lazy')"), isTrue);
      expect(n.contains("img.setAttribute('decoding', 'async')"), isTrue);
    });
  });

  group('TODO-1074：restore 不再 gate 在全部 <img> onload', () {
    test('imagePromises 为空数组（不再逐图 onload 才 resolve）', () {
      // 旧实现：var imagePromises = Array.from(...).map(... new Promise(... img.onload=mark));
      // 修复后：restore 不等未完成图，imagePromises 恒空 → Promise.all 立即 resolve。
      expect(
        norm(paginated).contains('var imagePromises = [];'),
        isTrue,
        reason: 'restore/buildNodeOffsets 只能等已完成图（瞬时），未完成图不得 gate',
      );
      expect(
        norm(continuous).contains('var imagePromises = [];'),
        isTrue,
      );
    });

    test('不再把 img.onload 塞进 imagePromises 的 Promise（不得逐图阻塞 resolve）', () {
      // 负向：旧的「img.onload = mark;」+ new Promise(function(resolve){...resolve()})
      // 组合已删。block-img 归类改走 addEventListener('load', ...)（不进 imagePromises）。
      expect(
        paginated.contains('img.onload = mark'),
        isFalse,
        reason: '旧的逐图 onload gate（阻塞 Promise.all）必须删除',
      );
      expect(
        continuous.contains('img.onload = mark'),
        isFalse,
      );
    });

    test('Promise.all(imagePromises).then 仍在（保留 restore/metrics 失效编排壳）', () {
      // 保留消费点，只是 imagePromises 现在为空立即 resolve —— 不动 restore/sasayaki/
      // paginationMetrics=null 的编排结构（最小改面）。
      expect(
        paginated.contains('Promise.all(imagePromises).then('),
        isTrue,
      );
      expect(
        continuous.contains('Promise.all(imagePromises).then('),
        isTrue,
      );
    });
  });

  group('TODO-1074：延迟归类的图 load 后失效 paginationMetrics（TODO-627 同源）', () {
    test('未完成图挂 load 监听补做 block-img 归类', () {
      expect(
        norm(paginated).contains("img.addEventListener('load', function()"),
        isTrue,
        reason: '未完成图真正 load 后必须补做 block-img 归类（懒图滚进视口才 load）',
      );
    });

    test('补做归类后失效 paginationMetrics 强制几何重建', () {
      // 与 initialize() 里 TODO-627 的 `paginationMetrics = null` 同源：图真实尺寸
      // 到位后必须让下次 paginate 重建几何，否则漏掉图片所占列 → 误判末页跳章。
      final String n = norm(paginated);
      expect(
        n.contains('r.paginationMetrics = null'),
        isTrue,
        reason: '延迟归类命中后失效 metrics，避免图未撑开时的过小 maxScroll 误判',
      );
    });
  });

  group('TODO-1074：不破坏 BUG-025 SVG 封面同步 block-img', () {
    test('SVG 封面仍走同步 querySelectorAll(\'svg\') 分支（无 onload 依赖）', () {
      // <svg><image> 封面尺寸取属性/viewBox，同步归类；本次只动 <img> 的 promise，
      // 不触及 svg 分支 → BUG-025 行为不变。
      expect(
        paginated.contains("document.querySelectorAll('svg')"),
        isTrue,
      );
      expect(
        paginated.contains("svg.classList.add('block-img')"),
        isTrue,
        reason: '大 SVG 封面仍同步升级为 block-img（BUG-025 不回退）',
      );
    });
  });
}
