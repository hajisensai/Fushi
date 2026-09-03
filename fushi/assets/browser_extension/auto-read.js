// 查词后自动朗读（浏览器扩展侧）。
//
// app 的全局偏好 `autoReadOnLookup` 早就在三个表面生效——app 内弹窗、app 外瞬态查词浮窗、
// 剪贴板面板（BUG-1210 正是为「同一个开关在一个表面生效、另一个表面完全无效」收的口）。
// 浏览器扩展是最后一个漏掉的表面：在扩展里查词只能手动点 ♪。这里补上，并且**页面弹窗与
// 侧边栏弹窗共用这一份**——两个表面各写一份正是 BUG-1210 那个病。
//
// 偏好本身不在扩展里另立开关：由 app 随查词响应下发（`data.autoReadOnLookup`），改一处即可
// 三端一致。解析走 popup.js 点 ♪ 的同一条路径（callHandler('resolveWordAudio') → background
// → /api/lookup/audio），播放走 popup.js 自己的 playWordAudio（window.__fushiPlayWordAudioUrl），
// 因此音量、interrupt 语义与失败处理都与手动点 ♪ 完全一致，不新增第二套播放实现。
(function () {
  'use strict';

  // 换词即作废上一次在途解析：慢响应回来时不得盖掉用户已经在看的那个新词的发音。
  var generation = 0;

  // 关窗/换词时由调用方作废在途朗读（弹窗都没了还响一声是纯噪音）。
  window.fushiCancelAutoRead = function () {
    generation += 1;
  };

  // entries：popupJson 解析出的词条数组（第一条 = 弹窗顶部那条）。
  // options.enabled：app 下发的 autoReadOnLookup；options.audioSources：app 已启用的音频源，
  // 空数组意味着连 ♪ 按钮都不会渲染，自然也没有可播的东西。
  // 返回是否真的发起了朗读（供测试与调用方判断，不代表播放成功）。
  window.fushiAutoReadFirstEntry = function (entries, options) {
    generation += 1;
    var token = generation;
    var opts = options || {};
    if (opts.enabled !== true) return false;
    if (!Array.isArray(entries) || !entries.length) return false;
    if (!Array.isArray(opts.audioSources) || !opts.audioSources.length) return false;
    var entry = entries[0] || {};
    var expression = String(entry.expression || '').trim();
    if (!expression) return false;
    var reading = String(entry.reading || '').trim() || expression;
    var bridge = window.flutter_inappwebview;
    if (!bridge || typeof bridge.callHandler !== 'function') return false;
    try {
      Promise.resolve(bridge.callHandler('resolveWordAudio', {
        expression: expression, reading: reading,
      })).then(function (url) {
        if (token !== generation || !url) return;
        var play = window.__fushiPlayWordAudioUrl;
        if (typeof play === 'function') play(url);
      }).catch(function () { /* 解析失败：与手动点 ♪ 一样静默，不打断查词 */ });
    } catch (_) {
      return false;
    }
    return true;
  };
})();
