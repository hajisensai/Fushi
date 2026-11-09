/// WebUI 静态页：一个 HTML 字符串，原生 JS，无构建步骤、无第三方脚本。
///
/// 页面只吃 `/api/admin/*` JSON；所有状态都轮询（2~5 秒），不做 WebSocket——
/// 单管理员局域网面板，轮询足够且没有连接状态机要维护。
///
/// 界面语言来自配置 `language`（`en` / `zh`），在出页时定：[renderAdminWebUi] /
/// [renderAdminLogin]。源文案是中文，英文在 `web_ui_en.dart` 的 [kWebUiEnglish]
/// （键 = 中文原文）；`web_ui_i18n_test.dart` 保证页面里每条中文都有英文。
library;

import 'dart:convert';

import 'package:fushi_server/src/admin/web_ui_en.dart';
import 'package:fushi_server/src/config/server_config.dart';

const String adminLoginHtml = r'''<!doctype html>
<html lang="__FUSHI_HTML_LANG__"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>fushi_server</title>
<style>
body{font-family:system-ui,sans-serif;background:#121417;color:#e6e6e6;display:flex;align-items:center;justify-content:center;height:100vh;margin:0}
form{background:#1c1f24;padding:32px;border-radius:12px;min-width:320px;box-shadow:0 8px 32px #0008}
h1{margin:0 0 16px;font-size:20px}
input{width:100%;box-sizing:border-box;padding:10px;border-radius:8px;border:1px solid #333;background:#0e1013;color:#eee;font-size:14px}
button{margin-top:14px;width:100%;padding:10px;border:0;border-radius:8px;background:#4c8dff;color:#fff;font-size:14px;cursor:pointer}
.err{color:#ff7b7b;font-size:13px}
.hint{color:#888;font-size:12px;margin-top:10px}
</style></head><body>
<form method="post" action="/login">
<h1>fushi_server</h1>
<!--error-->
<input type="password" name="token" placeholder="admin_token" autofocus autocomplete="current-password">
<button type="submit">__T_登录__</button>
<p class="hint">__T_token 在 fushi_server.yaml 的 admin_token；忘了用 <code>fushi_server admin reset-token</code> 重生成。__</p>
</form></body></html>''';

