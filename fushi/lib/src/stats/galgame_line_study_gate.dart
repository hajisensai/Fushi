/// galgame hook 台词 → 学习统计的**入账门**（反馈 LUgHjyc8By）。
///
/// [GalgameLineCharCounter]（`mining/galgame_char_count.dart`）只回答「这一行有几个
/// 字」：标点剔除、相邻重发去重、打字机递增只计增量。它回答不了「这一行读过没有」，
/// 于是两类没读的文本被整句计进字数，再被游玩时长一除就成了虚高的阅读速度：
///
///  1. **快进 / 跳过**（Ctrl 跳过已读、Skip 按钮）：引擎每帧推一句，hook 每句都抓到；
///  2. **历史记录（Backlog）回看**：部分引擎在回看界面重绘旧台词时走的是同一个文本
///     线程，旧台词作为新行再进来一次。
///
/// 两条都与引擎无关，所以判据放在统计层、只看「行文本 + 到达时刻」，不读任何引擎 /
/// 线程 / 游戏特征：
///
///  * **会话内去重**：本会话已经入账过的台词（规范化文本）再出现，一字不计。会话 =
///    一个 hook 会话（换游戏 / 停止监听即 [reset]），跨会话（次日重玩、二周目）照计；
///  * **快速连发不计**：一行从出现到下一行出现的停留时长低于「人能读完它」的下限
///    （[kGalStudyMinLineDwell] 与 [kGalStudyMaxReadableCharsPerSecond] 取大者），且
///    这样的行**连续**出现 [kGalStudySkipBurstMinLines] 行以上，判为快进流：整串撤回
///    字数，停留时长记为跳过时长（游玩时长据此扣除）。
///
/// 一行在它**被离开**的那一刻才知道停留了多久，所以入账是「先记、离开时裁决」：行到
/// 达即按字数入账（统计页随开随见），下一行到达时若判为快进流再撤回。停在最后一行上
/// 的那句（用户松开快进键后真正在读的那句）不会被离开，照常入账。
///
/// 纯 Dart、无 I/O、不持有时钟：时刻由调用方传入（引擎路径用 hook 事件自带的
/// GetTickCount64 毫秒，外部通道用行的接收时刻），只用差值。
library;

import 'package:fushi_engine/stats/study_char_count.dart';

/// 一行台词从出现到被下一行替换的最短可阅读停留。
///
/// 依据：人从看到新文本到点击推进，单是视觉识别 + 选择反应 + 按键就要约 200ms 以上
/// （简单反应时约 200–250ms；读完再点只会更长）。快进 / 跳过模式下引擎按帧推进，
/// 实测量级是每行 16–100ms，与这条下限之间有一个数量级以上的余量。短行（几个字）
/// 的判据由它主导，免得「うん」这类 2 字行按字速算出 50ms 的门形同虚设。
const Duration kGalStudyMinLineDwell = Duration(milliseconds: 200);

/// 可阅读速度上限（字 / 秒）。停留时长低于 `字数 / 这个值` 的行不可能是读过的。
///
/// 依据：日语母语者的默读速度约 400–900 字 / 分（7–15 字 / 秒），速读 / 熟练 VN
/// 读者的上沿约 1200–1500 字 / 分（20–25 字 / 秒）；exSTATic / LunaTranslator 社区
/// 统计里的 VN 读速多在 1–3 万字 / 小时（3–8 字 / 秒）。取 40 字 / 秒（14.4 万字 /
/// 小时）= 人类上沿的约 1.6 倍：宁可让少量极快的真阅读照计，也不误伤正常阅读；
/// 快进流（30 字台词 / 100ms ≈ 300 字 / 秒）仍远在门外。
const int kGalStudyMaxReadableCharsPerSecond = 40;

/// 连续多少行「快于可阅读速度」才判为快进流。
///
/// 单独一两行的快速推进是噪声（误点、双击、两句之间的连点）——用户确实看到了，
/// 不该为此撤回；快进 / Backlog 滚动一次就是几十上百行。3 行足以把两者分开：
/// 门之前的两行先照计，第 3 行确认后整串（含前两行）一起撤回。
const int kGalStudySkipBurstMinLines = 3;

