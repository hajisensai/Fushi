/// WebUI「备份」页（第 4B 期：服务端整机备份 + 自动备份计划）：导航项、页面标记、页面脚本与英文表，
/// 由 `web_ui.dart` 拼进 [adminWebUiHtml]，英文表并进 [kWebUiEnglish]。单独成文件，免得与别的页面改动挤在一处。
///
/// 只吃 `/api/admin/backups*`（admin_backups.dart）。还原要停服，页面只给出 CLI 命令。
library;

/// 侧边栏「系统」组里的导航项。
const String kWebUiBackupsNav =
    r'''<button class="nav-item" data-s="backups"><span class="nav-indicator"><span class="msr-slot" data-fushi-icon="update"></span></span><span class="nav-label">备份</span></button>
''';

/// 页面标记。
const String kWebUiBackupsSection = r'''
<section id="s-backups">
<div class="card"><div class="card-head"><div class="card-head-copy"><h2 class="kit-title-medium">整机备份</h2><p class="kit-supporting" id="bk-state"></p></div><button class="primary-button" id="btn-bk-now"><span class="msr-slot" data-fushi-icon="add"></span>立即备份</button></div>
<label class="switch-row"><span class="switch"><input type="checkbox" id="bk-now-docs"><span></span></span><span>这次手动备份带上 documents/（书 / 封面 / 有声书 / 下载）</span></label>
<p class="kit-supporting">备份包含数据库、复习库、数据目录和配置文件（含 admin_token 与各项凭据），请当密钥保管。手动备份不会被自动删除。</p>
</div>
<h3 class="kit-section-title">自动备份</h3>
<div class="card" id="bk-form">
<p class="kit-supporting">按计划在服务端本地时间备份设置与数据；停机错过了时刻，下次启动时补上；与上次相比没有变化就跳过。保留：48 小时内全留，之后 7 天每天、4 周每周、3 个月每月各留一份，超过总大小上限从最旧的删起，最新一份始终保留；手动备份与更新前备份不受影响。远程更新换包之前也会自动备份一次（不含 documents/，保留最新 3 份）。</p>
<div class="field">频率<div class="segmented" role="radiogroup" id="bk-interval">
<label><input type="radio" name="bk-interval" value="off"><span>关闭</span></label>
<label><input type="radio" name="bk-interval" value="daily"><span>每天</span></label>
<label><input type="radio" name="bk-interval" value="every3Days"><span>每 3 天</span></label>
<label><input type="radio" name="bk-interval" value="weekly"><span>每周</span></label>
</div></div>
<label class="field">时刻（服务端本地时间）<input type="time" id="bk-time" step="60"></label>
<label class="field">总大小上限（GB，0 = 不限）<input type="number" id="bk-cap" min="0" step="1"></label>
<label class="switch-row"><span class="switch"><input type="checkbox" id="bk-docs"><span></span></span><span>自动备份带上 documents/</span></label>
<div class="kv-grid" id="bk-status"></div>
<div class="action-row"><span class="kit-spacer"></span><button class="text-button" id="btn-bk-run"><span class="msr-slot" data-fushi-icon="play_arrow"></span>立即跑一次自动备份</button></div>
</div>
<h3 class="kit-section-title">备份列表</h3>
<div class="card"><div class="setting-list" id="bk-list"></div>
<details class="kit-supporting" id="bk-restore"><summary>怎么还原</summary><p>还原要先停掉服务端，再在服务端这台机器上运行下面的命令；当前数据会挪到数据目录旁边保留，不删除。备份目录、已配对设备复制来的备份原地留着；备份不含 documents/ 时，现有的书 / 封面 / 有声书 / 下载也原地不动。远程更新之后想回到旧版：先停服，用现在这版程序还原那份「更新前」备份（还原完先不要启动），再装回旧版程序，然后启动。</p><pre id="bk-restore-cmd"></pre></details></div>
</section>
''';

