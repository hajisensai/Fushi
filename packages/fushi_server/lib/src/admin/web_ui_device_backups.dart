/// WebUI「设备备份」页（自动备份第四期 A）：已配对设备复制到本服务器的定时还原点，按设备分组列出，可下载
/// zip、删一份 / 删一台的全部。端点见 admin_device_backups.dart。
///
/// 三段由 web_ui.dart 的 `adminWebUiHtml` 常量拼接进去（导航项在「系统」组「设置」之前，页面在
/// `<section id="s-settings">` 之前，脚本紧跟 `const loaders = {…};`、在首次出页 `go(startPage)` / `refresh()`
/// 之前登记，`#device-backups` 深链才认得）；英文表经 web_ui_en.dart 展开进 `kWebUiEnglish`
/// （`test/web_ui_i18n_test.dart` 照样查缺漏与多余的键）。
library;

/// 导航项（「系统」组里，「设置」之前）。
const String kDeviceBackupsNavHtml =
    '<button class="nav-item" data-s="device-backups"><span class="nav-indicator"><span class="msr-slot" data-fushi-icon="devices"></span></span><span class="nav-label">设备备份</span></button>\n';

/// 页面。
const String kDeviceBackupsSectionHtml = r'''<section id="s-device-backups">
<div class="card"><h2 class="kit-title-medium">已配对设备的自动备份</h2>
<p class="kit-supporting">已配对设备复制到这台服务器的自动备份。在 Fushi 的「设置 › 同步与备份 › 自动备份」里打开「复制到服务器」后，设备每做一份定时还原点就复制一份过来。</p></div>
<div id="devbak"><div class="setting-list is-surface"><div class="skeleton"></div></div></div>
<p class="note">每台设备自己修剪它复制来的副本：最近 48 小时的全部保留，此外保留最近 7 天每天一份、4 周每周一份、3 个月每月一份，合计不超过 5 GB。这台服务器自己从不删除它们，只有在这里手动删除。</p>
<p class="note">每份都是普通的 Fushi 备份包（zip）：下载后在 Fushi 的「设置 › 同步与备份 › 导入备份」里导入；或者在那台设备上打开「还原点」页，在「在服务器上」里选一份「复制到本机」。</p>
</section>

''';

/// 页面脚本：放在 `const loaders = {…};` 之后。回包没变就不重绘（跟 2.5 秒轮询走：目录很小，
/// 每份只有 zip + 元数据两个文件；不重绘则不打断悬停 / 焦点）。
const String kDeviceBackupsScript = r'''
// ── 设备备份 ── 已配对设备复制来的定时还原点（GET /api/admin/device-backups）；下载链接靠登录 cookie 鉴权。
let devBackupsSig = '';
const devBackupPath = (k, id) => 'device-backups/' + encodeURIComponent(k) + (id ? '/' + encodeURIComponent(id) : '');
async function loadDeviceBackups(){ const r = await api('device-backups'); const sig = JSON.stringify(r); if (sig===devBackupsSig) return; devBackupsSig = sig; renderDeviceBackups(r); }
function devBackupCopyRow(g, name, c){
  const when = fmtTime(c.createdAtMs);
  const meta = [fmtBytes(c.bytes), c.appVersion ? T('Fushi 版本 {0}', c.appVersion) : '', c.schema != null ? T('数据库 v{0}', c.schema) : ''].filter(Boolean).join(' · ');
  const label = T('下载');
  return `<div class="setting-row"><div class="list-lead">${icon('inbox')}</div><div class="setting-copy"><strong>${esc(when)}${c.fullDatabase===false?tag('info', T('部分数据')):''}</strong><small>${esc(meta)}</small><small class="mono">${esc(c.id)}</small></div><div class="setting-trail"><a class="icon-button" href="/api/admin/${devBackupPath(g.device, c.id)}" download title="${esc(label)}" aria-label="${esc(label)}">${icon('download')}</a>${iconBtn('delete', T('删除'), `data-devbak-del="${esc(g.device)}" data-id="${esc(c.id)}" data-name="${esc(name)}" data-when="${esc(when)}"`, true)}</div></div>`;
}
function renderDeviceBackups(r){
  const groups = r.devices || [];
  if (!groups.length){ $('#devbak').innerHTML = `<div class="setting-list is-surface">${empty(T('还没有设备复制过备份'), 'devices')}</div>`; return; }
  $('#devbak').innerHTML = groups.map(g=>{
    const name = g.name || g.device;
    const sum = [T('{0} 份', g.count), fmtBytes(g.bytes), g.newestAtMs ? T('最新 {0}', fmtTime(g.newestAtMs)) : '', g.incomplete ? T('另有 {0} 份没传完或已损坏', g.incomplete) : ''].filter(Boolean).join(' · ');
    const rows = (g.copies||[]).map(c=>devBackupCopyRow(g, name, c)).join('') || empty(T('没有完整的副本'), 'inbox');
    return `<h3 class="kit-section-title">${esc(name)}<span class="kit-spacer"></span><button class="plain-button danger-button" data-devbak-all="${esc(g.device)}" data-name="${esc(name)}">${icon('delete')}${esc(T('全部删除'))}</button></h3><p class="note">${esc(sum)} · <span class="mono">${esc(g.device)}</span></p><div class="setting-list is-surface">${rows}</div>`;
  }).join('');
}
$('#devbak').onclick = guard(async (ev)=>{
  const one = ev.target.closest('[data-devbak-del]');
  const all = ev.target.closest('[data-devbak-all]');
  if (one){
    if (!await ask(T('删除「{0}」{1} 的这份备份？删除后不能恢复。', one.dataset.name, one.dataset.when), true)) return;
    await del(devBackupPath(one.dataset.devbakDel, one.dataset.id));
  } else if (all){
    if (!await ask(T('删除「{0}」复制来的全部备份？删除后不能恢复。', all.dataset.name), true)) return;
    await del(devBackupPath(all.dataset.devbakAll));
  } else return;
  toast(T('已删除'));
  devBackupsSig = '';
  await loadDeviceBackups();
});
loaders['device-backups'] = loadDeviceBackups;
''';

