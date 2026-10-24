/// 编进 fushi_compute 原生库、但实现与 Dart 绑定都在上游的 C 符号。
///
/// 有声书转录 cue 后处理（能量吸附 / 修边 / 句内碎片合并 / 跟读显示余量）归上游
/// hajisensai/fushi-subtitles 的 `native/asr_cue_post`（crate `fushi_asr_cue_post`），由
/// `native/fushi_compute/Cargo.toml` 当依赖编进本库；绑定是 `fushi_asr_subtitles` 的
/// `AsrCuePostProcessor`，宿主经 `AsrCuePostLibrary.fromDynamicLibrary` 把本库交给它。
///
/// `native/fushi_compute/verify_abi.sh` 从这里抓期望符号集（产物必须导出它们）；
/// fushi_engine 的测试核对本清单与上游的 `kAsrCuePostSymbols` 一致。
const List<String> kFushiComputeLinkedCuePostSymbols = <String>[
  'fcp_abi_version',
  'fcp_cue_post_process',
];
