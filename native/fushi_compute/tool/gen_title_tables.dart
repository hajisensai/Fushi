// 生成 native/fushi_compute/src/parse/title_score/title_tables.rs：视频刮削标题归一化
// （`TitleNormalizer`，packages/fushi_engine/lib/media/video/scraper/title_normalizer.dart）
// 与 AniDB 标题搜索打分用的字符表。
//
// 用法（仓库根）：
//   dart native/fushi_compute/tool/gen_title_tables.dart          重新生成
//   dart native/fushi_compute/tool/gen_title_tables.dart --check  只比对，不一致退出 1
//
// **繁简映射与装饰符号只在这里定义一次**（运行时只有 Rust 查表）。其余几张表是把 Dart
// 运行时语义（`RegExp(r'\s')`、`String.trim()`、原 Dart 实现里的 `_isWordChar`）逐码点
// 冻结下来，让 Rust 侧与原 Dart 实现逐位一致（`String.toLowerCase` 用 crate 共用的
// `src/parse/dart_lower.rs`，表由 tool/gen_dart_lower_table.dart 生成，这里不再另导一份）：
//   - WS_REGEX / WS_TRIM：非 unicode 模式 `\s` 与 `trim()` 的空白集合（二者差一个 U+0085）。
//   - WORD_RANGES：分词的「字母/数字」判定（ASCII 字母数字、罗马数字区、CJK，以及
//     `toLowerCase() != toUpperCase() || \p{L}|\p{N}` 的其它码点）。
// 注意：后三类按**运行本脚本的 Dart SDK 的 Unicode 数据**生成；换 SDK 后重生成会改变
// 归一化 / 相似度结果（视频刮削的匹配口径），没打算改口径就别重生成。
import 'dart:io';

