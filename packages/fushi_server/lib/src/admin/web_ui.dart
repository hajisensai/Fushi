/// WebUI 静态页：一个 HTML 字符串，原生 JS，无构建步骤、无第三方脚本。
///
/// 页面只吃 `/api/admin/*` JSON；所有状态都轮询（2~5 秒），不做 WebSocket——
/// 单管理员局域网面板，轮询足够且没有连接状态机要维护。
library;

const String adminLoginHtml = r'''<!doctype html>
<html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
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
<button type="submit">登录</button>
<p class="hint">token 在 fushi_server.yaml 的 admin_token；忘了用 <code>fushi_server admin reset-token</code> 重生成。</p>
</form></body></html>''';

const String adminWebUiHtml = r'''<!doctype html>
<html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
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
input,select{padding:8px;border-radius:8px;border:1px solid #333;background:#0e1013;color:#eee;font-size:13px}
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
<button data-s="subscriptions">订阅</button><button data-s="models">模型</button><button data-s="settings">设置</button><button data-s="logs">日志</button>
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
<div class="card"><h2>已配对设备</h2><table><thead><tr><th>设备</th><th>peer id</th><th>最近地址</th><th>配对时间</th><th></th></tr></thead><tbody id="peers"></tbody></table></div>
</section>

<section id="s-libraries">
<div class="card"><h2>扫描根</h2>
<table><thead><tr><th>id</th><th>路径</th><th>类型</th><th>状态</th><th></th></tr></thead><tbody id="libs"></tbody></table>
<div class="row" style="margin-top:12px">
<input type="text" id="lib-path" placeholder="/srv/media/anime" style="flex:1">
<select id="lib-kind"><option value="video">video</option><option value="book">book (epub)</option></select>
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
</section>

<section id="s-models">
<div class="card"><h2>ASR 模型</h2>
<table><thead><tr><th>语言</th><th>就绪</th><th>变体 / provider</th><th>字节</th><th></th></tr></thead><tbody id="asr-models"></tbody></table></div>
<div class="card"><h2>漫画 OCR 模型</h2><div id="ocr-model"></div></div>
</section>

<section id="s-settings">
<div class="card"><h2>设置</h2>
<div class="grid" id="settings-form"></div>
<div class="row" style="margin-top:12px"><button class="b" id="btn-settings-save">保存</button><span class="small muted">端口 / TLS / 绑定 / qBittorrent / torrent / ffmpeg / onnxruntime 路径改后需重启 serve。</span></div>
</div>
</section>

<section id="s-logs">
<div class="card"><h2>最近日志</h2><div class="row"><button class="b sec" id="btn-log-refresh">刷新</button><label><input type="checkbox" id="log-auto" checked> 自动刷新</label></div><pre id="logs"></pre></div>
</section>

</main>
<div id="toast"></div>
<script>
'use strict';
const $ = (s) => document.querySelector(s);
const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const fmtBytes = (n) => { n = Number(n||0); const u=['B','KB','MB','GB','TB']; let i=0; while(n>=1024&&i<u.length-1){n/=1024;i++;} return n.toFixed(i?1:0)+' '+u[i]; };
const fmtTime = (v) => { if(!v) return ''; const d = typeof v==='number'? new Date(v): new Date(v); return isNaN(d)? String(v): d.toLocaleString(); };
let toastTimer; function toast(msg){ const t=$('#toast'); t.textContent=msg; t.style.display='block'; clearTimeout(toastTimer); toastTimer=setTimeout(()=>t.style.display='none',2600); }
async function api(path, opts){
  const r = await fetch('/api/admin/'+path, Object.assign({headers:{'Content-Type':'application/json'}}, opts||{}));
  if (r.status===401){ location.reload(); throw new Error('unauthorized'); }
  const j = await r.json().catch(()=>({}));
  if (!r.ok) throw new Error(j.error || ('HTTP '+r.status));
  return j;
}
const post = (p,b)=>api(p,{method:'POST',body:JSON.stringify(b||{})});
const del = (p)=>api(p,{method:'DELETE'});
const put = (p,b)=>api(p,{method:'PUT',body:JSON.stringify(b||{})});
function guard(fn){ return async (...a)=>{ try{ await fn(...a);}catch(e){ toast('失败: '+e.message);} }; }

// ── 导航 ──
let current='status';
document.querySelectorAll('nav button').forEach(b=>b.onclick=()=>{ current=b.dataset.s; document.querySelectorAll('nav button').forEach(x=>x.classList.toggle('on',x===b)); document.querySelectorAll('main section').forEach(s=>s.classList.toggle('on',s.id==='s-'+current)); refresh(); });

// ── 状态 ──
async function loadStatus(){
  const s = await api('status');
  $('#devname').textContent = s.deviceName + ' · ' + s.listen;
  const kv = [
    ['监听', s.listen + (s.tls?' (https)':' (http)')], ['设备 id', s.deviceId], ['TLS 指纹', s.fingerprint||'—'],
    ['运行时长', Math.floor(s.uptimeSeconds/3600)+'h '+Math.floor(s.uptimeSeconds%3600/60)+'m'], ['数据目录', s.dataDir],
    ['视频', s.videos], ['书', s.books], ['已配对', s.peers], ['库根', s.libraries],
    ['OCR 模型', s.ocr ? (s.ocr.ready?'就绪':'缺失') : '—'],
    ['下载后端', s.downloads ? (s.downloads.supported ? (s.downloads.backend||'ok') : '未配置') : '—'],
    ['订阅', s.subscriptionCount==null ? '—' : s.subscriptionCount],
    ['上传配额', fmtBytes(s.uploadUsedBytes)+' / '+fmtBytes(s.uploadQuotaBytes)],
  ];
  $('#status-grid').innerHTML = kv.map(([k,v])=>`<div class="kv"><b>${esc(k)}</b><span>${esc(v)}</span></div>`).join('');
  $('#scan-state').textContent = s.scanning ? '扫描中…' : (s.lastScan ? `上次 ${fmtTime(s.lastScanAt)}: ${s.lastScan}` : '尚未扫描');
  $('#btn-scan').disabled = !!s.scanning;
}
$('#btn-scan').onclick = guard(async()=>{ await post('scan'); toast('已开始扫描'); loadStatus(); });

// ── 配对 ──
async function loadPairing(){
  const p = await api('pairing');
  $('#pairing-pending').innerHTML = p.pending
    ? `<p>${esc(p.pending.deviceName||'未知设备')} <span class="muted">(${esc(p.pending.remoteAddress||'?')})</span> 请求配对，请在该设备输入：</p><div class="pin">${esc(p.pending.pin)}</div><p class="small muted">${fmtTime(p.pending.createdAt)}</p>`
    : '<p class="muted">没有待处理的配对。在 Fushi 里添加互联设备并输入本机地址，PIN 会显示在这里。</p>';
  $('#peers').innerHTML = p.peers.map(x=>`<tr><td>${esc(x.deviceName||'—')}</td><td class="small muted">${esc(x.peerId)}</td><td>${esc(x.lastSeenIp||'')}</td><td>${fmtTime(x.pairedAtMs)}</td><td><button class="b danger" data-revoke="${esc(x.peerId)}">吊销</button></td></tr>`).join('') || '<tr><td colspan="5" class="muted">无</td></tr>';
  $('#peers').querySelectorAll('[data-revoke]').forEach(b=>b.onclick=guard(async()=>{ if(!confirm('吊销该设备？')) return; await del('pairing/peers/'+encodeURIComponent(b.dataset.revoke)); loadPairing(); }));
}

// ── 库 ──
async function loadLibraries(){
  const r = await api('libraries');
  $('#libs').innerHTML = r.libraries.map(l=>`<tr><td>${esc(l.id)}</td><td>${esc(l.path)}</td><td>${esc(l.kind)}</td><td>${l.exists?'<span class="tag ok">存在</span>':'<span class="tag err">目录不存在</span>'}${l.enabled?'':' <span class="tag">禁用</span>'}</td><td><button class="b danger" data-rm="${esc(l.id)}">移除</button></td></tr>`).join('') || '<tr><td colspan="5" class="muted">还没有扫描根</td></tr>';
  $('#libs').querySelectorAll('[data-rm]').forEach(b=>b.onclick=guard(async()=>{ if(!confirm('从配置移除该库根？（不删文件、不删已入库条目）')) return; await del('libraries/'+encodeURIComponent(b.dataset.rm)); loadLibraries(); }));
  $('#up-lib').innerHTML = r.libraries.map(l=>`<option value="${esc(l.id)}">${esc(l.id)} — ${esc(l.path)}</option>`).join('');
}
$('#btn-lib-add').onclick = guard(async()=>{ await post('libraries',{path:$('#lib-path').value, kind:$('#lib-kind').value, id:$('#lib-id').value}); $('#lib-path').value=''; $('#lib-id').value=''; toast('已添加'); loadLibraries(); });

// ── 上传 ──
const CHUNK = 8*1024*1024;
async function uploadOne(file, lib, sub, row){
  const rel = (sub ? sub.replace(/^\/+|\/+$/g,'')+'/' : '') + file.name;
  const q = `upload?library=${encodeURIComponent(lib)}&path=${encodeURIComponent(rel)}`;
  const st = await api(q);
  let off = st.received || 0;
  if (off >= file.size && file.size>0){ row.querySelector('.st').textContent='已存在'; return; }
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
  row.querySelector('.st').textContent='完成';
}
$('#btn-up').onclick = guard(async()=>{
  const files = Array.from($('#up-files').files); const lib=$('#up-lib').value; const sub=$('#up-sub').value.trim();
  if(!lib) throw new Error('先添加一个库根'); if(!files.length) throw new Error('没选文件');
  $('#btn-up').disabled=true;
  try{ for(const f of files){ const row=document.createElement('div'); row.innerHTML=`<div class="row"><span style="flex:1">${esc(f.name)}</span><span class="st muted small">等待</span></div><div class="bar"><i style="width:0"></i></div>`; $('#up-list').prepend(row); try{ await uploadOne(f,lib,sub,row);}catch(e){ row.querySelector('.st').textContent='失败: '+e.message; } } toast('上传结束，记得扫描库'); }
  finally{ $('#btn-up').disabled=false; loadStatus(); }
});

// ── 任务 ──
const stTag = (s) => `<span class="tag ${(s==='done'||s==='completed')?'ok':((s==='error'||s==='failed')?'err':((s==='running'||s==='uploading'||s==='active')?'warn':''))}">${esc(s)}</span>`;
async function loadJobs(){
  const r = await api('jobs');
  $('#jobs').innerHTML = r.jobs.map(j=>`<tr><td class="small muted">${esc(j.id)}</td><td>${esc(j.kind)}</td><td>${stTag(j.state)}</td><td>${j.progress!=null?(j.progress*100).toFixed(0)+'%':''} <span class="small muted">${esc(j.message||'')}</span></td><td class="small">${fmtTime(j.createdAt)}</td><td class="small" style="color:var(--err)">${esc(j.error||'')}</td><td><button class="b danger" data-jdel="${esc(j.id)}">删除</button></td></tr>`).join('') || '<tr><td colspan="7" class="muted">无</td></tr>';
  $('#jobs').querySelectorAll('[data-jdel]').forEach(b=>b.onclick=guard(async()=>{ await del('jobs/'+encodeURIComponent(b.dataset.jdel)); loadJobs(); }));
}

// ── 下载 ──
async function loadDownloads(){
  const r = await api('downloads');
  $('#dl-cap').textContent = r.supported ? `后端: ${r.backend||'ok'}` : '下载后端未配置：在「设置」填 qBittorrent WebUI 地址并重启。';
  $('#btn-dl-add').disabled = !r.supported;
  $('#dls').innerHTML = r.jobs.map(j=>`<tr><td>${esc(j.title)}<div class="small muted">${esc(j.jobId)} · ${esc(j.mediaKind||'')}</div></td><td>${stTag(j.lifecycle)}</td><td>${j.stageProgress!=null?(Number(j.stageProgress)*100).toFixed(0)+'%':''} <span class="small muted">${esc(j.stage||'')}</span></td><td class="small" style="color:var(--err)">${esc(j.lastError||'')}</td><td class="row"><button class="b sec" data-dl="cancel" data-id="${esc(j.jobId)}">取消</button><button class="b sec" data-dl="retry" data-id="${esc(j.jobId)}">重试</button><button class="b danger" data-dl="delete" data-id="${esc(j.jobId)}">清理</button></td></tr>`).join('') || '<tr><td colspan="5" class="muted">无</td></tr>';
  $('#dls').querySelectorAll('[data-dl]').forEach(b=>b.onclick=guard(async()=>{ const id=encodeURIComponent(b.dataset.id); if(b.dataset.dl==='delete') await del('downloads/'+id); else await post('downloads/'+id+'/'+b.dataset.dl); loadDownloads(); }));
}
$('#btn-dl-add').onclick = guard(async()=>{ await post('downloads',{magnet:$('#dl-magnet').value, title:$('#dl-title').value, mediaKind:$('#dl-kind').value}); $('#dl-magnet').value=''; $('#dl-title').value=''; toast('已添加'); loadDownloads(); });

// ── 订阅 ──
async function loadSubscriptions(){
  const r = await api('subscriptions');
  $('#sub-cap').textContent = r.supported ? `后端: ${r.backend}；可用索引器: ${(r.providers||[]).join(', ')||'无'}` : '下载后端未配置，订阅不可用。';
  $('#btn-sub-add').disabled = !r.supported; $('#btn-sub-check-all').disabled = !r.supported;
  const sel = $('#sub-provider'); const cur = sel.value;
  sel.innerHTML = (r.providers||[]).map(p=>`<option value="${esc(p)}">${esc(p)}</option>`).join('');
  if (cur) sel.value = cur;
  const fmtCounts = (c)=> c ? Object.entries(c).map(([k,v])=>`${k} ${v}`).join(' · ') : '';
  $('#subs').innerHTML = (r.subscriptions||[]).map(s=>`<tr><td>${esc(s.title)}<div class="small muted">${esc(s.mediaKind)} · ${esc(s.mode)}</div></td><td class="small">${esc(s.searchQuery)}</td><td class="small">${esc(s.resourceProvider)}</td><td>${s.enabled?'<span class="tag ok">启用</span>':'<span class="tag">停用</span>'} ${s.lastError?`<div class="small" style="color:var(--err)">${esc(s.lastError)}</div>`:''}</td><td class="small">${esc(fmtCounts(s.itemCounts))}</td><td class="small">${s.lastCheckedAt?fmtTime(s.lastCheckedAt):'—'}</td><td class="row"><button class="b sec" data-sub="enable" data-id="${esc(s.subscriptionId)}" data-enabled="${s.enabled?'0':'1'}">${s.enabled?'停用':'启用'}</button><button class="b sec" data-sub="check" data-id="${esc(s.subscriptionId)}">检查</button><button class="b danger" data-sub="delete" data-id="${esc(s.subscriptionId)}">删除</button></td></tr>`).join('') || '<tr><td colspan="7" class="muted">无</td></tr>';
  $('#subs').querySelectorAll('[data-sub]').forEach(b=>b.onclick=guard(async()=>{ const id=encodeURIComponent(b.dataset.id);
    if(b.dataset.sub==='delete'){ if(!confirm('删除该订阅？（已下载的任务不受影响）')) return; await del('subscriptions/'+id); }
    else if(b.dataset.sub==='enable'){ await post('subscriptions/'+id+'/enable',{enabled:b.dataset.enabled==='1'}); }
    else { await post('subscriptions/'+id+'/check'); }
    loadSubscriptions(); }));
}
$('#btn-sub-add').onclick = guard(async()=>{ const after=$('#sub-after').value.trim(); await post('subscriptions',{title:$('#sub-title').value, searchQuery:$('#sub-query').value, mediaKind:$('#sub-kind').value, resourceProvider:$('#sub-provider').value, startAfterEpisode: after?Number(after):undefined}); $('#sub-title').value=''; $('#sub-query').value=''; toast('已创建'); loadSubscriptions(); });
$('#btn-sub-check-all').onclick = guard(async()=>{ await post('subscriptions/check'); toast('已触发检查'); loadSubscriptions(); });

// ── 模型 ──
async function loadModels(){
  const r = await api('models');
  $('#asr-models').innerHTML = r.asr.map(m=>`<tr><td>${esc(m.name||m.tag)} <span class="small muted">${esc(m.tag)}</span></td><td>${m.error?`<span class="tag err">${esc(m.error)}</span>`:(m.ready?'<span class="tag ok">就绪</span>':'<span class="tag">缺失</span>')}</td><td class="small">${esc(m.variant||'')} / ${esc(m.provider||'')}</td><td class="small">${m.totalBytes?fmtBytes(m.obtainedBytes)+' / '+fmtBytes(m.totalBytes):''}</td><td>${m.ready?'':`<button class="b" data-pull="${esc(m.tag)}" ${m.pulling?'disabled':''}>${m.pulling?'下载中…':'下载'}</button>`}</td></tr>`).join('');
  $('#ocr-model').innerHTML = r.ocr ? `<div class="row">${r.ocr.ready?'<span class="tag ok">就绪</span>':'<span class="tag">缺失</span>'} <span class="small muted">${fmtBytes(r.ocr.obtainedBytes)} / ${fmtBytes(r.ocr.totalBytes)}</span> ${r.ocr.ready?'':`<button class="b" data-pull="ocr" ${r.ocr.pulling?'disabled':''}>${r.ocr.pulling?'下载中…':'下载'}</button>`}</div>` : '<p class="muted">OCR 服务不可用</p>';
  document.querySelectorAll('[data-pull]').forEach(b=>b.onclick=guard(async()=>{ await post('models/pull',{model:b.dataset.pull}); toast('开始下载'); loadModels(); }));
}

// ── 设置 ──
const FIELDS = [
  ['deviceName','设备名','text'],['port','互联端口','number'],['bind','绑定地址','text'],['tls','TLS','bool'],['lanRequiresPin','局域网配对必须 PIN','bool'],
  ['subtitleLanguage','字幕语言','text'],['metadataLocale','刮削资料语言（BCP-47，如 ja / zh-CN）','text'],['ffmpeg','ffmpeg 路径（空=PATH）','text'],['ffprobe','ffprobe 路径（空=PATH）','text'],['onnxruntimeLibrary','onnxruntime 动态库','text'],['uploadQuotaBytes','上传配额（字节）','number'],['adminPort','WebUI 端口','number'],
  ['torrent.engine','torrent 引擎','select:auto,embedded,qbittorrent'],['torrent.library','内置引擎库路径（空=随包/系统）','text'],['torrent.listen','libtorrent 监听接口','text'],
  ['qbittorrent.url','qBittorrent WebUI 地址','text'],['qbittorrent.username','qBittorrent 用户名','text'],['qbittorrent.password','qBittorrent 密码','password'],
];
let settingsCache=null;
async function loadSettings(){
  const s = await api('settings'); settingsCache=s;
  const found = s.torrent && s.torrent.embeddedLibraryFound;
  $('#settings-form').innerHTML = FIELDS.map(([k,label,type])=>{ const v = k.includes('.') ? (s[k.split('.')[0]]||{})[k.split('.')[1]] : s[k]; const id='f-'+k.replace('.','-'); if(k==='torrent.library'&&!v) label += found ? `（已找到 ${found}）` : '（未找到随包库）';
    if(type==='bool') return `<label class="f">${esc(label)}<select id="${id}"><option value="true" ${v?'selected':''}>开</option><option value="false" ${!v?'selected':''}>关</option></select></label>`;
    if(type.startsWith('select:')) return `<label class="f">${esc(label)}<select id="${id}">${type.slice(7).split(',').map(o=>`<option value="${esc(o)}" ${o===v?'selected':''}>${esc(o)}</option>`).join('')}</select></label>`;
    if(type==='password') return `<label class="f">${esc(label)} ${s.qbittorrent.passwordSet?'<span class="muted">(已设置，留空不改)</span>':''}<input type="password" id="${id}" value=""></label>`;
    return `<label class="f">${esc(label)}<input type="${type}" id="${id}" value="${esc(v??'')}"></label>`; }).join('');
}
$('#btn-settings-save').onclick = guard(async()=>{
  const body={qbittorrent:{},torrent:{}};
  for(const [k,,type] of FIELDS){ const el=$('#f-'+k.replace('.','-')); let v=el.value; if(type==='bool') v=(v==='true'); else if(type==='number') v=Number(v); if(type!=='bool'&&type!=='number'&&v==='') v=null;
    if(k.includes('.')) body[k.split('.')[0]][k.split('.')[1]]=v; else body[k]=v; }
  // 路径类字段：空串代表「清掉」——但 copyWith 的 null 是「不改」，所以传空串让服务端按空处理
  for(const k of ['ffmpeg','ffprobe','onnxruntimeLibrary']) if(body[k]===null) delete body[k];
  await put('settings',body); toast('已保存'); loadSettings();
});

// ── 日志 ──
async function loadLogs(){ const r = await api('logs'); const pre=$('#logs'); const atBottom = pre.scrollTop+pre.clientHeight >= pre.scrollHeight-10; pre.textContent = r.lines.join('\n'); if(atBottom) pre.scrollTop=pre.scrollHeight; }
$('#btn-log-refresh').onclick = guard(loadLogs);

// ── 轮询 ──
const loaders = {status:loadStatus, pairing:loadPairing, libraries:loadLibraries, upload:async()=>{ await loadLibraries(); const s=await api('status'); $('#up-quota').textContent=`配额已用 ${fmtBytes(s.uploadUsedBytes)} / ${fmtBytes(s.uploadQuotaBytes)}`; }, jobs:loadJobs, downloads:loadDownloads, subscriptions:loadSubscriptions, models:loadModels, settings:async()=>{ if(!settingsCache) await loadSettings(); }, logs:async()=>{ if($('#log-auto').checked) await loadLogs(); }};
let busy=false;
async function refresh(){ if(busy) return; busy=true; try{ await loaders[current](); }catch(e){ console.warn(e); } finally{ busy=false; } }
refresh(); setInterval(refresh, 2500);
// 配对 PIN 不管在哪个页都要能看见：标题栏闪提示
setInterval(async()=>{ if(current==='pairing') return; try{ const p=await api('pairing'); if(p.pending){ document.title='★ 配对 PIN '+p.pending.pin+' — fushi_server'; } else document.title='fushi_server'; }catch(e){} }, 3000);
</script>
</body></html>''';