/// 一行在可阅读速度下至少要停留多久（毫秒）。
int galStudyMinDwellMsForChars(int chars) {
  final int byRate = chars <= 0
      ? 0
      : (chars * 1000 / kGalStudyMaxReadableCharsPerSecond).ceil();
  final int floor = kGalStudyMinLineDwell.inMilliseconds;
  return byRate > floor ? byRate : floor;
}

/// 去重用的规范化：去掉空白、标点、符号，西文小写。同一句台词在正文窗与 Backlog
/// 里常差一个括号 / 句号 / 换行，按原文比会漏判。
final RegExp _kNormalizeStrip = RegExp(r'[\s\p{P}\p{S}]', unicode: true);

String normalizeGalStudyLine(String text) =>
    text.replaceAll(_kNormalizeStrip, '').toLowerCase();

/// [GalgameLineStudyGate.admit] 的裁决：调用方据此 `addChars(credit)` /
/// `retractChars(retract)`。两者可同时非 0（上一串被判为快进流撤回、本行照计）。
final class GalgameLineStudyDecision {
  const GalgameLineStudyDecision({
    this.credit = 0,
    this.retract = 0,
    this.skippedDwellMs = 0,
    this.duplicate = false,
    this.retractedLines = 0,
  });

  /// 本行这一拍应入账的字数。
  final int credit;

  /// 应从本会话已入账字数中撤回的字数（快进流确认 / 本行判为重复时撤回本行先前
  /// 已入的打字机增量）。
  final int retract;

  /// 本次新判为快进流的停留时长合计（毫秒），游玩时长据此扣除。
  final int skippedDwellMs;

  /// 本行是本会话已入账台词的重复。
  final bool duplicate;

  /// 本次被判为快进流而撤回的行数（诊断用）。
  final int retractedLines;

  bool get isNoop => credit == 0 && retract == 0 && skippedDwellMs == 0;
}

class _GateLine {
  _GateLine({required this.id, required this.text, required this.firstAtMs});

  final String? id;
  String text;
  final int firstAtMs;
  String normalized = '';
  int credited = 0;
  bool duplicate = false;

  /// 被判为快行时记下的停留（毫秒）。
  int dwellMs = 0;
}

/// 每个 hook 会话一个实例；换游戏 / 停止监听时 [reset]。
class GalgameLineStudyGate {
  /// 本会话已入账（且未被撤回）的台词，规范化文本。量级 = 一局读过的行数。
  final Set<String> _credited = <String>{};

  /// 当前这一行（尚未被离开）。
  _GateLine? _current;

  /// 已离开、停留快于可阅读速度、还没被慢行打断、尚未凑够
  /// [kGalStudySkipBurstMinLines] 行的连续快行。
  final List<_GateLine> _fastRun = <_GateLine>[];

  /// 已确认处在快进流中（凑够门槛后、下一行慢行之前）。
  bool _inBurst = false;