/// 繁体（含日文旧字体与新字体变体）→ 简体 单字映射。
/// 只求覆盖动画标题高频字，不做全量 OpenCC；一对多歧义字（如 发/髮）
/// 按标题语境取最常见义。表刻意保持一行一条便于增补。
const Map<String, String> _kTraditionalToSimplified = <String, String>{
  '無': '无',
  '職': '职',
  '転': '转',
  '轉': '转',
  '傳': '传',
  '伝': '传',
  '說': '说',
  '説': '说',
  '戰': '战',
  '戦': '战',
  '鬥': '斗',
  '闘': '斗',
  '鬪': '斗',
  '學': '学',
  '樂': '乐',
  '楽': '乐',
  '藥': '药',
  '薬': '药',
  '龍': '龙',
  '竜': '龙',
  '鳳': '凤',
  '們': '们',
  '個': '个',
  '這': '这',
  '來': '来',
  '氣': '气',
  '気': '气',
  '愛': '爱',
  '惡': '恶',
  '悪': '恶',
  '戀': '恋',
  '點': '点',
  '眞': '真',
  '實': '实',
  '実': '实',
  '寫': '写',
  '髮': '发',
  '髪': '发',
  '發': '发',
  '廢': '废',
  '廃': '废',
  '陰': '阴',
  '陽': '阳',
  '隱': '隐',
  '隠': '隐',
  '靈': '灵',
  '霊': '灵',
  '國': '国',
  '圖': '图',
  '図': '图',
  '圓': '圆',
  '円': '圆',
  '團': '团',
  '団': '团',
  '園': '园',
  '書': '书',
  '畫': '画',
  '話': '话',
  '語': '语',
  '誰': '谁',
  '課': '课',
  '讀': '读',
  '読': '读',
  '談': '谈',
  '請': '请',
  '諸': '诸',
  '謎': '谜',
  '譯': '译',
  '訳': '译',
  '證': '证',
  '証': '证',
  '議': '议',
  '記': '记',
  '車': '车',
  '軍': '军',
  '輪': '轮',
  '輝': '辉',
  '較': '较',
  '載': '载',
  '轟': '轰',
  '門': '门',
  '問': '问',
  '間': '间',
  '聞': '闻',
  '開': '开',
  '關': '关',
  '関': '关',
  '閉': '闭',
  '閃': '闪',
  '馬': '马',
  '騎': '骑',
  '驅': '驱',
  '駆': '驱',
  '驚': '惊',
  '驗': '验',
  '験': '验',
  '鳥': '鸟',
  '鳴': '鸣',
  '鶴': '鹤',
  '魚': '鱼',
  '鮮': '鲜',
  '風': '风',
  '飛': '飞',
  '飯': '饭',
  '館': '馆',
  '餓': '饿',
  '頭': '头',
  '顏': '颜',
  '顔': '颜',
  '願': '愿',
  '類': '类',
  '題': '题',
  '額': '额',
  '順': '顺',
  '須': '须',
  '頂': '顶',
  '項': '项',
  '領': '领',
  '頻': '频',
  '顯': '显',
  '黒': '黑',
  '歲': '岁',
  '歳': '岁',
  '兒': '儿',
  '児': '儿',
  '處': '处',
  '処': '处',
  '號': '号',
  '萬': '万',
  '與': '与',
  '體': '体',
  '勞': '劳',
  '労': '劳',
  '動': '动',
  '働': '动',
  '員': '员',
  '勝': '胜',
  '勢': '势',
  '區': '区',
  '醫': '医',
  '華': '华',
  '榮': '荣',
  '栄': '荣',
  '覺': '觉',
  '覚': '觉',
  '觀': '观',
  '観': '观',
  '見': '见',
  '視': '视',
  '親': '亲',
  '覽': '览',
  '計': '计',
  '訓': '训',
  '討': '讨',
  '訪': '访',
  '設': '设',
  '許': '许',
  '詞': '词',
  '詩': '诗',
  '試': '试',
  '詳': '详',
  '誌': '志',
  '認': '认',
  '誤': '误',
  '誕': '诞',
  '調': '调',
  '論': '论',
  '謝': '谢',
  '講': '讲',
  '識': '识',
  '護': '护',
  '讓': '让',
  '貝': '贝',
  '負': '负',
  '財': '财',
  '貨': '货',
  '販': '贩',
  '貴': '贵',
  '買': '买',
  '貸': '贷',
  '費': '费',
  '資': '资',
  '賊': '贼',
  '賢': '贤',
  '賣': '卖',
  '売': '卖',
  '質': '质',
  '購': '购',
  '贊': '赞',
  '輕': '轻',
  '軽': '轻',
  '運': '运',
  '過': '过',
  '達': '达',
  '違': '违',
  '遙': '遥',
  '遠': '远',
  '適': '适',
  '選': '选',
  '遲': '迟',
  '還': '还',
  '邊': '边',
  '辺': '边',
  '遊': '游',
  '針': '针',
  '鈍': '钝',
  '鋼': '钢',
  '錄': '录',
  '録': '录',
  '錢': '钱',
  '鐵': '铁',
  '鉄': '铁',
  '銀': '银',
  '銃': '铳',
  '鏡': '镜',
  '鐘': '钟',
  '長': '长',
  '陣': '阵',
  '際': '际',
  '隊': '队',
  '階': '阶',
  '隨': '随',
  '險': '险',
  '雙': '双',
  '雜': '杂',
  '雑': '杂',
  '難': '难',
  '離': '离',
  '雲': '云',
  '電': '电',
  '靜': '静',
  '韓': '韩',
  '飾': '饰',
  '養': '养',
  '餘': '余',
  '麗': '丽',
  '麼': '么',
  '黃': '黄',
  '齊': '齐',
  '斉': '齐',
  '齡': '龄',
  '劍': '剑',
  '剣': '剑',
  '創': '创',
  '劇': '剧',
  '務': '务',
  '勵': '励',
  '協': '协',
  '單': '单',
  '単': '单',
  '嚴': '严',
  '厳': '严',
  '喚': '唤',
  '喪': '丧',
  '嘆': '叹',
  '壞': '坏',
  '壊': '坏',
  '壓': '压',
  '圧': '压',
  '壘': '垒',
  '塁': '垒',
  '墮': '堕',
  '塵': '尘',
  '夢': '梦',
  '夥': '伙',
  '夠': '够',
  '奮': '奋',
  '婦': '妇',
  '媽': '妈',
  '孫': '孙',
  '寶': '宝',
  '寢': '寝',
  '審': '审',
  '寬': '宽',
  '壽': '寿',
  '專': '专',
  '將': '将',
  '尋': '寻',
  '對': '对',
  '導': '导',
  '師': '师',
  '帶': '带',
  '帰': '归',
  '歸': '归',
  '幫': '帮',
  '幾': '几',
  '廣': '广',
  '広': '广',
  '廳': '厅',
  '庁': '厅',
  '彈': '弹',
  '弾': '弹',
  '強': '强',
  '彌': '弥',
  '彎': '弯',
  '從': '从',
  '憶': '忆',
  '応': '应',
  '應': '应',
  '懷': '怀',
  '憂': '忧',
  '態': '态',
  '慶': '庆',
  '憲': '宪',
  '懸': '悬',
  '戲': '戏',
  '戯': '戏',
  '戸': '户',
  '戶': '户',
  '掃': '扫',
  '擊': '击',
  '撃': '击',
  '擁': '拥',
  '擇': '择',
  '択': '择',
  '據': '据',
  '擬': '拟',
  '擴': '扩',
  '拡': '扩',
  '敗': '败',
  '敵': '敌',
  '數': '数',
  '斷': '断',
  '時': '时',
  '晝': '昼',
  '曉': '晓',
  '暁': '晓',
  '會': '会',
  '機': '机',
  '極': '极',
  '樓': '楼',
  '標': '标',
  '樹': '树',
  '橋': '桥',
  '檢': '检',
  '検': '检',
  '權': '权',
  '歐': '欧',
  '歡': '欢',
  '歓': '欢',
  '歩': '步',
  '歷': '历',
  '歴': '历',
  '殘': '残',
  '殺': '杀',
  '殼': '壳',
  '毆': '殴',
  '毎': '每',
  '氷': '冰',
  '決': '决',
  '沒': '没',
  '沢': '泽',
  '澤': '泽',
  '淚': '泪',
  '涙': '泪',
  '滿': '满',
  '満': '满',
  '漢': '汉',
  '濱': '滨',
  '浜': '滨',
  '灣': '湾',
  '瀨': '濑',
  '瀬': '濑',
  '燒': '烧',
  '焼': '烧',
  '營': '营',
  '爲': '为',
  '為': '为',
  '烏': '乌',
  '燈': '灯',
  '爭': '争',
  '獨': '独',
  '獄': '狱',
  '獣': '兽',
  '獸': '兽',
  '現': '现',
  '環': '环',
  '產': '产',
  '産': '产',
  '異': '异',
  '畢': '毕',
  '當': '当',
  '療': '疗',
  '癒': '愈',
  '盡': '尽',
  '監': '监',
  '盤': '盘',
  '礎': '础',
  '禮': '礼',
  '禍': '祸',
  '稱': '称',
  '種': '种',
  '穩': '稳',
  '窮': '穷',
  '竊': '窃',
  '筆': '笔',
  '節': '节',
  '築': '筑',
  '簡': '简',
  '籠': '笼',
  '篭': '笼',
  '級': '级',
  '紀': '纪',
  '約': '约',
  '紅': '红',
  '純': '纯',
  '紙': '纸',
  '結': '结',
  '絆': '绊',
  '絕': '绝',
  '絶': '绝',
  '統': '统',
  '經': '经',
  '経': '经',
  '綺': '绮',
  '緒': '绪',
  '緣': '缘',
  '縁': '缘',
  '線': '线',
  '練': '练',
  '縛': '缚',
  '總': '总',
  '織': '织',
  '繩': '绳',
  '繪': '绘',
  '絵': '绘',
  '續': '续',
  '続': '续',
  '纏': '缠',
  '罰': '罚',
  '羅': '罗',
  '聖': '圣',
  '聲': '声',
  '聯': '联',
  '聽': '听',
  '腦': '脑',
  '脳': '脑',
  '臟': '脏',
  '臓': '脏',
  '舊': '旧',
  '艦': '舰',
  '莊': '庄',
  '葉': '叶',
  '蒼': '苍',
  '蓋': '盖',
  '蔵': '藏',
  '藍': '蓝',
  '蘭': '兰',
  '蟲': '虫',
  '術': '术',
  '衛': '卫',
  '衝': '冲',
  '裝': '装',
  '製': '制',
  '複': '复',
  '襲': '袭',
  '覇': '霸',
  '觸': '触',
  '豐': '丰',
  '貓': '猫',
  '軌': '轨',
  '邏': '逻',
  '釀': '酿',
  '隣': '邻',
  '鄰': '邻',
  '響': '响',
  '騷': '骚',
  '騒': '骚',
  '髏': '髅',
  '鯨': '鲸',
  '鹽': '盐',
  '黨': '党',
  '齋': '斋',
  '斎': '斋',
  '島': '岛',
  '嶋': '岛',
  '嶺': '岭',
  '亞': '亚',
  '亜': '亚',
  '傑': '杰',
  '傷': '伤',
  '僞': '伪',
  '偽': '伪',
  '優': '优',
  '內': '内',
  '兩': '两',
  '凍': '冻',
  '劉': '刘',
  '勳': '勋',
  '吳': '吴',
  '呉': '吴',
  '場': '场',
  '奧': '奥',
  '姫': '姬',
  '宮': '宫',
  '層': '层',
  '庫': '库',
  '後': '后',
  '復': '复',
  '恆': '恒',
  '撫': '抚',
  '擔': '担',
  '敘': '叙',
  '東': '东',
  '櫻': '樱',
  '桜': '樱',
  '淵': '渊',
  '溫': '温',
  '熱': '热',
  '窓': '窗',
  '競': '竞',
  '裏': '里',
  '裡': '里',
  '週': '周',
  '陸': '陆',
  '霧': '雾',
  '頁': '页',
  '默': '默',
  '黙': '默',
  '齒': '齿',
  '歯': '齿',
  '龜': '龟',
  '亀': '龟',
  '條': '条',
  '樣': '样',
  '様': '样',
  '檔': '档',
  '隻': '只',
  '祥': '祥',
  '屬': '属',
  '屍': '尸',
  '屆': '届',
  '樱': '樱',
  '緑': '绿',
  '綠': '绿',
  '藝': '艺',
  '芸': '艺',
  '溝': '沟',
  '灰': '灰',
  '燄': '焰',
  '獵': '猎',
  '猟': '猎',
  '皚': '皑',
  '禱': '祷',
  '祈': '祈',
  '緊': '紧',
  '縣': '县',
  '県': '县',
  '聡': '聪',
  '聰': '聪',
  '荘': '庄',
  '虛': '虚',
  '虚': '虚',
  '蟬': '蝉',
  '蝉': '蝉',
  '訣': '诀',
  '誇': '夸',
  '誓': '誓',
  '謳': '讴',
  '譚': '谭',
  '讚': '赞',
  '贖': '赎',
  '躍': '跃',
  '輩': '辈',
  '輸': '输',
  '辭': '辞',
  '辞': '辞',
  '遺': '遗',
  '鄉': '乡',
  '鄕': '乡',
  '釣': '钓',
  '鈴': '铃',
  '鎖': '锁',
  '鎮': '镇',
  '鏈': '链',
  '鑑': '鉴',
  '陛': '陛',
  '隅': '隅',
  '隷': '隶',
  '隸': '隶',
  '雛': '雏',
  '雫': '雫',
  '靑': '青',
  '韻': '韵',
  '飼': '饲',
  '駄': '驮',
  '骨': '骨',
  '魎': '魉',
  '魍': '魍',
  '鴉': '鸦',
  '麵': '面',
  '麺': '面',
  '黎': '黎',
  '齢': '龄',
};

