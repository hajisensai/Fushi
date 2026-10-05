/// 设置搜索的同义词表：用户脑子里的词和设置项标题用的词常常不是同一个
/// （搜「深色」，标题写的是「暗色主题」；搜「快捷键」，标题写的是「按键绑定」）。
///
/// 每组是一组可互换的说法（小写，中 / 英 / 日混排）。查询词元命中组里任一
/// 写法（相等，或是 ≥2 字的子串）时，组内其它写法也参与匹配，排在字面命中之后。
/// 只做召回扩展，不做高亮（字面上不存在的词没法画）。
///
/// 新增设置项时如果它有常见的别称，往这里加一组即可，不需要改 schema。
const List<Set<String>> kSettingsSearchSynonymGroups = <Set<String>>[
  <String>{'暗色', '深色', '夜间', '黑暗', '暗黑', 'dark', 'night', 'ダーク'},
  <String>{'亮色', '浅色', '白天', 'light', 'ライト'},
  <String>{'主题', '配色', '颜色', '色彩', 'theme', 'color', 'colour', 'テーマ'},
  <String>{'字体', '字型', 'font', 'typeface', 'フォント'},
  <String>{'字号', '字大小', '文字大小', 'font size', 'text size', '文字サイズ'},
  <String>{'行距', '行高', '行间距', 'line height', 'line spacing', '行間'},
  <String>{
    '快捷键',
    '按键',
    '键位',
    '热键',
    '绑定',
    'shortcut',
    'hotkey',
    'keybinding',
    'ショートカット',
  },
  <String>{'手柄', '游戏手柄', '控制器', 'gamepad', 'controller', 'コントローラー'},
  <String>{'查词', '词典', '辞典', '字典', 'dictionary', 'lookup', '辞書'},
  <String>{'弹窗', '浮窗', '弹出', 'popup', 'pop-up', 'ポップアップ'},
  <String>{'制卡', '卡片', 'anki', '挖矿', 'mining', 'card', 'カード'},
  <String>{'有声书', '听书', '音频', 'audiobook', 'audio', 'オーディオブック'},
  <String>{'字幕', 'subtitle', 'caption', 'srt', 'ass', '字幕ファイル'},
  <String>{'视频', '影片', '播放器', 'video', 'player', '動画'},
  <String>{'漫画', 'manga', 'comic', 'マンガ'},
  <String>{'游戏', 'galgame', 'gal', 'game', 'ゲーム'},
  <String>{'同步', '云同步', '备份', 'sync', 'backup', 'cloud', '同期', 'バックアップ'},
  <String>{'互联', '局域网', '配对', '设备', 'interconnect', 'lan', 'pair', 'device'},
  <String>{
    '下载',
    '种子',
    '磁力',
    'download',
    'torrent',
    'magnet',
    'qbittorrent',
    'ダウンロード',
  },
  <String>{'代理', '网络', 'proxy', 'network', 'プロキシ'},
  <String>{'语言', '界面语言', '本地化', 'language', 'locale', '言語'},
  <String>{'缓存', '存储', '空间', '占用', '清理', 'cache', 'storage', 'disk', 'キャッシュ'},
  <String>{'日志', '诊断', '调试', '报错', 'log', 'debug', 'diagnostic', 'ログ'},
  <String>{'更新', '版本', 'update', 'version', 'アップデート'},
  <String>{'关于', '许可', '开源', 'about', 'license', 'ライセンス'},
  <String>{'翻页', '分页', '滚动', 'page turn', 'paginated', 'scroll', 'ページ'},
  <String>{'竖排', '纵排', '直排', 'vertical', 'tategaki', '縦書き'},
  <String>{'横排', 'horizontal', 'yokogaki', '横書き'},
  <String>{'注音', '假名', '振假名', 'furigana', 'ruby', 'ふりがな'},
  <String>{'音量', '声音', '静音', 'volume', 'sound', 'mute', '音量'},
  <String>{'倍速', '速度', '播放速度', 'speed', 'playback rate', '再生速度'},
  <String>{'亮度', 'brightness', '明るさ'},
  <String>{'墨水屏', '电纸书', '电子墨水', 'eink', 'e-ink', 'e-paper', '電子ペーパー'},
  <String>{'动画', '动效', '动态效果', 'animation', 'motion', 'アニメーション'},
  <String>{'通知', '提醒', 'notification', 'notify', '通知'},
  <String>{'隐私', '权限', 'privacy', 'permission', 'プライバシー'},
  <String>{'账号', '账户', '登录', 'account', 'login', 'sign in', 'アカウント'},
  <String>{'刮削', '元数据', '资料', 'scrape', 'metadata', 'メタデータ'},
  <String>{'ocr', '文字识别', '识别', 'text recognition', '文字認識'},
  <String>{'ai', '大模型', '人工智能', 'llm', 'gpt', 'claude'},
  <String>{'图标', 'icon', 'アイコン'},
  <String>{'悬浮球', '浮动球', 'floating ball', 'bubble'},
  <String>{'统计', '学习时间', '阅读时间', 'statistics', 'stats', '統計'},
  <String>{'配置', '档案', '个人资料', 'profile', 'プロファイル'},
  <String>{'高亮', '标记', 'highlight', 'ハイライト'},
  <String>{'书签', 'bookmark', 'ブックマーク'},
  <String>{'目录', '章节', 'toc', 'chapter', '目次'},
];

/// 查询词元 [token]（已小写）的同义写法（含自身）。命中规则：与组内某写法相等，
/// 或词元 ≥ 2 字且是某写法的子串 / 某写法是词元的子串（「深色模式」也能落到
/// 「深色」组）。
List<String> settingsSearchSynonymsOf(String token) {
  final Set<String> result = <String>{token};
  if (token.isEmpty) return result.toList(growable: false);
  for (final Set<String> group in kSettingsSearchSynonymGroups) {
    final bool hit = group.any(
      (String word) =>
          word == token ||
          (token.length >= 2 && word.contains(token)) ||
          (_longEnough(word) && token.contains(word)),
    );
    if (hit) result.addAll(group);
  }
  return result.toList(growable: false);
}

/// 「词元里包含组内写法」这个方向只对足够长的写法成立：短的拉丁写法（ai / gal /
/// lan / ass）会被无关单词包含（language ⊃ lan），CJK 两个字已经足够专指。
bool _longEnough(String word) {
  final bool ascii = word.codeUnits.every((int c) => c < 0x80);
  return ascii ? word.length >= 4 : word.length >= 2;
}