/// 本页的英文（只放 `kWebUiEnglish` 里还没有的键：常量 map 里重复的键编不过）。
const Map<String, String> kDeviceBackupsWebUiEnglish = <String, String>{
  '设备备份': 'Device backups',
  '已配对设备的自动备份': 'Automatic backups from paired devices',
  '已配对设备复制到这台服务器的自动备份。在 Fushi 的「设置 › 同步与备份 › 自动备份」里打开「复制到服务器」后，设备每做一份定时还原点就复制一份过来。':
      'Automatic backups that paired devices copied to this server. With "Copy to server" turned on in Fushi under Settings › Sync & backup › Automatic backup, a device copies each scheduled restore point here.',
  '每台设备自己修剪它复制来的副本：最近 48 小时的全部保留，此外保留最近 7 天每天一份、4 周每周一份、3 个月每月一份，合计不超过 5 GB。这台服务器自己从不删除它们，只有在这里手动删除。':
      'Each device trims the copies it made: everything from the last 48 hours, then one per day for 7 days, one per week for 4 weeks and one per month for 3 months, 5 GB at most. This server never deletes them by itself; only you can, here.',
  '每份都是普通的 Fushi 备份包（zip）：下载后在 Fushi 的「设置 › 同步与备份 › 导入备份」里导入；或者在那台设备上打开「还原点」页，在「在服务器上」里选一份「复制到本机」。':
      'Each copy is a normal Fushi backup (zip): download it and import it in Fushi under Settings › Sync & backup › Import backup, or on the device itself open the Restore points page and pick one under "On the server" › "Copy to this device".',
  'Fushi 版本 {0}': 'Fushi {0}',
  '数据库 v{0}': 'Database v{0}',
  '部分数据': 'Partial data',
  '还没有设备复制过备份': 'No device has copied a backup here yet',
  '{0} 份': 'Copies: {0}',
  '最新 {0}': 'Newest {0}',
  '另有 {0} 份没传完或已损坏': '{0} more unfinished or damaged',
  '没有完整的副本': 'No complete copies',
  '全部删除': 'Delete all',
  '删除「{0}」{1} 的这份备份？删除后不能恢复。':
      'Delete the backup of "{0}" from {1}? This cannot be undone.',
  '删除「{0}」复制来的全部备份？删除后不能恢复。':
      'Delete all backups copied from "{0}"? This cannot be undone.',
};