/// 装饰符号（归一化后按半角判断；替换为空格再折叠）。
/// 注意不含 CJK 长音符「ー」（是词的一部分）与罗马数字（用于季度识别）。
final List<int> _kDecorationChars = <int>[
  // ASCII 标点（全角经平移后也落在这里）。
  ...r'''!"#$%&'()*+,-./:;<=>?@[\]^_`{|}~'''.codeUnits,
  // 常见 CJK / 排版装饰符。
  ...'～〜、。・·•「」『』【】《》〈〉≪≫〔〕｛｝｟｠…‥⋯′″‘’“”—―–‐‑‒−☆★♪♫♡♥◆◇■□●○◎△▲▽▼※†‡°〇÷×'.runes,
];

final RegExp _unicodeLetterOrDigit = RegExp(r'\p{L}|\p{N}', unicode: true);
final RegExp _regexWhitespace = RegExp(r'\s');

bool _isCjk(int rune) {
  return (rune >= 0x4E00 && rune <= 0x9FFF) ||
      (rune >= 0x3400 && rune <= 0x4DBF) ||
      (rune >= 0xF900 && rune <= 0xFAFF) ||
      (rune >= 0x3040 && rune <= 0x309F) ||
      (rune >= 0x30A0 && rune <= 0x30FF);
}

