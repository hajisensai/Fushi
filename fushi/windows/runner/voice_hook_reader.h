#ifndef RUNNER_VOICE_HOOK_READER_H_
#define RUNNER_VOICE_HOOK_READER_H_

#include <windows.h>

#include <cstdint>
#include <string>
#include <vector>

// galgame 一键制卡 C 阶段（docs/specs/galgame-mining）—— fushi.exe **读侧** native。
//
// 隔离红线：注入进游戏、装 XAudio2/DirectSound hook 的代码全在独立组件
// 独立仓库 hibiki-hook（injector + hook DLL），会被杀软报毒，**绝不进 fushi.exe**。
// 本 reader 只做一件被杀软视为无害的事：按名 [OpenFileMappingW] 打开那个组件建好的**共享内存**，
// 读环形缓冲里 hook 抓到的干净语音 PCM。它是 A 阶段 [AudioLoopbackCapture] 的引擎-hook 版对偶：
// 同样「开一路 → 需要时取最近 N 毫秒」，只是数据源从本进程 WASAPI 换成跨进程共享内存。
//
// 单读者、无锁：hook DLL 是唯一写者（单写 write_pos/total_written），host 只读，读到的量至多
// 滞后一个音频包，对「抓最近一句语音」无害（契约见 voice_hook_ipc.h）。
namespace fushi {

// 从共享内存 header 读出的语音格式 + 状态。[ok] 仅当映射有效、契约匹配、hook 已填格式时为 true。
struct VoiceHookStatus {
  int ipc_protocol_version = 0;
  int luna_bridge_abi_version = 0;
  int luna_vendored_version = 0;
  int sample_rate = 0;
  int channels = 0;
  int bits_per_sample = 0;
  bool is_float = false;
  bool hooked = false;       // hook DLL 是否已注入并安装钩子（proof-of-life）
  bool calibrating = false;  // 是否处于校准模式（识别 voice callsite 中）
  bool text_hooked = false;  // 文本 hook 是否已装（v2）
  bool audio_hooks_ready = false;  // 首轮音频导出 hook 探测是否已完成
  bool raw_voice_ready = false;  // 游戏资源逐句音频 hook 已就绪（可无 PCM 格式）
  bool ok = false;           // 映射有效且格式已就绪（音频格式已填）
  // v13 文本分道的两个容量事实。必须一路带到 UI/诊断：道用尽的症状（某些线程的台词
  // 就是不来）与 v13 要根治的 256 槽挤压完全同形，没有这两个数，真机上分不出
  // 「分道没生效」和「道不够用」。
  int64_t text_lane_recycles = 0;   // 回收过多少次最久未写的非选定道
  int64_t text_lane_overflows = 0;  // 连可回收的道都没有、只能丢弃的行数
};

// [VoiceHookReader::Open] 失败的**结构化原因**。
//
// 这四条出口（pid 非法 / OpenFileMapping 失败 / MapViewOfFile 失败 / 契约不匹配）旧实现
// 一律 `return VoiceHookStatus{}` 全零，上层只拿得到「打不开」一个比特，于是 UI 只能说
// 「捕获通道无法打开，请重启 Fushi」——而这几种原因的处置**完全不同**：
//   - 映射不存在：helper 没建好会话，重启 app 无用，要重开游戏；
//   - 拒绝访问：游戏跑在更高完整性级别（多为管理员权限启动），要以管理员运行 Fushi；
//   - 契约不匹配：helper 与本体版本不一致，重启多少次都不会好，必须更新/重装 helper。
// 原因是在 `return` 那一刻丢掉的，任何下游文案层补丁都救不回来（同 BUG-1142 的教训）。
enum class VoiceHookOpenError {
  kNone = 0,
  kInvalidPid,         // pid 为 0（调用方没有有效目标）
  kMappingNotFound,    // OpenFileMappingW ERROR_FILE_NOT_FOUND：helper 未建会话/pid 不符
  kAccessDenied,       // OpenFileMappingW ERROR_ACCESS_DENIED：目标完整性级别更高
  kMappingOpenFailed,  // OpenFileMappingW 其它 win32 失败
  kMapViewFailed,      // 映射打开了但 MapViewOfFile 失败
  kProtocolMismatch,   // 映射有效但契约五字段不符（helper 与本体版本漂开）
};

// [VoiceHookReader::Open] 的完整结局：状态 + 失败原因 + 一手事实。
//
// [detail] 是**纯事实**的 ASCII 摘要（win32 错误码 / 映射名 / 双方版本对照），不做任何解释，
// 供 Dart 侧原样附进用户可见诊断——「一次就能确诊」靠的是它，不是猜。
struct VoiceHookOpenResult {
  VoiceHookStatus status;
  VoiceHookOpenError error = VoiceHookOpenError::kNone;
  uint32_t win32_error = 0;
  std::string detail;

