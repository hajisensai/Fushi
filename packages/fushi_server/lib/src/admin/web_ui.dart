/// WebUI 静态页：一个 HTML 字符串，原生 JS，无构建步骤、无第三方脚本、无外链字体。
///
/// 页面只吃 `/api/admin/*` JSON；所有状态都轮询（2~5 秒），不做 WebSocket——
/// 单管理员局域网面板，轮询足够且没有连接状态机要维护。
///
/// 视觉与浏览器扩展共用同一套设计系统（`/kit/`，见 `web_kit.dart`；真源
/// `tools/browser-extension/`）：token、HCT 动态配色、明暗 / 预设配色 / M3E 与液态玻璃
/// 两套风格、控件形态（按钮 / 分段 / chip / 开关 / 下拉 / 对话框 / 列表行 / 导航 rail）
/// 与 Material Symbols 图标都从那里来，本页只写布局与少量页面专属样式。页面在
/// `<html data-fushi-theme-host="page">` 上声明自己是独立网页，主题选择存在本机浏览器。
///
/// 界面语言来自配置 `language`（`en` / `zh`），在出页时定：[renderAdminWebUi] /
/// [renderAdminLogin]。源文案是中文，英文在 `web_ui_en.dart` 的 [kWebUiEnglish]
/// （键 = 中文原文）；`web_ui_i18n_test.dart` 保证页面里每条中文都有英文。
library;

import 'dart:convert';

import 'package:fushi_engine/media/torrent/bt_site_parser_rule.dart'
    show kBtSiteParserRuleTemplate;
import 'package:fushi_server/src/admin/web_kit.dart';
import 'package:fushi_server/src/admin/web_ui_assets.dart';
import 'package:fushi_server/src/admin/web_ui_en.dart';
import 'package:fushi_server/src/config/server_config.dart';

/// 两页共用的 `<head>` 公共部分；`__FUSHI_KIT_HEAD__` 在出页时换成共享库标签。
const String _kHead =
    r'''<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="color-scheme" content="light dark">
<link rel="icon" type="image/png" href="__FUSHI_LOGO__">
__FUSHI_KIT_HEAD__
<style>
*{box-sizing:border-box}
html,body{height:100%}
body{margin:0;font-family:var(--md-sys-typescale-font);font-size:var(--md-sys-typescale-body-medium-size);line-height:1.45;background:var(--md-sys-color-surface);color:var(--md-sys-color-on-surface);-webkit-font-smoothing:antialiased}
button,input,select,textarea{font:inherit;color:inherit}
code,.mono{font-family:ui-monospace,"Cascadia Mono","SF Mono","Roboto Mono",Menlo,monospace}
code{font-size:.92em;background:var(--md-sys-color-surface-container-highest);padding:1px 6px;border-radius:var(--md-sys-shape-corner-extra-small);overflow-wrap:anywhere}
.mono{font-size:12px}
</style>''';

const String adminLoginHtml =
    r'''<!doctype html>
<html lang="__FUSHI_HTML_LANG__" data-fushi-theme-host="page"><head>
<title>fushi_server</title>
''' +
    _kHead +
    r'''
<style>
body{display:flex;align-items:center;justify-content:center;padding:24px 16px}
form{width:100%;max-width:400px;display:flex;flex-direction:column;gap:16px;padding:32px 28px;animation:pop var(--fushi-dur-medium) var(--fushi-ease-decel) both}
.logo{width:56px;height:56px;border-radius:var(--md-sys-shape-corner-large);display:block}
h1{margin:0}
.err{margin:0;padding:10px 14px;border-radius:var(--md-sys-shape-corner-medium);background:var(--md-sys-color-error-container);color:var(--md-sys-color-on-error-container);font-size:13px}
input{height:48px}
.primary-button{width:100%;height:48px}
@keyframes pop{from{opacity:0;transform:scale(.94)}}
</style></head><body>
<form class="card" method="post" action="/login">
<img class="logo" src="__FUSHI_LOGO__" alt="">
<h1 class="kit-title-large">fushi_server</h1>
<!--error-->
<input type="password" name="token" placeholder="admin_token" autofocus autocomplete="current-password" aria-label="admin_token">
<button class="primary-button" type="submit">__T_登录__</button>
<p class="kit-supporting">__T_token 在 fushi_server.yaml 的 admin_token；忘了用 <code>fushi_server admin reset-token</code> 重生成。__</p>
</form></body></html>''';