bool _isWordChar(int rune) {
  if ((rune >= 0x30 && rune <= 0x39) ||
      (rune >= 0x41 && rune <= 0x5A) ||
      (rune >= 0x61 && rune <= 0x7A)) {
    return true;
  }
  if (rune >= 0x2160 && rune <= 0x217F) return true;
  if (_isCjk(rune)) return true;
  if (rune > 0x7F) {
    final String s = String.fromCharCode(rune);
    return s.toLowerCase() != s.toUpperCase() ||
        _unicodeLetterOrDigit.hasMatch(s);
  }
  return false;
}

String _hex(int value) => '0x${value.toRadixString(16).toUpperCase()}';

int _fnv(int hash, int value) {
  for (int shift = 0; shift < 32; shift += 8) {
    hash ^= (value >> shift) & 0xff;
    hash = (hash * 0x01000193) & 0xffffffff;
  }
  return hash;
}

String _render() {
  int digest = 0x811c9dc5;
  final StringBuffer out = StringBuffer()
    ..writeln('// 由 native/fushi_compute/tool/gen_title_tables.dart 生成，不要手改。')
    ..writeln('// 表的来源与重新生成的纪律见该脚本文件头。')
    ..writeln();

  for (final MapEntry<String, String> e in _kTraditionalToSimplified.entries) {
    if (e.key.length != 1 || e.value.length != 1) {
      throw StateError('trad→simp entries must be single BMP units: ${e.key}');
    }
  }
  final List<MapEntry<int, int>> t2s = <MapEntry<int, int>>[
    for (final MapEntry<String, String> e in _kTraditionalToSimplified.entries)
      MapEntry<int, int>(e.key.codeUnitAt(0), e.value.codeUnitAt(0)),
  ]..sort((MapEntry<int, int> a, MapEntry<int, int> b) => a.key - b.key);
  out.writeln('/// 繁→简单字映射（按键升序；键与值都是单个 BMP 码元）。');
  out.writeln(
    'pub(super) static TRAD_TO_SIMP: [(u16, u16); ${t2s.length}] = [',
  );
  for (final MapEntry<int, int> e in t2s) {
    out.writeln('    (${_hex(e.key)}, ${_hex(e.value)}),');
    digest = _fnv(_fnv(digest, e.key), e.value);
  }
  out
    ..writeln('];')
    ..writeln();

  final List<int> decoration = _kDecorationChars.toSet().toList()..sort();
  for (final int c in decoration) {
    if (c > 0xFFFF) throw StateError('decoration chars must be BMP');
  }
  out.writeln('/// 装饰符号（升序，单个 BMP 码元）。');
  out.writeln('pub(super) static DECORATION: [u16; ${decoration.length}] = [');
  for (final int c in decoration) {
    out.writeln('    ${_hex(c)},');
    digest = _fnv(digest, c);
  }
  out
    ..writeln('];')
    ..writeln();

  // 补充平面没有空白；按码元判即可（`\s` 在非 unicode 模式下逐码元匹配）。
  final List<int> regexWs = <int>[
    for (int u = 0; u <= 0xFFFF; u++)
      if (_regexWhitespace.hasMatch(String.fromCharCode(u))) u,
  ];
  final List<int> trimWs = <int>[
    for (int u = 0; u <= 0xFFFF; u++)
      if ('a${String.fromCharCode(u)}'.trim() == 'a' &&
          '${String.fromCharCode(u)}a'.trim() == 'a')
        u,
  ];
  for (final (String name, List<int> set) in <(String, List<int>)>[
    ('WS_REGEX', regexWs),
    ('WS_TRIM', trimWs),
  ]) {
    out.writeln('/// 空白码元集合（升序），见脚本文件头。');
    out.writeln('pub(super) static $name: [u16; ${set.length}] = [');
    for (final int u in set) {
      out.writeln('    ${_hex(u)},');
      digest = _fnv(digest, u);
    }
    out
      ..writeln('];')
      ..writeln();
  }

  final List<(int, int)> word = <(int, int)>[];
  int? start;
  for (int cp = 0; cp <= 0x110000; cp++) {
    final bool inWord = cp <= 0x10FFFF && _isWordChar(cp);
    if (inWord) {
      start ??= cp;
    } else if (start != null) {
      word.add((start, cp - 1));
      start = null;
    }
  }
  out.writeln('/// 分词「字母/数字」码点区间（闭区间、升序、互不重叠）。');
  out.writeln(
    'pub(super) static WORD_RANGES: [(u32, u32); ${word.length}] = [',
  );
  for (final (int a, int b) in word) {
    out.writeln('    (${_hex(a)}, ${_hex(b)}),');
    digest = _fnv(_fnv(digest, a), b);
  }
  out
    ..writeln('];')
    ..writeln()
    ..writeln('/// 以上全部表按出现顺序逐个 u32 的 FNV-1a；Rust 测试用同一算法核对。')
    ..writeln('#[cfg(test)]')
    ..writeln(
      'pub(super) const TITLE_TABLES_FNV1A: u32 = '
      '0x${digest.toRadixString(16).padLeft(8, '0')};',
    );
  return out.toString();
}

void main(List<String> args) {
  final bool check = args.contains('--check');
  final String scriptDir = File(Platform.script.toFilePath()).parent.path;
  final File target = File(
    '$scriptDir/../src/parse/title_score/title_tables.rs',
  );
  final String rendered = _render();
  if (check) {
    final bool same =
        target.existsSync() && target.readAsStringSync() == rendered;
    stdout.writeln(same ? 'title_tables.rs up to date' : 'OUT OF DATE');
    exitCode = same ? 0 : 1;
    return;
  }
  target.parent.createSync(recursive: true);
  target.writeAsStringSync(rendered);
  stdout.writeln('wrote ${target.path}');
}