  bool ok() const { return error == VoiceHookOpenError::kNone; }
};

// [VoiceHookOpenError] → 机器可读 token（Dart 侧据此归类，跨语言契约的唯一名字）。
const char* VoiceHookOpenErrorToken(VoiceHookOpenError error);

// 一条 hook 文本事件（台词行或 Luna 线程发现，v10 文本环）。
struct VoiceHookText {
  uint64_t seq = 0;           // 单调序号
  uint64_t timestamp_ms = 0;  // hook 写入时刻（GetTickCount64）
  std::string utf8;           // UTF-8 文本
  uint64_t thread_id = 0;     // 会话内稳定 Hook 线程 id
  // hook「面」id（不含 ctx）。v13 把选定线程的过滤从采集期挪到消费期，消费方要按 hook 面
  // 放行（同一 hook 面换调用点 ctx 会变、thread_id 随之变，精确匹配会丢整段台词 —— BUG-1159），
  // 判据必须用 native 算好的这个值，不能在 Dart 侧照抄一遍哈希。
  uint64_t face_id = 0;
  uint64_t thread_address = 0;
  uint64_t thread_context = 0;
  uint64_t thread_context2 = 0;
  uint32_t process_id = 0;
  uint32_t source_kind = 0;
  uint32_t event_kind = 0;
  uint32_t event_flags = 0;
  std::string hook_name;
  std::string hook_code;
};

// 一条线程的预览快照（v12 线程预览区）。与 [VoiceHookText] 的关键差别：预览按 thread_id
// 寻址、每线程恒一条，**不受线程选择门控影响**——未被选中的线程也有预览，这正是选择器
// 能像 LunaTranslator 那样展示全部候选的来源。
struct VoiceHookThreadPreview {
  uint64_t thread_id = 0;
  uint64_t seq = 0;             // 该槽最近一次写入的全局序号
  uint64_t timestamp_ms = 0;
  uint64_t line_count = 0;      // 累计行数（含被过滤/门控丢弃的），跨会话记忆恢复的消歧依据
  uint64_t artifact_count = 0;  // 其中判为重复伪影的行数
  uint32_t event_flags = 0;     // bit0 = 最近这行是伪影
  std::string utf8;             // 预览文本
};

// 一条**活跃语音源**（source voice / DS buffer）的元数据快照（[ListAudioTracks] 产出）。游戏常有
// 多条并行流式源（BGM/语音/SE 各一条），本结构供 app UI 列「音轨列表」让用户手动选/排除语音源
// （自动能量选源可能误选 BGM，见 GrabUtterance）。所有量取自 ts_ms 附近环形窗口内该源的 clip。
struct VoiceTrackInfo {
  uint64_t source_ptr = 0;    // 源指针（会话内稳定；跨启动会变——UI 侧宜落创建顺序/格式签名）
  int sample_rate = 0;
  int channels = 0;
  int bits_per_sample = 0;
  bool is_float = false;
  uint64_t avg_bytes = 0;     // **环内**该源每段平均字节数（缓冲规模，代理该源是否持续流式）
  double avg_energy = 0.0;    // 文本时刻窗 [ts-150,ts+450] 平均能量（16-bit 平均绝对幅值；非 16-bit=-1）
  int order_index = 0;        // **环内**按首次出现（clip seq 升序）排的创建顺序，0-based
  int clip_count = 0;         // **环内**该源的总段数——注意不是「当前这句附近」，恒 >= 1
  // 文本时刻窗 [ts-150,ts+450] 内该源的段数。avg_energy 的 -1 有两义（窗内没段 /
  // 非 16-bit 算不了能量），拿它判「此刻这条轨响没响」会把非 16-bit 的可用轨也误判成
  // 静音；本字段与位深无关，是该判断的唯一正确依据（BUG-1165）。
  int clip_count_at_cue = 0;
};

// 单例：整个进程一路引擎-hook 读取。所有方法可从 UI 线程调用，绝不抛异常（全 HRESULT/句柄校验）。
class VoiceHookReader {
 public:
  static VoiceHookReader& Instance();

  // 按目标游戏 [pid] 打开 injector 建好的共享内存并校验契约（幂等：已打开同 pid 直接返回状态）。
  // 打开成功但 hook 尚未填格式时 status.ok=false、hooked 可能仍为 false（调用方轮询等 hooked/ok），
  // 此时 [VoiceHookOpenResult::error] 仍是 kNone——**「映射打开了」与「hook 就绪了」是两件事**。
  // 打不开时 error 说明是哪一种打不开，detail 带上 win32 码 / 映射名 / 双方版本对照。
  VoiceHookOpenResult Open(uint32_t pid);

  // 读当前 header 状态（格式/hooked/calibrating）。未打开返回 ok=false。
  VoiceHookStatus Status();

  // 把「最近 [back_ms] 毫秒」的语音 PCM 拷进 [out]（帧对齐，环形回绕处理）。缓冲不足则返回现有
  // 全部。未打开 / hook 未就绪 / 无数据时 [out] 清空、返回 ok=false。
  VoiceHookStatus GrabRecent(int back_ms, std::vector<uint8_t>& out);

