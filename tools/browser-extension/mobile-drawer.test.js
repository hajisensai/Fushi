'use strict';
// mobile-drawer.js 行为测试（vm 假 DOM，全链一条）：横屏仅限全屏挂载的门控、竖屏底挂
// 交互、全屏右挂压播放器让位与 adopt 跟随自重排、快照还原往返、媒体全屏（fs 元素即
// video 本体，安卓站常态）可拖且只压本体、设置停用整体卸除。十六段共用一条状态机
// 链——正是抽屉真实生命周期；任何一环断掉都带中文现场抛出。
const { test } = require('node:test');
const fs = require('fs');
const path = require('path');
const vm = require('vm');

test('mobile-drawer 抽屉状态机全链（门控/底挂/让位/adopt/还原/卸除）', () => {
  const fs = require('fs');
  const vm = require('vm');
  const SRC = fs.readFileSync(path.join(__dirname, 'mobile-drawer.js'), 'utf8');

  function makeNode(tag) {
    const node = {
      nodeType: 1, tag, tagName: tag.toUpperCase(), children: [], parentNode: null, handlers: {}, attrs: {},
      style: {
        setProperty(k, v, p) { this[k] = v; (this.__prio = this.__prio || {})[k] = p || ''; },
        removeProperty(k) { delete this[k]; if (this.__prio) delete this.__prio[k]; },
        getPropertyValue(k) { return this[k] || ''; },
        getPropertyPriority(k) { return (this.__prio && this.__prio[k]) || ''; },
      },
      textContent: '', id: '', className: '',
      src: '', contentWindow: null,
      classSet: new Set(),
      _videos: [], _all: [], _rect: { left: 0, top: 0, right: 100, bottom: 100, width: 100, height: 100 },
      appendChild(child) {
        if (child.parentNode && child.parentNode !== this) child.parentNode.removeChild(child);
        this.children.push(child); child.parentNode = this; return child;
      },
      removeChild(child) { this.children = this.children.filter((c) => c !== child); child.parentNode = null; return child; },
      setAttribute(k, v) { this.attrs[k] = String(v); },
      removeAttribute(k) { delete this.attrs[k]; },
      getAttribute(k) { return this.attrs[k]; },
      addEventListener(type, fn) { (this.handlers[type] = this.handlers[type] || []).push(fn); },
      removeEventListener() {},
      dispatch(type, ev) { for (const fn of this.handlers[type] || []) fn(ev); },
      setPointerCapture() {},
      toggleAttribute() {},
      closest() { return null; },
      querySelectorAll(sel) { return sel === 'video' ? this._videos.slice() : this._all.slice(); },
      getBoundingClientRect() { return this._rect; },
    };
    node.classList = {
      toggle(name, on) { if (on === undefined) on = !node.classSet.has(name); on ? node.classSet.add(name) : node.classSet.delete(name); },
      contains(name) { return node.classSet.has(name); },
      add(name) { node.classSet.add(name); },
      remove(name) { node.classSet.delete(name); },
    };
    if (tag === 'iframe') {
      node.contentWindow = { postMessage(m, o) { (node.postMsg = node.postMsg || []).push({ m, o }); } };
    }
    return node;
  }

  const videoEl = makeNode('video');
  const htmlEl = makeNode('html');
  const body = makeNode('body');
  const captured = { message: [], storage: {}, interval: null, intervals: [], rafs: [], ticketSeq: 0, ticketOk: true };
  const document = {
    fullscreenElement: null,
    body,
    documentElement: htmlEl,
    querySelector(sel) { return sel === 'video' ? videoEl : null; },
    createElement: (t) => makeNode(t),
    addEventListener(type, fn) { (this._h = this._h || {}); ((this._h[type] = this._h[type] || []).push(fn)); },
    removeEventListener() {},
  };
  const storageArea = {
    get(keys, cb) { const out = {}; for (const k of [].concat(keys)) if (k in captured.storage) out[k] = captured.storage[k]; cb && cb(out); return Promise.resolve(out); },
    set(obj) { Object.assign(captured.storage, obj); return Promise.resolve(); },
    onChanged: { addListener(fn) { captured.storageOnChanged = fn; } },
  };
  const winHandlers = {};
  const win = {
    innerWidth: 800, innerHeight: 400,
    addEventListener(type, fn) { (winHandlers[type] = winHandlers[type] || []).push(fn); },
    removeEventListener(type, fn) { if (winHandlers[type]) winHandlers[type] = winHandlers[type].filter((f) => f !== fn); },
    dispatch(type, ev) { for (const fn of (winHandlers[type] || []).slice()) fn(ev); },
    matchMedia: (q) => ({ matches: q.indexOf('coarse') >= 0 }),
    setInterval(fn) { captured.interval = fn; captured.intervals.push(fn); return captured.intervals.length; },
  };
  const chrome = {
    runtime: {
      getURL: (p) => 'chrome-extension://aaa/' + p,
      sendMessage(msg, cb) { captured.message.push(msg); if (msg.type === 'drawerFrameTicket') cb && cb(captured.ticketOk === false ? { ok: false } : { ok: true, ticket: 'tkt-' + (++captured.ticketSeq) }); else cb && cb({}); },
      lastError: null,
    },
    storage: { local: storageArea, onChanged: storageArea.onChanged },
  };
  const sandbox = {
    window: win, document, chrome, console, Array,
    location: { origin: 'https://m.test', hostname: 'm.test' }, // content script 世界必有宿主页 location
    setTimeout: (fn) => { fn(); return 1; }, clearTimeout() {},
    requestAnimationFrame: (fn) => { captured.rafs.push(fn); return captured.rafs.length; },
    setInterval: win.setInterval, clearInterval() {}, Math, Number, Date, String, Object, JSON, Promise, isFinite, RegExp,
  };
  function flush() { while (captured.rafs.length) captured.rafs.shift()(); }
  const syncUi = () => captured.intervals[0](); // 脚本尾部第一支 setInterval = 900ms 轮询 syncUi（永久可指）
  const fsFire = () => (document._h.fullscreenchange || []).forEach((fn) => fn());
  vm.createContext(sandbox);
  vm.runInContext(SRC, sandbox);

  let root = null; let strip = null;
  function bindRoot(host) {
    root = (host.children || []).find((c) => c.id === 'fushi-drawer') || null;
    strip = root ? root.children[0] : null;
  }
  const T = () => root.style.transform;
  function down(x, y) { strip.dispatch('pointerdown', { pointerId: 1, pointerType: 'touch', clientX: x, clientY: y, preventDefault() {} }); }
  function move(x, y) { win.dispatch('pointermove', { pointerId: 1, clientX: x, clientY: y }); }
  function up(x, y) { win.dispatch('pointerup', { pointerId: 1, clientX: x, clientY: y }); flush(); }
  function cancel() { win.dispatch('pointercancel', { pointerId: 1 }); flush(); }
  function tap(x, y) { down(x, y); up(x, y); }
  function drag(x0, y0, x1, y1) { down(x0, y0); move(x1, y1); up(x1, y1); }

  // 0. 横屏非全屏 = 门拒挂（用户终局裁决：这种情况不开字幕列表）
  syncUi();
  if (body.children.length !== 0) throw new Error('横屏非全屏竟然挂载了抽屉');
  if (htmlEl.style.width || videoEl.style.width) throw new Error('门拒挂却污染了页面');

  // 1. 转竖屏 → 轮询放行挂载：底挂收起 full=800×0.48=384 → translateY(372)
  win.innerWidth = 400; win.innerHeight = 800;
  syncUi();
  bindRoot(body);
  if (!root) throw new Error('竖屏没挂载');
  if (!root.classList.contains('is-port') || root.classList.contains('is-land')) throw new Error('竖屏朝向类错');
  if (T() !== 'translateY(372px)') throw new Error('竖屏初始几何错: ' + T());
  if (root.style.height !== '384px') throw new Error('竖屏初始高度错: ' + root.style.height);

  // 2. 点开（竖屏页面态：iframe 懒建 + 零让位）→ 再点关
  tap(200, 790);
  const frame = root.children[1];
  if (!frame || frame.tag !== 'iframe') throw new Error('点开后 iframe 未建');
  // 身份只能是 SW 现发的一次性票据：绝不能再把 tabId/hostOrigin 写进 URL（嵌入方自证）。
  if (frame.src !== 'chrome-extension://aaa/side-panel.html?fushiTicket=tkt-1') throw new Error('帧 URL 不是票据形态: ' + frame.src);
  if (/fushiTabId|fushiHostOrigin/.test(frame.src)) throw new Error('URL 里再次出现了可伪造的身份参数: ' + frame.src);
  if (T() !== 'translateY(0px)') throw new Error('开态应贴零: ' + T());
  if (videoEl.style.width || videoEl.style.height || htmlEl.style.width || htmlEl.style.height) {
    throw new Error('非全屏竖屏绝不让位');
  }
  if (!frame.postMsg || frame.postMsg[0].m.type !== 'resume') throw new Error('开时没发 resume');
  if (frame.postMsg[0].o !== 'chrome-extension://aaa/side-panel.html') throw new Error('postMessage targetOrigin 没钉自己的扩展页');
  tap(200, 790);
  if (T() !== 'translateY(372px)') throw new Error('关态几何错: ' + T());
  if (frame.postMsg[1].m.type !== 'pause') throw new Error('关时没发 pause');

  // 3. 竖屏上拖自由停位：12+280×1.5=432（放大 1.5×），松手即宽高
  drag(200, 780, 200, 500);
  if (T() !== 'translateY(0px)') throw new Error('拖开没贴边: ' + T());
  if (Math.abs(parseFloat(root.style.height) - 432) > 1) throw new Error('自由停位没停在松手处: ' + root.style.height);
  if (Math.abs(captured.storage.mobileSubtitleDrawerGeom.portH - 432) > 1) throw new Error('竖屏尺寸没持久化');

  // 4. 再拖 → 60% 上限收住：拖出 1482 也只给到 480（800×0.6）
  drag(200, 700, 200, 0);
  if (Math.abs(parseFloat(root.style.height) - 480) > 1) throw new Error('拖高没收在上限: ' + root.style.height);

  // 5. 开态往回压：地板 260（=折叠头挤压一行极限宽，MIN_OPEN 与 CSS 对齐）拖不成细条，松手停 260
  down(200, 700);
  move(200, 1500);
  if (T() !== 'translateY(220px)') throw new Error('拖拽没被地板拦住: ' + T()); // 480-260
  up(200, 1500);
  if (Math.abs(parseFloat(root.style.height) - 260) > 1) throw new Error('该停在地板 260: ' + root.style.height);
  if (T() !== 'translateY(0px)') throw new Error('停地板后没贴边: ' + T());

  // 6. 拖到一半 pointercancel：有位移按松手结算（260+90=350），不弹跳
  down(200, 700);
  move(200, 640);
  cancel();
  if (Math.abs(parseFloat(root.style.height) - 350) > 1) throw new Error('cancel 没按松手结算: ' + root.style.height);
  tap(200, 790); // 轻点关：保留拖后的 350
  if (T() !== 'translateY(338px)') throw new Error('关态应保留拖后的高: ' + T());
  if (Math.abs(captured.storage.mobileSubtitleDrawerGeom.portH - 350) > 1) throw new Error('关后尺寸档案没更新');

  // 7. 横屏 + 进全屏 = 门放行（主形态）：迁移 host、is-fs、右挂收起 translateX(324)
  const fsEl = makeNode('div');
  const innerVideo = makeNode('video');
  innerVideo.style.height = '800px'; // 播放器写死的像素内联尺寸——快照必须能还原它
  innerVideo.style.setProperty('object-fit', 'fill', 'important'); // 站点原本拉伸填充
  fsEl.style.width = '100vw';        // 站点自己的内联宽：还原后必须原样还在
  innerVideo._rect = { left: 8, top: 60, right: 392, bottom: 476, width: 384, height: 416 };
  const ctrl = makeNode('div');
  ctrl.className = 'player-controls';
  ctrl._rect = { left: 0, top: 720, right: 400, bottom: 800, width: 400, height: 80 };
  fsEl._videos = [innerVideo];
  fsEl._all = [innerVideo, ctrl];
  win.innerWidth = 800; win.innerHeight = 400;
  document.fullscreenElement = fsEl;
  fsFire();
  flush();
  bindRoot(fsEl);
  if (!root || root.parentNode !== fsEl) throw new Error('没跟进全屏');
  if (!root.classList.contains('is-fs')) throw new Error('全屏态没打 is-fs');
  if (T() !== 'translateX(324px)') throw new Error('横屏全屏收起几何错: ' + T());

  // 8. 横屏全屏点开：压全屏容器 + video 联压(464) + 测缝钉左 + 控件条收宽（页面元素零污染）
  ctrl._rect = { left: 0, top: 360, right: 800, bottom: 400, width: 800, height: 40 }; // 横屏通宽进度条
  tap(780, 200);
  const frame2 = root.children[1];
  if (T() !== 'translateX(0px)') throw new Error('开态应贴零: ' + T());
  if (fsEl.style.width !== '464px' || fsEl.style.__prio.width !== 'important') throw new Error('全屏容器没让位: ' + fsEl.style.width);
  if (innerVideo.style.width !== '464px') throw new Error('内层 video 没联压: ' + innerVideo.style.width);
  if (innerVideo.style['object-fit'] !== 'contain' || innerVideo.style.__prio['object-fit'] !== 'important') throw new Error('压宽没锁住画面比例');
  if (innerVideo.style.position !== 'fixed' || innerVideo.style.left !== '0px' || innerVideo.style.top !== '60px') {
    throw new Error('横屏缝隙没吃掉: ' + innerVideo.style.position + '/' + innerVideo.style.left);
  }
  if (ctrl.style.width !== '464px' || ctrl.style.__prio.width !== 'important') throw new Error('横屏进度条没收进区域: ' + ctrl.style.width);
  if (htmlEl.style.width || videoEl.style.width) throw new Error('全屏让位污染了页面元素');
  if (!frame2 || frame2.tag !== 'iframe') throw new Error('host 迁移后 iframe 丢了');

  // 9. 播放器晚到的重排：adopt 吸真值→重压；幂等
  innerVideo.style.setProperty('width', '700px', '');
  captured.interval();
  if (innerVideo.style.width !== '464px') throw new Error('晚到重排后没重压: ' + innerVideo.style.width);
  captured.interval();
  if (innerVideo.style.width !== '464px') throw new Error('adopt 幂等性破了: ' + innerVideo.style.width);

  // 10. 全屏内转竖屏：钉位还原、压高重排、控件条上提；再上拖到 480（区域 320）
  win.innerWidth = 400; win.innerHeight = 800;
  ctrl._rect = { left: 0, top: 720, right: 400, bottom: 800, width: 400, height: 80 };
  win.dispatch('resize', {});
  flush();
  if (T() !== 'translateY(0px)') throw new Error('全屏内转竖屏没贴边: ' + T());
  if (innerVideo.style.position) throw new Error('竖屏没还原横屏钉位: ' + innerVideo.style.position);
  drag(200, 700, 200, 508); // 350(portH)+288=638 → 60% 封顶 480
  if (Math.abs(parseFloat(root.style.height) - 480) > 1) throw new Error('竖屏全屏拖高没到上限: ' + root.style.height);
  if (fsEl.style.height !== '320px') throw new Error('竖屏全屏容器没让位: ' + fsEl.style.height);
  if (innerVideo.style.height !== '260px') throw new Error('竖屏内层 video 压高不对: ' + innerVideo.style.height); // 320 - top60
  if (ctrl.style.bottom !== '480px') throw new Error('竖屏控件条没上提: ' + ctrl.style.bottom);

  // 11. 退出全屏（竖屏，门仍放行）：播放器同步重排 600 → adopt 重新起基，还原给它而不是旧快照
  innerVideo.style.setProperty('height', '600px', ''); // 退出时刻播放器已按页面重排
  document.fullscreenElement = null;
  bindRoot(body); // syncUi→attachToHost 回 body
  fsFire();
  flush();
  if (innerVideo.style.height !== '600px') throw new Error('退出全屏盖写了播放器重排: ' + innerVideo.style.height);
  if (ctrl.style.bottom || fsEl.style.height) throw new Error('退出全屏让位没还原干净: ' + ctrl.style.bottom + '/' + fsEl.style.height);

  // 12. 竖屏开着 → 转横屏非全屏：门翻转 → 即时卸除 + 页面零残留
  innerVideo.style.width = '640px';
  innerVideo.style.height = '360px';
  win.innerWidth = 800; win.innerHeight = 400;
  win.dispatch('resize', {});
  if (body.children.length !== 0 || fsEl.children.length !== 0) throw new Error('横屏非全屏没卸除');
  if (innerVideo.style.width !== '640px' || innerVideo.style['object-fit'] !== 'fill') throw new Error('卸除伤了播放器现值');
  if (htmlEl.style.width || videoEl.style.width) throw new Error('卸除后页面残留');

  // 13. 再进全屏：轮询重挂 + 开态恢复（st.open 一直 true）→ 新快照以横屏重排值起基
  document.fullscreenElement = fsEl;
  syncUi();
  flush();
  bindRoot(fsEl);
  if (!root) throw new Error('再进全屏没重挂');
  if (T() !== 'translateX(0px)') throw new Error('重挂没恢复开态: ' + T());
  const frame3 = root.children[1];
  if (!frame3 || frame3.tag !== 'iframe') throw new Error('重挂没重建 iframe');
  if (innerVideo.style.width !== '464px') throw new Error('重挂没重新让位: ' + innerVideo.style.width);

  // 14. 轻点关：还原到 640（本轮起基值）→ 停用整体卸除干净
  tap(780, 200);
  if (innerVideo.style.width !== '640px' || innerVideo.style.height !== '360px') {
    throw new Error('关时没还原到本轮基准: ' + innerVideo.style.width + '/' + innerVideo.style.height);
  }
  if (innerVideo.style.position || innerVideo.style.left || innerVideo.style.top) throw new Error('钉位残留');
  if (fsEl.style.width !== '100vw') throw new Error('站点内联被误伤: ' + fsEl.style.width);
  if (ctrl.style.width || ctrl.className !== 'player-controls') throw new Error('控件条改写没还原干净: ' + ctrl.style.width + '/' + ctrl.className);
  // 15. 原生 <video> 全屏（fs 元素就是媒体本身，Android 站常见）：抽屉必须在，
  // host 回落 body，压 video 本体是那里唯一有效的让位——别再把这条路门掉
  document.fullscreenElement = innerVideo;
  fsFire();
  flush();
  if (root.parentNode !== body) throw new Error('媒体全屏应挂 body 而不是消失');
  if (!root.classList.contains('is-fs')) throw new Error('媒体全屏没打 is-fs');
  tap(780, 200); // 开：压视频本体 inline（800-336=464）
  if (T() !== 'translateX(0px)') throw new Error('媒体全屏开态几何错: ' + T());
  if (innerVideo.style.width !== '464px' || innerVideo.style.__prio.width !== 'important') {
    throw new Error('媒体全屏没让位: ' + innerVideo.style.width);
  }
  if (innerVideo.style.position) throw new Error('媒体全屏没有子层可钉，不该出钉位');
  tap(780, 200); // 关：还原播放器现值 640
  if (innerVideo.style.width !== '640px') throw new Error('媒体全屏关后没还原: ' + innerVideo.style.width);
  document.fullscreenElement = null;
  // 16. 设置关 → 整体卸除干净
  captured.storageOnChanged({ mobileSubtitleDrawer: { newValue: false } }, 'local');
  if (body.children.length !== 0 || fsEl.children.length !== 0) throw new Error('停用后没卸干净');

  // 17. 拖到一半被卸除（门翻转/停用）：drag 是模块级状态，不清就永久停在「拖拽中」，
  //     而 onResize 头一句就是 `if (drag) return` —— 旋屏重排从此全部短路，重挂载也救不回。
  captured.storageOnChanged({ mobileSubtitleDrawer: { newValue: true } }, 'local');
  win.innerWidth = 400; win.innerHeight = 800;
  document.fullscreenElement = null;
  syncUi();
  bindRoot(body);
  if (!root) throw new Error('17: 重新启用后没挂载');
  down(200, 700); move(200, 640);            // 拖拽进行中（故意不松手）
  win.innerWidth = 800; win.innerHeight = 400; // 转横屏非全屏 = 门翻转
  syncUi();                                   // 900ms 轮询不看拖拽状态，该卸就卸
  if (body.children.length !== 0) throw new Error('17: 门翻转没卸除');
  win.innerWidth = 400; win.innerHeight = 800;
  syncUi();
  bindRoot(body);
  if (!root) throw new Error('17: 没重挂');
  win.innerHeight = 600;                      // 新上限 min(600×0.6, 600-160)=360
  win.dispatch('resize', {});
  flush();
  if (Math.abs(parseFloat(root.style.height) - 360) > 1) {
    throw new Error('17: 卸除没清 drag，重挂后旋屏重排永久失效: ' + root.style.height);
  }

  // 18. 拿不到票就不加载面板：不带票的 side-panel 文档在对端一律停摆，
  //     留个空转的扩展页只是浪费；下次开抽屉重试即可。
  captured.ticketOk = false;
  captured.storageOnChanged({ mobileSubtitleDrawer: { newValue: false } }, 'local'); // 卸除（iframe 一并丢）
  captured.storageOnChanged({ mobileSubtitleDrawer: { newValue: true } }, 'local');
  syncUi();
  bindRoot(body);
  if (!root) throw new Error('18: 没重挂');
  if (!root.classList.contains('is-open')) tap(200, 790);
  if (root.children.length !== 1) throw new Error('18: 无票却留下了 iframe');
  captured.ticketOk = true;
  tap(200, 790); tap(200, 790); // 关再开：重试取票
  const frame4 = root.children[1];
  if (!frame4 || frame4.tag !== 'iframe') throw new Error('18: 取到票后没重建 iframe');
  if (!/\?fushiTicket=tkt-\d+$/.test(frame4.src)) throw new Error('18: 重建帧没带新票: ' + frame4.src);
  captured.storageOnChanged({ mobileSubtitleDrawer: { newValue: false } }, 'local');
  if (body.children.length !== 0) throw new Error('18: 收尾没卸干净');
});