/// 页面脚本（插在 `loaders` 定义之后：用到页面里的 `api` / `T` / `esc` / `tag` / `kvHtml` / `iconBtn` / `ask` /
/// `toast` / `guard` / `fmtBytes` / `fmtTime` / `empty`）。
const String kWebUiBackupsScript = r'''
// ── 备份（服务端整机备份 + 自动备份计划，admin_backups.dart）──
const BK_KIND = {manual:T('手动'), auto:T('自动'), pre_update:T('更新前')};
const BK_KIND_TONE = {manual:'info', auto:'', pre_update:'warn'};
const BK_SKIP = {unchanged:T('没有变化'), srs_migration_running:T('复习库正在升级，稍后重试')};
function bkWhen(ms){ return ms ? fmtTime(ms) : T('还没有'); }
function bkError(e){ return e==='interrupted' ? T('写到一半被中断，已清理') : (e==='srs_migration_running' ? T('复习库正在升级') : e); }
async function loadBackups(){ renderBackups(await api('backups')); }
function renderBackups(r){
  const s = r.schedule || {}, st = r.status || {};
  const a = document.activeElement;
  if (!(a && a.closest && a.closest('#bk-form'))){
    document.querySelectorAll('input[name="bk-interval"]').forEach(x=>{ x.checked = x.value===s.interval; });
    $('#bk-time').value = s.time || '04:00';
    $('#bk-cap').value = String(s.maxTotalGb ?? 5);
    $('#bk-docs').checked = !!s.documents;
  }
  $('#bk-state').textContent = r.running ? T('正在备份：{0}', r.running) : (r.lastError ? T('上次手动备份失败：{0}', r.lastError) : T('同一时刻只做一份备份。'));
  $('#btn-bk-now').disabled = !!r.running; $('#btn-bk-run').disabled = !!r.running;
  const kv = [[T('上次成功'), st.lastSuccessAtMs ? T('{0} · {1}', fmtTime(st.lastSuccessAtMs), fmtBytes(st.lastSuccessBytes)) : T('还没有')]];
  if (s.interval==='off') kv.unshift([T('自动备份'), tag('warn', T('已关闭')), true]);
  if (st.lastFailureAtMs) kv.push([T('上次失败'), tag('err', T('{0} · {1}', fmtTime(st.lastFailureAtMs), bkError(st.lastError))), true]);
  if (st.lastSkippedAtMs) kv.push([T('上次跳过'), T('{0} · {1}', fmtTime(st.lastSkippedAtMs), BK_SKIP[st.lastSkipReason] || st.lastSkipReason)]);
  if (st.preUpdateAtMs) kv.push([T('更新前备份'), st.preUpdateError ? tag('err', T('{0} · 失败（更新照样进行了）：{1}', fmtTime(st.preUpdateAtMs), bkError(st.preUpdateError))) : esc(T('{0} · {1}', fmtTime(st.preUpdateAtMs), st.preUpdateName)), true]);
  $('#bk-status').innerHTML = kvHtml(kv);
  const items = r.items || [];
  $('#bk-list').innerHTML = items.map(i=>`<div class="setting-row"><div class="list-lead">${icon(i.kind==='pre_update'?'restart_alt':(i.kind==='auto'?'schedule':'task_alt'))}</div><div class="setting-copy"><strong>${esc(i.name)} ${tag(BK_KIND_TONE[i.kind]||'', BK_KIND[i.kind]||i.kind)}</strong><small>${esc(T('{0} · {1}', fmtTime(i.createdAt), fmtBytes(i.bytes)))}</small></div><a class="icon-button" href="/api/admin/backups/${encodeURIComponent(i.name)}" download="${esc(i.name)}" title="${esc(T('下载'))}" aria-label="${esc(T('下载'))}">${icon('download')}</a>${iconBtn('delete', T('删除'), `data-bk-del="${esc(i.name)}"`, true)}</div>`).join('') || empty(T('还没有备份。'));
  $('#bk-list').querySelectorAll('[data-bk-del]').forEach(b=>b.onclick=guard(async()=>{ const n=b.dataset.bkDel; if(!(await ask(T('删除备份 {0}？删除后无法恢复。', n), true))) return; await del('backups/'+encodeURIComponent(n)); toast(T('已删除')); await loadBackups(); }));
  const sep = /\\/.test(r.backupsDir||'') ? '\\' : '/';
  const pick = items[0] ? items[0].name : 'fushi_server-backup-YYYYMMDD-HHMMSS.zip';
  $('#bk-restore-cmd').textContent = `fushi_server backup restore "${(r.backupsDir||'')}${sep}${pick}" --yes --config "${r.configFile||''}"`;
}
async function saveBackupSchedule(patch){ try{ await put('backups/schedule', patch); toast(T('已保存')); }catch(e){ toast(T('失败: {0}', e.message), true); } await loadBackups(); }
document.querySelectorAll('input[name="bk-interval"]').forEach(x=>x.onchange=()=>saveBackupSchedule({interval:x.value}));
$('#bk-time').onchange = ()=>{ if($('#bk-time').value) saveBackupSchedule({time:$('#bk-time').value}); };
$('#bk-cap').onchange = ()=>{ const v=Number($('#bk-cap').value); if(Number.isInteger(v) && v>=0) saveBackupSchedule({maxTotalGb:v}); else toast(T('总大小上限要是非负整数'), true); };
$('#bk-docs').onchange = ()=>saveBackupSchedule({documents:$('#bk-docs').checked});
$('#btn-bk-now').onclick = guard(async()=>{ const r=await post('backups', {documents:$('#bk-now-docs').checked}); toast(T('已开始备份：{0}', r.name)); await loadBackups(); });
$('#btn-bk-run').onclick = guard(async()=>{ const r=await post('backups/run'); toast(T('已开始自动备份：{0}', r.name)); await loadBackups(); });
loaders.backups = loadBackups;
''';