const String adminWebUiHtml = r'''<!doctype html>
<html lang="__FUSHI_HTML_LANG__"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>fushi_server</title>
<style>
:root{--bg:#121417;--card:#1c1f24;--line:#2a2e35;--fg:#e6e6e6;--muted:#8a919c;--accent:#4c8dff;--ok:#4cd07d;--warn:#ffb648;--err:#ff7b7b}
*{box-sizing:border-box}
body{margin:0;font-family:system-ui,-apple-system,"Segoe UI",sans-serif;background:var(--bg);color:var(--fg);font-size:14px}
header{display:flex;align-items:center;gap:16px;padding:12px 20px;border-bottom:1px solid var(--line);position:sticky;top:0;background:var(--bg);z-index:2}
header h1{font-size:16px;margin:0}
header .sp{flex:1}
nav{display:flex;gap:4px;flex-wrap:wrap}
nav button{background:none;border:1px solid transparent;color:var(--muted);padding:6px 10px;border-radius:8px;cursor:pointer}
nav button.on{color:var(--fg);border-color:var(--line);background:var(--card)}
main{max-width:1100px;margin:0 auto;padding:20px}
section{display:none}section.on{display:block}
.card{background:var(--card);border:1px solid var(--line);border-radius:12px;padding:16px;margin-bottom:16px}
.card h2{margin:0 0 12px;font-size:15px}
.grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(220px,1fr));gap:12px}
.kv{display:flex;flex-direction:column;gap:2px}.kv b{font-size:12px;color:var(--muted);font-weight:500}.kv span{word-break:break-all}
table{width:100%;border-collapse:collapse}th,td{text-align:left;padding:8px 6px;border-bottom:1px solid var(--line);vertical-align:top}th{color:var(--muted);font-weight:500;font-size:12px}
input,select,textarea{padding:8px;border-radius:8px;border:1px solid #333;background:#0e1013;color:#eee;font-size:13px}
textarea{width:100%;font-family:ui-monospace,monospace;resize:vertical}
input[type=text],input[type=number],input[type=password]{min-width:180px}
button.b{padding:7px 12px;border:0;border-radius:8px;background:var(--accent);color:#fff;cursor:pointer;font-size:13px}
button.b.sec{background:#2d3138}button.b.danger{background:#7a2e2e}button.b:disabled{opacity:.5;cursor:default}
.row{display:flex;gap:8px;flex-wrap:wrap;align-items:center;margin:6px 0}
.pin{font-size:40px;letter-spacing:8px;font-weight:700;color:var(--warn);font-family:ui-monospace,monospace}
.tag{display:inline-block;padding:2px 8px;border-radius:999px;font-size:12px;background:#2d3138}
.tag.ok{background:#1d4d31;color:var(--ok)}.tag.err{background:#4d1d1d;color:var(--err)}.tag.warn{background:#4d3a1d;color:var(--warn)}
pre{background:#0e1013;padding:12px;border-radius:8px;overflow:auto;max-height:60vh;font-size:12px;line-height:1.5;white-space:pre-wrap}
.bar{height:6px;background:#2d3138;border-radius:3px;overflow:hidden}.bar i{display:block;height:100%;background:var(--accent)}
.muted{color:var(--muted)}.small{font-size:12px}
#toast{position:fixed;bottom:20px;left:50%;transform:translateX(-50%);background:#2d3138;padding:10px 16px;border-radius:8px;display:none;z-index:9}
label.f{display:flex;flex-direction:column;gap:4px;font-size:12px;color:var(--muted)}
</style></head><body>
<header><h1>fushi_server</h1><span id="devname" class="muted"></span><span class="sp"></span>
<nav>
<button data-s="status" class="on">状态</button><button data-s="pairing">配对</button><button data-s="libraries">库</button>
<button data-s="upload">上传</button><button data-s="jobs">任务</button><button data-s="downloads">下载</button>
<button data-s="subscriptions">订阅</button><button data-s="ai">AI 助手</button><button data-s="anki">Anki</button><button data-s="srs">复习</button><button data-s="models">模型</button><button data-s="settings">设置</button><button data-s="logs">日志</button>
</nav>
<form method="post" action="/logout" style="margin:0"><button class="b sec" type="submit">退出</button></form>
</header>
<main>

<section id="s-status" class="on">
<div class="card"><h2>运行状态</h2><div class="grid" id="status-grid"></div></div>
<div class="card"><h2>扫描</h2>
<div class="row"><button class="b" id="btn-scan">立即扫描库</button><span id="scan-state" class="muted"></span></div>
</div>
</section>

<section id="s-pairing">
<div class="card"><h2>配对请求</h2><div id="pairing-pending"><p class="muted">没有待处理的配对。在 Fushi 里添加互联设备并输入本机地址，PIN 会显示在这里。</p></div></div>
<div class="card"><h2>已配对设备</h2><table><thead><tr><th>设备</th><th>peer id</th><th>最近地址</th><th>配对时间</th><th>我的设备</th><th></th></tr></thead><tbody id="peers"></tbody></table>
<p class="small muted"><span id="lb-link-state"></span> 标为「我的设备」的已配对设备在本机没有 Fushi 账户时，会跟随本机（当前 Profile）的排行榜账户自动登录：设备只交来它自己的公钥，由本机账户代绑；私钥 / 恢复码不外传。配对不会自动标记；只有配对时证明过设备钥匙的设备能标（旧版客户端需升级后重新配对）。仅 TLS 下可用，总开关在「设置」。</p></div>
<div class="card"><h2>配置文件寄存</h2>
<div class="row"><span id="prof-state" class="small"></span><span class="sp"></span><button class="b sec" id="btn-prof-toggle"></button></div>
<p class="small muted">已配对设备在「互联 → 上传配置 / 下载配置」里把配置方案（Profile）推到本机寄存，另一台设备再拉走。本机只寄存、不应用；设备拉取时交出标「分发中」的那一份（缺省为最近收到的）。凭据已由发送端剔除。仅 TLS 下可用。</p>
<table><thead><tr><th>名称</th><th>设置项</th><th>收到时间</th><th>状态</th><th></th></tr></thead><tbody id="profiles"></tbody></table></div>
</section>

<section id="s-libraries">
<div class="card"><h2>扫描根</h2>
<table><thead><tr><th>id</th><th>路径</th><th>类型</th><th>状态</th><th></th></tr></thead><tbody id="libs"></tbody></table>
<div class="row" style="margin-top:12px">
<input type="text" id="lib-path" placeholder="/srv/media/anime" style="flex:1">
<select id="lib-kind"><option value="video">video</option><option value="book">book (epub)</option><option value="manga">manga (mokuro / cbz / cbr / cb7 / zip / rar / 页图目录)</option><option value="audiobook">audiobook (音频目录，可带 epub / 字幕)</option></select>
<input type="text" id="lib-id" placeholder="id（可空）" style="min-width:120px">
<button class="b" id="btn-lib-add">添加</button></div>
<p class="small muted">加完记得在「状态」页点扫描；服务端进程要能读到该目录。</p>
</div>
</section>

<section id="s-upload">
<div class="card"><h2>上传到库</h2>
<div class="row"><select id="up-lib"></select><input type="text" id="up-sub" placeholder="子目录（可空，如 Season1）"><input type="file" id="up-files" multiple></div>
<div class="row"><button class="b" id="btn-up">开始上传</button><span class="muted small">分块 8 MB，可断点续传（同名文件继续）；上传完成后需扫描库。</span></div>
<div id="up-list"></div>
<p class="small muted" id="up-quota"></p>
</div>
</section>

<section id="s-jobs">
<div class="card"><h2>互联任务（ASR 等）</h2>
<table><thead><tr><th>id</th><th>类型</th><th>状态</th><th>进度</th><th>创建</th><th>错误</th><th></th></tr></thead><tbody id="jobs"></tbody></table></div>
</section>

<section id="s-downloads">
<div class="card"><h2>添加磁力下载</h2>
<div class="row"><input type="text" id="dl-magnet" placeholder="magnet:?xt=urn:btih:…" style="flex:1"><input type="text" id="dl-title" placeholder="标题"><select id="dl-kind"><option value="movie">movie</option><option value="tv">tv</option></select><button class="b" id="btn-dl-add">添加</button></div>
<p class="small muted" id="dl-cap"></p></div>
<div class="card"><h2>下载任务</h2>
<table><thead><tr><th>标题</th><th>状态</th><th>进度</th><th>错误</th><th></th></tr></thead><tbody id="dls"></tbody></table></div>
</section>

<section id="s-subscriptions">
<div class="card"><h2>新建订阅（按搜索词追新）</h2>
<div class="row"><input type="text" id="sub-title" placeholder="标题（显示用）"><input type="text" id="sub-query" placeholder="搜索词，如 Frieren 1080p" style="flex:1"></div>
<div class="row"><select id="sub-provider"></select><select id="sub-kind"><option value="tv">tv（持续追新）</option><option value="movie">movie（一次）</option></select><input type="number" id="sub-after" placeholder="从第几集之后开始（可空）" style="min-width:220px"><button class="b" id="btn-sub-add">创建</button></div>
<p class="small muted" id="sub-cap">从 Fushi 客户端的发现页订阅会带完整作品身份（原名/别名/交叉 ID）；这里只按搜索词匹配。</p></div>
<div class="card"><h2>订阅</h2><div class="row"><button class="b sec" id="btn-sub-check-all">全部立即检查</button></div>
<table><thead><tr><th>标题</th><th>搜索词</th><th>源</th><th>状态</th><th>集数</th><th>最近</th><th></th></tr></thead><tbody id="subs"></tbody></table></div>
<div class="card"><h2>资源索引器</h2>
<p class="small muted">订阅与代下载在这些来源里搜资源。与 Fushi app 的资源来源设置是同一份配置；改动对正在运行的服务立即生效（正在下载的种子不受影响）。</p>
<p class="small muted" id="ri-none" style="display:none">还没有 BT 来源。添加一个 BT 站地址，或接入 Torznab 索引器</p>
<h2 style="margin-top:16px">BT 站</h2>
<div id="ri-bt"></div>
<div style="border:1px solid var(--line);border-radius:8px;padding:10px;margin:8px 0">
<div class="row"><input type="text" id="bt-url" placeholder="https://example.com" style="flex:1"><input type="text" id="bt-name" placeholder="名称（可选）"></div>
<div class="row" id="bt-domains"></div>
<div class="row"><label><input type="checkbox" id="bt-enabled" checked> 启用</label><label><input type="checkbox" id="bt-insecure"> 允许明文 HTTP（仅受信任局域网）</label><button class="b" id="btn-bt-add">添加</button></div>
<p class="small muted">只填地址即可，添加时会自动检测站点。</p></div>
<h2 style="margin-top:16px">Torznab（Jackett / Prowlarr）</h2>
<div id="ri-torznab"></div>
<div class="row"><button class="b sec" id="btn-ri-add">添加 indexer</button><button class="b" id="btn-ri-save">保存</button><button class="b sec" id="btn-ri-reset">放弃修改</button></div>
<p class="small muted" id="ri-state"></p></div>
</section>

<section id="s-models">
<div class="card"><h2>ASR 模型</h2>
<table><thead><tr><th>语言</th><th>就绪</th><th>变体 / provider</th><th>字节</th><th></th></tr></thead><tbody id="asr-models"></tbody></table></div>
<div class="card"><h2>漫画 OCR 模型</h2><div id="ocr-model"></div></div>
</section>

<section id="s-anki">
<div class="card"><h2>Anki 落地</h2>
<p class="small muted">打开后，其它设备（没装 Anki 的手机等）经互联同步过来的待发卡片由本机写进 Anki，再同步到 AnkiWeb 或你的自建 Anki 同步服务器。本机需要随包的 fushi-anki-sync。</p>
<div class="grid" id="anki-status"></div>
<div class="row" style="margin-top:12px"><label><input type="checkbox" id="anki-landing"> 接收其他设备的卡片</label>
<button class="b sec" id="btn-anki-run">立即落地</button><button class="b sec" id="btn-anki-retry">重试失败的卡</button></div>
</div>
<div class="card"><h2>Anki 同步账号</h2><div id="anki-account"></div></div>
<div class="card"><h2>牌组 / 笔记类型 / 字段</h2><div id="anki-config"></div></div>
</section>

<section id="s-srs">
<div class="card"><h2>Fushi 复习</h2>
<p class="small muted">本机替已配对设备保管 Fushi 复习的收藏：手机可以远程复习、制卡落到这里，Yomitan 可经下面的 AnkiConnect 往这里加卡。勾选要提供的配置文件（每门语言一份）；不勾选任何一份 = 关闭。同步位置开了端到端加密的配置文件暂不支持。</p>
<div class="grid" id="srs-status"></div>
<div id="srs-profiles" style="margin-top:12px"></div>
</div>
<div class="card"><h2>制卡落点</h2><div id="srs-mining"></div></div>
<div class="card"><h2>AnkiConnect 兼容接口</h2>
<p class="small muted">默认关闭。只监听本机时可以不设 key；监听局域网地址必须设 key。每份配置文件可以有自己的 key（Yomitan 里一门语言一个 key），共用 key 落到默认那份。</p>
<div id="srs-ankiconnect"></div></div>
</section>

<section id="s-settings">
<div class="card"><h2>设置</h2>
<div class="grid" id="settings-form"></div>
<div class="row" style="margin-top:12px"><button class="b" id="btn-settings-save">保存</button><span class="small muted">端口 / TLS / 绑定 / qBittorrent / torrent / ffmpeg / onnxruntime 路径改后需重启 serve。</span></div>
</div>
<div class="card"><h2>远程访问</h2>
<label class="f">公网地址（每行一个，http:// 或 https://；反代 / DDNS / 端口映射后的地址，已配对设备会自动学到）<textarea id="rr-public" rows="3" placeholder="https://nas.example.com:38765"></textarea></label>
<div class="row" style="margin:12px 0"><label><input type="checkbox" id="rr-p2p"> 允许 P2P 隧道连接</label><span class="small muted">没有公网 IP 时用（iroh）；开启后会连接中继与发现服务，对端 / 中继能看到本机 IP。</span></div>
<label class="f">自建中继（每行一个，空 = iroh 公共中继）<textarea id="rr-relays" rows="2" placeholder="https://relay.example.com"></textarea></label>
<p class="small" id="rr-state"></p>
<div class="row"><button class="b" id="btn-rr-save">保存</button><span class="small muted">这三项保存即生效，无需重启。</span></div>
</div>
</section>

<section id="s-ai">
<div class="card"><h2>AI 助手会话</h2>
<p class="small muted">已配对设备经互联让本服务端跑的 AI 助手会话（保留 30 天）。这里只读；撤销与续接在发起的那台设备上做。</p>
<table><thead><tr><th>标题</th><th>发起设备</th><th>更新</th><th>tokens</th></tr></thead><tbody id="ai-sessions"></tbody></table></div>
<div class="card" id="ai-detail" style="display:none"><h2 id="ai-detail-title"></h2><p class="small muted" id="ai-detail-meta"></p><div id="ai-entries"></div></div>
</section>

<section id="s-logs">
<div class="card"><h2>最近日志</h2><div class="row"><button class="b sec" id="btn-log-refresh">刷新</button><label><input type="checkbox" id="log-auto" checked> 自动刷新</label></div><pre id="logs"></pre></div>
</section>

</main>
<div id="toast"></div>
<script>
'use strict';
// ── 界面语言 ── LANG / EN 由服务端在出页时填（配置 `language`，见 renderAdminWebUi）。
// 源文案是中文；T(s, ...a) 在英文界面查 EN 表，{0}/{1}… 换成参数。静态标记在下面 translateStatic 里一次性翻。
const LANG = '__FUSHI_LANG__';
const EN = __FUSHI_EN__;
function T(s, ...a){ const r = (LANG==='en' && EN[s]) || s; return a.length ? r.replace(/\{(\d+)\}/g, (_, i) => String(a[Number(i)] ?? '')) : r; }
function translateStatic(root){
  if (LANG !== 'en') return;
  const w = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
  for (let n = w.nextNode(); n; n = w.nextNode()){ const k = n.data.trim(); if (k && EN[k]) n.data = n.data.replace(k, EN[k]); }
  root.querySelectorAll('[placeholder],[title]').forEach(el=>{ for (const a of ['placeholder','title']){ const v = el.getAttribute(a); if (v && EN[v]) el.setAttribute(a, EN[v]); } });
}
translateStatic(document.body);
const $ = (s) => document.querySelector(s);
const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const fmtBytes = (n) => { n = Number(n||0); const u=['B','KB','MB','GB','TB']; let i=0; while(n>=1024&&i<u.length-1){n/=1024;i++;} return n.toFixed(i?1:0)+' '+u[i]; };
const fmtTime = (v) => { if(!v) return ''; const d = typeof v==='number'? new Date(v): new Date(v); return isNaN(d)? String(v): d.toLocaleString(LANG==='en'?'en':'zh-CN'); };
let toastTimer; function toast(msg){ const t=$('#toast'); t.textContent=msg; t.style.display='block'; clearTimeout(toastTimer); toastTimer=setTimeout(()=>t.style.display='none',2600); }
const REASON_TEXT = {disabled:T('订阅已停用，请先启用'), unrecognized:T('无法识别这个站点'), timedOut:T('站点响应超时'), invalidUrl:T('地址无效'), insecureHttp:T('这是明文 HTTP 地址：请改用 HTTPS，或勾选「允许明文 HTTP」')};
async function api(path, opts){
  const r = await fetch('/api/admin/'+path, Object.assign({headers:{'Content-Type':'application/json'}}, opts||{}));
  if (r.status===401){ location.reload(); throw new Error('unauthorized'); }
  const j = await r.json().catch(()=>({}));
  if (!r.ok) throw new Error(REASON_TEXT[j.reason] || j.error || ('HTTP '+r.status));
  return j;
}
const post = (p,b)=>api(p,{method:'POST',body:JSON.stringify(b||{})});
const del = (p)=>api(p,{method:'DELETE'});
const put = (p,b)=>api(p,{method:'PUT',body:JSON.stringify(b||{})});
function guard(fn){ return async (...a)=>{ try{ await fn(...a);}catch(e){ toast(T('失败: {0}', e.message));} }; }
const tag = (cls, text) => `<span class="tag${cls?' '+cls:''}">${esc(text)}</span>`;
const empty = (cols, text) => `<tr><td colspan="${cols}" class="muted">${esc(text)}</td></tr>`;

// ── 导航 ──
let current='status';
document.querySelectorAll('nav button').forEach(b=>b.onclick=()=>{ current=b.dataset.s; document.querySelectorAll('nav button').forEach(x=>x.classList.toggle('on',x===b)); document.querySelectorAll('main section').forEach(s=>s.classList.toggle('on',s.id==='s-'+current)); refresh(); });

// ── 状态 ──
function scrapeSummary(sc){
  if(!sc) return '—';
  const tail = sc.tmdbAvailable ? '' : T(' · 未配置 TMDB key');
  if(sc.busy) return T('进行中 {0}/{1}', sc.current, sc.total) + (sc.work ? ' ' + sc.work : '') + tail;
  const r = sc.lastReport;
  const last = r ? T(' · 上次 {0}/{1} 部成功', r.succeeded, r.totalWorks) + (r.pendingConfirmations ? T('，{0} 部待指定', r.pendingConfirmations) : '') : '';
  return (sc.enabled ? T('空闲') : T('自动补刮已关闭')) + last + tail;
}
async function loadStatus(){
  const s = await api('status');
  $('#devname').textContent = s.deviceName + ' · ' + s.listen;
  const kv = [
    [T('监听'), s.listen + (s.tls?' (https)':' (http)')], [T('设备 id'), s.deviceId], [T('TLS 指纹'), s.fingerprint||'—'],
    [T('运行时长'), Math.floor(s.uptimeSeconds/3600)+'h '+Math.floor(s.uptimeSeconds%3600/60)+'m'], [T('数据目录'), s.dataDir],
    [T('视频'), s.videos], [T('书'), s.books], [T('已配对'), s.peers], [T('库根'), s.libraries],
    [T('OCR 模型'), s.ocr ? (s.ocr.ready?T('就绪'):T('缺失')) : '—'],
    [T('下载后端'), s.downloads ? (s.downloads.supported ? (s.downloads.backend||'ok') : T('未配置')) : '—'],
    [T('订阅'), s.subscriptionCount==null ? '—' : s.subscriptionCount],
    [T('上传配额'), fmtBytes(s.uploadUsedBytes)+' / '+fmtBytes(s.uploadQuotaBytes)],
    [T('P2P 隧道'), p2pSummary(s.p2p)],
    [T('刮削'), scrapeSummary(s.scrape)],
  ];
  $('#status-grid').innerHTML = kv.map(([k,v])=>`<div class="kv"><b>${esc(k)}</b><span>${esc(v)}</span></div>`).join('');
  const notes = (s.lastScanNotes && s.lastScanNotes.length) ? ' — ' + s.lastScanNotes.join('; ') : '';
  $('#scan-state').textContent = s.scanning ? T('扫描中…') : (s.lastScan ? T('上次 {0}: {1}', fmtTime(s.lastScanAt), s.lastScan + notes) : T('尚未扫描'));
  $('#btn-scan').disabled = !!s.scanning;
}
$('#btn-scan').onclick = guard(async()=>{ await post('scan'); toast(T('已开始扫描')); loadStatus(); });

// ── 配对 ──
async function loadPairing(){
  const p = await api('pairing');
  $('#pairing-pending').innerHTML = p.pending
    ? `<p>${esc(T('{0} ({1}) 请求配对，请在该设备输入：', p.pending.deviceName||T('未知设备'), p.pending.remoteAddress||'?'))}</p><div class="pin">${esc(p.pending.pin)}</div><p class="small muted">${fmtTime(p.pending.createdAt)}</p>`
    : `<p class="muted">${esc(T('没有待处理的配对。在 Fushi 里添加互联设备并输入本机地址，PIN 会显示在这里。'))}</p>`;
  $('#peers').innerHTML = p.peers.map(x=>`<tr><td>${esc(x.deviceName||'—')}</td><td class="small muted">${esc(x.peerId)}</td><td>${esc(x.lastSeenIp||'')}</td><td>${fmtTime(x.pairedAtMs)}</td><td>${x.deviceKeyVerified ? `<button class="b ${x.ownerDevice?'':'sec'}" data-owner="${esc(x.peerId)}" data-on="${x.ownerDevice?'1':'0'}">${esc(x.ownerDevice?T('是（取消）'):T('标为我的设备'))}</button>` : `<span class="small muted">${esc(T('未证明设备钥匙'))}</span>`}</td><td><button class="b danger" data-revoke="${esc(x.peerId)}">${esc(T('吊销'))}</button></td></tr>`).join('') || empty(6, T('无'));
  const lb = p.leaderboardLink || {};
  $('#lb-link-state').innerHTML = lb.enabled ? (lb.tls ? tag('ok', T('自动登录已开')) : tag('', T('自动登录已开，但 TLS 关着——端点在明文下拒绝访问'))) : tag('', T('自动登录已关'));
  $('#peers').querySelectorAll('[data-revoke]').forEach(b=>b.onclick=guard(async()=>{ if(!confirm(T('吊销该设备？'))) return; await del('pairing/peers/'+encodeURIComponent(b.dataset.revoke)); loadPairing(); }));
  $('#peers').querySelectorAll('[data-owner]').forEach(b=>b.onclick=guard(async()=>{ const on = b.dataset.on!=='1'; if(on && !confirm(T('标为「我的设备」？它将能跟随本机的 Fushi 排行榜账户自动登录（代绑出去的设备钥匙在账户里是满权限）。只标你自己的设备。'))) return; await put('pairing/peers/'+encodeURIComponent(b.dataset.owner)+'/owner',{owner:on}); toast(on?T('已标为我的设备'):T('已取消')); loadPairing(); }));
  await loadProfiles();
}
async function loadProfiles(){
  const r = await api('profiles');
  $('#prof-state').innerHTML = r.enabled ? (r.tls ? tag('ok', T('已允许')) : tag('', T('已允许，但 TLS 关着——端点在明文下拒绝访问'))) : tag('', T('未允许（默认）'));
  $('#btn-prof-toggle').textContent = r.enabled ? T('禁止设备推送 / 拉取') : T('允许设备推送 / 拉取');
  $('#btn-prof-toggle').dataset.enabled = r.enabled ? '1' : '0';
  $('#profiles').innerHTML = (r.profiles||[]).map(x=>`<tr><td>${esc(x.name)}</td><td>${x.settingCount}</td><td>${fmtTime(x.receivedAt)}</td><td>${x.shared?tag('ok', T('分发中')):''}</td><td class="row">${x.shared?'':`<button class="b sec" data-prof="share" data-id="${x.id}">${esc(T('设为分发'))}</button>`}<button class="b danger" data-prof="delete" data-id="${x.id}">${esc(T('删除'))}</button></td></tr>`).join('') || empty(5, T('还没有设备推送过配置'));
  $('#profiles').querySelectorAll('[data-prof]').forEach(b=>b.onclick=guard(async()=>{ const id=b.dataset.id;
    if(b.dataset.prof==='delete'){ if(!confirm(T('删除这份寄存的配置？'))) return; await del('profiles/'+id); }
    else { await post('profiles/'+id+'/share'); }
    loadProfiles(); }));
}
$('#btn-prof-toggle').onclick = guard(async()=>{ const on = $('#btn-prof-toggle').dataset.enabled!=='1'; if(on && !confirm(T('允许已配对设备把配置推到本机寄存、并从本机拉走？'))) return; await put('settings',{profileTransfer:on}); settingsCache=null; toast(on?T('已允许'):T('已禁止')); loadProfiles(); });

// ── 库 ──
async function loadLibraries(){
  const r = await api('libraries');
  $('#libs').innerHTML = r.libraries.map(l=>`<tr><td>${esc(l.id)}</td><td>${esc(l.path)}</td><td>${esc(l.kind)}</td><td>${l.exists?tag('ok', T('存在')):tag('err', T('目录不存在'))}${l.enabled?'':' '+tag('', T('禁用'))}</td><td><button class="b danger" data-rm="${esc(l.id)}">${esc(T('移除'))}</button> <button class="b danger" data-purge="${esc(l.id)}">${esc(T('移除并清理'))}</button></td></tr>`).join('') || empty(5, T('还没有扫描根'));
  $('#libs').querySelectorAll('[data-rm]').forEach(b=>b.onclick=guard(async()=>{ if(!confirm(T('从配置移除该库根？（不删文件、不删已入库条目）'))) return; await del('libraries/'+encodeURIComponent(b.dataset.rm)); loadLibraries(); }));
  $('#libs').querySelectorAll('[data-purge]').forEach(b=>b.onclick=guard(async()=>{ if(!confirm(T('移除该库根，并清理「文件已消失」的条目？\n只回收条目与其刮削资料 / 正文副本，不删任何源文件。\n注意：目录若只是没挂载，其下条目也会被当成已删除。'))) return; const r=await del('libraries/'+encodeURIComponent(b.dataset.purge)+'?purge=true'); const p=r&&r.purge; toast(p?(p.skipped?T('未清理：{0}', p.reason||T('被护栏拦下')):T('已清理 {0} 条', p.deleted)):T('已移除')); loadLibraries(); loadStatus(); }));
  $('#up-lib').innerHTML = r.libraries.map(l=>`<option value="${esc(l.id)}">${esc(l.id)} — ${esc(l.path)}</option>`).join('');
}
$('#btn-lib-add').onclick = guard(async()=>{ await post('libraries',{path:$('#lib-path').value, kind:$('#lib-kind').value, id:$('#lib-id').value}); $('#lib-path').value=''; $('#lib-id').value=''; toast(T('已添加')); loadLibraries(); });

// ── 上传 ──
const CHUNK = 8*1024*1024;
async function uploadOne(file, lib, sub, row){
  const rel = (sub ? sub.replace(/^\/+|\/+$/g,'')+'/' : '') + file.name;
  const q = `upload?library=${encodeURIComponent(lib)}&path=${encodeURIComponent(rel)}`;
  const st = await api(q);
  let off = st.received || 0;
  if (off >= file.size && file.size>0){ row.querySelector('.st').textContent=T('已存在'); return; }
  while (off < file.size){
    const end = Math.min(off+CHUNK, file.size);
    const r = await fetch('/api/admin/'+q, {method:'PUT', headers:{'Content-Range':`bytes ${off}-${end-1}/${file.size}`,'Content-Type':'application/octet-stream'}, body:file.slice(off,end)});
    const j = await r.json().catch(()=>({}));
    if (!r.ok) throw new Error(j.error||('HTTP '+r.status));
    off = j.received;
    row.querySelector('.bar i').style.width = (off/file.size*100).toFixed(1)+'%';
    row.querySelector('.st').textContent = fmtBytes(off)+' / '+fmtBytes(file.size);
    if (j.complete) break;
  }
  if (file.size===0){ await fetch('/api/admin/'+q,{method:'PUT',headers:{'Content-Range':'bytes 0-0/0'},body:new Blob([])}); }
  row.querySelector('.st').textContent=T('完成');
}
$('#btn-up').onclick = guard(async()=>{
  const files = Array.from($('#up-files').files); const lib=$('#up-lib').value; const sub=$('#up-sub').value.trim();
  if(!lib) throw new Error(T('先添加一个库根')); if(!files.length) throw new Error(T('没选文件'));
  $('#btn-up').disabled=true;
  try{ for(const f of files){ const row=document.createElement('div'); row.innerHTML=`<div class="row"><span style="flex:1">${esc(f.name)}</span><span class="st muted small">${esc(T('等待'))}</span></div><div class="bar"><i style="width:0"></i></div>`; $('#up-list').prepend(row); try{ await uploadOne(f,lib,sub,row);}catch(e){ row.querySelector('.st').textContent=T('失败: {0}', e.message); } } toast(T('上传结束，记得扫描库')); }
  finally{ $('#btn-up').disabled=false; loadStatus(); }
});

// ── 任务 ──
const stTag = (s) => `<span class="tag ${(s==='done'||s==='completed')?'ok':((s==='error'||s==='failed')?'err':((s==='running'||s==='uploading'||s==='active')?'warn':''))}">${esc(s)}</span>`;
async function loadJobs(){
  const r = await api('jobs');
  $('#jobs').innerHTML = r.jobs.map(j=>`<tr><td class="small muted">${esc(j.id)}</td><td>${esc(j.kind)}</td><td>${stTag(j.state)}</td><td>${j.progress!=null?(j.progress*100).toFixed(0)+'%':''} <span class="small muted">${esc(j.message||'')}</span></td><td class="small">${fmtTime(j.createdAt)}</td><td class="small" style="color:var(--err)">${esc(j.error||'')}</td><td><button class="b danger" data-jdel="${esc(j.id)}">${esc(T('删除'))}</button></td></tr>`).join('') || empty(7, T('无'));
  $('#jobs').querySelectorAll('[data-jdel]').forEach(b=>b.onclick=guard(async()=>{ await del('jobs/'+encodeURIComponent(b.dataset.jdel)); loadJobs(); }));
}

// ── 下载 ──
async function loadDownloads(){
  const r = await api('downloads');
  $('#dl-cap').textContent = r.supported ? T('后端: {0}', r.backend||'ok') : T('下载后端未配置：在「设置」填 qBittorrent WebUI 地址并重启。');
  $('#btn-dl-add').disabled = !r.supported;
  $('#dls').innerHTML = r.jobs.map(j=>`<tr><td>${esc(j.title)}<div class="small muted">${esc(j.jobId)} · ${esc(j.mediaKind||'')}</div></td><td>${stTag(j.lifecycle)}</td><td>${j.stageProgress!=null?(Number(j.stageProgress)*100).toFixed(0)+'%':''} <span class="small muted">${esc(j.stage||'')}</span></td><td class="small" style="color:var(--err)">${esc(j.lastError||'')}</td><td class="row"><button class="b sec" data-dl="cancel" data-id="${esc(j.jobId)}">${esc(T('取消'))}</button><button class="b sec" data-dl="retry" data-id="${esc(j.jobId)}">${esc(T('重试'))}</button><button class="b danger" data-dl="delete" data-id="${esc(j.jobId)}">${esc(T('清理'))}</button></td></tr>`).join('') || empty(5, T('无'));
  $('#dls').querySelectorAll('[data-dl]').forEach(b=>b.onclick=guard(async()=>{ const id=encodeURIComponent(b.dataset.id); if(b.dataset.dl==='delete') await del('downloads/'+id); else await post('downloads/'+id+'/'+b.dataset.dl); loadDownloads(); }));
}
$('#btn-dl-add').onclick = guard(async()=>{ await post('downloads',{magnet:$('#dl-magnet').value, title:$('#dl-title').value, mediaKind:$('#dl-kind').value}); $('#dl-magnet').value=''; $('#dl-title').value=''; toast(T('已添加')); loadDownloads(); });

// ── 订阅 ──
async function loadSubscriptions(){
  const r = await api('subscriptions');
  const opts = r.providerOptions||[];
  $('#sub-cap').textContent = r.supported ? T('后端: {0}；可用来源: {1}', r.backend, opts.map(o=>o.label).join(', ')||T('无')) : T('下载后端未配置，订阅不可用。');
  $('#btn-sub-add').disabled = !r.supported; $('#btn-sub-check-all').disabled = !r.supported;
  const sel = $('#sub-provider'); const cur = sel.value;
  sel.innerHTML = opts.map(o=>`<option value="${esc(o.value)}">${esc(o.label)}</option>`).join('');
  if (cur) sel.value = cur;
  const fmtCounts = (c)=> c ? Object.entries(c).map(([k,v])=>`${k} ${v}`).join(' · ') : '';
  $('#subs').innerHTML = (r.subscriptions||[]).map(s=>`<tr><td>${esc(s.title)}<div class="small muted">${esc(s.mediaKind)} · ${esc(s.mode)}</div></td><td class="small">${esc(s.searchQuery)}</td><td class="small">${s.resourceProviderLabel?esc(s.resourceProviderLabel):`<span class="muted">${esc(T('没有可用来源'))}</span>`}</td><td>${s.enabled?tag('ok', T('启用')):tag('', T('停用'))} ${s.lastError?`<div class="small" style="color:var(--err)">${esc(s.lastError)}</div>`:''}</td><td class="small">${esc(fmtCounts(s.itemCounts))}</td><td class="small">${s.lastCheckedAt?fmtTime(s.lastCheckedAt):'—'}</td><td class="row"><button class="b sec" data-sub="enable" data-id="${esc(s.subscriptionId)}" data-enabled="${s.enabled?'0':'1'}">${esc(s.enabled?T('停用'):T('启用'))}</button><button class="b sec" data-sub="check" data-id="${esc(s.subscriptionId)}"${s.enabled?'':` disabled title="${esc(T('已停用的订阅不检查，请先启用'))}"`}>${esc(T('检查'))}</button><button class="b danger" data-sub="delete" data-id="${esc(s.subscriptionId)}">${esc(T('删除'))}</button></td></tr>`).join('') || empty(7, T('无'));
  $('#subs').querySelectorAll('[data-sub]').forEach(b=>b.onclick=guard(async()=>{ const id=encodeURIComponent(b.dataset.id);
    if(b.dataset.sub==='delete'){ if(!confirm(T('删除该订阅？（已下载的任务不受影响）'))) return; await del('subscriptions/'+id); }
    else if(b.dataset.sub==='enable'){ await post('subscriptions/'+id+'/enable',{enabled:b.dataset.enabled==='1'}); }
    else { await post('subscriptions/'+id+'/check'); }
    loadSubscriptions(); }));
}
$('#btn-sub-add').onclick = guard(async()=>{ const after=$('#sub-after').value.trim(); await post('subscriptions',{title:$('#sub-title').value, searchQuery:$('#sub-query').value, mediaKind:$('#sub-kind').value, resourceProvider:$('#sub-provider').value, startAfterEpisode: after?Number(after):undefined}); $('#sub-title').value=''; $('#sub-query').value=''; toast(T('已创建')); loadSubscriptions(); });
$('#btn-sub-check-all').onclick = guard(async()=>{ await post('subscriptions/check'); toast(T('已触发检查')); loadSubscriptions(); });

// ── 资源索引器（用户 BT 站 + Torznab；Torznab 表单只在首次 / 保存 / 放弃时重画，轮询不冲掉编辑）──
let riLoaded=false;
const BT_DOMAINS = [['anime',T('动画')],['movie',T('电影')],['tv',T('剧集')],['novel',T('小说')],['audiobook',T('有声书')],['manga',T('漫画')],['game',T('游戏')]];
const btDomainBoxes = (attr, on) => BT_DOMAINS.map(([k,l])=>`<label><input type="checkbox" ${attr}="${k}" ${on.includes(k)?'checked':''}> ${esc(l)}</label>`).join('');
const btPicked = (root, attr) => Array.from(root.querySelectorAll(`[${attr}]`)).filter(e=>e.checked).map(e=>e.getAttribute(attr));
$('#bt-domains').innerHTML = btDomainBoxes('data-bt-add-domain', BT_DOMAINS.map(d=>d[0]));
function btRow(x){
  const label = Object.fromEntries(BT_DOMAINS);
  const eff = x.effectiveDomains||[];
  const off = (x.domains||[]).filter(d=>!eff.includes(d));
  const state = !x.enabled ? tag('', T('已停用')) : (x.active===true ? tag('ok', T('生效中')) : (x.active===false ? tag('warn', T('未参与资源搜索')) : ''));
  const sep = T('、');
  return `<div class="bt-row" data-id="${esc(x.id)}" style="border:1px solid var(--line);border-radius:8px;padding:10px;margin:8px 0">
    <div class="row"><b>${esc(x.displayName)}</b><span class="small muted">${esc(x.host)}</span>${state}</div>
    <div class="small muted">${esc(T('适用：{0}', eff.map(d=>label[d]||d).join(sep)||T('无')))}${off.length?esc(T('；对 {0} 不生效', off.map(d=>label[d]||d).join(sep))):''}</div>
    <div class="bt-edit" style="display:none">
      <div class="row"><input type="text" data-k="name" placeholder="${esc(T('名称（可选）'))}" value="${esc(x.name||'')}"><input type="text" data-k="url" placeholder="${esc(T('新地址（留空不改）'))}" style="flex:1"></div>
      <div class="row">${btDomainBoxes('data-bt-domain', x.domains||[])}</div>
      <div class="row"><label><input type="checkbox" data-k="enabled" ${x.enabled?'checked':''}> ${esc(T('启用'))}</label><label><input type="checkbox" data-k="allowInsecureHttp" ${x.allowInsecureHttp?'checked':''}> ${esc(T('允许明文 HTTP（仅受信任局域网）'))}</label><button class="b" data-bt="save">${esc(T('保存'))}</button></div>
    </div>
    <div class="row"><button class="b sec" data-bt="edit">${esc(T('编辑'))}</button><button class="b sec" data-bt="reprobe">${esc(T('重新检测'))}</button><button class="b danger" data-bt="delete">${esc(T('删除'))}</button></div></div>`;
}
function renderRiState(r){
  const bt = r.btSites||[]; const tz = r.torznab||[];
  $('#ri-none').style.display = (bt.length||tz.length) ? 'none' : '';
  const activeBt = bt.filter(x=>x.active===true).length;
  const activeTz = (r.providers||[]).filter(p=>p.startsWith('torznab:')).length;
  $('#ri-state').textContent = r.applied ? T('当前生效：{0} 个 BT 站、{1} 个 Torznab 索引器', activeBt, activeTz) : T('互联 host 未运行：保存后下次启动 serve 生效。');
}
function renderBtSites(r){
  $('#ri-bt').innerHTML = (r.btSites||[]).map(btRow).join('');
  $('#ri-bt').querySelectorAll('[data-bt]').forEach(b=>b.onclick=guard(async()=>{
    const row = b.closest('.bt-row'); const id = encodeURIComponent(row.dataset.id); const act = b.dataset.bt;
    if (act==='edit'){ const e=row.querySelector('.bt-edit'); e.style.display = e.style.display==='none' ? '' : 'none'; return; }
    let res;
    b.disabled = true;
    try {
      if (act==='delete'){ if(!confirm(T('删除这个 BT 站？（已建的订阅会改用其它来源，没有可用来源时暂停）'))) return; res = await del('resource-indexers/bt-sites/'+id); toast(T('已删除')); }
      else if (act==='reprobe'){ toast(T('正在检测站点…')); res = await post('resource-indexers/bt-sites/'+id+'/reprobe'); toast(T('检测完成')); }
      else {
        const v = (k)=>row.querySelector(`.bt-edit [data-k="${k}"]`);
        const domains = btPicked(row, 'data-bt-domain');
        if (!domains.length) throw new Error(T('至少选择一个媒体域'));
        const body = {name: v('name').value, domains, enabled: v('enabled').checked, allowInsecureHttp: v('allowInsecureHttp').checked};
        const url = v('url').value.trim(); if (url) { body.url = url; toast(T('正在检测站点…')); }
        res = await put('resource-indexers/bt-sites/'+id, body); toast(T('已保存'));
      }
    } finally { b.disabled = false; }
    renderBtSites(res); renderRiState(res); loadSubscriptions();
  }));
}
$('#btn-bt-add').onclick = guard(async()=>{
  const url = $('#bt-url').value.trim(); if (!url) throw new Error(T('请填写站点地址'));
  const domains = btPicked($('#bt-domains'), 'data-bt-add-domain'); if (!domains.length) throw new Error(T('至少选择一个媒体域'));
  $('#btn-bt-add').disabled = true; toast(T('正在检测站点…'));
  try {
    const r = await post('resource-indexers/bt-sites', {url, name: $('#bt-name').value, domains, enabled: $('#bt-enabled').checked, allowInsecureHttp: $('#bt-insecure').checked});
    $('#bt-url').value=''; $('#bt-name').value='';
    renderBtSites(r); renderRiState(r); toast(T('已添加')); loadSubscriptions();
  } finally { $('#btn-bt-add').disabled = false; }
});
function riRow(x){
  const keySet = x.apiKeySet ? ` <span class="muted">${esc(T('(已设置，留空不改)'))}</span>` : '';
  return `<div class="ri-row" data-id="${esc(x.id||'')}" style="border:1px solid var(--line);border-radius:8px;padding:10px;margin:8px 0"><div class="grid">
    <label class="f">${esc(T('名称'))}<input type="text" data-k="name" value="${esc(x.name||'')}"></label>
    <label class="f">${esc(T('地址（https://…/api；带 ?apikey= 会自动拆进 key 栏）'))}<input type="text" data-k="endpoint" value="${esc(x.endpoint||'')}"></label>
    <label class="f">API key${keySet}<input type="password" data-k="apiKey" value="" autocomplete="off"></label>
    <label class="f">${esc(T('优先级（小的先搜）'))}<input type="number" data-k="priority" value="${esc(x.priority??100)}"></label>
    <label class="f">${esc(T('分类（逗号分隔，可空）'))}<input type="text" data-k="categories" value="${esc((x.categories||[]).join(','))}"></label></div>
    <div class="row"><label><input type="checkbox" data-k="enabled" ${x.enabled!==false?'checked':''}> ${esc(T('启用'))}</label><label><input type="checkbox" data-k="allowInsecureHttp" ${x.allowInsecureHttp?'checked':''}> ${esc(T('允许明文 HTTP（仅受信任局域网）'))}</label>${x.apiKeySet?`<label><input type="checkbox" data-k="clearApiKey"> ${esc(T('清除已存的 key'))}</label>`:''}<button class="b danger" data-ri-rm>${esc(T('移除'))}</button></div></div>`;
}
function bindRiRemove(){ $('#ri-torznab').querySelectorAll('[data-ri-rm]').forEach(b=>b.onclick=()=>b.closest('.ri-row').remove()); }
function renderIndexers(r){
  renderBtSites(r);
  $('#ri-torznab').innerHTML = (r.torznab||[]).map(riRow).join('') || `<p class="muted small" id="ri-empty">${esc(T('还没有 Torznab indexer。'))}</p>`;
  bindRiRemove();
  renderRiState(r);
}
async function loadIndexers(force){ if(riLoaded && !force) return; const r = await api('resource-indexers'); riLoaded=true; renderIndexers(r); }
$('#btn-ri-add').onclick = ()=>{ const e=$('#ri-empty'); if(e) e.remove(); $('#ri-torznab').insertAdjacentHTML('beforeend', riRow({})); bindRiRemove(); };
$('#btn-ri-reset').onclick = guard(()=>loadIndexers(true));
$('#btn-ri-save').onclick = guard(async()=>{
  const torznab = Array.from(document.querySelectorAll('#ri-torznab .ri-row')).map((row,i)=>{
    const v = (k)=>row.querySelector(`[data-k="${k}"]`);
    const pr = v('priority').value.trim();
    if (pr!=='' && !/^-?\d+$/.test(pr)) throw new Error(T('第 {0} 个 indexer 的优先级必须是整数', i+1));
    const clear = v('clearApiKey');
    return {id: row.dataset.id || undefined, name: v('name').value, endpoint: v('endpoint').value, apiKey: v('apiKey').value, clearApiKey: clear ? clear.checked : false,
      priority: pr==='' ? undefined : Number(pr), categories: v('categories').value, enabled: v('enabled').checked, allowInsecureHttp: v('allowInsecureHttp').checked};
  });
  $('#btn-ri-save').disabled=true;
  try { const r = await put('resource-indexers', {torznab}); renderIndexers(r); toast(r.applied ? T('已保存并生效') : T('已保存')); loadSubscriptions(); }
  finally { $('#btn-ri-save').disabled=false; }
});

// ── 模型 ──
const readyTag = (m) => m.error ? tag('err', m.error) : (m.ready ? tag('ok', T('就绪')) : tag('', T('缺失')));
const pullButton = (key, pulling) => `<button class="b" data-pull="${esc(key)}" ${pulling?'disabled':''}>${esc(pulling?T('下载中…'):T('下载'))}</button>`;
async function loadModels(){
  const r = await api('models');
  $('#asr-models').innerHTML = r.asr.map(m=>`<tr><td>${esc(m.name||m.tag)} <span class="small muted">${esc(m.tag)}</span></td><td>${readyTag(m)}</td><td class="small">${esc(m.variant||'')} / ${esc(m.provider||'')}</td><td class="small">${m.totalBytes?fmtBytes(m.obtainedBytes)+' / '+fmtBytes(m.totalBytes):''}</td><td>${m.ready?'':pullButton(m.tag, m.pulling)}</td></tr>`).join('');
  $('#ocr-model').innerHTML = (r.ocrModels && r.ocrModels.length) ? `<table>${r.ocrModels.map(m=>`<tr><td>${esc(m.name||m.key)}</td><td>${readyTag(m)}</td><td class="small">${m.totalBytes?fmtBytes(m.obtainedBytes)+' / '+fmtBytes(m.totalBytes):''}</td><td>${m.ready||m.error?'':pullButton('ocr:'+m.key, m.pulling)}</td></tr>`).join('')}</table>` : r.ocr ? `<div class="row">${r.ocr.ready?tag('ok', T('就绪')):tag('', T('缺失'))} <span class="small muted">${fmtBytes(r.ocr.obtainedBytes)} / ${fmtBytes(r.ocr.totalBytes)}</span> ${r.ocr.ready?'':pullButton('ocr', r.ocr.pulling)}</div>` : `<p class="muted">${esc(T('OCR 服务不可用'))}</p>`;
  document.querySelectorAll('[data-pull]').forEach(b=>b.onclick=guard(async()=>{ await post('models/pull',{model:b.dataset.pull}); toast(T('开始下载')); loadModels(); }));
}

// ── Anki ──
const ANKI_PHASE = {signedOut:T('未登录'), idle:T('空闲'), busy:T('同步中…'), blocked:T('被拦：服务器要求整库上传（Fushi 不做）。请先在官方 Anki 里同步一次。'), failed:T('上次同步失败')};
let ankiFormKey = null;
let ankiRelogin = false;
async function loadAnki(){
  const a = await api('anki');
  const L = a.landing, S = a.sync;
  const kv = [
    ['fushi-anki-sync', a.available ? T('已随包') : T('未找到（此服务端包不带，无法落地）')],
    [T('落地'), L.enabled ? T('开') : T('关')],
    [T('待落地 / 失败'), L.pending + ' / ' + L.failed],
    [T('上次落地'), L.lastRunAt ? fmtTime(L.lastRunAt) + (L.lastReport ? T('（收 {0}，落 {1}，失败 {2}，等配置 {3}）', L.lastReport.received, L.lastReport.delivered, L.lastReport.failed, L.lastReport.waiting) : '') : '—'],
    [T('同步'), S ? (ANKI_PHASE[S.phase] || S.phase) + (S.message ? T('：') + S.message : '') : '—'],
    [T('未同步的卡'), S ? S.unsynced : '—'],
    [T('上次同步'), S && S.lastSyncAt ? fmtTime(S.lastSyncAt) : '—'],
  ];
  if (S && S.failing) kv.push([T('写入失败（会自动重试）'), T('{0} 张：{1}', S.failing, S.lastError || '')]);
  if (L.lastError) kv.push([T('落地错误'), L.lastError]);
  $('#anki-status').innerHTML = kv.map(([k,v])=>`<div class="kv"><b>${esc(k)}</b><span>${esc(v)}</span></div>`).join('');
  $('#anki-landing').checked = !!L.enabled;
  $('#anki-landing').disabled = !a.available;

  // 表单只在账号 / 可选项变了时重画，否则 2.5 秒一次的轮询会冲掉正在输入的内容。
  const key = JSON.stringify([a.available, a.account, ankiRelogin, a.settings.decks, a.settings.noteTypes, a.settings.noteType]);
  if (key === ankiFormKey) return;
  ankiFormKey = key;
  if (!a.available) { $('#anki-account').innerHTML = `<p class="muted">${esc(T('此服务端包没有 fushi-anki-sync。'))}</p>`; $('#anki-config').innerHTML=''; return; }
  const showLogin = !a.account || ankiRelogin;
  $('#anki-account').innerHTML = !showLogin
    ? `<p>${esc(T('已登录：{0}', a.account.username))} <span class="muted">(${esc(a.account.server || 'AnkiWeb')})</span></p>
       <div class="row"><button class="b" id="btn-anki-sync">${esc(T('立即同步'))}</button><button class="b sec" id="btn-anki-refresh">${esc(T('刷新牌组 / 笔记类型'))}</button><button class="b sec" id="btn-anki-relogin">${esc(T('重新登录'))}</button><button class="b danger" id="btn-anki-logout">${esc(T('退出登录'))}</button></div>`
    : `<div class="grid">
       <label class="f">${esc(T('同步服务器（自建服务器地址，如 http://nas:8080/；留空为 AnkiWeb）'))}<input id="anki-endpoint" value="${esc(a.account ? (a.account.server || '') : '')}"></label>
       <label class="f">${esc(T('用户名'))}<input id="anki-user" value="${esc(a.account ? a.account.username : '')}"></label>
       <label class="f">${esc(T('密码'))}<input type="password" id="anki-pass"></label></div>
       <div class="row" style="margin-top:12px"><button class="b" id="btn-anki-login">${esc(T('登录并下载牌组集合'))}</button>${a.account ? `<button class="b sec" id="btn-anki-relogin-cancel">${esc(T('取消'))}</button>` : ''}</div>
       <p class="small muted">${esc(T('密码只用来换取同步凭据，不保存。同一服务器与用户名重新登录只换凭据，本机的牌组集合与未同步的卡都保留。'))}</p>`;
  if (!showLogin) {
    $('#btn-anki-sync').onclick = guard(async()=>{ await post('anki/sync'); toast(T('已同步')); ankiFormKey=null; loadAnki(); });
    $('#btn-anki-refresh').onclick = guard(async()=>{ await post('anki/refresh'); toast(T('已刷新')); ankiFormKey=null; loadAnki(); });
    $('#btn-anki-relogin').onclick = ()=>{ ankiRelogin=true; ankiFormKey=null; loadAnki(); };
    $('#btn-anki-logout').onclick = guard(async()=>{
      if(!confirm(T('退出登录会删掉本机的牌组集合副本。继续？'))) return;
      try { await post('anki/logout'); }
      catch(e){
        const m = /^unsynced:(\d+)$/.exec(e.message);
        if (!m) throw e;
        if (!confirm(T('还有 {0} 张卡没有同步到 Anki。放弃这些卡并退出？（放弃后无法找回）', m[1]))) return;
        await post('anki/logout', {discardUnsynced: true});
      }
      ankiFormKey=null; loadAnki();
    });
  } else {
    const cancel = $('#btn-anki-relogin-cancel');
    if (cancel) cancel.onclick = ()=>{ ankiRelogin=false; ankiFormKey=null; loadAnki(); };
    $('#btn-anki-login').onclick = guard(async()=>{
      const endpoint = $('#anki-endpoint').value.trim();
      let acceptAnkiWeb = false;
      if (!endpoint) {
        if (!confirm(T('AnkiWeb 的服务条款只允许官方 Anki 客户端同步。Fushi 会如实表明自己是 Fushi，因此 AnkiWeb 可能拒绝连接，或对你的账号采取措施。自建同步服务器没有这项限制。\n\n仍然使用 AnkiWeb？'))) return;
        acceptAnkiWeb = true;
      }
      await post('anki/login', {endpoint, username: $('#anki-user').value, password: $('#anki-pass').value, acceptAnkiWeb});
      toast(T('已登录')); ankiRelogin=false; ankiFormKey=null; loadAnki();
    });
  }

  const st = a.settings;
  if (!a.account || !st.decks.length) { $('#anki-config').innerHTML = `<p class="muted">${esc(T('登录后显示。'))}</p>`; return; }
  const opt = (list, sel) => list.map(x=>`<option ${x===sel?'selected':''}>${esc(x)}</option>`).join('');
  const ph = `<datalist id="anki-ph">${a.placeholders.map(x=>`<option value="${esc(x)}">`).join('')}</datalist>`;
  $('#anki-config').innerHTML = `${ph}<div class="grid">
    <label class="f">${esc(T('牌组'))}<select id="anki-deck">${opt(st.decks, st.deck)}</select></label>
    <label class="f">${esc(T('笔记类型'))}<select id="anki-nt">${opt(st.noteTypes, st.noteType)}</select></label>
    <label class="f">${esc(T('标签（空格分隔）'))}<input id="anki-tags" value="${esc(st.tags)}"></label></div>
    <h2 style="margin-top:16px">${esc(T('字段映射'))}</h2><p class="small muted">${esc(T('每个字段填占位符，如 {expression}、{reading}、{glossary}、{sentence}；可组合。没填映射时卡片会留着等，不会丢。'))}</p>
    <div class="grid">${st.fields.map(f=>`<label class="f">${esc(f)}<input list="anki-ph" data-field="${esc(f)}" value="${esc(st.fieldMappings[f]||'')}"></label>`).join('')}</div>
    <div class="row" style="margin-top:12px"><button class="b" id="btn-anki-save">${esc(T('保存'))}</button></div>`;
  $('#anki-nt').onchange = guard(async()=>{ await put('anki/settings', {noteType: $('#anki-nt').value}); ankiFormKey=null; loadAnki(); });
  $('#btn-anki-save').onclick = guard(async()=>{
    const fieldMappings = {};
    document.querySelectorAll('#anki-config [data-field]').forEach(el=>{ fieldMappings[el.dataset.field] = el.value; });
    await put('anki/settings', {deck: $('#anki-deck').value, noteType: $('#anki-nt').value, tags: $('#anki-tags').value, fieldMappings});
    toast(T('已保存')); ankiFormKey=null; loadAnki();
  });
}
$('#anki-landing').onchange = guard(async()=>{ await post('anki/landing', {enabled: $('#anki-landing').checked}); loadAnki(); });
$('#btn-anki-run').onclick = guard(async()=>{ await post('anki/run'); toast(T('已落地一轮')); loadAnki(); });
$('#btn-anki-retry').onclick = guard(async()=>{ const r = await post('anki/retry'); toast(T('已重试 {0} 张', r.retried)); loadAnki(); });

// ── 复习 ──
const SRS_STATE = {opening:T('打开中'), ready:T('可用'), encrypted:T('同步位置已加密（暂不支持）'), needs_upgrade:T('数据来自更新版本的 Fushi，请升级服务端'), failed:T('出错')};
let srsFormKey = null;
async function loadSrs(){
  const [st, found] = await Promise.all([api('srs'), api('srs/profiles')]);
  const ac = st.ankiConnect || {};
  const kv = [
    [T('状态'), st.enabled ? T('已开启') : T('未开启（没有勾选配置文件）')],
    [T('调度器'), st.scheduler ? T('FSRS 可用') : T('没找到 fushi_fsrs（只能浏览 / 加卡）')],
    ['AnkiConnect', ac.listening ? T('监听 {0}:{1}', ac.bind, ac.listeningPort) : (ac.enabled ? T('未监听') + (ac.lastError ? T('：') + ac.lastError : '') : T('关闭'))],
  ];
  $('#srs-status').innerHTML = kv.map(([k,v])=>`<div class="kv"><b>${esc(k)}</b><span>${esc(v)}</span></div>`).join('');
  const served = {}; (st.profiles||[]).forEach(p=>served[p.uid]=p);
  const list = found.profiles || [];
  const key = JSON.stringify([list.map(p=>[p.uid,p.name,p.served,p.missing]), st.config, ac.enabled, ac.bind, ac.port, ac.apiKeySet, ac.profileKeysSet]);
  // 状态每轮刷新；表单只在内容变了时重画，不冲掉正在编辑的输入。
  const statusOf = (uid)=>{ const p = served[uid]; if(!p) return ''; return `${SRS_STATE[p.state]||p.state}${p.notes!=null?T(' · {0} 条笔记', p.notes):''}${p.lastSyncAt?T(' · 同步于 {0}', fmtTime(p.lastSyncAt)):''}${p.lastError?' · '+p.lastError:''}`; };
  if (key === srsFormKey) { document.querySelectorAll('[data-srs-status]').forEach(el=>{ el.textContent = statusOf(el.dataset.srsStatus); }); return; }
  srsFormKey = key;
  const cfg = st.config;
  const def = st.defaultProfile || cfg.defaultProfile;
  $('#srs-profiles').innerHTML = list.length ? `<table><tr><th>${esc(T('提供'))}</th><th>${esc(T('默认'))}</th><th>${esc(T('配置文件'))}</th><th>${esc(T('设备'))}</th><th>${esc(T('状态'))}</th><th></th></tr>${list.map(p=>`<tr>
      <td><input type="checkbox" data-srs-serve="${esc(p.uid)}" ${p.served?'checked':''}></td>
      <td><input type="radio" name="srs-def" data-srs-def="${esc(p.uid)}" ${p.uid===def?'checked':''} ${p.served?'':'disabled'}></td>
      <td>${esc(p.name||p.uid)}<div class="small muted">${esc(p.uid)}${p.missing?esc(T(' · 同步目录里已没有')):''}</div></td>
      <td class="small">${esc((p.devices||[]).join(T('、')))}${p.noteCount!=null?`<div class="muted">${esc(T('{0} 条笔记', p.noteCount))}</div>`:''}</td>
      <td class="small" data-srs-status="${esc(p.uid)}">${esc(statusOf(p.uid))}</td>
      <td>${p.served?`<button class="b sec" data-srs-sync="${esc(p.uid)}">${esc(T('同步'))}</button>`:''}</td></tr>`).join('')}</table>`
    : `<p class="muted">${esc(T('同步目录里还没有任何配置文件：先让一台设备经互联同步一次复习数据。'))}</p>`;
  document.querySelectorAll('[data-srs-serve]').forEach(el=>el.onchange = guard(async()=>{
    await put('srs', el.checked ? {addProfiles:[el.dataset.srsServe]} : {removeProfiles:[el.dataset.srsServe]});
    toast(el.checked ? T('已开始提供') : T('已停止提供')); srsFormKey=null; loadSrs();
  }));
  document.querySelectorAll('[data-srs-def]').forEach(el=>el.onchange = guard(async()=>{ await put('srs', {defaultProfile: el.dataset.srsDef}); toast(T('已设为默认')); srsFormKey=null; loadSrs(); }));
  document.querySelectorAll('[data-srs-sync]').forEach(el=>el.onclick = guard(async()=>{ await post('srs/sync', {profile: el.dataset.srsSync}); toast(T('已同步')); loadSrs(); }));

  const servedList = list.filter(p=>p.served);
  $('#srs-mining').innerHTML = `<p class="small muted">${esc(T('已配对设备「制卡到已配对设备」时卡片落到哪。手机可以在自己的设置里另选；没选时，手机当前的配置文件本机有就落进那份，否则落进默认那份。'))}</p>
    <div class="grid"><label class="f">${esc(T('落到'))}<select id="srs-target">${[['auto',T('自动（没配好 Anki 时进复习）')],['review',T('Fushi 复习')],['anki','Anki']].map(([v,l])=>`<option value="${v}" ${cfg.miningTarget===v?'selected':''}>${esc(l)}</option>`).join('')}</select></label>
    <label class="f">${esc(T('换日时刻（0–23 点）'))}<input type="number" min="0" max="23" id="srs-rollover" value="${cfg.rolloverHour}"></label>
    ${servedList.map(p=>`<label class="f">${esc(T('{0} 的制卡牌组（空 = 默认牌组）', p.name||p.uid))}<input data-srs-deck="${esc(p.uid)}" value="${esc((cfg.miningDecks||{})[p.uid]||'')}"></label>`).join('')}</div>
    <div class="row" style="margin-top:12px"><button class="b" id="btn-srs-save">${esc(T('保存'))}</button></div>`;
  $('#btn-srs-save').onclick = guard(async()=>{
    const miningDecks = {}; document.querySelectorAll('[data-srs-deck]').forEach(el=>{ if(el.value.trim()) miningDecks[el.dataset.srsDeck]=el.value.trim(); });
    await put('srs', {miningTarget: $('#srs-target').value, rolloverHour: parseInt($('#srs-rollover').value,10), miningDecks});
    toast(T('已保存')); srsFormKey=null; loadSrs();
  });

  const setNote = (isSet) => isSet ? ` <span class="muted">${esc(T('(已设置，留空不改)'))}</span>` : '';
  $('#srs-ankiconnect').innerHTML = `<div class="grid">
    <label class="f">${esc(T('开关'))}<select id="ac-enabled"><option value="true" ${ac.enabled?'selected':''}>${esc(T('开'))}</option><option value="false" ${!ac.enabled?'selected':''}>${esc(T('关'))}</option></select></label>
    <label class="f">${esc(T('监听地址（127.0.0.1 = 只限本机）'))}<input id="ac-bind" value="${esc(ac.bind||'127.0.0.1')}"></label>
    <label class="f">${esc(T('端口'))}<input type="number" id="ac-port" value="${ac.port||8765}"></label>
    <label class="f">${esc(T('共用 key（落到默认配置文件）'))}${setNote(ac.apiKeySet)}<input type="password" id="ac-key" value=""></label>
    ${servedList.map(p=>`<label class="f">${esc(T('{0} 专用 key', p.name||p.uid))}${setNote((ac.profileKeysSet||{})[p.uid])}<input type="password" data-ac-key="${esc(p.uid)}" value=""></label>`).join('')}</div>
    <div class="row" style="margin-top:12px"><button class="b" id="btn-ac-save">${esc(T('保存'))}</button>${ac.apiKeySet?`<button class="b sec" id="btn-ac-clear">${esc(T('清除共用 key'))}</button>`:''}</div>`;
  $('#btn-ac-save').onclick = guard(async()=>{
    const body = {enabled: $('#ac-enabled').value==='true', bind: $('#ac-bind').value.trim(), port: parseInt($('#ac-port').value,10)};
    if ($('#ac-key').value) body.apiKey = $('#ac-key').value;
    const profileKeys = {}; document.querySelectorAll('[data-ac-key]').forEach(el=>{ if(el.value) profileKeys[el.dataset.acKey]=el.value; });
    if (Object.keys(profileKeys).length) body.profileKeys = profileKeys;
    await put('srs', {ankiConnect: body}); toast(T('已保存')); srsFormKey=null; loadSrs();
  });
  const clear = $('#btn-ac-clear');
  if (clear) clear.onclick = guard(async()=>{ await put('srs', {ankiConnect:{apiKey:''}}); toast(T('已清除')); srsFormKey=null; loadSrs(); });
}

// ── 设置 ──
const FIELDS = [
  ['language',T('界面语言（Language）'),'select:en,zh'],
  ['deviceName',T('设备名'),'text'],['port',T('互联端口'),'number'],['bind',T('绑定地址'),'text'],['tls','TLS','bool'],['lanRequiresPin',T('局域网配对必须 PIN'),'bool'],
  ['subtitleLanguage',T('字幕语言'),'text'],['metadataLocale',T('刮削资料语言（BCP-47，如 ja / zh-CN）'),'text'],
  ['scanScrape',T('扫描后自动补刮视频资料'),'bool'],['tmdbApiKey',T('TMDB API key（服务端没有内置 key，不填则 TMDB 不可用）'),'secret:tmdbApiKeySet'],['scanPrune',T('扫描后清理文件已消失的视频条目'),'bool'],['profileTransfer',T('允许已配对设备推送 / 拉取配置文件（Profile）'),'bool'],['remoteUpdate',T('允许已配对设备远程更新本服务端（仅发布包；装完退出码 75，由服务管理器重启）'),'bool'],['leaderboardLink',T('允许「我的设备」跟随本机 Fushi 排行榜账户自动登录'),'bool'],['lookupChineseScriptVariants',T('中文查词简繁互查（只管不自带开关的浏览器扩展 / 旧客户端；新版 app 用自己的开关）'),'bool'],['ffmpeg',T('ffmpeg 路径（空=PATH）'),'text'],['ffprobe',T('ffprobe 路径（空=PATH）'),'text'],['onnxruntimeLibrary',T('onnxruntime 动态库'),'text'],['uploadQuotaBytes',T('上传配额（字节）'),'number'],['adminPort',T('WebUI 端口'),'number'],
  ['torrent.engine',T('torrent 引擎'),'select:auto,embedded,qbittorrent'],['torrent.library',T('内置引擎库路径（空=随包/系统）'),'text'],['torrent.listen',T('libtorrent 监听接口'),'text'],
  ['qbittorrent.url',T('qBittorrent WebUI 地址'),'text'],['qbittorrent.username',T('qBittorrent 用户名'),'text'],['qbittorrent.password',T('qBittorrent 密码'),'password'],
  ['ai.preset',T('AI 提供商（手机「AI 下视频」选本机执行时用；空 = 不用 AI、不发任何 AI 请求）'),'dyn:aiPresets'],['ai.apiKey','AI API key','secret:ai.apiKeySet'],
  ['ai.model',T('AI 模型（空 = 预设起点模型）'),'text'],['ai.baseUrl',T('AI 接口地址（空 = 预设地址）'),'text'],['ai.protocol',T('AI 协议（空 = 跟随预设）'),'select:,openAiCompatible,anthropicMessages,geminiGenerateContent'],
  ['ai.reasoningEffort',T('AI 推理档位'),'select:none,low,medium,high'],['ai.allowInsecureHttp',T('AI 允许明文 HTTP（本地推理服务）'),'bool'],['ai.webKnowledge',T('AI 联网资料（维基辅助识别作品）'),'bool'],['ai.libraryOrganize',T('扫描入库后自动 AI 整理库（把该在一起的归进合集，按量计费）'),'bool'],
];
const LANGUAGE_NAMES = {en:'English', zh:'中文'};
let settingsCache=null;
async function loadSettings(){
  const s = await api('settings'); const first=!settingsCache; settingsCache=s;
  // 远程访问卡片有自己的保存键：主表单保存后只刷新 P2P 状态，不冲掉它未保存的编辑。
  if(first) renderRemoteReach(s); else renderP2pState(s.p2pStatus);
  const found = s.torrent && s.torrent.embeddedLibraryFound;
  const setNote = (isSet) => isSet ? ` <span class="muted">${esc(T('(已设置，留空不改)'))}</span>` : '';
  $('#settings-form').innerHTML = FIELDS.map(([k,label,type])=>{ let v = k.includes('.') ? (s[k.split('.')[0]]||{})[k.split('.')[1]] : s[k]; const id='f-'+k.replace('.','-'); if(k==='torrent.library'&&!v) label += found ? T('（已找到 {0}）', found) : T('（未找到随包库）');
    if(k==='ai.webKnowledge'&&!s.ai) v=true; if(k==='ai.preset'&&s.ai) label += s.ai.status==='ready' ? T('（可用）') : T('（未配全：{0}）', s.ai.problem||'');
    if(type.startsWith('dyn:')) return `<label class="f">${esc(label)}<select id="${id}">${['',...(s[type.slice(4)]||[])].map(o=>`<option value="${esc(o)}" ${o===(v??'')?'selected':''}>${esc(o)}</option>`).join('')}</select></label>`;
    if(type==='bool') return `<label class="f">${esc(label)}<select id="${id}"><option value="true" ${v?'selected':''}>${esc(T('开'))}</option><option value="false" ${!v?'selected':''}>${esc(T('关'))}</option></select></label>`;
    if(type.startsWith('select:')) return `<label class="f">${esc(label)}<select id="${id}">${type.slice(7).split(',').map(o=>`<option value="${esc(o)}" ${o===v?'selected':''}>${esc(k==='language'?LANGUAGE_NAMES[o]:o)}</option>`).join('')}</select></label>`;
    if(type==='password') return `<label class="f">${esc(label)}${setNote(s.qbittorrent.passwordSet)}<input type="password" id="${id}" value=""></label>`;
    if(type.startsWith('secret:')){ const sk=type.slice(7); const isSet = sk.includes('.') ? (s[sk.split('.')[0]]||{})[sk.split('.')[1]] : s[sk]; return `<label class="f">${esc(label)}${setNote(isSet)}<input type="password" id="${id}" value=""></label>`; }
    return `<label class="f">${esc(label)}<input type="${type}" id="${id}" value="${esc(v??'')}"></label>`; }).join('');
}
$('#btn-settings-save').onclick = guard(async()=>{
  const body={qbittorrent:{},torrent:{},ai:{}};
  for(const [k,,type] of FIELDS){ const el=$('#f-'+k.replace('.','-')); let v=el.value; if(type==='bool') v=(v==='true'); else if(type==='number') v=Number(v); if(type!=='bool'&&type!=='number'&&v==='') v=null;
    if(k.includes('.')) body[k.split('.')[0]][k.split('.')[1]]=v; else body[k]=v; }
  // 路径类字段：空串代表「清掉」——但 copyWith 的 null 是「不改」，所以传空串让服务端按空处理
  for(const k of ['ffmpeg','ffprobe','onnxruntimeLibrary']) if(body[k]===null) delete body[k];
  await put('settings',body);
  // 界面语言在出页时定：改了就重载。
  if (body.language && body.language !== LANG) { location.reload(); return; }
  toast(T('已保存')); loadSettings();
});

// ── 远程访问（公网地址 / P2P / 自建中继：保存即生效）──
const lines = (s)=>s.split(/\r?\n/).map(x=>x.trim()).filter(Boolean);
const P2P_REASON = {unavailable:T('不可用：没找到 libfushi_p2p（放在 bin/../lib/ 或设环境变量 FUSHI_P2P_LIB）'), disabled:T('未开启'), host_stopped:T('互联 host 未运行'), loopback_bind:T('未生效：bind 只监听本机（127.0.0.1），隧道不对外开'), start_failed:T('启动失败，详见日志')};
function p2pSummary(st){ if(!st) return '—'; return st.active ? T('已启用') : (P2P_REASON[st.reason]||st.reason||'—'); }
function renderP2pState(st){
  if(!st) return;
  const cb=$('#rr-p2p');
  // 不可用时置灰；但原本就开着（手写 yaml）时仍允许关掉。
  cb.disabled = !st.available && !cb.checked;
  const el=$('#rr-state');
  if(st.active){
    el.innerHTML = `${tag('ok', T('已启用'))} NodeId <code>${esc(st.nodeId)}</code>`
      + (st.relayUrl?`<br><span class="muted">${esc(T('中继 {0}', st.relayUrl))}</span>`:'')
      + ((st.directAddrs||[]).length?`<br><span class="muted">${esc(T('直连 {0}', st.directAddrs.join(', ')))}</span>`:'');
  } else {
    const bad = st.reason==='unavailable'||st.reason==='start_failed'||st.reason==='loopback_bind';
    el.innerHTML = tag(bad?'err':'', p2pSummary(st))
      + (st.nodeId?` NodeId <code>${esc(st.nodeId)}</code>`:'')
      + (st.lastError?`<br><span style="color:var(--err)">${esc(st.lastError)}</span>`:'');
  }
}
function renderRemoteReach(s){
  $('#rr-public').value=(s.publicUrls||[]).join('\n');
  $('#rr-relays').value=(s.p2pRelays||[]).join('\n');
  $('#rr-p2p').checked=!!s.p2p;
  renderP2pState(s.p2pStatus);
}
$('#btn-rr-save').onclick = guard(async()=>{
  $('#btn-rr-save').disabled=true;
  try{
    const s = await put('settings',{publicUrls:lines($('#rr-public').value), p2p:$('#rr-p2p').checked, p2pRelays:lines($('#rr-relays').value)});
    settingsCache=s; renderRemoteReach(s); toast(T('已保存并生效'));
  } finally { $('#btn-rr-save').disabled=false; }
});

// ── AI 助手会话 ──
const AI_KIND = {user:T('用户'), assistant:'AI', toolCall:T('操作'), confirm:T('确认'), choice:T('候选'), notice:T('提示')};
const aiDevice = (s) => s.originPeerId ? (s.originDeviceName || s.originPeerId) : T('本机');
let aiOpen = null;
async function loadAi(){
  const r = await api('ai/sessions');
  $('#ai-sessions').innerHTML = r.sessions.map(s=>`<tr data-ai="${esc(s.id)}" style="cursor:pointer"><td>${esc(s.title||T('新对话'))}</td><td>${esc(aiDevice(s))}</td><td class="small">${fmtTime(s.updatedAt)}</td><td class="small">${esc(s.tokens)}</td></tr>`).join('') || empty(4, T('无'));
  $('#ai-sessions').querySelectorAll('[data-ai]').forEach(tr=>tr.onclick=guard(async()=>{ aiOpen=tr.dataset.ai; await loadAiDetail(); }));
  if (aiOpen) await loadAiDetail();
}
async function loadAiDetail(){
  const s = await api('ai/sessions/'+encodeURIComponent(aiOpen));
  $('#ai-detail').style.display='block';
  $('#ai-detail-title').textContent = s.title || T('新对话');
  $('#ai-detail-meta').textContent = `${aiDevice(s)} · ${fmtTime(s.createdAt)} → ${fmtTime(s.updatedAt)} · ${s.tokens} tokens`;
  $('#ai-entries').innerHTML = s.entries.map(e=>`<div class="row" style="align-items:flex-start"><span class="tag">${esc(AI_KIND[e.kind]||e.kind)}</span><div style="flex:1;white-space:pre-wrap">${esc(e.toolName?e.toolName+(e.text?' — '+e.text:''):(e.text||''))} ${e.status&&e.kind!=='user'&&e.kind!=='assistant'?stTag(e.status):''} ${e.errorCode?`<span class="small" style="color:var(--err)">${esc(e.errorCode)}</span>`:''}</div></div>`).join('') || `<p class="muted">${esc(T('无'))}</p>`;
}

// ── 日志 ──
async function loadLogs(){ const r = await api('logs'); const pre=$('#logs'); const atBottom = pre.scrollTop+pre.clientHeight >= pre.scrollHeight-10; pre.textContent = r.lines.join('\n'); if(atBottom) pre.scrollTop=pre.scrollHeight; }
$('#btn-log-refresh').onclick = guard(loadLogs);

// ── 轮询 ──
const loaders = {status:loadStatus, pairing:loadPairing, libraries:loadLibraries, upload:async()=>{ await loadLibraries(); const s=await api('status'); $('#up-quota').textContent=T('配额已用 {0} / {1}', fmtBytes(s.uploadUsedBytes), fmtBytes(s.uploadQuotaBytes)); }, jobs:loadJobs, downloads:loadDownloads, subscriptions:async()=>{ await loadSubscriptions(); await loadIndexers(false); }, ai:loadAi, anki:loadAnki, srs:loadSrs, models:loadModels, settings:async()=>{ if(!settingsCache) await loadSettings(); else renderP2pState(await api('p2p')); }, logs:async()=>{ if($('#log-auto').checked) await loadLogs(); }};
let busy=false;
async function refresh(){ if(busy) return; busy=true; try{ await loaders[current](); }catch(e){ console.warn(e); } finally{ busy=false; } }
refresh(); setInterval(refresh, 2500);
// 配对 PIN 不管在哪个页都要能看见：标题栏闪提示
setInterval(async()=>{ if(current==='pairing') return; try{ const p=await api('pairing'); if(p.pending){ document.title=T('★ 配对 PIN {0} — fushi_server', p.pending.pin); } else document.title='fushi_server'; }catch(e){} }, 3000);
</script>
</body></html>''';

