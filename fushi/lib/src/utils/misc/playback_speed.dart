/// 播放倍速的统一范围与吸附规则：有声书倍速拖动条、galgame 台词 TTS 倍速、
/// TTS 兜底发音倍速共用这一份（0.25×–3.0×，0.05× 一档）。
library;

/// 倍速下限。
const double kPlaybackSpeedMin = 0.25;

/// 倍速上限。
const double kPlaybackSpeedMax = 3.0;

/// 吸附步长：0.05× 一档。
const double kPlaybackSpeedStep = 0.05;

/// 拖动吸附档数：(3.0 - 0.25) / 0.05 = 55 档。
const int kPlaybackSpeedDivisions = 55;

/// 吸附到 [kPlaybackSpeedStep] 一档并夹进 [kPlaybackSpeedMin]..[kPlaybackSpeedMax]
/// （键盘步进累加的浮点误差也在这里抹平）。乘 20 取整再除以 20（整数除法结果是
/// 最近的 double），不乘 0.05：0.05 不可精确表示，`23 * 0.05` 会得 1.1500000000000001。
double snapPlaybackSpeed(double value) =>
    ((value * _kStepsPerUnit).roundToDouble() / _kStepsPerUnit).clamp(
      kPlaybackSpeedMin,
      kPlaybackSpeedMax,
    );

/// 1 / [kPlaybackSpeedStep]。
const double _kStepsPerUnit = 20;
