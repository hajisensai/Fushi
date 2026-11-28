/// WebUI 英文文案：键 = `web_ui.dart` 里的中文原文，值 = 英文。
///
/// 页面脚本用 `T('中文', ...)` 查这张表（`{0}`、`{1}`… 是参数位，键与值里个数相同），
/// 静态标记在页面加载时按文本节点 / placeholder / title 整段查表。改了页面里的中文就要
/// 同步改这里的键；`test/web_ui_i18n_test.dart` 会列出缺的与多余的键。
library;

const Map<String, String> kWebUiEnglish = <String, String>{
  // ── 导航与通用 ──
  '状态': 'Status',
  '配对': 'Pairing',
  '库': 'Libraries',
  '上传': 'Upload',
  '任务': 'Jobs',
  '下载': 'Download',
  '订阅': 'Subscriptions',
  'AI 助手': 'AI assistant',
  '复习': 'Review',
  '模型': 'Models',
  '设置': 'Settings',
  '日志': 'Logs',
  '退出': 'Sign out',
  '登录': 'Sign in',
  'token 在 fushi_server.yaml 的 admin_token；忘了用 <code>fushi_server admin reset-token</code> 重生成。':
      'The token is admin_token in fushi_server.yaml. Forgot it? Run <code>fushi_server admin reset-token</code> to make a new one.',
  'Token 不正确': 'Wrong token',
  '失败: {0}': 'Failed: {0}',
  '无': 'None',
  '、': ', ',
  '：': ': ',
  '开': 'On',
  '关': 'Off',
  '保存': 'Save',
  '已保存': 'Saved',
  '已保存并生效': 'Saved and applied',
  '添加': 'Add',
  '已添加': 'Added',
  '删除': 'Delete',
  '已删除': 'Deleted',
  '移除': 'Remove',
  '已移除': 'Removed',
  '取消': 'Cancel',
  '已取消': 'Cancelled',
  '重试': 'Retry',
  '清理': 'Clean up',
  '编辑': 'Edit',
  '刷新': 'Refresh',
  '已刷新': 'Refreshed',
  '启用': 'Enabled',
  '停用': 'Disable',
  '已停用': 'Disabled',
  '禁用': 'Disabled',
  '已启用': 'Enabled',
  '就绪': 'Ready',
  '缺失': 'Missing',
  '可用': 'Available',
  '出错': 'Error',
  '名称': 'Name',
  '名称（可选）': 'Name (optional)',
  '路径': 'Path',
  '类型': 'Type',
  '创建': 'Create',
  '已创建': 'Created',
  '标题': 'Title',
  '设备': 'Device',
  '端口': 'Port',
  '默认': 'Default',
  '提供': 'Serve',
  '开关': 'Enabled',
  '关闭': 'Off',
  '完成': 'Done',
  '等待': 'Waiting',
  '已存在': 'Already there',
  '(已设置，留空不改)': '(set; leave empty to keep)',

  // ── 状态 ──
  '运行状态': 'Server status',
  '扫描': 'Scan',
  '立即扫描库': 'Scan libraries now',
  '扫描中…': 'Scanning…',
  '上次 {0}: {1}': 'Last scan {0}: {1}',
  '尚未扫描': 'Not scanned yet',
  '已开始扫描': 'Scan started',
  '监听': 'Listening on',
  '设备 id': 'Device ID',
  'TLS 指纹': 'TLS fingerprint',
  '运行时长': 'Uptime',
  '数据目录': 'Data directory',
  '视频': 'Videos',
  '书': 'Books',
  '已配对': 'Paired devices',
  'OCR 模型': 'OCR models',
  '下载后端': 'Download backend',
  '未配置': 'Not configured',
  '上传配额': 'Upload quota',
  'P2P 隧道': 'P2P tunnel',
  '刮削': 'Metadata',
  ' · 未配置 TMDB key': ' · no TMDB key set',
  '进行中 {0}/{1}': 'Running {0}/{1}',
  ' · 上次 {0}/{1} 部成功': ' · last run {0}/{1} titles matched',
  '，{0} 部待指定': ', {0} need a manual pick',
  '空闲': 'Idle',
  '自动补刮已关闭': 'Automatic metadata fetch is off',

  // ── 配对 ──
  '没有待处理的配对。在 Fushi 里添加互联设备并输入本机地址，PIN 会显示在这里。':
      'No pending pairing. In Fushi, add an interconnect device and enter this server\'s address; the PIN shows up here.',
  '{0} ({1}) 请求配对，请在该设备输入：':
      '{0} ({1}) wants to pair. Enter this on that device:',
  '未知设备': 'Unknown device',
  '局域网': 'LAN',
  '公网或反向代理': 'internet or reverse proxy',
  '来自{0}的配对因多次 PIN 错误暂停至 {1}':
      'Pairing from {0} is paused until {1} after repeated wrong PINs',
  '解除': 'Unlock',
  '已解除': 'Unlocked',
  '配对链接': 'Pairing link',
  '一次性链接自带票据，配对不用 PIN；来自公网的 PIN 配对被暂停时也能用。':
      'A single-use link carries its own ticket, so pairing needs no PIN. It works even while PIN pairing from the internet is paused.',
  '生成配对链接': 'Create pairing link',
  '复制': 'Copy',
  '{0} 分钟内有效，只能用一次。在 Fushi 的互联设置里点「粘贴配对链接」使用。':
      'Valid for {0} minutes, single use. In the interconnect settings of Fushi, tap "Paste pairing link".',
  '浏览器不让复制，请手动选中':
      'The browser blocked copying; select the link and copy it manually',
  '已复制': 'Copied',
  '互联服务没在运行': 'The interconnect service is not running',
  '没有能放进链接的地址：配对链接只收 HTTPS 地址或 P2P 隧道。请开启 TLS、在「设置 › 远程访问」填写 HTTPS 公网地址，或开启 P2P 隧道':
      'No address can go into the link: pairing links only carry HTTPS addresses or a P2P tunnel. Turn on TLS, add an HTTPS public address under Settings › Remote access, or turn on the P2P tunnel',
  '已配对设备': 'Paired devices',
  '我的设备': 'My device',
  '标为我的设备': 'Mark as my device',
  '未证明设备钥匙': 'Device key not verified',
  '吊销': 'Revoke',
  '吊销该设备？': 'Revoke this device?',
  '标为「我的设备」的已配对设备在本机没有 Fushi 账户时，会跟随本机（当前 Profile）的排行榜账户自动登录：设备只交来它自己的公钥，由本机账户代绑；私钥 / 恢复码不外传。配对不会自动标记；只有配对时证明过设备钥匙的设备能标（旧版客户端需升级后重新配对）。仅 TLS 下可用，总开关在「设置」。':
      'A paired device marked as "my device" that has no Fushi account signs in with this server\'s leaderboard account (current profile): the device only sends its public key, and this server\'s account links it. Private keys and recovery codes never leave. Pairing never marks a device by itself; only devices that proved their device key while pairing can be marked (older clients must update and pair again). TLS only; the master switch is in Settings.',
  '自动登录已开': 'Auto sign-in on',
  '自动登录已开，但 TLS 关着——端点在明文下拒绝访问':
      'Auto sign-in on, but TLS is off; the endpoint refuses plain HTTP',
  '自动登录已关': 'Auto sign-in off',
  '标为「我的设备」？它将能跟随本机的 Fushi 排行榜账户自动登录（代绑出去的设备钥匙在账户里是满权限）。只标你自己的设备。':
      'Mark as "my device"? It will be able to sign in with this server\'s Fushi leaderboard account (a linked device key has full rights on the account). Only mark your own devices.',
  '已标为我的设备': 'Marked as my device',
  '配置文件寄存': 'Profile storage',
  '已配对设备在「互联 → 上传配置 / 下载配置」里把配置方案（Profile）推到本机寄存，另一台设备再拉走。本机只寄存、不应用；设备拉取时交出标「分发中」的那一份（缺省为最近收到的）。凭据已由发送端剔除。仅 TLS 下可用。':
      'Paired devices push a settings profile here from "Interconnect → Upload settings / Download settings", and another device pulls it. This server only stores profiles and never applies them; a pull gets the one marked "Shared" (by default the most recent). The sender strips credentials. TLS only.',
  '已允许': 'Allowed',
  '已允许，但 TLS 关着——端点在明文下拒绝访问':
      'Allowed, but TLS is off; the endpoint refuses plain HTTP',
  '未允许（默认）': 'Not allowed (default)',
  '禁止设备推送 / 拉取': 'Stop devices pushing / pulling',
  '允许设备推送 / 拉取': 'Allow devices to push / pull',
  '分发中': 'Shared',
  '设为分发': 'Share this one',
  '还没有设备推送过配置': 'No device has pushed a profile yet',
  '删除这份寄存的配置？': 'Delete this stored profile?',
  '允许已配对设备把配置推到本机寄存、并从本机拉走？':
      'Allow paired devices to store profiles here and pull them from here?',
  '已禁止': 'Not allowed',

  // ── 库 ──
  '扫描根': 'Library roots',
  'id（可空）': 'id (optional)',
  '加完记得在「状态」页点扫描；服务端进程要能读到该目录。':
      'After adding, run a scan from the Status page. The server process must be able to read the folder.',
  '存在': 'Found',
  '目录不存在': 'Folder missing',
  '移除并清理': 'Remove and clean up',
  '还没有扫描根': 'No library roots yet',
  '从配置移除该库根？（不删文件、不删已入库条目）':
      'Remove this library root from the config? (Files and imported items are kept.)',
  '移除该库根，并清理「文件已消失」的条目？\n只回收条目与其刮削资料 / 正文副本，不删任何源文件。\n注意：目录若只是没挂载，其下条目也会被当成已删除。':
      'Remove this library root and clean up items whose files are gone?\nOnly the items and their metadata / text copies are removed; no source file is deleted.\nNote: if the folder is just not mounted, its items will also be treated as deleted.',
  '未清理：{0}': 'Not cleaned up: {0}',
  '被护栏拦下': 'stopped by a safety check',
  '已清理 {0} 条': 'Cleaned up {0} items',

  // ── 上传 ──
  '上传到库': 'Upload to a library',
  '子目录（可空，如 Season1）': 'Subfolder (optional, e.g. Season1)',
  '开始上传': 'Start upload',
  '分块 8 MB，可断点续传（同名文件继续）；上传完成后需扫描库。':
      'Uploads in 8 MB chunks and resumes (a file with the same name continues). Scan the library when done.',
  '先添加一个库根': 'Add a library root first',
  '没选文件': 'No files selected',
  '上传结束，记得扫描库': 'Upload finished; remember to scan the library',
  '配额已用 {0} / {1}': 'Quota used {0} / {1}',

  // ── 任务 ──
  '互联任务（ASR 等）': 'Interconnect jobs (ASR etc.)',

  // ── 下载 ──
  '添加磁力下载': 'Add a magnet download',
  '下载任务': 'Downloads',
  '后端: {0}': 'Backend: {0}',
  '下载后端未配置：在「设置」填 qBittorrent WebUI 地址并重启。':
      'No download backend: set the qBittorrent WebUI address in Settings and restart.',

  // ── 订阅 ──
  '新建订阅（按搜索词追新）': 'New subscription (follow new releases by search term)',
  '标题（显示用）': 'Title (for display)',
  '搜索词，如 Frieren 1080p': 'Search term, e.g. Frieren 1080p',
  'tv（持续追新）': 'tv (keep following)',
  'movie（一次）': 'movie (once)',
  '从第几集之后开始（可空）': 'Start after episode (optional)',
  '从 Fushi 客户端的发现页订阅会带完整作品身份（原名/别名/交叉 ID）；这里只按搜索词匹配。':
      'Subscribing from the Discover page in the Fushi app carries the full title identity (original name / aliases / cross IDs); here matching is by search term only.',
  '全部立即检查': 'Check all now',
  '搜索词': 'Search term',
  '源': 'Source',
  '后端: {0}；可用来源: {1}': 'Backend: {0}; sources: {1}',
  '下载后端未配置，订阅不可用。': 'No download backend, so subscriptions are unavailable.',
  '没有可用来源': 'No source available',
  '已停用的订阅不检查，请先启用': 'Disabled subscriptions are not checked; enable it first',
  '检查': 'Check',
  '删除该订阅？（已下载的任务不受影响）':
      'Delete this subscription? (Existing downloads are not affected.)',
  '已触发检查': 'Check started',
  '订阅已停用，请先启用': 'The subscription is disabled; enable it first',

  // ── 资源索引器 ──
  '资源索引器': 'Resource indexers',
  '订阅与代下载在这些来源里搜资源。与 Fushi app 的资源来源设置是同一份配置；改动对正在运行的服务立即生效（正在下载的种子不受影响）。':
      'Subscriptions and downloads search these sources. This is the same configuration as the resource sources in the Fushi app; changes apply to the running server right away (active torrents are not affected).',
  '还没有 BT 来源。添加一个 BT 站地址，或接入 Torznab 索引器':
      'No BT sources yet. Add a BT site address, or connect a Torznab indexer',
  'BT 站': 'BT sites',
  '允许明文 HTTP（仅受信任局域网）': 'Allow plain HTTP (trusted LAN only)',
  '只填地址即可，添加时会自动检测站点。':
      'An address is enough; the site is detected when you add it.',
  '解析规则（可选，JSON）': 'Parser rule (optional, JSON)',
  '登录 Cookie（可选，仅带解析规则的站点）':
      'Login cookie (optional, only for sites with a parser rule)',
  '自动检测认不出的站点，可以粘贴它的解析规则（JSON）；需要登录的站再填 Cookie。':
      "For a site that automatic detection can't recognize, paste its parser "
      'rule (JSON); add a cookie for sites that need a login.',
  '怎么写解析规则': 'How to write a parser rule',
  '解析规则用 CSS 选择器告诉服务端站点搜索页上的结果在哪："search" 填搜索页地址里域名之后的部分，搜索词换成 {query}；"rows" 选中包住整条结果的元素（通常是表格行 tr）；"fields" 里写这一行内部的选择器，"title" 必填，"magnet" / "torrent" / "infoHash" 至少一个，末尾加 @href 表示取属性而不是文字。':
      'A parser rule uses CSS selectors to tell the server where the results are on the '
      'site\'s search page: "search" is the part of the search page address after the '
      'domain, with your search word replaced by {query}; "rows" selects the element that '
      'wraps one whole result (usually a table row, tr); "fields" holds selectors inside '
      'that row: "title" is required, plus at least one of "magnet" / "torrent" / '
      '"infoHash". Add @href to read an attribute instead of the text.',
  '下载链接只在详情页时，让 "details" 指向详情页链接，再在 "detail" 段里写 "magnet" 或 "torrent"。不是 UTF-8 的站把 "encoding" 设为 windows-1251 或 latin1。规则里不含登录信息，需要登录的站另填 Cookie。用不到的部分直接删掉。':
      'If the download link is only on each result\'s own page, point "details" at that '
      'page\'s link and put "magnet" or "torrent" in the "detail" section. Sites that '
      'aren\'t UTF-8 can set "encoding" to windows-1251 or latin1. The rule never holds '
      'your login; add a cookie separately for sites that need signing in. Delete any '
      'part you don\'t need.',
  '填入模板': 'Use template',
  '解析规则（JSON；清空 = 改回自动检测）':
      'Parser rule (JSON; clear it to go back to automatic detection)',
  '新 Cookie（留空不改）': 'New cookie (leave empty to keep the current one)',
  'Torznab（Jackett / Prowlarr）': 'Torznab (Jackett / Prowlarr)',
  '添加 indexer': 'Add indexer',
  '放弃修改': 'Discard changes',
  '无法识别这个站点：可以粘贴它的解析规则后再添加':
      'Could not recognize this site; paste a parser rule for it and add it again',
  '按解析规则打不开站点的搜索页：请检查地址，或登录 Cookie 是否已过期':
      "The parser rule couldn't load the site's search page; check the address, "
      'or whether the login cookie has expired',
  '按解析规则在搜索页上没解析出任何结果：请检查规则里的选择器，或站点是否需要登录 Cookie':
      "The parser rule found no results on the site's search page; check the "
      "rule's selectors, or whether the site needs a login cookie",
  '站点响应超时': 'The site timed out',
  '地址无效': 'Invalid address',
  '这是明文 HTTP 地址：请改用 HTTPS，或勾选「允许明文 HTTP」':
      'This is a plain HTTP address: use HTTPS, or tick "Allow plain HTTP"',
  '动画': 'Anime',
  '电影': 'Movies',
  '剧集': 'TV',
  '小说': 'Novels',
  '有声书': 'Audiobooks',
  '漫画': 'Manga',
  '游戏': 'Games',
  '生效中': 'Active',
  '未参与资源搜索': 'Not used in searches',
  '适用：{0}': 'Used for: {0}',
  '；对 {0} 不生效': '; not used for {0}',
  '新地址（留空不改）': 'New address (leave empty to keep)',
  '重新检测': 'Detect again',
  '当前生效：{0} 个 BT 站、{1} 个 Torznab 索引器':
      'Active now: {0} BT sites, {1} Torznab indexers',
  '互联 host 未运行：保存后下次启动 serve 生效。':
      'The interconnect host is not running: changes apply the next time serve starts.',
  '删除这个 BT 站？（已建的订阅会改用其它来源，没有可用来源时暂停）':
      'Delete this BT site? (Existing subscriptions switch to other sources, and pause if none is left.)',
  '正在检测站点…': 'Detecting site…',
  '检测完成': 'Detection done',
  '至少选择一个媒体域': 'Pick at least one media type',
  '请填写站点地址': 'Enter the site address',
  '地址（https://…/api；带 ?apikey= 会自动拆进 key 栏）':
      'Address (https://…/api; a ?apikey= part moves into the key field)',
  '优先级（小的先搜）': 'Priority (lower is searched first)',
  '分类（不选 = 全部）': 'Categories (none selected = all)',
  '其他分类 ID（逗号分隔，可空）': 'Other category IDs (comma-separated, optional)',
  '清除已存的 key': 'Clear the stored key',
  // ── 在线字幕来源 ──
  '在线字幕来源': 'Online subtitle sources',
  '代下载配字幕与补字幕用。与 app 同一份设置；key 不回显，留空不改。设了 FUSHI_* 环境变量时，环境变量里的 key 优先。':
      'Used to fetch subtitles for downloads and subtitle backfill. Same settings as the app; keys are never shown, leave empty to keep. When a FUSHI_* environment variable is set, its key takes priority.',
  '保存即生效：下一个下载任务的字幕阶段就用新设置。':
      "Applies on save: the next download task's subtitle stage uses the new settings.",
  'OpenSubtitles（不填 key 时用 app 内置 key）':
      "OpenSubtitles (uses the app's built-in key when empty)",
  '未生效': 'Inactive',
  '（环境变量里的 key 优先于这里存的）':
      "(the environment variable's key takes priority over the one stored here)",
  '用户名（可选）': 'Username (optional)',
  '清除已存的密码': 'Clear the stored password',
  '还没有 Torznab indexer。': 'No Torznab indexers yet.',
  '第 {0} 个 indexer 的优先级必须是整数':
      'The priority of indexer {0} must be a whole number',

  // ── 模型 ──
  'ASR 模型': 'ASR models',
  '漫画 OCR 模型': 'Manga OCR models',
  '下载中…': 'Downloading…',
  'OCR 服务不可用': 'OCR service unavailable',
  '开始下载': 'Download started',

  // ── Anki ──
  'Anki 落地': 'Anki delivery',
  '打开后，其它设备（没装 Anki 的手机等）经互联同步过来的待发卡片由本机写进 Anki，再同步到 AnkiWeb 或你的自建 Anki 同步服务器。本机需要随包的 fushi-anki-sync。':
      'When on, cards waiting on other devices (phones without Anki, etc.) arrive over interconnect, and this server writes them into Anki, then syncs to AnkiWeb or your own Anki sync server. Needs the bundled fushi-anki-sync.',
  '接收其他设备的卡片': 'Receive cards from other devices',
  '立即落地': 'Deliver now',
  '重试失败的卡': 'Retry failed cards',
  'Anki 同步账号': 'Anki sync account',
  '牌组 / 笔记类型 / 字段': 'Deck / note type / fields',
  '未登录': 'Signed out',
  '同步中…': 'Syncing…',
  '被拦：服务器要求整库上传（Fushi 不做）。请先在官方 Anki 里同步一次。':
      'Blocked: the server wants a full collection upload, which Fushi does not do. Sync once in the official Anki first.',
  '上次同步失败': 'Last sync failed',
  '已随包': 'Bundled',
  '未找到（此服务端包不带，无法落地）':
      'Not found (this server package does not include it, so delivery is unavailable)',
  '落地': 'Delivery',
  '待落地 / 失败': 'Waiting / failed',
  '上次落地': 'Last delivery',
  '（收 {0}，落 {1}，失败 {2}，等配置 {3}）':
      ' (received {0}, delivered {1}, failed {2}, waiting for setup {3})',
  '同步': 'Sync',
  '未同步的卡': 'Unsynced cards',
  '上次同步': 'Last sync',
  '写入失败（会自动重试）': 'Write failures (retried automatically)',
  '{0} 张：{1}': '{0} cards: {1}',
  '落地错误': 'Delivery error',
  '此服务端包没有 fushi-anki-sync。':
      'This server package does not include fushi-anki-sync.',
  '已登录：{0}': 'Signed in: {0}',
  '立即同步': 'Sync now',
  '刷新牌组 / 笔记类型': 'Refresh decks / note types',
  '重新登录': 'Sign in again',
  '退出登录': 'Sign out',
  '同步服务器（自建服务器地址，如 http://nas:8080/；留空为 AnkiWeb）':
      'Sync server (your own server address, e.g. http://nas:8080/; empty = AnkiWeb)',
  '用户名': 'Username',
  '密码': 'Password',
  '登录并下载牌组集合': 'Sign in and download the collection',
  '密码只用来换取同步凭据，不保存。同一服务器与用户名重新登录只换凭据，本机的牌组集合与未同步的卡都保留。':
      'The password is only used to get sync credentials and is not stored. Signing in again with the same server and username only replaces the credentials; the local collection and unsynced cards are kept.',
  '已同步': 'Synced',
  '退出登录会删掉本机的牌组集合副本。继续？':
      'Signing out deletes the local copy of the collection. Continue?',
  '还有 {0} 张卡没有同步到 Anki。放弃这些卡并退出？（放弃后无法找回）':
      '{0} cards have not synced to Anki yet. Discard them and sign out? (They cannot be recovered.)',
  'AnkiWeb 的服务条款只允许官方 Anki 客户端同步。Fushi 会如实表明自己是 Fushi，因此 AnkiWeb 可能拒绝连接，或对你的账号采取措施。自建同步服务器没有这项限制。\n\n仍然使用 AnkiWeb？':
      'AnkiWeb\'s terms only allow the official Anki clients to sync. Fushi identifies itself honestly as Fushi, so AnkiWeb may refuse the connection or act against your account. A self-hosted sync server has no such limit.\n\nUse AnkiWeb anyway?',
  '已登录': 'Signed in',
  '登录后显示。': 'Shown after you sign in.',
  '牌组': 'Deck',
  '笔记类型': 'Note type',
  '标签（空格分隔）': 'Tags (space-separated)',
  '字段映射': 'Field mapping',
  '每个字段填占位符，如 {expression}、{reading}、{glossary}、{sentence}；可组合。没填映射时卡片会留着等，不会丢。':
      'Fill each field with placeholders such as {expression}, {reading}, {glossary}, {sentence}; they can be combined. Without a mapping, cards wait and are not lost.',
  '已落地一轮': 'Delivered one round',
  '已重试 {0} 张': 'Retried {0} cards',

  // ── 复习 ──
  'Fushi 复习': 'Fushi review',
  '本机替已配对设备保管 Fushi 复习的收藏：手机可以远程复习、制卡落到这里，Yomitan 可经下面的 AnkiConnect 往这里加卡。勾选要提供的配置文件（每门语言一份）；不勾选任何一份 = 关闭。同步位置开了端到端加密的配置文件暂不支持。':
      'This server keeps the Fushi review collection for paired devices: phones can review remotely and save cards here, and Yomitan can add cards through the AnkiConnect interface below. Tick the profiles to serve (one per language); none ticked = off. Profiles whose sync location uses end-to-end encryption are not supported yet.',
  '制卡落点': 'Where saved cards go',
  'RWKV 模型': 'RWKV model',
  '算法是 RWKV 的牌组用哪个模型排程（整台设备一个设置，各份配置文件共用）。换了当场生效：需要时先下载新权重，没有这一档的快照时按全部复习历史重放一次，期间这些牌组不出复习卡。':
      'Which model schedules decks that use the RWKV algorithm (one setting for the whole device, shared by all profiles). A change applies at once: the new weights download if needed, and without a saved state for that size the whole review history is replayed once; those decks show no review cards meanwhile.',
  '使用的模型': 'Model',
  'Tiny（默认，每张卡省约 30% 内存，准确度只差约 0.6%）':
      'Tiny (default, about 30% less memory per card, only about 0.6% less accurate)',
  'Small（准确度最好）': 'Small (most accurate)',
  '已切换 RWKV 模型': 'RWKV model switched',
  'RWKV 下载权重中': 'RWKV downloading weights',
  'RWKV 准备中': 'RWKV preparing',
  'RWKV 就绪': 'RWKV ready',
  'RWKV 出错': 'RWKV error',
  'AnkiConnect 兼容接口': 'AnkiConnect-compatible interface',
  '默认关闭。只监听本机时可以不设 key；监听局域网地址必须设 key。每份配置文件可以有自己的 key（Yomitan 里一门语言一个 key），共用 key 落到默认那份。':
      'Off by default. A key is optional when listening on this machine only, and required on a LAN address. Each profile can have its own key (one key per language in Yomitan); the shared key goes to the default profile.',
  '打开中': 'Opening',
  '同步位置已加密（暂不支持）': 'Sync location is encrypted (not supported yet)',
  '数据来自更新版本的 Fushi，请升级服务端':
      'The data comes from a newer Fushi; update the server',
  '复习库升级中': 'Upgrading the review library',
  '升级中': 'Upgrading',
  '另一个进程在升级': 'Another process is upgrading it',
  '需要升级': 'Needs an upgrade',
  '升级失败': 'Upgrade failed',
  '只剩封存的旧库': 'Only the sealed old library is left',
  '新库旁边还有没升级的旧库':
      'An old library that was never upgraded sits beside the new one',
  '升级受阻': 'Upgrade blocked',
  '磁盘空间不够': 'Not enough disk space',
  ' · 已请求叫停': ' · stop requested',
  '复习库换代': 'Review library upgrade',
  '原因': 'Reason',
  '报告': 'Report',
  '开始升级': 'Start upgrade',
  '叫停升级': 'Stop upgrade',
  '开始升级复习库？升级期间远程复习与制卡暂停；旧的 srs.db 会封存保留，不删除任何文件。':
      'Start upgrading the review library? Remote review and mining pause meanwhile; the old srs.db is sealed and kept, no file is deleted.',
  '叫停复习库升级？提交步骤之前叫停会回到升级前的样子；刚好进入提交步骤时以最终结论为准。':
      'Stop the review library upgrade? Before the commit step everything goes back to how it was; if it just entered the commit step, the final verdict is what counts.',
  '已开始升级': 'Upgrade started',
  '已请求叫停': 'Stop requested',
  '复习库升级没完成，需在服务端处理（ctl srs migration）':
      'The review library upgrade did not finish; handle it on the server (ctl srs migration)',
  '已开启': 'On',
  '未开启（没有勾选配置文件）': 'Off (no profile ticked)',
  '调度器': 'Scheduler',
  'FSRS 可用': 'FSRS available',
  '没找到 fushi_fsrs（只能浏览 / 加卡）': 'fushi_fsrs not found (browse / add cards only)',
  '监听 {0}:{1}': 'Listening on {0}:{1}',
  '未监听': 'Not listening',
  ' · {0} 条笔记': ' · {0} notes',
  ' · 同步于 {0}': ' · synced {0}',
  '配置文件': 'Profile',
  ' · 同步目录里已没有': ' · no longer in the sync folder',
  '{0} 条笔记': '{0} notes',
  '同步目录里还没有任何配置文件：先让一台设备经互联同步一次复习数据。':
      'The sync folder has no profiles yet: sync review data from a device over interconnect once first.',
  '待确认的设备': 'Devices waiting for confirmation',
  '本机开始提供某份配置文件之后才第一次同步过来的设备，它的普通修改照常生效，删除与彻底清除先扣在本机，确认是你自己的设备后再生效。拒绝 = 继续扣着，之后仍可改为信任。':
      'A device that first syncs after this server started serving a profile has its ordinary changes applied as usual, but its deletes and purges are held here until you confirm it is your own device. Reject = keep holding them; you can still trust it later.',
  '{0}（Fushi {1}）': '{0} (Fushi {1})',
  '未命名设备': 'Unnamed device',
  '扣着 {0} 条删除、{1} 条彻底清除': 'Holding {0} deletes, {1} purges',
  '首次出现 {0}': 'First seen {0}',
  '待确认': 'Waiting',
  '已拒绝': 'Rejected',
  '信任': 'Trust',
  '拒绝': 'Reject',
  '没有待确认的设备': 'No devices waiting for confirmation',
  '信任「{0}」？它扣着的 {1} 条删除与彻底清除会立即生效。':
      'Trust "{0}"? Its {1} held deletes and purges take effect immediately.',
  '已信任': 'Trusted',
  '已拒绝，删除继续扣着': 'Rejected; its deletes stay held',
  '已开始提供': 'Now serving',
  '已停止提供': 'Stopped serving',
  '已设为默认': 'Set as default',
  '已配对设备「制卡到已配对设备」时卡片落到哪。手机可以在自己的设置里另选；没选时，手机当前的配置文件本机有就落进那份，否则落进默认那份。':
      'Where cards go when a paired device uses "Save to paired device". A phone can choose otherwise in its own settings; if it has not, cards go to the phone\'s current profile when this server has it, otherwise to the default profile.',
  '落到': 'Save to',
  '自动（没配好 Anki 时进复习）': 'Automatic (Review when Anki is not set up)',
  '换日时刻': 'Day starts at',
  '{0} 的制卡牌组（空 = 默认牌组）': 'Deck for {0} (empty = default deck)',
  '{0} 的名字（空 = 用设备报的名字）': 'Name for {0} (empty = the name devices report)',
  '保存名字': 'Save names',
  '旧版本保留副本': 'Old-version retained copy',
  '{0} 到期后自动删除': 'Deleted automatically after {0}',
  '删除前一直保留（不会自动到期）': 'Kept until you delete it (never expires on its own)',
  '自动删除没做成': 'Automatic deletion did not happen',
  '删除保留副本': 'Delete retained copy',
  '已损坏（不是可读的 SQLite 文件），不能再用它退回旧版本；当前复习库不受影响':
      'Damaged (not a readable SQLite file): it can no longer be used to go back to the old version. The current review library is not affected.',
  '立即删除旧版本保留副本？不可撤销：删除后不能再退回旧版本，彻底清除过的内容在旧库里的原文也随之消失。删除前会先核对新库完好，核对不过不删。':
      'Delete the old-version retained copy now? This cannot be undone: you can no longer go back to the old version, and the original text of anything you permanently purged goes with it. The current library is checked first; if the check fails nothing is deleted.',
  '已删除保留副本，释放 {0}': 'Retained copy deleted, {0} freed',
  '没有可删除的保留副本': 'No retained copy to delete',
  '监听地址': 'Listen address',
  '共用 key（落到默认配置文件）': 'Shared key (goes to the default profile)',
  '{0} 专用 key': 'Key for {0}',
  '清除共用 key': 'Clear shared key',
  '已清除': 'Cleared',

  // ── 设置 ──
  '端口 / TLS / 绑定 / qBittorrent / torrent / ffmpeg / onnxruntime 路径改后需重启 serve。':
      'Changes to port / TLS / bind / qBittorrent / torrent / ffmpeg / onnxruntime paths need a serve restart.',
  '界面语言（Language）': 'Language (界面语言)',
  '设备名': 'Device name',
  '互联端口': 'Interconnect port',
  '绑定地址': 'Bind address',
  '局域网配对必须 PIN': 'Require a PIN for LAN pairing',
  '字幕语言': 'Subtitle language',
  '自动（跟随每个视频的语言）': "Auto (follow each video's language)",
  '刮削资料语言（BCP-47，如 ja / zh-CN）':
      'Metadata language (BCP-47, e.g. ja / en / zh-CN)',
  '扫描后自动补刮视频资料': 'Fetch video metadata after scans',
  'TMDB API key（服务端没有内置 key，不填则 TMDB 不可用）':
      'TMDB API key (the server has no built-in key; without one TMDB is unavailable)',
  '扫描后清理文件已消失的视频条目': 'Remove video items whose files are gone after scans',
  '允许已配对设备推送 / 拉取配置文件（Profile）':
      'Allow paired devices to push / pull settings profiles',
  '允许已配对设备远程更新本服务端（仅发布包；装完退出码 10，由服务管理器重启）':
      'Allow paired devices to update this server remotely (release packages only; exits with code 10 for the service manager to restart it)',
  '允许「我的设备」跟随本机 Fushi 排行榜账户自动登录':
      'Allow "my devices" to sign in with this server\'s Fushi leaderboard account',
  '中文查词简繁互查（只管不自带开关的浏览器扩展 / 旧客户端；新版 app 用自己的开关）':
      'Chinese lookup across Simplified / Traditional (only for browser extensions / old clients without their own switch; the current app uses its own)',
  'ffmpeg 路径（空=PATH）': 'ffmpeg path (empty = PATH)',
  'ffprobe 路径（空=PATH）': 'ffprobe path (empty = PATH)',
  'onnxruntime 动态库': 'onnxruntime library',
  'WebUI 端口': 'WebUI port',
  'torrent 引擎': 'Torrent engine',
  '内置引擎库路径（空=随包/系统）': 'Embedded engine library path (empty = bundled / system)',
  'libtorrent 监听接口': 'libtorrent listen interfaces',
  '允许上传 / 做种（关 = 不给任何 peer 上传，已完成的种子暂停做种）':
      'Allow uploading / seeding (off = upload to no peer; finished torrents stop seeding)',
  '上传限速 KB/s（0 = 不限）': 'Upload limit KB/s (0 = unlimited)',
  '下载限速 KB/s（0 = 不限）': 'Download limit KB/s (0 = unlimited)',
  '限速也作用于局域网 peer': 'Apply the limits to LAN peers too',
  '同时下载的种子数（-1 = 不限，0 = libtorrent 默认 3）':
      'Concurrent downloading torrents (-1 = unlimited, 0 = libtorrent default 3)',
  '同时做种的种子数（-1 = 不限，0 = libtorrent 默认 5）':
      'Concurrent seeding torrents (-1 = unlimited, 0 = libtorrent default 5)',
  '最大连接数（0 = 按内存自动推导）': 'Max connections (0 = derived from memory)',
  '分享率上限（0 = 不限；开上传时生效）':
      'Share ratio limit (0 = unlimited; applies when uploading is on)',
  '做种时长上限 分钟（0 = 不限；开上传时生效）':
      'Seeding time limit in minutes (0 = unlimited; applies when uploading is on)',
  'qBittorrent WebUI 地址': 'qBittorrent WebUI address',
  'qBittorrent 用户名': 'qBittorrent username',
  'qBittorrent 密码': 'qBittorrent password',
  'AI 提供商（手机「AI 下视频」选本机执行时用；空 = 不用 AI、不发任何 AI 请求）':
      'AI provider (used when a phone runs "AI video download" on this server; empty = no AI, no AI requests)',
  'AI 模型（空 = 预设起点模型）': 'AI model (empty = the preset\'s default)',
  'AI 接口地址（空 = 预设地址）': 'AI endpoint (empty = the preset\'s address)',
  'AI 协议（空 = 跟随预设）': 'AI protocol (empty = follow the preset)',
  'AI 推理档位': 'AI reasoning effort',
  'AI 允许明文 HTTP（本地推理服务）': 'AI: allow plain HTTP (local inference servers)',
  'AI 联网资料（维基辅助识别作品）': 'AI web knowledge (Wikipedia helps identify titles)',
  'AI 模型能看图（字幕校对会附上视频画面）':
      'AI model accepts images (subtitle proofreading sends video frames)',
  '扫描入库后自动 AI 整理库（把该在一起的归进合集，按量计费）':
      'Organize the library with AI after scans (groups related items into collections; billed per use)',

  // ── 远程访问 ──
  '远程访问': 'Remote access',
  '公网地址（每行一个，http:// 或 https://；反代 / DDNS / 端口映射后的地址，已配对设备会自动学到）':
      'Public addresses (one per line, http:// or https://; the address behind a reverse proxy / DDNS / port forward; paired devices learn them automatically)',
  '允许 P2P 隧道连接': 'Allow P2P tunnel connections',
  '没有公网 IP 时用（iroh）；开启后会连接中继与发现服务，对端 / 中继能看到本机 IP。':
      'For when there is no public IP (iroh). When on, the server connects to relay and discovery services, and peers / relays can see this machine\'s IP.',
  '自建中继（每行一个，空 = iroh 公共中继）':
      'Self-hosted relays (one per line; empty = iroh public relays)',
  '这三项保存即生效，无需重启。': 'These three apply on save; no restart needed.',
  '不可用：没找到 libfushi_p2p（放在 bin/../lib/ 或设环境变量 FUSHI_P2P_LIB）':
      'Unavailable: libfushi_p2p not found (put it in bin/../lib/ or set FUSHI_P2P_LIB)',
  '未开启': 'Off',
  '互联 host 未运行': 'Interconnect host not running',
  '未生效：bind 只监听本机（127.0.0.1），隧道不对外开':
      'Not active: bind listens on this machine only (127.0.0.1), so the tunnel is not exposed',
  '启动失败，详见日志': 'Failed to start; see the logs',
  '中继 {0}': 'Relay {0}',
  '直连 {0}': 'Direct {0}',

  // ── AI 助手会话 ──
  'AI 助手会话': 'AI assistant sessions',
  '已配对设备经互联让本服务端跑的 AI 助手会话（保留 30 天）。这里只读；撤销与续接在发起的那台设备上做。':
      'AI assistant sessions that paired devices ran on this server over interconnect (kept for 30 days). Read-only here; undo and continue on the device that started them.',
  '用户': 'User',
  '操作': 'Action',
  '确认': 'Confirm',
  '候选': 'Choices',
  '提示': 'Notice',
  '本机': 'This server',
  '新对话': 'New chat',

  // ── 词典 ──
  '词典': 'Dictionaries',
  '查词引擎': 'Lookup engine',
  '已配对设备查词时只把要查的文字发过来，去屈折（「食べた」→「食べる」）在本机用本机的变形表做，所以变形表装在服务端即可，各设备无需自带。':
      'Paired devices send only the text to look up. Deinflection (食べた → 食べる) runs here with this server\'s transform tables, so they only need to be installed on the server, not on each device.',
  '导入词典': 'Import a dictionary',
  '导入': 'Import',
  '重新装载引擎': 'Reload engine',
  '词典包': 'Dictionary package',
  '支持 Fushi app 导出的 .fushidict 词典包，以及 Yomitan（.zip）、MDX、DSL 词典。同名词典视为更新，保留排序与设置。导入完立即生效，计入上传配额；也可以在 Fushi 的「词典 · 传输」推送过来。':
      'Accepts .fushidict packages exported from the Fushi app, as well as Yomitan (.zip), MDX and DSL dictionaries. A dictionary with the same name counts as an update and keeps its order and settings. Imports take effect immediately and count toward the upload quota; you can also push one from Fushi under "Dictionaries · Transfer".',
  '顺序决定查词结果里各词典的排列。「默认启用」只对不携带配置词典选择的请求生效（浏览器扩展、旧版 app）；Fushi app 每次查词都带自己配置（Profile）的选择，会覆盖这里的默认值。':
      'The order decides how dictionaries are ranked in lookup results. "Enabled by default" only applies to requests that carry no profile dictionary selection (browser extension, older apps). The Fushi app sends the selection from its own profile with every lookup, which overrides this default.',
  '词典语言同 app 里每本词典的语言设置：「自动」用词典包自己声明的词头语言。改动在设备下次刷新服务端词典目录时生效。':
      'Dictionary language works like the per-dictionary language setting in the app: "Auto" uses the headword language the dictionary package declares. Devices pick up changes the next time they refresh the server dictionary list.',
  '试查': 'Try a lookup',
  '食べた': '食べた',
  '查词': 'Look up',
  '术语': 'Terms',
  '频率': 'Frequency',
  '音调': 'Pitch',
  '汉字': 'Kanji',
  '引擎': 'Engine',
  '已加载': 'Loaded',
  '不可用': 'Unavailable',
  '不可用：{0}': 'Unavailable: {0}',
  '已装载': 'Loaded dictionaries',
  '{0} 本': '{0}',
  '变形表（去屈折）': 'Transform tables (deinflection)',
  '缺失：只能查原形（设 FUSHI_TRANSFORMS_DIR 或随包放 share/fushi/transforms）':
      'Missing: only dictionary forms can be looked up (set FUSHI_TRANSFORMS_DIR or ship share/fushi/transforms)',
  '原生库': 'Native library',
  '默认搜索路径': 'Default search path',
  '上移': 'Move up',
  '下移': 'Move down',
  '文件缺失': 'File missing',
  '日语 (ja)': 'Japanese (ja)',
  '简体中文 (zh-Hans)': 'Simplified Chinese (zh-Hans)',
  '繁体中文 (zh-Hant)': 'Traditional Chinese (zh-Hant)',
  '韩语 (ko)': 'Korean (ko)',
  '英语 (en)': 'English (en)',
  '自动（包内声明：{0}）': 'Auto (package declares {0})',
  '自动（包内未声明）': 'Auto (package declares none)',
  '词典语言': 'Dictionary language',
  'BCP-47 标签，如 de、pt-BR': 'BCP-47 tag, e.g. de or pt-BR',
  '未标注语言': 'No language',
  '版本 {0}': 'Revision {0}',
  '默认启用': 'Enabled by default',
  '已默认启用': 'Now enabled by default',
  '已默认停用': 'Now disabled by default',
  '词典语言已设为 {0}': 'Dictionary language set to {0}',
  '词典语言已恢复自动': 'Dictionary language set back to auto',
  '语言标签无效：{0}': 'Invalid language tag: {0}',
  '修改显示名': 'Rename',
  '显示名': 'Display name',
  '回车保存，Esc 取消，留空恢复原名':
      'Enter to save, Esc to cancel, leave empty to restore the original name',
  '显示名已改为「{0}」': 'Display name changed to "{0}"',
  '已恢复原名': 'Original name restored',
  '服务端还没有词典。在上面导入词典包，或在 Fushi app 的词典管理里推送到服务器。':
      'No dictionaries on the server yet. Import a dictionary package above, or push one from dictionary management in the Fushi app.',
  '删除词典「{0}」？会删掉服务端上的词典文件，用它查词的设备将查不到它（不影响各设备本地的词典）。':
      'Delete dictionary "{0}"? This deletes its files on the server, and devices that look words up with it will no longer find it (dictionaries stored on your devices are not affected).',
  '已重新装载，{0} 本': 'Reloaded, {0} dictionaries',
  '网络错误': 'Network error',
  '先选择一个词典文件': 'Choose a dictionary file first',
  '上传中 {0}%': 'Uploading {0}%',
  '导入中…（大词典要几分钟）': 'Importing… (large dictionaries take a few minutes)',
  '已更新「{0}」（{1}，{2} 词条{3}）': 'Updated "{0}" ({1}, {2} entries{3})',
  '已导入「{0}」（{1}，{2} 词条{3}）': 'Imported "{0}" ({1}, {2} entries{3})',
  '，{0} 汉字': ', {0} kanji',
  '导入失败：{0}': 'Import failed: {0}',
  '按「{0}」查': 'Looked up as "{0}"',
  '没有结果': 'No results',
  // ── 日志 / 标题栏 ──
  '最近日志': 'Recent logs',
  '自动刷新': 'Auto refresh',
  '★ 配对 PIN {0} — fushi_server': '★ Pairing PIN {0} — fushi_server',
  // ── 重设计新增（导航 / 主题 / 空状态 / 设置分组）──
  '菜单': 'Menu',
  '主题：跟随系统': 'Theme: system',
  '主题：浅色': 'Theme: light',
  '主题：深色': 'Theme: dark',
  '确定': 'OK',
  '文件': 'Files',
  '磁力链接': 'Magnet link',
  '站点地址': 'Site address',
  '{0} 个库根': 'Library roots: {0}',
  '取消我的设备': 'Unmark as my device',
  '还没有已配对设备': 'No paired devices yet',
  '已吊销': 'Revoked',
  '{0} 项设置': '{0} settings',
  '没有互联任务': 'No jobs',
  '没有下载任务': 'No downloads',
  '最近检查 {0}': 'Last checked {0}',
  '还没有订阅': 'No subscriptions yet',
  '还没有 AI 助手会话': 'No AI assistant sessions yet',
  '通用': 'General',
  '网络与配对': 'Network and pairing',
  '媒体与刮削': 'Media and metadata',
  '设备权限': 'Device permissions',
  '外部工具': 'External tools',
  '已找到 {0}': 'Found {0}',
  '未找到随包库': 'No bundled library found',
  '未配全：{0}': 'Incomplete: {0}',
  '需重启': 'Restart needed',
  '需要处理': 'Needs attention',
  '漫画 OCR 模型缺失': 'Manga OCR models missing',
  '在「模型」页下载后才能识别漫画文字。':
      'Download them on the Models page to read text in manga.',
  '下载后端未配置': 'Download backend not configured',
  '下载与订阅不可用；在「设置 → 下载」里配置后重启。':
      'Downloads and subscriptions are unavailable. Set one up in Settings → Downloads, then restart.',
  '{0} 部作品待指定刮削结果': '{0} titles need a manual metadata pick',
  '自动刮削拿不准，需要手动指定。':
      'Automatic metadata matching was unsure; pick the right title manually.',
  '未配置 TMDB key': 'No TMDB key set',
  '自动补刮拿不到 TMDB 资料；在「设置 → 媒体与刮削」填写。':
      "Automatic metadata can't use TMDB. Add a key in Settings → Media and metadata.",
  '书籍': 'Books',
  '含漫画与有声书': 'Includes manga and audiobooks',
  '页图目录': 'image folders',
  '音频目录，可带 epub / 字幕': 'Audio folder, optionally with an EPUB / subtitles',
  '更多': 'More',
  '放弃': 'Discard',
  '{0} 项未保存': 'Unsaved changes: {0}',
  '全部': 'All',
  '仅错误': 'Errors only',
  '没有错误': 'No errors',
  // ── 下拉选项 ──
  '其他…': 'Other…',
  '单位': 'Unit',
  '所有网络（0.0.0.0）': 'All networks (0.0.0.0)',
  '仅本机（127.0.0.1）': 'This machine only (127.0.0.1)',
  '不用 AI': 'No AI',
  '自定义': 'Custom',
  // 外观（共享设计系统的明暗 / 风格 / 配色，存本机浏览器）
  '外观': 'Appearance',
  '只存在这台电脑的浏览器里，不影响服务端与其他设备。':
      'Saved in this browser only; does not affect the server or other devices.',
  '明暗': 'Brightness',
  '跟随系统': 'System',
  '浅色': 'Light',
  '深色': 'Dark',
  '风格': 'Style',
  '液态玻璃': 'Liquid glass',
  '配色': 'Color',
  'Fushi 默认': 'Fushi default',
  '紫': 'Purple',
  '靛蓝': 'Indigo',
  '蓝': 'Blue',
  '青': 'Teal',
  '绿': 'Green',
  '黄': 'Yellow',
  '橙': 'Orange',
  '红': 'Red',
  '粉': 'Pink',
  '中性': 'Neutral',
  '拖放文件到这里，或点击选择': 'Drop files here, or click to choose',
  // 侧边栏分组与收起
  '概览': 'Overview',
  '媒体库': 'Media',
  '获取': 'Acquire',
  '学习': 'Study',
  '系统': 'System',
  '收起侧边栏': 'Collapse sidebar',
  '展开侧边栏': 'Expand sidebar',
};