const String adminWebUiHtml =
    r'''<!doctype html>
<html lang="__FUSHI_HTML_LANG__" data-fushi-theme-host="page"><head>
<title>fushi_server</title>
''' +
    _kHead +
    r'''
<style>
/* hidden 一律压过共享库组件自带的 display（图标按钮 / 进度条 / 徽标 / 就地编辑框）。 */
[hidden]{display:none!important}
section > .kit-section-title{margin:8px 4px -4px}
.app{--rail-w:88px;height:100%;display:grid;grid-template-columns:var(--rail-w) minmax(0,1fr);grid-template-rows:64px minmax(0,1fr);transition:grid-template-columns var(--md-sys-motion-spring-default-spatial-duration) var(--md-sys-motion-spring-default-spatial)}
.app:has(.nav-rail.is-expanded){--rail-w:264px}
/* ── 导航：宽屏 rail，窄屏抽屉（.is-drawer 由脚本按宽度切） ── */
.nav-rail{grid-row:1/3;z-index:5}
.brand{display:flex;align-items:center;gap:12px;min-width:0}
.brand img{width:40px;height:40px;border-radius:var(--md-sys-shape-corner-medium);display:block;flex:none}
.brand span{display:none;font-size:var(--md-sys-typescale-title-medium-size);line-height:var(--md-sys-typescale-title-medium-line-height);font-weight:var(--md-sys-typescale-weight-emphasized,600);white-space:nowrap}
.nav-rail:is(.is-expanded,.is-drawer) .brand span{display:block}
.nav-rail.is-drawer #btn-rail{display:none}
/* ── 顶栏 ── */
.topbar{grid-column:2;display:flex;align-items:center;gap:4px;padding:0 12px 0 24px;min-width:0}
.topbar #btn-menu{display:none}
.topbar form{margin:0}
.ttl{flex:1;min-width:0;display:flex;flex-direction:column}
.ttl h1{margin:0;font-size:var(--md-sys-typescale-title-large-size,22px);font-weight:400;line-height:28px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.ttl span{font-size:12px;color:var(--md-sys-color-on-surface-variant);white-space:nowrap;overflow:hidden;text-overflow:ellipsis;font-variant-numeric:tabular-nums}
/* ── 内容：每页一栏，进页时子块错峰浮入 ── */
main{grid-column:2;overflow-y:auto;padding:4px 24px 48px}
section{display:none;max-width:1040px;flex-direction:column;gap:16px}
section.on{display:flex}
section.on > *{animation:enter var(--fushi-dur-long,420ms) var(--fushi-ease-decel) both}
section.on > :nth-child(2){animation-delay:30ms}section.on > :nth-child(3){animation-delay:60ms}section.on > :nth-child(4){animation-delay:90ms}section.on > :nth-child(5){animation-delay:120ms}section.on > :nth-child(n+6){animation-delay:150ms}
@keyframes enter{from{opacity:0;transform:translateY(12px)}}
.card,.card-inset{display:flex;flex-direction:column;gap:16px}
.card > *,.card-inset > *{margin:0}
.card > :is(.kit-title-medium,h2) + .kit-supporting,.card-inset > .kit-supporting + .kit-supporting{margin-top:-12px}
.card > .card-head + .progress{margin-top:-4px}
.card-head-copy > .kit-supporting{margin-top:4px}
.kit-title-medium{margin:0}
/* 色阶：页面 surface 上的内容块（卡片 / 分段列表 / 空状态）统一高一级 surface-container-low；卡片里的列表行再高一级，卡片里的空状态不另起底。 */
:root:not([data-style="glass"]) main :is(.setting-list > .setting-row,.empty-state){background-color:var(--md-sys-color-surface-container-low)}
:root:not([data-style="glass"]) main .card :is(.setting-list > .setting-row){background-color:var(--md-sys-color-surface-container)}
main .card .empty-state{background:none;padding:16px 8px}
.nav-rail:is(.is-expanded,.is-drawer) .nav-group-label{padding:0 18px}
.note{margin:0 4px;color:var(--md-sys-color-on-surface-variant);font-size:12px;line-height:1.55}
.muted{color:var(--md-sys-color-on-surface-variant)}.small{font-size:12px}
.tiles{display:grid;grid-template-columns:repeat(4,minmax(0,1fr));gap:12px}
.tiles .skeleton{height:104px}
.setting-list > .skeleton{height:64px}
.choice-ctl{display:flex;flex-direction:column;gap:8px;min-width:0}
.bytes-ctl{display:flex;gap:8px;min-width:0}
.bytes-ctl > input{flex:1 1 auto;min-width:0}
.bytes-ctl > .fgs,.bytes-ctl > select{flex:0 0 104px}
.kind-hint{color:var(--md-sys-color-on-surface-variant);font-weight:400}
/* 「需要处理」 */
.attn .setting-row{cursor:pointer}
.chev{color:var(--md-sys-color-on-surface-variant);flex:none}
.more{position:relative}
.more > .kit-menu{position:absolute;right:0;top:calc(100% + 4px);z-index:20}
/* 词典行：语言下拉 / 自定义标签 / 显示名就地编辑 */
.dict-lang{min-width:168px;max-width:240px}
input.dict-lang-other{width:168px;height:40px}
input.dict-name-edit{width:min(320px,100%);height:36px}
/* 日志 */
pre{margin:12px 0 0;background:var(--md-sys-color-surface-container-lowest);border-radius:var(--md-sys-shape-corner-medium);padding:14px;overflow:auto;max-height:65vh;font-family:ui-monospace,"Cascadia Mono","SF Mono",Menlo,monospace;font-size:12px;line-height:1.6;white-space:pre-wrap;color:var(--md-sys-color-on-surface-variant)}
.lv-error{color:var(--md-sys-color-error)}
/* 配对 PIN */
.pin-card{display:flex;gap:12px 24px;align-items:center;flex-wrap:wrap}
.pin-card > div{flex:1 1 240px;min-width:0}
.pin{font-family:ui-monospace,"Cascadia Mono","SF Mono",Menlo,monospace;font-size:44px;font-weight:600;letter-spacing:.18em;font-variant-numeric:tabular-nums;overflow-wrap:anywhere}
.pulse{display:inline-block;width:10px;height:10px;border-radius:50%;background:currentColor;margin-right:8px;animation:pulse 1.6s infinite}
@keyframes pulse{50%{opacity:.25}}
/* AI 会话 */
.setting-row.is-selected{background:color-mix(in oklch,var(--md-sys-color-on-surface) 8%,transparent)}
.entry{display:flex;gap:12px;align-items:flex-start;padding:10px 0}
.entry + .entry{border-top:1px solid var(--md-sys-color-outline-variant)}
.entry > div{flex:1;min-width:0;white-space:pre-wrap;overflow-wrap:anywhere}
.err-text{color:var(--md-sys-color-error)}
#toast.is-error{background-color:var(--md-sys-color-error-container);color:var(--md-sys-color-on-error-container)}
/* 外观 */
.appearance{display:flex;flex-direction:column;gap:20px}
.appearance .field{max-width:100%}
/* ── 响应式 ── */
@media (max-width: 1000px){.tiles{grid-template-columns:repeat(2,minmax(0,1fr))}}
@media (max-width: 640px){
.app{grid-template-columns:minmax(0,1fr)}
.topbar{grid-column:1;padding:0 8px}
.topbar #btn-menu{display:grid}
.ttl h1{font-size:18px;line-height:24px}
main{grid-column:1;padding:4px 16px 48px}
.tiles{gap:8px}
.pin{font-size:36px}
}
</style></head><body>
<div class="app">
<nav class="nav-rail" id="rail">
<div class="nav-rail-head"><div class="brand"><img src="__FUSHI_LOGO__" alt=""><span>fushi_server</span></div><button class="icon-button" id="btn-rail" type="button" title="收起侧边栏" aria-expanded="true"><span class="msr-slot" data-fushi-icon="menu"></span></button></div>
<div class="nav-group-label">概览</div>
<button class="nav-item" data-s="status" aria-current="page"><span class="nav-indicator"><span class="msr-slot" data-fushi-icon="dashboard"></span></span><span class="nav-label">状态</span></button>
<button class="nav-item" data-s="pairing"><span class="nav-indicator"><span class="msr-slot" data-fushi-icon="link"></span><span class="badge" id="pair-badge" hidden></span></span><span class="nav-label">配对</span></button>
<div class="nav-group-label">媒体库</div>
<button class="nav-item" data-s="libraries"><span class="nav-indicator"><span class="msr-slot" data-fushi-icon="folder"></span></span><span class="nav-label">库</span></button>
<button class="nav-item" data-s="upload"><span class="nav-indicator"><span class="msr-slot" data-fushi-icon="cloud_upload"></span></span><span class="nav-label">上传</span></button>
<button class="nav-item" data-s="dictionaries"><span class="nav-indicator"><span class="msr-slot" data-fushi-icon="dictionary"></span></span><span class="nav-label">词典</span></button>
<div class="nav-group-label">获取</div>
<button class="nav-item" data-s="jobs"><span class="nav-indicator"><span class="msr-slot" data-fushi-icon="task_alt"></span></span><span class="nav-label">任务</span></button>
<button class="nav-item" data-s="downloads"><span class="nav-indicator"><span class="msr-slot" data-fushi-icon="download"></span></span><span class="nav-label">下载</span></button>
<button class="nav-item" data-s="subscriptions"><span class="nav-indicator"><span class="msr-slot" data-fushi-icon="rss_feed"></span></span><span class="nav-label">订阅</span></button>
<button class="nav-item" data-s="models"><span class="nav-indicator"><span class="msr-slot" data-fushi-icon="memory"></span></span><span class="nav-label">模型</span></button>
<div class="nav-group-label">学习</div>
<button class="nav-item" data-s="ai"><span class="nav-indicator"><span class="msr-slot" data-fushi-icon="auto_awesome"></span></span><span class="nav-label">AI 助手</span></button>
<button class="nav-item" data-s="anki"><span class="nav-indicator"><span class="msr-slot" data-fushi-icon="layers"></span></span><span class="nav-label">Anki</span></button>
<button class="nav-item" data-s="srs"><span class="nav-indicator"><span class="msr-slot" data-fushi-icon="school"></span></span><span class="nav-label">复习</span></button>
<div class="nav-group-label">系统</div>
<button class="nav-item" data-s="settings"><span class="nav-indicator"><span class="msr-slot" data-fushi-icon="settings"></span></span><span class="nav-label">设置</span></button>
<button class="nav-item" data-s="logs"><span class="nav-indicator"><span class="msr-slot" data-fushi-icon="receipt_long"></span></span><span class="nav-label">日志</span></button>
</nav>
<div class="nav-scrim" id="scrim-nav"></div>
<header class="topbar">
<button class="icon-button" id="btn-menu" type="button" title="菜单"><span class="msr-slot" data-fushi-icon="menu"></span></button>
<div class="ttl"><h1 id="page-title">状态</h1><span id="devname"></span></div>
<button class="icon-button" id="btn-theme" type="button"><span class="msr-slot" data-fushi-icon="contrast"></span></button>
<form method="post" action="/logout"><button class="icon-button" type="submit" title="退出"><span class="msr-slot" data-fushi-icon="logout"></span></button></form>
</header>
<main id="main">

<section id="s-status" class="on">
<div class="tiles" id="status-tiles"><div class="skeleton"></div><div class="skeleton"></div><div class="skeleton"></div><div class="skeleton"></div></div>
<h3 class="kit-section-title" id="attn-h" hidden>需要处理</h3>
<div class="setting-list is-surface attn" id="status-attn"></div>
<div class="card"><div class="card-head"><div class="card-head-copy"><h2 class="kit-title-medium">扫描</h2><p class="kit-supporting" id="scan-state"></p></div><button class="primary-button" id="btn-scan"><span class="msr-slot" data-fushi-icon="refresh"></span>立即扫描库</button></div>
<div class="progress is-indeterminate" id="scan-bar" hidden><i></i></div></div>
<h3 class="kit-section-title">运行状态</h3>
<div class="card"><div class="kv-grid" id="status-grid"></div></div>
</section>

<section id="s-pairing">
<div id="pairing-lockout"></div>
<div class="card"><div class="card-head"><div class="card-head-copy"><h2 class="kit-title-medium">配对链接</h2><p class="kit-supporting">一次性链接自带票据，配对不用 PIN；来自公网的 PIN 配对被暂停时也能用。</p></div><button class="text-button" id="btn-pair-link">生成配对链接</button></div><div id="pair-link-out" hidden></div></div>
<div id="pairing-pending"><div class="setting-list is-surface"><div class="skeleton"></div></div></div>
<h3 class="kit-section-title">已配对设备</h3>
<div class="setting-list is-surface" id="peers"><div class="skeleton"></div><div class="skeleton"></div></div>
<p class="note"><span id="lb-link-state"></span> 标为「我的设备」的已配对设备在本机没有 Fushi 账户时，会跟随本机（当前 Profile）的排行榜账户自动登录：设备只交来它自己的公钥，由本机账户代绑；私钥 / 恢复码不外传。配对不会自动标记；只有配对时证明过设备钥匙的设备能标（旧版客户端需升级后重新配对）。仅 TLS 下可用，总开关在「设置」。</p>
<h3 class="kit-section-title">配置文件寄存<span class="kit-spacer"></span><span id="prof-state"></span></h3>
<div class="card"><div class="card-head"><div class="card-head-copy"><p class="kit-supporting">已配对设备在「互联 → 上传配置 / 下载配置」里把配置方案（Profile）推到本机寄存，另一台设备再拉走。本机只寄存、不应用；设备拉取时交出标「分发中」的那一份（缺省为最近收到的）。凭据已由发送端剔除。仅 TLS 下可用。</p></div><button class="text-button" id="btn-prof-toggle"></button></div></div>
<div class="setting-list is-surface" id="profiles"></div>
</section>

<section id="s-libraries">
<h3 class="kit-section-title">扫描根</h3>
<div class="setting-list is-surface" id="libs"><div class="skeleton"></div><div class="skeleton"></div></div>
<div class="card"><h2 class="kit-title-medium">添加</h2>
<div class="form-grid">
<label class="field is-wide">路径<input type="text" id="lib-path" placeholder="/srv/media/anime"></label>
<div class="field is-wide">类型<div class="segmented" id="lib-kind" role="radiogroup">
<label><input type="radio" name="lib-kind" value="video" checked><span><span class="msr-slot" data-fushi-icon="movie"></span>视频</span></label>
<label><input type="radio" name="lib-kind" value="book"><span><span class="msr-slot" data-fushi-icon="book"></span>书</span></label>
<label><input type="radio" name="lib-kind" value="manga"><span><span class="msr-slot" data-fushi-icon="auto_stories"></span>漫画</span></label>
<label><input type="radio" name="lib-kind" value="audiobook"><span><span class="msr-slot" data-fushi-icon="headphones"></span>有声书</span></label></div><span class="field-hint" id="lib-kind-hint"></span></div>
<label class="field">id（可空）<input type="text" id="lib-id"></label></div>
<div class="action-row"><button class="primary-button" id="btn-lib-add"><span class="msr-slot" data-fushi-icon="add"></span>添加</button><span class="field-hint">加完记得在「状态」页点扫描；服务端进程要能读到该目录。</span></div>
</div>
</section>

<section id="s-upload">
<div class="card"><h2 class="kit-title-medium">上传到库</h2>
<div class="form-grid">
<label class="field">库<select id="up-lib"></select></label>
<label class="field">子目录（可空，如 Season1）<input type="text" id="up-sub" list="up-sub-list" autocomplete="off"><datalist id="up-sub-list"></datalist></label>
<div class="field is-wide">文件<label class="dropzone"><input type="file" id="up-files" multiple><span class="msr-slot" data-fushi-icon="upload_file"></span><span class="dropzone-label">拖放文件到这里，或点击选择</span><span class="dropzone-files" id="up-files-names"></span></label></div></div>
<div class="action-row"><button class="primary-button" id="btn-up"><span class="msr-slot" data-fushi-icon="upload"></span>开始上传</button><span class="field-hint">分块 8 MB，可断点续传（同名文件继续）；上传完成后需扫描库。</span></div>
</div>
<div class="setting-list is-surface" id="up-list"></div>
<p class="note" id="up-quota"></p>
</section>

<section id="s-dictionaries">
<h3 class="kit-section-title">查词引擎<span class="kit-spacer"></span><button class="plain-button" id="btn-dict-reload"><span class="msr-slot" data-fushi-icon="refresh"></span>重新装载引擎</button></h3>
<div class="card"><div class="kv-grid" id="dict-engine"></div></div>
<p class="note">已配对设备查词时只把要查的文字发过来，去屈折（「食べた」→「食べる」）在本机用本机的变形表做，所以变形表装在服务端即可，各设备无需自带。</p>
<div class="card"><h2 class="kit-title-medium">导入词典</h2>
<div class="form-grid"><div class="field is-wide">词典包<label class="dropzone"><input type="file" id="dict-file" accept=".zip,.fushidict,.mdx,.dsl" multiple><span class="msr-slot" data-fushi-icon="upload_file"></span><span class="dropzone-label">拖放文件到这里，或点击选择</span><span class="dropzone-files" id="dict-file-name"></span></label></div></div>
<div class="action-row"><button class="primary-button" id="btn-dict-up"><span class="msr-slot" data-fushi-icon="upload"></span>导入</button><span class="field-hint">支持 Fushi app 导出的 .fushidict 词典包，以及 Yomitan（.zip）、MDX、DSL 词典。同名词典视为更新，保留排序与设置。导入完立即生效，计入上传配额；也可以在 Fushi 的「词典 · 传输」推送过来。</span></div>
<p class="kit-supporting" id="dict-up-state"></p>
</div>
<h3 class="kit-section-title">词典</h3>
<div class="setting-list is-surface" id="dicts"><div class="skeleton"></div><div class="skeleton"></div></div>
<p class="note">顺序决定查词结果里各词典的排列。「默认启用」只对不携带配置词典选择的请求生效（浏览器扩展、旧版 app）；Fushi app 每次查词都带自己配置（Profile）的选择，会覆盖这里的默认值。</p>
<p class="note">词典语言同 app 里每本词典的语言设置：「自动」用词典包自己声明的词头语言。改动在设备下次刷新服务端词典目录时生效。</p>
<h3 class="kit-section-title">试查</h3>
<div class="card"><div class="action-row"><input type="text" id="dict-q" placeholder="食べた" style="flex:1 1 200px;height:40px"><button class="primary-button" id="btn-dict-q"><span class="msr-slot" data-fushi-icon="search"></span>查词</button></div></div>
<div id="dict-results"></div>
</section>

<section id="s-jobs">
<h3 class="kit-section-title">互联任务（ASR 等）</h3>
<div class="setting-list is-surface" id="jobs"><div class="skeleton"></div></div>
</section>

<section id="s-downloads">
<div class="card"><h2 class="kit-title-medium">添加磁力下载</h2><p class="kit-supporting" id="dl-cap"></p>
<div class="form-grid">
<label class="field is-wide">磁力链接<input type="text" id="dl-magnet" placeholder="magnet:?xt=urn:btih:…"></label>
<label class="field">标题<input type="text" id="dl-title"></label>
<label class="field">类型<select id="dl-kind"><option value="movie">movie</option><option value="tv">tv</option></select></label></div>
<div class="action-row"><button class="primary-button" id="btn-dl-add"><span class="msr-slot" data-fushi-icon="add"></span>添加</button></div></div>
<h3 class="kit-section-title">下载任务</h3>
<div class="setting-list is-surface" id="dls"><div class="skeleton"></div></div>
</section>

<section id="s-subscriptions">
<div class="card"><h2 class="kit-title-medium">新建订阅（按搜索词追新）</h2><p class="kit-supporting" id="sub-cap">从 Fushi 客户端的发现页订阅会带完整作品身份（原名/别名/交叉 ID）；这里只按搜索词匹配。</p>
<div class="form-grid">
<label class="field">标题（显示用）<input type="text" id="sub-title"></label>
<label class="field">搜索词<input type="text" id="sub-query" placeholder="搜索词，如 Frieren 1080p"></label>
<label class="field">源<select id="sub-provider"></select></label>
<label class="field">类型<select id="sub-kind"><option value="tv">tv（持续追新）</option><option value="movie">movie（一次）</option></select></label>
<label class="field">从第几集之后开始（可空）<input type="number" id="sub-after"></label></div>
<div class="action-row"><button class="primary-button" id="btn-sub-add"><span class="msr-slot" data-fushi-icon="add"></span>创建</button></div></div>
<h3 class="kit-section-title">订阅<span class="kit-spacer"></span><button class="plain-button" id="btn-sub-check-all"><span class="msr-slot" data-fushi-icon="refresh"></span>全部立即检查</button></h3>
<div class="setting-list is-surface" id="subs"><div class="skeleton"></div></div>
<h3 class="kit-section-title">资源索引器</h3>
<div class="card">
<p class="kit-supporting">订阅与代下载在这些来源里搜资源。与 Fushi app 的资源来源设置是同一份配置；改动对正在运行的服务立即生效（正在下载的种子不受影响）。</p>
<p class="kit-supporting" id="ri-none" style="display:none">还没有 BT 来源。添加一个 BT 站地址，或接入 Torznab 索引器</p>
<h2 class="kit-title-medium">BT 站</h2>
<div id="ri-bt"></div>
<div class="card-inset">
<div class="form-grid"><label class="field">站点地址<input type="text" id="bt-url" placeholder="https://example.com"></label><label class="field">名称（可选）<input type="text" id="bt-name"></label></div>
<div class="chip-set" id="bt-domains"></div>
<div class="action-row"><label class="switch-row"><span class="switch"><input type="checkbox" id="bt-enabled" checked><span></span></span><span>启用</span></label><label class="switch-row"><span class="switch"><input type="checkbox" id="bt-insecure"><span></span></span><span>允许明文 HTTP（仅受信任局域网）</span></label><span class="kit-spacer"></span><button class="primary-button" id="btn-bt-add"><span class="msr-slot" data-fushi-icon="add"></span>添加</button></div>
<div class="form-grid"><label class="field is-wide">解析规则（可选，JSON）<textarea id="bt-parser" rows="4"></textarea></label>
<label class="field is-wide">登录 Cookie（可选，仅带解析规则的站点）<input type="password" id="bt-cookie" autocomplete="off"></label></div>
<p class="kit-supporting">只填地址即可，添加时会自动检测站点。</p>
<p class="kit-supporting">自动检测认不出的站点，可以粘贴它的解析规则（JSON）；需要登录的站再填 Cookie。</p>
<details class="kit-supporting" id="bt-parser-help"><summary>怎么写解析规则</summary><p>解析规则用 CSS 选择器告诉服务端站点搜索页上的结果在哪："search" 填搜索页地址里域名之后的部分，搜索词换成 {query}；"rows" 选中包住整条结果的元素（通常是表格行 tr）；"fields" 里写这一行内部的选择器，"title" 必填，"magnet" / "torrent" / "infoHash" 至少一个，末尾加 @href 表示取属性而不是文字。</p><p>下载链接只在详情页时，让 "details" 指向详情页链接，再在 "detail" 段里写 "magnet" 或 "torrent"。不是 UTF-8 的站把 "encoding" 设为 windows-1251 或 latin1。规则里不含登录信息，需要登录的站另填 Cookie。用不到的部分直接删掉。</p><pre id="bt-parser-template">__FUSHI_BT_PARSER_TEMPLATE__</pre><div class="action-row"><button class="plain-button" id="btn-bt-template">填入模板</button></div></details></div>
<h2 class="kit-title-medium">Torznab（Jackett / Prowlarr）</h2>
<div id="ri-torznab"></div>
<div class="action-row"><button class="outlined-button" id="btn-ri-add"><span class="msr-slot" data-fushi-icon="add"></span>添加 indexer</button><span class="kit-spacer"></span><button class="plain-button" id="btn-ri-reset">放弃修改</button><button class="primary-button" id="btn-ri-save">保存</button></div>
<p class="kit-supporting" id="ri-state"></p></div>
</section>

<section id="s-models">
<h3 class="kit-section-title">ASR 模型</h3>
<div class="setting-list is-surface" id="asr-models"><div class="skeleton"></div></div>
<h3 class="kit-section-title">漫画 OCR 模型</h3>
<div class="setting-list is-surface" id="ocr-model"><div class="skeleton"></div></div>
</section>

<section id="s-anki">
<div class="card"><h2 class="kit-title-medium">Anki 落地</h2>
<p class="kit-supporting">打开后，其它设备（没装 Anki 的手机等）经互联同步过来的待发卡片由本机写进 Anki，再同步到 AnkiWeb 或你的自建 Anki 同步服务器。本机需要随包的 fushi-anki-sync。</p>
<div class="kv-grid" id="anki-status"></div>
<div class="action-row"><label class="switch-row"><span class="switch"><input type="checkbox" id="anki-landing"><span></span></span><span>接收其他设备的卡片</span></label><span class="kit-spacer"></span>
<button class="text-button" id="btn-anki-run">立即落地</button><button class="text-button" id="btn-anki-retry">重试失败的卡</button></div>
</div>
<h3 class="kit-section-title">Anki 同步账号</h3>
<div class="card" id="anki-account"></div>
<h3 class="kit-section-title">牌组 / 笔记类型 / 字段</h3>
<div class="card" id="anki-config"></div>
</section>

<section id="s-srs">
<div class="card"><h2 class="kit-title-medium">Fushi 复习</h2>
<p class="kit-supporting">本机替已配对设备保管 Fushi 复习的收藏：手机可以远程复习、制卡落到这里，Yomitan 可经下面的 AnkiConnect 往这里加卡。勾选要提供的配置文件（每门语言一份）；不勾选任何一份 = 关闭。同步位置开了端到端加密的配置文件暂不支持。</p>
<div class="kv-grid" id="srs-status"></div>
<div id="srs-migration"></div>
<div id="srs-retained"></div>
<div id="srs-profiles" style="margin-top:12px"></div>
</div>
<h3 class="kit-section-title">待确认的设备</h3>
<div class="card">
<p class="kit-supporting">本机开始提供某份配置文件之后才第一次同步过来的设备，它的普通修改照常生效，删除与彻底清除先扣在本机，确认是你自己的设备后再生效。拒绝 = 继续扣着，之后仍可改为信任。</p>
<div class="setting-list" id="srs-devices"></div></div>
<h3 class="kit-section-title">制卡落点</h3>
<div class="card" id="srs-mining"></div>
<h3 class="kit-section-title">RWKV 模型</h3>
<div class="card">
<p class="kit-supporting">算法是 RWKV 的牌组用哪个模型排程（整台设备一个设置，各份配置文件共用）。换了当场生效：需要时先下载新权重，没有这一档的快照时按全部复习历史重放一次，期间这些牌组不出复习卡。</p>
<div id="srs-rwkv"></div></div>
<h3 class="kit-section-title">AnkiConnect 兼容接口</h3>
<div class="card">
<p class="kit-supporting">默认关闭。只监听本机时可以不设 key；监听局域网地址必须设 key。每份配置文件可以有自己的 key（Yomitan 里一门语言一个 key），共用 key 落到默认那份。</p>
<div id="srs-ankiconnect"></div></div>
</section>

<section id="s-settings">
<h3 class="kit-section-title">外观</h3>
<div class="card appearance">
<p class="kit-supporting">只存在这台电脑的浏览器里，不影响服务端与其他设备。</p>
<div class="field">明暗<div class="segmented" role="radiogroup" id="ap-theme">
<label><input type="radio" name="ap-theme" value="auto"><span><span class="msr-slot" data-fushi-icon="contrast"></span>跟随系统</span></label>
<label><input type="radio" name="ap-theme" value="light"><span><span class="msr-slot" data-fushi-icon="light_mode"></span>浅色</span></label>
<label><input type="radio" name="ap-theme" value="dark"><span><span class="msr-slot" data-fushi-icon="dark_mode"></span>深色</span></label></div></div>
<div class="field">风格<div class="segmented" role="radiogroup" id="ap-style">
<label><input type="radio" name="ap-style" value="m3e"><span>Material 3 Expressive</span></label>
<label><input type="radio" name="ap-style" value="glass"><span>液态玻璃</span></label></div></div>
<div class="field">配色<div class="swatch-set" id="ap-palette" role="radiogroup"></div></div>
</div>
<div id="settings-form"><div class="setting-list is-surface"><div class="skeleton"></div><div class="skeleton"></div><div class="skeleton"></div></div></div>
<div class="save-bar" id="savebar" hidden><span class="count" id="dirty-count"></span><span class="field-hint">端口 / TLS / 绑定 / qBittorrent / torrent / ffmpeg / onnxruntime 路径改后需重启 serve。</span><button class="plain-button" id="btn-settings-discard">放弃</button><button class="primary-button" id="btn-settings-save">保存</button></div>
<h3 class="kit-section-title">远程访问</h3>
<div class="card">
<div class="form-grid">
<label class="field is-wide">公网地址（每行一个，http:// 或 https://；反代 / DDNS / 端口映射后的地址，已配对设备会自动学到）<textarea id="rr-public" rows="3" placeholder="https://nas.example.com:38765"></textarea></label>
<div class="field is-wide"><label class="switch-row"><span class="switch"><input type="checkbox" id="rr-p2p"><span></span></span><span>允许 P2P 隧道连接</span></label><span class="field-hint">没有公网 IP 时用（iroh）；开启后会连接中继与发现服务，对端 / 中继能看到本机 IP。</span></div>
<label class="field is-wide">自建中继（每行一个，空 = iroh 公共中继）<textarea id="rr-relays" rows="2" placeholder="https://relay.example.com"></textarea></label></div>
<p class="kit-supporting" id="rr-state"></p>
<div class="action-row"><button class="primary-button" id="btn-rr-save">保存</button><span class="field-hint">这三项保存即生效，无需重启。</span></div>
</div>
<h3 class="kit-section-title">在线字幕来源</h3>
<div class="card">
<p class="kit-supporting">代下载配字幕与补字幕用。与 app 同一份设置；key 不回显，留空不改。设了 FUSHI_* 环境变量时，环境变量里的 key 优先。</p>
<div id="subs-form"></div>
<div class="action-row"><button class="primary-button" id="btn-subs-save">保存</button><span class="field-hint">保存即生效：下一个下载任务的字幕阶段就用新设置。</span></div>
</div>
</section>

<section id="s-ai">
<div class="card"><h2 class="kit-title-medium">AI 助手会话</h2>
<p class="kit-supporting">已配对设备经互联让本服务端跑的 AI 助手会话（保留 30 天）。这里只读；撤销与续接在发起的那台设备上做。</p></div>
<div class="setting-list is-surface" id="ai-sessions"><div class="skeleton"></div></div>
<div class="card" id="ai-detail" style="display:none"><h2 class="kit-title-medium" id="ai-detail-title"></h2><p class="kit-supporting" id="ai-detail-meta"></p><div id="ai-entries"></div></div>
</section>

<section id="s-logs">
<div class="card"><div class="card-head"><div class="card-head-copy"><h2 class="kit-title-medium">最近日志</h2></div><label class="switch-row"><span>自动刷新</span><span class="switch"><input type="checkbox" id="log-auto" checked><span></span></span></label><button class="text-button" id="btn-log-refresh"><span class="msr-slot" data-fushi-icon="refresh"></span>刷新</button></div>
<div class="segmented" role="radiogroup"><label><input type="radio" name="log-lv" value="all" checked><span>全部</span></label><label><input type="radio" name="log-lv" value="problems"><span id="log-lv-problems">仅错误</span></label></div>
<pre id="logs"></pre></div>
</section>

</main>
</div>
<dialog class="kit-dialog" id="dlg"><div class="kit-dialog-icon"><span class="msr-slot" data-fushi-icon="help" data-fushi-icon-size="24"></span></div><p class="kit-dialog-body" id="dlg-msg"></p>
<div class="kit-dialog-actions"><button class="plain-button" id="dlg-no" type="button">取消</button><button class="primary-button" id="dlg-ok" type="button">确定</button></div></dialog>
<div class="toast is-floating" id="toast" role="status" aria-live="polite"></div>
__FUSHI_KIT_BODY__
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
// 页面里的语义名 → Material Symbols（共享库 icons.js）。动态插入的节点由下面的 MutationObserver 统一填图标、换下拉。
const ICON = {status:'dashboard', pairing:'link', libraries:'folder', upload:'upload', jobs:'task_alt', downloads:'download', subscriptions:'rss_feed', models:'memory', ai:'auto_awesome', anki:'layers', srs:'school', settings:'settings', logs:'receipt_long', refresh:'refresh', warn:'warning', help:'help', device:'devices', video:'movie', book:'book', manga:'auto_stories', audio:'headphones', empty:'inbox', chevron:'chevron_right', dictionaries:'dictionary', edit:'edit', up:'arrow_upward', down:'arrow_downward', search:'search', more:'more_vert', add:'add'};
const icon = (name, cls) => `<span class="msr-slot${cls?' '+cls:''}" data-fushi-icon="${ICON[name]||name}"></span>`;
function enhance(root){ try{ window.fushiIcons && fushiIcons.hydrate(root); }catch(e){ console.warn('icons', e); } try{ window.fushiGlassSelect && fushiGlassSelect.enhanceAll(root); }catch(e){ console.warn('select', e); } }
// 以变动的父节点为根：hydrate 只查后代，直接插进来的图标位本身也要算上。
new MutationObserver((records)=>{ const roots=new Set(); for(const r of records) if(r.addedNodes.length && r.target.nodeType===1) roots.add(r.target); roots.forEach(enhance); }).observe(document.body, {childList:true, subtree:true});
enhance(document);
// snackbar：err=true 用错误色。
let toastTimer; function toast(msg, err){ const t=$('#toast'); t.textContent=msg; t.classList.toggle('is-error', !!err); t.classList.add('is-on'); clearTimeout(toastTimer); toastTimer=setTimeout(()=>t.classList.remove('is-on'), err?4200:2600); }
// 确认对话框（替代 window.confirm）：返回 Promise<bool>；danger=true 时确认键用错误色。
function ask(msg, danger){
  const d=$('#dlg'); $('#dlg-msg').textContent=msg; d.classList.toggle('is-danger', !!danger);
  d.querySelector('.kit-dialog-icon').innerHTML = icon(danger?'warn':'help');
  $('#dlg-ok').className = danger ? 'primary-button danger-button' : 'primary-button';
  return new Promise((resolve)=>{
    const done=(v)=>{ d.onclose=null; $('#dlg-ok').onclick=null; $('#dlg-no').onclick=null; if(d.open) d.close(); resolve(v); };
    $('#dlg-ok').onclick=()=>done(true); $('#dlg-no').onclick=()=>done(false); d.onclose=()=>done(false);
    d.showModal(); $('#dlg-no').focus();
  });
}
const REASON_TEXT = {not_running:T('互联服务没在运行'), no_reachable_address:T('没有能放进链接的地址：配对链接只收 HTTPS 地址或 P2P 隧道。请开启 TLS、在「设置 › 远程访问」填写 HTTPS 公网地址，或开启 P2P 隧道'), disabled:T('订阅已停用，请先启用'), unrecognized:T('无法识别这个站点：可以粘贴它的解析规则后再添加'), timedOut:T('站点响应超时'), ruleRequestFailed:T('按解析规则打不开站点的搜索页：请检查地址，或登录 Cookie 是否已过期'), ruleMatchedNothing:T('按解析规则在搜索页上没解析出任何结果：请检查规则里的选择器，或站点是否需要登录 Cookie'), invalidUrl:T('地址无效'), insecureHttp:T('这是明文 HTTP 地址：请改用 HTTPS，或勾选「允许明文 HTTP」')};
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
function guard(fn){ return async (...a)=>{ try{ await fn(...a);}catch(e){ toast(T('失败: {0}', e.message), true);} }; }
const TONE = {ok:'success', err:'error', warn:'warn', info:'info'};
const tag = (cls, text) => `<span class="status-chip${String(text).length>24?' is-wrap':''}"${TONE[cls]?` data-tone="${TONE[cls]}"`:''}>${esc(text)}</span>`;
const empty = (text, ic) => `<div class="empty-state">${icon(ic||'empty')}<span>${esc(text)}</span></div>`;
const kvHtml = (kv) => kv.map(([k,v,html])=>`<div class="kv"><b>${esc(k)}</b><span>${html?v:esc(v)}</span></div>`).join('');
const iconBtn = (ic, label, attrs, danger) => `<button class="icon-button${danger?' danger-button':''}" ${attrs} title="${esc(label)}" aria-label="${esc(label)}">${icon(ic)}</button>`;
const progress = (frac) => `<div class="progress"><i style="width:${Math.max(0,Math.min(100,frac*100)).toFixed(1)}%"></i></div>`;

// ── 外观（明暗 / 配色 / 风格）：共享库 theme.js 决议与套用，选择存本机浏览器（独立网页模式）──
const TH = window.fushiTheme;
const THEME_ORDER = ['auto','light','dark'];
const THEME_TITLE = {auto:T('主题：跟随系统'), light:T('主题：浅色'), dark:T('主题：深色')};
const THEME_ICON = {auto:'contrast', light:'light_mode', dark:'dark_mode'};
// 预设名（与 app themePresets 同序）；'app' = Fushi 默认配色（不改写 token）。
const PRESET_NAME = {'app':T('Fushi 默认'), 'm3-baseline':T('紫'), 'm3-indigo':T('靛蓝'), 'm3-blue':T('蓝'), 'm3-teal':T('青'), 'm3-green':T('绿'), 'm3-yellow':T('黄'), 'm3-orange':T('橙'), 'm3-red':T('红'), 'm3-pink':T('粉'), 'm3-neutral':T('中性')};
const savePref = (changes) => { if (TH) TH.save(changes); };
// 旧版 WebUI 的主题键（fushi-admin-theme）迁到共享库的键上，只迁一次。
try{ const old=localStorage.getItem('fushi-admin-theme'); if(old){ localStorage.removeItem('fushi-admin-theme'); if(old==='light'||old==='dark') savePref({extensionTheme:old}); } }catch(e){}
function syncAppearance(){
  const pref = (TH && TH.preference) || 'auto';
  const btn = $('#btn-theme');
  btn.innerHTML = icon(THEME_ICON[pref]||'contrast'); btn.title = THEME_TITLE[pref]||''; btn.setAttribute('aria-label', btn.title);
  const pick = (name, v) => { const el = document.querySelector(`input[name="${name}"][value="${v}"]`); if (el) el.checked = true; };
  pick('ap-theme', pref); pick('ap-style', (TH && TH.style) || 'm3e'); pick('ap-palette', (TH && TH.palette) || 'app');
}
const presets = (window.fushiThemePalette && fushiThemePalette.PRESETS) || [];
$('#ap-palette').innerHTML = [{key:'app', seed:'#1f4959'}, ...presets].map(p=>`<label class="color-swatch" style="--swatch:${esc(p.seed)}"><input type="radio" name="ap-palette" value="${esc(p.key)}"><span></span><span>${esc(PRESET_NAME[p.key]||p.key)}</span></label>`).join('');
document.querySelectorAll('input[name="ap-theme"]').forEach(x=>x.onchange=()=>savePref({extensionTheme:x.value}));
document.querySelectorAll('input[name="ap-style"]').forEach(x=>x.onchange=()=>savePref({extensionStyle:x.value}));
document.querySelectorAll('input[name="ap-palette"]').forEach(x=>x.onchange=()=>savePref({extensionPalette:x.value}));
$('#btn-theme').onclick = ()=>{ const t=(TH && TH.preference) || 'auto'; savePref({extensionTheme:THEME_ORDER[(THEME_ORDER.indexOf(t)+1)%THEME_ORDER.length]}); };
if (TH && TH.onChange) TH.onChange(syncAppearance);
syncAppearance();
// 窄屏把 rail 换成模态抽屉。
// 侧边栏三种形态：窄屏模态抽屉；宽屏按用户选择展开 / 紧凑（没选过时 ≥1100 px 展开），选择存本机浏览器。
const narrow = window.matchMedia('(max-width: 640px)');
const wide = window.matchMedia('(min-width: 1100px)');
const RAIL_KEY = 'fushi-admin-rail';
const railPref = () => { try{ const v=localStorage.getItem(RAIL_KEY); return v==='expanded'||v==='compact' ? v : null; }catch(e){ return null; } };
function syncRail(){
  const rail=$('#rail'), drawer=narrow.matches;
  const expanded = !drawer && (railPref() ? railPref()==='expanded' : wide.matches);
  rail.classList.toggle('is-drawer', drawer);
  rail.classList.toggle('is-expanded', expanded);
  if (!drawer) { rail.classList.remove('is-open'); $('#scrim-nav').classList.remove('is-open'); }
  const btn=$('#btn-rail'); btn.title = expanded ? T('收起侧边栏') : T('展开侧边栏'); btn.setAttribute('aria-label', btn.title); btn.setAttribute('aria-expanded', String(expanded));
  // 紧凑形态下文字只进 tooltip。
  navButtons.forEach(b=>{ const l=b.querySelector('.nav-label').textContent; if (expanded||drawer) b.removeAttribute('title'); else b.title=l; });
}
$('#btn-rail').onclick = ()=>{ const expanded=$('#rail').classList.contains('is-expanded'); try{ localStorage.setItem(RAIL_KEY, expanded?'compact':'expanded'); }catch(e){} syncRail(); };
narrow.addEventListener('change', syncRail); wide.addEventListener('change', syncRail);
// 拖放区：显示选中的文件名（多个时前面带个数）。input 透明铺满整个拖放区，拖进来的文件由浏览器
// 直接落到 input 上；带 multiple 的 input 一次可收多个。
for (const [inp, out] of [['#up-files','#up-files-names'],['#dict-file','#dict-file-name']]){
  const el=$(inp), zone=el.closest('.dropzone');
  el.addEventListener('change', ()=>{ const names=Array.from(el.files).map(f=>f.name); $(out).textContent = names.length>1 ? T('{0} 个文件：{1}', names.length, names.join(T('、'))) : names.join(''); });
  zone.addEventListener('dragover', ()=>zone.classList.add('is-over')); zone.addEventListener('dragleave', ()=>zone.classList.remove('is-over')); zone.addEventListener('drop', ()=>zone.classList.remove('is-over'));
}

// ── 导航 ──
// 选中项背后的 M3E 多边形：每项轮流取一种（同 app 的 kNavRailFallbackShapes），用极坐标波形画。
function navShape(n, a, rot){ let d=''; for(let k=0;k<=120;k++){ const t=k/120*2*Math.PI; const r=20*(1+a*Math.cos(n*(t+rot))); d+=(k?'L':'M')+(23+r*Math.cos(t)).toFixed(2)+' '+(23+r*Math.sin(t)).toFixed(2); } return d+'Z'; }
const NAV_SHAPES = [[9,.07,0],[4,.16,0],[10,.05,0],[8,.1,0],[4,.08,Math.PI/4],[8,.05,0],[6,.09,0],[5,.08,0],[6,.06,0],[8,.14,0]];
const navButtons = Array.from(document.querySelectorAll('.nav-item[data-s]'));
navButtons.forEach((b,i)=>{ const [n,a,r]=NAV_SHAPES[i%NAV_SHAPES.length]; b.querySelector('.nav-indicator').insertAdjacentHTML('afterbegin', `<svg class="nav-shape" viewBox="0 0 46 46" aria-hidden="true"><path d="${navShape(n,a,r)}"/></svg>`); });
let current='status';
function closeNav(){ $('#rail').classList.remove('is-open'); $('#scrim-nav').classList.remove('is-open'); }
function go(s, push){
  const b = navButtons.find(x=>x.dataset.s===s); if(!b) return;
  current=s;
  if (s==='dictionaries') dictsLoaded=false;
  navButtons.forEach(x=>{ if(x===b) x.setAttribute('aria-current','page'); else x.removeAttribute('aria-current'); });
  document.querySelectorAll('main section').forEach(sec=>sec.classList.toggle('on', sec.id==='s-'+s));
  $('#page-title').textContent = b.querySelector('.nav-label').textContent;
  $('#main').scrollTop = 0;
  if (push) { try{ history.replaceState(null, '', '#'+s); }catch(e){} }
  closeNav(); refresh();
}
navButtons.forEach(b=>b.onclick=()=>go(b.dataset.s, true));
syncRail();
$('#btn-menu').onclick = ()=>{ $('#rail').classList.add('is-open'); $('#scrim-nav').classList.add('is-open'); $('#rail').scrollTop=0; const on=$('.nav-item[aria-current="page"]'); if(on) on.focus({preventScroll:true}); };
$('#scrim-nav').onclick = closeNav;
document.addEventListener('keydown', (e)=>{ if(e.key==='Escape' && $('#rail').classList.contains('is-open')) closeNav(); });

// ── 状态 ──
function scrapeSummary(sc){
  if(!sc) return '—';
  const tail = sc.tmdbAvailable ? '' : T(' · 未配置 TMDB key');
  if(sc.busy) return T('进行中 {0}/{1}', sc.current, sc.total) + (sc.work ? ' ' + sc.work : '') + tail;
  const r = sc.lastReport;
  const last = r ? T(' · 上次 {0}/{1} 部成功', r.succeeded, r.totalWorks) + (r.pendingConfirmations ? T('，{0} 部待指定', r.pendingConfirmations) : '') : '';
  return (sc.enabled ? T('空闲') : T('自动补刮已关闭')) + last + tail;
}
// 运行状态里要人处理的项提到顶上，点一下去能修它的那一页。
const P2P_BAD = new Set(['unavailable','start_failed','loopback_bind']);
function renderAttention(s){
  const items = [];
  if (s.ocr && !s.ocr.ready) items.push(['models', T('漫画 OCR 模型缺失'), T('在「模型」页下载后才能识别漫画文字。')]);
  if (s.downloads && !s.downloads.supported) items.push(['settings', T('下载后端未配置'), T('下载与订阅不可用；在「设置 → 下载」里配置后重启。')]);
  if (s.p2p && !s.p2p.active && P2P_BAD.has(s.p2p.reason)) items.push(['settings', T('P2P 隧道'), p2pSummary(s.p2p)]);
  const sc = s.scrape, r = sc && sc.lastReport;
  if (r && r.pendingConfirmations) items.push(['', T('{0} 部作品待指定刮削结果', r.pendingConfirmations), T('自动刮削拿不准，需要手动指定。')]);
  if (sc && sc.enabled && !sc.tmdbAvailable) items.push(['settings', T('未配置 TMDB key'), T('自动补刮拿不到 TMDB 资料；在「设置 → 媒体与刮削」填写。')]);
  $('#attn-h').hidden = !items.length;
  $('#status-attn').innerHTML = items.map(([to, t, sub])=>`<div class="setting-row${to?' is-clickable':''}"${to?` data-go="${to}" tabindex="0" role="button"`:''}><div class="list-lead" data-tone="warn">${icon('warn')}</div><div class="setting-copy"><strong>${esc(t)}</strong><small>${esc(sub)}</small></div>${to?`${icon('chevron','chev')}`:''}</div>`).join('');
  $('#status-attn').querySelectorAll('[data-go]').forEach(el=>{ el.onclick=()=>go(el.dataset.go, true); el.onkeydown=(e)=>{ if(e.key==='Enter'||e.key===' '){ e.preventDefault(); go(el.dataset.go, true); } }; });
}
async function loadStatus(){
  const s = await api('status');
  $('#devname').textContent = s.deviceName + ' · ' + s.listen + (s.tls?' · https':' · http');
  const quota = s.uploadQuotaBytes ? s.uploadUsedBytes / s.uploadQuotaBytes : 0;
  const tile = (cls, ic, k, v, sub, extra) => `<div class="stat-tile${cls}"><span class="stat-label">${icon(ic)}${esc(k)}</span><span class="stat-value">${esc(v)}</span><span class="stat-sub">${esc(sub)}</span>${extra||''}</div>`;
  $('#status-tiles').innerHTML =
    tile(' is-primary', 'video', T('视频'), s.videos, '') +
    tile('', 'book', T('书籍'), s.books, T('含漫画与有声书')) +
    tile('', 'pairing', T('已配对'), s.peers, '') +
    tile('', 'upload', T('上传配额'), Math.round(quota*100)+'%', fmtBytes(s.uploadUsedBytes)+' / '+fmtBytes(s.uploadQuotaBytes), progress(quota));
  const okTag = (ok, a, b) => ok ? tag('ok', a) : tag('', b);
  $('#status-grid').innerHTML = kvHtml([
    [T('监听'), s.listen + (s.tls?' (https)':' (http)')], [T('设备 id'), s.deviceId], [T('TLS 指纹'), s.fingerprint||'—'],
    [T('运行时长'), Math.floor(s.uptimeSeconds/3600)+'h '+Math.floor(s.uptimeSeconds%3600/60)+'m'], [T('数据目录'), s.dataDir],
    [T('OCR 模型'), s.ocr ? okTag(s.ocr.ready, T('就绪'), T('缺失')) : '—', true],
    [T('下载后端'), s.downloads ? okTag(s.downloads.supported, s.downloads.backend||'ok', T('未配置')) : '—', true],
    [T('订阅'), s.subscriptionCount==null ? '—' : s.subscriptionCount],
    [T('P2P 隧道'), p2pSummary(s.p2p)],
    [T('刮削'), scrapeSummary(s.scrape)],
  ]);
  renderAttention(s);
  const notes = (s.lastScanNotes && s.lastScanNotes.length) ? ' — ' + s.lastScanNotes.join('; ') : '';
  $('#scan-state').textContent = T('{0} 个库根', s.libraries) + ' · ' + (s.scanning ? T('扫描中…') : (s.lastScan ? T('上次 {0}: {1}', fmtTime(s.lastScanAt), s.lastScan + notes) : T('尚未扫描')));
  $('#btn-scan').disabled = !!s.scanning;
  $('#scan-bar').hidden = !s.scanning;
}
$('#btn-scan').onclick = guard(async()=>{ await post('scan'); toast(T('已开始扫描')); loadStatus(); });

// ── 配对 ──
function setPairBadge(pending){ $('#pair-badge').hidden = !pending; }
// BUG-4391：管理员签发一次性配对链接（票据配对不走 PIN 预算）。再签一张即作废上一张。
$('#btn-pair-link').onclick = guard(async()=>{
  const r = await post('pairing/link');
  const out = $('#pair-link-out');
  out.innerHTML = `<div class="action-row"><input id="pair-link-uri" class="mono" readonly value="${esc(r.uri)}"><button class="text-button" id="btn-pair-link-copy">${esc(T('复制'))}</button></div><p class="kit-supporting">${esc(T('{0} 分钟内有效，只能用一次。在 Fushi 的互联设置里点「粘贴配对链接」使用。', Math.max(1, Math.round(r.expiresInSeconds/60))))}</p>`;
  out.hidden = false;
  $('#btn-pair-link-copy').onclick = guard(async()=>{
    const input = $('#pair-link-uri');
    // 明文 http 访问 WebUI 时不是安全上下文，没有 navigator.clipboard，退回选中复制。
    if (navigator.clipboard && window.isSecureContext) await navigator.clipboard.writeText(input.value);
    else { input.select(); if (!document.execCommand('copy')) throw new Error(T('浏览器不让复制，请手动选中')); }
    toast(T('已复制'));
  });
});
async function loadPairing(){
  const p = await api('pairing');
  setPairBadge(p.pending);
  const lockClass = {lan:T('局域网'), p2p:T('P2P 隧道'), public:T('公网或反向代理')};
  const locks = Object.entries(p.lockout||{}).filter(([,v])=>v);
  $('#pairing-lockout').innerHTML = locks.length
    ? `<div class="card"><div class="card-head"><div class="card-head-copy">${locks.map(([k,v])=>`<p class="kit-supporting">${tag('warn', T('来自{0}的配对因多次 PIN 错误暂停至 {1}', lockClass[k]||k, fmtTime(v)))}</p>`).join('')}</div><button class="primary-button" id="btn-pair-unlock">${esc(T('解除'))}</button></div></div>`
    : '';
  if (locks.length) $('#btn-pair-unlock').onclick = guard(async()=>{ await post('pairing/unlock'); toast(T('已解除')); loadPairing(); });
  // 待输入 PIN 按会话各一条（并发配对互不覆盖）；旧后端只有 pending 时退回单条。
  const pendings = p.pendingList || (p.pending ? [p.pending] : []);
  $('#pairing-pending').innerHTML = pendings.length
    ? pendings.slice().reverse().map(x=>`<div class="card is-tertiary pin-card"><div><b><span class="pulse"></span>${esc(T('{0} ({1}) 请求配对，请在该设备输入：', x.deviceName||T('未知设备'), x.remoteAddress||'?'))}</b><p class="kit-supporting">${fmtTime(x.createdAt)}</p></div><div class="pin">${esc(x.pin)}</div></div>`).join('')
    : `<div class="setting-list is-surface">${empty(T('没有待处理的配对。在 Fushi 里添加互联设备并输入本机地址，PIN 会显示在这里。'), 'pairing')}</div>`;
  $('#peers').innerHTML = p.peers.map(x=>`<div class="setting-row"><div class="list-lead">${icon('device')}</div><div class="setting-copy"><strong>${esc(x.deviceName||'—')}${x.ownerDevice?tag('info', T('我的设备')):''}</strong><small>${esc([x.lastSeenIp, fmtTime(x.pairedAtMs)].filter(Boolean).join(' · '))}</small><small class="mono">${esc(x.peerId)}</small></div><div class="setting-trail">${x.deviceKeyVerified ? `<button class="${x.ownerDevice?'outlined-button':'text-button'}" data-owner="${esc(x.peerId)}" data-on="${x.ownerDevice?'1':'0'}">${esc(x.ownerDevice?T('取消我的设备'):T('标为我的设备'))}</button>` : tag('', T('未证明设备钥匙'))}<button class="plain-button danger-button" data-revoke="${esc(x.peerId)}">${esc(T('吊销'))}</button></div></div>`).join('') || empty(T('还没有已配对设备'), 'device');
  const lb = p.leaderboardLink || {};
  $('#lb-link-state').innerHTML = lb.enabled ? (lb.tls ? tag('ok', T('自动登录已开')) : tag('warn', T('自动登录已开，但 TLS 关着——端点在明文下拒绝访问'))) : tag('', T('自动登录已关'));
  $('#peers').querySelectorAll('[data-revoke]').forEach(b=>b.onclick=guard(async()=>{ if(!await ask(T('吊销该设备？'), true)) return; await del('pairing/peers/'+encodeURIComponent(b.dataset.revoke)); toast(T('已吊销')); loadPairing(); }));
  $('#peers').querySelectorAll('[data-owner]').forEach(b=>b.onclick=guard(async()=>{ const on = b.dataset.on!=='1'; if(on && !await ask(T('标为「我的设备」？它将能跟随本机的 Fushi 排行榜账户自动登录（代绑出去的设备钥匙在账户里是满权限）。只标你自己的设备。'))) return; await put('pairing/peers/'+encodeURIComponent(b.dataset.owner)+'/owner',{owner:on}); toast(on?T('已标为我的设备'):T('已取消')); loadPairing(); }));
  await loadProfiles();
}
async function loadProfiles(){
  const r = await api('profiles');
  $('#prof-state').innerHTML = r.enabled ? (r.tls ? tag('ok', T('已允许')) : tag('warn', T('已允许，但 TLS 关着——端点在明文下拒绝访问'))) : tag('', T('未允许（默认）'));
  $('#btn-prof-toggle').textContent = r.enabled ? T('禁止设备推送 / 拉取') : T('允许设备推送 / 拉取');
  $('#btn-prof-toggle').dataset.enabled = r.enabled ? '1' : '0';
  $('#profiles').innerHTML = (r.profiles||[]).map(x=>`<div class="setting-row"><div class="setting-copy"><strong>${esc(x.name)}${x.shared?tag('ok', T('分发中')):''}</strong><small>${esc(T('{0} 项设置', x.settingCount))} · ${esc(fmtTime(x.receivedAt))}</small></div><div class="setting-trail">${x.shared?'':`<button class="text-button" data-prof="share" data-id="${x.id}">${esc(T('设为分发'))}</button>`}${iconBtn('delete', T('删除'), `data-prof="delete" data-id="${x.id}"`, true)}</div></div>`).join('') || empty(T('还没有设备推送过配置'));
  $('#profiles').querySelectorAll('[data-prof]').forEach(b=>b.onclick=guard(async()=>{ const id=b.dataset.id;
    if(b.dataset.prof==='delete'){ if(!await ask(T('删除这份寄存的配置？'), true)) return; await del('profiles/'+id); toast(T('已删除')); }
    else { await post('profiles/'+id+'/share'); }
    loadProfiles(); }));
}
$('#btn-prof-toggle').onclick = guard(async()=>{ const on = $('#btn-prof-toggle').dataset.enabled!=='1'; if(on && !await ask(T('允许已配对设备把配置推到本机寄存、并从本机拉走？'))) return; await put('settings',{profileTransfer:on}); settingsCache=null; toast(on?T('已允许'):T('已禁止')); loadProfiles(); });

// ── 库 ──
const KIND_ICON = {video:'video', book:'book', manga:'manga', audiobook:'audio'};
const KIND_LABEL = {video:T('视频'), book:T('书'), manga:T('漫画'), audiobook:T('有声书')};
const KIND_HINT = {video:'mkv / mp4 / avi / …', book:'EPUB', manga:'mokuro / cbz / cbr / cb7 / zip / rar / ' + T('页图目录'), audiobook:T('音频目录，可带 epub / 字幕')};
const folderName = (p) => { const parts = String(p).split(/[\\/]+/).filter(Boolean); return parts.length ? parts[parts.length-1] : p; };
const libKind = () => (document.querySelector('input[name="lib-kind"]:checked')||{}).value || 'video';
const showKindHint = () => { $('#lib-kind-hint').textContent = KIND_HINT[libKind()]; };
document.querySelectorAll('input[name="lib-kind"]').forEach(x=>x.onchange=showKindHint);
showKindHint();
function closeMenus(){ document.querySelectorAll('.kit-menu').forEach(m=>{ if(!m.hidden){ m.hidden=true; const b=m.previousElementSibling; if(b) b.setAttribute('aria-expanded','false'); } }); }
document.addEventListener('click', closeMenus);
function bindMoreMenus(root){ root.querySelectorAll('[data-more]').forEach(b=>b.onclick=(e)=>{ e.stopPropagation(); const m=b.nextElementSibling; const open=m.hidden; closeMenus(); if(open){ m.hidden=false; b.setAttribute('aria-expanded','true'); m.querySelector('button').focus(); } }); }
document.addEventListener('keydown', (e)=>{ if(e.key==='Escape'){ const m=$('.kit-menu:not([hidden])'); if(m){ closeMenus(); m.previousElementSibling.focus(); } } });
async function loadLibraries(){
  const r = await api('libraries');
  // 轮询重绘会关掉开着的菜单：菜单开着时跳过这一轮。
  if ($('#libs .kit-menu:not([hidden])')) return;
  $('#libs').innerHTML = r.libraries.map(l=>`<div class="setting-row"><div class="list-lead">${icon(KIND_ICON[l.kind]||'libraries')}</div><div class="setting-copy"><strong>${esc(folderName(l.path))}${l.exists?tag('ok', T('存在')):tag('err', T('目录不存在'))}${l.enabled?'':tag('', T('禁用'))}</strong><small>${esc([KIND_LABEL[l.kind]||l.kind, l.id===folderName(l.path)?'':l.id].filter(Boolean).join(' · '))}</small><small>${esc(l.path)}</small></div><div class="setting-trail more"><button class="icon-button" data-more title="${esc(T('更多'))}" aria-label="${esc(T('更多'))}" aria-haspopup="menu" aria-expanded="false">${icon('more')}</button><div class="kit-menu" role="menu" hidden><button role="menuitem" class="kit-menu-item" data-rm="${esc(l.id)}">${esc(T('移除'))}</button><button role="menuitem" class="kit-menu-item danger-button" data-purge="${esc(l.id)}">${esc(T('移除并清理'))}</button></div></div></div>`).join('') || empty(T('还没有扫描根'), 'libraries');
  bindMoreMenus($('#libs'));
  $('#libs').querySelectorAll('[data-rm]').forEach(b=>b.onclick=guard(async()=>{ if(!await ask(T('从配置移除该库根？（不删文件、不删已入库条目）'), true)) return; await del('libraries/'+encodeURIComponent(b.dataset.rm)); toast(T('已移除')); loadLibraries(); }));
  $('#libs').querySelectorAll('[data-purge]').forEach(b=>b.onclick=guard(async()=>{ if(!await ask(T('移除该库根，并清理「文件已消失」的条目？\n只回收条目与其刮削资料 / 正文副本，不删任何源文件。\n注意：目录若只是没挂载，其下条目也会被当成已删除。'), true)) return; const r=await del('libraries/'+encodeURIComponent(b.dataset.purge)+'?purge=true'); const p=r&&r.purge; toast(p?(p.skipped?T('未清理：{0}', p.reason||T('被护栏拦下')):T('已清理 {0} 条', p.deleted)):T('已移除')); loadLibraries(); loadStatus(); }));
  const sel = $('#up-lib'); const cur = sel.value;
  sel.innerHTML = r.libraries.map(l=>`<option value="${esc(l.id)}">${esc(l.id)} — ${esc(l.path)}</option>`).join('');
  if (cur) sel.value = cur;
  loadUploadFolders();
}
// 上传子目录框的建议：所选库根下已有的子目录（取不到就不给建议，照样可手填）。
async function loadUploadFolders(){
  const lib = $('#up-lib').value, list = $('#up-sub-list');
  if (!lib) { list.innerHTML = ''; return; }
  try {
    const r = await api('upload/folders?library='+encodeURIComponent(lib));
    if ($('#up-lib').value !== lib) return;
    list.innerHTML = (r.folders||[]).map(f=>`<option value="${esc(f)}">`).join('');
  } catch (e) { list.innerHTML = ''; console.warn('upload folders', e); }
}
$('#up-lib').addEventListener('change', loadUploadFolders);
$('#btn-lib-add').onclick = guard(async()=>{ await post('libraries',{path:$('#lib-path').value, kind:libKind(), id:$('#lib-id').value}); $('#lib-path').value=''; $('#lib-id').value=''; toast(T('已添加')); loadLibraries(); });

// ── 上传 ──
const CHUNK = 8*1024*1024;
async function uploadOne(file, lib, sub, row){
  const rel = (sub ? sub.replace(/^\/+|\/+$/g,'')+'/' : '') + file.name;
  const q = `upload?library=${encodeURIComponent(lib)}&path=${encodeURIComponent(rel)}`;
  const st = await api(q);
  let off = st.received || 0;
  if (off >= file.size && file.size>0){ row.querySelector('.st').textContent=T('已存在'); row.querySelector('.progress > i').style.width='100%'; return; }
  while (off < file.size){
    const end = Math.min(off+CHUNK, file.size);
    const r = await fetch('/api/admin/'+q, {method:'PUT', headers:{'Content-Range':`bytes ${off}-${end-1}/${file.size}`,'Content-Type':'application/octet-stream'}, body:file.slice(off,end)});
    const j = await r.json().catch(()=>({}));
    if (!r.ok) throw new Error(j.error||('HTTP '+r.status));
    off = j.received;
    row.querySelector('.progress > i').style.width = (off/file.size*100).toFixed(1)+'%';
    row.querySelector('.st').textContent = fmtBytes(off)+' / '+fmtBytes(file.size);
    if (j.complete) break;
  }
  if (file.size===0){ await fetch('/api/admin/'+q,{method:'PUT',headers:{'Content-Range':'bytes 0-0/0'},body:new Blob([])}); }
  row.querySelector('.st').textContent=T('完成');
  row.querySelector('.progress > i').style.width='100%';
}
$('#btn-up').onclick = guard(async()=>{
  const files = Array.from($('#up-files').files); const lib=$('#up-lib').value; const sub=$('#up-sub').value.trim();
  if(!lib) throw new Error(T('先添加一个库根')); if(!files.length) throw new Error(T('没选文件'));
  $('#btn-up').disabled=true;
  try{ for(const f of files){ const row=document.createElement('div'); row.className='setting-row'; row.innerHTML=`<div class="list-lead">${icon('upload')}</div><div class="setting-copy"><strong>${esc(f.name)}</strong><small class="st">${esc(T('等待'))}</small>${progress(0)}</div>`; $('#up-list').prepend(row); try{ await uploadOne(f,lib,sub,row);}catch(e){ const st=row.querySelector('.st'); st.className='is-error st'; st.textContent=T('失败: {0}', e.message); } } toast(T('上传结束，记得扫描库')); }
  finally{ $('#btn-up').disabled=false; loadStatus(); loadUploadFolders(); }
});

// ── 任务 ──
const stCls = (s) => (s==='done'||s==='completed')?'ok':((s==='error'||s==='failed')?'err':((s==='running'||s==='uploading'||s==='active')?'warn':''));
const stTag = (s) => tag(stCls(s), s);
async function loadJobs(){
  const r = await api('jobs');
  $('#jobs').innerHTML = r.jobs.map(j=>`<div class="setting-row"><div class="setting-copy"><strong>${esc(j.kind)}${stTag(j.state)}</strong><small><span class="mono">${esc(j.id)}</span> · ${esc(fmtTime(j.createdAt))}${j.progress!=null?' · '+(j.progress*100).toFixed(0)+'%':''}${j.message?' · '+esc(j.message):''}</small>${j.progress!=null&&stCls(j.state)==='warn'?progress(j.progress):''}${j.error?`<small class="is-error">${esc(j.error)}</small>`:''}</div><div class="setting-trail">${iconBtn('delete', T('删除'), `data-jdel="${esc(j.id)}"`, true)}</div></div>`).join('') || empty(T('没有互联任务'), 'jobs');
  $('#jobs').querySelectorAll('[data-jdel]').forEach(b=>b.onclick=guard(async()=>{ await del('jobs/'+encodeURIComponent(b.dataset.jdel)); loadJobs(); }));
}

// ── 下载 ──
async function loadDownloads(){
  const r = await api('downloads');
  $('#dl-cap').textContent = r.supported ? T('后端: {0}', r.backend||'ok') : T('下载后端未配置：在「设置」填 qBittorrent WebUI 地址并重启。');
  $('#btn-dl-add').disabled = !r.supported;
  $('#dls').innerHTML = r.jobs.map(j=>{ const p = j.stageProgress!=null ? Number(j.stageProgress) : null;
    return `<div class="setting-row"><div class="list-lead">${icon(j.mediaKind==='tv'||j.mediaKind==='movie'?'video':'downloads')}</div><div class="setting-copy"><strong>${esc(j.title)}${stTag(j.lifecycle)}</strong><small>${esc([j.mediaKind, j.stage, p!=null?(p*100).toFixed(0)+'%':''].filter(Boolean).join(' · '))}</small><small class="mono">${esc(j.jobId)}</small>${p!=null&&stCls(j.lifecycle)!=='ok'?progress(p):''}${j.lastError?`<small class="is-error">${esc(j.lastError)}</small>`:''}</div><div class="setting-trail">${iconBtn('close', T('取消'), `data-dl="cancel" data-id="${esc(j.jobId)}"`)}${iconBtn('replay', T('重试'), `data-dl="retry" data-id="${esc(j.jobId)}"`)}${iconBtn('delete', T('清理'), `data-dl="delete" data-id="${esc(j.jobId)}"`, true)}</div></div>`; }).join('') || empty(T('没有下载任务'), 'downloads');
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
  $('#subs').innerHTML = (r.subscriptions||[]).map(s=>`<div class="setting-row"><div class="list-lead">${icon('subscriptions')}</div><div class="setting-copy"><strong>${esc(s.title)}${s.enabled?tag('ok', T('启用')):tag('', T('停用'))}</strong><small>${esc(s.searchQuery)} · ${esc(s.mediaKind)} · ${esc(s.mode)}</small><small>${s.resourceProviderLabel?esc(s.resourceProviderLabel):esc(T('没有可用来源'))}${s.itemCounts?' · '+esc(fmtCounts(s.itemCounts)):''} · ${esc(T('最近检查 {0}', s.lastCheckedAt?fmtTime(s.lastCheckedAt):'—'))}</small>${s.lastError?`<small class="is-error">${esc(s.lastError)}</small>`:''}</div><div class="setting-trail">${iconBtn(s.enabled?'pause':'play_arrow', s.enabled?T('停用'):T('启用'), `data-sub="enable" data-id="${esc(s.subscriptionId)}" data-enabled="${s.enabled?'0':'1'}"`)}${iconBtn('refresh', s.enabled?T('检查'):T('已停用的订阅不检查，请先启用'), `data-sub="check" data-id="${esc(s.subscriptionId)}"${s.enabled?'':' disabled'}`)}${iconBtn('delete', T('删除'), `data-sub="delete" data-id="${esc(s.subscriptionId)}"`, true)}</div></div>`).join('') || empty(T('还没有订阅'), 'subscriptions');
  $('#subs').querySelectorAll('[data-sub]').forEach(b=>b.onclick=guard(async()=>{ const id=encodeURIComponent(b.dataset.id);
    if(b.dataset.sub==='delete'){ if(!await ask(T('删除该订阅？（已下载的任务不受影响）'), true)) return; await del('subscriptions/'+id); toast(T('已删除')); }
    else if(b.dataset.sub==='enable'){ await post('subscriptions/'+id+'/enable',{enabled:b.dataset.enabled==='1'}); }
    else { await post('subscriptions/'+id+'/check'); }
    loadSubscriptions(); }));
}
$('#btn-sub-add').onclick = guard(async()=>{ const after=$('#sub-after').value.trim(); await post('subscriptions',{title:$('#sub-title').value, searchQuery:$('#sub-query').value, mediaKind:$('#sub-kind').value, resourceProvider:$('#sub-provider').value, startAfterEpisode: after?Number(after):undefined}); $('#sub-title').value=''; $('#sub-query').value=''; toast(T('已创建')); loadSubscriptions(); });
$('#btn-sub-check-all').onclick = guard(async()=>{ await post('subscriptions/check'); toast(T('已触发检查')); loadSubscriptions(); });

// ── 资源索引器（用户 BT 站 + Torznab；Torznab 表单只在首次 / 保存 / 放弃时重画，轮询不冲掉编辑）──
let riLoaded=false;
const BT_DOMAINS = [['anime',T('动画')],['movie',T('电影')],['tv',T('剧集')],['novel',T('小说')],['audiobook',T('有声书')],['manga',T('漫画')],['game',T('游戏')]];
const btDomainBoxes = (attr, on) => BT_DOMAINS.map(([k,l])=>`<label class="chip"><input type="checkbox" ${attr}="${k}" ${on.includes(k)?'checked':''}><span>${esc(l)}</span></label>`).join('');
const btPicked = (root, attr) => Array.from(root.querySelectorAll(`[${attr}]`)).filter(e=>e.checked).map(e=>e.getAttribute(attr));
$('#bt-domains').innerHTML = btDomainBoxes('data-bt-add-domain', BT_DOMAINS.map(d=>d[0]));
const swLabel = (attrs, on, text) => `<label class="switch-row"><span class="switch"><input type="checkbox" ${attrs} ${on?'checked':''}><span></span></span><span>${esc(text)}</span></label>`;
function btRow(x){
  const label = Object.fromEntries(BT_DOMAINS);
  const eff = x.effectiveDomains||[];
  const off = (x.domains||[]).filter(d=>!eff.includes(d));
  const state = !x.enabled ? tag('', T('已停用')) : (x.active===true ? tag('ok', T('生效中')) : (x.active===false ? tag('warn', T('未参与资源搜索')) : ''));
  const sep = T('、');
  return `<div class="bt-row card-inset" data-id="${esc(x.id)}">
    <div class="setting-copy"><strong>${esc(x.displayName)}${state}</strong><small>${esc(x.host)}</small>
    <small>${esc(T('适用：{0}', eff.map(d=>label[d]||d).join(sep)||T('无')))}${off.length?esc(T('；对 {0} 不生效', off.map(d=>label[d]||d).join(sep))):''}</small></div>
    <div class="bt-edit" style="display:none">
      <div class="form-grid"><label class="field">${esc(T('名称（可选）'))}<input type="text" data-k="name" value="${esc(x.name||'')}"></label><label class="field">${esc(T('新地址（留空不改）'))}<input type="text" data-k="url"></label></div>
      <div class="chip-set">${btDomainBoxes('data-bt-domain', x.domains||[])}</div>
      <label class="field">${esc(T('解析规则（JSON；清空 = 改回自动检测）'))}<textarea rows="4" data-k="parser">${esc(x.parser ? JSON.stringify(x.parser, null, 2) : '')}</textarea></label>
      <label class="field">${esc(T('新 Cookie（留空不改）'))}<input type="password" autocomplete="off" data-k="cookie"></label>
      <div class="action-row">${swLabel('data-k="enabled"', x.enabled, T('启用'))}${swLabel('data-k="allowInsecureHttp"', x.allowInsecureHttp, T('允许明文 HTTP（仅受信任局域网）'))}<span class="kit-spacer"></span><button class="primary-button" data-bt="save">${esc(T('保存'))}</button></div>
    </div>
    <div class="action-row"><button class="text-button" data-bt="edit">${esc(T('编辑'))}</button><button class="plain-button" data-bt="reprobe">${esc(T('重新检测'))}</button><span class="kit-spacer"></span><button class="plain-button danger-button" data-bt="delete">${esc(T('删除'))}</button></div></div>`;
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
    const x0 = (r.btSites||[]).find(s=>s.id===row.dataset.id) || {};
    if (act==='edit'){ const e=row.querySelector('.bt-edit'); e.style.display = e.style.display==='none' ? '' : 'none'; return; }
    let res;
    b.disabled = true;
    try {
      if (act==='delete'){ if(!await ask(T('删除这个 BT 站？（已建的订阅会改用其它来源，没有可用来源时暂停）'), true)) return; res = await del('resource-indexers/bt-sites/'+id); toast(T('已删除')); }
      else if (act==='reprobe'){ toast(T('正在检测站点…')); res = await post('resource-indexers/bt-sites/'+id+'/reprobe'); toast(T('检测完成')); }
      else {
        const v = (k)=>row.querySelector(`.bt-edit [data-k="${k}"]`);
        const domains = btPicked(row, 'data-bt-domain');
        if (!domains.length) throw new Error(T('至少选择一个媒体域'));
        const body = {name: v('name').value, domains, enabled: v('enabled').checked, allowInsecureHttp: v('allowInsecureHttp').checked};
        const url = v('url').value.trim(); if (url) { body.url = url; toast(T('正在检测站点…')); }
        const parser = v('parser').value.trim(); const parserWas = x0.parser ? JSON.stringify(x0.parser, null, 2) : '';
        if (parser !== parserWas.trim()) { body.parser = parser; toast(T('正在检测站点…')); }
        const cookie = v('cookie').value.trim(); if (cookie) { body.cookie = cookie; toast(T('正在检测站点…')); }
        res = await put('resource-indexers/bt-sites/'+id, body); toast(T('已保存'));
      }
    } finally { b.disabled = false; }
    renderBtSites(res); renderRiState(res); loadSubscriptions();
  }));
}
$('#btn-bt-template').onclick = () => { const p = $('#bt-parser'); if (!p.value.trim()) p.value = $('#bt-parser-template').textContent; };
$('#btn-bt-add').onclick = guard(async()=>{
  const url = $('#bt-url').value.trim(); if (!url) throw new Error(T('请填写站点地址'));
  const domains = btPicked($('#bt-domains'), 'data-bt-add-domain'); if (!domains.length) throw new Error(T('至少选择一个媒体域'));
  $('#btn-bt-add').disabled = true; toast(T('正在检测站点…'));
  try {
    const body = {url, name: $('#bt-name').value, domains, enabled: $('#bt-enabled').checked, allowInsecureHttp: $('#bt-insecure').checked};
    const parser = $('#bt-parser').value.trim(); if (parser) { body.parser = parser; body.cookie = $('#bt-cookie').value.trim(); }
    const r = await post('resource-indexers/bt-sites', body);
    $('#bt-url').value=''; $('#bt-name').value=''; $('#bt-parser').value=''; $('#bt-cookie').value='';
    renderBtSites(r); renderRiState(r); toast(T('已添加')); loadSubscriptions();
  } finally { $('#btn-bt-add').disabled = false; }
});
// Newznab 标准分类里与 Fushi 媒体相关的几个；不在表里的 ID 进「其他」文本框。
const TORZNAB_CATS = [[2000,T('电影')],[5000,T('剧集')],[5070,T('动画')],[7000,T('书籍')],[7030,T('漫画')],[3030,T('有声书')]];
function riCatsCtl(cats){
  const known = new Set(TORZNAB_CATS.map(([id])=>id));
  const rest = cats.filter(c=>!known.has(Number(c)));
  return `<div class="field is-wide"><span class="kit-supporting">${esc(T('分类（不选 = 全部）'))}</span><div class="chip-set">${TORZNAB_CATS.map(([id,l])=>`<label class="chip"><input type="checkbox" data-ri-cat="${id}" ${cats.map(Number).includes(id)?'checked':''}><span>${esc(l)} · ${id}</span></label>`).join('')}</div>
    <label class="field">${esc(T('其他分类 ID（逗号分隔，可空）'))}<input type="text" data-k="categories" value="${esc(rest.join(','))}"></label></div>`;
}
function riRow(x){
  const keySet = x.apiKeySet ? ` <span class="muted">${esc(T('(已设置，留空不改)'))}</span>` : '';
  return `<div class="ri-row card-inset" data-id="${esc(x.id||'')}"><div class="form-grid">
    <label class="field">${esc(T('名称'))}<input type="text" data-k="name" value="${esc(x.name||'')}"></label>
    <label class="field">${esc(T('地址（https://…/api；带 ?apikey= 会自动拆进 key 栏）'))}<input type="text" data-k="endpoint" value="${esc(x.endpoint||'')}"></label>
    <label class="field">API key${keySet}<input type="password" data-k="apiKey" value="" autocomplete="off"></label>
    <label class="field">${esc(T('优先级（小的先搜）'))}<input type="number" data-k="priority" value="${esc(x.priority??100)}"></label>
    ${riCatsCtl(x.categories||[])}</div>
    <div class="action-row">${swLabel('data-k="enabled"', x.enabled!==false, T('启用'))}${swLabel('data-k="allowInsecureHttp"', x.allowInsecureHttp, T('允许明文 HTTP（仅受信任局域网）'))}${x.apiKeySet?swLabel('data-k="clearApiKey"', false, T('清除已存的 key')):''}<span class="kit-spacer"></span><button class="plain-button danger-button" data-ri-rm>${esc(T('移除'))}</button></div></div>`;
}
function bindRiRemove(){ $('#ri-torznab').querySelectorAll('[data-ri-rm]').forEach(b=>b.onclick=()=>b.closest('.ri-row').remove()); }
function renderIndexers(r){
  renderBtSites(r);
  $('#ri-torznab').innerHTML = (r.torznab||[]).map(riRow).join('') || `<p class="kit-supporting" id="ri-empty">${esc(T('还没有 Torznab indexer。'))}</p>`;
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
      priority: pr==='' ? undefined : Number(pr), categories: [...Array.from(row.querySelectorAll('[data-ri-cat]:checked')).map(c=>c.dataset.riCat), ...v('categories').value.split(',').map(t=>t.trim()).filter(Boolean)].join(','), enabled: v('enabled').checked, allowInsecureHttp: v('allowInsecureHttp').checked};
  });
  $('#btn-ri-save').disabled=true;
  try { const r = await put('resource-indexers', {torznab}); renderIndexers(r); toast(r.applied ? T('已保存并生效') : T('已保存')); loadSubscriptions(); }
  finally { $('#btn-ri-save').disabled=false; }
});

// ── 模型 ──
const readyTag = (m) => m.error ? tag('err', m.error) : (m.ready ? tag('ok', T('就绪')) : tag('', T('缺失')));
const pullButton = (key, pulling) => `<button class="text-button" data-pull="${esc(key)}" ${pulling?'disabled':''}>${icon('downloads')}${esc(pulling?T('下载中…'):T('下载'))}</button>`;
const modelBytes = (m) => m.totalBytes ? fmtBytes(m.obtainedBytes)+' / '+fmtBytes(m.totalBytes) : '';
const modelRow = (name, sub, m, key, ic) => `<div class="setting-row"><div class="list-lead"${m.ready?' data-tone="success"':''}>${icon(ic||'models')}</div><div class="setting-copy"><strong>${name}${readyTag(m)}</strong>${sub?`<small>${sub}</small>`:''}${m.pulling&&m.totalBytes?progress(m.obtainedBytes/m.totalBytes):''}</div>${m.ready||m.error?'':`<div class="setting-trail">${pullButton(key, m.pulling)}</div>`}</div>`;
async function loadModels(){
  const r = await api('models');
  $('#asr-models').innerHTML = r.asr.map(m=>modelRow(`${esc(m.name||m.tag)} <span class="muted">${esc(m.tag)}</span>`, esc([[m.variant,m.provider].filter(Boolean).join(' / '), modelBytes(m)].filter(Boolean).join(' · ')), m, m.tag, 'graphic_eq')).join('') || empty(T('无'), 'models');
  $('#ocr-model').innerHTML = (r.ocrModels && r.ocrModels.length) ? r.ocrModels.map(m=>modelRow(esc(m.name||m.key), esc(modelBytes(m)), m, 'ocr:'+m.key, 'text_fields')).join('')
    : r.ocr ? modelRow('OCR', esc(fmtBytes(r.ocr.obtainedBytes)+' / '+fmtBytes(r.ocr.totalBytes)), r.ocr, 'ocr', 'text_fields') : empty(T('OCR 服务不可用'), 'models');
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
  $('#anki-status').innerHTML = kvHtml(kv);
  $('#anki-landing').checked = !!L.enabled;
  $('#anki-landing').disabled = !a.available;

  // 表单只在账号 / 可选项变了时重画，否则 2.5 秒一次的轮询会冲掉正在输入的内容。
  const key = JSON.stringify([a.available, a.account, ankiRelogin, a.settings.decks, a.settings.noteTypes, a.settings.noteType]);
  if (key === ankiFormKey) return;
  ankiFormKey = key;
  if (!a.available) { $('#anki-account').innerHTML = empty(T('此服务端包没有 fushi-anki-sync。'), 'anki'); $('#anki-config').innerHTML = empty(T('登录后显示。'), 'anki'); return; }
  const showLogin = !a.account || ankiRelogin;
  $('#anki-account').innerHTML = !showLogin
    ? `<div class="card-head"><div class="card-head-copy"><h2 class="kit-title-medium">${esc(T('已登录：{0}', a.account.username))}</h2><p class="kit-supporting">${esc(a.account.server || 'AnkiWeb')}</p></div></div>
       <div class="action-row"><button class="primary-button" id="btn-anki-sync">${icon('refresh')}${esc(T('立即同步'))}</button><button class="text-button" id="btn-anki-refresh">${esc(T('刷新牌组 / 笔记类型'))}</button><button class="plain-button" id="btn-anki-relogin">${esc(T('重新登录'))}</button><span class="kit-spacer"></span><button class="plain-button danger-button" id="btn-anki-logout">${esc(T('退出登录'))}</button></div>`
    : `<div class="form-grid">
       <label class="field is-wide">${esc(T('同步服务器（自建服务器地址，如 http://nas:8080/；留空为 AnkiWeb）'))}<input id="anki-endpoint" value="${esc(a.account ? (a.account.server || '') : '')}"></label>
       <label class="field">${esc(T('用户名'))}<input id="anki-user" value="${esc(a.account ? a.account.username : '')}"></label>
       <label class="field">${esc(T('密码'))}<input type="password" id="anki-pass"></label></div>
       <div class="action-row"><button class="primary-button" id="btn-anki-login">${esc(T('登录并下载牌组集合'))}</button>${a.account ? `<button class="plain-button" id="btn-anki-relogin-cancel">${esc(T('取消'))}</button>` : ''}</div>
       <p class="kit-supporting">${esc(T('密码只用来换取同步凭据，不保存。同一服务器与用户名重新登录只换凭据，本机的牌组集合与未同步的卡都保留。'))}</p>`;
  if (!showLogin) {
    $('#btn-anki-sync').onclick = guard(async()=>{ await post('anki/sync'); toast(T('已同步')); ankiFormKey=null; loadAnki(); });
    $('#btn-anki-refresh').onclick = guard(async()=>{ await post('anki/refresh'); toast(T('已刷新')); ankiFormKey=null; loadAnki(); });
    $('#btn-anki-relogin').onclick = ()=>{ ankiRelogin=true; ankiFormKey=null; loadAnki(); };
    $('#btn-anki-logout').onclick = guard(async()=>{
      if(!await ask(T('退出登录会删掉本机的牌组集合副本。继续？'), true)) return;
      try { await post('anki/logout'); }
      catch(e){
        const m = /^unsynced:(\d+)$/.exec(e.message);
        if (!m) throw e;
        if (!await ask(T('还有 {0} 张卡没有同步到 Anki。放弃这些卡并退出？（放弃后无法找回）', m[1]), true)) return;
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
        if (!await ask(T('AnkiWeb 的服务条款只允许官方 Anki 客户端同步。Fushi 会如实表明自己是 Fushi，因此 AnkiWeb 可能拒绝连接，或对你的账号采取措施。自建同步服务器没有这项限制。\n\n仍然使用 AnkiWeb？'))) return;
        acceptAnkiWeb = true;
      }
      await post('anki/login', {endpoint, username: $('#anki-user').value, password: $('#anki-pass').value, acceptAnkiWeb});
      toast(T('已登录')); ankiRelogin=false; ankiFormKey=null; loadAnki();
    });
  }

  const st = a.settings;
  if (!a.account || !st.decks.length) { $('#anki-config').innerHTML = empty(T('登录后显示。'), 'anki'); return; }
  const opt = (list, sel) => list.map(x=>`<option ${x===sel?'selected':''}>${esc(x)}</option>`).join('');
  const ph = `<datalist id="anki-ph">${a.placeholders.map(x=>`<option value="${esc(x)}">`).join('')}</datalist>`;
  $('#anki-config').innerHTML = `${ph}<div class="form-grid">
    <label class="field">${esc(T('牌组'))}<select id="anki-deck">${opt(st.decks, st.deck)}</select></label>
    <label class="field">${esc(T('笔记类型'))}<select id="anki-nt">${opt(st.noteTypes, st.noteType)}</select></label>
    <label class="field">${esc(T('标签（空格分隔）'))}<input id="anki-tags" value="${esc(st.tags)}"></label></div>
    <h2 class="kit-title-medium">${esc(T('字段映射'))}</h2><p class="kit-supporting">${esc(T('每个字段填占位符，如 {expression}、{reading}、{glossary}、{sentence}；可组合。没填映射时卡片会留着等，不会丢。'))}</p>
    <div class="form-grid">${st.fields.map(f=>`<label class="field">${esc(f)}<input list="anki-ph" data-field="${esc(f)}" value="${esc(st.fieldMappings[f]||'')}"></label>`).join('')}</div>
    <div class="action-row"><button class="primary-button" id="btn-anki-save">${esc(T('保存'))}</button></div>`;
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
const SRS_STATE = {opening:T('打开中'), ready:T('可用'), encrypted:T('同步位置已加密（暂不支持）'), needs_upgrade:T('数据来自更新版本的 Fushi，请升级服务端'), failed:T('出错'), upgrading:T('复习库升级中'), upgrade_blocked:T('复习库升级没完成，需在服务端处理（ctl srs migration）')};
// 各份配置文件的 RWKV 准备状态（ServerSrsProfile.toJson 的 rwkv / rwkvError）：idle = 库里没有 RWKV 牌组 / 还没开始，不显示。
const SRS_RWKV = {downloading:T('RWKV 下载权重中'), preparing:T('RWKV 准备中'), ready:T('RWKV 就绪'), failed:T('RWKV 出错')};
// 复习库换代（协议 3 srs.db → 新代，server_srs.dart ServerSrsGeneration）：ready 不显示；其余显示状态、进度、处置说明。
// 失败类状态不自动重跑，「开始升级」由管理员表态后才发（server.srs.migration.start）；提交点之前可叫停。
const SRS_GEN_STATE = {migrating:T('升级中'), migrating_elsewhere:T('另一个进程在升级'), needs_migration:T('需要升级'), migration_failed:T('升级失败'), sealed_old_only:T('只剩封存的旧库'), legacy_beside_new:T('新库旁边还有没升级的旧库'), blocked:T('升级受阻'), no_space:T('磁盘空间不够'), error:T('出错')};
const SRS_GEN_IDLE = ['ready','migrating','migrating_elsewhere'];
function renderSrsMigration(g){
  const box = $('#srs-migration');
  if (!g || g.state==='ready') { box.innerHTML=''; return; }
  const progress = g.step ? ` · ${g.step}${g.total ? ' '+g.done+'/'+g.total : ''}` : '';
  const kv = [[T('复习库换代'), (SRS_GEN_STATE[g.state]||g.state) + progress + (g.cancelRequested ? T(' · 已请求叫停') : '')]];
  if (g.code) kv.push([T('原因'), g.code + (g.reason ? T('：') + g.reason : '')]);
  if (g.reportPath) kv.push([T('报告'), g.reportPath]);
  const start = !SRS_GEN_IDLE.includes(g.state) ? `<button class="primary-button" id="btn-srs-mig-start">${esc(T('开始升级'))}</button>` : '';
  const cancel = g.cancellable ? `<button class="outlined-button danger-button" id="btn-srs-mig-cancel">${esc(T('叫停升级'))}</button>` : '';
  box.innerHTML = `<div class="kv-grid" style="margin-top:12px">${kvHtml(kv)}</div><p class="kit-supporting" data-srs-advice>${esc(g.advice||'')}</p>${start||cancel ? `<div class="action-row">${start}${cancel}</div>` : ''}`;
  const s = $('#btn-srs-mig-start');
  if (s) s.onclick = guard(async()=>{ if(!await ask(T('开始升级复习库？升级期间远程复习与制卡暂停；旧的 srs.db 会封存保留，不删除任何文件。'))) return; await post('srs/migration/start'); toast(T('已开始升级')); loadSrs(); });
  const c = $('#btn-srs-mig-cancel');
  if (c) c.onclick = guard(async()=>{ if(!await ask(T('叫停复习库升级？提交步骤之前叫停会回到升级前的样子；刚好进入提交步骤时以最终结论为准。'), true)) return; await post('srs/migration/cancel'); toast(T('已请求叫停')); loadSrs(); });
}
// 旧版本保留副本（D32，engine srs_ctl_routes.dart 的 retained 路由）：迁移时封存在原位的协议 3 srs.db。只在还是封存的
// 副本时显示；删除不可撤销（之后不能退回旧版本，清除过的原文随之消失），一定先确认、带 confirm: true 才发。副本坏了
// （copy = unreadable，BUG-5079）只提示、不给删除。
function renderSrsRetained(r){
  const box = $('#srs-retained');
  if (r && r.copy === 'unreadable') { box.innerHTML = `<div class="kv-grid" style="margin-top:12px">${kvHtml([[T('旧版本保留副本'), T('已损坏（不是可读的 SQLite 文件），不能再用它退回旧版本；当前复习库不受影响')]])}</div>`; return; }
  if (!r || r.copy !== 'sealed') { box.innerHTML=''; return; }
  const due = r.dueAtMs ? T('{0} 到期后自动删除', fmtTime(r.dueAtMs)) : T('删除前一直保留（不会自动到期）');
  const kv = [[T('旧版本保留副本'), fmtBytes(r.bytes) + ' · ' + due]];
  if (r.error) kv.push([T('自动删除没做成'), r.error]);
  box.innerHTML = `<div class="kv-grid" style="margin-top:12px">${kvHtml(kv)}</div><div class="action-row"><button class="outlined-button danger-button" id="btn-srs-retained-delete">${esc(T('删除保留副本'))}</button></div>`;
  $('#btn-srs-retained-delete').onclick = guard(async()=>{
    if (!await ask(T('立即删除旧版本保留副本？不可撤销：删除后不能再退回旧版本，彻底清除过的内容在旧库里的原文也随之消失。删除前会先核对新库完好，核对不过不删。'), true)) return;
    const res = await post('srs/retained/delete', {confirm: true});
    toast(res.deleted ? T('已删除保留副本，释放 {0}', fmtBytes(res.freedBytes)) : T('没有可删除的保留副本'));
    loadSrs();
  });
}
let srsFormKey = null;
// 待确认 / 已拒绝的设备（服务端开库后第一次同步过来的；删除与彻底清除在本机扣着，engine srs_devices.dart）。
function renderSrsDevices(devs){
  const rows = [];
  (devs.profiles||[]).forEach(p=>(p.untrusted||[]).forEach(d=>rows.push([p, d])));
  const many = (devs.profiles||[]).length > 1;
  $('#srs-devices').innerHTML = rows.map(([p, d])=>{
    const name = d.name ? (d.app ? T('{0}（Fushi {1}）', d.name, d.app) : d.name) : T('未命名设备');
    const held = T('扣着 {0} 条删除、{1} 条彻底清除', d.heldDeletes, d.heldPurges);
    const seen = d.trustSince ? T('首次出现 {0}', fmtTime(d.trustSince)) : '';
    return `<div class="setting-row"><div class="list-lead">${icon('device')}</div><div class="setting-copy"><strong>${esc(name)}${d.trust==='pending'?tag('warn', T('待确认')):tag('', T('已拒绝'))}</strong><small>${esc([held, seen, many?(p.name||p.uid):''].filter(Boolean).join(' · '))}</small><small class="mono">${esc(d.device)}</small></div><div class="setting-trail"><button class="text-button" data-srs-trust="${esc(d.device)}" data-uid="${esc(p.uid)}" data-name="${esc(name)}" data-held="${d.heldDeletes+d.heldPurges}" data-purges="${d.heldPurges}">${esc(T('信任'))}</button>${d.trust==='pending'?`<button class="plain-button danger-button" data-srs-reject="${esc(d.device)}" data-uid="${esc(p.uid)}">${esc(T('拒绝'))}</button>`:''}</div></div>`;
  }).join('') || empty(T('没有待确认的设备'), 'device');
  document.querySelectorAll('[data-srs-trust]').forEach(el=>el.onclick = guard(async()=>{
    if (!await ask(T('信任「{0}」？它扣着的 {1} 条删除与彻底清除会立即生效。', el.dataset.name, el.dataset.held), Number(el.dataset.purges) > 0)) return;
    await post('srs/devices/trust', {profile: el.dataset.uid, device: el.dataset.srsTrust, trust: true}); toast(T('已信任')); loadSrs();
  }));
  document.querySelectorAll('[data-srs-reject]').forEach(el=>el.onclick = guard(async()=>{
    await post('srs/devices/trust', {profile: el.dataset.uid, device: el.dataset.srsReject, trust: false}); toast(T('已拒绝，删除继续扣着')); loadSrs();
  }));
}
async function loadSrs(){
  const [st, found, devs, retained] = await Promise.all([api('srs'), api('srs/profiles'), api('srs/devices').catch(()=>({profiles:[]})), api('srs/retained').catch(()=>null)]);
  const ac = st.ankiConnect || {};
  const kv = [
    [T('状态'), st.enabled ? T('已开启') : T('未开启（没有勾选配置文件）')],
    [T('调度器'), st.scheduler ? T('FSRS 可用') : T('没找到 fushi_fsrs（只能浏览 / 加卡）')],
    ['AnkiConnect', ac.listening ? T('监听 {0}:{1}', ac.bind, ac.listeningPort) : (ac.enabled ? T('未监听') + (ac.lastError ? T('：') + ac.lastError : '') : T('关闭'))],
  ];
  $('#srs-status').innerHTML = kvHtml(kv);
  renderSrsMigration(st.generation);
  renderSrsDevices(devs);
  renderSrsRetained(retained);
  const served = {}; (st.profiles||[]).forEach(p=>served[p.uid]=p);
  const list = found.profiles || [];
  const key = JSON.stringify([list.map(p=>[p.uid,p.name,p.served,p.missing]), st.config, ac.enabled, ac.bind, ac.port, ac.apiKeySet, ac.profileKeysSet]);
  // 状态每轮刷新；表单只在内容变了时重画，不冲掉正在编辑的输入。
  const statusOf = (uid)=>{ const p = served[uid]; if(!p) return ''; return `${SRS_STATE[p.state]||p.state}${p.notes!=null?T(' · {0} 条笔记', p.notes):''}${p.lastSyncAt?T(' · 同步于 {0}', fmtTime(p.lastSyncAt)):''}${p.lastError?' · '+p.lastError:''}${SRS_RWKV[p.rwkv]?' · '+SRS_RWKV[p.rwkv]:''}${p.rwkvError?T('：')+p.rwkvError:''}`; };
  if (key === srsFormKey) { document.querySelectorAll('[data-srs-status]').forEach(el=>{ el.textContent = statusOf(el.dataset.srsStatus); }); return; }
  srsFormKey = key;
  const cfg = st.config;
  const def = st.defaultProfile || cfg.defaultProfile;
  const H = {serve:T('提供'), def:T('默认'), prof:T('配置文件'), dev:T('设备'), state:T('状态')};
  $('#srs-profiles').innerHTML = list.length ? `<table class="data-table is-responsive"><tr class="is-head"><th>${esc(H.serve)}</th><th>${esc(H.def)}</th><th>${esc(H.prof)}</th><th>${esc(H.dev)}</th><th>${esc(H.state)}</th><th></th></tr>${list.map(p=>`<tr>
      <td data-label="${esc(H.serve)}"><span class="switch"><input type="checkbox" data-srs-serve="${esc(p.uid)}" ${p.served?'checked':''}><span></span></span></td>
      <td data-label="${esc(H.def)}"><input type="radio" name="srs-def" data-srs-def="${esc(p.uid)}" ${p.uid===def?'checked':''} ${p.served?'':'disabled'}></td>
      <td data-label="${esc(H.prof)}"><div>${esc(p.name||p.uid)}<div class="small muted mono">${esc(p.uid)}${p.missing?esc(T(' · 同步目录里已没有')):''}</div></div></td>
      <td class="small" data-label="${esc(H.dev)}"><div>${esc((p.devices||[]).join(T('、')))}${p.noteCount!=null?`<div class="muted">${esc(T('{0} 条笔记', p.noteCount))}</div>`:''}</div></td>
      <td class="small" data-label="${esc(H.state)}" data-srs-status="${esc(p.uid)}">${esc(statusOf(p.uid))}</td>
      <td>${p.served?`<button class="text-button" data-srs-sync="${esc(p.uid)}">${esc(T('同步'))}</button>`:''}</td></tr>`).join('')}</table>`
    : empty(T('同步目录里还没有任何配置文件：先让一台设备经互联同步一次复习数据。'), 'srs');
  // 管理员给提供中的配置文件起名（srs.profile_names）：本机发布到同步位置的说明文件、远程复习的选择列表都用它；空 = 用设备报的名字。
  const named = list.filter(p=>p.served);
  if (named.length) {
    $('#srs-profiles').insertAdjacentHTML('beforeend', `<div class="form-grid" style="margin-top:12px">${named.map(p=>`<label class="field is-wide">${esc(T('{0} 的名字（空 = 用设备报的名字）', p.uid))}<input data-srs-name="${esc(p.uid)}" maxlength="100" autocomplete="off" placeholder="${esc(p.name && p.name!==p.uid ? p.name : '')}" value="${esc((cfg.profileNames||{})[p.uid]||'')}"></label>`).join('')}</div><div class="action-row"><button class="text-button" id="btn-srs-names">${esc(T('保存名字'))}</button></div>`);
    $('#btn-srs-names').onclick = guard(async()=>{
      const profileNames = {}; document.querySelectorAll('[data-srs-name]').forEach(el=>{ if(el.value.trim()) profileNames[el.dataset.srsName]=el.value.trim(); });
      await put('srs', {profileNames}); toast(T('已保存')); srsFormKey=null; loadSrs();
    });
  }
  document.querySelectorAll('[data-srs-serve]').forEach(el=>el.onchange = guard(async()=>{
    await put('srs', el.checked ? {addProfiles:[el.dataset.srsServe]} : {removeProfiles:[el.dataset.srsServe]});
    toast(el.checked ? T('已开始提供') : T('已停止提供')); srsFormKey=null; loadSrs();
  }));
  document.querySelectorAll('[data-srs-def]').forEach(el=>el.onchange = guard(async()=>{ await put('srs', {defaultProfile: el.dataset.srsDef}); toast(T('已设为默认')); srsFormKey=null; loadSrs(); }));
  document.querySelectorAll('[data-srs-sync]').forEach(el=>el.onclick = guard(async()=>{ await post('srs/sync', {profile: el.dataset.srsSync}); toast(T('已同步')); loadSrs(); }));

  const servedList = list.filter(p=>p.served);
  $('#srs-mining').innerHTML = `<p class="kit-supporting">${esc(T('已配对设备「制卡到已配对设备」时卡片落到哪。手机可以在自己的设置里另选；没选时，手机当前的配置文件本机有就落进那份，否则落进默认那份。'))}</p>
    <div class="form-grid"><label class="field">${esc(T('落到'))}<select id="srs-target">${[['auto',T('自动（没配好 Anki 时进复习）')],['review',T('Fushi 复习')],['anki','Anki']].map(([v,l])=>`<option value="${v}" ${cfg.miningTarget===v?'selected':''}>${esc(l)}</option>`).join('')}</select></label>
    <label class="field">${esc(T('换日时刻'))}<select id="srs-rollover">${Array.from({length:24},(_,h)=>`<option value="${h}" ${h===Number(cfg.rolloverHour)?'selected':''}>${String(h).padStart(2,'0')}:00</option>`).join('')}</select></label>
    ${servedList.map(p=>`<label class="field">${esc(T('{0} 的制卡牌组（空 = 默认牌组）', p.name||p.uid))}<input data-srs-deck="${esc(p.uid)}" list="srs-decks-${esc(p.uid)}" autocomplete="off" value="${esc((cfg.miningDecks||{})[p.uid]||'')}"><datalist id="srs-decks-${esc(p.uid)}"></datalist></label>`).join('')}</div>
    <div class="action-row"><button class="primary-button" id="btn-srs-save">${esc(T('保存'))}</button></div>`;
  // 牌组框的建议：各份 profile 已有的牌组，取自 ctl 的 `GET srs/decks?profile=`（AdminSrsCtl，name 是 `父::子` 全名；取不到就不给建议，照样可手填新牌组名）。
  servedList.forEach(p=>api('srs/decks?profile='+encodeURIComponent(p.uid)).then(r=>{
    const dl = document.getElementById('srs-decks-'+p.uid);
    if (dl) dl.innerHTML = (r.decks||[]).map(d=>d.name).sort().map(n=>`<option value="${esc(n)}">`).join('');
  }, e=>console.warn('srs decks', e)));
  $('#btn-srs-save').onclick = guard(async()=>{
    const miningDecks = {}; document.querySelectorAll('[data-srs-deck]').forEach(el=>{ if(el.value.trim()) miningDecks[el.dataset.srsDeck]=el.value.trim(); });
    await put('srs', {miningTarget: $('#srs-target').value, rolloverHour: parseInt($('#srs-rollover').value,10), miningDecks});
    toast(T('已保存')); srsFormKey=null; loadSrs();
  });

  $('#srs-rwkv').innerHTML = `<div class="form-grid"><label class="field">${esc(T('使用的模型'))}<select id="srs-rwkv-model">${[['small',T('Small（默认，准确度最好）')],['tiny',T('Tiny（每张卡省约 30% 内存，准确度略差）')]].map(([v,l])=>`<option value="${v}" ${(cfg.rwkvModel||'small')===v?'selected':''}>${esc(l)}</option>`).join('')}</select></label></div>`;
  $('#srs-rwkv-model').onchange = guard(async()=>{ try { await put('srs', {rwkvModel: $('#srs-rwkv-model').value}); toast(T('已切换 RWKV 模型')); } finally { srsFormKey=null; loadSrs(); } });

  const setNote = (isSet) => isSet ? ` <span class="muted">${esc(T('(已设置，留空不改)'))}</span>` : '';
  $('#srs-ankiconnect').innerHTML = `<div class="action-row">${swLabel('id="ac-enabled"', ac.enabled, T('开关'))}</div>
    <div class="form-grid">
    <label class="field">${esc(T('监听地址'))}${choiceCtl('ac-bind', BIND_CHOICES(), ac.bind||'127.0.0.1')}</label>
    <label class="field">${esc(T('端口'))}<input type="number" id="ac-port" value="${ac.port||8765}"></label>
    <label class="field">${esc(T('共用 key（落到默认配置文件）'))}${setNote(ac.apiKeySet)}<input type="password" id="ac-key" value=""></label>
    ${servedList.map(p=>`<label class="field">${esc(T('{0} 专用 key', p.name||p.uid))}${setNote((ac.profileKeysSet||{})[p.uid])}<input type="password" data-ac-key="${esc(p.uid)}" value=""></label>`).join('')}</div>
    <div class="action-row"><button class="primary-button" id="btn-ac-save">${esc(T('保存'))}</button>${ac.apiKeySet?`<button class="plain-button danger-button" id="btn-ac-clear">${esc(T('清除共用 key'))}</button>`:''}</div>`;
  $('#btn-ac-save').onclick = guard(async()=>{
    const body = {enabled: $('#ac-enabled').checked, bind: choiceValue('ac-bind') ?? '', port: parseInt($('#ac-port').value,10)};
    if ($('#ac-key').value) body.apiKey = $('#ac-key').value;
    const profileKeys = {}; document.querySelectorAll('[data-ac-key]').forEach(el=>{ if(el.value) profileKeys[el.dataset.acKey]=el.value; });
    if (Object.keys(profileKeys).length) body.profileKeys = profileKeys;
    await put('srs', {ankiConnect: body}); toast(T('已保存')); srsFormKey=null; loadSrs();
  });
  const clear = $('#btn-ac-clear');
  if (clear) clear.onclick = guard(async()=>{ await put('srs', {ankiConnect:{apiKey:''}}); toast(T('已清除')); srsFormKey=null; loadSrs(); });
}

// ── 设置 ──
// 每项：[键, 文案, 类型, 分组]。文案里末尾括号部分显示成说明行；分组只管显示，保存时仍是一个请求体。
const FIELDS = [
  ['language',T('界面语言（Language）'),'seg:en,zh','general'],['deviceName',T('设备名'),'text','general'],
  ['port',T('互联端口'),'number','network'],['bind',T('绑定地址'),'choice:bind','network'],['tls','TLS','bool','network'],['lanRequiresPin',T('局域网配对必须 PIN'),'bool','network'],['adminPort',T('WebUI 端口'),'number','network'],
  ['subtitleLanguage',T('字幕语言'),'choice:subtitleLanguage','media'],['metadataLocale',T('刮削资料语言（BCP-47，如 ja / zh-CN）'),'choice:metadataLocale','media'],
  ['scanScrape',T('扫描后自动补刮视频资料'),'bool','media'],['tmdbApiKey',T('TMDB API key（服务端没有内置 key，不填则 TMDB 不可用）'),'secret:tmdbApiKeySet','media'],['scanPrune',T('扫描后清理文件已消失的视频条目'),'bool','media'],['uploadQuotaBytes',T('上传配额'),'bytes','media'],
  ['profileTransfer',T('允许已配对设备推送 / 拉取配置文件（Profile）'),'bool','access'],['remoteUpdate',T('允许已配对设备远程更新本服务端（仅发布包；装完退出码 10，由服务管理器重启）'),'bool','access'],['leaderboardLink',T('允许「我的设备」跟随本机 Fushi 排行榜账户自动登录'),'bool','access'],['lookupChineseScriptVariants',T('中文查词简繁互查（只管不自带开关的浏览器扩展 / 旧客户端；新版 app 用自己的开关）'),'bool','access'],
  ['ffmpeg',T('ffmpeg 路径（空=PATH）'),'text','tools'],['ffprobe',T('ffprobe 路径（空=PATH）'),'text','tools'],['onnxruntimeLibrary',T('onnxruntime 动态库'),'text','tools'],
  ['torrent.engine',T('torrent 引擎'),'select:auto,embedded,qbittorrent','downloads'],['torrent.library',T('内置引擎库路径（空=随包/系统）'),'text','downloads'],['torrent.listen',T('libtorrent 监听接口'),'text','downloads'],
  ['torrent.uploadEnabled',T('允许上传 / 做种（关 = 不给任何 peer 上传，已完成的种子暂停做种）'),'bool','downloads'],['torrent.uploadLimitKbps',T('上传限速 KB/s（0 = 不限）'),'number','downloads'],['torrent.downloadLimitKbps',T('下载限速 KB/s（0 = 不限）'),'number','downloads'],['torrent.limitLocalPeers',T('限速也作用于局域网 peer'),'bool','downloads'],['torrent.maxActiveDownloads',T('同时下载的种子数（-1 = 不限，0 = libtorrent 默认 3）'),'number','downloads'],['torrent.maxActiveSeeds',T('同时做种的种子数（-1 = 不限，0 = libtorrent 默认 5）'),'number','downloads'],['torrent.maxConnections',T('最大连接数（0 = 按内存自动推导）'),'number','downloads'],['torrent.seedRatioLimit',T('分享率上限（0 = 不限；开上传时生效）'),'number','downloads'],['torrent.seedTimeLimitMinutes',T('做种时长上限 分钟（0 = 不限；开上传时生效）'),'number','downloads'],
  ['qbittorrent.url',T('qBittorrent WebUI 地址'),'text','downloads'],['qbittorrent.username',T('qBittorrent 用户名'),'text','downloads'],['qbittorrent.password',T('qBittorrent 密码'),'password','downloads'],
  ['ai.preset',T('AI 提供商（手机「AI 下视频」选本机执行时用；空 = 不用 AI、不发任何 AI 请求）'),'dyn:aiPresets','ai'],['ai.apiKey','AI API key','secret:ai.apiKeySet','ai'],
  ['ai.model',T('AI 模型（空 = 预设起点模型）'),'aimodel','ai'],['ai.baseUrl',T('AI 接口地址（空 = 预设地址）'),'text','ai'],['ai.protocol',T('AI 协议（空 = 跟随预设）'),'select:,openAiCompatible,anthropicMessages,geminiGenerateContent','ai'],
  ['ai.reasoningEffort',T('AI 推理档位'),'select:none,low,medium,high','ai'],['ai.allowInsecureHttp',T('AI 允许明文 HTTP（本地推理服务）'),'bool','ai'],['ai.images',T('AI 模型能看图（字幕校对会附上视频画面）'),'bool','ai'],['ai.webKnowledge',T('AI 联网资料（维基辅助识别作品）'),'bool','ai'],['ai.libraryOrganize',T('扫描入库后自动 AI 整理库（把该在一起的归进合集，按量计费）'),'bool','ai'],
];
const SETTING_GROUPS = [['general',T('通用')],['network',T('网络与配对')],['media',T('媒体与刮削')],['access',T('设备权限')],['tools',T('外部工具')],['downloads',T('下载')],['ai',T('AI 助手')]];
// 改后要重启 serve 才生效的项（同保存键旁的提示）。
const RESTART = new Set(['port','bind','tls','adminPort','ffmpeg','ffprobe','onnxruntimeLibrary','torrent.engine','torrent.library','torrent.listen','qbittorrent.url','qbittorrent.username','qbittorrent.password']);
const LANGUAGE_NAMES = {en:'English', zh:'中文'};
const LABEL_SPLIT = new RegExp('^(.+?)\\s*[(' + String.fromCharCode(0xFF08) + '](.+)[)' + String.fromCharCode(0xFF09) + ']$');
const splitLabel = (l) => { const m = LABEL_SPLIT.exec(l); return m ? [m[1], m[2]] : [l, '']; };
// 「下拉 + 其他…」型字段的选项：[值, 显示名]。值不在表里时选「其他…」并露出文本框，手填照旧可用。
const BIND_CHOICES = () => [['0.0.0.0',T('所有网络（0.0.0.0）')],['127.0.0.1',T('仅本机（127.0.0.1）')]];
const CHOICES = {
  bind: BIND_CHOICES,
  subtitleLanguage: (s) => [['', T('自动（跟随每个视频的语言）')], ...(s.subtitleLanguageOptions||[]).map(o=>[o.code, `${o.name} (${o.code})`])],
  metadataLocale: (s) => (s.metadataLocaleOptions||[]).map(o=>[o.code, `${o.name} (${o.code})`]),
};
const OTHER = '__other';
// 下拉 + 「其他…」文本框；id 给下拉，文本框是 id-other。
function choiceCtl(id, opts, v){
  v = v ?? '';
  const other = !opts.some(([o])=>o===v);
  return `<div class="choice-ctl"><select id="${id}" data-choice="1">${opts.map(([o,l])=>`<option value="${esc(o)}" ${o===v?'selected':''}>${esc(l)}</option>`).join('')}<option value="${OTHER}" ${other?'selected':''}>${esc(T('其他…'))}</option></select><input type="text" id="${id}-other" value="${esc(other?v:'')}" aria-label="${esc(T('其他…'))}" ${other?'':'hidden'}></div>`;
}
function choiceValue(id){
  const sel=$('#'+id); if(!sel) return null;
  const v = sel.value===OTHER ? $('#'+id+'-other').value.trim() : sel.value;
  return v==='' ? null : v;
}
// 选了「其他…」才露文本框（设置页与复习页共用，事件委托到 document）。
document.addEventListener('change', (e)=>{
  const t=e.target; if(!(t instanceof HTMLSelectElement) || !t.dataset.choice) return;
  const box=$('#'+t.id+'-other'); if(!box) return;
  box.hidden = t.value!==OTHER; if(!box.hidden) box.focus();
});
// 字节数 ↔ 数字 + 单位：取能整除的最大单位，保存时乘回字节。
const BYTE_UNITS = [['TB',1024**4],['GB',1024**3],['MB',1024**2]];
function bytesCtl(id, v){
  const n = Number(v)||0;
  const [unit,size] = BYTE_UNITS.find(([,sz])=>n>0 && n%sz===0) || ['MB',1024**2];
  return `<div class="bytes-ctl"><input type="number" min="0" step="any" id="${id}" value="${esc(String(n/size))}"><select id="${id}-unit" aria-label="${esc(T('单位'))}">${BYTE_UNITS.map(([u])=>`<option value="${u}" ${u===unit?'selected':''}>${u}</option>`).join('')}</select></div>`;
}
function bytesValue(id){
  const size = (BYTE_UNITS.find(([u])=>u===$('#'+id+'-unit').value)||BYTE_UNITS[2])[1];
  return Math.round(Number($('#'+id).value)*size);
}
// AI 预设下拉的显示名；模型框的建议值跟着当前预设走。
const aiPresetLabel = (s, o) => o==='' ? T('不用 AI') : o==='custom' ? T('自定义') : ((s.aiPresetOptions||[]).find(x=>x.id===o)||{}).name || o;
function syncAiModelHint(){
  const s=settingsCache, sel=$('#f-ai-preset'), box=$('#f-ai-model'), list=$('#ai-model-list');
  if(!s||!sel||!box||!list) return;
  const m = ((s.aiPresetOptions||[]).find(x=>x.id===sel.value)||{}).model || '';
  box.placeholder = m; list.innerHTML = m ? `<option value="${esc(m)}">` : '';
}
let settingsCache=null, settingsBaseline=null;
async function loadSettings(){
  const s = await api('settings'); const first=!settingsCache; settingsCache=s;
  // 远程访问卡片有自己的保存键：主表单保存后只刷新 P2P 状态，不冲掉它未保存的编辑。
  if(first) renderRemoteReach(s); else renderP2pState(s.p2pStatus);
  if(first) renderSubtitleProviders(s.subtitleProviders);
  const found = s.torrent && s.torrent.embeddedLibraryFound;
  const setNote = (isSet) => isSet ? tag('ok', T('(已设置，留空不改)')) : '';
  const field = ([k,label,type]) => {
    let v = k.includes('.') ? (s[k.split('.')[0]]||{})[k.split('.')[1]] : s[k]; const id='f-'+k.replace('.','-');
    let extra = '';
    if(k==='torrent.library'&&!v) extra = tag(found?'ok':'warn', found ? T('已找到 {0}', found) : T('未找到随包库'));
    if(k==='ai.webKnowledge'&&!s.ai) v=true;
    if(k==='ai.preset'&&s.ai) extra = s.ai.status==='ready' ? tag('ok', T('可用')) : tag('warn', T('未配全：{0}', s.ai.problem||''));
    let ctl;
    let wrapped = false;
    if(type.startsWith('dyn:')) ctl = `<select id="${id}">${['',...(s[type.slice(4)]||[])].map(o=>`<option value="${esc(o)}" ${o===(v??'')?'selected':''}>${esc(k==='ai.preset'?aiPresetLabel(s,o):o)}</option>`).join('')}</select>`;
    else if(type.startsWith('choice:')){ ctl = choiceCtl(id, CHOICES[type.slice(7)](s), v); wrapped = true; }
    else if(type==='bytes'){ ctl = bytesCtl(id, v); wrapped = true; }
    else if(type==='aimodel') ctl = `<input type="text" id="${id}" list="ai-model-list" value="${esc(v??'')}" autocomplete="off"><datalist id="ai-model-list"></datalist>`;
    else if(type==='bool') ctl = `<span class="switch"><input type="checkbox" id="${id}" ${v?'checked':''}><span></span></span>`;
    else if(type.startsWith('seg:')) ctl = `<div class="segmented" id="${id}" role="radiogroup">${type.slice(4).split(',').map(o=>`<label><input type="radio" name="${id}" value="${esc(o)}" ${o===v?'checked':''}><span>${esc(LANGUAGE_NAMES[o]||o)}</span></label>`).join('')}</div>`;
    else if(type.startsWith('select:')) ctl = `<select id="${id}">${type.slice(7).split(',').map(o=>`<option value="${esc(o)}" ${o===v?'selected':''}>${esc(k==='language'?LANGUAGE_NAMES[o]:o)}</option>`).join('')}</select>`;
    else if(type==='password'){ extra += setNote(s.qbittorrent.passwordSet); ctl = `<input type="password" id="${id}" value="" autocomplete="off">`; }
    else if(type.startsWith('secret:')){ const sk=type.slice(7); const isSet = sk.includes('.') ? (s[sk.split('.')[0]]||{})[sk.split('.')[1]] : s[sk]; extra += setNote(isSet); ctl = `<input type="password" id="${id}" value="" autocomplete="off">`; }
    else ctl = `<input type="${type}" id="${id}" value="${esc(v??'')}">`;
    const [title, sub] = splitLabel(label);
    return `<div class="setting-row"><label class="setting-copy" for="${id}"><strong>${esc(title)}${RESTART.has(k)?tag('warn', T('需重启')):''}${extra}</strong>${sub?`<small>${esc(sub)}</small>`:''}</label><div class="setting-trail${type==='bool'?'':' is-field'}">${ctl}</div></div>`;
  };
  $('#settings-form').innerHTML = SETTING_GROUPS.map(([g,name])=>`<h3 class="kit-section-title">${esc(name)}</h3><div class="setting-list is-surface">${FIELDS.filter(f=>f[3]===g).map(field).join('')}</div>`).join('');
  syncAiModelHint(); const ps=$('#f-ai-preset'); if(ps) ps.addEventListener('change', syncAiModelHint);
  settingsBaseline = FIELDS.map(([k,,type])=>fieldValue(k,type));
  updateDirty();
}
// 空串本身是有效取值的下拉（字幕语言：空 = 自动），不能像别的字段那样把空当「没填」。
const EMPTY_IS_VALUE = new Set(['subtitleLanguage']);
// 表单里一项的当前值（与保存请求体同一套换算）。
function fieldValue(k, type){
  const id='f-'+k.replace('.','-');
  if(type.startsWith('seg:')) return (document.querySelector(`input[name="${id}"]:checked`)||{}).value;
  if(type.startsWith('choice:')) return choiceValue(id) ?? (EMPTY_IS_VALUE.has(k) ? '' : null);
  if(type==='bytes') return bytesValue(id);
  const el=$('#'+id); let v=el.value;
  if(type==='bool') v=el.checked; else if(type==='number') v=Number(v);
  if(type!=='bool'&&type!=='number'&&v==='') v=null;
  return v;
}
// 有未保存的更改才浮出保存条，并显示改了几项。
function updateDirty(){
  if(!settingsBaseline) return;
  const n = FIELDS.filter(([k,,type],i)=>fieldValue(k,type)!==settingsBaseline[i]).length;
  $('#savebar').hidden = n===0;
  $('#dirty-count').textContent = T('{0} 项未保存', n);
}
$('#settings-form').addEventListener('input', updateDirty);
$('#settings-form').addEventListener('change', updateDirty);
$('#btn-settings-discard').onclick = guard(loadSettings);
$('#btn-settings-save').onclick = guard(async()=>{
  const body={qbittorrent:{},torrent:{},ai:{}};
  for(const [k,,type] of FIELDS){ const v=fieldValue(k,type);
    if(k.includes('.')) body[k.split('.')[0]][k.split('.')[1]]=v; else body[k]=v; }
  // 路径类字段：空串代表「清掉」——但 copyWith 的 null 是「不改」，所以传空串让服务端按空处理
  for(const k of ['ffmpeg','ffprobe','onnxruntimeLibrary']) if(body[k]===null) delete body[k];
  $('#btn-settings-save').disabled=true;
  try{
    await put('settings',body);
    // 界面语言在出页时定：改了就重载。
    if (body.language && body.language !== LANG) { location.reload(); return; }
    toast(T('已保存')); loadSettings();
  } finally { $('#btn-settings-save').disabled=false; }
});

// ── 在线字幕来源（偏好表，保存即生效；key / 密码只报「设过没有」）──
const SUBS = [['opensubtitles',T('OpenSubtitles（不填 key 时用 app 内置 key）'),true],['subdl','SubDL',false],['jimaku','Jimaku',false]];
function renderSubtitleProviders(sp){
  sp = sp||{};
  const setNote = (isSet) => isSet ? ` <span class="muted">${esc(T('(已设置，留空不改)'))}</span>` : '';
  $('#subs-form').innerHTML = SUBS.map(([id,label,login])=>{ const x=sp[id]||{};
    const st = x.active ? tag('ok', T('生效中')) : tag('', T('未生效'));
    return `<div class="card-inset" data-subs="${esc(id)}"><div class="action-row"><b>${esc(label)}</b> ${st}${x.apiKeyFromEnv?` <span class="small muted">${esc(T('（环境变量里的 key 优先于这里存的）'))}</span>`:''}</div>
    <div class="form-grid"><label class="field">API key${setNote(x.apiKeySet)}<input type="password" data-k="apiKey" value="" autocomplete="off"></label>
    ${login?`<label class="field">${esc(T('用户名（可选）'))}<input type="text" data-k="username" value="${esc(x.username||'')}"></label><label class="field">${esc(T('密码'))}${setNote(x.passwordSet)}<input type="password" data-k="password" value="" autocomplete="off"></label>`:''}</div>
    <div class="action-row">${swLabel('data-k="enabled"', x.enabled!==false, T('启用'))}${x.apiKeySet?swLabel('data-k="clearApiKey"', false, T('清除已存的 key')):''}${login&&x.passwordSet?swLabel('data-k="clearPassword"', false, T('清除已存的密码')):''}</div></div>`; }).join('');
}
$('#btn-subs-save').onclick = guard(async()=>{
  const body={};
  for(const card of document.querySelectorAll('[data-subs]')){
    const v=(k)=>card.querySelector(`[data-k="${k}"]`); const o={enabled: v('enabled').checked};
    if(v('apiKey').value) o.apiKey=v('apiKey').value;
    const ck=v('clearApiKey'); if(ck&&ck.checked) o.clearApiKey=true;
    const u=v('username'); if(u) o.username=u.value;
    const pw=v('password'); if(pw&&pw.value) o.password=pw.value;
    const cp=v('clearPassword'); if(cp&&cp.checked) o.clearPassword=true;
    body[card.dataset.subs]=o;
  }
  const s = await put('settings',{subtitleProviders:body}); settingsCache=s; renderSubtitleProviders(s.subtitleProviders); toast(T('已保存并生效'));
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
      + (st.lastError?`<br><span style="color:var(--md-sys-color-error)">${esc(st.lastError)}</span>`:'');
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
  $('#ai-sessions').innerHTML = r.sessions.map(s=>`<div class="setting-row is-clickable${s.id===aiOpen?' is-selected':''}" data-ai="${esc(s.id)}" tabindex="0" role="button"><div class="list-lead">${icon('ai')}</div><div class="setting-copy"><strong>${esc(s.title||T('新对话'))}</strong><small>${esc(aiDevice(s))} · ${esc(fmtTime(s.updatedAt))} · ${esc(s.tokens)} tokens</small></div>${icon('chevron','chev')}</div>`).join('') || empty(T('还没有 AI 助手会话'), 'ai');
  $('#ai-sessions').querySelectorAll('[data-ai]').forEach(el=>{ const open = guard(async()=>{ aiOpen=el.dataset.ai; await loadAiDetail(); $('#ai-sessions').querySelectorAll('[data-ai]').forEach(x=>x.classList.toggle('is-selected', x===el)); }); el.onclick=open; el.onkeydown=(e)=>{ if(e.key==='Enter'||e.key===' '){ e.preventDefault(); open(); } }; });
  if (aiOpen) await loadAiDetail();
}
async function loadAiDetail(){
  const s = await api('ai/sessions/'+encodeURIComponent(aiOpen));
  $('#ai-detail').style.display='block';
  $('#ai-detail-title').textContent = s.title || T('新对话');
  $('#ai-detail-meta').textContent = `${aiDevice(s)} · ${fmtTime(s.createdAt)} → ${fmtTime(s.updatedAt)} · ${s.tokens} tokens`;
  $('#ai-entries').innerHTML = s.entries.map(e=>`<div class="entry">${tag(e.kind==='assistant'?'info':'', AI_KIND[e.kind]||e.kind)}<div>${esc(e.toolName?e.toolName+(e.text?' — '+e.text:''):(e.text||''))} ${e.status&&e.kind!=='user'&&e.kind!=='assistant'?stTag(e.status):''} ${e.errorCode?`<span class="small" style="color:var(--md-sys-color-error)">${esc(e.errorCode)}</span>`:''}</div></div>`).join('') || empty(T('无'));
}

// ── 词典 ──
// 清单要统计每本词典目录的占用（遍历文件），而且行里有就地编辑的输入框：不跟 2.5 秒轮询走，
// 进页时拉一次；改动类端点回整份 GET 回包，直接拿它重绘。
let dictsLoaded=false;
const DICT_TYPE = {term:T('术语'), frequency:T('频率'), pitch:T('音调'), kanji:T('汉字')};
// 与 app 的内容语言选择器同一组常用标签（content_language_picker.dart 的 kContentLanguageOptions）。
const DICT_LANGS = [['ja',T('日语 (ja)')], ['zh-Hans',T('简体中文 (zh-Hans)')], ['zh-Hant',T('繁体中文 (zh-Hant)')], ['ko',T('韩语 (ko)')], ['en',T('英语 (en)')]];
const langLabel = (code) => { const o = DICT_LANGS.find(([c])=>c===code); return o ? o[1] : code; };
const LANG_TAG_RE = /^[A-Za-z0-9-]{2,35}$/;
// BCP-47 大小写规范化（同 app 的 canonicalDictionaryLanguageTag）：主语言小写、4 字母文字子标签首字母大写、地区大写，下划线当连字符。
function canonLang(v){
  const parts = String(v||'').trim().split(/[-_]+/).filter(Boolean);
  if (!parts.length) return '';
  return [parts[0].toLowerCase(), ...parts.slice(1).map(p=>/^[A-Za-z]{4}$/.test(p) ? p[0].toUpperCase()+p.slice(1).toLowerCase() : (/^([A-Za-z]{2}|\d{3})$/.test(p) ? p.toUpperCase() : p.toLowerCase()))].join('-');
}
let dictNames = [];
// PATCH /api/admin/dictionaries/<名>：任意几项（defaultEnabled / languageOverride / displayName），回整份清单。
const patchDict = (name, body) => api('dictionaries/'+encodeURIComponent(name), {method:'PATCH', body:JSON.stringify(body)});
function dictLangSelect(d){
  const cur = d.languageOverride || '';
  const opts = [['', d.packageLanguage ? T('自动（包内声明：{0}）', langLabel(d.packageLanguage)) : T('自动（包内未声明）')], ...DICT_LANGS];
  if (cur && !opts.some(([c])=>c===cur)) opts.push([cur, cur]);
  opts.push(['__other', T('其他…')]);
  return `<select class="dict-lang" data-dict-lang="${esc(d.name)}" aria-label="${esc(T('词典语言'))}" title="${esc(T('词典语言'))}">${opts.map(([c,l])=>`<option value="${esc(c)}"${c===cur?' selected':''}>${esc(l)}</option>`).join('')}</select><input type="text" class="dict-lang-other" data-dict-lang-other="${esc(d.name)}" placeholder="${esc(T('BCP-47 标签，如 de、pt-BR'))}" aria-label="${esc(T('词典语言'))}" hidden>`;
}
function dictRow(d, i, n){
  const label = d.displayName || d.name;
  const lang = d.sourceLanguage ? tag(d.languageOverride ? 'info' : '', d.sourceLanguage) : tag('warn', T('未标注语言'));
  const meta = [DICT_TYPE[d.type]||d.type, d.formatKey, d.revision ? T('版本 {0}', d.revision) : '', d.present ? fmtBytes(d.sizeBytes) : ''].filter(Boolean).join(' · ');
  return `<div class="setting-row"><div class="list-lead">${icon('dictionaries')}</div><div class="setting-copy"><strong><span class="dict-label"${label!==d.name?` title="${esc(d.name)}"`:''}>${esc(label)}</span><button class="icon-button is-small" data-dict-rename="${esc(d.name)}" title="${esc(T('修改显示名'))}" aria-label="${esc(T('修改显示名'))}">${icon('edit')}</button><input type="text" class="dict-name-edit" data-dict-name-edit="${esc(d.name)}" data-current="${esc(d.displayName||'')}" maxlength="200" placeholder="${esc(d.name)}" aria-label="${esc(T('显示名'))}" title="${esc(T('回车保存，Esc 取消，留空恢复原名'))}" hidden>${lang}${d.present?'':tag('err', T('文件缺失'))}</strong><small>${esc(meta)}</small>${label!==d.name?`<small class="mono">${esc(d.name)}</small>`:''}</div><div class="setting-trail more">${dictLangSelect(d)}<label class="switch-row"><span>${esc(T('默认启用'))}</span><span class="switch"><input type="checkbox" data-dict-default="${esc(d.name)}"${d.defaultEnabled?' checked':''}><span></span></span></label><button class="icon-button" data-mv="-1" data-i="${i}" ${i===0?'disabled':''} title="${esc(T('上移'))}" aria-label="${esc(T('上移'))}">${icon('up')}</button><button class="icon-button" data-mv="1" data-i="${i}" ${i===n-1?'disabled':''} title="${esc(T('下移'))}" aria-label="${esc(T('下移'))}">${icon('down')}</button><button class="icon-button" data-more title="${esc(T('更多'))}" aria-label="${esc(T('更多'))}" aria-haspopup="menu" aria-expanded="false">${icon('more')}</button><div class="kit-menu" role="menu" hidden><button role="menuitem" class="kit-menu-item danger-button" data-drm="${esc(d.name)}" data-label="${esc(label)}">${esc(T('删除'))}</button></div></div></div>`;
}
async function loadDictionaries(){ renderDictionaries(await api('dictionaries')); }
function renderDictionaries(r){
  dictsLoaded=true;
  const e = r.engine || {};
  $('#dict-engine').innerHTML = kvHtml([
    [T('引擎'), e.available ? tag('ok', T('已加载')) : tag('err', e.reason ? T('不可用：{0}', e.reason) : T('不可用')), true],
    [T('已装载'), e.available ? T('{0} 本', e.loadedCount) : '—'],
    [T('变形表（去屈折）'), e.transformsLoaded ? tag('ok', T('已加载')) : `<span style="color:var(--md-sys-color-error)">${esc(T('缺失：只能查原形（设 FUSHI_TRANSFORMS_DIR 或随包放 share/fushi/transforms）'))}</span>`, true],
    [T('原生库'), e.libraryPath || T('默认搜索路径')],
  ]);
  $('#btn-dict-reload').disabled = !e.available;
  const rows = r.dictionaries || [];
  dictNames = rows.map(d=>d.name);
  const list = $('#dicts');
  list.innerHTML = rows.map((d,i)=>dictRow(d, i, rows.length)).join('') || empty(T('服务端还没有词典。在上面导入词典包，或在 Fushi app 的词典管理里推送到服务器。'), 'dictionaries');
  bindMoreMenus(list);
  list.querySelectorAll('[data-mv]').forEach(b=>b.onclick=guard(async()=>{ const i=Number(b.dataset.i), j=i+Number(b.dataset.mv); const names=dictNames.slice(); [names[i],names[j]]=[names[j],names[i]]; renderDictionaries(await put('dictionaries/order',{names})); }));
  list.querySelectorAll('[data-dict-default]').forEach(c=>c.onchange=async()=>{
    const on=c.checked; c.disabled=true;
    try{ const r2 = await patchDict(c.dataset.dictDefault, {defaultEnabled:on}); toast(on?T('已默认启用'):T('已默认停用')); renderDictionaries(r2); }
    catch(err){ c.checked=!on; c.disabled=false; toast(T('失败: {0}', err.message), true); }
  });
  list.querySelectorAll('[data-dict-lang]').forEach(sel=>{
    const prev = sel.value; const other = sel.nextElementSibling;
    const name = sel.dataset.dictLang;
    const apply = async(v)=>{ const r2 = await patchDict(name, {languageOverride: v || null}); toast(v ? T('词典语言已设为 {0}', langLabel(v)) : T('词典语言已恢复自动')); renderDictionaries(r2); };
    sel.onchange = guard(async()=>{
      if (sel.value==='__other'){ other.hidden=false; other.value=prev; other.focus(); return; }
      other.hidden=true; sel.disabled=true;
      try{ await apply(sel.value); }
      catch(err){ sel.value=prev; sel.disabled=false; throw err; }
    });
    // 自定义标签：回车或失焦提交；留空或没改就收起，下拉回到原值。
    const submit = guard(async()=>{
      if (other.hidden || other.disabled) return;
      const v = canonLang(other.value);
      if (!v || v===prev){ other.hidden=true; sel.value=prev; return; }
      if (!LANG_TAG_RE.test(v)) throw new Error(T('语言标签无效：{0}', v));
      other.disabled=true; sel.disabled=true;
      try{ await apply(v); }
      catch(err){ other.disabled=false; sel.disabled=false; throw err; }
    });
    other.onkeydown = (ev)=>{ if(ev.key==='Enter'){ ev.preventDefault(); submit(); } else if(ev.key==='Escape'){ other.hidden=true; sel.value=prev; sel.focus(); } };
    other.onblur = submit;
  });
  // 显示名：铅笔 → 就地文本框；回车或失焦保存，Esc 取消；留空或填回原名 = 清掉覆盖名。
  list.querySelectorAll('[data-dict-rename]').forEach(b=>{
    const input = b.nextElementSibling; const label = b.previousElementSibling;
    const name = b.dataset.dictRename; const cur = input.dataset.current;
    const close = ()=>{ input.hidden=true; label.hidden=false; b.hidden=false; };
    b.onclick = ()=>{ label.hidden=true; b.hidden=true; input.hidden=false; input.value = cur || name; input.focus(); input.select(); };
    const submit = guard(async()=>{
      if (input.hidden || input.disabled) return;
      let v = input.value.trim(); if (v===name) v='';
      if (v===cur){ close(); return; }
      input.disabled=true;
      try{ const r2 = await patchDict(name, {displayName: v || null}); toast(v ? T('显示名已改为「{0}」', v) : T('已恢复原名')); renderDictionaries(r2); }
      catch(err){ input.disabled=false; throw err; }
    });
    input.onkeydown = (ev)=>{ if(ev.key==='Enter'){ ev.preventDefault(); submit(); } else if(ev.key==='Escape'){ ev.preventDefault(); close(); b.focus(); } };
    input.onblur = submit;
  });
  list.querySelectorAll('[data-drm]').forEach(b=>b.onclick=guard(async()=>{
    if(!await ask(T('删除词典「{0}」？会删掉服务端上的词典文件，用它查词的设备将查不到它（不影响各设备本地的词典）。', b.dataset.label), true)) return;
    const r2 = await del('dictionaries/'+encodeURIComponent(b.dataset.drm)); toast(T('已删除')); renderDictionaries(r2);
  }));
}
// 导入：PUT 整个文件（XHR 才有上传进度），文件名放 ?filename= 让服务端按扩展名认格式。
function uploadDictionary(file, onProgress){
  return new Promise((resolve, reject)=>{
    const x = new XMLHttpRequest();
    x.open('PUT', '/api/admin/dictionaries?filename='+encodeURIComponent(file.name));
    x.setRequestHeader('Content-Type', 'application/octet-stream');
    x.upload.onprogress = (ev)=>{ if(ev.lengthComputable) onProgress(ev.loaded/ev.total); };
    x.upload.onload = ()=>onProgress(1);
    x.onload = ()=>{ if(x.status===401){ location.reload(); return; } let j={}; try{ j=JSON.parse(x.responseText); }catch(e){} if(x.status>=200&&x.status<300) resolve(j); else reject(new Error(j.error||('HTTP '+x.status))); };
    x.onerror = ()=>reject(new Error(T('网络错误')));
    x.send(file);
  });
}
// 可一次选 / 拖入多个词典：逐个顺序 PUT（复用单文件端点），一个失败不影响其余；结束后统一报
// 成功 / 失败清单、只刷新一次清单。失败的文件留在选择框里，可直接再点「导入」重试。
$('#btn-dict-up').onclick = guard(async()=>{
  const input=$('#dict-file'), files=Array.from(input.files); if(!files.length) throw new Error(T('先选择一个词典文件'));
  const btn=$('#btn-dict-up'), st=$('#dict-up-state'); btn.disabled=true; st.style.color=''; st.style.whiteSpace='pre-line';
  const many=files.length>1, done=[], failed=[];
  const describe = (r)=>{ const args=[r.name, DICT_TYPE[r.type]||r.type, r.termCount, r.kanjiCount?T('，{0} 汉字', r.kanjiCount):'']; return r.replaced ? T('已更新「{0}」（{1}，{2} 词条{3}）', ...args) : T('已导入「{0}」（{1}，{2} 词条{3}）', ...args); };
  try{
    for (const [i, f] of files.entries()){
      const prefix = many ? T('（{0}/{1}）{2}：', i+1, files.length, f.name) : '';
      try{
        const r = await uploadDictionary(f, (p)=>{ st.textContent = prefix + (p<1 ? T('上传中 {0}%', Math.round(p*100)) : T('导入中…（大词典要几分钟）')); });
        done.push(describe(r));
      }catch(e){ failed.push({file:f, error:e.message}); }
    }
    const keep = new DataTransfer(); failed.forEach(x=>keep.items.add(x.file)); input.files = keep.files; input.dispatchEvent(new Event('change'));
    if (done.length) await loadDictionaries();
    if (!many){
      if (failed.length){ st.style.color='var(--md-sys-color-error)'; st.textContent=T('导入失败：{0}', failed[0].error); throw new Error(failed[0].error); }
      st.textContent=done[0]; toast(st.textContent); return;
    }
    const head = T('导入完成：{0} 个成功，{1} 个失败', done.length, failed.length);
    st.textContent = [head, ...done, ...failed.map(x=>T('「{0}」导入失败：{1}', x.file.name, x.error))].join('\n');
    if (failed.length){ st.style.color='var(--md-sys-color-error)'; throw new Error(head); }
    toast(head);
  }finally{ btn.disabled=false; }
});
$('#btn-dict-reload').onclick = guard(async()=>{
  $('#btn-dict-reload').disabled=true;
  try{ const r=await post('dictionaries/reload'); toast(T('已重新装载，{0} 本', (r.engine||{}).loadedCount||0)); renderDictionaries(r); }
  catch(e){ await loadDictionaries(); throw e; }
});
async function dictLookup(){
  const q = $('#dict-q').value.trim(); if(!q) return;
  const r = await api('dictionaries/lookup?q='+encodeURIComponent(q));
  const head = r.searchTerm && r.searchTerm!==q ? `<p class="note" style="margin:12px 4px">${esc(T('按「{0}」查', r.searchTerm))}</p>` : '';
  $('#dict-results').innerHTML = head + `<div class="setting-list is-surface">${r.entries.map(e=>`<div class="setting-row" style="align-items:flex-start"><div class="setting-copy"><strong>${esc(e.word)}${e.reading&&e.reading!==e.word?` <span class="muted">${esc(e.reading)}</span>`:''}${tag('info', e.dictionary)}</strong><small style="white-space:pre-wrap">${esc(e.meaning)}</small></div></div>`).join('') || empty(T('没有结果'), 'search')}</div>`;
}
$('#btn-dict-q').onclick = guard(dictLookup);
$('#dict-q').onkeydown = (ev)=>{ if(ev.key==='Enter') guard(dictLookup)(); };

// ── 日志 ──
// 一条日志可能跨多行（堆栈 / ffmpeg 输出）：续行跟随它前面那条的级别。
const LOG_HEAD = /^\d{4}-\d\d-\d\dT\S+ \[(\w+)\]/;
let logLines = [];
function logLevel(tag){ return tag==='error'||tag==='fatal' ? 'error' : ''; }
function renderLogs(){
  const pre=$('#logs'); const atBottom = pre.scrollTop+pre.clientHeight >= pre.scrollHeight-10;
  const onlyProblems = (document.querySelector('input[name="log-lv"]:checked')||{}).value==='problems';
  let lv='', problems=0; const out=[];
  for(const line of logLines){
    const m = LOG_HEAD.exec(line); if(m){ lv = logLevel(m[1]); if(lv) problems++; }
    if(onlyProblems && !lv) continue;
    out.push(lv ? `<span class="lv-${lv}">${esc(line)}</span>` : esc(line));
  }
  pre.innerHTML = out.join('\n') || esc(onlyProblems ? T('没有错误') : '');
  $('#log-lv-problems').textContent = T('仅错误') + (problems ? ` (${problems})` : '');
  if(atBottom) pre.scrollTop=pre.scrollHeight;
}
async function loadLogs(){ const r = await api('logs'); logLines = r.lines; renderLogs(); }
document.querySelectorAll('input[name="log-lv"]').forEach(x=>x.onchange=renderLogs);
$('#btn-log-refresh').onclick = guard(loadLogs);

// ── 轮询 ──
const loaders = {status:loadStatus, pairing:loadPairing, libraries:loadLibraries, dictionaries:async()=>{ if(!dictsLoaded) await loadDictionaries(); }, upload:async()=>{ await loadLibraries(); const s=await api('status'); $('#up-quota').textContent=T('配额已用 {0} / {1}', fmtBytes(s.uploadUsedBytes), fmtBytes(s.uploadQuotaBytes)); }, jobs:loadJobs, downloads:loadDownloads, subscriptions:async()=>{ await loadSubscriptions(); await loadIndexers(false); }, ai:loadAi, anki:loadAnki, srs:loadSrs, models:loadModels, settings:async()=>{ if(!settingsCache) await loadSettings(); else renderP2pState(await api('p2p')); }, logs:async()=>{ if($('#log-auto').checked) await loadLogs(); }};
let busy=false;
async function refresh(){ if(busy) return; busy=true; try{ await loaders[current](); }catch(e){ console.warn(e); } finally{ busy=false; } }
const startPage = location.hash.slice(1);
if (startPage && startPage!=='status' && navButtons.some(b=>b.dataset.s===startPage)) go(startPage, false); else refresh();
setInterval(refresh, 2500);
window.addEventListener('hashchange', ()=>{ const h=location.hash.slice(1); if (h && h!==current) go(h, false); });
// 配对 PIN 不管在哪个页都要能看见：标题栏闪提示 + 导航红点
setInterval(async()=>{ if(current==='pairing') return; try{ const p=await api('pairing'); setPairBadge(p.pending); if(p.pending){ document.title=T('★ 配对 PIN {0} — fushi_server', p.pending.pin); } else document.title='fushi_server'; }catch(e){} }, 3000);
</script>
</body></html>''';

