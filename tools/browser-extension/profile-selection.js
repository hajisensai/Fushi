// 反馈 biLEesNqWb：在扩展里手动选择 Fushi 配置（Profile），只影响扩展。纯函数 + 常量（node 可测），
// background（SW，importScripts）与工具栏菜单（vendor/action-popup.js）共用。
//
// 数据流：
//   工具栏菜单 → background `fushiProfiles` → POST /api/extension/profiles 列出配置；
//   用户选中 → chrome.storage.local.fushiProfileSelection = {id, name}（「跟随 Fushi」= 删键）；
//   查词 / 制卡 / 查重 / 单词音频 / 在 Anki 中打开 / 复习标记（词状态、打开笔记）→ 请求头 X-Fushi-Profile-Id；
//   app 按该配置的只读设置视图处理这条请求，不切换 App 的激活配置（见 fushi/lib/src/sync/extension_profile_api.dart），
//   响应头 X-Fushi-Profile-Missing = 所选配置已被删 → 回退到「跟随 Fushi」并留提示；
//   列配置时发现改名 → 更新保存的名字并留提示。
(function (root) {
  const SELECTION_KEY = 'fushiProfileSelection';
  const NOTICE_KEY = 'fushiProfileNotice';
  const REQUEST_HEADER = 'X-Fushi-Profile-Id';
  const ACTIVE_HEADER = 'X-Fushi-Profile-Active';
  const MISSING_HEADER = 'X-Fushi-Profile-Missing';

  function tr(key, params) {
    return (typeof root.fushiT === 'function') ? root.fushiT(key, params) : key;
  }

  function positiveId(v) {
    const n = typeof v === 'string' && v.trim() !== '' ? Number(v) : v;
    return (typeof n === 'number' && Number.isInteger(n) && n > 0) ? n : null;
  }

  /** 存储里的选择 → {id, name} 或 null（= 跟随 Fushi）。坏值一律当没选。 */
  function fushiNormalizeProfileSelection(raw) {
    if (!raw || typeof raw !== 'object') return null;
    const id = positiveId(raw.id);
    if (id === null) return null;
    return { id, name: typeof raw.name === 'string' ? raw.name : '' };
  }

  /** 在既有请求头上加所选配置；没选（跟随 Fushi）时原样返回副本，不带头。 */
  function fushiProfileRequestHeaders(headers, profileId) {
    const out = Object.assign({}, headers || {});
    const id = positiveId(profileId);
    if (id !== null) out[REQUEST_HEADER] = String(id);
    return out;
  }

  /** /api/extension/profiles 响应 → {profiles:[{id,name}], activeProfileId} 或 null（形状不对）。 */
  function fushiParseProfileList(json) {
    if (!json || typeof json !== 'object' || !Array.isArray(json.profiles)) return null;
    const profiles = [];
    for (const p of json.profiles) {
      const id = p && positiveId(p.id);
      if (id === null) continue;
      profiles.push({ id, name: typeof p.name === 'string' ? p.name : String(id) });
    }
    return { profiles, activeProfileId: positiveId(json.activeProfileId) };
  }

  /**
   * 拿到最新配置列表后校正保存的选择：
   * - 所选 id 不在列表里（被删）→ 回退到跟随 Fushi，提示 removed；
   * - 名字变了（改名）→ 更新名字，提示 renamed；
   * - 其余不变，notice 为 null。
   * changed = 需要写回存储。
   */
  function fushiReconcileProfileSelection(selection, list) {
    const sel = fushiNormalizeProfileSelection(selection);
    if (!sel || !list || !Array.isArray(list.profiles)) {
      return { selection: sel, notice: null, changed: false };
    }
    const hit = list.profiles.find((p) => p.id === sel.id);
    if (!hit) {
      return { selection: null, notice: { kind: 'removed', name: sel.name }, changed: true };
    }
    if (hit.name !== sel.name) {
      return {
        selection: { id: sel.id, name: hit.name },
        notice: sel.name ? { kind: 'renamed', oldName: sel.name, name: hit.name } : null,
        changed: true,
      };
    }
    return { selection: sel, notice: null, changed: false };
  }

  /**
   * 按配置生效的请求的响应头 → 所选配置被删时的回退决策；无需改动返回 null。
   * 只认与当前选择同一个 id 的 missing（选择在请求途中被改过就不误伤新选择）。
   * @param {{id:number,name:string}|null} selection
   * @param {(name: string) => (string|null)} getHeader
   */
  function fushiProfileFallbackFromResponse(selection, getHeader) {
    const sel = fushiNormalizeProfileSelection(selection);
    if (!sel || typeof getHeader !== 'function') return null;
    let missing = null;
    try { missing = positiveId(getHeader(MISSING_HEADER)); } catch (_) { missing = null; }
    if (missing === null || missing !== sel.id) return null;
    return { selection: null, notice: { kind: 'removed', name: sel.name } };
  }

  /** 提示文案（工具栏菜单显示）；未知 notice 返回 ''。 */
  function fushiProfileNoticeText(notice) {
    if (!notice || typeof notice !== 'object') return '';
    const name = typeof notice.name === 'string' && notice.name ? notice.name : '?';
    if (notice.kind === 'removed') return tr('ap_profile_notice_removed', { name });
    if (notice.kind === 'renamed') {
      const oldName = typeof notice.oldName === 'string' && notice.oldName ? notice.oldName : '?';
      return tr('ap_profile_notice_renamed', { old: oldName, name });
    }
    return '';
  }

  /**
   * 下拉选项：首项「跟随 Fushi（当前：X）」value ''，其后每个配置 value = id。
   * 所选配置不在列表（离线 / 尚未加载）时仍保留一项显示保存的名字，下拉不至于空跳。
   */
  function fushiProfileOptions(list, selection) {
    const sel = fushiNormalizeProfileSelection(selection);
    const profiles = list && Array.isArray(list.profiles) ? list.profiles : [];
    const active = list ? profiles.find((p) => p.id === list.activeProfileId) : null;
    const options = [{
      value: '',
      label: active
        ? tr('ap_profile_follow_app', { name: active.name })
        : tr('ap_profile_follow_app_plain'),
    }];
    for (const p of profiles) options.push({ value: String(p.id), label: p.name });
    if (sel && !profiles.some((p) => p.id === sel.id)) {
      options.push({ value: String(sel.id), label: sel.name || String(sel.id) });
    }
    return { options, value: sel ? String(sel.id) : '' };
  }

  const api = {
    FUSHI_PROFILE_SELECTION_KEY: SELECTION_KEY,
    FUSHI_PROFILE_NOTICE_KEY: NOTICE_KEY,
    FUSHI_PROFILE_REQUEST_HEADER: REQUEST_HEADER,
    FUSHI_PROFILE_ACTIVE_HEADER: ACTIVE_HEADER,
    FUSHI_PROFILE_MISSING_HEADER: MISSING_HEADER,
    fushiNormalizeProfileSelection,
    fushiProfileRequestHeaders,
    fushiParseProfileList,
    fushiReconcileProfileSelection,
    fushiProfileFallbackFromResponse,
    fushiProfileNoticeText,
    fushiProfileOptions,
  };
  root.FUSHI_PROFILE = api;
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
})(typeof self !== 'undefined' ? self : (typeof window !== 'undefined' ? window : globalThis));
