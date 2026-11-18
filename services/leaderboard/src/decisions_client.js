// 拍板台 /dev/decisions 的客户端脚本，由 GET /dev/decisions.js 原样下发（CSP script-src 'self'）。
//
// 用字符串而不是函数 toString：wrangler 的 esbuild 默认 keepNames，会往函数体里插 __name(...)，浏览器里没有这个符号。
// 所以脚本本体里不能出现反引号和美元加花括号（String.raw 模板会把它们当插值）。
//
// 做的事：
//   - 切栏：本地按 data-stage / data-never 过滤，history.replaceState 改地址，不请求服务端；
//   - 拍板 / 留言：拦截表单提交，fetch 带 Accept: application/json，只把回来的那一张卡换掉；
//     离开当前栏的卡淡出，焦点自动移到下一条；底部提示可撤销（恢复为上一个决定）；
//   - 同步：页面可见时每 20 秒、切回页面时立即，带签名请求 /dev/decisions.json，有变化才换卡；
//     正在写的留言草稿与焦点在换卡后原样恢复；
//   - 附件：把文件拖到卡片上、在留言框里粘贴截图、或点「上传附件」选文件，逐个 POST /dev/d/:id/files（multipart），
//     传完换卡；
//   - 键盘：J/K 移动，1…6 做 / 方案，X 不做，L 以后，N 永远不做，E 没看懂，D 要设计图，Y 你定，C 写留言，U 撤销，
//     Ctrl+Enter 只发留言，Esc 离开输入框。

