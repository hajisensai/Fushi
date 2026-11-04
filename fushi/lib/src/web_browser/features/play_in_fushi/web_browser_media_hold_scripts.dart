// 从 play_in_fushi_feature.dart 抽出的两段页面脚本：标签页切后台的可见性 feature
// 与「用 Fushi 播放」共用。可见性 feature 只要这两段字符串，单独放一个叶子文件，
// 免得经 play_in_fushi_feature → 视频播放页把它拖进 AppModel 的 import 环
// （test/build/import_cycle_guard_test.dart）。

/// 交给 Fushi 播放器期间按住页面的媒体：暂停在播的 `<video>` / `<audio>`，并在捕获阶段拦
/// `play` 事件，之后谁开播都立刻停。只暂停一次不够（BUG-3801，用户「感觉有两个视频在播放」）：
/// 自动交接发生在地址刚变到观看页时，站点的 `<video>` 还没建；退回选集页后预告片也会自动播。
/// 幂等；由 [kWebBrowserReleaseMediaScript] 解除。
const String kWebBrowserHoldMediaScript =
    '(function(){var n=0;if(!window.__fushiMediaHold){'
    'window.__fushiMediaHold=function(e){var v=e.target;'
    'if(v&&v.pause){try{v.pause();}catch(_){}}};'
    'document.addEventListener("play",window.__fushiMediaHold,true);}'
    'var vs=document.querySelectorAll("video,audio");'
    'for(var i=0;i<vs.length;i++){try{if(!vs[i].paused){vs[i].pause();n++;}}'
    'catch(e){}}return n;})();';

/// 解除 [kWebBrowserHoldMediaScript]（播放页关掉、浏览器标签页重新在前台时）。
const String kWebBrowserReleaseMediaScript =
    '(function(){var h=window.__fushiMediaHold;if(h){'
    'document.removeEventListener("play",h,true);'
    'window.__fushiMediaHold=null;}})();';