/// 登录页里要翻的两段（`__T_<中文>__` 占位，见 [renderAdminLogin]）。
final RegExp _loginTextSlot = RegExp(r'__T_(.+?)__', dotAll: true);

/// `<html lang>` 值。
String _htmlLang(String language) =>
    language == ServerConfig.languageChinese ? 'zh-CN' : 'en';

/// 按界面语言出 WebUI 主页：填 `<html lang>`、页面脚本里的 `LANG` 与英文表 `EN`
/// （中文界面给空表，`T()` 原样返回中文）。
String renderAdminWebUi(String language) {
  final bool en = language == ServerConfig.languageEnglish;
  return adminWebUiHtml
      .replaceFirst('__FUSHI_HTML_LANG__', _htmlLang(language))
      .replaceFirst("'__FUSHI_LANG__'", jsonEncode(language))
      .replaceFirst('__FUSHI_EN__', en ? jsonEncode(kWebUiEnglish) : '{}');
}

/// 按界面语言出登录页；[tokenError] = 上次提交的 token 不对。
String renderAdminLogin(String language, {bool tokenError = false}) {
  final bool en = language == ServerConfig.languageEnglish;
  String t(String zh) => en ? (kWebUiEnglish[zh] ?? zh) : zh;
  String html = adminLoginHtml
      .replaceFirst('__FUSHI_HTML_LANG__', _htmlLang(language))
      .replaceAllMapped(_loginTextSlot, (Match m) => t(m.group(1)!));
  if (tokenError) {
    html = html.replaceFirst(
      '<!--error-->',
      '<p class="err">${t('Token 不正确')}</p>',
    );
  }
  return html;
}
