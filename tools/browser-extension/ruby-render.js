// 字幕文本渲染（含振假名）。
//
// cue.text 永远只有正文（读音在采集时就被分了出去，见 subtitle-providers.js 的 fushiCollectCueSegments
// 与 subtitle-adapters.js 的 splitCueRuby——`<rt>` 的内容拼进正文会让读音和正文变成同级文字，
// 还会污染查词与制卡 sentence）。cue.ruby 是「正文段 + 可选读音」的序列，有它就画真正的
// `<ruby><rt>`，振假名回到正文上方。
//
// 字幕列表与视频上的覆盖层**共用这一份**：两个表面各写一份正是 BUG-1210 那个病。
(function () {
  'use strict';

  // 把 cue 渲染进 el（会先清空）。返回是否画了振假名。
  window.fushiRenderCueText = function (el, cue) {
    if (!el) return false;
    var text = String((cue && cue.text) || '');
    var segments = cue && Array.isArray(cue.ruby) ? cue.ruby : null;
    if (!segments || !segments.length) {
      el.textContent = text; // 无注音：与从前完全一样的一个文本节点
      return false;
    }
    el.textContent = '';
    var drew = false;
    for (var i = 0; i < segments.length; i++) {
      var seg = segments[i] || {};
      var base = String(seg.text || '');
      if (!base) continue;
      var reading = String(seg.reading || '');
      if (!reading) {
        el.appendChild(document.createTextNode(base));
        continue;
      }
      var ruby = document.createElement('ruby');
      ruby.appendChild(document.createTextNode(base));
      var rt = document.createElement('rt');
      rt.textContent = reading;
      ruby.appendChild(rt);
      el.appendChild(ruby);
      drew = true;
    }
    if (!el.childNodes.length) {
      el.textContent = text; // 段序列全空：退回正文，绝不留下一行空白
      return false;
    }
    return drew;
  };
})();
