import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/manga/manga_overlay_html.dart';
import 'package:hibiki/src/media/manga/manga_reading_mode.dart';
import 'package:hibiki/src/media/manga/mokuro_payload.dart';
import 'package:hibiki/src/reader/reader_selection_scripts.dart';

MokuroImage _pageWithTwoBlocks() {
  return const MokuroImage(
    url: 'p001.jpg',
    size: Size(1000, 2000),
    blocks: <MokuroBlock>[
      MokuroBlock(
        rectangle: Rect.fromLTWH(100, 200, 300, 400),
        isVertical: true,
        fontSize: 32,
        zIndex: 0,
        lines: <String>['一行目', '二行目'],
      ),
      MokuroBlock(
        rectangle: Rect.fromLTWH(500, 600, 200, 100),
        isVertical: false,
        fontSize: 24,
        zIndex: 1,
        lines: <String>['横書き'],
      ),
    ],
  );
}

void main() {
  group('mangaOcrBoxesHtml', () {
    test('每个 block 生成一个 <p class="ocr-box">', () {
      final String html = mangaOcrBoxesHtml(_pageWithTwoBlocks());
      final int count = '<p class="ocr-box"'.allMatches(html).length;
      expect(count, 2, reason: '两个 block 应生成两个 ocr-box <p>');
    });

    test('多行用 <br> 分隔，绝不含字面 \\n 作行分隔', () {
      final String html = mangaOcrBoxesHtml(_pageWithTwoBlocks());
      // 竖排框两行之间必须是 <br>
      expect(html.contains('一行目<br>二行目'), isTrue, reason: '框内多行必须用 <br> 连接');
      // 行内文本绝不能出现裸换行符（\n 是 scanDelimiter，会截断扫描）
      expect(html.contains('一行目\n二行目'), isFalse);
      expect(html.contains('一行目\\n二行目'), isFalse);
    });

    test('scanDelimiters 契约：换行符 \\n 在扫描分隔集里（故必须用 <br>）', () {
      // develop 的 ReaderSelectionScripts.scanDelimiters 是含 `\n` 的大标点集；
      // 若覆盖层用裸 `\n` 连接跨行文本，扫描会在换行处截断跨行长词。这里锚定该
      // 契约：源码含 scanDelimiters 且包含换行符，佐证覆盖层用 <br> 的必要性。
      final String scripts = ReaderSelectionScripts.source();
      expect(scripts.contains('scanDelimiters'), isTrue,
          reason: '选区脚本应定义 scanDelimiters（扫描分隔集）');
      expect(scripts.contains(r'\n'), isTrue,
          reason: 'scanDelimiters 含换行 → 覆盖层必须用 <br> 而非 \\n');
      // BLOCK_SELECTOR 认 p → <p class="ocr-box"> 能被 findParagraph 命中为块。
      expect(RegExp(r'BLOCK_SELECTOR:\s*.p[,\x27]').hasMatch(scripts), isTrue,
          reason: 'BLOCK_SELECTOR 必须含 p（覆盖层块级 <p> 才会被命中）');
    });

    test('坐标按百分比换算（box / page.size）', () {
      final String html = mangaOcrBoxesHtml(_pageWithTwoBlocks());
      // block1: left=100/1000=10%, top=200/2000=10%, width=300/1000=30%, height=400/2000=20%
      expect(html.contains('left:10%'), isTrue);
      expect(html.contains('top:10%'), isTrue);
      expect(html.contains('width:30%'), isTrue);
      expect(html.contains('height:20%'), isTrue);
    });

    test('字号用容器查询单位 cqi（ERRATA H5），绝不用 font-size:% ', () {
      final String html = mangaOcrBoxesHtml(_pageWithTwoBlocks());
      // H5: font-size:% 相对父字号会塌缩让点击全 miss → 改用容器相对单位。
      // 用 cqi（inline-size 容器单位）而非 cqh：cqh 需 size containment，会塌缩
      // img 驱动的页高、两框重叠串字（设备实测过）。block0: fontSize 32 /
      // img_width 1000 * 100 = 3.2cqi。
      expect(html.contains('cqi'), isTrue, reason: 'OCR 框字号必须用容器查询单位 cqi');
      // 绝不能出现 font-size:<数字>%（相对父字号会塌缩）
      expect(RegExp(r'font-size:\s*[\d.]+%').hasMatch(html), isFalse,
          reason: '字号绝不能用百分比（相对父字号）');
      expect(html.contains('font-size:3.2cqi'), isTrue,
          reason: 'block0 字号应为 32/1000*100=3.2cqi');
    });

    test('font_size==0 不塌缩：用非零下限 cqi（ERRATA M1）', () {
      // mokuro 偶尔给 font_size==0 → font-size:0cqi 会把透明文字塌成 0 高、整框
      // 命中区域塌缩到原点点框全 miss。须落地非零下限（3cqi）。
      const MokuroImage page = MokuroImage(
        url: 'p.jpg',
        size: Size(1000, 1000),
        blocks: <MokuroBlock>[
          MokuroBlock(
            rectangle: Rect.fromLTWH(0, 0, 500, 500),
            isVertical: false,
            fontSize: 0, // ← 缺字段容错回退
            zIndex: 0,
            lines: <String>['あ'],
          ),
        ],
      );
      final String html = mangaOcrBoxesHtml(page);
      expect(html.contains('font-size:0cqi'), isFalse,
          reason: 'font_size==0 绝不能写出 font-size:0cqi（塌缩）');
      expect(html.contains('font-size:3cqi'), isTrue,
          reason: 'font_size==0 应回退到非零下限 3cqi');
    });

    test('竖排框带 writing-mode:vertical-rl，横排框不带', () {
      final String html = mangaOcrBoxesHtml(_pageWithTwoBlocks());
      expect('writing-mode:vertical-rl'.allMatches(html).length, 1,
          reason: '仅竖排 block 应带 vertical-rl');
    });

    test('文字 transparent + margin/padding 清零 + pointer-events:auto', () {
      final String html = mangaOcrBoxesHtml(_pageWithTwoBlocks());
      expect(html.contains('color:transparent'), isTrue);
      expect(html.contains('margin:0'), isTrue);
      expect(html.contains('padding:0'), isTrue);
      expect(html.contains('pointer-events:auto'), isTrue);
    });

    test('HTML 特殊字符转义（< > & 不破坏结构）', () {
      const MokuroImage page = MokuroImage(
        url: 'p.jpg',
        size: Size(100, 100),
        blocks: <MokuroBlock>[
          MokuroBlock(
            rectangle: Rect.fromLTWH(0, 0, 10, 10),
            isVertical: false,
            fontSize: 10,
            zIndex: 0,
            lines: <String>['a<b>&c'],
          ),
        ],
      );
      final String html = mangaOcrBoxesHtml(page);
      expect(html.contains('a&lt;b&gt;&amp;c'), isTrue,
          reason: '行文本里的 < > & 必须转义');
    });
  });

  group('mangaPageDivHtml', () {
    test(
        '包 <div class="manga-page"> + container-type:inline-size + <img '
        'pointer-events:none> + 框', () {
      final String html =
          mangaPageDivHtml(_pageWithTwoBlocks(), 'manga.local/0/p001.jpg');
      expect(html.contains('<div class="manga-page"'), isTrue);
      // H5: 容器查询上下文必须在 .manga-page 上（cqi 才有参照宽）。用 inline-size
      // 而非 size（size 会塌缩 img 驱动的页高、两框重叠串字）。
      expect(html.contains('container-type:inline-size'), isTrue,
          reason: '.manga-page 必须声明 container-type:inline-size 供 cqi 参照');
      expect(html.contains('src="manga.local/0/p001.jpg"'), isTrue);
      // 底图必须 pointer-events:none（点裸图→放大，点框→查词，互斥命中）
      expect(
        RegExp(r'<img[^>]*pointer-events\s*:\s*none').hasMatch(html),
        isTrue,
        reason: '底图 <img> 必须 pointer-events:none',
      );
      expect(html.contains('<p class="ocr-box"'), isTrue);
    });

    // CRITICAL-1：spread 槽宽驱动——单页 100vw、双页每页 50vw，跨页单元横向恒占
    // 100vw（绝不横向溢出被裁）；高由 aspect-ratio 推。
    test('spread 单页 → width:100vw（跨页单元恰占 100vw）', () {
      final String html = mangaPageDivHtml(_pageWithTwoBlocks(), 'p.jpg',
          pagesInSpread: 1, isWebtoon: false);
      expect(html.contains('width:100vw'), isTrue,
          reason: 'spread 单页槽宽必须是 100vw');
      // 不再用 height:100vh 驱动（旧几何竖版页宽=100vh*(w/h)>100vw 被裁）。
      expect(html.contains('height:100vh'), isFalse,
          reason: 'spread 页不再用 height:100vh 驱动（改宽驱动）');
      expect(html.contains('aspect-ratio:'), isTrue,
          reason: '高由 aspect-ratio 从 definite 宽推出');
    });

    test('spread 双页 → 每页 width:50vw（两页合计 100vw 并排）', () {
      final String html = mangaPageDivHtml(_pageWithTwoBlocks(), 'p.jpg',
          pagesInSpread: 2, isWebtoon: false);
      expect(html.contains('width:50vw'), isTrue,
          reason: 'spread 双页每页槽宽必须是 50vw（两页 100vw 并排，右页不移出屏）');
      expect(html.contains('width:100vw'), isFalse);
    });

    test('webtoon → .manga-page div 不内联 width（宽由 style 块 width:100vw 给）', () {
      // 用无 OCR 框的页：OCR 框自带 width:% 会干扰「div 是否内联 width」的判定。
      const MokuroImage blank = MokuroImage(
          url: 'p.jpg', size: Size(800, 1200), blocks: <MokuroBlock>[]);
      final String html =
          mangaPageDivHtml(blank, 'p.jpg', pagesInSpread: 1, isWebtoon: true);
      // .manga-page div 的 style 不含 vw 宽（webtoon 宽由外部 style 块给）。
      expect(html.contains('width:100vw'), isFalse,
          reason: 'webtoon 页 div 不应内联 width:100vw');
      expect(html.contains('width:50vw'), isFalse);
      expect(html.contains('aspect-ratio:'), isTrue);
      // webtoon 底图必须 lazy 加载（整书单文档，避免一次性解码全卷）。
      expect(html.contains('loading="lazy"'), isTrue,
          reason: 'webtoon <img> 必须 loading="lazy"');
    });
  });

  group('mangaWindowDocument', () {
    test('spread RTL → flex-row + direction:rtl，内联选词 JS + null-guard', () {
      final MokuroImage page = _pageWithTwoBlocks();
      final String doc = mangaWindowDocument(
        <MokuroImage>[page],
        <String>['manga.local/0/p001.jpg'],
        mode: MangaReadingMode.spread,
        spreadDirection: 'rtl',
        inlineSelectionJs: ReaderSelectionScripts.source(),
      );
      expect(doc.contains('<!DOCTYPE html>'), isTrue);
      expect(doc.contains('flex-direction:row'), isTrue);
      expect(doc.contains('direction:rtl'), isTrue);
      // 内联选词 JS 源进文档
      expect(doc.contains('window.hoshiSelection'), isTrue);
      // 调 selectText 前必须 null-guard bridge
      expect(doc.contains('window.flutter_inappwebview'), isTrue);
      // ERRATA C1: 唯一一个 pointerup 监听，调 selectText 带 maxLength=40 +
      // fromHover=false（对齐 develop 四参签名 TODO-851）。
      expect('selectText('.allMatches(doc).length, 1,
          reason: '全文档恰好一处 selectText 调用（唯一 pointerup 监听）');
      expect(
          RegExp(r'hoshiSelection\.selectText\([^)]*,\s*40,\s*false\)')
              .hasMatch(doc),
          isTrue,
          reason: 'selectText 必须带 maxLength=40 + fromHover=false（四参），'
              '漏 maxLength 扫描 gate 恒假查词哑火');
      // 唯一一个 pointerup 监听
      expect('pointerup'.allMatches(doc).length, 1,
          reason: '全文档恰好一个 pointerup 监听（C1 收敛不变式）');
    });

    test('spread 视口裁剪 + translateX 翻页机（ERRATA C1）', () {
      final MokuroImage page = _pageWithTwoBlocks();
      final String doc = mangaWindowDocument(
        <MokuroImage>[page, page],
        <String>['a.jpg', 'b.jpg'],
        mode: MangaReadingMode.spread,
        spreadDirection: 'rtl',
        inlineSelectionJs: ReaderSelectionScripts.source(),
        pageSpreadIndices: <int>[0, 1],
        currentSpread: 1,
      );
      // 外层固定视口 overflow:hidden（只显示当前跨页）。
      expect(doc.contains('#manga-viewport{overflow:hidden'), isTrue,
          reason: 'spread 必须有 overflow:hidden 视口裁剪');
      expect(doc.contains('id="manga-viewport"'), isTrue);
      // strip 用 translateX 平移；翻页机 + 恢复定位函数存在。
      expect(doc.contains('__mangaApplyTranslate'), isTrue,
          reason: 'spread 必须有 translateX 定位函数');
      expect(doc.contains('translateX'), isTrue);
      // 翻页手势报 onMangaTurn。
      expect(doc.contains('onMangaTurn'), isTrue,
          reason: 'spread swipe 必须报 onMangaTurn');
      // 恢复定位用到 currentSpread=1。
      expect(RegExp(r'CURRENT\s*=\s*1').hasMatch(doc), isTrue,
          reason: '恢复定位必须用 currentSpread');
      // 每页带 data-spread 标注（供 JS 按跨页分组）。
      expect(doc.contains('data-spread="0"'), isTrue);
      expect(doc.contains('data-spread="1"'), isTrue);
    });

    test('点裸图（框间）报 onImageTap，点框走 selectText（ERRATA H1 + 收敛不变式）', () {
      final MokuroImage page = _pageWithTwoBlocks();
      final String doc = mangaWindowDocument(
        <MokuroImage>[page],
        <String>['p.jpg'],
        mode: MangaReadingMode.spread,
        spreadDirection: 'rtl',
        inlineSelectionJs: ReaderSelectionScripts.source(),
        pageSpreadIndices: <int>[0],
      );
      // H1：未命中 ocr-box 时取 .manga-page 的 img.src 报 onImageTap。
      expect(doc.contains('onImageTap'), isTrue,
          reason: '点裸图必须报 onImageTap（H1 图片放大）');
      // 收敛不变式：OCR 选词 selectText 调用仍恰好一处（手势机不重复触发选词）。
      expect('selectText('.allMatches(doc).length, 1,
          reason: '全文档恰好一处 selectText 调用（选词路径唯一）');
      expect(
          RegExp(r'hoshiSelection\.selectText\([^)]*,\s*40,\s*false\)')
              .hasMatch(doc),
          isTrue,
          reason: 'selectText 必须带 maxLength=40 + fromHover=false（四参）');
      // 收敛不变式：恰好一个 pointerup 监听。
      expect("addEventListener('pointerup'".allMatches(doc).length, 1,
          reason: '全文档恰好一个 pointerup 监听（C1 收敛不变式）');
    });

    test('webtoon → 竖向堆叠（column）', () {
      final MokuroImage page = _pageWithTwoBlocks();
      final String doc = mangaWindowDocument(
        <MokuroImage>[page],
        <String>['manga.local/0/p001.jpg'],
        mode: MangaReadingMode.webtoon,
        spreadDirection: 'rtl',
        inlineSelectionJs: ReaderSelectionScripts.source(),
      );
      expect(doc.contains('flex-direction:column'), isTrue);
      // webtoon 滚动近边缘报 onMangaScroll（ERRATA C1）。
      expect(doc.contains('onMangaScroll'), isTrue,
          reason: 'webtoon 滚动必须报 onMangaScroll');
      // webtoon 不裁 spread 视口（靠文档竖滚）。
      expect(doc.contains('#manga-viewport{overflow:hidden'), isFalse,
          reason: 'webtoon 不应有 spread 视口裁剪');
      // webtoon 模式不报 spread 翻页。
      expect(doc.contains('onMangaTurn'), isTrue,
          reason: '手势机仍内联（IS_WEBTOON 闸门内部不触发翻页）');
    });

    // CRITICAL-1（文档级）：双页跨页两页各 50vw（并排 100vw），viewport 锁高 + 行内
    // 居中；单页跨页 100vw。pagesPerSpread 与 pages 等长，逐页驱动槽宽。
    test('spread 双页跨页：两页各 50vw + viewport 居中（CRITICAL-1）', () {
      final MokuroImage page = _pageWithTwoBlocks();
      final String doc = mangaWindowDocument(
        <MokuroImage>[page, page],
        <String>['a.jpg', 'b.jpg'],
        mode: MangaReadingMode.spread,
        spreadDirection: 'rtl',
        inlineSelectionJs: '',
        pageSpreadIndices: <int>[0, 0],
        pagesPerSpread: <int>[2, 2], // 同一双页跨页
      );
      expect('width:50vw'.allMatches(doc).length, 2,
          reason: '双页跨页两页都应是 50vw（合计 100vw 并排，右页不移出屏）');
      // viewport 锁高 100vh，行内居中（竖版长页上下留白而非裁切）。
      expect(doc.contains('#manga-viewport{overflow:hidden'), isTrue);
      expect(doc.contains('align-items:center'), isTrue,
          reason: 'spread strip 必须 align-items:center 让页在视口内垂直居中');
      // 不再让 .manga-page 锁 height:100vh（旧几何裁竖版页）。
      expect(RegExp(r'\.manga-page\{height:100vh').hasMatch(doc), isFalse);
    });

    test('spread 单页跨页：页占 100vw（CRITICAL-1）', () {
      final MokuroImage page = _pageWithTwoBlocks();
      final String doc = mangaWindowDocument(
        <MokuroImage>[page, page],
        <String>['a.jpg', 'b.jpg'],
        mode: MangaReadingMode.spread,
        spreadDirection: 'ltr',
        inlineSelectionJs: '',
        pageSpreadIndices: <int>[0, 1],
        pagesPerSpread: <int>[1, 1], // 两个独立单页跨页
      );
      // 至少两处页槽 100vw（两个单页跨页）。viewport 自身也是 100vw，故 >=3。
      expect('width:100vw'.allMatches(doc).length >= 2, isTrue,
          reason: '两个单页跨页应各占 100vw');
    });

    // HIGH-1：webtoon scroll 报**页内** fraction（(scrollY-offsetTop)/offsetHeight），
    // 与 __mangaScrollToSpread 恢复口径统一；绝非文档全局 y/docH。
    test('webtoon scroll 报页内 fraction（HIGH-1），非文档全局', () {
      final MokuroImage page = _pageWithTwoBlocks();
      final String doc = mangaWindowDocument(
        <MokuroImage>[page, page],
        <String>['a.jpg', 'b.jpg'],
        mode: MangaReadingMode.webtoon,
        spreadDirection: 'rtl',
        inlineSelectionJs: '',
      );
      // 页内归一化：(y - page.offsetTop) / page.offsetHeight。
      expect(doc.contains('pages[i].offsetTop'), isTrue,
          reason: 'fraction 必须按视口顶部所在页的 offsetTop 算页内偏移');
      expect(doc.contains('pages[i].offsetHeight'), isTrue,
          reason: 'fraction 分母必须是该页 offsetHeight（页内口径）');
      // 旧的文档全局口径（scrollHeight - vh 当分母）必须移除。
      expect(doc.contains('scrollHeight - vh'), isFalse,
          reason: 'webtoon fraction 不得再用文档全局口径（scrollHeight-vh）');
      // 恢复函数仍按页内 fraction 微调。
      expect(doc.contains('__mangaScrollToSpread'), isTrue);
      expect(doc.contains('page.offsetTop + (fraction'), isTrue,
          reason: '恢复定位必须 page.offsetTop + fraction*page.offsetHeight（同口径）');
    });

    // BUG-051：桌面鼠标三种自然操作（滚轮/拖动/键盘）在 spread 模式全失效。
    // ① spread 必须监听 wheel→onMangaTurn（overflow:hidden 视口下滚轮本是死操作，
    //    复用为桌面 swipe 等价物）；② webtoon 不接 wheel→翻页（保留原生竖滚）；
    // ③ 禁用 user-select/user-drag + dragstart preventDefault，消除拖动残影「秃瓢」。
    test('spread 接 wheel→onMangaTurn 且 IS_WEBTOON=false 闸门放行（BUG-051）', () {
      final MokuroImage page = _pageWithTwoBlocks();
      final String doc = mangaWindowDocument(
        <MokuroImage>[page, page],
        <String>['a.jpg', 'b.jpg'],
        mode: MangaReadingMode.spread,
        spreadDirection: 'rtl',
        inlineSelectionJs: '',
        pageSpreadIndices: <int>[0, 1],
      );
      // wheel 监听内联存在，且被 `if (!IS_WEBTOON) {` 闸门包裹（闸门在监听注册之前）。
      final int gateIdx = doc.indexOf('if (!IS_WEBTOON) {');
      final int wheelIdx = doc.indexOf("addEventListener('wheel'");
      expect(gateIdx >= 0, isTrue, reason: 'wheel 必须有 if(!IS_WEBTOON) 闸门');
      expect(wheelIdx > gateIdx, isTrue,
          reason: 'wheel 监听必须在 !IS_WEBTOON 闸门之内');
      // spread → IS_WEBTOON=false → 运行时闸门放行，滚轮翻页生效。
      expect(doc.contains('var IS_WEBTOON = false'), isTrue,
          reason: 'spread 必须 IS_WEBTOON=false（滚轮翻页生效）');
      // wheel 回调必须 preventDefault（overflow:hidden 视口下消除无操作反馈）并按
      // deltaY 符号报 next/prev。
      expect(doc.contains('e.preventDefault()'), isTrue);
      expect(doc.contains("d > 0 ? 'next' : 'prev'"), isTrue,
          reason: 'wheel 必须按滚动方向报 next/prev');
    });

    test('webtoon IS_WEBTOON=true 运行时跳过 wheel→翻页（保留原生竖滚，BUG-051）', () {
      final MokuroImage page = _pageWithTwoBlocks();
      final String doc = mangaWindowDocument(
        <MokuroImage>[page, page],
        <String>['a.jpg', 'b.jpg'],
        mode: MangaReadingMode.webtoon,
        spreadDirection: 'rtl',
        inlineSelectionJs: '',
      );
      // wheel 源码内联（与 onMangaTurn 同样常驻），但 IS_WEBTOON=true 让
      // if(!IS_WEBTOON) 闸门在运行时跳过滚轮翻页 → 不抢 WebView 原生竖滚。
      expect(doc.contains('var IS_WEBTOON = true'), isTrue,
          reason: 'webtoon 必须 IS_WEBTOON=true（运行时跳过滚轮翻页闸门）');
    });

    test('spread + webtoon 都禁用原生选区/拖拽残影「秃瓢」（BUG-051）', () {
      final MokuroImage page = _pageWithTwoBlocks();
      for (final MangaReadingMode mode in <MangaReadingMode>[
        MangaReadingMode.spread,
        MangaReadingMode.webtoon,
      ]) {
        final String doc = mangaWindowDocument(
          <MokuroImage>[page],
          <String>['a.jpg'],
          mode: mode,
          spreadDirection: 'rtl',
          inlineSelectionJs: '',
        );
        // 文字选区禁用（查词走坐标式 DOM 读取，不依赖原生选区，故安全）。
        expect(doc.contains('user-select:none'), isTrue,
            reason: '$mode：必须禁用原生文字选区');
        // 图片拖拽禁用 + dragstart 兜底 preventDefault。
        expect(doc.contains('user-drag:none'), isTrue,
            reason: '$mode：必须禁用原生图片拖拽');
        expect(
            RegExp(r"addEventListener\(\s*'dragstart'").hasMatch(doc), isTrue,
            reason: '$mode：必须 preventDefault dragstart 兜底消除残影');
      }
    });

    test('spread RTL 页序：direction:rtl 让 flex-row 从右往左排（首页贴右）', () {
      final MokuroImage page = _pageWithTwoBlocks();
      final String docRtl = mangaWindowDocument(
        <MokuroImage>[page, page],
        <String>['a.jpg', 'b.jpg'],
        mode: MangaReadingMode.spread,
        spreadDirection: 'rtl',
        inlineSelectionJs: '',
      );
      // RTL：DOM 顺序不变（a 在前 b 在后），靠 CSS direction:rtl 翻转视觉左右。
      expect(docRtl.indexOf('a.jpg') < docRtl.indexOf('b.jpg'), isTrue);
      expect(docRtl.contains('direction:rtl'), isTrue);

      final String docLtr = mangaWindowDocument(
        <MokuroImage>[page, page],
        <String>['a.jpg', 'b.jpg'],
        mode: MangaReadingMode.spread,
        spreadDirection: 'ltr',
        inlineSelectionJs: '',
      );
      expect(docLtr.contains('direction:ltr'), isTrue);
      expect(docLtr.contains('direction:rtl'), isFalse);
    });
  });
}
