/// WebUI 静态页：一个 HTML 字符串，原生 JS，无构建步骤、无第三方脚本、无外链字体。
///
/// 页面只吃 `/api/admin/*` JSON；所有状态都轮询（2~5 秒），不做 WebSocket——
/// 单管理员局域网面板，轮询足够且没有连接状态机要维护。
///
/// 视觉跟 Fushi app 走同一套 MD3 / M3 Expressive 语言：色板是 app 默认主题
/// （seed `#1F4959`、vibrant 方案，`kFushiDefaultSeed`）用 material_color_utilities
/// 算出的亮 / 暗两套角色色；圆角取 `FushiRadii`（分组 20、卡片 / 控件 12、chip 6、
/// 对话框 28）；导航选中项是 M3E 多边形而不是药丸（同 `kNavRailFallbackShapes`）。
///
/// 界面语言来自配置 `language`（`en` / `zh`），在出页时定：[renderAdminWebUi] /
/// [renderAdminLogin]。源文案是中文，英文在 `web_ui_en.dart` 的 [kWebUiEnglish]
/// （键 = 中文原文）；`web_ui_i18n_test.dart` 保证页面里每条中文都有英文。
library;

import 'dart:convert';

import 'package:fushi_server/src/admin/web_ui_assets.dart';
import 'package:fushi_server/src/admin/web_ui_en.dart';
import 'package:fushi_server/src/config/server_config.dart';

/// 两页共用：主题色 token（亮色在 `:root`，暗色在系统偏好 / `data-theme` 下重定义）
/// 与基础排版。主题选择存在 localStorage，`<script id="boot">` 在首帧前套上。
const String _kThemeHead =
    r'''<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="color-scheme" content="light dark">
<link rel="icon" type="image/png" href="__FUSHI_LOGO__">
<script id="boot">try{var t=localStorage.getItem('fushi-admin-theme');if(t==='light'||t==='dark')document.documentElement.setAttribute('data-theme',t);}catch(e){}</script>
<style>
:root{
--primary:#006782;--on-primary:#ffffff;--primary-container:#bbe9ff;--on-primary-container:#004d63;
--secondary-container:#cce5ff;--on-secondary-container:#2d4960;
--tertiary-container:#d6e3ff;--on-tertiary-container:#2c4770;
--error:#ba1a1a;--on-error:#ffffff;--error-container:#ffdad6;--on-error-container:#93000a;
--ok-container:#c9ecd2;--on-ok-container:#0f5129;--warn-container:#ffe08f;--on-warn-container:#574400;
--surface:#f3faff;--on-surface:#121d22;--on-surface-variant:#3b494f;
--sc-lowest:#ffffff;--sc-low:#eaf5fc;--sc:#e4f0f6;--sc-high:#dfeaf0;--sc-highest:#d9e4eb;
--outline:#6b7980;--outline-variant:#bac9d1;--inverse-surface:#273237;--inverse-on-surface:#e7f2f9;--inverse-primary:#60d4ff;
--scrim:rgba(0,0,0,.32);
--font:system-ui,-apple-system,"Segoe UI",Roboto,"Noto Sans","Noto Sans SC","PingFang SC","Microsoft YaHei",sans-serif;
--mono:ui-monospace,"Cascadia Mono","SF Mono","Roboto Mono",Menlo,monospace;
--r-group:20px;--r-card:12px;--r-control:12px;--r-chip:6px;--r-menu:16px;--r-dialog:28px;
--ease:cubic-bezier(.2,0,0,1);--ease-decel:cubic-bezier(.05,.7,.1,1);--spring:cubic-bezier(.34,1.56,.64,1);
--err:var(--error);--line:var(--outline-variant);
color-scheme:light}
@media (prefers-color-scheme: dark){:root:not([data-theme="light"]){
--primary:#60d4ff;--on-primary:#003545;--primary-container:#004d63;--on-primary-container:#bbe9ff;
--secondary-container:#2d4960;--on-secondary-container:#cce5ff;
--tertiary-container:#2c4770;--on-tertiary-container:#d6e3ff;
--error:#ffb4ab;--on-error:#690005;--error-container:#93000a;--on-error-container:#ffdad6;
--ok-container:#1d4d31;--on-ok-container:#a6f0bd;--warn-container:#4d3a00;--on-warn-container:#ffe08f;
--surface:#0a1519;--on-surface:#d9e4eb;--on-surface-variant:#bac9d1;
--sc-lowest:#051014;--sc-low:#121d22;--sc:#172126;--sc-high:#212b30;--sc-highest:#2c363b;
--outline:#84939a;--outline-variant:#3b494f;--inverse-surface:#d9e4eb;--inverse-on-surface:#273237;--inverse-primary:#006782;
--scrim:rgba(0,0,0,.5);color-scheme:dark}}
:root[data-theme="dark"]{
--primary:#60d4ff;--on-primary:#003545;--primary-container:#004d63;--on-primary-container:#bbe9ff;
--secondary-container:#2d4960;--on-secondary-container:#cce5ff;
--tertiary-container:#2c4770;--on-tertiary-container:#d6e3ff;
--error:#ffb4ab;--on-error:#690005;--error-container:#93000a;--on-error-container:#ffdad6;
--ok-container:#1d4d31;--on-ok-container:#a6f0bd;--warn-container:#4d3a00;--on-warn-container:#ffe08f;
--surface:#0a1519;--on-surface:#d9e4eb;--on-surface-variant:#bac9d1;
--sc-lowest:#051014;--sc-low:#121d22;--sc:#172126;--sc-high:#212b30;--sc-highest:#2c363b;
--outline:#84939a;--outline-variant:#3b494f;--inverse-surface:#d9e4eb;--inverse-on-surface:#273237;--inverse-primary:#006782;
--scrim:rgba(0,0,0,.5);color-scheme:dark}
*{box-sizing:border-box}
html,body{height:100%}
body{margin:0;font-family:var(--font);font-size:14px;line-height:1.45;background:var(--surface);color:var(--on-surface);transition:background-color .3s var(--ease),color .3s var(--ease);-webkit-font-smoothing:antialiased}
button,input,select,textarea{font:inherit;color:inherit}
:focus-visible{outline:2px solid var(--primary);outline-offset:2px}
code{font-family:var(--mono);font-size:.92em;background:var(--sc-highest);padding:1px 6px;border-radius:4px;overflow-wrap:anywhere}
input[type=text],input[type=number],input[type=password],input:not([type]),select,textarea{height:48px;border-radius:var(--r-control);border:1px solid var(--outline);background:var(--sc-lowest);color:var(--on-surface);padding:0 14px;font-size:15px;min-width:0;width:100%;transition:border-color .15s,box-shadow .15s}
textarea{height:auto;padding:12px 14px;font-family:var(--mono);font-size:13px;resize:vertical}
input:focus,select:focus,textarea:focus{outline:0;border-color:var(--primary);box-shadow:inset 0 0 0 1px var(--primary)}
input:disabled,select:disabled{opacity:.5}
input[type=checkbox],input[type=radio]{accent-color:var(--primary);width:18px;height:18px;margin:0;cursor:pointer}
.b{height:40px;padding:0 20px;border-radius:999px;border:0;display:inline-flex;align-items:center;justify-content:center;gap:8px;cursor:pointer;font-weight:500;font-size:14px;white-space:nowrap;background:var(--primary);color:var(--on-primary);transition:transform .15s var(--ease),box-shadow .15s,background-color .15s,opacity .15s}
.b svg.i{width:18px;height:18px;margin-left:-4px}
.b:hover{box-shadow:0 1px 3px rgba(0,0,0,.22)}
.b:active{transform:scale(.96)}
.b.sec{background:var(--secondary-container);color:var(--on-secondary-container)}
.b.danger{background:var(--error-container);color:var(--on-error-container)}
.b.out{background:none;border:1px solid var(--outline);color:var(--primary)}
.b.text{background:none;color:var(--primary);padding:0 12px}
.b.text.danger{color:var(--error)}
.b.sec:hover,.b.out:hover,.b.text:hover,.b.danger:hover{box-shadow:none;background-image:linear-gradient(color-mix(in srgb,currentColor 8%,transparent),color-mix(in srgb,currentColor 8%,transparent))}
.b:disabled{opacity:.38;cursor:default;transform:none;box-shadow:none}
@media (prefers-reduced-motion: reduce){*,*::before,*::after{animation:none!important;transition:none!important}}
</style>''';

const String adminLoginHtml =
    r'''<!doctype html>
<html lang="__FUSHI_HTML_LANG__"><head>
<title>fushi_server</title>
''' +
    _kThemeHead +
    r'''
<style>
body{display:flex;align-items:center;justify-content:center;padding:24px 16px}
form{width:100%;max-width:400px;background:var(--sc-low);border-radius:var(--r-dialog);padding:32px 28px;display:flex;flex-direction:column;gap:16px;animation:pop .35s var(--ease-decel) both}
.logo{width:56px;height:56px;border-radius:16px;display:block}
h1{margin:0;font-size:28px;font-weight:400;line-height:36px}
.err{margin:0;background:var(--error-container);color:var(--on-error-container);border-radius:var(--r-card);padding:10px 14px;font-size:13px}
.b{height:48px;width:100%}
.hint{margin:0;color:var(--on-surface-variant);font-size:12px;line-height:1.6}
@keyframes pop{from{opacity:0;transform:scale(.94)}}
</style></head><body>
<form method="post" action="/login">
<img class="logo" src="__FUSHI_LOGO__" alt="">
<h1>fushi_server</h1>
<!--error-->
<input type="password" name="token" placeholder="admin_token" autofocus autocomplete="current-password" aria-label="admin_token">
<button class="b" type="submit">__T_登录__</button>
<p class="hint">__T_token 在 fushi_server.yaml 的 admin_token；忘了用 <code>fushi_server admin reset-token</code> 重生成。__</p>
</form></body></html>''';

