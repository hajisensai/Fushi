// 会话控制器把一个已连上的 TyranoScript DOM 会话发布给查词几何（attached surface 的
// 实测排版路线）用的只读面。
//
// 一个 feed 对应一次成功连接：断开 / 停源 / 换游戏时会话控制器关闭它并换成 null（或在
// 有限重连成功后换成新 feed）。消费者按对象身份判断「数据源换了」，所以 feed 不复用。

import 'dart:async';

import 'package:fushi/src/mining/tyrano_dom/tyrano_dom_frame.dart';

/// 一个已连上的 DOM 数据源的帧广播。
class TyranoDomFeed {
  /// 创建 feed。[port] / [gamePid] 只用于诊断。
  TyranoDomFeed({required this.port, this.gamePid});

  /// 游戏页面的 CDP 端口。
  final int port;

  /// 游戏进程 PID（launch 拿不到时为 null）。
  final int? gamePid;

  final StreamController<TyranoDomFrame> _frames =
      StreamController<TyranoDomFrame>.broadcast();
  TyranoDomFrame? _latest;

  /// 帧广播；feed 关闭时结束。
  Stream<TyranoDomFrame> get frames => _frames.stream;

  /// 最近一帧（重发 / 刚订阅时用）。
  TyranoDomFrame? get latest => _latest;

  /// feed 是否已关闭。
  bool get isClosed => _frames.isClosed;

  /// 发布一帧。
  void add(TyranoDomFrame frame) {
    if (_frames.isClosed) return;
    _latest = frame;
    _frames.add(frame);
  }

  /// 关闭 feed（订阅者收到 done）。
  Future<void> close() => _frames.close();
}
