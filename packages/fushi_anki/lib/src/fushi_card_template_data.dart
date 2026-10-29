// GENERATED FILE — DO NOT EDIT.
// 源文件：packages/fushi_anki/templates/fushi_card/{front.html,back.html,styling.css}
// 重新生成：在 packages/fushi_anki/ 下 dart run tool/gen_fushi_card_template.dart

/// Fushi 卡片模板 · 正面。
const String kFushiCardFrontTemplate = r'''<!--
  Fushi 卡片 · 正面。字段名与 Lapis 逐字一致；卡型开关沿用 Lapis 语义（IsSentenceCard /
  IsWordAndSentenceCard / IsClickCard / IsAudioCard 都为空 = 单词卡）。
  外观由 Fushi 宿主经 --fushi-srs-* 变量与 fushi-srs-* 类名注入；在 Anki 里没有宿主，按默认外观显示。
-->
<div class="fc fc-front" lang="ja">
  {{#FrequencyRank}}<div class="fc-front-freq"><span class="fc-chip fc-chip--freq">{{FrequencyRank}}</span></div>{{/FrequencyRank}}

  {{^IsSentenceCard}}{{^IsWordAndSentenceCard}}{{^IsClickCard}}{{^IsAudioCard}}
  <div class="fc-front-term">
    <div class="fc-term fc-term--hero fc-term--plain">{{Term}}</div>
    {{#TermFurigana}}<div class="fc-term fc-term--hero fc-term--ruby">{{furigana:TermFurigana}}</div>{{/TermFurigana}}
    <div class="fc-front-pitch">{{PitchPosition}}</div>
  </div>
  {{/IsAudioCard}}{{/IsClickCard}}{{/IsWordAndSentenceCard}}{{/IsSentenceCard}}

  {{#IsSentenceCard}}
  <div class="fc-front-sentence">{{kanji:Sentence}}</div>
  {{/IsSentenceCard}}

  {{#IsWordAndSentenceCard}}
  <div class="fc-front-term">
    <div class="fc-term fc-term--hero fc-term--plain">{{Term}}</div>
    {{#TermFurigana}}<div class="fc-term fc-term--hero fc-term--ruby">{{furigana:TermFurigana}}</div>{{/TermFurigana}}
    <div class="fc-front-pitch">{{PitchPosition}}</div>
  </div>
  <div class="fc-front-context">{{kanji:Sentence}}</div>
  {{/IsWordAndSentenceCard}}

  {{#IsClickCard}}
  <div class="fc-click" role="button" tabindex="0">
    <div class="fc-term fc-term--hero fc-click-term">{{Term}}</div>
    <div class="fc-front-sentence fc-click-sentence">{{kanji:Sentence}}</div>
  </div>
  {{/IsClickCard}}

  {{#IsAudioCard}}
  <div class="fc-front-audio">
    <div class="fc-front-sentence fc-front-sentence--masked">{{kanji:Sentence}}</div>
    <div class="fc-audio fc-audio--large">
      {{#SentenceAudio}}{{SentenceAudio}}{{/SentenceAudio}}
      {{^SentenceAudio}}{{TermAudio}}{{/SentenceAudio}}
    </div>
  </div>
  {{/IsAudioCard}}

  {{#Hint}}<div class="fc-hint">{{Hint}}</div>{{/Hint}}
</div>

<script>
  /* 点击卡：点一下 / 按 C 在「词条」与「例句」之间切换（Lapis ClickCard 的等价物）。
     键盘监听只挂一次：外壳换卡时会重放本脚本，监听器查的是当下的 DOM。 */
  (function () {
    var click = document.querySelector(".fc-click");
    if (click) {
      click.addEventListener("click", function () {
        click.classList.toggle("fc-click--open");
      });
    }
    if (!window.__fushiCardClickKey) {
      window.__fushiCardClickKey = true;
      document.addEventListener("keydown", function (e) {
        if (e.key !== "c" && e.key !== "C") return;
        var el = document.querySelector(".fc-click");
        if (el) el.classList.toggle("fc-click--open");
      });
    }
  })();
</script>
''';