const String adminWebUiHtml =
    r'''<!doctype html>
<html lang="__FUSHI_HTML_LANG__"><head>
<title>fushi_server</title>
''' +
    _kThemeHead +
    r'''
<style>
svg.i{width:24px;height:24px;fill:currentColor;flex:none}
.app{height:100%;display:grid;grid-template-columns:88px minmax(0,1fr);grid-template-rows:64px minmax(0,1fr)}
/* ── 导航栏（宽屏侧栏，窄屏抽屉）── */
.rail{grid-row:1/3;display:flex;flex-direction:column;align-items:center;gap:2px;padding:12px 0 16px;overflow-y:auto;scrollbar-width:none;background:var(--surface);z-index:5}
.rail::-webkit-scrollbar{display:none}
.brand{display:flex;align-items:center;gap:12px;margin-bottom:8px;flex:none}
.brand img{width:40px;height:40px;border-radius:14px;display:block}
.brand span{display:none;font-size:18px;font-weight:500}
.rail hr{width:40px;border:0;border-top:1px solid var(--outline-variant);margin:4px 0;flex:none}
.rail button{width:80px;flex:none;border:0;background:none;display:flex;flex-direction:column;align-items:center;gap:2px;padding:2px 0 4px;cursor:pointer;color:var(--on-surface-variant);font-size:12px;font-weight:500;line-height:16px;text-align:center}
.ind{position:relative;width:56px;height:32px;display:grid;place-items:center;flex:none}
.ind::before{content:"";position:absolute;inset:0;border-radius:16px;background:var(--on-surface);opacity:0;transition:opacity .15s}
.rail button:hover .ind::before{opacity:.08}
.ind svg.shape{position:absolute;left:50%;top:50%;width:46px;height:46px;margin:-23px 0 0 -23px;fill:var(--secondary-container);transform:scale(.2) rotate(-60deg);opacity:0;transition:transform .5s var(--spring),opacity .15s}
.ind svg.i{position:relative;z-index:1}
.rail button.on{color:var(--on-surface)}
.rail button.on .ind{color:var(--on-secondary-container)}
.rail button.on .ind svg.shape{transform:none;opacity:1}
.badge{position:absolute;z-index:2;top:2px;right:12px;width:8px;height:8px;border-radius:50%;background:var(--error)}
.scrim-nav{display:none}
/* ── 顶栏 ── */
.topbar{grid-column:2;display:flex;align-items:center;gap:4px;padding:0 12px 0 24px;min-width:0}
.topbar .menu{display:none}
.ttl{flex:1;min-width:0;display:flex;flex-direction:column}
.ttl h1{margin:0;font-size:22px;font-weight:400;line-height:28px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.ttl span{font-size:12px;color:var(--on-surface-variant);white-space:nowrap;overflow:hidden;text-overflow:ellipsis;font-variant-numeric:tabular-nums}
.icon-btn{width:40px;height:40px;flex:none;border-radius:50%;border:0;background:none;display:grid;place-items:center;cursor:pointer;color:var(--on-surface-variant);transition:background-color .15s}
.icon-btn:hover{background:color-mix(in srgb,var(--on-surface) 8%,transparent)}
.topbar form{margin:0}
/* ── 内容 ── */
main{grid-column:2;overflow-y:auto;padding:4px 24px 48px}
section{display:none;max-width:1040px;flex-direction:column;gap:16px}
section.on{display:flex}
section.on > *{animation:enter .42s var(--ease-decel) both}
section.on > :nth-child(2){animation-delay:30ms}section.on > :nth-child(3){animation-delay:60ms}section.on > :nth-child(4){animation-delay:90ms}section.on > :nth-child(5){animation-delay:120ms}section.on > :nth-child(n+6){animation-delay:150ms}
@keyframes enter{from{opacity:0;transform:translateY(12px)}}
.sh{display:flex;align-items:center;gap:8px;margin:8px 4px -6px;color:var(--primary);font-size:14px;font-weight:500;min-height:40px}
.sp{flex:1}
.card{background:var(--sc-low);border-radius:var(--r-group);padding:20px;min-width:0}
.card h2{margin:0 0 4px;font-size:16px;font-weight:500}
.card h2.sub-h{margin-top:20px;font-size:14px;color:var(--primary)}
.card-head{display:flex;gap:12px;align-items:center;flex-wrap:wrap}
.card-head > div{flex:1 1 240px;min-width:0}
.sup,.note{color:var(--on-surface-variant);font-size:13px;margin:4px 0 0;line-height:1.55}
.note{margin:0 4px;font-size:12px}
.muted{color:var(--on-surface-variant)}.small{font-size:12px}
.mono{font-family:var(--mono);font-size:12px}
.grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(220px,1fr));gap:12px 16px;margin-top:12px}
label.f{display:flex;flex-direction:column;gap:6px;font-size:12px;font-weight:500;color:var(--on-surface-variant);min-width:0}
label.f .muted{font-weight:400}
.row{display:flex;gap:8px;flex-wrap:wrap;align-items:center;margin:8px 0}
.actions{display:flex;gap:8px;flex-wrap:wrap;align-items:center;margin-top:16px}
.actions .hint{color:var(--on-surface-variant);font-size:12px;flex:1 1 220px}
.check{display:inline-flex;align-items:center;gap:10px;font-size:14px;cursor:pointer;min-height:40px}
/* 状态网格 */
.kv{display:flex;flex-direction:column;gap:2px;min-width:0}.kv b{font-size:12px;color:var(--on-surface-variant);font-weight:500}.kv span{overflow-wrap:anywhere;font-variant-numeric:tabular-nums}
.tiles{display:grid;grid-template-columns:repeat(4,minmax(0,1fr));gap:12px}
.tile{background:var(--sc-low);border-radius:var(--r-group);padding:16px 18px;display:flex;flex-direction:column;gap:4px;min-width:0}
.tile .k{font-size:12px;color:var(--on-surface-variant);font-weight:500;display:flex;align-items:center;gap:6px}
.tile .k svg.i{width:18px;height:18px}
.tile .v{font-size:28px;line-height:36px;font-variant-numeric:tabular-nums;overflow-wrap:anywhere}
.tile .s{font-size:12px;color:var(--on-surface-variant)}
.tile.hero{background:var(--primary-container);color:var(--on-primary-container)}
.tile.hero .k,.tile.hero .s{color:var(--on-primary-container)}
/* 列表（app 设置页式分组） */
.list{background:var(--sc-low);border-radius:var(--r-group);overflow:hidden}
.list:empty{display:none}
.lrow{display:flex;align-items:center;gap:16px;padding:14px 20px;min-height:64px}
.lrow + .lrow{border-top:1px solid color-mix(in srgb,var(--outline-variant) 60%,transparent)}
.lead{width:40px;height:40px;border-radius:12px;background:var(--sc-highest);color:var(--on-surface-variant);display:grid;place-items:center;flex:none}
.txt{flex:1;min-width:0;display:flex;flex-direction:column;gap:2px}
.txt .t{font-weight:500;font-size:15px;overflow-wrap:anywhere;display:flex;flex-wrap:wrap;gap:4px 8px;align-items:center}
.txt .s{color:var(--on-surface-variant);font-size:13px;overflow-wrap:anywhere}
.txt .e{color:var(--error);font-size:13px;overflow-wrap:anywhere}
.trail{display:flex;gap:4px 8px;align-items:center;flex-wrap:wrap;justify-content:flex-end}
.lrow.click{cursor:pointer;transition:background-color .15s}
.lrow.click:hover,.lrow.click.sel{background:color-mix(in srgb,var(--on-surface) 6%,transparent)}
label.lrow{cursor:pointer}
.empty{display:flex;flex-direction:column;align-items:center;text-align:center;gap:8px;padding:28px 20px;color:var(--on-surface-variant);font-size:13px}
.empty svg.i{width:36px;height:36px;color:var(--outline)}
.skel{height:64px;margin:0;background:linear-gradient(90deg,var(--sc-low) 25%,var(--sc-high) 50%,var(--sc-low) 75%);background-size:200% 100%;animation:shimmer 1.4s infinite linear}
.skel + .skel{border-top:1px solid var(--surface)}
.tile.skel{height:104px;border-radius:var(--r-group)}
@keyframes shimmer{to{background-position:-200% 0}}
.inset{border:1px solid var(--outline-variant);border-radius:var(--r-card);padding:14px 16px;margin:10px 0;background:var(--surface)}
/* chip / 进度 / 开关 */
.tag{display:inline-flex;align-items:center;height:24px;padding:0 10px;border-radius:var(--r-chip);font-size:12px;font-weight:500;background:var(--sc-highest);color:var(--on-surface-variant);white-space:nowrap;max-width:100%;overflow:hidden;text-overflow:ellipsis}
.tag.ok{background:var(--ok-container);color:var(--on-ok-container)}
.tag.err{background:var(--error-container);color:var(--on-error-container)}
.tag.warn{background:var(--warn-container);color:var(--on-warn-container)}
.tag.info{background:var(--tertiary-container);color:var(--on-tertiary-container)}
.bar{height:4px;border-radius:2px;background:var(--sc-highest);overflow:hidden;margin-top:6px}
.bar i{display:block;height:100%;border-radius:2px;background:var(--primary);transition:width .4s var(--ease)}
.bar.indet i{width:35%;animation:indet 1.3s infinite var(--ease)}
@keyframes indet{from{transform:translateX(-100%)}to{transform:translateX(300%)}}
input.sw{appearance:none;-webkit-appearance:none;position:relative;flex:none;width:52px;height:32px;margin:0;border-radius:16px;border:2px solid var(--outline);background:var(--sc-highest);cursor:pointer;transition:background-color .2s var(--ease),border-color .2s}
input.sw::after{content:"";position:absolute;left:6px;top:6px;width:16px;height:16px;border-radius:50%;background:var(--outline);transition:all .25s var(--spring)}
input.sw:checked{background:var(--primary);border-color:var(--primary)}
input.sw:checked::after{left:22px;top:2px;width:24px;height:24px;background:var(--on-primary)}
input.sw:active::after{width:26px;height:26px;top:1px;left:1px}
input.sw:checked:active::after{left:19px}
input.sw:disabled{opacity:.38;cursor:default}
.fchips{display:flex;flex-wrap:wrap;gap:8px;margin:10px 0}
.fchip{position:relative;display:inline-flex}
.fchip input{position:absolute;opacity:0;inset:0;width:100%;height:100%;cursor:pointer}
.fchip span{display:inline-flex;align-items:center;height:32px;padding:0 14px;border-radius:8px;border:1px solid var(--outline);font-size:13px;font-weight:500;color:var(--on-surface-variant);transition:background-color .15s,border-color .15s}
.fchip input:checked + span{background:var(--secondary-container);border-color:transparent;color:var(--on-secondary-container)}
.fchip input:checked + span::before{content:"✓";margin-right:6px}
.fchip input:focus-visible + span{outline:2px solid var(--primary);outline-offset:2px}
/* 设置行 */
.srow{display:flex;align-items:center;gap:16px;padding:14px 20px;min-height:64px}
.srow + .srow{border-top:1px solid color-mix(in srgb,var(--outline-variant) 60%,transparent)}
.srow .txt{cursor:default}
.srow .ctl{width:min(320px,45%);flex:none;display:flex;justify-content:flex-end}
.srow.swr .ctl{width:auto}
.savebar{position:sticky;bottom:-48px;background:var(--surface);padding:12px 0 16px;margin:0;z-index:2}
/* 配对 PIN */
.pin-card{background:var(--tertiary-container);color:var(--on-tertiary-container);border-radius:var(--r-group);padding:20px 24px;display:flex;gap:12px 24px;align-items:center;flex-wrap:wrap}
.pin-card > div{flex:1 1 240px;min-width:0}
.pin-card b{font-size:16px;font-weight:500}
.pin-card .sup{color:inherit;opacity:.8}
.pin{font-family:var(--mono);font-size:44px;font-weight:600;letter-spacing:.18em;font-variant-numeric:tabular-nums;overflow-wrap:anywhere}
.pulse{display:inline-block;width:10px;height:10px;border-radius:50%;background:currentColor;margin-right:8px;animation:pulse 1.6s infinite}
@keyframes pulse{50%{opacity:.25}}
/* 表格（复习页配置文件），窄屏叠成卡片 */
.tbl{overflow-x:auto;margin-top:12px}
table{width:100%;border-collapse:collapse}
th,td{text-align:left;padding:10px 8px;border-bottom:1px solid color-mix(in srgb,var(--outline-variant) 60%,transparent);vertical-align:middle}
th{color:var(--on-surface-variant);font-weight:500;font-size:12px}
pre{margin:12px 0 0;background:var(--sc-lowest);border-radius:var(--r-card);padding:14px;overflow:auto;max-height:65vh;font-family:var(--mono);font-size:12px;line-height:1.6;white-space:pre-wrap;color:var(--on-surface-variant)}
/* AI 会话 */
.entry{display:flex;gap:12px;align-items:flex-start;padding:10px 0}
.entry + .entry{border-top:1px solid color-mix(in srgb,var(--outline-variant) 60%,transparent)}
.entry > div{flex:1;min-width:0;white-space:pre-wrap;overflow-wrap:anywhere}
/* 对话框 / snackbar */
dialog{border:0;padding:24px;border-radius:var(--r-dialog);background:var(--sc-high);color:var(--on-surface);width:min(400px,calc(100% - 32px));max-height:calc(100% - 48px);overflow:auto}
dialog::backdrop{background:var(--scrim)}
dialog[open]{animation:pop .3s var(--ease-decel)}
dialog .di{display:flex;justify-content:center;color:var(--primary);margin-bottom:16px}
dialog.danger .di{color:var(--error)}
dialog p{margin:0;font-size:15px;line-height:1.6;white-space:pre-line;color:var(--on-surface-variant)}
dialog .actions{justify-content:flex-end;margin-top:24px}
@keyframes pop{from{opacity:0;transform:scale(.92)}}
#toast{position:fixed;left:50%;bottom:24px;z-index:50;transform:translate(-50%,24px);opacity:0;pointer-events:none;background:var(--inverse-surface);color:var(--inverse-on-surface);border-radius:8px;padding:14px 18px;min-width:220px;max-width:calc(100% - 32px);box-shadow:0 4px 12px rgba(0,0,0,.25);transition:transform .3s var(--ease-decel),opacity .2s;font-size:14px}
#toast.on{transform:translate(-50%,0);opacity:1}
#toast.err{background:var(--error-container);color:var(--on-error-container)}
/* ── 响应式 ── */
@media (max-width: 1000px){.tiles{grid-template-columns:repeat(2,minmax(0,1fr))}}
@media (max-width: 640px){
.app{grid-template-columns:minmax(0,1fr)}
.topbar{grid-column:1;padding:0 8px}
.topbar .menu{display:grid}
.ttl h1{font-size:18px;line-height:24px}
main{grid-column:1;padding:4px 16px 48px}
.rail{position:fixed;top:0;bottom:0;left:0;width:min(300px,85vw);align-items:stretch;padding:16px 12px;background:var(--sc-low);border-radius:0 16px 16px 0;transform:translateX(-105%);transition:transform .35s var(--ease-decel);z-index:30;visibility:hidden}
.rail.open{transform:none;visibility:visible}
.brand{margin:0 0 12px 12px}.brand span{display:block}
.rail hr{width:auto;margin:6px 16px}
.rail button{width:auto;flex-direction:row;gap:12px;height:56px;padding:0 16px 0 4px;border-radius:28px;font-size:14px;text-align:left}
.ind{width:44px}
.rail button.on{background:color-mix(in srgb,var(--secondary-container) 45%,transparent)}
.badge{right:4px}
.scrim-nav{display:block;position:fixed;inset:0;background:var(--scrim);z-index:29;opacity:0;pointer-events:none;transition:opacity .3s}
.scrim-nav.on{opacity:1;pointer-events:auto}
.tiles{gap:8px}.tile{padding:14px}.tile .v{font-size:24px;line-height:32px}
.card{padding:16px}
.lrow,.srow{padding:12px 16px;gap:12px;flex-wrap:wrap}
.lrow .trail{width:100%;justify-content:flex-start}
.lrow .lead + .txt + .trail{padding-left:52px}
.srow .ctl{width:100%}
.srow.swr .ctl{width:auto}
.pin{font-size:36px}
.b{height:44px}
table.rt,.rt tbody,.rt tr,.rt td{display:block;width:100%}
.rt tr.h{display:none}
.rt tr{padding:8px 0;border-bottom:1px solid var(--outline-variant)}
.rt td{border:0;padding:4px 0;display:flex;gap:12px;align-items:center}
.rt td[data-label]::before{content:attr(data-label);min-width:88px;color:var(--on-surface-variant);font-size:12px}
}
</style></head><body>
<svg width="0" height="0" style="position:absolute" aria-hidden="true"><defs>
<symbol id="i-status" viewBox="0 0 24 24"><path d="M3 13h8V3H3v10zm0 8h8v-6H3v6zm10 0h8V11h-8v10zm0-18v6h8V3h-8z"/></symbol>
<symbol id="i-pairing" viewBox="0 0 24 24"><path d="M3.9 12c0-1.71 1.39-3.1 3.1-3.1h4V7H7c-2.76 0-5 2.24-5 5s2.24 5 5 5h4v-1.9H7c-1.71 0-3.1-1.39-3.1-3.1zM8 13h8v-2H8v2zm9-6h-4v1.9h4c1.71 0 3.1 1.39 3.1 3.1s-1.39 3.1-3.1 3.1h-4V17h4c2.76 0 5-2.24 5-5s-2.24-5-5-5z"/></symbol>
<symbol id="i-libraries" viewBox="0 0 24 24"><path d="M10 4H4c-1.1 0-1.99.9-1.99 2L2 18c0 1.1.9 2 2 2h16c1.1 0 2-.9 2-2V8c0-1.1-.9-2-2-2h-8l-2-2z"/></symbol>
<symbol id="i-upload" viewBox="0 0 24 24"><path d="M9 16h6v-6h4l-7-7-7 7h4zm-4 2h14v2H5z"/></symbol>
<symbol id="i-jobs" viewBox="0 0 24 24"><path d="M19 3H5c-1.1 0-2 .9-2 2v14c0 1.1.9 2 2 2h14c1.1 0 2-.9 2-2V5c0-1.1-.9-2-2-2zm-9 14l-5-5 1.41-1.41L10 14.17l7.59-7.59L19 8l-9 9z"/></symbol>
<symbol id="i-downloads" viewBox="0 0 24 24"><path d="M19 9h-4V3H9v6H5l7 7 7-7zM5 18v2h14v-2H5z"/></symbol>
<symbol id="i-subscriptions" viewBox="0 0 24 24"><path d="M6.18 15.64a2.18 2.18 0 0 1 2.18 2.18C8.36 19 7.38 20 6.18 20 5 20 4 19 4 17.82a2.18 2.18 0 0 1 2.18-2.18M4 4.44A15.56 15.56 0 0 1 19.56 20h-2.83A12.73 12.73 0 0 0 4 7.27V4.44m0 5.66a9.9 9.9 0 0 1 9.9 9.9h-2.83A7.07 7.07 0 0 0 4 12.93V10.1z"/></symbol>
<symbol id="i-models" viewBox="0 0 24 24"><path d="M15 9H9v6h6V9zm-2 4h-2v-2h2v2zm8-2V9h-2V7c0-1.1-.9-2-2-2h-2V3h-2v2h-2V3H9v2H7c-1.1 0-2 .9-2 2v2H3v2h2v2H3v2h2v2c0 1.1.9 2 2 2h2v2h2v-2h2v2h2v-2h2c1.1 0 2-.9 2-2v-2h2v-2h-2v-2h2zm-4 6H7V7h10v10z"/></symbol>
<symbol id="i-ai" viewBox="0 0 24 24"><path d="M19 9l1.25-2.75L23 5l-2.75-1.25L19 1l-1.25 2.75L15 5l2.75 1.25L19 9zm-7.5.5L9 4 6.5 9.5 1 12l5.5 2.5L9 20l2.5-5.5L17 12l-5.5-2.5zM19 15l-1.25 2.75L15 19l2.75 1.25L19 23l1.25-2.75L23 19l-2.75-1.25L19 15z"/></symbol>
<symbol id="i-anki" viewBox="0 0 24 24"><path d="M11.99 18.54l-7.37-5.73L3 14.07l9 7 9-7-1.63-1.27-7.38 5.74zM12 16l7.36-5.73L21 9l-9-7-9 7 1.63 1.27L12 16z"/></symbol>
<symbol id="i-srs" viewBox="0 0 24 24"><path d="M5 13.18v4L12 21l7-3.82v-4L12 17l-7-3.82zM12 3L1 9l11 6 9-4.91V17h2V9L12 3z"/></symbol>
<symbol id="i-settings" viewBox="0 0 24 24"><path d="M19.14 12.94c.04-.3.06-.61.06-.94 0-.32-.02-.64-.07-.94l2.03-1.58a.49.49 0 0 0 .12-.61l-1.92-3.32a.488.488 0 0 0-.59-.22l-2.39.96c-.5-.38-1.03-.7-1.62-.94l-.36-2.54a.484.484 0 0 0-.48-.41h-3.84c-.24 0-.43.17-.47.41l-.36 2.54c-.59.24-1.13.57-1.62.94l-2.39-.96c-.22-.08-.47 0-.59.22L2.74 8.87c-.12.21-.08.47.12.61l2.03 1.58c-.05.3-.09.63-.09.94s.02.64.07.94l-2.03 1.58a.49.49 0 0 0-.12.61l1.92 3.32c.12.22.37.29.59.22l2.39-.96c.5.38 1.03.7 1.62.94l.36 2.54c.05.24.24.41.48.41h3.84c.24 0 .44-.17.47-.41l.36-2.54c.59-.24 1.13-.56 1.62-.94l2.39.96c.22.08.47 0 .59-.22l1.92-3.32c.12-.22.07-.47-.12-.61l-2.01-1.58zM12 15.6c-1.98 0-3.6-1.62-3.6-3.6s1.62-3.6 3.6-3.6 3.6 1.62 3.6 3.6-1.62 3.6-3.6 3.6z"/></symbol>
<symbol id="i-logs" viewBox="0 0 24 24"><path d="M3 18h12v-2H3v2zM3 6v2h18V6H3zm0 7h18v-2H3v2z"/></symbol>
<symbol id="i-menu" viewBox="0 0 24 24"><path d="M3 18h18v-2H3v2zm0-5h18v-2H3v2zm0-7v2h18V6H3z"/></symbol>
<symbol id="i-logout" viewBox="0 0 24 24"><path d="M17 7l-1.41 1.41L18.17 11H8v2h10.17l-2.58 2.58L17 17l5-5zM4 5h8V3H4c-1.1 0-2 .9-2 2v14c0 1.1.9 2 2 2h8v-2H4V5z"/></symbol>
<symbol id="i-dark" viewBox="0 0 24 24"><path d="M12 3a9 9 0 1 0 9 9c0-.46-.04-.92-.1-1.36a5.389 5.389 0 0 1-4.4 2.26 5.403 5.403 0 0 1-3.14-9.8c-.44-.06-.9-.1-1.36-.1z"/></symbol>
<symbol id="i-light" viewBox="0 0 24 24"><path d="M12 7c-2.76 0-5 2.24-5 5s2.24 5 5 5 5-2.24 5-5-2.24-5-5-5zM2 13h2c.55 0 1-.45 1-1s-.45-1-1-1H2c-.55 0-1 .45-1 1s.45 1 1 1zm18 0h2c.55 0 1-.45 1-1s-.45-1-1-1h-2c-.55 0-1 .45-1 1s.45 1 1 1zM11 2v2c0 .55.45 1 1 1s1-.45 1-1V2c0-.55-.45-1-1-1s-1 .45-1 1zm0 18v2c0 .55.45 1 1 1s1-.45 1-1v-2c0-.55-.45-1-1-1s-1 .45-1 1zM5.99 4.58a.996.996 0 0 0-1.41 0 .996.996 0 0 0 0 1.41l1.06 1.06c.39.39 1.03.39 1.41 0s.39-1.03 0-1.41L5.99 4.58zm12.37 12.37a.996.996 0 0 0-1.41 0 .996.996 0 0 0 0 1.41l1.06 1.06c.39.39 1.03.39 1.41 0a.996.996 0 0 0 0-1.41l-1.06-1.06zm1.06-10.96a.996.996 0 0 0 0-1.41.996.996 0 0 0-1.41 0l-1.06 1.06c-.39.39-.39 1.03 0 1.41s1.03.39 1.41 0l1.06-1.06zM7.05 18.36a.996.996 0 0 0 0-1.41.996.996 0 0 0-1.41 0l-1.06 1.06c-.39.39-.39 1.03 0 1.41s1.03.39 1.41 0l1.06-1.06z"/></symbol>
<symbol id="i-system" viewBox="0 0 24 24"><path d="M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm1 17.93V4.07c3.94.49 7 3.85 7 7.93s-3.06 7.44-7 7.93z"/></symbol>
<symbol id="i-add" viewBox="0 0 24 24"><path d="M19 13h-6v6h-2v-6H5v-2h6V5h2v6h6v2z"/></symbol>
<symbol id="i-refresh" viewBox="0 0 24 24"><path d="M17.65 6.35A7.958 7.958 0 0 0 12 4c-4.42 0-7.99 3.58-7.99 8s3.57 8 7.99 8c3.73 0 6.84-2.55 7.73-6h-2.08A5.99 5.99 0 0 1 12 18c-3.31 0-6-2.69-6-6s2.69-6 6-6c1.66 0 3.14.69 4.22 1.78L13 11h7V4l-2.35 2.35z"/></symbol>
<symbol id="i-warn" viewBox="0 0 24 24"><path d="M1 21h22L12 2 1 21zm12-3h-2v-2h2v2zm0-4h-2v-4h2v4z"/></symbol>
<symbol id="i-help" viewBox="0 0 24 24"><path d="M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm1 17h-2v-2h2v2zm2.07-7.75l-.9.92C13.45 12.9 13 13.5 13 15h-2v-.5c0-1.1.45-2.1 1.17-2.83l1.24-1.26c.37-.36.59-.86.59-1.41 0-1.1-.9-2-2-2s-2 .9-2 2H8c0-2.21 1.79-4 4-4s4 1.79 4 4c0 .88-.36 1.68-.93 2.25z"/></symbol>
<symbol id="i-device" viewBox="0 0 24 24"><path d="M17 1.01L7 1c-1.1 0-2 .9-2 2v18c0 1.1.9 2 2 2h10c1.1 0 2-.9 2-2V3c0-1.1-.9-1.99-2-1.99zM17 19H7V5h10v14z"/></symbol>
<symbol id="i-video" viewBox="0 0 24 24"><path d="M18 4l2 4h-3l-2-4h-2l2 4h-3l-2-4H8l2 4H7L5 4H4c-1.1 0-1.99.9-1.99 2L2 18c0 1.1.9 2 2 2h16c1.1 0 2-.9 2-2V4h-4z"/></symbol>
<symbol id="i-book" viewBox="0 0 24 24"><path d="M18 2H6c-1.1 0-2 .9-2 2v16c0 1.1.9 2 2 2h12c1.1 0 2-.9 2-2V4c0-1.1-.9-2-2-2zM6 4h5v8l-2.5-1.5L6 12V4z"/></symbol>
<symbol id="i-manga" viewBox="0 0 24 24"><path d="M21 5c-1.11-.35-2.33-.5-3.5-.5-1.95 0-4.05.4-5.5 1.5-1.45-1.1-3.55-1.5-5.5-1.5S2.45 4.9 1 6v14.65c0 .25.25.5.5.5.1 0 .15-.05.25-.05C3.1 20.45 5.05 20 6.5 20c1.95 0 4.05.4 5.5 1.5 1.35-.85 3.8-1.5 5.5-1.5 1.65 0 3.35.3 4.75 1.05.1.05.15.05.25.05.25 0 .5-.25.5-.5V6c-.6-.45-1.25-.75-2-1zm0 13.5c-1.1-.35-2.3-.5-3.5-.5-1.7 0-4.15.65-5.5 1.5V8c1.35-.85 3.8-1.5 5.5-1.5 1.2 0 2.4.15 3.5.5v11.5z"/></symbol>
<symbol id="i-audio" viewBox="0 0 24 24"><path d="M12 1a9 9 0 0 0-9 9v7c0 1.66 1.34 3 3 3h3v-8H5v-2c0-3.87 3.13-7 7-7s7 3.13 7 7v2h-4v8h3c1.66 0 3-1.34 3-3v-7a9 9 0 0 0-9-9z"/></symbol>
<symbol id="i-empty" viewBox="0 0 24 24"><path d="M19 3H4.99c-1.11 0-1.98.89-1.98 2L3 19c0 1.1.88 2 1.99 2H19c1.1 0 2-.9 2-2V5a2 2 0 0 0-2-2zm0 12h-4c0 1.66-1.35 3-3 3s-3-1.34-3-3H4.99V5H19v10z"/></symbol>
</defs></svg>
<div class="app">
<nav class="rail" id="rail">
<div class="brand"><img src="__FUSHI_LOGO__" alt=""><span>fushi_server</span></div>
<button data-s="status" class="on"><span class="ind"><svg class="i"><use href="#i-status"/></svg></span><span class="lbl">状态</span></button>
<button data-s="pairing"><span class="ind"><svg class="i"><use href="#i-pairing"/></svg><span class="badge" id="pair-badge" hidden></span></span><span class="lbl">配对</span></button>
<button data-s="libraries"><span class="ind"><svg class="i"><use href="#i-libraries"/></svg></span><span class="lbl">库</span></button>
<button data-s="upload"><span class="ind"><svg class="i"><use href="#i-upload"/></svg></span><span class="lbl">上传</span></button>
<hr>
<button data-s="jobs"><span class="ind"><svg class="i"><use href="#i-jobs"/></svg></span><span class="lbl">任务</span></button>
<button data-s="downloads"><span class="ind"><svg class="i"><use href="#i-downloads"/></svg></span><span class="lbl">下载</span></button>
<button data-s="subscriptions"><span class="ind"><svg class="i"><use href="#i-subscriptions"/></svg></span><span class="lbl">订阅</span></button>
<button data-s="models"><span class="ind"><svg class="i"><use href="#i-models"/></svg></span><span class="lbl">模型</span></button>
<hr>
<button data-s="ai"><span class="ind"><svg class="i"><use href="#i-ai"/></svg></span><span class="lbl">AI 助手</span></button>
<button data-s="anki"><span class="ind"><svg class="i"><use href="#i-anki"/></svg></span><span class="lbl">Anki</span></button>
<button data-s="srs"><span class="ind"><svg class="i"><use href="#i-srs"/></svg></span><span class="lbl">复习</span></button>
<hr>
<button data-s="settings"><span class="ind"><svg class="i"><use href="#i-settings"/></svg></span><span class="lbl">设置</span></button>
<button data-s="logs"><span class="ind"><svg class="i"><use href="#i-logs"/></svg></span><span class="lbl">日志</span></button>
</nav>
<div class="scrim-nav" id="scrim-nav"></div>
<header class="topbar">
<button class="icon-btn menu" id="btn-menu" type="button" title="菜单"><svg class="i"><use href="#i-menu"/></svg></button>
<div class="ttl"><h1 id="page-title">状态</h1><span id="devname"></span></div>
<button class="icon-btn" id="btn-theme" type="button"><svg class="i"><use href="#i-system"/></svg></button>
<form method="post" action="/logout"><button class="icon-btn" type="submit" title="退出"><svg class="i"><use href="#i-logout"/></svg></button></form>
</header>
<main id="main">

<section id="s-status" class="on">
<div class="tiles" id="status-tiles"><div class="tile skel"></div><div class="tile skel"></div><div class="tile skel"></div><div class="tile skel"></div></div>
<div class="card"><div class="card-head"><div><h2>扫描</h2><p class="sup" id="scan-state"></p></div><button class="b" id="btn-scan"><svg class="i"><use href="#i-refresh"/></svg>立即扫描库</button></div>
<div class="bar indet" id="scan-bar" hidden><i></i></div></div>
<h3 class="sh">运行状态</h3>
<div class="card"><div class="grid" id="status-grid" style="margin:0"></div></div>
</section>

<section id="s-pairing">
<div id="pairing-pending"><div class="list"><div class="skel"></div></div></div>
<h3 class="sh">已配对设备</h3>
<div class="list" id="peers"><div class="skel"></div><div class="skel"></div></div>
<p class="note"><span id="lb-link-state"></span> 标为「我的设备」的已配对设备在本机没有 Fushi 账户时，会跟随本机（当前 Profile）的排行榜账户自动登录：设备只交来它自己的公钥，由本机账户代绑；私钥 / 恢复码不外传。配对不会自动标记；只有配对时证明过设备钥匙的设备能标（旧版客户端需升级后重新配对）。仅 TLS 下可用，总开关在「设置」。</p>
<h3 class="sh">配置文件寄存<span class="sp"></span><span id="prof-state"></span></h3>
<div class="card"><div class="card-head"><div><p class="sup" style="margin:0">已配对设备在「互联 → 上传配置 / 下载配置」里把配置方案（Profile）推到本机寄存，另一台设备再拉走。本机只寄存、不应用；设备拉取时交出标「分发中」的那一份（缺省为最近收到的）。凭据已由发送端剔除。仅 TLS 下可用。</p></div><button class="b sec" id="btn-prof-toggle"></button></div></div>
<div class="list" id="profiles"></div>
</section>

<section id="s-libraries">
<h3 class="sh">扫描根</h3>
<div class="list" id="libs"><div class="skel"></div><div class="skel"></div></div>
<div class="card"><h2>添加</h2>
<div class="grid">
<label class="f" style="grid-column:1/-1">路径<input type="text" id="lib-path" placeholder="/srv/media/anime"></label>
<label class="f">类型<select id="lib-kind"><option value="video">video</option><option value="book">book (epub)</option><option value="manga">manga (mokuro / cbz / cbr / cb7 / zip / rar / 页图目录)</option><option value="audiobook">audiobook (音频目录，可带 epub / 字幕)</option></select></label>
<label class="f">id（可空）<input type="text" id="lib-id"></label></div>
<div class="actions"><button class="b" id="btn-lib-add"><svg class="i"><use href="#i-add"/></svg>添加</button><span class="hint">加完记得在「状态」页点扫描；服务端进程要能读到该目录。</span></div>
</div>
</section>

<section id="s-upload">
<div class="card"><h2>上传到库</h2>
<div class="grid">
<label class="f">库<select id="up-lib"></select></label>
<label class="f">子目录（可空，如 Season1）<input type="text" id="up-sub"></label>
<label class="f" style="grid-column:1/-1">文件<input type="file" id="up-files" multiple style="height:auto;padding:12px 14px"></label></div>
<div class="actions"><button class="b" id="btn-up"><svg class="i"><use href="#i-upload"/></svg>开始上传</button><span class="hint">分块 8 MB，可断点续传（同名文件继续）；上传完成后需扫描库。</span></div>
</div>
<div class="list" id="up-list"></div>
<p class="note" id="up-quota"></p>
</section>

<section id="s-jobs">
<h3 class="sh">互联任务（ASR 等）</h3>
<div class="list" id="jobs"><div class="skel"></div></div>
</section>

<section id="s-downloads">
<div class="card"><h2>添加磁力下载</h2><p class="sup" id="dl-cap"></p>
<div class="grid">
<label class="f" style="grid-column:1/-1">磁力链接<input type="text" id="dl-magnet" placeholder="magnet:?xt=urn:btih:…"></label>
<label class="f">标题<input type="text" id="dl-title"></label>
<label class="f">类型<select id="dl-kind"><option value="movie">movie</option><option value="tv">tv</option></select></label></div>
<div class="actions"><button class="b" id="btn-dl-add"><svg class="i"><use href="#i-add"/></svg>添加</button></div></div>
<h3 class="sh">下载任务</h3>
<div class="list" id="dls"><div class="skel"></div></div>
</section>

<section id="s-subscriptions">
<div class="card"><h2>新建订阅（按搜索词追新）</h2><p class="sup" id="sub-cap">从 Fushi 客户端的发现页订阅会带完整作品身份（原名/别名/交叉 ID）；这里只按搜索词匹配。</p>
<div class="grid">
<label class="f">标题（显示用）<input type="text" id="sub-title"></label>
<label class="f">搜索词<input type="text" id="sub-query" placeholder="搜索词，如 Frieren 1080p"></label>
<label class="f">源<select id="sub-provider"></select></label>
<label class="f">类型<select id="sub-kind"><option value="tv">tv（持续追新）</option><option value="movie">movie（一次）</option></select></label>
<label class="f">从第几集之后开始（可空）<input type="number" id="sub-after"></label></div>
<div class="actions"><button class="b" id="btn-sub-add"><svg class="i"><use href="#i-add"/></svg>创建</button></div></div>
<h3 class="sh">订阅<span class="sp"></span><button class="b text" id="btn-sub-check-all"><svg class="i"><use href="#i-refresh"/></svg>全部立即检查</button></h3>
<div class="list" id="subs"><div class="skel"></div></div>
<h3 class="sh">资源索引器</h3>
<div class="card">
<p class="sup" style="margin:0">订阅与代下载在这些来源里搜资源。与 Fushi app 的资源来源设置是同一份配置；改动对正在运行的服务立即生效（正在下载的种子不受影响）。</p>
<p class="sup" id="ri-none" style="display:none">还没有 BT 来源。添加一个 BT 站地址，或接入 Torznab 索引器</p>
<h2 class="sub-h">BT 站</h2>
<div id="ri-bt"></div>
<div class="inset">
<div class="grid" style="margin:0"><label class="f">站点地址<input type="text" id="bt-url" placeholder="https://example.com"></label><label class="f">名称（可选）<input type="text" id="bt-name"></label></div>
<div class="fchips" id="bt-domains"></div>
<div class="row"><label class="check"><input type="checkbox" class="sw" id="bt-enabled" checked><span>启用</span></label><label class="check"><input type="checkbox" class="sw" id="bt-insecure"><span>允许明文 HTTP（仅受信任局域网）</span></label><span class="sp"></span><button class="b" id="btn-bt-add"><svg class="i"><use href="#i-add"/></svg>添加</button></div>
<p class="sup">只填地址即可，添加时会自动检测站点。</p></div>
<h2 class="sub-h">Torznab（Jackett / Prowlarr）</h2>
<div id="ri-torznab"></div>
<div class="actions"><button class="b out" id="btn-ri-add"><svg class="i"><use href="#i-add"/></svg>添加 indexer</button><span class="sp"></span><button class="b text" id="btn-ri-reset">放弃修改</button><button class="b" id="btn-ri-save">保存</button></div>
<p class="sup" id="ri-state"></p></div>
</section>

<section id="s-models">
<h3 class="sh">ASR 模型</h3>
<div class="list" id="asr-models"><div class="skel"></div></div>
<h3 class="sh">漫画 OCR 模型</h3>
<div class="list" id="ocr-model"><div class="skel"></div></div>
</section>

<section id="s-anki">
<div class="card"><h2>Anki 落地</h2>
<p class="sup">打开后，其它设备（没装 Anki 的手机等）经互联同步过来的待发卡片由本机写进 Anki，再同步到 AnkiWeb 或你的自建 Anki 同步服务器。本机需要随包的 fushi-anki-sync。</p>
<div class="grid" id="anki-status"></div>
<div class="actions"><label class="check"><input type="checkbox" class="sw" id="anki-landing"><span>接收其他设备的卡片</span></label><span class="sp"></span>
<button class="b sec" id="btn-anki-run">立即落地</button><button class="b sec" id="btn-anki-retry">重试失败的卡</button></div>
</div>
<h3 class="sh">Anki 同步账号</h3>
<div class="card" id="anki-account"></div>
<h3 class="sh">牌组 / 笔记类型 / 字段</h3>
<div class="card" id="anki-config"></div>
</section>

<section id="s-srs">
<div class="card"><h2>Fushi 复习</h2>
<p class="sup">本机替已配对设备保管 Fushi 复习的收藏：手机可以远程复习、制卡落到这里，Yomitan 可经下面的 AnkiConnect 往这里加卡。勾选要提供的配置文件（每门语言一份）；不勾选任何一份 = 关闭。同步位置开了端到端加密的配置文件暂不支持。</p>
<div class="grid" id="srs-status"></div>
<div id="srs-profiles" style="margin-top:12px"></div>
</div>
<h3 class="sh">制卡落点</h3>
<div class="card" id="srs-mining"></div>
<h3 class="sh">AnkiConnect 兼容接口</h3>
<div class="card">
<p class="sup" style="margin:0">默认关闭。只监听本机时可以不设 key；监听局域网地址必须设 key。每份配置文件可以有自己的 key（Yomitan 里一门语言一个 key），共用 key 落到默认那份。</p>
<div id="srs-ankiconnect"></div></div>
</section>

<section id="s-settings">
<div id="settings-form"><div class="list"><div class="skel"></div><div class="skel"></div><div class="skel"></div></div></div>
<div class="actions savebar"><button class="b" id="btn-settings-save">保存</button><span class="hint">端口 / TLS / 绑定 / qBittorrent / torrent / ffmpeg / onnxruntime 路径改后需重启 serve。</span></div>
<h3 class="sh">远程访问</h3>
<div class="card">
<label class="f">公网地址（每行一个，http:// 或 https://；反代 / DDNS / 端口映射后的地址，已配对设备会自动学到）<textarea id="rr-public" rows="3" placeholder="https://nas.example.com:38765"></textarea></label>
<div class="row" style="margin:16px 0"><label class="check"><input type="checkbox" class="sw" id="rr-p2p"><span>允许 P2P 隧道连接</span></label><span class="small muted">没有公网 IP 时用（iroh）；开启后会连接中继与发现服务，对端 / 中继能看到本机 IP。</span></div>
<label class="f">自建中继（每行一个，空 = iroh 公共中继）<textarea id="rr-relays" rows="2" placeholder="https://relay.example.com"></textarea></label>
<p class="sup" id="rr-state"></p>
<div class="actions"><button class="b" id="btn-rr-save">保存</button><span class="hint">这三项保存即生效，无需重启。</span></div>
</div>
</section>

<section id="s-ai">
<div class="card"><h2>AI 助手会话</h2>
<p class="sup">已配对设备经互联让本服务端跑的 AI 助手会话（保留 30 天）。这里只读；撤销与续接在发起的那台设备上做。</p></div>
<div class="list" id="ai-sessions"><div class="skel"></div></div>
<div class="card" id="ai-detail" style="display:none"><h2 id="ai-detail-title"></h2><p class="sup" id="ai-detail-meta"></p><div id="ai-entries" style="margin-top:8px"></div></div>
</section>

<section id="s-logs">
<div class="card"><div class="card-head"><div><h2 style="margin:0">最近日志</h2></div><label class="check"><span>自动刷新</span><input type="checkbox" class="sw" id="log-auto" checked></label><button class="b sec" id="btn-log-refresh"><svg class="i"><use href="#i-refresh"/></svg>刷新</button></div><pre id="logs"></pre></div>
</section>

</main>
</div>
<dialog id="dlg"><div class="di"><svg class="i"><use href="#i-help"/></svg></div><p id="dlg-msg"></p>
<div class="actions"><button class="b text" id="dlg-no" type="button">取消</button><button class="b" id="dlg-ok" type="button">确定</button></div></dialog>
<div id="toast" role="status" aria-live="polite"></div>
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
const icon = (name) => `<svg class="i"><use href="#i-${name}"/></svg>`;
// snackbar：err=true 用错误色。
let toastTimer; function toast(msg, err){ const t=$('#toast'); t.textContent=msg; t.classList.toggle('err', !!err); t.classList.add('on'); clearTimeout(toastTimer); toastTimer=setTimeout(()=>t.classList.remove('on'), err?4200:2600); }
// 确认对话框（替代 window.confirm）：返回 Promise<bool>；danger=true 时确认键用错误色。
function ask(msg, danger){
  const d=$('#dlg'); $('#dlg-msg').textContent=msg; d.classList.toggle('danger', !!danger);
  d.querySelector('.di use').setAttribute('href', danger?'#i-warn':'#i-help');
  $('#dlg-ok').className = danger ? 'b danger' : 'b';
  return new Promise((resolve)=>{
    const done=(v)=>{ d.onclose=null; $('#dlg-ok').onclick=null; $('#dlg-no').onclick=null; if(d.open) d.close(); resolve(v); };
    $('#dlg-ok').onclick=()=>done(true); $('#dlg-no').onclick=()=>done(false); d.onclose=()=>done(false);
    d.showModal(); $('#dlg-no').focus();
  });
}
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
function guard(fn){ return async (...a)=>{ try{ await fn(...a);}catch(e){ toast(T('失败: {0}', e.message), true);} }; }
const tag = (cls, text) => `<span class="tag${cls?' '+cls:''}">${esc(text)}</span>`;
const empty = (text, ic) => `<div class="empty">${icon(ic||'empty')}<span>${esc(text)}</span></div>`;
const kvHtml = (kv) => kv.map(([k,v,html])=>`<div class="kv"><b>${esc(k)}</b><span>${html?v:esc(v)}</span></div>`).join('');
const progress = (frac) => `<div class="bar"><i style="width:${Math.max(0,Math.min(100,frac*100)).toFixed(1)}%"></i></div>`;

// ── 主题（跟随系统 / 浅色 / 深色，存本机浏览器）──
const THEMES = ['system','light','dark'];
const THEME_TITLE = {system:T('主题：跟随系统'), light:T('主题：浅色'), dark:T('主题：深色')};
function readTheme(){ try{ const t=localStorage.getItem('fushi-admin-theme'); return THEMES.includes(t)?t:'system'; }catch(e){ return 'system'; } }
function applyTheme(t){
  if (t==='system') document.documentElement.removeAttribute('data-theme'); else document.documentElement.setAttribute('data-theme', t);
  try{ localStorage.setItem('fushi-admin-theme', t); }catch(e){}
  $('#btn-theme use').setAttribute('href', '#i-'+t); $('#btn-theme').title = THEME_TITLE[t]; $('#btn-theme').setAttribute('aria-label', THEME_TITLE[t]);
}
applyTheme(readTheme());
$('#btn-theme').onclick = ()=>{ const t=readTheme(); applyTheme(THEMES[(THEMES.indexOf(t)+1)%THEMES.length]); };

// ── 导航 ──
// 选中项背后的 M3E 多边形：每项轮流取一种（同 app 的 kNavRailFallbackShapes），用极坐标波形画。
function navShape(n, a, rot){ let d=''; for(let k=0;k<=120;k++){ const t=k/120*2*Math.PI; const r=20*(1+a*Math.cos(n*(t+rot))); d+=(k?'L':'M')+(23+r*Math.cos(t)).toFixed(2)+' '+(23+r*Math.sin(t)).toFixed(2); } return d+'Z'; }
const NAV_SHAPES = [[9,.07,0],[4,.16,0],[10,.05,0],[8,.1,0],[4,.08,Math.PI/4],[8,.05,0],[6,.09,0],[5,.08,0],[6,.06,0],[8,.14,0]];
const navButtons = Array.from(document.querySelectorAll('.rail button[data-s]'));
navButtons.forEach((b,i)=>{ const [n,a,r]=NAV_SHAPES[i%NAV_SHAPES.length]; b.querySelector('.ind').insertAdjacentHTML('afterbegin', `<svg class="shape" viewBox="0 0 46 46" aria-hidden="true"><path d="${navShape(n,a,r)}"/></svg>`); });
let current='status';
function closeNav(){ $('#rail').classList.remove('open'); $('#scrim-nav').classList.remove('on'); }
function go(s, push){
  const b = navButtons.find(x=>x.dataset.s===s); if(!b) return;
  current=s;
  navButtons.forEach(x=>{ x.classList.toggle('on', x===b); if(x===b) x.setAttribute('aria-current','page'); else x.removeAttribute('aria-current'); });
  document.querySelectorAll('main section').forEach(sec=>sec.classList.toggle('on', sec.id==='s-'+s));
  $('#page-title').textContent = b.querySelector('.lbl').textContent;
  $('#main').scrollTop = 0;
  if (push) { try{ history.replaceState(null, '', '#'+s); }catch(e){} }
  closeNav(); refresh();
}
navButtons.forEach(b=>b.onclick=()=>go(b.dataset.s, true));
$('#btn-menu').onclick = ()=>{ $('#rail').classList.add('open'); $('#scrim-nav').classList.add('on'); const on=$('.rail button.on'); if(on) on.focus(); };
$('#scrim-nav').onclick = closeNav;
document.addEventListener('keydown', (e)=>{ if(e.key==='Escape' && $('#rail').classList.contains('open')) closeNav(); });

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
  $('#devname').textContent = s.deviceName + ' · ' + s.listen + (s.tls?' · https':' · http');
  const quota = s.uploadQuotaBytes ? s.uploadUsedBytes / s.uploadQuotaBytes : 0;
  const tile = (cls, ic, k, v, sub, extra) => `<div class="tile${cls}"><span class="k">${icon(ic)}${esc(k)}</span><span class="v">${esc(v)}</span><span class="s">${esc(sub)}</span>${extra||''}</div>`;
  $('#status-tiles').innerHTML =
    tile(' hero', 'video', T('视频'), s.videos, T('{0} 个库根', s.libraries)) +
    tile('', 'book', T('书'), s.books, '') +
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
  const notes = (s.lastScanNotes && s.lastScanNotes.length) ? ' — ' + s.lastScanNotes.join('; ') : '';
  $('#scan-state').textContent = s.scanning ? T('扫描中…') : (s.lastScan ? T('上次 {0}: {1}', fmtTime(s.lastScanAt), s.lastScan + notes) : T('尚未扫描'));
  $('#btn-scan').disabled = !!s.scanning;
  $('#scan-bar').hidden = !s.scanning;
}
$('#btn-scan').onclick = guard(async()=>{ await post('scan'); toast(T('已开始扫描')); loadStatus(); });

// ── 配对 ──
function setPairBadge(pending){ $('#pair-badge').hidden = !pending; }
async function loadPairing(){
  const p = await api('pairing');
  setPairBadge(p.pending);
  $('#pairing-pending').innerHTML = p.pending
    ? `<div class="pin-card"><div><b><span class="pulse"></span>${esc(T('{0} ({1}) 请求配对，请在该设备输入：', p.pending.deviceName||T('未知设备'), p.pending.remoteAddress||'?'))}</b><p class="sup">${fmtTime(p.pending.createdAt)}</p></div><div class="pin">${esc(p.pending.pin)}</div></div>`
    : `<div class="list">${empty(T('没有待处理的配对。在 Fushi 里添加互联设备并输入本机地址，PIN 会显示在这里。'), 'pairing')}</div>`;
  $('#peers').innerHTML = p.peers.map(x=>`<div class="lrow"><div class="lead">${icon('device')}</div><div class="txt"><div class="t">${esc(x.deviceName||'—')}${x.ownerDevice?tag('info', T('我的设备')):''}</div><div class="s">${esc([x.lastSeenIp, fmtTime(x.pairedAtMs)].filter(Boolean).join(' · '))}</div><div class="s mono">${esc(x.peerId)}</div></div><div class="trail">${x.deviceKeyVerified ? `<button class="b ${x.ownerDevice?'out':'sec'}" data-owner="${esc(x.peerId)}" data-on="${x.ownerDevice?'1':'0'}">${esc(x.ownerDevice?T('取消我的设备'):T('标为我的设备'))}</button>` : tag('', T('未证明设备钥匙'))}<button class="b text danger" data-revoke="${esc(x.peerId)}">${esc(T('吊销'))}</button></div></div>`).join('') || empty(T('还没有已配对设备'), 'device');
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
  $('#profiles').innerHTML = (r.profiles||[]).map(x=>`<div class="lrow"><div class="txt"><div class="t">${esc(x.name)}${x.shared?tag('ok', T('分发中')):''}</div><div class="s">${esc(T('{0} 项设置', x.settingCount))} · ${esc(fmtTime(x.receivedAt))}</div></div><div class="trail">${x.shared?'':`<button class="b sec" data-prof="share" data-id="${x.id}">${esc(T('设为分发'))}</button>`}<button class="b text danger" data-prof="delete" data-id="${x.id}">${esc(T('删除'))}</button></div></div>`).join('') || empty(T('还没有设备推送过配置'));
  $('#profiles').querySelectorAll('[data-prof]').forEach(b=>b.onclick=guard(async()=>{ const id=b.dataset.id;
    if(b.dataset.prof==='delete'){ if(!await ask(T('删除这份寄存的配置？'), true)) return; await del('profiles/'+id); toast(T('已删除')); }
    else { await post('profiles/'+id+'/share'); }
    loadProfiles(); }));
}
$('#btn-prof-toggle').onclick = guard(async()=>{ const on = $('#btn-prof-toggle').dataset.enabled!=='1'; if(on && !await ask(T('允许已配对设备把配置推到本机寄存、并从本机拉走？'))) return; await put('settings',{profileTransfer:on}); settingsCache=null; toast(on?T('已允许'):T('已禁止')); loadProfiles(); });

// ── 库 ──
const KIND_ICON = {video:'video', book:'book', manga:'manga', audiobook:'audio'};
async function loadLibraries(){
  const r = await api('libraries');
  $('#libs').innerHTML = r.libraries.map(l=>`<div class="lrow"><div class="lead">${icon(KIND_ICON[l.kind]||'libraries')}</div><div class="txt"><div class="t">${esc(l.path)}</div><div class="s">${esc(l.id)} · ${esc(l.kind)}</div></div><div class="trail">${l.exists?tag('ok', T('存在')):tag('err', T('目录不存在'))}${l.enabled?'':tag('', T('禁用'))}<button class="b text" data-rm="${esc(l.id)}">${esc(T('移除'))}</button><button class="b text danger" data-purge="${esc(l.id)}">${esc(T('移除并清理'))}</button></div></div>`).join('') || empty(T('还没有扫描根'), 'libraries');
  $('#libs').querySelectorAll('[data-rm]').forEach(b=>b.onclick=guard(async()=>{ if(!await ask(T('从配置移除该库根？（不删文件、不删已入库条目）'), true)) return; await del('libraries/'+encodeURIComponent(b.dataset.rm)); toast(T('已移除')); loadLibraries(); }));
  $('#libs').querySelectorAll('[data-purge]').forEach(b=>b.onclick=guard(async()=>{ if(!await ask(T('移除该库根，并清理「文件已消失」的条目？\n只回收条目与其刮削资料 / 正文副本，不删任何源文件。\n注意：目录若只是没挂载，其下条目也会被当成已删除。'), true)) return; const r=await del('libraries/'+encodeURIComponent(b.dataset.purge)+'?purge=true'); const p=r&&r.purge; toast(p?(p.skipped?T('未清理：{0}', p.reason||T('被护栏拦下')):T('已清理 {0} 条', p.deleted)):T('已移除')); loadLibraries(); loadStatus(); }));
  const sel = $('#up-lib'); const cur = sel.value;
  sel.innerHTML = r.libraries.map(l=>`<option value="${esc(l.id)}">${esc(l.id)} — ${esc(l.path)}</option>`).join('');
  if (cur) sel.value = cur;
}
$('#btn-lib-add').onclick = guard(async()=>{ await post('libraries',{path:$('#lib-path').value, kind:$('#lib-kind').value, id:$('#lib-id').value}); $('#lib-path').value=''; $('#lib-id').value=''; toast(T('已添加')); loadLibraries(); });

// ── 上传 ──
const CHUNK = 8*1024*1024;
async function uploadOne(file, lib, sub, row){
  const rel = (sub ? sub.replace(/^\/+|\/+$/g,'')+'/' : '') + file.name;
  const q = `upload?library=${encodeURIComponent(lib)}&path=${encodeURIComponent(rel)}`;
  const st = await api(q);
  let off = st.received || 0;
  if (off >= file.size && file.size>0){ row.querySelector('.st').textContent=T('已存在'); row.querySelector('.bar i').style.width='100%'; return; }
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
  row.querySelector('.bar i').style.width='100%';
}
$('#btn-up').onclick = guard(async()=>{
  const files = Array.from($('#up-files').files); const lib=$('#up-lib').value; const sub=$('#up-sub').value.trim();
  if(!lib) throw new Error(T('先添加一个库根')); if(!files.length) throw new Error(T('没选文件'));
  $('#btn-up').disabled=true;
  try{ for(const f of files){ const row=document.createElement('div'); row.className='lrow'; row.innerHTML=`<div class="lead">${icon('upload')}</div><div class="txt"><div class="t">${esc(f.name)}</div><div class="s st">${esc(T('等待'))}</div>${progress(0)}</div>`; $('#up-list').prepend(row); try{ await uploadOne(f,lib,sub,row);}catch(e){ const st=row.querySelector('.st'); st.className='e st'; st.textContent=T('失败: {0}', e.message); } } toast(T('上传结束，记得扫描库')); }
  finally{ $('#btn-up').disabled=false; loadStatus(); }
});

// ── 任务 ──
const stCls = (s) => (s==='done'||s==='completed')?'ok':((s==='error'||s==='failed')?'err':((s==='running'||s==='uploading'||s==='active')?'warn':''));
const stTag = (s) => tag(stCls(s), s);
async function loadJobs(){
  const r = await api('jobs');
  $('#jobs').innerHTML = r.jobs.map(j=>`<div class="lrow"><div class="txt"><div class="t">${esc(j.kind)}${stTag(j.state)}</div><div class="s"><span class="mono">${esc(j.id)}</span> · ${esc(fmtTime(j.createdAt))}${j.progress!=null?' · '+(j.progress*100).toFixed(0)+'%':''}${j.message?' · '+esc(j.message):''}</div>${j.progress!=null&&stCls(j.state)==='warn'?progress(j.progress):''}${j.error?`<div class="e">${esc(j.error)}</div>`:''}</div><div class="trail"><button class="b text danger" data-jdel="${esc(j.id)}">${esc(T('删除'))}</button></div></div>`).join('') || empty(T('没有互联任务'), 'jobs');
  $('#jobs').querySelectorAll('[data-jdel]').forEach(b=>b.onclick=guard(async()=>{ await del('jobs/'+encodeURIComponent(b.dataset.jdel)); loadJobs(); }));
}

// ── 下载 ──
async function loadDownloads(){
  const r = await api('downloads');
  $('#dl-cap').textContent = r.supported ? T('后端: {0}', r.backend||'ok') : T('下载后端未配置：在「设置」填 qBittorrent WebUI 地址并重启。');
  $('#btn-dl-add').disabled = !r.supported;
  $('#dls').innerHTML = r.jobs.map(j=>{ const p = j.stageProgress!=null ? Number(j.stageProgress) : null;
    return `<div class="lrow"><div class="lead">${icon(j.mediaKind==='tv'||j.mediaKind==='movie'?'video':'downloads')}</div><div class="txt"><div class="t">${esc(j.title)}${stTag(j.lifecycle)}</div><div class="s">${esc([j.mediaKind, j.stage, p!=null?(p*100).toFixed(0)+'%':''].filter(Boolean).join(' · '))}</div><div class="s mono">${esc(j.jobId)}</div>${p!=null&&stCls(j.lifecycle)!=='ok'?progress(p):''}${j.lastError?`<div class="e">${esc(j.lastError)}</div>`:''}</div><div class="trail"><button class="b text" data-dl="cancel" data-id="${esc(j.jobId)}">${esc(T('取消'))}</button><button class="b text" data-dl="retry" data-id="${esc(j.jobId)}">${esc(T('重试'))}</button><button class="b text danger" data-dl="delete" data-id="${esc(j.jobId)}">${esc(T('清理'))}</button></div></div>`; }).join('') || empty(T('没有下载任务'), 'downloads');
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
  $('#subs').innerHTML = (r.subscriptions||[]).map(s=>`<div class="lrow"><div class="lead">${icon('subscriptions')}</div><div class="txt"><div class="t">${esc(s.title)}${s.enabled?tag('ok', T('启用')):tag('', T('停用'))}</div><div class="s">${esc(s.searchQuery)} · ${esc(s.mediaKind)} · ${esc(s.mode)}</div><div class="s">${s.resourceProviderLabel?esc(s.resourceProviderLabel):esc(T('没有可用来源'))}${s.itemCounts?' · '+esc(fmtCounts(s.itemCounts)):''} · ${esc(T('最近检查 {0}', s.lastCheckedAt?fmtTime(s.lastCheckedAt):'—'))}</div>${s.lastError?`<div class="e">${esc(s.lastError)}</div>`:''}</div><div class="trail"><button class="b text" data-sub="enable" data-id="${esc(s.subscriptionId)}" data-enabled="${s.enabled?'0':'1'}">${esc(s.enabled?T('停用'):T('启用'))}</button><button class="b text" data-sub="check" data-id="${esc(s.subscriptionId)}"${s.enabled?'':` disabled title="${esc(T('已停用的订阅不检查，请先启用'))}"`}>${esc(T('检查'))}</button><button class="b text danger" data-sub="delete" data-id="${esc(s.subscriptionId)}">${esc(T('删除'))}</button></div></div>`).join('') || empty(T('还没有订阅'), 'subscriptions');
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
const btDomainBoxes = (attr, on) => BT_DOMAINS.map(([k,l])=>`<label class="fchip"><input type="checkbox" ${attr}="${k}" ${on.includes(k)?'checked':''}><span>${esc(l)}</span></label>`).join('');
const btPicked = (root, attr) => Array.from(root.querySelectorAll(`[${attr}]`)).filter(e=>e.checked).map(e=>e.getAttribute(attr));
$('#bt-domains').innerHTML = btDomainBoxes('data-bt-add-domain', BT_DOMAINS.map(d=>d[0]));
const swLabel = (attrs, on, text) => `<label class="check"><input type="checkbox" class="sw" ${attrs} ${on?'checked':''}><span>${esc(text)}</span></label>`;
function btRow(x){
  const label = Object.fromEntries(BT_DOMAINS);
  const eff = x.effectiveDomains||[];
  const off = (x.domains||[]).filter(d=>!eff.includes(d));
  const state = !x.enabled ? tag('', T('已停用')) : (x.active===true ? tag('ok', T('生效中')) : (x.active===false ? tag('warn', T('未参与资源搜索')) : ''));
  const sep = T('、');
  return `<div class="bt-row inset" data-id="${esc(x.id)}">
    <div class="txt"><div class="t">${esc(x.displayName)}${state}</div><div class="s">${esc(x.host)}</div>
    <div class="s">${esc(T('适用：{0}', eff.map(d=>label[d]||d).join(sep)||T('无')))}${off.length?esc(T('；对 {0} 不生效', off.map(d=>label[d]||d).join(sep))):''}</div></div>
    <div class="bt-edit" style="display:none">
      <div class="grid"><label class="f">${esc(T('名称（可选）'))}<input type="text" data-k="name" value="${esc(x.name||'')}"></label><label class="f">${esc(T('新地址（留空不改）'))}<input type="text" data-k="url"></label></div>
      <div class="fchips">${btDomainBoxes('data-bt-domain', x.domains||[])}</div>
      <div class="row">${swLabel('data-k="enabled"', x.enabled, T('启用'))}${swLabel('data-k="allowInsecureHttp"', x.allowInsecureHttp, T('允许明文 HTTP（仅受信任局域网）'))}<span class="sp"></span><button class="b" data-bt="save">${esc(T('保存'))}</button></div>
    </div>
    <div class="row" style="margin-bottom:0"><button class="b sec" data-bt="edit">${esc(T('编辑'))}</button><button class="b text" data-bt="reprobe">${esc(T('重新检测'))}</button><span class="sp"></span><button class="b text danger" data-bt="delete">${esc(T('删除'))}</button></div></div>`;
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
      if (act==='delete'){ if(!await ask(T('删除这个 BT 站？（已建的订阅会改用其它来源，没有可用来源时暂停）'), true)) return; res = await del('resource-indexers/bt-sites/'+id); toast(T('已删除')); }
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
  return `<div class="ri-row inset" data-id="${esc(x.id||'')}"><div class="grid" style="margin:0">
    <label class="f">${esc(T('名称'))}<input type="text" data-k="name" value="${esc(x.name||'')}"></label>
    <label class="f">${esc(T('地址（https://…/api；带 ?apikey= 会自动拆进 key 栏）'))}<input type="text" data-k="endpoint" value="${esc(x.endpoint||'')}"></label>
    <label class="f">API key${keySet}<input type="password" data-k="apiKey" value="" autocomplete="off"></label>
    <label class="f">${esc(T('优先级（小的先搜）'))}<input type="number" data-k="priority" value="${esc(x.priority??100)}"></label>
    <label class="f">${esc(T('分类（逗号分隔，可空）'))}<input type="text" data-k="categories" value="${esc((x.categories||[]).join(','))}"></label></div>
    <div class="row" style="margin-bottom:0">${swLabel('data-k="enabled"', x.enabled!==false, T('启用'))}${swLabel('data-k="allowInsecureHttp"', x.allowInsecureHttp, T('允许明文 HTTP（仅受信任局域网）'))}${x.apiKeySet?swLabel('data-k="clearApiKey"', false, T('清除已存的 key')):''}<span class="sp"></span><button class="b text danger" data-ri-rm>${esc(T('移除'))}</button></div></div>`;
}
function bindRiRemove(){ $('#ri-torznab').querySelectorAll('[data-ri-rm]').forEach(b=>b.onclick=()=>b.closest('.ri-row').remove()); }
function renderIndexers(r){
  renderBtSites(r);
  $('#ri-torznab').innerHTML = (r.torznab||[]).map(riRow).join('') || `<p class="sup" id="ri-empty">${esc(T('还没有 Torznab indexer。'))}</p>`;
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
const pullButton = (key, pulling) => `<button class="b sec" data-pull="${esc(key)}" ${pulling?'disabled':''}>${icon('downloads')}${esc(pulling?T('下载中…'):T('下载'))}</button>`;
const modelBytes = (m) => m.totalBytes ? fmtBytes(m.obtainedBytes)+' / '+fmtBytes(m.totalBytes) : '';
const modelRow = (name, sub, m, key) => `<div class="lrow"><div class="lead">${icon('models')}</div><div class="txt"><div class="t">${name}${readyTag(m)}</div>${sub?`<div class="s">${sub}</div>`:''}${m.pulling&&m.totalBytes?progress(m.obtainedBytes/m.totalBytes):''}</div>${m.ready||m.error?'':`<div class="trail">${pullButton(key, m.pulling)}</div>`}</div>`;
async function loadModels(){
  const r = await api('models');
  $('#asr-models').innerHTML = r.asr.map(m=>modelRow(`${esc(m.name||m.tag)} <span class="mono muted">${esc(m.tag)}</span>`, esc([[m.variant,m.provider].filter(Boolean).join(' / '), modelBytes(m)].filter(Boolean).join(' · ')), m, m.tag)).join('') || empty(T('无'), 'models');
  $('#ocr-model').innerHTML = (r.ocrModels && r.ocrModels.length) ? r.ocrModels.map(m=>modelRow(esc(m.name||m.key), esc(modelBytes(m)), m, 'ocr:'+m.key)).join('')
    : r.ocr ? modelRow('OCR', esc(fmtBytes(r.ocr.obtainedBytes)+' / '+fmtBytes(r.ocr.totalBytes)), r.ocr, 'ocr') : empty(T('OCR 服务不可用'), 'models');
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
    ? `<div class="card-head"><div><h2 style="margin:0">${esc(T('已登录：{0}', a.account.username))}</h2><p class="sup">${esc(a.account.server || 'AnkiWeb')}</p></div></div>
       <div class="actions"><button class="b" id="btn-anki-sync">${icon('refresh')}${esc(T('立即同步'))}</button><button class="b sec" id="btn-anki-refresh">${esc(T('刷新牌组 / 笔记类型'))}</button><button class="b text" id="btn-anki-relogin">${esc(T('重新登录'))}</button><span class="sp"></span><button class="b text danger" id="btn-anki-logout">${esc(T('退出登录'))}</button></div>`
    : `<div class="grid" style="margin:0">
       <label class="f" style="grid-column:1/-1">${esc(T('同步服务器（自建服务器地址，如 http://nas:8080/；留空为 AnkiWeb）'))}<input id="anki-endpoint" value="${esc(a.account ? (a.account.server || '') : '')}"></label>
       <label class="f">${esc(T('用户名'))}<input id="anki-user" value="${esc(a.account ? a.account.username : '')}"></label>
       <label class="f">${esc(T('密码'))}<input type="password" id="anki-pass"></label></div>
       <div class="actions"><button class="b" id="btn-anki-login">${esc(T('登录并下载牌组集合'))}</button>${a.account ? `<button class="b text" id="btn-anki-relogin-cancel">${esc(T('取消'))}</button>` : ''}</div>
       <p class="sup">${esc(T('密码只用来换取同步凭据，不保存。同一服务器与用户名重新登录只换凭据，本机的牌组集合与未同步的卡都保留。'))}</p>`;
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
  $('#anki-config').innerHTML = `${ph}<div class="grid" style="margin:0">
    <label class="f">${esc(T('牌组'))}<select id="anki-deck">${opt(st.decks, st.deck)}</select></label>
    <label class="f">${esc(T('笔记类型'))}<select id="anki-nt">${opt(st.noteTypes, st.noteType)}</select></label>
    <label class="f">${esc(T('标签（空格分隔）'))}<input id="anki-tags" value="${esc(st.tags)}"></label></div>
    <h2 class="sub-h">${esc(T('字段映射'))}</h2><p class="sup">${esc(T('每个字段填占位符，如 {expression}、{reading}、{glossary}、{sentence}；可组合。没填映射时卡片会留着等，不会丢。'))}</p>
    <div class="grid">${st.fields.map(f=>`<label class="f">${esc(f)}<input list="anki-ph" data-field="${esc(f)}" value="${esc(st.fieldMappings[f]||'')}"></label>`).join('')}</div>
    <div class="actions"><button class="b" id="btn-anki-save">${esc(T('保存'))}</button></div>`;
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
  $('#srs-status').innerHTML = kvHtml(kv);
  const served = {}; (st.profiles||[]).forEach(p=>served[p.uid]=p);
  const list = found.profiles || [];
  const key = JSON.stringify([list.map(p=>[p.uid,p.name,p.served,p.missing]), st.config, ac.enabled, ac.bind, ac.port, ac.apiKeySet, ac.profileKeysSet]);
  // 状态每轮刷新；表单只在内容变了时重画，不冲掉正在编辑的输入。
  const statusOf = (uid)=>{ const p = served[uid]; if(!p) return ''; return `${SRS_STATE[p.state]||p.state}${p.notes!=null?T(' · {0} 条笔记', p.notes):''}${p.lastSyncAt?T(' · 同步于 {0}', fmtTime(p.lastSyncAt)):''}${p.lastError?' · '+p.lastError:''}`; };
  if (key === srsFormKey) { document.querySelectorAll('[data-srs-status]').forEach(el=>{ el.textContent = statusOf(el.dataset.srsStatus); }); return; }
  srsFormKey = key;
  const cfg = st.config;
  const def = st.defaultProfile || cfg.defaultProfile;
  const H = {serve:T('提供'), def:T('默认'), prof:T('配置文件'), dev:T('设备'), state:T('状态')};
  $('#srs-profiles').innerHTML = list.length ? `<div class="tbl"><table class="rt"><tr class="h"><th>${esc(H.serve)}</th><th>${esc(H.def)}</th><th>${esc(H.prof)}</th><th>${esc(H.dev)}</th><th>${esc(H.state)}</th><th></th></tr>${list.map(p=>`<tr>
      <td data-label="${esc(H.serve)}"><input type="checkbox" class="sw" data-srs-serve="${esc(p.uid)}" ${p.served?'checked':''}></td>
      <td data-label="${esc(H.def)}"><input type="radio" name="srs-def" data-srs-def="${esc(p.uid)}" ${p.uid===def?'checked':''} ${p.served?'':'disabled'}></td>
      <td data-label="${esc(H.prof)}"><div>${esc(p.name||p.uid)}<div class="small muted mono">${esc(p.uid)}${p.missing?esc(T(' · 同步目录里已没有')):''}</div></div></td>
      <td class="small" data-label="${esc(H.dev)}"><div>${esc((p.devices||[]).join(T('、')))}${p.noteCount!=null?`<div class="muted">${esc(T('{0} 条笔记', p.noteCount))}</div>`:''}</div></td>
      <td class="small" data-label="${esc(H.state)}" data-srs-status="${esc(p.uid)}">${esc(statusOf(p.uid))}</td>
      <td>${p.served?`<button class="b sec" data-srs-sync="${esc(p.uid)}">${esc(T('同步'))}</button>`:''}</td></tr>`).join('')}</table></div>`
    : empty(T('同步目录里还没有任何配置文件：先让一台设备经互联同步一次复习数据。'), 'srs');
  document.querySelectorAll('[data-srs-serve]').forEach(el=>el.onchange = guard(async()=>{
    await put('srs', el.checked ? {addProfiles:[el.dataset.srsServe]} : {removeProfiles:[el.dataset.srsServe]});
    toast(el.checked ? T('已开始提供') : T('已停止提供')); srsFormKey=null; loadSrs();
  }));
  document.querySelectorAll('[data-srs-def]').forEach(el=>el.onchange = guard(async()=>{ await put('srs', {defaultProfile: el.dataset.srsDef}); toast(T('已设为默认')); srsFormKey=null; loadSrs(); }));
  document.querySelectorAll('[data-srs-sync]').forEach(el=>el.onclick = guard(async()=>{ await post('srs/sync', {profile: el.dataset.srsSync}); toast(T('已同步')); loadSrs(); }));

  const servedList = list.filter(p=>p.served);
  $('#srs-mining').innerHTML = `<p class="sup" style="margin:0">${esc(T('已配对设备「制卡到已配对设备」时卡片落到哪。手机可以在自己的设置里另选；没选时，手机当前的配置文件本机有就落进那份，否则落进默认那份。'))}</p>
    <div class="grid"><label class="f">${esc(T('落到'))}<select id="srs-target">${[['auto',T('自动（没配好 Anki 时进复习）')],['review',T('Fushi 复习')],['anki','Anki']].map(([v,l])=>`<option value="${v}" ${cfg.miningTarget===v?'selected':''}>${esc(l)}</option>`).join('')}</select></label>
    <label class="f">${esc(T('换日时刻（0–23 点）'))}<input type="number" min="0" max="23" id="srs-rollover" value="${cfg.rolloverHour}"></label>
    ${servedList.map(p=>`<label class="f">${esc(T('{0} 的制卡牌组（空 = 默认牌组）', p.name||p.uid))}<input data-srs-deck="${esc(p.uid)}" value="${esc((cfg.miningDecks||{})[p.uid]||'')}"></label>`).join('')}</div>
    <div class="actions"><button class="b" id="btn-srs-save">${esc(T('保存'))}</button></div>`;
  $('#btn-srs-save').onclick = guard(async()=>{
    const miningDecks = {}; document.querySelectorAll('[data-srs-deck]').forEach(el=>{ if(el.value.trim()) miningDecks[el.dataset.srsDeck]=el.value.trim(); });
    await put('srs', {miningTarget: $('#srs-target').value, rolloverHour: parseInt($('#srs-rollover').value,10), miningDecks});
    toast(T('已保存')); srsFormKey=null; loadSrs();
  });

  const setNote = (isSet) => isSet ? ` <span class="muted">${esc(T('(已设置，留空不改)'))}</span>` : '';
  $('#srs-ankiconnect').innerHTML = `<div class="row" style="margin-top:16px">${swLabel('id="ac-enabled"', ac.enabled, T('开关'))}</div>
    <div class="grid">
    <label class="f">${esc(T('监听地址（127.0.0.1 = 只限本机）'))}<input id="ac-bind" value="${esc(ac.bind||'127.0.0.1')}"></label>
    <label class="f">${esc(T('端口'))}<input type="number" id="ac-port" value="${ac.port||8765}"></label>
    <label class="f">${esc(T('共用 key（落到默认配置文件）'))}${setNote(ac.apiKeySet)}<input type="password" id="ac-key" value=""></label>
    ${servedList.map(p=>`<label class="f">${esc(T('{0} 专用 key', p.name||p.uid))}${setNote((ac.profileKeysSet||{})[p.uid])}<input type="password" data-ac-key="${esc(p.uid)}" value=""></label>`).join('')}</div>
    <div class="actions"><button class="b" id="btn-ac-save">${esc(T('保存'))}</button>${ac.apiKeySet?`<button class="b text danger" id="btn-ac-clear">${esc(T('清除共用 key'))}</button>`:''}</div>`;
  $('#btn-ac-save').onclick = guard(async()=>{
    const body = {enabled: $('#ac-enabled').checked, bind: $('#ac-bind').value.trim(), port: parseInt($('#ac-port').value,10)};
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
  ['language',T('界面语言（Language）'),'select:en,zh','general'],['deviceName',T('设备名'),'text','general'],
  ['port',T('互联端口'),'number','network'],['bind',T('绑定地址'),'text','network'],['tls','TLS','bool','network'],['lanRequiresPin',T('局域网配对必须 PIN'),'bool','network'],['adminPort',T('WebUI 端口'),'number','network'],
  ['subtitleLanguage',T('字幕语言'),'text','media'],['metadataLocale',T('刮削资料语言（BCP-47，如 ja / zh-CN）'),'text','media'],
  ['scanScrape',T('扫描后自动补刮视频资料'),'bool','media'],['tmdbApiKey',T('TMDB API key（服务端没有内置 key，不填则 TMDB 不可用）'),'secret:tmdbApiKeySet','media'],['scanPrune',T('扫描后清理文件已消失的视频条目'),'bool','media'],['uploadQuotaBytes',T('上传配额（字节）'),'number','media'],
  ['profileTransfer',T('允许已配对设备推送 / 拉取配置文件（Profile）'),'bool','access'],['remoteUpdate',T('允许已配对设备远程更新本服务端（仅发布包；装完退出码 75，由服务管理器重启）'),'bool','access'],['leaderboardLink',T('允许「我的设备」跟随本机 Fushi 排行榜账户自动登录'),'bool','access'],['lookupChineseScriptVariants',T('中文查词简繁互查（只管不自带开关的浏览器扩展 / 旧客户端；新版 app 用自己的开关）'),'bool','access'],
  ['ffmpeg',T('ffmpeg 路径（空=PATH）'),'text','tools'],['ffprobe',T('ffprobe 路径（空=PATH）'),'text','tools'],['onnxruntimeLibrary',T('onnxruntime 动态库'),'text','tools'],
  ['torrent.engine',T('torrent 引擎'),'select:auto,embedded,qbittorrent','downloads'],['torrent.library',T('内置引擎库路径（空=随包/系统）'),'text','downloads'],['torrent.listen',T('libtorrent 监听接口'),'text','downloads'],
  ['qbittorrent.url',T('qBittorrent WebUI 地址'),'text','downloads'],['qbittorrent.username',T('qBittorrent 用户名'),'text','downloads'],['qbittorrent.password',T('qBittorrent 密码'),'password','downloads'],
  ['ai.preset',T('AI 提供商（手机「AI 下视频」选本机执行时用；空 = 不用 AI、不发任何 AI 请求）'),'dyn:aiPresets','ai'],['ai.apiKey','AI API key','secret:ai.apiKeySet','ai'],
  ['ai.model',T('AI 模型（空 = 预设起点模型）'),'text','ai'],['ai.baseUrl',T('AI 接口地址（空 = 预设地址）'),'text','ai'],['ai.protocol',T('AI 协议（空 = 跟随预设）'),'select:,openAiCompatible,anthropicMessages,geminiGenerateContent','ai'],
  ['ai.reasoningEffort',T('AI 推理档位'),'select:none,low,medium,high','ai'],['ai.allowInsecureHttp',T('AI 允许明文 HTTP（本地推理服务）'),'bool','ai'],['ai.webKnowledge',T('AI 联网资料（维基辅助识别作品）'),'bool','ai'],['ai.libraryOrganize',T('扫描入库后自动 AI 整理库（把该在一起的归进合集，按量计费）'),'bool','ai'],
];
const SETTING_GROUPS = [['general',T('通用')],['network',T('网络与配对')],['media',T('媒体与刮削')],['access',T('设备权限')],['tools',T('外部工具')],['downloads',T('下载')],['ai',T('AI 助手')]];
// 改后要重启 serve 才生效的项（同保存键旁的提示）。
const RESTART = new Set(['port','bind','tls','adminPort','ffmpeg','ffprobe','onnxruntimeLibrary','torrent.engine','torrent.library','torrent.listen','qbittorrent.url','qbittorrent.username','qbittorrent.password']);
const LANGUAGE_NAMES = {en:'English', zh:'中文'};
const LABEL_SPLIT = new RegExp('^(.+?)\\s*[(' + String.fromCharCode(0xFF08) + '](.+)[)' + String.fromCharCode(0xFF09) + ']$');
const splitLabel = (l) => { const m = LABEL_SPLIT.exec(l); return m ? [m[1], m[2]] : [l, '']; };
let settingsCache=null;
async function loadSettings(){
  const s = await api('settings'); const first=!settingsCache; settingsCache=s;
  // 远程访问卡片有自己的保存键：主表单保存后只刷新 P2P 状态，不冲掉它未保存的编辑。
  if(first) renderRemoteReach(s); else renderP2pState(s.p2pStatus);
  const found = s.torrent && s.torrent.embeddedLibraryFound;
  const setNote = (isSet) => isSet ? tag('ok', T('(已设置，留空不改)')) : '';
  const field = ([k,label,type]) => {
    let v = k.includes('.') ? (s[k.split('.')[0]]||{})[k.split('.')[1]] : s[k]; const id='f-'+k.replace('.','-');
    let extra = '';
    if(k==='torrent.library'&&!v) extra = tag(found?'ok':'warn', found ? T('已找到 {0}', found) : T('未找到随包库'));
    if(k==='ai.webKnowledge'&&!s.ai) v=true;
    if(k==='ai.preset'&&s.ai) extra = s.ai.status==='ready' ? tag('ok', T('可用')) : tag('warn', T('未配全：{0}', s.ai.problem||''));
    let ctl;
    if(type.startsWith('dyn:')) ctl = `<select id="${id}">${['',...(s[type.slice(4)]||[])].map(o=>`<option value="${esc(o)}" ${o===(v??'')?'selected':''}>${esc(o)}</option>`).join('')}</select>`;
    else if(type==='bool') ctl = `<input type="checkbox" class="sw" id="${id}" ${v?'checked':''}>`;
    else if(type.startsWith('select:')) ctl = `<select id="${id}">${type.slice(7).split(',').map(o=>`<option value="${esc(o)}" ${o===v?'selected':''}>${esc(k==='language'?LANGUAGE_NAMES[o]:o)}</option>`).join('')}</select>`;
    else if(type==='password'){ extra += setNote(s.qbittorrent.passwordSet); ctl = `<input type="password" id="${id}" value="" autocomplete="off">`; }
    else if(type.startsWith('secret:')){ const sk=type.slice(7); const isSet = sk.includes('.') ? (s[sk.split('.')[0]]||{})[sk.split('.')[1]] : s[sk]; extra += setNote(isSet); ctl = `<input type="password" id="${id}" value="" autocomplete="off">`; }
    else ctl = `<input type="${type}" id="${id}" value="${esc(v??'')}">`;
    const [title, sub] = splitLabel(label);
    return `<div class="srow${type==='bool'?' swr':''}"><label class="txt" for="${id}"><span class="t">${esc(title)}${RESTART.has(k)?tag('warn', T('需重启')):''}${extra}</span>${sub?`<span class="s">${esc(sub)}</span>`:''}</label><div class="ctl">${ctl}</div></div>`;
  };
  $('#settings-form').innerHTML = SETTING_GROUPS.map(([g,name])=>`<h3 class="sh">${esc(name)}</h3><div class="list" style="margin-top:16px">${FIELDS.filter(f=>f[3]===g).map(field).join('')}</div>`).join('');
}
$('#btn-settings-save').onclick = guard(async()=>{
  const body={qbittorrent:{},torrent:{},ai:{}};
  for(const [k,,type] of FIELDS){ const el=$('#f-'+k.replace('.','-')); let v=el.value; if(type==='bool') v=el.checked; else if(type==='number') v=Number(v); if(type!=='bool'&&type!=='number'&&v==='') v=null;
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
  $('#ai-sessions').innerHTML = r.sessions.map(s=>`<div class="lrow click${s.id===aiOpen?' sel':''}" data-ai="${esc(s.id)}" tabindex="0" role="button"><div class="lead">${icon('ai')}</div><div class="txt"><div class="t">${esc(s.title||T('新对话'))}</div><div class="s">${esc(aiDevice(s))} · ${esc(fmtTime(s.updatedAt))} · ${esc(s.tokens)} tokens</div></div></div>`).join('') || empty(T('还没有 AI 助手会话'), 'ai');
  $('#ai-sessions').querySelectorAll('[data-ai]').forEach(el=>{ const open = guard(async()=>{ aiOpen=el.dataset.ai; await loadAiDetail(); $('#ai-sessions').querySelectorAll('[data-ai]').forEach(x=>x.classList.toggle('sel', x===el)); }); el.onclick=open; el.onkeydown=(e)=>{ if(e.key==='Enter'||e.key===' '){ e.preventDefault(); open(); } }; });
  if (aiOpen) await loadAiDetail();
}
async function loadAiDetail(){
  const s = await api('ai/sessions/'+encodeURIComponent(aiOpen));
  $('#ai-detail').style.display='block';
  $('#ai-detail-title').textContent = s.title || T('新对话');
  $('#ai-detail-meta').textContent = `${aiDevice(s)} · ${fmtTime(s.createdAt)} → ${fmtTime(s.updatedAt)} · ${s.tokens} tokens`;
  $('#ai-entries').innerHTML = s.entries.map(e=>`<div class="entry">${tag(e.kind==='assistant'?'info':'', AI_KIND[e.kind]||e.kind)}<div>${esc(e.toolName?e.toolName+(e.text?' — '+e.text:''):(e.text||''))} ${e.status&&e.kind!=='user'&&e.kind!=='assistant'?stTag(e.status):''} ${e.errorCode?`<span class="small" style="color:var(--err)">${esc(e.errorCode)}</span>`:''}</div></div>`).join('') || empty(T('无'));
}

// ── 日志 ──
async function loadLogs(){ const r = await api('logs'); const pre=$('#logs'); const atBottom = pre.scrollTop+pre.clientHeight >= pre.scrollHeight-10; pre.textContent = r.lines.join('\n'); if(atBottom) pre.scrollTop=pre.scrollHeight; }
$('#btn-log-refresh').onclick = guard(loadLogs);

// ── 轮询 ──
const loaders = {status:loadStatus, pairing:loadPairing, libraries:loadLibraries, upload:async()=>{ await loadLibraries(); const s=await api('status'); $('#up-quota').textContent=T('配额已用 {0} / {1}', fmtBytes(s.uploadUsedBytes), fmtBytes(s.uploadQuotaBytes)); }, jobs:loadJobs, downloads:loadDownloads, subscriptions:async()=>{ await loadSubscriptions(); await loadIndexers(false); }, ai:loadAi, anki:loadAnki, srs:loadSrs, models:loadModels, settings:async()=>{ if(!settingsCache) await loadSettings(); else renderP2pState(await api('p2p')); }, logs:async()=>{ if($('#log-auto').checked) await loadLogs(); }};
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
      .replaceAll('__FUSHI_LOGO__', kWebUiLogoDataUri);
}

/// 按界面语言出登录页；[tokenError] = 上次提交的 token 不对。
String renderAdminLogin(String language, {bool tokenError = false}) {
  final bool en = language == ServerConfig.languageEnglish;
  String t(String zh) => en ? (kWebUiEnglish[zh] ?? zh) : zh;
  String html = adminLoginHtml
      .replaceFirst('__FUSHI_HTML_LANG__', _htmlLang(language))
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
