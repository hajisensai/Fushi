// 测试夹具：造旧协议形态的事件（别的设备 / 旧版本写出来、之后经备份合并或导入进来的那种）。
//
// 本机的写入者（dot / 因果上下文）与 HLC 时钟都在内核里（native/fushi_fsrs/src/store/legacy_clock.rs、
// store/sync2/mod.rs `apply_local_on`），生产代码不再有 Dart 版；这里的两个小工具只给测试造「对端写的」数据用。
import 'package:fushi_srs/fushi_srs.dart';

/// 旧协议的写入者：按序分配 dot，每条记录的因果上下文覆盖它此前写过的全部。
class LegacyEditWriter {
  LegacyEditWriter(this.writerId);

  final String writerId;
  int _lastSeq = 0;
  SrsCausalContext _applied = SrsCausalContext.empty();

  SrsFieldEdit create({
    required String profileUid,
    required SrsEntityKind entityKind,
    required String entityId,
    required String fieldKey,
    required Object? value,
    required Hlc hlc,
    required SrsTimeSource timeSource,
    bool machine = false,
  }) {
    _lastSeq += 1;
    final SrsFieldEdit edit = SrsFieldEdit(
      profileUid: profileUid,
      entityKind: entityKind,
      entityId: entityId,
      fieldKey: fieldKey,
      dot: SrsDot(writerId, _lastSeq),
      ctx: _applied,
      value: value,
      hlc: hlc,
      timeSource: timeSource,
      machine: machine,
    );
    _applied = _applied.merge(edit.ctx).add(edit.dot);
    return edit;
  }
}

/// 旧协议写入者 [writerId] 的 HLC 来源：发出事件时取 max(可信时间, 已见过的最大 HLC)，从 [last] 接着走。
Hlc Function(int nowMs) legacyTicker(String writerId, {Hlc? last}) {
  Hlc cur = last ?? Hlc(0, 0, writerId);
  return (int nowMs) => cur = nowMs > cur.physical
      ? Hlc(nowMs, 0, writerId)
      : Hlc(cur.physical, cur.counter + 1, writerId);
}
