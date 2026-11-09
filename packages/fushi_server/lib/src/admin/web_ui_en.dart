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
  '进度': 'Progress',
  '创建': 'Create',
  '已创建': 'Created',
  '错误': 'Error',
  '标题': 'Title',
  '设备': 'Device',
  '端口': 'Port',
  '语言': 'Language',
  '字节': 'Bytes',
  '更新': 'Updated',
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
  '库根': 'Library roots',
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
  '配对请求': 'Pairing requests',
  '没有待处理的配对。在 Fushi 里添加互联设备并输入本机地址，PIN 会显示在这里。':
      'No pending pairing. In Fushi, add an interconnect device and enter this server\'s address; the PIN shows up here.',
  '{0} ({1}) 请求配对，请在该设备输入：':
      '{0} ({1}) wants to pair. Enter this on that device:',
  '未知设备': 'Unknown device',
  '已配对设备': 'Paired devices',
  '最近地址': 'Last address',
  '配对时间': 'Paired at',
  '我的设备': 'My device',
  '是（取消）': 'Yes (unmark)',
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
  '设置项': 'Settings',
  '收到时间': 'Received',
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
  'manga (mokuro / cbz / cbr / cb7 / zip / rar / 页图目录)':
      'manga (mokuro / cbz / cbr / cb7 / zip / rar / image folder)',
  'audiobook (音频目录，可带 epub / 字幕)':
      'audiobook (audio folder, optionally with epub / subtitles)',
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
  '集数': 'Episodes',
  '最近': 'Last check',
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
  'Torznab（Jackett / Prowlarr）': 'Torznab (Jackett / Prowlarr)',
  '添加 indexer': 'Add indexer',
  '放弃修改': 'Discard changes',
  '无法识别这个站点': 'Could not recognize this site',
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
  '分类（逗号分隔，可空）': 'Categories (comma-separated, optional)',
  '清除已存的 key': 'Clear the stored key',
  '还没有 Torznab indexer。': 'No Torznab indexers yet.',
  '第 {0} 个 indexer 的优先级必须是整数':
      'The priority of indexer {0} must be a whole number',

  // ── 模型 ──
  'ASR 模型': 'ASR models',
  '变体 / provider': 'Variant / provider',
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
  'AnkiConnect 兼容接口': 'AnkiConnect-compatible interface',
  '默认关闭。只监听本机时可以不设 key；监听局域网地址必须设 key。每份配置文件可以有自己的 key（Yomitan 里一门语言一个 key），共用 key 落到默认那份。':
      'Off by default. A key is optional when listening on this machine only, and required on a LAN address. Each profile can have its own key (one key per language in Yomitan); the shared key goes to the default profile.',
  '打开中': 'Opening',
  '同步位置已加密（暂不支持）': 'Sync location is encrypted (not supported yet)',
  '数据来自更新版本的 Fushi，请升级服务端':
      'The data comes from a newer Fushi; update the server',
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
  '已开始提供': 'Now serving',
  '已停止提供': 'Stopped serving',
  '已设为默认': 'Set as default',
  '已配对设备「制卡到已配对设备」时卡片落到哪。手机可以在自己的设置里另选；没选时，手机当前的配置文件本机有就落进那份，否则落进默认那份。':
      'Where cards go when a paired device uses "Save to paired device". A phone can choose otherwise in its own settings; if it has not, cards go to the phone\'s current profile when this server has it, otherwise to the default profile.',
  '落到': 'Save to',
  '自动（没配好 Anki 时进复习）': 'Automatic (Review when Anki is not set up)',
  '换日时刻（0–23 点）': 'Day starts at (hour, 0–23)',
  '{0} 的制卡牌组（空 = 默认牌组）': 'Deck for {0} (empty = default deck)',
  '监听地址（127.0.0.1 = 只限本机）': 'Listen address (127.0.0.1 = this machine only)',
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
  '刮削资料语言（BCP-47，如 ja / zh-CN）':
      'Metadata language (BCP-47, e.g. ja / en / zh-CN)',
  '扫描后自动补刮视频资料': 'Fetch video metadata after scans',
  'TMDB API key（服务端没有内置 key，不填则 TMDB 不可用）':
      'TMDB API key (the server has no built-in key; without one TMDB is unavailable)',
  '扫描后清理文件已消失的视频条目': 'Remove video items whose files are gone after scans',
  '允许已配对设备推送 / 拉取配置文件（Profile）':
      'Allow paired devices to push / pull settings profiles',
  '允许已配对设备远程更新本服务端（仅发布包；装完退出码 75，由服务管理器重启）':
      'Allow paired devices to update this server remotely (release packages only; exits with code 75 for the service manager to restart it)',
  '允许「我的设备」跟随本机 Fushi 排行榜账户自动登录':
      'Allow "my devices" to sign in with this server\'s Fushi leaderboard account',
  '中文查词简繁互查（只管不自带开关的浏览器扩展 / 旧客户端；新版 app 用自己的开关）':
      'Chinese lookup across Simplified / Traditional (only for browser extensions / old clients without their own switch; the current app uses its own)',
  'ffmpeg 路径（空=PATH）': 'ffmpeg path (empty = PATH)',
  'ffprobe 路径（空=PATH）': 'ffprobe path (empty = PATH)',
  'onnxruntime 动态库': 'onnxruntime library',
  '上传配额（字节）': 'Upload quota (bytes)',
  'WebUI 端口': 'WebUI port',
  'torrent 引擎': 'Torrent engine',
  '内置引擎库路径（空=随包/系统）': 'Embedded engine library path (empty = bundled / system)',
  'libtorrent 监听接口': 'libtorrent listen interfaces',
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
  '扫描入库后自动 AI 整理库（把该在一起的归进合集，按量计费）':
      'Organize the library with AI after scans (groups related items into collections; billed per use)',
  '（已找到 {0}）': ' (found {0})',
  '（未找到随包库）': ' (no bundled library found)',
  '（可用）': ' (ready)',
  '（未配全：{0}）': ' (incomplete: {0})',

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
  '发起设备': 'Started from',
  '用户': 'User',
  '操作': 'Action',
  '确认': 'Confirm',
  '候选': 'Choices',
  '提示': 'Notice',
  '本机': 'This server',
  '新对话': 'New chat',

  // ── 日志 / 标题栏 ──
  '最近日志': 'Recent logs',
  '自动刷新': 'Auto refresh',
  '★ 配对 PIN {0} — fushi_server': '★ Pairing PIN {0} — fushi_server',
};