/// Fushi 卡片模板 · 背面。
const String kFushiCardBackTemplate = r'''<!--
  Fushi 卡片 · 背面。字段名与 Lapis 逐字一致；唯一的扩展字段 SentenceTranslation（为空时整块不出现）。
  版式按卡面宽度自适应：窄（手机）单栏、宽（≥720px，电脑 / 平板横屏）左栏词条 + 例句、右栏释义
  （宿主可用 fushi-srs-layout-wide / -narrow 强制）。
  脚本只做五件事：音调图、释义按词典分组 / 去重、词频明细按词典合并、折叠与版式随外观 / 宽度更新、图片放大；脚本不跑时卡面照常可读。
  音调解析与分类改写自 Lapis v1.7.0（donkuri/lapis，GPL-3.0）。
-->
<div class="fc fc-back" lang="ja">
  <div class="fc-aside">
    <header class="fc-head">
      <div class="fc-head-main">
        <div class="fc-term">{{#TermFurigana}}{{furigana:TermFurigana}}{{/TermFurigana}}{{^TermFurigana}}{{Term}}{{/TermFurigana}}</div>
        <div class="fc-reading-row">
          <span class="fc-reading">{{#TermFurigana}}{{kana:TermFurigana}}{{/TermFurigana}}{{^TermFurigana}}{{TermReading}}{{/TermFurigana}}</span>
          {{#PitchPosition}}<span class="fc-pitch-tags">{{PitchPosition}}</span>{{/PitchPosition}}
          {{#TermAudio}}<span class="fc-audio">{{TermAudio}}</span>{{/TermAudio}}
          {{#FrequencyRank}}<span class="fc-chip fc-chip--freq">{{FrequencyRank}}</span>{{/FrequencyRank}}
        </div>
      </div>
      {{#Media}}<figure class="fc-picture {{Tags}}">{{Media}}</figure>{{/Media}}
    </header>

    {{#Sentence}}
    <section class="fc-sentence-block">
      <div class="fc-sentence-body">
        <div class="fc-sentence">{{furigana:Sentence}}</div>
        {{#SentenceTranslation}}<div class="fc-translation" lang="">{{SentenceTranslation}}</div>{{/SentenceTranslation}}
      </div>
      {{#SentenceAudio}}<span class="fc-audio">{{SentenceAudio}}</span>{{/SentenceAudio}}
    </section>
    {{/Sentence}}
  </div>

  <section class="fc-defs">
    {{#LookupSelection}}<blockquote class="fc-selection">{{LookupSelection}}</blockquote>{{/LookupSelection}}
    {{#DefinitionMedia}}<div class="fc-def-picture">{{DefinitionMedia}}</div>{{/DefinitionMedia}}
    {{#MainDefinition}}<div class="fc-gloss fc-gloss--main">{{MainDefinition}}</div>{{/MainDefinition}}
    {{#Glossary}}
    <details class="fc-more"{{^MainDefinition}} open{{/MainDefinition}}>
      <summary class="fc-more-label"><span class="fc-more-title"></span><span class="fc-more-count"></span></summary>
      <div class="fc-gloss fc-gloss--all">{{Glossary}}</div>
    </details>
    {{/Glossary}}
  </section>

  <footer class="fc-foot">
    {{#Frequency}}
    <section class="fc-meta-row fc-meta-row--freq">
      <span class="fc-meta-label fc-meta-label--freq"></span>
      <div class="fc-freq-list">{{Frequency}}</div>
    </section>
    {{/Frequency}}
    {{#Source}}
    <section class="fc-meta-row fc-meta-row--source">
      <span class="fc-meta-label fc-meta-label--source"></span>
      <div class="fc-source">{{Source}}</div>
    </section>
    {{/Source}}
  </footer>

  <span class="fc-src" data-fc="pitch-categories" hidden>{{text:PitchCategories}}</span>
</div>

<script>
  (function () {
    var root = document.querySelector(".fc-back");
    if (!root) return;

    /* 宿主类名挂在 .card 上（Fushi 外壳：body 与卡面根节点；Anki：body）。 */
    function hostHas(name) {
      return document.body.classList.contains(name) || !!document.querySelector(".card." + name);
    }
    var WIDE = "(min-width: 720px)";
    /* 双栏与否：宿主强制（外观页预览的「桌面 / 手机」）优先，否则按视口宽度。 */
    function isWide() {
      if (hostHas("fushi-srs-layout-wide")) return true;
      if (hostHas("fushi-srs-layout-narrow")) return false;
      return !!(window.matchMedia && window.matchMedia(WIDE).matches);
    }

    /* ---------- 音调图（读音上画高低线，按类型着色） ---------- */
    var SMALL = "ァィゥェォャュョヮぁぃぅぇぉゃゅょゎ゙゚°";
    function morae(kana) {
      var out = [];
      for (var i = 0; i < kana.length; i++) {
        var c = kana[i];
        if (i + 1 < kana.length && SMALL.indexOf(kana[i + 1]) >= 0) {
          c += kana[i + 1];
          i++;
        }
        out.push(c);
      }
      return out;
    }
    function toHira(s) {
      return s.replace(/[ァ-ヶ]/g, function (ch) {
        return String.fromCharCode(ch.charCodeAt(0) - 0x60);
      });
    }
    function pitchType(position, moraCount, categories) {
      if (position === 0) return "heiban";
      var cats = categories.match(/heiban|atamadaka|nakadaka|odaka|kifuku/g) || [];
      if (cats.indexOf("kifuku") >= 0) return "kifuku";
      if (position === 1) return "atamadaka";
      return position >= moraCount ? "odaka" : "nakadaka";
    }
    /* 「[0]」这类数字，或「カヨイマ＼ス」这类带降调符的假名写法。 */
    function parsePitch(token, kana) {
      if (/^\d+$/.test(token)) return Number(token);
      var marked = token.replace(/[・]/g, "");
      var plain = marked.replace(/[\\＼ꜜ]/g, "");
      if (toHira(plain) !== toHira(kana)) return null;
      var cut = marked.search(/[\\＼ꜜ]/);
      return cut < 0 ? 0 : morae(marked.slice(0, cut)).length;
    }
    function drawPitch() {
      var readingEl = root.querySelector(".fc-reading");
      var tagsEl = root.querySelector(".fc-pitch-tags");
      if (!readingEl || !tagsEl) return;
      var kana = readingEl.textContent.trim();
      if (!kana) return;
      var tokens = tagsEl.textContent.match(/\d+|[ぁ-ヺー\\＼ꜜ・]+/g) || [];
      var positions = [];
      tokens.forEach(function (t) {
        var p = parsePitch(t, kana);
        if (p !== null && positions.indexOf(p) < 0) positions.push(p);
      });
      if (!positions.length) return;
      var m = morae(kana);
      var cats = (root.querySelector('[data-fc="pitch-categories"]') || {}).textContent || "";
      var p = positions[0];
      var type = pitchType(p, m.length, cats);
      root.setAttribute("data-fc-pitch", type);
      var html = "";
      m.forEach(function (mora, i) {
        var high = p === 0 ? i > 0 : p === 1 ? i === 0 : i > 0 && i < p;
        var drop = p > 0 && i === p - 1;
        html += '<span class="fc-mora" data-pitch="' + (high ? "high" : "low") + '"' +
          (drop ? ' data-drop="1"' : "") + ">" + mora + '<span class="fc-mora-line"></span></span>';
      });
      if (p > 0 && p >= m.length) html += '<span class="fc-mora fc-mora--tail" data-pitch="low"><span class="fc-mora-line"></span></span>';
      readingEl.innerHTML = html;
      readingEl.classList.add("fc-reading--graph");
      tagsEl.innerHTML = positions.map(function (x) {
        return '<span class="fc-pitch-num" data-type="' + pitchType(x, m.length, cats) + '">' + x + "</span>";
      }).join("");
    }

    /* ---------- 释义：同一词典的相邻条目收进一张卡（与查词弹窗同形） ---------- */
    function tagsFromLabel(label, dict) {
      var t = (label || "").trim().replace(/^\(|\)$/g, "");
      if (t === dict) return [];
      if (t.slice(-(dict.length + 2)) === ", " + dict) t = t.slice(0, -(dict.length + 2));
      return t ? t.split(", ") : [];
    }
    function groupGlossary(container, skip) {
      var made = 0;
      container.querySelectorAll(".yomitan-glossary").forEach(function (gl) {
        var lists = Array.prototype.filter.call(gl.children, function (c) { return c.tagName === "OL"; });
        if (!lists.length) return;
        var wrap = document.createElement("div");
        wrap.className = "fc-dicts";
        var group = null, current = null;
        lists.forEach(function (ol) {
          Array.prototype.slice.call(ol.children).forEach(function (li) {
            var dict = li.getAttribute("data-dictionary") || "";
            if (skip && skip.indexOf(dict) >= 0) { li.remove(); return; }
            if (dict !== current || !group) {
              current = dict;
              group = document.createElement("details");
              group.className = "fc-dict";
              group.setAttribute("data-fc-dict", dict);
              var sum = document.createElement("summary");
              sum.className = "fc-dict-label";
              var name = document.createElement("span");
              name.className = "fc-dict-name";
              name.textContent = dict;
              sum.appendChild(name);
              group.appendChild(sum);
              var items = document.createElement("ol");
              items.className = "fc-dict-items";
              group.appendChild(items);
              wrap.appendChild(group);
              made++;
            }
            var label = li.querySelector(":scope > i");
            if (label) {
              var tags = tagsFromLabel(label.textContent, dict);
              var chips = document.createElement("span");
              chips.className = "fc-tags";
              tags.forEach(function (tag) {
                var chip = document.createElement("span");
                chip.className = "fc-tag";
                chip.textContent = tag;
                chips.appendChild(chip);
              });
              label.replaceWith(chips);
            }
            group.lastChild.appendChild(li);
          });
          ol.remove();
        });
        gl.insertBefore(wrap, gl.firstChild);
      });
      return made;
    }
    function setUpGlossary() {
      var main = root.querySelector(".fc-gloss--main");
      var shown = [];
      if (main) {
        main.querySelectorAll("li[data-dictionary]").forEach(function (li) {
          var d = li.getAttribute("data-dictionary");
          if (shown.indexOf(d) < 0) shown.push(d);
        });
        groupGlossary(main, null);
        main.querySelectorAll(".fc-dict").forEach(function (g) { g.open = true; });
      }
      var more = root.querySelector(".fc-more");
      var all = root.querySelector(".fc-gloss--all");
      if (!more || !all) return;
      var count = groupGlossary(all, main ? shown : null);
      if (main && count === 0) { more.remove(); return; }
      more.querySelector(".fc-more-count").textContent = String(count);
    }

    /* ---------- 词频明细：同一词典的多个值（普通形 + 假名形等）合成一项 ----------
       制卡写的是「一个值一个 <li>词典名: 值</li>」；按最后一个「: 」切出词典名（名字可带冒号）。
       与原生卡面 srsFrequencyGroups、查词弹窗的分组一致。 */
    function groupFrequency() {
      var seen = {};
      root.querySelectorAll(".fc-freq-list li").forEach(function (li) {
        var text = li.textContent.trim();
        var cut = text.lastIndexOf(": ");
        if (cut <= 0 || cut + 2 >= text.length) return;
        var dict = text.slice(0, cut).trim();
        var value = text.slice(cut + 2).trim();
        var first = seen[dict];
        if (!first) { seen[dict] = { li: li, values: [value] }; return; }
        if (!first.values.includes(value)) first.values.push(value);
        first.li.textContent = dict + ": " + first.values.join(", ");
        li.remove();
      });
    }

    /* ---------- 折叠与版式：随外观（全部释义默认展开）与卡面宽度更新 ----------
       默认：主释义展开；「全部释义」收起（没有主释义时展开）。其中的词典分组与查词弹窗同形：
       宽屏、只有一部词典、或宿主要求「默认展开」时展开；窄屏收成一列可折叠的词典标题，
       点哪部开哪部，但没有主释义时第一部照样展开。
       只在这两个条件真的变了时重排，用户手动开合过的不被覆盖。 */
    function applyLayout() {
      var expanded = hostHas("fushi-srs-gloss-expanded");
      var wide = isWide();
      root.classList.toggle("fc-layout-wide", wide);
      var aside = root.querySelector(".fc-aside");
      if (aside) {
        /* 宽屏左栏能整个放进视口时吸顶：往下翻释义时词条与例句一直在眼前。 */
        aside.classList.toggle("fc-aside--sticky", wide && aside.offsetHeight < window.innerHeight - 48);
      }
      updateClamp();
      var key = (expanded ? "e" : "c") + (wide ? "w" : "n");
      if (root.__fcLayoutKey === key) return;
      root.__fcLayoutKey = key;
      var main = root.querySelector(".fc-gloss--main");
      var more = root.querySelector(".fc-more");
      if (more) {
        more.open = expanded || !main;
        var groups = more.querySelectorAll(".fc-dict");
        /* 没有主释义时第一部词典就是主释义，窄屏也展开它。 */
        groups.forEach(function (g, i) {
          g.open = expanded || wide || groups.length === 1 || (i === 0 && !main);
        });
      }
    }

    /* ---------- 窄屏：主释义过长时收到约半屏，一次点按看全文 ---------- */
    function updateClamp() {
      var main = root.querySelector(".fc-gloss--main");
      if (!main) return;
      var btn = root.querySelector(".fc-clamp-toggle");
      if (!btn) {
        btn = document.createElement("button");
        btn.type = "button";
        btn.className = "fc-clamp-toggle";
        btn.addEventListener("click", function () {
          main.classList.add("fc-gloss--unclamped");
          btn.hidden = true;
        });
        main.parentNode.insertBefore(btn, main.nextSibling);
      }
      if (main.classList.contains("fc-gloss--unclamped")) { btn.hidden = true; return; }
      main.classList.add("fc-gloss--clamp");
      /* 只有真的被截断才显示按钮（宽屏 / 宿主关掉收起时 CSS 不截断，按钮也不出现）。 */
      btn.hidden = !(main.scrollHeight > main.clientHeight + 8);
      main.classList.toggle("fc-gloss--clamped", !btn.hidden);
    }
    window.__fcApplyLayout = applyLayout;
    if (!window.__fcLayoutListeners) {
      window.__fcLayoutListeners = true;
      var rerun = function () { if (window.__fcApplyLayout) window.__fcApplyLayout(); };
      document.addEventListener("fushi-srs-theme", rerun);
      window.addEventListener("resize", rerun);
    }

    /* ---------- 图片：点按放大，再点关闭；加载完重算左栏能否吸顶 ---------- */
    function setUpLightbox() {
      /* 视频片段（制卡写进 Media 的 <video>）尺寸要等元数据到了才知道，同样重算 */
      root.querySelectorAll(".fc-picture video, .fc-def-picture video").forEach(function (v) {
        if (v.readyState < 1) v.addEventListener("loadedmetadata", applyLayout, { once: true });
      });
      var imgs = root.querySelectorAll(".fc-picture img, .fc-def-picture img");
      if (!imgs.length) return;
      imgs.forEach(function (img) {
        if (!img.complete) img.addEventListener("load", applyLayout, { once: true });
      });
      root.querySelectorAll(".fc-gloss img").forEach(function (img) {
        if (!img.complete) img.addEventListener("load", updateClamp, { once: true });
      });
      var box = document.createElement("div");
      box.className = "fc-lightbox";
      box.addEventListener("click", function () { box.classList.remove("fc-lightbox--open"); });
      root.appendChild(box);
      imgs.forEach(function (img) {
        img.addEventListener("click", function () {
          box.innerHTML = "";
          var big = document.createElement("img");
          big.src = img.currentSrc || img.src;
          box.appendChild(big);
          box.classList.add("fc-lightbox--open");
        });
      });
    }

    [drawPitch, setUpGlossary, groupFrequency, applyLayout, setUpLightbox].forEach(function (step) {
      try { step(); } catch (e) { if (window.console) console.error(e); }
    });
  })();
</script>
''';