/// 登录页里要翻的两段（`__T_<中文>__` 占位，见 [renderAdminLogin]）。
final RegExp _loginTextSlot = RegExp(r'__T_(.+?)__', dotAll: true);

/// `<html lang>` 值。
String _htmlLang(String language) =>
    language == ServerConfig.languageChinese ? 'zh-CN' : 'en';

/// 按界面语言出 WebUI 主页：填 `<html lang>`、页面脚本里的 `LANG` 与英文表 `EN`
/// （中文界面给空表，`T()` 原样返回中文），以及内嵌图标。
String renderAdminWebUi(String language) {
  final bool en = language == ServerConfig.languageEnglish;
  return adminWebUiHtml
      .replaceFirst('__FUSHI_HTML_LANG__', _htmlLang(language))
      .replaceFirst("'__FUSHI_LANG__'", jsonEncode(language))
      .replaceFirst('__FUSHI_EN__', en ? jsonEncode(kWebUiEnglish) : '{}')
      .replaceFirst(
        '__FUSHI_BT_PARSER_TEMPLATE__',
        const HtmlEscape().convert(kBtSiteParserRuleTemplate),
      )
      .replaceFirst('__FUSHI_KIT_HEAD__', webKitHeadTags())
      .replaceFirst('__FUSHI_KIT_BODY__', webKitBodyScripts())
      .replaceAll('__FUSHI_LOGO__', kWebUiLogoDataUri);
}

/// 按界面语言出登录页；[tokenError] = 上次提交的 token 不对。
String renderAdminLogin(String language, {bool tokenError = false}) {
  final bool en = language == ServerConfig.languageEnglish;
  String t(String zh) => en ? (kWebUiEnglish[zh] ?? zh) : zh;
  String html = adminLoginHtml
      .replaceFirst('__FUSHI_HTML_LANG__', _htmlLang(language))
      .replaceFirst('__FUSHI_KIT_HEAD__', webKitHeadTags())
      .replaceAll('__FUSHI_LOGO__', kWebUiLogoDataUri)
      .replaceAllMapped(_loginTextSlot, (Match m) => t(m.group(1)!));
  if (tokenError) {
    html = html.replaceFirst(
      '<!--error-->',
      '<p class="err">${t('Token 不正确')}</p>',
    );
  }
  return html;
}