  // 当前文本事件总数（text_write_count）；未打开返回 0。Dart 侧记住 last，取 (last, count]。
  uint64_t TextWriteCount();

  // 取序号在 (from_seq, text_write_count] 区间的文本事件（供 Dart 喂 texthooker/线程目录）。最多
  // 回最近 kTextSlotCount 个（更旧的已被覆盖）。未打开 / 无新事件时 [out] 空。
  void PollText(uint64_t from_seq, std::vector<VoiceHookText>& out);

  // 取全部已认领线程的预览快照（v12）。这是**全量快照**而非增量：预览槽按 thread_id 寻址、
  // 每线程恒一条，没有"漏读就丢"的问题，故不需要游标。返回 thread_preview_write_count 供
  // 调用方判断"有没有变"以跳过整区扫描；未打开 / 契约不匹配时 [out] 空并返回 0。
  uint64_t PollThreadPreviews(std::vector<VoiceHookThreadPreview>& out);

  // 选择 Luna 文本线程：0 = 清除选择（v12 起清除后文本环恒空，不再回到自动选择），
  // 非 0 写入共享 header 让 injector 只发布该线程。映射未打开或契约不匹配返回 false。
  bool SelectTextThread(uint64_t thread_id);

  // **按句取语音**：找时间戳与 [ts_ms] 最近（且差 <= [tolerance_ms]）的语音 clip，把它那段 PCM
  // 从音频环形拷进 [out]（clip 已被环形覆盖则跳过）。找不到则 [out] 空、返回 ok=false。
  // 这是「该句的语音」自动选取——替代手动波形选区。
  //   - [target_source] 非 0：只考虑该源的 clip（用户手动选定的语音轨）。
  //   - [exclude_sources]：这些源的 clip 一律跳过（用户标记的 BGM）。本方法是
  //     [GrabUtterance] 的兜底，兜底若不认排除集，用户排除的 BGM 会从这里绕回制卡
  //     ——两个入口必须遵守同一份选轨/排除契约。
  VoiceHookStatus GrabClipNear(uint64_t ts_ms, uint64_t tolerance_ms,
                               uint64_t target_source,
                               const std::vector<uint64_t>& exclude_sources,
                               std::vector<uint8_t>& out);

  // **按句取「整句」语音**（[GrabClipNear] 的整句版，替代 ~125ms 碎片）：游戏多条 source voice
  // 并行流式，一次 SubmitSourceBuffer 只 ~60-136ms。本方法把同一 [source_ptr] 源在 [ts_ms-200,
  // ts_ms+6000] 的所有段逐段从环形拼接、去首尾静音，产出整句 PCM 到 [out]。
  //   - [target_source] 非 0：**直接用该源**（用户手动选定的语音轨），跳过能量自动选源。
  //   - [target_source] 为 0：按能量自动选语音源（说话前静音、文本时刻突然有能量者），并排除
  //     [exclude_sources] 里的源（用户标记的 BGM）。自动选源在真机上可能误选 BGM，故提供手动。
  // 找不到语音源 / 段全被环形覆盖 / 无数据则 [out] 空、返回 ok=false（调用方回退 GrabClipNear）。
  // 算法真相源：独立仓库 hibiki-hook 的 `tools/ring_probe.cpp` 的 DumpUtterance（已真机验证）。
  //
  // [end_ts_ms] 非 0 时把窗口右界收到 `min(ts_ms + 6000, end_ts_ms)`（BUG-1475）：
  // 收敛因「下一句到达」而收手时要补最后一次 grab，把已进环但还没被读走的那
  // ≤250ms 拿回来；但**绝不能**因此把下一句的段拼进上一句——那正是 BUG-1109
  // 当初刻意用「下一句到达即封口」防住的东西。上界由调用方传下一句的时间戳。
  VoiceHookStatus GrabUtterance(uint64_t ts_ms, uint64_t target_source,
                                const std::vector<uint64_t>& exclude_sources,
                                std::vector<uint8_t>& out,
                                uint64_t end_ts_ms = 0);

  // 枚举 [ts_ms] 附近环形窗口内的**活跃语音源**及其元数据（格式/平均缓冲/近窗平均能量/创建顺序），
  // 供 app UI 显示「音轨列表」让用户手动选/排除语音源（[GrabUtterance] 的 target/exclude）。
  // 未打开 / 无 clip 时 [out] 空。
  void ListAudioTracks(uint64_t ts_ms, std::vector<VoiceTrackInfo>& out);

  // 解除映射、释放句柄。幂等。不杀 injector 子进程（那由 Dart 侧管理）。
  void Close();

 private:
  VoiceHookReader() = default;
  ~VoiceHookReader();
  VoiceHookReader(const VoiceHookReader&) = delete;
  VoiceHookReader& operator=(const VoiceHookReader&) = delete;
};

}  // namespace fushi

#endif  // RUNNER_VOICE_HOOK_READER_H_