/// Fushi 卡片模板 · 样式。
const String kFushiCardStylingCss = r'''/*
 * Fushi 卡片 · 样式。
 *
 * 分五层：
 *   1. 主题令牌：颜色 / 字体 / 字阶 / 间距全部经 --fushi-srs-* 读宿主注入值，没注入时用这里的
 *      默认值（导出到 Anki 也能看）。颜色按 Flutter ColorScheme 角色命名，宿主一一注入；
 *      字面颜色只出现在本层。宿主类名（挂在 .card 上）开关区块显隐、密度、正面读音等。
 *   2. 卡面版式（正面 / 背面；背面按卡面宽度分窄屏单栏、宽屏双栏）。
 *   3. 释义区：规则取自查词弹窗 fushi/assets/popup/popup.css（词典分组卡、词典名、标签、
 *      结构化内容表格 / 图片 / 注音、深色下词典内联底色），全部限定在 .fc-gloss 内。
 *   4. 统一词典样式（M3E）：宿主挂 fushi-srs-dict-unified 且宿主脚本量完原色（fc-dt-ready）
 *      后，按 data-fushi-dt* 语义取卡面令牌（同 popup.css「词典样式统一」）。
 *   5. 交互附件（图片放大层）与减弱动态效果。
 */

/* ================================================================
 * 1. 主题令牌
 * ================================================================ */

.card {
  /* ---- 颜色（浅色默认） ---- */
  --fc-bg: var(--fushi-srs-bg, #fbfaf7);
  --fc-fg: var(--fushi-srs-fg, #1c1b19);
  --fc-accent: var(--fushi-srs-accent, #386a58);
  --fc-on-accent: var(--fushi-srs-on-accent, #ffffff);

  /* 未注入时由前景 / 背景 / 强调色推出来，宿主只给三个色也能自洽 */
  --fc-fg-muted: var(--fushi-srs-fg-muted, color-mix(in srgb, var(--fc-fg) 64%, var(--fc-bg)));
  --fc-accent-container: var(--fushi-srs-accent-container, color-mix(in srgb, var(--fc-accent) 15%, var(--fc-bg)));
  --fc-on-accent-container: var(--fushi-srs-on-accent-container, var(--fc-fg));
  --fc-secondary-container: var(--fushi-srs-secondary-container, color-mix(in srgb, var(--fc-accent) 10%, var(--fc-surface-2)));
  --fc-on-secondary-container: var(--fushi-srs-on-secondary-container, var(--fc-fg));
  --fc-surface-1: var(--fushi-srs-surface-container, color-mix(in srgb, var(--fc-fg) 4.5%, var(--fc-bg)));
  --fc-surface-2: var(--fushi-srs-surface-container-high, color-mix(in srgb, var(--fc-fg) 9%, var(--fc-bg)));
  --fc-surface-3: var(--fushi-srs-surface-container-highest, color-mix(in srgb, var(--fc-fg) 13%, var(--fc-bg)));
  --fc-outline: var(--fushi-srs-outline-variant, color-mix(in srgb, var(--fc-fg) 15%, var(--fc-bg)));
  --fc-outline-strong: var(--fushi-srs-outline, color-mix(in srgb, var(--fc-fg) 45%, var(--fc-bg)));
  --fc-highlight: var(--fushi-srs-highlight, color-mix(in srgb, var(--fc-accent) 28%, transparent));
  --fc-target: var(--fushi-srs-target, var(--fc-accent));
  --fc-link: var(--fushi-srs-link, var(--fc-accent));
  --fc-image-filter: var(--fushi-srs-image-filter, none);

  /* 音调类型配色（沿用 Lapis 的五类；可整组覆盖） */
  --fc-pitch-heiban: var(--fushi-srs-pitch-heiban, #1a8fc4);
  --fc-pitch-atamadaka: var(--fushi-srs-pitch-atamadaka, #d93a43);
  --fc-pitch-nakadaka: var(--fushi-srs-pitch-nakadaka, #e0650b);
  --fc-pitch-odaka: var(--fushi-srs-pitch-odaka, #4f9a2f);
  --fc-pitch-kifuku: var(--fushi-srs-pitch-kifuku, #7e53c4);

  /* ---- 形状（M3E：外层大圆角，分段卡内小圆角） ---- */
  --fc-radius: var(--fushi-srs-radius, 20px);
  --fc-radius-inner: var(--fushi-srs-radius-inner, 4px);
  --fc-radius-small: var(--fushi-srs-radius-small, 10px);

  /* ---- 字体（日文优先，中文 / 韩文 / 西文按 :lang() 分流，同查词弹窗） ---- */
  --fc-font-ja: var(--fushi-srs-font-ja, "Hiragino Sans", "Hiragino Kaku Gothic ProN", "Yu Gothic UI", "Yu Gothic", "Meiryo", "Noto Sans CJK JP", "Noto Sans JP", sans-serif);
  --fc-font-display: var(--fushi-srs-font-display, var(--fc-font-ja));
  --fc-font-zh: var(--fushi-srs-font-zh, "PingFang SC", "Heiti SC", "Microsoft YaHei UI", "Microsoft YaHei", "Noto Sans CJK SC", "Noto Sans SC", sans-serif);
  --fc-font-zh-hant: var(--fushi-srs-font-zh-hant, "PingFang TC", "Heiti TC", "Microsoft JhengHei UI", "Microsoft JhengHei", "Noto Sans CJK TC", "Noto Sans TC", sans-serif);
  --fc-font-ko: var(--fushi-srs-font-ko, "Apple SD Gothic Neo", "Malgun Gothic", "Noto Sans CJK KR", "Noto Sans KR", sans-serif);
  --fc-font-ui: var(--fushi-srs-font-ui, system-ui, -apple-system, "Segoe UI", "Roboto", var(--fc-font-ja));

  /* ---- 字阶：宿主只给三个倍率（正文 / 词条 / 行距），各区块的基准在这里 ---- */
  --fc-text-scale: var(--fushi-srs-text-scale, 1);
  --fc-term-scale: var(--fushi-srs-term-scale, 1);
  --fc-line-scale: var(--fushi-srs-line-scale, 1);
  --fc-size-body: calc(16px * var(--fc-text-scale));
  --fc-size-gloss: calc(15px * var(--fc-text-scale));
  --fc-size-sentence: calc(20px * var(--fc-text-scale));
  --fc-size-reading: calc(19px * var(--fc-text-scale));
  --fc-size-front-sentence: calc(clamp(24px, 6.4vw, 36px) * var(--fc-text-scale));
  --fc-size-term: calc(clamp(34px, 10vw, 52px) * var(--fc-term-scale));
  --fc-size-term-hero: calc(clamp(60px, 21vw, 112px) * var(--fc-term-scale));
  --fc-lh-body: calc(1.6 * var(--fc-line-scale));
  --fc-lh-gloss: calc(1.85 * var(--fc-line-scale));
  --fc-lh-sentence: calc(1.9 * var(--fc-line-scale));

  /* ---- 间距（密度：宿主类名 fushi-srs-density-compact / -comfortable） ---- */
  --fc-gap: 16px;
  --fc-pad: 16px;
  --fc-tap: 40px;
  /* 窄屏标题区右上角的图片缩略图边长 */
  --fc-thumb: var(--fushi-srs-thumb, 84px);

  /* ---- 标签文字（宿主按界面语言注入；这里是英文兜底） ---- */
  --fc-label-more: var(--fushi-srs-label-more, "All definitions");
  --fc-label-frequency: var(--fushi-srs-label-frequency, "Frequency");
  --fc-label-source: var(--fushi-srs-label-source, "Source");
  --fc-label-masked: var(--fushi-srs-label-masked, "［…］");
  --fc-label-show-more: var(--fushi-srs-label-show-more, "Show more");

  /* 窄屏主释义收起后的高度（约半屏；宿主类名 fushi-srs-full-gloss 关掉收起） */
  --fc-clamp: var(--fushi-srs-clamp, 52vh);
  --fc-clamp-short: max(52vh, 300px);
}

.card.nightMode {
  --fc-bg: var(--fushi-srs-bg, #151413);
  --fc-fg: var(--fushi-srs-fg, #e9e5de);
  --fc-accent: var(--fushi-srs-accent, #9dd7b8);
  --fc-on-accent: var(--fushi-srs-on-accent, #00382a);
  --fc-surface-1: var(--fushi-srs-surface-container, color-mix(in srgb, var(--fc-fg) 7%, var(--fc-bg)));
  --fc-surface-2: var(--fushi-srs-surface-container-high, color-mix(in srgb, var(--fc-fg) 12%, var(--fc-bg)));
  --fc-surface-3: var(--fushi-srs-surface-container-highest, color-mix(in srgb, var(--fc-fg) 17%, var(--fc-bg)));
  --fc-outline: var(--fushi-srs-outline-variant, color-mix(in srgb, var(--fc-fg) 20%, var(--fc-bg)));
  --fc-accent-container: var(--fushi-srs-accent-container, color-mix(in srgb, var(--fc-accent) 22%, var(--fc-bg)));
  --fc-highlight: var(--fushi-srs-highlight, color-mix(in srgb, var(--fc-accent) 34%, transparent));
  --fc-image-filter: var(--fushi-srs-image-filter, brightness(0.9));

  --fc-pitch-heiban: var(--fushi-srs-pitch-heiban, #4fc0ec);
  --fc-pitch-atamadaka: var(--fushi-srs-pitch-atamadaka, #f0646b);
  --fc-pitch-nakadaka: var(--fushi-srs-pitch-nakadaka, #ff9b52);
  --fc-pitch-odaka: var(--fushi-srs-pitch-odaka, #7fcc58);
  --fc-pitch-kifuku: var(--fushi-srs-pitch-kifuku, #b592f6);
}

.card.fushi-srs-density-compact {
  --fc-gap: 10px;
  --fc-pad: 12px;
}

.card.fushi-srs-density-comfortable {
  --fc-gap: 22px;
  --fc-pad: 20px;
}

/* 触屏：命中区放大到 48dp 量级 */
@media (pointer: coarse) {
  .card {
    --fc-tap: 46px;
  }
}

/* ================================================================
 * 2. 卡面版式
 * ================================================================ */

.card {
  background-color: var(--fc-bg);
  color: var(--fc-fg);
  font-family: var(--fc-font-ja);
  font-size: var(--fc-size-body);
  line-height: var(--fc-lh-body);
  text-align: left;
  -webkit-text-size-adjust: 100%;
  text-size-adjust: 100%;
  -webkit-tap-highlight-color: transparent;
}

.fc,
.fc * {
  box-sizing: border-box;
}

.fc {
  max-width: 760px;
  margin: 0 auto;
  font-family: var(--fc-font-ja);
  overflow-wrap: break-word;
}

.fc :lang(ja) { font-family: var(--fc-font-ja); }
.fc :lang(zh) { font-family: var(--fc-font-zh); }
.fc :lang(zh-Hant) { font-family: var(--fc-font-zh-hant); }
.fc :lang(ko) { font-family: var(--fc-font-ko); }

.fc a {
  color: var(--fc-link);
  text-decoration: none;
}

.fc img,
.fc video {
  filter: var(--fc-image-filter);
}

/* 注音只给基字留位置，复制时不带振假名（同查词弹窗） */
.fc rt,
.fc rp {
  -webkit-user-select: none;
  user-select: none;
}

/* ---------- 通用小件 ---------- */

.fc-chip {
  display: inline-flex;
  align-items: center;
  gap: 4px;
  min-height: 24px;
  padding: 0 10px;
  border-radius: 999px;
  background: var(--fc-surface-2);
  color: var(--fc-fg-muted);
  font-family: var(--fc-font-ui);
  font-size: 12px;
  font-weight: 500;
  line-height: 1;
  white-space: nowrap;
  font-variant-numeric: tabular-nums;
}

/* 词频序位：前缀一个三格柱图标（纯 CSS，不依赖字体） */
.fc-chip--freq::before {
  content: "";
  width: 10px;
  height: 10px;
  background:
    linear-gradient(currentColor, currentColor) 0 100% / 2px 40% no-repeat,
    linear-gradient(currentColor, currentColor) 4px 100% / 2px 70% no-repeat,
    linear-gradient(currentColor, currentColor) 8px 100% / 2px 100% no-repeat;
  opacity: 0.8;
}

/* 播放按钮：外壳把 [sound:] 换成 .fushi-srs-sound；Anki 桌面是 .replay-button */
.fc .fushi-srs-sound,
.fc .replay-button {
  display: inline-flex;
  align-items: center;
  justify-content: center;
  width: var(--fc-tap);
  height: var(--fc-tap);
  margin: 0;
  padding: 0;
  border: none;
  border-radius: 999px;
  background: var(--fc-accent-container);
  color: var(--fc-on-accent-container);
  vertical-align: middle;
  cursor: pointer;
  transition: transform 140ms cubic-bezier(0.2, 0, 0, 1), background-color 140ms ease;
}

.fc .fushi-srs-sound:active,
.fc .replay-button:active {
  transform: scale(0.9);
  background: color-mix(in srgb, var(--fc-accent) 30%, var(--fc-bg));
}

@media (hover: hover) {
  .fc .fushi-srs-sound:hover,
  .fc .replay-button:hover {
    background: color-mix(in srgb, var(--fc-accent) 24%, var(--fc-bg));
  }
}

.fc .fushi-srs-sound svg,
.fc .replay-button svg {
  width: 18px;
  height: 18px;
  fill: currentColor;
}

.fc .replay-button svg circle {
  display: none;
}

.fc-audio {
  display: inline-flex;
  gap: 6px;
  flex: 0 0 auto;
}

.fc-audio--large .fushi-srs-sound,
.fc-audio--large .replay-button {
  width: 60px;
  height: 60px;
}

.fc-audio--large svg {
  width: 28px;
  height: 28px;
}

/* ---------- 正面 ---------- */

.fc-front {
  position: relative;
  display: flex;
  flex-direction: column;
  align-items: center;
  justify-content: center;
  gap: 20px;
  min-height: calc(100vh - 32px);
  padding: 24px 0;
  text-align: center;
}

.fc-term {
  font-family: var(--fc-font-display);
  font-size: var(--fc-size-term);
  font-weight: 500;
  line-height: 1.25;
  letter-spacing: 0.02em;
}

.fc-term--hero {
  font-size: var(--fc-size-term-hero);
  line-height: 1.2;
}

.fc-term ruby rt {
  font-size: 0.36em;
  font-weight: 400;
  color: var(--fc-fg-muted);
  letter-spacing: 0.04em;
}

/* 正面默认只给词条本身；宿主挂 fushi-srs-front-reading 时换成带注音的版本并显示音调 */
.fc-front .fc-term--ruby,
.fc-front .fc-front-pitch {
  display: none;
}

.fushi-srs-front-reading .fc-front .fc-term--ruby {
  display: block;
}

.fushi-srs-front-reading .fc-front .fc-term--ruby ~ .fc-front-pitch,
.fushi-srs-front-reading .fc-front .fc-term--ruby + .fc-front-pitch {
  display: block;
}

.fushi-srs-front-reading .fc-front .fc-front-term:has(.fc-term--ruby) .fc-term--plain {
  display: none;
}

.fc-front-pitch ul {
  display: inline-flex;
  gap: 6px;
  margin: 0;
  padding: 0;
  list-style: none;
  color: var(--fc-fg-muted);
  font-size: 14px;
}

.fc-front-freq {
  position: absolute;
  top: 0;
  right: 0;
  display: none;
}

.fushi-srs-front-freq .fc-front-freq {
  display: block;
}

.fc-front-sentence {
  max-width: 30em;
  font-size: var(--fc-size-front-sentence);
  line-height: calc(1.75 * var(--fc-line-scale));
  text-align: center;
}

.fc-front-context {
  max-width: 34em;
  padding: 10px 18px;
  border-radius: var(--fc-radius);
  background: var(--fc-surface-1);
  color: var(--fc-fg-muted);
  font-size: calc(var(--fc-size-front-sentence) * 0.74);
  line-height: calc(1.8 * var(--fc-line-scale));
}

.fc-front-sentence b,
.fc-front-context b {
  font-weight: 700;
  color: var(--fc-target);
  background: linear-gradient(transparent 60%, var(--fc-highlight) 60%);
}

/* 听力卡：目标词挖空（替代 Lapis 的 HideTargetWord 脚本） */
.fc-front-sentence--masked b {
  font-size: 0;
  background: none;
}

.fc-front-sentence--masked b::after {
  content: var(--fc-label-masked);
  font-size: var(--fc-size-front-sentence);
  color: var(--fc-target);
}

.fc-front-audio {
  display: flex;
  flex-direction: column;
  align-items: center;
  gap: 20px;
}

/* 点击卡：词条 ⇄ 例句 */
.fc-click {
  cursor: pointer;
  -webkit-user-select: none;
  user-select: none;
  outline: none;
}

.fc-click-term {
  display: inline-block;
  border-bottom: 2px dotted var(--fc-outline);
}

.fc-click-sentence,
.fc-click--open .fc-click-term {
  display: none;
}

.fc-click--open .fc-click-sentence {
  display: block;
}

.fc-hint {
  max-width: 34em;
  padding: 8px 16px;
  border-radius: var(--fc-radius-small);
  background: var(--fc-accent-container);
  color: var(--fc-on-accent-container);
  font-size: 15px;
}

/* ---------- 背面：窄屏（默认）单栏，关键信息在首屏 ---------- */

.fc-back {
  display: flex;
  flex-direction: column;
  gap: var(--fc-gap);
  padding-bottom: 8px;
}

.fc-aside {
  display: flex;
  flex-direction: column;
  gap: var(--fc-gap);
  min-width: 0;
}

.fc-head {
  display: flex;
  align-items: flex-start;
  gap: 14px;
}

.fc-head-main {
  flex: 1 1 auto;
  min-width: 0;
  padding-top: 2px;
}

.fc-back .fc-term {
  /* 注音占位：振假名画在基字上方，不让它顶出卡片 */
  padding-top: 0.2em;
}

.fc-reading-row {
  display: flex;
  /* 读音、音调、播放、词频优先排在一行；放不下才折行 */
  flex-wrap: wrap;
  align-items: center;
  gap: 8px 10px;
  margin-top: 6px;
}

.fc-reading {
  font-size: var(--fc-size-reading);
  line-height: 1.5;
  color: var(--fc-fg-muted);
  letter-spacing: 0.04em;
}

/* 音调图：高音段画顶线、降调处画竖线（形同查词弹窗的 Yomitan 发音图） */
.fc-back[data-fc-pitch="heiban"] { --fc-pitch: var(--fc-pitch-heiban); }
.fc-back[data-fc-pitch="atamadaka"] { --fc-pitch: var(--fc-pitch-atamadaka); }
.fc-back[data-fc-pitch="nakadaka"] { --fc-pitch: var(--fc-pitch-nakadaka); }
.fc-back[data-fc-pitch="odaka"] { --fc-pitch: var(--fc-pitch-odaka); }
.fc-back[data-fc-pitch="kifuku"] { --fc-pitch: var(--fc-pitch-kifuku); }

.fc-reading--graph {
  display: inline-flex;
  padding-top: 4px;
  color: var(--fc-fg);
}

.fc-mora {
  position: relative;
  padding: 0 1px;
}

.fc-mora-line {
  position: absolute;
  left: 0;
  right: 0;
  top: 0;
  height: 0;
}

.fc-mora[data-pitch="high"] > .fc-mora-line {
  border-top: 2px solid var(--fc-pitch, var(--fc-fg-muted));
}

.fc-mora[data-drop] > .fc-mora-line {
  right: -1px;
  height: 0.45em;
  border-right: 2px solid var(--fc-pitch, var(--fc-fg-muted));
}

.fc-mora--tail {
  width: 0.6em;
}

.fc-mora--tail > .fc-mora-line {
  border-bottom: 2px dotted var(--fc-pitch, var(--fc-fg-muted));
  top: 0.75em;
}

/* 音调号：脚本跑过是彩色小圆片，没跑是字段原样的 [n] 列表 */
.fc-pitch-tags ul {
  display: inline-flex;
  gap: 4px;
  margin: 0;
  padding: 0;
  list-style: none;
  color: var(--fc-fg-muted);
  font-size: 13px;
}

.fc-pitch-tags {
  display: inline-flex;
  gap: 4px;
}

.fc-pitch-num {
  display: inline-flex;
  align-items: center;
  justify-content: center;
  min-width: 22px;
  height: 22px;
  padding: 0 6px;
  border-radius: 999px;
  font-family: var(--fc-font-ui);
  font-size: 12px;
  font-weight: 600;
  color: var(--fc-bg);
  background: var(--fc-fg-muted);
}

.fc-pitch-num[data-type="heiban"] { background: var(--fc-pitch-heiban); }
.fc-pitch-num[data-type="atamadaka"] { background: var(--fc-pitch-atamadaka); }
.fc-pitch-num[data-type="nakadaka"] { background: var(--fc-pitch-nakadaka); }
.fc-pitch-num[data-type="odaka"] { background: var(--fc-pitch-odaka); }
.fc-pitch-num[data-type="kifuku"] { background: var(--fc-pitch-kifuku); }

/* 图片：窄屏是标题区右上角的紧凑缩略图，按原比例完整显示（书封等竖图不裁切），
   限高限宽不挤占词条行；点按放大看全图。Media 也可能是视频片段（<video>，视频制卡默认）
   或动图（GIF / WebP / AVIF 都是 <img>）：视频与图片同一套尺寸 / 圆角 / 打码规则，
   但不放大（控制条本身就要点按） */
.fc-picture {
  flex: 0 0 auto;
  max-width: calc(var(--fc-thumb) * 1.5);
  margin: 0;
}

.fc-picture img,
.fc-picture video {
  display: block;
  width: auto;
  height: auto;
  max-width: 100%;
  max-height: calc(var(--fc-thumb) * 1.4);
  border-radius: var(--fc-radius-small);
  cursor: zoom-in;
  transition: transform 180ms cubic-bezier(0.2, 0, 0, 1);
}

.fc-picture video {
  cursor: auto;
  background: #000;
}

@media (hover: hover) {
  .fc-picture img:hover,
  .fc-def-picture img:hover {
    transform: scale(1.03);
  }
}

.fc-picture.nsfw img,
.fc-picture.NSFW img,
.fc-picture.Nsfw img,
.fc-picture.nsfw video,
.fc-picture.NSFW video,
.fc-picture.Nsfw video {
  filter: blur(14px) var(--fc-image-filter);
}

.fc-picture.nsfw img:hover,
.fc-picture.NSFW img:hover,
.fc-picture.Nsfw img:hover,
.fc-picture.nsfw video:hover,
.fc-picture.NSFW video:hover,
.fc-picture.Nsfw video:hover {
  filter: var(--fc-image-filter);
}

/* 例句 */
.fc-sentence-block {
  display: flex;
  align-items: flex-start;
  gap: 12px;
  padding: calc(var(--fc-pad) - 2px) var(--fc-pad);
  border-radius: var(--fc-radius);
  background: var(--fc-surface-1);
}

.fc-sentence-body {
  flex: 1 1 auto;
  min-width: 0;
}

.fc-sentence {
  font-size: var(--fc-size-sentence);
  line-height: var(--fc-lh-sentence);
}

.fc-sentence b {
  font-weight: 700;
  color: var(--fc-target);
  background: linear-gradient(transparent 62%, var(--fc-highlight) 62%);
  border-radius: 2px;
}

/* 例句字段自带的注音悬停 / 点按显示（Lapis 的 "hover"） */
.fc-sentence rt {
  font-size: 0.5em;
  color: var(--fc-fg-muted);
  opacity: 0;
  transition: opacity 150ms ease;
}

.fc-sentence:hover rt,
.fc-sentence:active rt {
  opacity: 1;
}

.fc-translation {
  margin-top: 8px;
  padding-top: 8px;
  border-top: 1px solid var(--fc-outline);
  color: var(--fc-fg-muted);
  font-family: var(--fc-font-ui);
  font-size: calc(15px * var(--fc-text-scale));
  line-height: 1.55;
}

/* 释义区 */
.fc-defs {
  display: flex;
  flex-direction: column;
  gap: 12px;
  min-width: 0;
}

.fc-selection {
  margin: 0;
  padding: 10px 14px;
  border-left: 3px solid var(--fc-accent);
  border-radius: 0 var(--fc-radius-small) var(--fc-radius-small) 0;
  background: var(--fc-accent-container);
  color: var(--fc-on-accent-container);
  font-size: var(--fc-size-gloss);
}

.fc-def-picture img,
.fc-def-picture video {
  max-width: 100%;
  max-height: 200px;
  border-radius: var(--fc-radius-small);
  cursor: zoom-in;
  transition: transform 180ms cubic-bezier(0.2, 0, 0, 1);
}

.fc-more {
  border-radius: var(--fc-radius);
}

.fc-more > summary {
  list-style: none;
}

.fc-more > summary::-webkit-details-marker {
  display: none;
}

.fc-more-label {
  display: flex;
  align-items: center;
  gap: 8px;
  min-height: var(--fc-tap);
  padding: 0 16px;
  border-radius: 999px;
  border: 1px solid var(--fc-outline);
  color: var(--fc-fg-muted);
  font-family: var(--fc-font-ui);
  font-size: 14px;
  font-weight: 500;
  cursor: pointer;
  -webkit-user-select: none;
  user-select: none;
  transition: background-color 140ms ease, border-color 140ms ease;
}

@media (hover: hover) {
  .fc-more-label:hover {
    background: var(--fc-surface-1);
    border-color: var(--fc-outline-strong);
  }
}

.fc-more-title::before {
  content: var(--fc-label-more);
}

.fc-more-count:not(:empty) {
  display: inline-flex;
  align-items: center;
  justify-content: center;
  min-width: 22px;
  height: 20px;
  padding: 0 6px;
  border-radius: 999px;
  background: var(--fc-secondary-container);
  color: var(--fc-on-secondary-container);
  font-size: 12px;
  font-variant-numeric: tabular-nums;
}

.fc-more-label::after {
  content: "";
  width: 8px;
  height: 8px;
  margin-left: auto;
  border-right: 2px solid currentColor;
  border-bottom: 2px solid currentColor;
  transform: rotate(-45deg);
  transition: transform 200ms cubic-bezier(0.2, 0, 0, 1);
  opacity: 0.8;
}

.fc-more[open] > .fc-more-label {
  margin-bottom: 8px;
}

.fc-more[open] > .fc-more-label::after {
  transform: rotate(45deg);
}

/* 频率 / 来源 */
.fc-foot {
  display: flex;
  flex-direction: column;
  gap: 6px;
  min-width: 0;
}

.fc-foot:not(:has(.fc-meta-row)) {
  display: none;
}

.fc-meta-row {
  display: flex;
  align-items: baseline;
  gap: 12px;
  padding-top: 12px;
  border-top: 1px solid var(--fc-outline);
  color: var(--fc-fg-muted);
  font-family: var(--fc-font-ui);
  font-size: 13px;
  line-height: 1.5;
}

.fc-meta-row + .fc-meta-row {
  padding-top: 0;
  border-top: none;
}

.fc-meta-label {
  flex: 0 0 4.5em;
  font-size: 12px;
  font-weight: 500;
  letter-spacing: 0.04em;
  opacity: 0.85;
}

.fc-meta-label--freq::before { content: var(--fc-label-frequency); }
.fc-meta-label--source::before { content: var(--fc-label-source); }

.fc-freq-list ul {
  display: flex;
  flex-wrap: wrap;
  gap: 6px;
  margin: 0;
  padding: 0;
  list-style: none;
  text-align: left !important;
}

.fc-freq-list li {
  padding: 2px 10px;
  border-radius: 999px;
  background: var(--fc-surface-1);
  font-variant-numeric: tabular-nums;
}

.fc-source {
  min-width: 0;
}

/* 区块显隐（宿主类名；Anki 里全显示） */
.fushi-srs-hide-picture .fc-picture,
.fushi-srs-hide-picture .fc-def-picture,
.fushi-srs-hide-translation .fc-translation,
.fushi-srs-hide-frequency .fc-meta-row--freq,
.fushi-srs-hide-frequency .fc-back .fc-chip--freq,
.fushi-srs-hide-source .fc-meta-row--source {
  display: none;
}

/* 词频跟随查词的「词频聚合」（宿主类 fushi-srs-freq-aggregate）：聚合且有平均值时只留读音行的
   平均值，否则只留按词典合并的明细区，两者不同时出现（与原生卡面同一规则）。宿主类挂在 body 与
   卡面根节点上；Anki 里没有宿主类 = 明细。 */
.fushi-srs-freq-aggregate .fc-back:has(.fc-reading-row .fc-chip--freq) .fc-meta-row--freq,
body:not(.fushi-srs-freq-aggregate) .fc-back:has(.fc-meta-row--freq) .fc-reading-row .fc-chip--freq {
  display: none;
}

.fushi-srs-hide-frequency .fc-meta-row--source {
  padding-top: 12px;
  border-top: 1px solid var(--fc-outline);
}

/* ---------- 背面窄屏：长释义收起 + 词典页签（背面脚本挂类名；宽屏不受影响） ---------- */
.fc-back:not(.fc-layout-wide) .fc-gloss--clamp {
  max-height: var(--fc-clamp);
  overflow: hidden;
}

/* 手机横屏（视口矮）：双栏照旧，但长主释义同样收起，不然右栏一拉三四屏。桌面窗口够高，不受影响。 */
@media (max-height: 520px) {
  .fc-back.fc-layout-wide .fc-gloss--clamp {
    max-height: var(--fc-clamp-short);
    overflow: hidden;
  }

  /* 左栏图片在矮视口里收小（点按仍可放大），词条 + 例句尽量留在首屏。 */
  .fc-back.fc-layout-wide .fc-picture img,
  .fc-back.fc-layout-wide .fc-picture video {
    max-height: 120px;
  }
}

.fc-gloss--clamped {
  -webkit-mask-image: linear-gradient(#000 calc(100% - 48px), transparent);
  mask-image: linear-gradient(#000 calc(100% - 48px), transparent);
}

.fushi-srs-full-gloss .fc-gloss--clamp,
.fc-gloss--unclamped {
  max-height: none !important;
  -webkit-mask-image: none !important;
  mask-image: none !important;
}

.fc-clamp-toggle {
  align-self: flex-start;
  min-height: var(--fc-tap);
  margin-top: -6px;
  padding: 0 16px;
  border: none;
  border-radius: 999px;
  background: var(--fc-secondary-container);
  color: var(--fc-on-secondary-container);
  font-family: var(--fc-font-ui);
  font-size: 14px;
  font-weight: 500;
  cursor: pointer;
}

.fc-clamp-toggle::before {
  content: var(--fc-label-show-more);
}

.fc-clamp-toggle[hidden],
.fushi-srs-full-gloss .fc-clamp-toggle {
  display: none;
}

/* ---------- 背面：中等宽度（平板竖屏 / 窄窗口），单栏加大字与图 ---------- */
@media (min-width: 560px) {
  .card {
    --fc-size-sentence: calc(22px * var(--fc-text-scale));
    --fc-size-gloss: calc(16px * var(--fc-text-scale));
  }

  .card {
    --fc-thumb: var(--fushi-srs-thumb, 104px);
  }

  .fc-sentence-block {
    padding: calc(var(--fc-pad) + 2px) calc(var(--fc-pad) + 6px);
  }
}

/* ---------- 背面：宽屏双栏（电脑 / 平板横屏） ----------
   左栏：词条、读音、图片、例句（一眼看清「这是哪个词、在哪句话里」）；
   右栏：释义（最长的部分单独成栏，少滚动）；左栏能放进视口时吸顶（脚本判定）。
   是否双栏由背面脚本给 .fc-back 挂 fc-layout-wide 决定：默认按视口宽度 ≥720px，宿主
   类名 fushi-srs-layout-wide / -narrow 可强制（外观页预览切「桌面 / 手机」）。脚本不跑
   时保持单栏，照样可读。 */
.fc-back.fc-layout-wide {
  display: grid;
  grid-template-columns: minmax(260px, 5fr) minmax(0, 7fr);
  grid-template-areas:
    "aside defs"
    "foot defs";
  grid-template-rows: auto 1fr;
  column-gap: calc(var(--fc-gap) * 1.75);
  row-gap: var(--fc-gap);
  align-items: start;
  max-width: 1160px;
}

.fc-layout-wide .fc-aside {
  grid-area: aside;
}

.fc-layout-wide .fc-aside--sticky {
  position: sticky;
  top: 0;
}

.fc-layout-wide .fc-defs {
  grid-area: defs;
}

.fc-layout-wide .fc-foot {
  grid-area: foot;
}

/* 左栏里图片放到词条下方整宽显示（栏宽有限，不再挤在标题右侧） */
.fc-layout-wide .fc-head {
  flex-direction: column;
  gap: var(--fc-gap);
}

.fc-layout-wide .fc-picture {
  width: auto;
  height: auto;
  max-width: 100%;
}

.fc-layout-wide .fc-picture img,
.fc-layout-wide .fc-picture video {
  width: auto;
  height: auto;
  max-width: 100%;
  max-height: 220px;
}

.fc-layout-wide .fc-meta-row {
  flex-direction: column;
  gap: 6px;
}

.fc-layout-wide .fc-meta-label {
  flex: 0 0 auto;
}

@media (min-width: 720px) {
  .fc-front {
    max-width: 1000px;
  }
}

/* ================================================================
 * 3. 释义区（取自查词弹窗 popup.css，全部限定在 .fc-gloss 内）
 * ================================================================ */

.fc-gloss {
  font-size: var(--fc-size-gloss);
  /* 词典正文多带逐字振假名：行距给足，注音不贴上一行 */
  line-height: var(--fc-lh-gloss);
  /* popup.css .glossary-group（BUG-1827）：找不到断点的短语在卡内折行，不撑破卡片 */
  overflow-wrap: anywhere;
}

.fc-gloss .yomitan-glossary {
  text-align: left !important;
}

/* 脚本没跑时的原样结构：<ol><li data-dictionary><i>(标签, 词典)</i> <span>…</span></li></ol> */
.fc-gloss .yomitan-glossary > ol {
  margin: 0;
  padding-left: 1.6em;
}

.fc-gloss .yomitan-glossary > ol > li > i {
  display: block;
  color: var(--fc-fg-muted);
  font-family: var(--fc-font-ui);
  font-size: 12px;
  font-style: normal;
}

/* 词典分组卡 = popup.css 的 M3E 分段卡片（html.fushi-m3e .glossary-group）：
   surfaceContainer 色块、组首尾大圆角、组内小圆角、卡间 2px */
.fc-dicts {
  display: flex;
  flex-direction: column;
  gap: 2px;
}

.fc-dict {
  min-width: 0;
  padding: 0 var(--fc-pad);
  border-radius: var(--fc-radius-inner);
  background: var(--fc-surface-1);
  transition: background-color 140ms ease;
}

.fc-dict[open] {
  padding-bottom: calc(var(--fc-pad) - 4px);
}

.fc-dicts > .fc-dict:first-child {
  border-top-left-radius: var(--fc-radius);
  border-top-right-radius: var(--fc-radius);
}

.fc-dicts > .fc-dict:last-child {
  border-bottom-left-radius: var(--fc-radius);
  border-bottom-right-radius: var(--fc-radius);
}

/* 词典名（卡头）：title-small、onSurfaceVariant，整行是折叠目标，箭头在行尾
   （popup.css html.fushi-m3e .dict-label） */
.fc-dict-label {
  display: flex;
  align-items: center;
  gap: 8px;
  min-height: var(--fc-tap);
  list-style: none;
  color: var(--fc-fg-muted);
  font-family: var(--fc-font-ui);
  font-size: 14px;
  line-height: 20px;
  font-weight: 500;
  letter-spacing: 0.01em;
  cursor: pointer;
  -webkit-user-select: none;
  user-select: none;
}

.fc-dict-label::-webkit-details-marker {
  display: none;
}

.fc-dict-name {
  flex: 1 1 auto;
  min-width: 0;
  padding: 2px 0;
  overflow-wrap: anywhere;
}

/* 折叠箭头：描边 chevron，只旋转不换盒子（popup.css BUG-2049） */
.fc-dict-label::after {
  content: "";
  flex: 0 0 auto;
  width: 8px;
  height: 8px;
  margin-right: 4px;
  border-right: 2px solid currentColor;
  border-bottom: 2px solid currentColor;
  transform: rotate(-45deg);
  transition: transform 200ms cubic-bezier(0.2, 0, 0, 1);
  opacity: 0.8;
}

.fc-dict[open] > .fc-dict-label::after {
  transform: rotate(45deg);
}

@media (hover: hover) {
  .fc-dict:not([open]):hover {
    background: var(--fc-surface-2);
  }

  .fc-dict-label:hover {
    color: var(--fc-fg);
  }
}

/* 主释义：词典名降成小字说明，不需要折叠的视觉暗示 */
.fc-gloss--main .fc-dict-label {
  min-height: 34px;
  font-size: 12px;
  pointer-events: none;
}

.fc-gloss--main .fc-dict-label::after {
  display: none;
}

.fc-dict-items {
  margin: 0;
  padding-left: 1.6em;
}

.fc-dict-items > li {
  margin: 2px 0;
}

.fc-dict-items > li + li {
  margin-top: 8px;
}

/* 一部词典只有一条时不编号（popup 只在多义项时出序号） */
.fc-dict-items:has(> li:only-child) {
  padding-left: 0;
  list-style: none;
}

.fc-dict-items > li::marker {
  color: var(--fc-fg-muted);
  font-family: var(--fc-font-ui);
  font-size: 0.85em;
}

/* 义项标签（词性等）：popup.css .glossary-tag 的小号 tonal chip */
.fc-tags {
  display: inline-flex;
  flex-wrap: wrap;
  gap: 4px;
  margin-right: 4px;
  vertical-align: 0.1em;
}

.fc-tags:empty {
  display: none;
}

.fc-tag {
  padding: 2px 6px;
  border-radius: 4px;
  background: var(--fc-surface-2);
  color: var(--fc-fg-muted);
  font-family: var(--fc-font-ui);
  font-size: 11px;
  line-height: 1.2;
}

/* 结构化内容的列表缩进（popup.css :where(.glossary-group > div[data-dictionary]) ul/ol/li） */
.fc-gloss :where(li[data-dictionary]) :where(ul, ol) {
  padding-left: 1.2em;
  margin: 2px 0;
}

.fc-gloss :where(li[data-dictionary]) :where(li) {
  margin: 1px 0;
}

/* 结构化内容表格（popup.css .gloss-sc-table*） */
.fc-gloss .gloss-sc-table-container {
  display: block;
  max-width: 100%;
  overflow-x: auto;
  -webkit-overflow-scrolling: touch;
}

.fc-gloss .gloss-sc-table {
  table-layout: auto;
  border-collapse: collapse;
}

.fc-gloss :where(.gloss-sc-thead, .gloss-sc-tfoot, .gloss-sc-th) {
  font-weight: bold;
  background-color: var(--fc-surface-2);
}

.fc-gloss :where(.gloss-sc-th, .gloss-sc-td) {
  border: 1px solid var(--fc-outline);
  padding: 0.25em;
  vertical-align: top;
}

/* 词典图片（popup.css .gloss-image*；导出时多数几何已内联，这里只兜宽度与深色单色图） */
.fc-gloss .gloss-image-link {
  display: inline-block;
  position: relative;
  max-width: 100%;
  line-height: 1;
}

.fc-gloss .gloss-image-container {
  max-width: 100%;
}

.fc-gloss img:not(.gloss-image) {
  max-width: 100%;
  height: auto;
}

.nightMode .fc-gloss .gloss-image-link[data-appearance="monochrome"] img.gloss-image {
  filter: brightness(0) invert(1);
}

/* 词典注音：原生 ruby，注音 0.6em（popup.css 注音字号的单一真相） */
.fc-gloss ruby {
  ruby-position: over;
}

.fc-gloss ruby rt {
  font-size: 0.6em;
}

/* 词典的署名行在卡面上没有信息量（同 Lapis） */
.fc-gloss [data-sc-content="attribution"],
.fc-gloss [data-sc-content="graphic-attribution"] {
  display: none;
}

/* 查词弹窗里用户选中的释义片段（popup.js applyGlossarySelectionHighlight 的 <mark>） */
.fc-gloss mark {
  background: var(--fc-highlight) !important;
  color: inherit !important;
  border-radius: 2px;
}

.fc-gloss a {
  color: var(--fc-link);
}

/* 深色下词典内联底色（为白纸设计的浅色色块）统一换成中性 chip（popup.css BUG-851）。
   只给「保留词典样式」模式：统一模式（fushi-srs-dict-unified + fc-dt-ready）自己按令牌着色；
   宿主量词典原色期间（fc-dt-measuring）也让路，否则量到的是这里的灰。 */
.nightMode .fc-gloss li[data-dictionary]:not(.fc-dt-measuring):not(.fc-dt-ready) [class^="gloss-sc-"][style*="background"],
.nightMode:not(.fushi-srs-dict-unified) .fc-gloss li[data-dictionary].fc-dt-ready [class^="gloss-sc-"][style*="background"] {
  background-color: color-mix(in srgb, var(--fc-fg) 14%, transparent) !important;
  color: inherit !important;
}

/* ================================================================
 * 4. 统一词典样式（M3E）
 *
 * 宿主脚本（fushi/lib/src/srs/srs_card_dict_style.dart，移植自 popup.js）量出每个元素的语义写成
 * data-fushi-dt*，并给每个词条（li[data-dictionary]）挂 fc-dt-ready；宿主类名
 * fushi-srs-dict-unified 是开关。全部选择器包在 :where() 里，特异度为 0：!important 压过词典的
 * inline style 与 styles.css，又让用户自己写的 !important 规则照样生效。只换颜色类声明，字号 /
 * 边距 / ruby / 表格结构 / 图片一概不动。卡面自己画的组件（.fc-tags）不参与。
 * ================================================================ */

:where(.fushi-srs-dict-unified .fc-gloss li.fc-dt-ready) {
  color: var(--fc-fg) !important;
}

:where(.fushi-srs-dict-unified .fc-gloss li.fc-dt-ready) :where(*:not(img, svg, svg *, canvas, video, picture, .gloss-image-background, .fc-tags, .fc-tag)),
:where(.fushi-srs-dict-unified .fc-gloss li.fc-dt-ready) :where(*:not(.fc-tags, .fc-tag))::before,
:where(.fushi-srs-dict-unified .fc-gloss li.fc-dt-ready) :where(*:not(.fc-tags, .fc-tag))::after {
  color: inherit !important;
  background-color: transparent !important;
  border-color: var(--fc-outline) !important;
  text-decoration-color: currentColor !important;
  text-emphasis-color: currentColor !important;
  -webkit-text-fill-color: currentColor !important;
}

:where(.fushi-srs-dict-unified .fc-gloss li.fc-dt-ready) :where(a) {
  color: var(--fc-link) !important;
}

:where(.fushi-srs-dict-unified .fc-gloss li.fc-dt-ready) :where(th, .gloss-sc-th) {
  background-color: var(--fc-surface-2) !important;
}

/* 彩色强调字 → accent；灰字 → muted；显式黑字 → 正文色。 */
:where(.fushi-srs-dict-unified .fc-gloss li.fc-dt-ready) :where([data-fushi-dt="accent"]),
:where(.fushi-srs-dict-unified .fc-gloss li.fc-dt-ready) :where([data-fushi-dt-before="accent"])::before,
:where(.fushi-srs-dict-unified .fc-gloss li.fc-dt-ready) :where([data-fushi-dt-after="accent"])::after {
  color: var(--fc-accent) !important;
}

:where(.fushi-srs-dict-unified .fc-gloss li.fc-dt-ready) :where([data-fushi-dt="muted"]) {
  color: var(--fc-fg-muted) !important;
}

:where(.fushi-srs-dict-unified .fc-gloss li.fc-dt-ready) :where([data-fushi-dt="plain"]) {
  color: var(--fc-fg) !important;
}

/* 渐变底（无论最终归到哪类）一律抹平；url() 图片底不动。 */
:where(.fushi-srs-dict-unified .fc-gloss li.fc-dt-ready) :where([data-fushi-dt="flat"], [data-fushi-dt="chip"], [data-fushi-dt="block"], [data-fushi-dt="panel"]) {
  background-image: none !important;
}

/* 标签 / 徽标 → M3E tonal chip。 */
:where(.fushi-srs-dict-unified .fc-gloss li.fc-dt-ready) :where([data-fushi-dt="chip"]),
:where(.fushi-srs-dict-unified .fc-gloss li.fc-dt-ready) :where([data-fushi-dt-before="chip"])::before,
:where(.fushi-srs-dict-unified .fc-gloss li.fc-dt-ready) :where([data-fushi-dt-after="chip"])::after {
  color: var(--fc-on-secondary-container) !important;
  background-color: var(--fc-secondary-container) !important;
  background-image: none !important;
  border-color: transparent !important;
  border-radius: 6px !important;
}

/* 词典原本零内边距的标签：补一点水平内边距，否则圆角色块贴着字。 */
:where(.fushi-srs-dict-unified .fc-gloss li.fc-dt-ready) :where([data-fushi-dt-pad]) {
  padding-left: 0.3em !important;
  padding-right: 0.3em !important;
}

/* 描框的短标签 → outlined chip。 */
:where(.fushi-srs-dict-unified .fc-gloss li.fc-dt-ready) :where([data-fushi-dt="chip-outline"]) {
  color: var(--fc-fg-muted) !important;
  border-color: var(--fc-outline-strong) !important;
  border-radius: 6px !important;
}

/* 深色 / 饱和底的块（大字框）→ primaryContainer。 */
:where(.fushi-srs-dict-unified .fc-gloss li.fc-dt-ready) :where([data-fushi-dt="block"]) {
  color: var(--fc-on-accent-container) !important;
  background-color: var(--fc-accent-container) !important;
  border-color: transparent !important;
  border-radius: 12px !important;
}

/* 浅色底纹块（例句底色）→ surfaceContainerHighest（词典卡本身是 surfaceContainer，再低一级就糊成一片）。 */
:where(.fushi-srs-dict-unified .fc-gloss li.fc-dt-ready) :where([data-fushi-dt="panel"]) {
  background-color: var(--fc-surface-3) !important;
  border-radius: 12px !important;
}

/* 容器里的链接跟随容器的 on-color，不在色块上再叠一层强调色。 */
:where(.fushi-srs-dict-unified .fc-gloss li.fc-dt-ready) :where([data-fushi-dt="chip"], [data-fushi-dt="block"]) :where(a) {
  color: inherit !important;
}

/* ================================================================
 * 5. 图片放大层与减弱动态效果
 * ================================================================ */

.fc-lightbox {
  position: fixed;
  inset: 0;
  z-index: 10;
  display: flex;
  align-items: center;
  justify-content: center;
  padding: 16px;
  background: color-mix(in srgb, var(--fc-bg) 82%, transparent);
  -webkit-backdrop-filter: blur(8px);
  backdrop-filter: blur(8px);
  opacity: 0;
  pointer-events: none;
  transition: opacity 180ms ease;
}

.fc-lightbox--open {
  opacity: 1;
  pointer-events: auto;
}

.fc-lightbox img {
  max-width: 100%;
  max-height: 100%;
  border-radius: var(--fc-radius-small);
  object-fit: contain;
}

@media (prefers-reduced-motion: reduce) {
  .fc *,
  .fc *::before,
  .fc *::after {
    transition: none !important;
  }
}

/* ---------- Fushi 复习页混合渲染：释义区单独进 WebView ----------
   词条 / 读音 / 例句 / 词频 / 来源由 Fushi 原生绘制，这一页只有释义区：不分栏。
   Anki 里不会出现 fc-defs-only，这几条不生效。 */
.fc-back.fc-defs-only,
.fc-back.fc-defs-only.fc-layout-wide {
  display: flex;
  padding-bottom: 0;
}
''';