export const DECISIONS_CLIENT_JS = String.raw`(function () {
  'use strict';
  var list = document.getElementById('dlist');
  if (!list) return;
  var tabs = document.getElementById('dtabs');
  var empty = document.getElementById('dempty');
  var toastBox = document.getElementById('dtoast');
  var syncEl = document.getElementById('dsync');
  var stage = list.getAttribute('data-stage') || 'todo';
  var sig = list.getAttribute('data-sig') || '';
  var syncing = false;
  var lastSync = Date.now();
  var SYNC_MS = 20000;

  var ERRORS = {
    decision_closed: '这条已经结单，不能再改',
    dev_session_required: '登录已过期，请刷新页面重新登录',
    bad_origin: '请求来源不对，请刷新页面',
    note_too_long: '留言太长了',
    bad_choice: '方案不存在',
    bad_verdict: '决定不合法',
    not_found: '这条已不存在',
    rate_limited: '操作太频繁，稍等再试',
    body_too_large: '留言太长了',
    no_file: '没有可上传的文件',
    too_many_files: '每条最多 10 个附件',
    bad_file_type: '只收 html / md / txt / 图片',
    bad_file_name: '文件名太长',
    file_too_large: '单个文件不能超过 10 MB',
    bad_upload: '上传格式不对'
  };
  var UPLOAD_EXT = /\.(html?|md|markdown|txt|png|jpe?g|webp|gif|svg)$/i;
  var UPLOAD_MAX = 10 * 1024 * 1024;

  function cards() { return Array.prototype.slice.call(list.querySelectorAll('article.dcard')); }
  function visibleCards() { return cards().filter(function (c) { return !c.hidden; }); }
  function inStage(c, s) {
    if (s === 'all') return true;
    if (s === 'never') return c.getAttribute('data-never') === '1';
    return c.getAttribute('data-stage') === s;
  }
  function pad(n) { return n < 10 ? '0' + n : String(n); }
  function hhmm(d) { return pad(d.getHours()) + ':' + pad(d.getMinutes()); }

  // ---- 提示条 ----
  function toast(text, opts) {
    opts = opts || {};
    var el = document.createElement('div');
    el.className = 'toast' + (opts.error ? ' err' : '');
    var span = document.createElement('span');
    span.textContent = text;
    el.appendChild(span);
    if (opts.action) {
      var b = document.createElement('button');
      b.type = 'button';
      b.textContent = opts.action.label;
      b.addEventListener('click', function () { el.remove(); opts.action.run(); });
      el.appendChild(b);
    }
    while (toastBox.children.length >= 3) toastBox.firstChild.remove();
    toastBox.appendChild(el);
    setTimeout(function () { el.remove(); }, opts.ms || (opts.action ? 8000 : 4000));
  }

  // ---- 栏与计数 ----
  function refreshCounts() {
    var all = cards();
    Array.prototype.forEach.call(tabs.querySelectorAll('a[data-stage]'), function (a) {
      var s = a.getAttribute('data-stage');
      var n = all.filter(function (c) { return inStage(c, s); }).length;
      var el = a.querySelector('.n');
      if (el) el.textContent = String(n);
    });
    var todo = all.filter(function (c) { return inStage(c, 'todo'); }).length;
    document.title = (todo ? '(' + todo + ') ' : '') + '拍板台 · Fushi 反馈处理台';
  }
  function applyFilter() {
    var shown = 0;
    cards().forEach(function (c) {
      var on = inStage(c, stage);
      c.hidden = !on;
      if (on) shown++;
    });
    empty.hidden = shown > 0;
    empty.textContent = stage === 'todo' ? '没有待拍的了。' : '这一栏是空的。';
    refreshCounts();
  }
  function setStage(s, push) {
    stage = s;
    list.setAttribute('data-stage', s);
    Array.prototype.forEach.call(tabs.querySelectorAll('a[data-stage]'), function (a) {
      a.classList.toggle('on', a.getAttribute('data-stage') === s);
    });
    Array.prototype.forEach.call(list.querySelectorAll('input[name=back]'), function (i) { i.value = s; });
    if (push) history.replaceState(null, '', '/dev/decisions?stage=' + s);
    applyFilter();
    var first = visibleCards()[0];
    setCurrent(first || null, false);
  }
  tabs.addEventListener('click', function (e) {
    var a = e.target.closest('a[data-stage]');
    if (!a || e.ctrlKey || e.metaKey || e.shiftKey || e.button !== 0) return;
    e.preventDefault();
    setStage(a.getAttribute('data-stage'), true);
    window.scrollTo({ top: 0 });
  });

  // ---- 当前卡（键盘焦点） ----
  var current = null;
  function setCurrent(c, scroll) {
    if (current) current.classList.remove('cur');
    current = c;
    if (!c) return;
    c.classList.add('cur');
    if (scroll) c.scrollIntoView({ block: 'nearest', behavior: 'smooth' });
  }
  function move(delta) {
    var vis = visibleCards();
    if (!vis.length) return;
    var i = current ? vis.indexOf(current) : -1;
    var next = vis[Math.max(0, Math.min(vis.length - 1, i < 0 ? 0 : i + delta))];
    setCurrent(next, true);
  }
  list.addEventListener('focusin', function (e) {
    var c = e.target.closest('article.dcard');
    if (c && c !== current) setCurrent(c, false);
  });
  list.addEventListener('pointerdown', function (e) {
    var c = e.target.closest('article.dcard');
    if (c && c !== current) setCurrent(c, false);
  });

  // ---- 换卡（保留草稿与焦点） ----
  function parse(html) {
    var t = document.createElement('template');
    t.innerHTML = html.trim();
    return t.content.firstElementChild;
  }
  function autoGrow(ta) {
    ta.style.height = 'auto';
    ta.style.height = Math.min(ta.scrollHeight + 2, 360) + 'px';
  }
  function swap(old, item) {
    var el = parse(item.html);
    el.querySelectorAll('input[name=back]').forEach(function (i) { i.value = stage; });
    var oldTa = old.querySelector('textarea');
    var newTa = el.querySelector('textarea');
    var hadFocus = oldTa && document.activeElement === oldTa;
    if (oldTa && newTa && oldTa.value) {
      newTa.value = oldTa.value;
      autoGrow(newTa);
    }
    el.hidden = !inStage(el, stage);
    var wasCurrent = old === current;
    old.replaceWith(el);
    if (wasCurrent) setCurrent(el, false);
    if (hadFocus && newTa) {
      var pos = oldTa.selectionStart;
      newTa.focus();
      try { newTa.setSelectionRange(pos, pos); } catch (err) { /* 忽略 */ }
    }
    return el;
  }

  // ---- 提交 ----
  function verdictLabel(card, v) {
    if (v === 'clear') return '已撤销决定';
    var b = card.querySelector('button[name=v][value="' + v + '"]');
    var label = b ? b.firstChild.textContent : v;
    return '已定为「' + label + '」';
  }
  function send(card, v, text) {
    var form = card.querySelector('form.dform');
    if (!form || card.classList.contains('busy')) return;
    var id = card.getAttribute('data-id');
    var prev = card.getAttribute('data-verdict') || '';
    var body = new URLSearchParams();
    body.set('v', v);
    body.set('text', text || '');
    body.set('back', stage);
    // 乐观锁：带上这张卡上看到的决定，别人先改了服务端回 409 + 最新的卡。
    body.set('base', prev);
    card.classList.add('busy');
    fetch(form.action, {
      method: 'POST',
      body: body,
      credentials: 'same-origin',
      headers: { Accept: 'application/json' }
    }).then(function (res) {
      return res.json().catch(function () { return {}; }).then(function (data) {
        if (res.status === 409 && data.error === 'verdict_conflict' && data.item) {
          // 换上最新的卡（草稿留在框里），告诉是谁刚拍的，不覆盖。
          var el = swap(card, data.item);
          if (data.sig) { sig = data.sig; list.setAttribute('data-sig', sig); }
          el.classList.add('fresh');
          applyFilter();
          if (!el.hidden) setCurrent(el, true);
          var who = el.querySelector('.dverdict');
          var e = new Error((who ? who.textContent.replace(/ · .*$/, '') : '别人刚改了这条的决定')
            + '。你的决定没有提交' + (text ? '，留言还在框里' : '') + '，看过后再拍');
          e.conflict = true;
          throw e;
        }
        if (!res.ok) throw new Error(ERRORS[data.error] || ('提交失败（' + (data.error || res.status) + '）'));
        return data;
      });
    }).then(function (data) {
      var vis = visibleCards();
      var idx = vis.indexOf(card);
      var item = data.item;
      var leaves = !(stage === 'all' || (stage === 'never' ? item.never : item.stage === stage));
      // 留言已随这次提交发出：清掉框里的这段（提交期间又改过的就留着，免得吞掉新写的）。
      var sentTa = card.querySelector('textarea');
      if (sentTa && text && sentTa.value === text) sentTa.value = '';
      var finish = function () {
        var el = swap(card, item);
        if (data.sig) { sig = data.sig; list.setAttribute('data-sig', sig); }
        applyFilter();
        if (leaves) {
          var rest = visibleCards();
          setCurrent(rest[Math.min(idx, rest.length - 1)] || null, true);
        } else {
          setCurrent(el, false);
        }
      };
      if (leaves) {
        card.classList.add('leaving');
        setTimeout(finish, 180);
      } else {
        finish();
      }
      if (v === 'note') {
        toast('留言已发送');
      } else if (prev !== v) {
        toast(verdictLabel(card, v) + (text ? '，留言已发送' : ''), {
          action: { label: '撤销', run: function () {
            var now = document.getElementById('d-' + id);
            if (now) send(now, prev || 'clear', '');
          } }
        });
      }
    }).catch(function (err) {
      card.classList.remove('busy');
      toast(err.message || '网络错误，没有提交成功', { error: true, ms: err.conflict ? 10000 : 6000 });
    });
  }

  list.addEventListener('submit', function (e) {
    var form = e.target.closest('form.dform');
    if (!form) return;
    e.preventDefault();
    var btn = e.submitter;
    var v = btn && btn.name === 'v' ? btn.value : 'note';
    var ta = form.querySelector('textarea');
    var text = ta ? ta.value : '';
    if (v === 'note' && !text.trim()) {
      if (ta) ta.focus();
      toast('先写点什么再发留言');
      return;
    }
    send(form.closest('article.dcard'), v, text);
  });

  // ---- 附件上传（拖放 / 粘贴 / 选文件） ----
  function upload(card, files) {
    if (!card || !card.querySelector('form.dupload')) { toast('这条已结单，不能再传附件', { error: true }); return; }
    if (card.classList.contains('busy')) return;
    var id = card.getAttribute('data-id');
    var action = card.querySelector('form.dupload').action;
    var ok = [];
    for (var i = 0; i < files.length; i++) {
      var f = files[i];
      if (!UPLOAD_EXT.test(f.name)) { toast(f.name + '：' + ERRORS.bad_file_type, { error: true }); continue; }
      if (f.size > UPLOAD_MAX) { toast(f.name + '：' + ERRORS.file_too_large, { error: true }); continue; }
      ok.push(f);
    }
    if (!ok.length) return;
    card.classList.add('busy');
    toast('正在上传 ' + ok.length + ' 个文件…');
    var last = null;
    var chain = Promise.resolve();
    ok.forEach(function (f) {
      chain = chain.then(function () {
        var fd = new FormData();
        fd.append('file', f, f.name);
        fd.append('back', stage);
        return fetch(action, {
          method: 'POST',
          body: fd,
          credentials: 'same-origin',
          headers: { Accept: 'application/json' }
        }).then(function (res) {
          return res.json().catch(function () { return {}; }).then(function (data) {
            if (!res.ok) throw new Error(f.name + '：' + (ERRORS[data.error] || ('上传失败（' + (data.error || res.status) + '）')));
            last = data;
          });
        });
      });
    });
    chain.then(function () {
      toast('已上传 ' + ok.length + ' 个文件');
    }).catch(function (err) {
      toast(err.message || '网络错误，上传没有完成', { error: true, ms: 8000 });
    }).then(function () {
      var now = document.getElementById('d-' + id) || card;
      now.classList.remove('busy');
      if (last && last.item) {
        var el = swap(now, last.item);
        if (last.sig) { sig = last.sig; list.setAttribute('data-sig', sig); }
        applyFilter();
        setCurrent(el, false);
      }
    });
  }

  list.addEventListener('change', function (e) {
    var t = e.target;
    if (t.tagName !== 'INPUT' || t.type !== 'file' || !t.files || !t.files.length) return;
    var files = Array.prototype.slice.call(t.files);
    t.value = '';
    upload(t.closest('article.dcard'), files);
  });

  function hasFiles(e) {
    var types = e.dataTransfer && e.dataTransfer.types;
    return !!types && Array.prototype.indexOf.call(types, 'Files') >= 0;
  }
  var dragCard = null;
  function setDrag(c) {
    if (dragCard === c) return;
    if (dragCard) dragCard.classList.remove('dragover');
    dragCard = c;
    if (c) c.classList.add('dragover');
  }
  document.addEventListener('dragover', function (e) {
    if (!hasFiles(e)) return;
    // 整页都接住拖放，免得没落在卡片上时浏览器直接打开文件。
    e.preventDefault();
    var c = e.target.closest && e.target.closest('article.dcard');
    var can = c && c.querySelector('form.dupload');
    e.dataTransfer.dropEffect = can ? 'copy' : 'none';
    setDrag(can ? c : null);
  });
  document.addEventListener('dragleave', function (e) {
    if (!e.relatedTarget || e.relatedTarget === document.documentElement) setDrag(null);
  });
  document.addEventListener('drop', function (e) {
    if (!hasFiles(e)) return;
    e.preventDefault();
    var c = e.target.closest && e.target.closest('article.dcard');
    setDrag(null);
    if (!c) { toast('把文件拖到某一条卡片上'); return; }
    upload(c, Array.prototype.slice.call(e.dataTransfer.files));
  });
  list.addEventListener('paste', function (e) {
    var files = e.clipboardData && e.clipboardData.files;
    if (!files || !files.length) return;
    e.preventDefault();
    upload(e.target.closest('article.dcard'), Array.prototype.slice.call(files));
  });

  list.addEventListener('input', function (e) {
    if (e.target.tagName === 'TEXTAREA') autoGrow(e.target);
  });

  // ---- 键盘 ----
  document.addEventListener('keydown', function (e) {
    var t = e.target;
    var typing = t && (t.tagName === 'TEXTAREA' || t.tagName === 'INPUT' || t.isContentEditable);
    if (typing) {
      if (t.tagName === 'TEXTAREA' && e.key === 'Enter' && (e.ctrlKey || e.metaKey)) {
        e.preventDefault();
        var c = t.closest('article.dcard');
        if (!t.value.trim()) { toast('先写点什么再发留言'); return; }
        if (c) send(c, 'note', t.value);
      } else if (e.key === 'Escape') {
        t.blur();
        var cc = t.closest('article.dcard');
        if (cc) cc.focus({ preventScroll: true });
      }
      return;
    }
    if (e.ctrlKey || e.metaKey || e.altKey) return;
    var k = e.key.toLowerCase();
    if (k === 'j') { e.preventDefault(); move(1); return; }
    if (k === 'k') { e.preventDefault(); move(-1); return; }
    if (!current || current.hidden) {
      if ('123456xlnedycu'.indexOf(k) >= 0) { move(0); }
      return;
    }
    if (k === 'c') {
      var ta = current.querySelector('textarea');
      if (ta) { e.preventDefault(); ta.focus(); }
      return;
    }
    var b = current.querySelector('button[data-key="' + k + '"]');
    if (!b) return;
    e.preventDefault();
    var tx = current.querySelector('textarea');
    send(current, b.value, tx ? tx.value : '');
  });

  // ---- 同步 ----
  function showSynced() {
    if (syncEl) syncEl.textContent = '已同步 ' + hhmm(new Date());
  }
  function sync() {
    if (syncing || document.visibilityState !== 'visible') return;
    syncing = true;
    fetch('/dev/decisions.json?sig=' + encodeURIComponent(sig), {
      credentials: 'same-origin',
      headers: { Accept: 'application/json' }
    }).then(function (res) {
      if (res.status === 401) throw new Error(ERRORS.dev_session_required);
      if (!res.ok) throw new Error('同步失败（' + res.status + '）');
      return res.json();
    }).then(function (data) {
      lastSync = Date.now();
      showSynced();
      if (data.same) return;
      sig = data.sig;
      list.setAttribute('data-sig', sig);
      var byId = {};
      cards().forEach(function (c) { byId[c.getAttribute('data-id')] = c; });
      var seen = {};
      var added = 0;
      var prevTodo = cards().filter(function (c) { return inStage(c, 'todo'); }).length;
      data.items.forEach(function (item, i) {
        seen[item.id] = true;
        var old = byId[item.id];
        var el;
        if (!old) {
          el = parse(item.html);
          el.querySelectorAll('input[name=back]').forEach(function (inp) { inp.value = stage; });
          el.classList.add('fresh');
          added++;
        } else if (old.getAttribute('data-v') !== item.v && !old.classList.contains('busy')) {
          el = swap(old, item);
          el.classList.add('fresh');
        } else {
          el = old;
        }
        var at = list.children[i];
        if (at !== el) list.insertBefore(el, at || null);
      });
      Object.keys(byId).forEach(function (id) {
        if (seen[id]) return;
        if (byId[id] === current) current = null;
        byId[id].remove();
      });
      applyFilter();
      var nowTodo = cards().filter(function (c) { return inStage(c, 'todo'); }).length;
      if (added) toast('来了 ' + added + ' 条新事项');
      else if (nowTodo > prevTodo) toast('有 ' + (nowTodo - prevTodo) + ' 条回到待拍');
      if (!current) setCurrent(visibleCards()[0] || null, false);
    }).catch(function (err) {
      if (syncEl) syncEl.textContent = err.message;
    }).then(function () { syncing = false; });
  }
  setInterval(function () { if (Date.now() - lastSync >= SYNC_MS) sync(); }, 5000);
  document.addEventListener('visibilitychange', function () { if (document.visibilityState === 'visible') sync(); });
  window.addEventListener('focus', function () { if (Date.now() - lastSync > 3000) sync(); });

  // ---- 初始 ----
  var hash = location.hash && document.getElementById(location.hash.slice(1));
  if (hash && hash.matches('article.dcard')) {
    if (hash.hidden) setStage('all', true);
    setCurrent(hash, true);
  } else {
    setCurrent(visibleCards()[0] || null, false);
  }
  refreshCounts();
  showSynced();
})();
`;