  /// 记一拍台词。
  ///
  /// [lineId] 是这句台词的稳定身份（引擎路径 = 折叠后复用的行 id，同一句越写越长
  /// 时不变）；外部通道没有折叠、传 null，此时「本行以上一行为前缀」即视为同一句
  /// 的打字机续写（与 [GalgameLineCharCounter.countLine] 同一判据）。
  /// [lineText] 是这句**当前的完整文本**，[chars] 是计数器给出的本拍新增字数，
  /// [atMs] 是本拍到达时刻（任意单调毫秒时钟，只用差值）。
  GalgameLineStudyDecision admit({
    required String? lineId,
    required String lineText,
    required int chars,
    required int atMs,
  }) {
    final String text = lineText.trim();
    final _GateLine? current = _current;
    final bool continuation =
        current != null &&
        (lineId != null
            ? lineId == current.id
            : text == current.text ||
                  (current.text.isNotEmpty && text.startsWith(current.text)));
    int retract = 0;
    int skippedDwellMs = 0;
    int retractedLines = 0;
    _GateLine line;
    if (continuation) {
      line = current;
      line.text = text;
    } else {
      if (current != null) {
        final _CloseResult closed = _close(current, atMs);
        retract += closed.retract;
        skippedDwellMs += closed.skippedDwellMs;
        retractedLines += closed.lines;
      }
      line = _GateLine(id: lineId, text: text, firstAtMs: atMs);
      _current = line;
    }
    if (line.duplicate) {
      return GalgameLineStudyDecision(
        retract: retract,
        skippedDwellMs: skippedDwellMs,
        duplicate: true,
        retractedLines: retractedLines,
      );
    }
    final String normalized = normalizeGalStudyLine(text);
    line.normalized = normalized;
    if (normalized.isNotEmpty && _credited.contains(normalized)) {
      // 已入账过的台词（Backlog 回看 / 回想重放）：本行一字不计，打字机先入的增量
      // 一并撤回。
      retract += line.credited;
      line.credited = 0;
      line.duplicate = true;
      return GalgameLineStudyDecision(
        retract: retract,
        skippedDwellMs: skippedDwellMs,
        duplicate: true,
        retractedLines: retractedLines,
      );
    }
    final int credit = chars > 0 ? chars : 0;
    line.credited += credit;
    return GalgameLineStudyDecision(
      credit: credit,
      retract: retract,
      skippedDwellMs: skippedDwellMs,
      retractedLines: retractedLines,
    );
  }

  /// 离开 [line]：按停留时长裁决它是否属于快进流。
  _CloseResult _close(_GateLine line, int atMs) {
    final int dwellMs = atMs - line.firstAtMs;
    // 重复行入账为 0，但它的停留同样要按「读完这句要多久」判，否则快进流里夹着的
    // 已读行一律按下限判、把整串打断成几截。字数走与入账同一口径
    // [countStudyChars]：规范化文本去掉了空白，按码点数会把西文按字母计、与
    // 非重复行（按学习单位入账）的速度门不同源。
    final int charsForRate = line.duplicate
        ? countStudyChars(line.text)
        : line.credited;
    // 时刻倒退（时钟源切换）= 停留未知，按慢行处理，不撤回。
    final bool fast =
        dwellMs >= 0 && dwellMs < galStudyMinDwellMsForChars(charsForRate);
    _remember(line);
    if (!fast) {
      _fastRun.clear();
      _inBurst = false;
      return const _CloseResult();
    }
    line.dwellMs = dwellMs;
    if (_inBurst) return _retractLines(<_GateLine>[line]);
    _fastRun.add(line);
    if (_fastRun.length < kGalStudySkipBurstMinLines) {
      return const _CloseResult();
    }
    // 确认快进流：门之前先照计的几行一起撤回，此后每离开一行快行就单独撤回，
    // 直到出现一行慢行（用户松开快进键 / 关掉 Backlog）。
    _inBurst = true;
    final _CloseResult result = _retractLines(_fastRun);
    _fastRun.clear();
    return result;
  }

  _CloseResult _retractLines(List<_GateLine> lines) {
    int retract = 0;
    int skipped = 0;
    for (final _GateLine runLine in lines) {
      skipped += runLine.dwellMs;
      if (runLine.credited > 0) {
        retract += runLine.credited;
        runLine.credited = 0;
        // 没读过：从「已入账」里摘掉，之后真正读到它时照计。
        _credited.remove(runLine.normalized);
      }
    }
    return _CloseResult(
      retract: retract,
      skippedDwellMs: skipped,
      lines: lines.length,
    );
  }

  void _remember(_GateLine line) {
    if (line.credited > 0 && line.normalized.isNotEmpty) {
      _credited.add(line.normalized);
    }
  }

  /// 会话结束 / 换游戏：下一段从零开始（跨会话的重读照计）。
  void reset() {
    _credited.clear();
    _current = null;
    _fastRun.clear();
    _inBurst = false;
  }
}

final class _CloseResult {
  const _CloseResult({
    this.retract = 0,
    this.skippedDwellMs = 0,
    this.lines = 0,
  });

  final int retract;
  final int skippedDwellMs;
  final int lines;
}