/// 本页英文（键 = 上面的中文原文；并进 [kWebUiEnglish]，`web_ui_i18n_test.dart` 一起查缺漏与多余）。
const Map<String, String> kWebUiBackupsEnglish = <String, String>{
  '备份': 'Backups',
  '整机备份': 'Server backup',
  '立即备份': 'Back up now',
  '这次手动备份带上 documents/（书 / 封面 / 有声书 / 下载）':
      'Include documents/ in this manual backup (books / covers / audiobooks / downloads)',
  '备份包含数据库、复习库、数据目录和配置文件（含 admin_token 与各项凭据），请当密钥保管。手动备份不会被自动删除。':
      'A backup holds the database, the review library, the data folder and the config file (with admin_token and all credentials); keep it as a secret. Manual backups are never deleted automatically.',
  '自动备份': 'Automatic backups',
  '按计划在服务端本地时间备份设置与数据；停机错过了时刻，下次启动时补上；与上次相比没有变化就跳过。保留：48 小时内全留，之后 7 天每天、4 周每周、3 个月每月各留一份，超过总大小上限从最旧的删起，最新一份始终保留；手动备份与更新前备份不受影响。远程更新换包之前也会自动备份一次（不含 documents/，保留最新 3 份）。':
      'Backs up settings and data on a schedule in the server\'s local time; a time missed while the server was down is caught up on the next start; a run is skipped when nothing changed. Retention: everything from the last 48 hours, then one per day for 7 days, one per week for 4 weeks and one per month for 3 months; above the size cap the oldest go first, and the newest is always kept. Manual and pre-update backups are not touched. A remote update also takes a backup right before it swaps the program files (without documents/, newest 3 kept).',
  '每天': 'Daily',
  '每 3 天': 'Every 3 days',
  '每周': 'Weekly',
  '时刻（服务端本地时间）': 'Time (server local time)',
  '总大小上限（GB，0 = 不限）': 'Size cap (GB, 0 = no limit)',
  '自动备份带上 documents/': 'Include documents/ in automatic backups',
  '立即跑一次自动备份': 'Run an automatic backup now',
  '备份列表': 'Backups',
  '怎么还原': 'How to restore',
  '还原要先停掉服务端，再在服务端这台机器上运行下面的命令；当前数据会挪到数据目录旁边保留，不删除。备份目录、已配对设备复制来的备份原地留着；备份不含 documents/ 时，现有的书 / 封面 / 有声书 / 下载也原地不动。远程更新之后想回到旧版：先停服，用现在这版程序还原那份「更新前」备份（还原完先不要启动），再装回旧版程序，然后启动。':
      'To restore, stop the server, then run the command below on the server machine; the current data is moved next to the data folder and kept, not deleted. The backup folder and the backups copied here by paired devices stay where they are; when the backup has no documents/, the existing books / covers / audiobooks / downloads stay in place too. To go back to the old version after a remote update: stop the server, restore the "pre-update" backup with the current program (do not start it afterwards), reinstall the old program, then start it.',
  '手动': 'Manual',
  '自动': 'Automatic',
  '更新前': 'Pre-update',
  '没有变化': 'Nothing changed',
  '复习库正在升级，稍后重试': 'Review library is upgrading; will retry',
  '还没有': 'Not yet',
  '写到一半被中断，已清理': 'Interrupted half-way; cleaned up',
  '复习库正在升级': 'Review library is upgrading',
  '正在备份：{0}': 'Backing up: {0}',
  '上次手动备份失败：{0}': 'Last manual backup failed: {0}',
  '同一时刻只做一份备份。': 'Only one backup runs at a time.',
  '上次成功': 'Last success',
  '{0} · {1}': '{0} · {1}',
  '已关闭': 'Off',
  '上次失败': 'Last failure',
  '上次跳过': 'Last skipped',
  '更新前备份': 'Pre-update backup',
  '{0} · 失败（更新照样进行了）：{1}': '{0} · failed (the update went ahead): {1}',
  '还没有备份。': 'No backups yet.',
  '删除备份 {0}？删除后无法恢复。': 'Delete backup {0}? This cannot be undone.',
  '总大小上限要是非负整数': 'The size cap must be a non-negative whole number',
  '已开始备份：{0}': 'Backup started: {0}',
  '已开始自动备份：{0}': 'Automatic backup started: {0}',
};
