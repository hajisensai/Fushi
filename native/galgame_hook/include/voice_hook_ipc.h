#ifndef FUSHI_VOICE_HOOK_IPC_H_
#define FUSHI_VOICE_HOOK_IPC_H_

#include <windows.h>

#include <cstdint>
#include <string>

#include "luna_version.h"
#include "thread_preview_ipc.h"

// galgame 一键制卡 C 阶段（docs/specs/galgame-mining）—— 引擎级 voice hook 的**进程间契约**。
//
// 部署红线：这套 injector + hook DLL 是**独立可选 helper 组件**，和 `hibiki.exe` 物理隔离、
// 分离分发（`CreateRemoteThread`/`WriteProcessMemory` 注入必被杀软启发式报毒，编进本体会污
// 染整个 app 的分发口碑）。Hibiki 主进程把 injector 当子进程拉起、通过下面这块共享内存消费
// 干净语音 PCM——被标记的注入代码只待在这个隔离组件里。
//
// 数据流（混音前的干净语音轨）：
//   game.exe 内的 hook DLL：在 XAudio2/DirectSound 把语音送进混音**之前** memcpy 进环形缓冲
//     → 只在音频回调里 memcpy + 更新 write_pos（零阻塞：写盘/编码/IPC 全部移出回调，爆音红线）
//   共享内存：header + 紧随其后的 PCM 环形缓冲
//   Hibiki host（经 injector）：读环形缓冲最近 N 毫秒 → 波形选区 → 制卡出口（复用 A 阶段流水线）
namespace fushi_voice_hook {

// 共享内存魔数 'HVH1'（小端）与当前契约版本。跨进程读到不匹配即拒绝，防旧/坏映射。
constexpr uint32_t kSharedMagic = 0x31485648;  // 'H''V''H''1'
// v2：在 v1 音频环形之外加「文本环」(hook 抓的台词行) + 「语音 clip 索引」(按句切的语音片段)。
// 全自动制卡：文本 hook 出一句 + voice hook 出对应那条语音 clip → 按时间戳配对 → 点+一键出卡。
// v6：在 clip 索引之后再加「loopback 混音环」+「时间戳↔环位置标记表」。作为没有引擎专属纯人声
//     hook 的游戏（Atelier Kaguya、未识别引擎等）的**兜底**——WASAPI loopback 抓系统渲染端点的
//     最终混音（voice+BGM），按文本时刻抽窗口做卡。与引擎级纯人声路径并存，互不干扰。
// v9：合并 v8 的引擎诊断/Unity 资源事件与 v6 的 loopback 环。
// v10：文本槽追加事件类型，透传 Luna ThreadCreate，使尚无台词的候选线程也可被选择。
// v11：显式声明稳定 IPC、Luna bridge ABI 与 vendored Luna 版本，host 可在读数据前拒绝错配。
// v12：追加「线程预览区」，并取消 injector 自动替用户选线程。
//     旧结构里文本环是**唯一**的文本出口，同时伺候两个诉求相反的消费者：语音配对要高信噪的
//     单条线程，线程选择器要每条线程都有样本。二者共用一块 256 槽全局 FIFO，于是"让所有 hook
//     都发布"必然把配对候选挤出环（kExpired → 降级 loopback，即 BUG-1159 的失败链），这才是
//     BUG-1193 真正的根因——不是门控本身。v12 把两个消费者拆到两块内存：
//       * 文本环（Ring A）：语义不变，仍只发布**当前生效线程**的行，配对路径逐字节不受影响；
//       * 线程预览区（本区）：每条线程各占**固定槽位**，只留最近一行。Luna 与游戏内
//         native adapter 使用互斥槽分区，跨进程 writer 不会争抢同一槽。
//     预览区按线程分槽而不是全局 FIFO，所以逐字重绘型 hook 只能覆盖它自己的槽，**物理上挤不掉
//     别的线程**——"挤压"从"要小心防"变成结构上不可能，这正是自动赢家门控得以退役的前提。
// v13：文本区从**一块 256 槽全局 FIFO**改成**按线程分道**，并取消采集期的选定线程过滤。
//     v12 只把"线程选择器"这个消费者搬进了按线程分槽的预览区；文本环本身仍是全局 FIFO，
//     它当时不被挤爆，只是因为**同一时刻只有一条线程在写**（未选定就一行都不发），不是
//     结构上挤不动。所以"放开非胜出线程"在 v12 上依然会复现 BUG-1159 的失败链：逐字重绘型
//     hook 几秒刷穿 256 槽 → 配对候选被挤出环 → kExpired → 整段降级 system_loopback。
//     v13 让每条线程写**自己那条道**，道内覆盖只吃掉自己的旧行，物理上挤不掉别人：
//       * 道下标与线程预览槽下标**取同一个值**，认领沿用预览区那套跨进程互斥分区
//         （Luna 在 injector 进程用低段，游戏内 native adapter 用高段），认领逻辑只有一份；
//       * TextSlot::seq 仍是**全局发布序**（host `pollText(fromSeq)` 契约逐字节不变），
//         新增 lane_seq 作道内完成标记；
//       * selected_text_thread_id 从"采集期过滤器"降级为"消费期指定"：native 不再丢弃任何
//         行，只由消费方（host 的文本消费点、游戏内 kirikiri 配对候选扫描）决定取哪条道。
//         这同时解开了旧方案的死结——Dart 回写选定线程不再等于让 native 重新开始丢行。
// v14：追加**游戏内查词区**（hit / input / frame 三通道，见下方 kLookup* 与 LookupHitSlot）。
//     纯追加：放在布局最尾，前面所有区偏移逐字节不动；lookup_region_offset==0 即"本会话
//     没有此区"，旧 host 读到 v14 映射也不会错位（版本号仍会先挡，这只是纵深防御）。
constexpr uint32_t kSharedVersion = 14;
constexpr uint32_t kStableIpcVersion = 1;

// 环形缓冲保留时长（秒）。C 阶段语音轨常见 48k 立体声 float32；60s 上界 ≈ 23MB。
// 32 位游戏地址空间有限，共享内存映射进游戏进程也吃它的地址空间——故设硬上界。
constexpr uint32_t kRingSeconds = 60;
constexpr uint32_t kMaxRingBytes = 64u * 1024u * 1024u;  // ≤64MB（spec C 阶段预算）

// 文本事件区（v13 按线程分道）：kTextLaneCount 条道，每道 kTextLaneSlotCount 个槽循环覆盖。
// 每槽固定 kTextSlotBytes 字节（TextSlot 头 + 紧跟的文本字节）。v6 保留 Luna ThreadParam /
// hook 名称与 hookcode；v10 再透传 Luna ThreadCreate，使尚无已发布台词的 TextRender 等线程
// 也能先出现在选择器里。
//
// kTextSlotCount 保留为**总槽数**（供整区尺寸计算与 host 的"最多能回溯多少条"上界），语义从
// "全局 FIFO 长度"变成"所有道加起来的容量"——它不再参与寻址，寻址一律走 TextLaneSlotAt。
constexpr uint32_t kTextLaneSlotCount = 8;
constexpr uint32_t kTextLaneCount = kThreadPreviewCount;  // 与预览槽同下标同分区
constexpr uint32_t kTextSlotCount = kTextLaneCount * kTextLaneSlotCount;
constexpr uint32_t kTextSlotBytes = 2048;
constexpr uint32_t kTextHookNameChars = 64;
constexpr uint32_t kTextHookCodeChars = 128;
constexpr uint32_t kTextSourceUnknown = 0;
constexpr uint32_t kTextSourceGdi = 1;
constexpr uint32_t kTextSourceLuna = 2;
constexpr uint32_t kTextSourceUnityTmp = 3;
constexpr uint32_t kTextSourceSiglus = 4;
constexpr uint32_t kTextEventLine = 0;
constexpr uint32_t kTextEventThreadDiscovered = 1;

// 语音 clip 索引：最近 kClipCount 条语音片段的位置记录（按 source voice / DirectSound buffer
// 的一次提交切一条；galgame 一句台词≈一条语音）。指向音频环形里的 [ring_offset, byte_len)。
constexpr uint32_t kClipCount = 1024;  // clip 索引环：128≈仅2秒历史不够重建整句语音，扩到 ~16秒

// hook DLL 完成首次 XAudio2/DirectSound 导出 hook 安装后置位。launch 模式在恢复游戏主线程
// 前等待此位，避免游戏抢先创建音频引擎导致整局都没有可配对的 source voice。
constexpr uint32_t kDiagStartupAudioHooksReady = 0x00000001u;
constexpr uint32_t kDiagUnityIl2CppHooksReady = 0x00000002u;
constexpr uint32_t kDiagUnityIl2CppClipCaptured = 0x00000004u;
constexpr uint32_t kDiagUnityIl2CppPlaybackObserved = 0x00000008u;
constexpr uint32_t kDiagUnityIl2CppGetDataRejected = 0x00000010u;
constexpr uint32_t kDiagUnityResourceExtractorReady = 0x00000020u;
constexpr uint32_t kDiagUnityResourceExtracted = 0x00000040u;
constexpr uint32_t kDiagUnityResourceExtractFailed = 0x00000080u;
constexpr uint32_t kDiagUnityTmpTextHooksReady = 0x00000100u;
constexpr uint32_t kDiagUnityNaninovelTextHookReady = 0x00000200u;
constexpr uint32_t kDiagLunaHostReady = 0x00000400u;
constexpr uint32_t kDiagLunaConnected = 0x00000800u;
constexpr uint32_t kDiagLunaOutputObserved = 0x00001000u;
constexpr uint32_t kDiagLunaInjectFailed = 0x00002000u;
constexpr uint32_t kDiagSiglusExactTextHookReady = 0x00004000u;
constexpr uint32_t kDiagSiglusExactTextObserved = 0x00008000u;
constexpr uint32_t kDiagFfmpegResourceHooksReady = 0x00010000u;
constexpr uint32_t kDiagFfmpegResourceCaptured = 0x00020000u;
constexpr uint32_t kDiagVisualArtsOvkHooksReady = 0x00040000u;
constexpr uint32_t kDiagVisualArtsOvkCaptured = 0x00080000u;
constexpr uint32_t kDiagKirikiriVorbisOpenHookReady = 0x00100000u;
constexpr uint32_t kDiagFfmpegVoiceResourceObserved = 0x00200000u;
constexpr uint32_t kDiagTyranoAsarHooksReady = 0x00400000u;
constexpr uint32_t kDiagTyranoAsarVoiceCaptured = 0x00800000u;
constexpr uint32_t kDiagBgiArcHooksReady = 0x01000000u;
constexpr uint32_t kDiagBgiArcVoiceCaptured = 0x02000000u;
constexpr uint32_t kDiagArtemisPfsHooksReady = 0x04000000u;
constexpr uint32_t kDiagArtemisPfsVoiceCaptured = 0x08000000u;
constexpr uint32_t kDiagCatSystem2PcmHooksReady = 0x10000000u;
constexpr uint32_t kDiagCatSystem2PcmVoiceCaptured = 0x20000000u;
constexpr uint32_t kDiagMalieLibpHooksReady = 0x40000000u;
constexpr uint32_t kDiagMalieLibpVoiceCaptured = 0x80000000u;

// reserved_hook_diagnostics is a secondary engine-I/O trace word. Malie uses
// it to distinguish handle discovery, async reads, and mapped views without
// consuming the saturated primary hook_diagnostics bitset.
constexpr uint32_t kDiagMalieArchiveHandleTracked = 0x00000001u;
constexpr uint32_t kDiagMalieReadRangeObserved = 0x00000002u;
constexpr uint32_t kDiagMalieMappingTracked = 0x00000004u;
constexpr uint32_t kDiagMalieMappedRangeObserved = 0x00000008u;
constexpr uint32_t kDiagMalieVoiceRangeQueued = 0x00000010u;
constexpr uint32_t kDiagQlieVorbisHooksReady = 0x00000020u;
constexpr uint32_t kDiagQlieVorbisOpenObserved = 0x00000040u;
constexpr uint32_t kDiagQlieVorbisPcmCaptured = 0x00000080u;
constexpr uint32_t kDiagQlieVorbisFloatHookReady = 0x00000100u;
constexpr uint32_t kDiagQlieVorbisFloatPcmCaptured = 0x00000200u;
constexpr uint32_t kDiagUnityTextScanReady = 0x00000400u;
constexpr uint32_t kDiagUnityUiTextClassFound = 0x00000800u;
constexpr uint32_t kDiagUnityUiTextMethodFound = 0x00001000u;
constexpr uint32_t kDiagUnityUiTextHookReady = 0x00002000u;
constexpr uint32_t kDiagUnityTextMeshClassFound = 0x00004000u;
constexpr uint32_t kDiagUnityTextMeshMethodFound = 0x00008000u;
constexpr uint32_t kDiagUnityTextMeshHookReady = 0x00010000u;
constexpr uint32_t kDiagUnityAudioClassFound = 0x00020000u;
constexpr uint32_t kDiagUnityAudioResourceMethodsFound = 0x00040000u;
constexpr uint32_t kDiagUnityAudioPcmMethodsFound = 0x00080000u;
constexpr uint32_t kDiagUnityAudioPlaybackMethodFound = 0x00100000u;
constexpr uint32_t kDiagUnityAudioPlaybackHookReady = 0x00200000u;
constexpr uint32_t kDiagUnityHooksDeferredUntilWindow = 0x00400000u;
constexpr uint32_t kDiagElfAi6ArcHooksReady = 0x00800000u;
constexpr uint32_t kDiagElfAi6ArcVoiceCaptured = 0x01000000u;
constexpr uint32_t kDiagElfAi6ArcHandleTracked = 0x02000000u;
constexpr uint32_t kDiagElfAi6ArcReadObserved = 0x04000000u;
constexpr uint32_t kDiagElfAi6ArcOggObserved = 0x08000000u;
constexpr uint32_t kDiagElfAi6ArcVoiceQueued = 0x10000000u;
constexpr uint32_t kDiagElfAi6ArcTaskRejected = 0x20000000u;

// reserved_luna 的资源音频诊断位。KiriKiriZ 的 TVPCreateStream hook 直接导出当前播放的
// 已解密 Ogg；Siglus 从 OVK 索引导出逐句 Ogg。它们只代表“资源捕获链已安装”，不要求 PCM
// 环已有格式，因此 host 应优先按时间戳配对资源文件，并把系统回环保留为逐句 fallback。
constexpr uint32_t kDiagKirikiriVoiceStreamHookReady = 0x00020000u;
constexpr uint32_t kDiagKirikiriVoiceStreamDumped = 0x00080000u;
constexpr uint32_t kDiagSiglusOvkHooksReady = 0x10000000u;

inline constexpr bool HasReadyGameResourceAudio(uint32_t reserved_luna,
                                                uint32_t hook_diagnostics,
                                                uint32_t reserved_hook_diagnostics = 0) {
  const uint32_t unity_required = kDiagUnityIl2CppHooksReady |
                                  kDiagUnityResourceExtractorReady;
  const bool unity_ready =
      (hook_diagnostics & unity_required) == unity_required;
  return (reserved_luna & kDiagKirikiriVoiceStreamHookReady) != 0 ||
         (reserved_luna & kDiagSiglusOvkHooksReady) != 0 ||
         (hook_diagnostics & kDiagFfmpegResourceHooksReady) != 0 ||
         (hook_diagnostics & kDiagTyranoAsarHooksReady) != 0 ||
         (hook_diagnostics & kDiagBgiArcHooksReady) != 0 ||
         (hook_diagnostics & kDiagArtemisPfsHooksReady) != 0 ||
         (hook_diagnostics & kDiagCatSystem2PcmHooksReady) != 0 ||
         (hook_diagnostics & kDiagMalieLibpHooksReady) != 0 ||
         (hook_diagnostics & kDiagVisualArtsOvkHooksReady) != 0 ||
         (reserved_hook_diagnostics & kDiagElfAi6ArcHooksReady) != 0 ||
         unity_ready;
}

// Unity Streaming AudioClip 不能用 AudioClip.GetData 读取。DLL 在 Play/set_clip 时只写一个
// 轻量资源事件（clip 名 + 最近打开的 voice bundle）；injector 宿主进程再解析 AssetBundle 并
// 用 vgmstream 解码，所有磁盘/解码工作都留在游戏进程之外。
constexpr uint32_t kUnityVoiceEventCount = 16;
constexpr uint32_t kUnityClipNameChars = 128;
constexpr uint32_t kUnityBundlePathChars = 520;
// ── v6 loopback 兜底混音捕获 ─────────────────────────────────────────────────
// loopback 环时长（秒）。injector 在**注入前**分配映射，此刻还拿不到真实混音格式，故按名义
// 立体声 16-bit 存储格式（48k*2ch*2B）预留固定字节；实际混音若是 5.1/7.1，同容量下只是历史
// 时长变短（例 6ch → ~20s），仍够 [ts-100ms, ts+5000ms] 抽窗。混音端 32-bit float 在 hook 侧
// 转成 16-bit PCM 再入环，故按 16-bit 名义容量算字节（同时压低 32 位游戏地址空间占用）。
constexpr uint32_t kLoopbackSeconds = 60;
constexpr uint32_t kMaxLoopbackBytes = 16u * 1024u * 1024u;  // ≤16MB（32 位地址空间预算）
// 时间戳↔环位置标记表槽数。loopback 线程每 ~200ms 记一条 {tick, total}；60s → 300 条，512 留余。
constexpr uint32_t kLoopbackMarkerCount = 512;

// 文本事件槽：lane_seq==该道 TextLane::write_count 对应值时该槽有效（v13 起道内校验，不再拿
// 全局序号取模）；event_kind==kTextEventLine 时，文本紧跟本头之后（kTextSlotBytes-头长）；
// 线程发现事件的 byte_len 为 0、只携带线程元数据。
#pragma pack(push, 8)
struct TextSlot {
  volatile uint64_t seq;    // 全局发布序（host 的 pollText 游标就是它；0=空）
  uint64_t timestamp_ms;    // GetTickCount64() 写入时刻（与语音 clip 配对用）
  uint32_t byte_len;        // 文本有效字节数（<= kTextSlotBytes - sizeof(TextSlot)）
  uint32_t is_utf8;         // 1=UTF-8，0=UTF-16LE
  uint64_t thread_id;       // 会话内稳定的 Hook 线程 id（0=不可区分）
  uint64_t thread_address;  // Luna ThreadParam.addr
  uint64_t thread_context;  // Luna ThreadParam.ctx
  uint64_t thread_context2; // Luna ThreadParam.ctx2
  uint32_t process_id;      // Luna ThreadParam.processId / GDI 当前进程
  uint32_t source_kind;     // kTextSource*；决定 UI 标签
  uint32_t hook_name_len;   // hook_name 有效字节数（不含结尾 0）
  uint32_t hook_code_len;   // hook_code 有效 wchar 数（不含结尾 0）
  uint32_t event_kind;      // kTextEvent*；0 保持旧写者默认语义为台词行
  uint32_t event_flags;     // 预留（当前线程发现事件写 Luna embedable 到 bit 0）
  // hook「面」id（不含 ctx，见 luna_text_selector.h 的 LunaTextFaceIdFrom）。
  //
  // v13 把选定线程的过滤从采集期挪到消费期，这个字段是**挪过去还能等价**的前提：旧的
  // native 过滤按 hook 面放行（同一 hook 面换调用点 ctx 会变、thread_id 随之变，精确匹配
  // 会把整段台词丢掉——BUG-1159）。消费方只有拿到同一个 face id，才能复刻同样的放行判据，
  // 而不是在 Dart 里照抄一遍 FNV 哈希（那又是一个漂移源）。0 = 写者无法提供。
  uint64_t face_id;
  // 道内序号，兼**完成标记**：==该道 write_count 快照即有效，**最后**写。
  //
  // 必须 volatile 且必须用 AtomicStorePreview64 发布（与预览槽 seq、VoiceClip::seq、
  // LoopbackMarker::seq 同一套纪律）：它是跨进程可见性的分界线。普通写有两个真实风险——
  // 编译器可以把它提到 payload 之前（reader 就会读到半写槽），x86 上 64 位普通写还可能被
  // 拆成两次 32 位写而撕裂。Interlocked 系是全栅栏且不可撕裂，一次解决两个。
  volatile uint64_t lane_seq;
  char hook_name[kTextHookNameChars];
  wchar_t hook_code[kTextHookCodeChars];
  // 紧跟文本字节。
};

// v13 文本道表头：每条线程一条道，位于文本区最前面，槽区紧随其后。
//
// 认领纪律与线程预览槽**完全一致**（下标同一套）：writer 先由进程内锁串行化，再按 thread_id
// 线性查找/认领；Luna（injector 进程）与游戏内 native adapter 使用互斥的下标区段，跨进程
// writer 因此不会争抢同一条道——进程内 CRITICAL_SECTION 串不住另一个进程，这是 v12 已经踩过
// 的坑，v13 不重新发明。
struct TextLane {
  volatile uint64_t thread_id;    // 0=空道（回收后允许出现空洞，查找必须扫完整张表）
  volatile uint64_t write_count;  // 道内单调写入数（reader 据此定位有效槽区间）
  // 最近一次写入时刻（GetTickCount64）。道用尽时按它挑最久没动的**非选定**道回收——
  // 见 WriteTextLaneEvent 的道满处置。
  volatile uint64_t last_write_ms;
};

// 语音 clip 记录：一段独立语音片段在音频环形里的位置 + 时刻 + 格式。host 按文本时间戳找最近
// clip，再从音频环形 [ring_offset, ring_offset+byte_len) 取 PCM（若已被环形覆盖则 total_at_write
// 与当前 total_written 差值 > ring_capacity，host 判为过期）。
struct VoiceClip {
  volatile uint64_t seq;      // 写入序号（0=空）
  uint64_t timestamp_ms;      // 该 clip 播放时刻
  uint64_t total_at_write;    // 写该 clip 尾时的 total_written（判是否已被环形覆盖）
  uint32_t ring_offset;       // 在音频环形里的起始偏移
  uint32_t byte_len;          // clip 字节数
  uint32_t sample_rate;
  uint32_t channels;
  uint32_t bits_per_sample;
  uint32_t is_float;
  uint32_t pad;               // 8 对齐
  uint64_t source_ptr;        // 该段所属 source voice / DS buffer 指针：区分语音源 vs BGM 源，
                              // 供 host 把同一源的连续段合成整句语音（而非只取一个 buffer 片段）
};

struct UnityVoiceEvent {
  volatile uint64_t seq;   // 全局序号，最后写；0=槽尚未完成
  uint64_t timestamp_ms;   // AudioSource 播放/绑定该 AudioClip 的 GetTickCount64
  wchar_t clip_name[kUnityClipNameChars];
  wchar_t bundle_path[kUnityBundlePathChars];
};

// loopback 时间戳↔环位置标记：loopback 线程每 ~200ms 写一条，记该时刻的墙钟 tick 与 loopback 环
// 已写字节 total。host/工具按文本时间戳（同为 GetTickCount64）在标记表里插值反查环内字节位置，
// 抽 [ts_start, ts_end] 窗口。单写者（仅 loopback 线程写），seq 作半写完成标记（reader 校验
// seq==loopback_marker_count 快照即有效），与 VoiceClip 同款纪律。
struct LoopbackMarker {
  volatile uint64_t seq;    // 写入序号（0=空；等于 loopback_marker_count 快照即有效），**最后**写
  uint64_t tick_ms;         // GetTickCount64() 记录时刻
  uint64_t total_written;   // 该时刻的 loopback_total_written（单调）
};

// ══ v14 游戏内查词区 ════════════════════════════════════════════════════
// KiriKiri/KAGEX 在**游戏渲染树内部**显示词典卡片。注入侧只做几何传感、
// 位图落地和输入转发；分词、查词、排版、卡片像素全部由 host（Hibiki 既有
// popup.html + WebView2 离屏合成）负责。跨进程边界上因此只有一块位图和一串整数。
//
// 三条通道各自单写单读，无锁：
//   hit   : hook → host，单槽 latest-wins，仅发布 submit；hover 在游戏线程即时高亮
//   input : hook → host，环（落在卡片矩形内的鼠标/滚轮事件，供 host 喂 SendMouseInput）
//   frame : host → hook，双缓冲（避免 host 写下一帧时撕裂 hook 正在拷的这一帧）
//
// **像素格式：BGRA8，直通（非预乘）alpha，自顶向下。** 两端都按直通最省事——host 侧
// WebView2 取帧经 PNG 解码出来的本来就是直通；注入侧 KiriKiri 的 ltAlpha 也正是直通
// （预乘对应的是 ltAddAlpha）。任何一侧擅自改成预乘，症状是卡片半透明边缘发暗，不会
// 报错，只会看起来"有点脏"——所以在这里写死，别靠两边默契。
constexpr uint32_t kLookupLineBytes = 1024;      // 单行台词 UTF-8 上限（整行，不截断）
constexpr uint32_t kLookupInputSlotCount = 64;   // 输入转发环槽数
constexpr uint32_t kLookupFrameCount = 2;        // 位图双缓冲
// 单缓冲位图上限 3MiB ≈ 880×880 BGRA。x86 游戏进程地址空间有限，故设硬上界；超限由
// host 负责钳制卡片尺寸，注入侧只做校验和拒绝，绝不按收到的 width/height 盲拷。
// 单张卡片位图的字节预算（双缓冲，共享内存占 2 倍）。
//
// 超预算时 runner 只能**裁**（DecodePngStreamToStraightBgra 直接改小 width/height
// 按左上角取块），不是缩——也就是说预算定小了，用户看到的是被切掉半张的卡片。
// 原来的 3 MiB 只够 786432 像素，1920x1440 视口下取 0.6 就已经逼近；抬到 8 MiB
// 后可容 2097152 像素（约 1600x1200 / 1920x1092），正常卡片不可能撞到。
//
// 抬这个数**不需要升 kSharedVersion**：区域寻址、IsLookupFrameSane、runner 的预算
// 校验一律读 header->lookup_bitmap_bytes，没有一处硬用本常量。旧 helper 建的段就
// 报 3 MiB，host 照它办，两侧仍自洽。代价只是共享内存多 10 MiB。
constexpr uint32_t kLookupBitmapBytes = 8u * 1024u * 1024u;

// lookup_diag 位。与 reserved_luna / hook_diagnostics 分开：那两个各自已满，且这里的
// 阶段语义（传感器装没装 / 像素走哪条路）与引擎探针、helper 启动都不是一回事。
constexpr uint32_t kLookupDiagSensorInstalled = 0x00000001u;  // TJS 传感器已装
constexpr uint32_t kLookupDiagGeometryObserved = 0x00000002u;  // 真拿到过逐字符几何
constexpr uint32_t kLookupDiagHitSubmitted = 0x00000004u;     // 真上报过命中
constexpr uint32_t kLookupDiagBufferRouteReady = 0x00000008u;  // mainImageBufferForWrite 可用
constexpr uint32_t kLookupDiagFallbackPngRoute = 0x00000010u;  // 降级走 PNG + loadImages
constexpr uint32_t kLookupDiagFramePresented = 0x00000020u;   // 位图真落进游戏 Layer
constexpr uint32_t kLookupDiagExpressionReady = 0x00000040u;  // TVPExecuteExpression 可用
constexpr uint32_t kLookupDiagFrameRejected = 0x00000080u;    // 收到过不合契约的帧（已拒）
// 传感器在游戏事件循环里吞下过异常（TJS 侧 fushiLookupFaults > 0）。
//
// 注入进别人的事件循环，异常就绝不允许逃逸——逃出去 KiriKiri 会弹「致命的なエラー」
// 把玩家这一局打断。但"不逃逸"必须与"看得见"成对出现：只 catch 不计数，查词会安静地
// 半死不活（命中报不上来、卡片不出现），而现场没有任何痕迹可查。这一位就是那道痕迹。
constexpr uint32_t kLookupDiagSensorFault = 0x00000100u;
// ── hover 未命中的原因（真机排查用；采集成功但点不中时唯一能分型的依据）──────
//
// 「采到了几何」和「点得中」之间隔着坐标系换算、图层可见性、逐字形命中三道，任何
// 一道断了，用户看到的都是同一句「点了没反应」。没有这几位就只能靠改一版试一版。
constexpr uint32_t kLookupDiagHoverBoxMiss = 0x00000200u;   // 光标不在整行包围盒内
constexpr uint32_t kLookupDiagHoverGlyphMiss = 0x00000400u; // 在包围盒内但无字形命中
constexpr uint32_t kLookupDiagHoverHidden = 0x00000800u;    // 命中但可见性判定否决
// 绘制原点在一次采集周期内被绑定多次 = drawCh 的 ox/oy 是**逐字符**位置，不是整行
// 原点。**这是引擎事实的记录位，不是错误位**：本样本（textrender.dll）实测每字一次，
// 采集侧据此改为「用 min(ox) 与 min(字形 x) 配对解平移量」，而不是把最后一个字的落
// 点当行原点（那正是第一版 HoverBoxMiss 的成因）。留着它是为了换引擎时一眼看出该
// 引擎属于哪一类。
constexpr uint32_t kLookupDiagOriginPerChar = 0x00001000u;
// 文字的绘制目标层不在 primaryLayer 的父链上（独立/离屏层），沿父链累加得到的偏移
// 因此没有意义。
constexpr uint32_t kLookupDiagLayerDetached = 0x00002000u;
// ── 投帧失败分型（真机上"卡片就是不出现"的唯一分辨依据）────────────────────
//
// 之前 FramePresented 在降级路上是**无条件置位**的：只证明"我让 TJS 去加载 PNG 了"，
// 不证明卡片显示了。而那条降级路要求有人把卡片写成 PNG 落盘——实测**没有任何一处
// 写过那个文件**，于是 loadImages 必然失败、被 TJS 的 catch 吞掉，所有诊断却都报成功。
// 诊断位声称的比它知道的多，是最难查的一类缺陷，这几位专门用来消除它。
constexpr uint32_t kLookupDiagCardLayerMissing = 0x00004000u;   // 卡片层建不出来
constexpr uint32_t kLookupDiagWriteBufferNull = 0x00008000u;    // 层在，但拿不到写指针
constexpr uint32_t kLookupDiagFallbackPngMissing = 0x00010000u; // 降级路的 PNG 文件不存在
// 卡片层退回了普通 Layer（自定义子类建不出来）。卡片能显示，但卡片内的鼠标事件
// 转发失效——降级发生了就要看得见，不许悄悄发生。
constexpr uint32_t kLookupDiagCardPlainFallback = 0x00020000u;
// hook → host：用户真正提交查词时命中了哪个字符。hover 由游戏线程即时画高亮，不写这个
// 单槽，避免后到 hover 覆盖尚未被 host 消费的 submit。写侧先把 `seq` 清 0，再写 payload，
// 最后用 Interlocked 发布新 `seq`，与 VoiceClip / LoopbackMarker 同一套纪律。
struct LookupHitSlot {
  volatile uint64_t seq;   // 单调；host 据此判新。0=从未命中
  // 光标落在第几个字符。**单位是 UTF-16 code unit**，不是 UTF-8 字节、不是 code point。
  //
  // 为什么是这个单位而不是随便挑一个：两端天然就都是 UTF-16——TJS 的 tjs_char 是 wchar_t
  // （UTF-16LE），Dart 的 String 下标也是 UTF-16 code unit。选它，两侧各自「就是自己的字符串
  // 下标」，零转换；选 UTF-8 字节或 code point，两端都要转，而转错的症状是**含非 ASCII 或
  // 非 BMP 字符的行整体偏移**——日文行必然含非 ASCII，也就是必错，但错得像"命中判定有点飘"
  // 而不像编码 bug，极难定位。line_utf8 用 UTF-8 只是因为它要跨 C ABI，不影响本字段单位。
  uint32_t char_index;
  uint32_t char_count;     // 本行 UTF-16 code unit 数（自洽校验：char_index < char_count）
  int32_t glyph_x;         // 命中字形矩形，primaryLayer 坐标
  int32_t glyph_y;
  int32_t glyph_w;
  int32_t glyph_h;
  int32_t view_w;          // primaryLayer 尺寸；host 据此定位与钳制卡片
  int32_t view_h;
  uint32_t flags;          // bit0: 1=点击提交，0=悬停预览
  uint32_t line_bytes;     // line_utf8 有效字节数（<= kLookupLineBytes）
  // **整行**台词，不截断。prototype 从点击字向后截 48 字，结果是制卡拿不到完整句子；
  // 分词也不该在注入侧做——host 的分词才是全 app 唯一真值。
  uint8_t line_utf8[kLookupLineBytes];
};

constexpr uint32_t kLookupHitFlagSubmit = 0x00000001u;

// host → hook：一帧卡片位图的元数据。
//
// **两个序号是两回事，别再压成一个字段。** 早先只有一个 `seq`（既当发布序、又当"回应
// 哪次 hit"），结果 dismiss 直接死在自己手里：收卡帧复用被撤那张卡的 hit seq，而那个 seq
// 刚 present 过，注入侧的"丢弃不比已应用的新"过滤把它当陈旧帧扔了——加个 0×0 分支也救不
// 回来，因为帧压根进不了候选。这不是漏了个分支，是数据结构错了：
//   * `seq`     = **发布序**。host 每投一帧（present 或 dismiss）都 +1，单调。注入侧用它
//                 判新与去重，也用它算槽下标。
//   * `hit_seq` = 这帧**回应哪次 hit**。注入侧用它判"这张卡是不是已经被更新的命中作废了"。
// 分开之后 dismiss 就是普通一帧，不需要任何特例。
//
// **槽下标规则（两侧唯一约定，别各写各的）**：元数据槽下标与像素块下标**同为**
// `seq % lookup_frame_count`（发布序，不是 hit_seq）。host 不许用自己的轮转计数器放元数据、
// 再用 seq%N 放像素——那样注入侧会全量拒帧，而症状（卡片永远不出现）和「host 压根没投帧」
// 完全同形，真机上根本分不开。注入侧按此下标读，不一致即丢帧并置 kLookupDiagFrameRejected。
//
// `ready` **最后**写：0=host 正在写，1=可读。hook 拷完必须复查 seq/ready 未变，否则丢弃。
struct LookupFrame {
  volatile uint64_t seq;      // 发布序：host 每投一帧 +1，单调。注入侧据此判新/去重/算槽
  uint64_t hit_seq;           // 这帧回应哪次 hit；比最新 hit 旧即作废
  uint32_t flags;             // kLookupFrame* 位
  uint32_t width;             // 像素宽（dismiss 帧为 0）
  uint32_t height;            // 像素高（dismiss 帧为 0）
  // 行字节跨距，**恒为正、恒自顶向下**（>= width*4）。这块内存是我们自己的，没有理由
  // 继承任何一侧的行序怪癖。游戏 Layer 那侧的 mainImageBufferPitch 可能为负（KiriKiri
  // 自底向上），那是注入侧搬运时的事，不许漏进这个跨进程契约。
  uint32_t pitch;
  int32_t anchor_x;           // 卡片左上角，primaryLayer 坐标（host 决定，含避让与钳制）
  int32_t anchor_y;
  uint32_t highlight_start;   // 字幕高亮起始字符下标
  uint32_t highlight_len;     // 高亮字符数（0=不高亮）
  uint32_t byte_len;          // 位图有效字节数（= pitch*height，<= kLookupBitmapBytes）
  volatile uint32_t ready;    // 0=写入中，1=可读
  uint32_t reserved;
  uint32_t reserved2;
};

// LookupFrame::flags 位。
// 收卡是**普通一帧**，靠这个位自述，不靠「width==0 是收卡」这种魔法编码：后者要求每个
// 读侧都记住这条隐规则，而它和「host 投了张废帧」在字节上完全一样。
constexpr uint32_t kLookupFrameDismiss = 0x00000001u;
// 只更新高亮：不带像素，注入侧跳过整张卡片的 memcpy，只把高亮挪到新位置。
//
// 悬停时卡片内容一个像素都没变，只是高亮要换字。而普通 present 每次都要走一整轮
// 「CapturePreview → PNG 编码 → WIC 解码 → 全卡 memcpy」——鼠标划过一行就是几十次，
// 真机上直接表现为"太卡了"。高亮本来就画在游戏自己的图层上，不在卡片位图里，所以
// 这条路不需要任何像素。
constexpr uint32_t kLookupFrameHighlightOnly = 0x00000002u;
// hook → host：落在卡片矩形内、需要喂给离屏 WebView2 的输入事件。
struct LookupInputSlot {
  volatile uint64_t seq;  // 单调；**最后**写
  int32_t x;              // 卡片局部坐标（已减去 anchor）
  int32_t y;
  uint32_t kind;          // kLookupInput*
  int32_t wheel;          // 滚轮增量（kind==kLookupInputWheel 时有效）
  uint32_t keys;          // 修饰键位掩码
  uint32_t reserved;
};

constexpr uint32_t kLookupInputMove = 0;
constexpr uint32_t kLookupInputLeftDown = 1;
constexpr uint32_t kLookupInputLeftUp = 2;
constexpr uint32_t kLookupInputWheel = 3;
constexpr uint32_t kLookupInputLeave = 4;

// 共享内存头。injector 创建并清零、填各区偏移；hook DLL 注入后填格式、持续更新计数。
// volatile 字段跨进程无锁单写单读。绝不在此放指针（跨进程地址无意义）。
// 内存布局：[SharedHeader][音频环形 ring_capacity][文本区 TextRegionBytes()]
//           [clip 索引 kClipCount*sizeof(VoiceClip)]，各区偏移由 injector 填进 header。
// 文本区自 v13 起是 [TextLane 表][按道分块的槽区]，寻址一律走 TextLaneSlotAt。
struct SharedHeader {
  uint32_t magic;           // = kSharedMagic
  uint32_t version;         // = kSharedVersion
  uint32_t ipc_protocol_version;     // = kStableIpcVersion
  uint32_t luna_bridge_abi_version;  // = kLunaBridgeAbiVersion
  uint32_t luna_vendored_version;    // packed 10.16.1.2
  uint32_t protocol_reserved;
  uint32_t sample_rate;     // hook 首次拿到语音格式后填
  uint32_t channels;        //
  uint32_t bits_per_sample;  //
  uint32_t is_float;        // 1 = IEEE float，0 = 整型 PCM
  uint32_t ring_capacity;   // 紧随 header 的音频环形字节数（帧对齐，≤kMaxRingBytes）
  uint32_t block_align;     // 每帧字节 = channels * bits/8（hook 填）
  volatile uint32_t write_pos;      // 下一个写入位置（0..ring_capacity）
  volatile uint32_t hooked;         // 1 = hook DLL 已注入并安装钩子（proof-of-life）
  volatile uint32_t calibrating;    // 1 = 校准模式（识别 voice callsite 中）
  volatile uint32_t text_hooked;    // 1 = 文本 hook 已装（v2）
  volatile uint64_t total_written;  // 单调累计写入音频字节（host 判断有多少可读）
  // ── v2 区偏移（injector 填，header 起算的字节偏移）──
  uint32_t text_region_offset;      // 文本环起始
  uint32_t clip_region_offset;      // clip 索引起始
  volatile uint64_t text_write_count;  // 单调：已写文本事件数（host 取 last..count 的新事件）
  volatile uint64_t clip_write_count;  // 单调：已写语音 clip 数
  // 0=尚未选定（v12 起文本环恒空）；非 0=用户在 Hibiki 选择的 TextSlot::thread_id。
  // injector 无条件过滤重复伪影，再仅写该线程/同一 hook face。
  volatile uint64_t selected_text_thread_id;
  // LunaHook（引擎精确）出干净行后 injector 置 1；置 1 后游戏内 GDI 文本 hook 让位不再写文本，
  // 消除「LunaHook 干净行 + GDI 每字重画伪影」双写者污染。音频写入不受此标志影响。GDI 仅在
  // luna_active==0（LunaHook 未覆盖该引擎）时作兜底文本源。
  volatile uint32_t luna_active;
  uint32_t reserved_luna;  // 32 位引擎诊断位（已满，loopback 另立字段）
  // Helper 自身诊断位。不能复用 reserved_luna：其 32 位已被各引擎探针占满，且 Siglus
  // 原始 OGG dump 也使用最高位。v10 单独扩展，避免启动同步与 Siglus 状态互相误判。
  volatile uint32_t hook_diagnostics;
  uint32_t reserved_hook_diagnostics;
  volatile uint64_t unity_voice_write_count;
  UnityVoiceEvent unity_voice_events[kUnityVoiceEventCount];
  // ── v6 loopback 区（injector 填偏移/容量，hook 侧 loopback 线程填格式/计数）──
  // 内存布局尾部追加：[...clip 索引][loopback 环 loopback_ring_capacity][标记表 kLoopbackMarkerCount*LoopbackMarker]
  uint32_t loopback_ring_offset;       // loopback 环起始（header 起算字节偏移）
  uint32_t loopback_ring_capacity;     // loopback 环字节容量（帧对齐）
  uint32_t loopback_marker_offset;     // 标记表起始（header 起算字节偏移）
  uint32_t loopback_marker_slot_count;  // 标记表槽数（= kLoopbackMarkerCount，冗余便于 reader 自洽）
  uint32_t loopback_sample_rate;       // loopback 混音采样率（GetMixFormat 后 hook 填）
  uint32_t loopback_channels;          // 混音声道数
  uint32_t loopback_bits_per_sample;   // 存入环的位深（固定 16，混音 float32 已转换）
  uint32_t loopback_block_align;       // 每帧字节 = channels*bits/8（存储格式；hook 填，作格式就绪信号）
  volatile uint32_t loopback_write_pos;  // 下一写入位置（0..loopback_ring_capacity）
  uint32_t loopback_diag;                // loopback 诊断位（线程启动/设备就绪/捕获非静音等）
  volatile uint64_t loopback_total_written;  // 单调累计写入 loopback 字节（reader 判可读量/覆盖）
  volatile uint64_t loopback_marker_count;   // 单调累计已写标记数
  // ── v12 线程预览区（injector 填偏移/槽数，写入者是 Luna 回调路径）──
  // 内存布局尾部再追加：[...标记表][线程预览区 thread_preview_slot_count*ThreadPreviewSlot]
  uint32_t thread_preview_offset;      // 线程预览区起始（header 起算字节偏移）
  uint32_t thread_preview_slot_count;  // 槽数（= kThreadPreviewCount，冗余便于 reader 自洽）
  // 单调累计预览变更次数（含 partial TextMesh 快照）。host 只用它判断「有没有新预览」；
  // 预览槽本身按
  // thread_id 寻址，不靠这个序号定位（与文本环的 text_write_count 语义不同，勿照搬）。
  volatile uint64_t thread_preview_write_count;
  // ── v13 文本分道（injector 填，冗余便于 reader 自洽；道表位于 text_region_offset 处）──
  // 布局：[TextLane 表 text_lane_count 条][槽区 text_lane_count*text_lane_slot_count*kTextSlotBytes]
  uint32_t text_lane_count;
  uint32_t text_lane_slot_count;
  // 道用尽时的两个计数（host 必须能把「道满」和「hook 压根没出文本」分开）。
  //
  // 为什么非有不可：v13 放开非胜出线程**本身就抬高了道满概率**（以前只有选定线程在写，
  // 现在每条线程都要占一条道）。而道满的症状——某些线程的台词就是不来——与它要根治的
  // 256 槽挤压**完全同形**。没有这两个数，真机上根本分不出「分道没生效」和「道不够用」，
  // 等于把要修的病换个地方藏起来。
  volatile uint64_t text_lane_recycle_count;   // 回收了一条最久未写的非选定道
  volatile uint64_t text_lane_overflow_count;  // 连可回收的道都没有，本行被丢弃
  // ── v14 游戏内查词区（injector 填偏移/容量；追加在布局最尾，前面各区偏移不动）────
  uint32_t lookup_region_offset;      // 查词区起始（header 起算字节偏移；0=本会话无此区）
  uint32_t lookup_bitmap_bytes;       // 单缓冲位图字节容量（= kLookupBitmapBytes，冗余自洽）
  uint32_t lookup_frame_count;        // 位图缓冲数（= kLookupFrameCount，冗余自洽）
  uint32_t lookup_input_slot_count;   // 输入环槽数（= kLookupInputSlotCount，冗余自洽）
  volatile uint64_t lookup_hit_count;    // hook→host 单调：命中事件数
  volatile uint64_t lookup_frame_count_written;  // host→hook 单调：已投位图帧数
  volatile uint64_t lookup_input_count;  // hook→host 单调：已转发的卡片输入事件数
  // host→hook 开关。取代 prototype 的 FUSHI_KIRIKIRI_LOOKUP_* 环境变量——把认证 token
  // 塞进游戏进程环境块是安全缺陷（任何拿得到 PROCESS_QUERY_INFORMATION 的进程都能读），
  // 且环境变量在进程启动后改不了，做不到运行期开关。形态照抄 selected_text_thread_id。
  volatile uint32_t lookup_enabled;
  volatile uint32_t lookup_diag;      // kLookupDiag* 位
};
#pragma pack(pop)

inline uint64_t SelectedTextThreadId(const SharedHeader* header) {
  if (header == nullptr) return 0;
  return AtomicLoadPreview64(&header->selected_text_thread_id);
}

inline bool IsExactTextThreadSelected(const SharedHeader* header,
                                      uint64_t thread_id) {
  return thread_id != 0 && SelectedTextThreadId(header) == thread_id;
}

// ── v13 文本分道寻址（写侧/读侧唯一实现，谁都不许自己再算一遍偏移）────────────────
//
// 整区尺寸：道表 + 槽区。injector 按此分配并填 text_region_offset / text_lane_*。
inline constexpr uint64_t TextRegionBytes(uint32_t lane_count,
                                          uint32_t lane_slot_count) {
  return static_cast<uint64_t>(lane_count) * sizeof(TextLane) +
         static_cast<uint64_t>(lane_count) * lane_slot_count * kTextSlotBytes;
}

inline TextLane* TextLanesOf(SharedHeader* header) {
  if (header == nullptr || header->text_region_offset == 0) return nullptr;
  return reinterpret_cast<TextLane*>(reinterpret_cast<uint8_t*>(header) +
                                     header->text_region_offset);
}

inline const TextLane* TextLanesOf(const SharedHeader* header) {
  if (header == nullptr || header->text_region_offset == 0) return nullptr;
  return reinterpret_cast<const TextLane*>(
      reinterpret_cast<const uint8_t*>(header) + header->text_region_offset);
}

// 槽区起点 = 道表之后。
inline uint64_t TextSlotAreaOffset(const SharedHeader* header) {
  return static_cast<uint64_t>(header->text_region_offset) +
         static_cast<uint64_t>(header->text_lane_count) * sizeof(TextLane);
}

// 第 [lane] 条道、道内序号 [lane_seq]（从 1 起）对应的槽。lane_seq 在道内取模覆盖。
inline uint8_t* TextLaneSlotAt(SharedHeader* header, uint32_t lane,
                               uint64_t lane_seq) {
  if (header == nullptr || lane >= header->text_lane_count ||
      header->text_lane_slot_count == 0 || lane_seq == 0) {
    return nullptr;
  }
  const uint64_t index_in_lane = (lane_seq - 1) % header->text_lane_slot_count;
  const uint64_t offset =
      TextSlotAreaOffset(header) +
      (static_cast<uint64_t>(lane) * header->text_lane_slot_count +
       index_in_lane) *
          kTextSlotBytes;
  return reinterpret_cast<uint8_t*>(header) + static_cast<size_t>(offset);
}

inline const uint8_t* TextLaneSlotAt(const SharedHeader* header, uint32_t lane,
                                     uint64_t lane_seq) {
  return TextLaneSlotAt(const_cast<SharedHeader*>(header), lane, lane_seq);
}

// 在 [begin, end) 区段里按 thread_id 查找/认领一条道。调用方持 writer 锁。
// 回收会产生空洞，因此必须扫完整个区段以优先找回已有 id（与 FindThreadPreviewSlot 同款纪律）。
// 区段用于隔离跨进程 writer：Luna 用低段、游戏内 native adapter 用高段。
inline TextLane* FindTextLane(TextLane* lanes, uint32_t begin, uint32_t end,
                              uint64_t thread_id, uint32_t* lane_index_out) {
  if (lanes == nullptr || thread_id == 0) return nullptr;
  TextLane* first_empty = nullptr;
  uint32_t first_empty_index = 0;
  for (uint32_t i = begin; i < end; ++i) {
    if (lanes[i].thread_id == thread_id) {
      if (lane_index_out != nullptr) *lane_index_out = i;
      return &lanes[i];
    }
    if (lanes[i].thread_id == 0 && first_empty == nullptr) {
      first_empty = &lanes[i];
      first_empty_index = i;
    }
  }
  if (first_empty != nullptr && lane_index_out != nullptr) {
    *lane_index_out = first_empty_index;
  }
  return first_empty;
}

// 按**全局发布序**枚举当前仍留在各道里的文本槽（只收 seq > [after_seq] 的）。
//
// 分道之后「读最近 N 条」不再是对一个全局序号取模，而是遍历各道再归并。读侧不止一个
// （host 的 PollText、诊断探针 ring_probe），归并写两遍就会两边行为漂开——所以实现只放
// 这里一份。插入排序，条数上界是总槽数（几百），无分配。
//
// 返回写入 [out] 的条数。[capacity] 不足时保留**序号最大**的那批（最近的行）。
inline uint32_t CollectTextSlotsBySeq(const SharedHeader* header,
                                      const TextSlot** out, uint32_t capacity,
                                      uint64_t after_seq) {
  if (header == nullptr || out == nullptr || capacity == 0) return 0;
  const TextLane* lanes = TextLanesOf(header);
  if (lanes == nullptr) return 0;
  const uint32_t lane_slots = header->text_lane_slot_count;
  if (lane_slots == 0) return 0;
  uint32_t count = 0;
  for (uint32_t lane = 0; lane < header->text_lane_count; ++lane) {
    if (lanes[lane].thread_id == 0) continue;
    const uint64_t written = lanes[lane].write_count;
    if (written == 0) continue;
    const uint64_t first =
        written > lane_slots ? written - lane_slots + 1 : 1;
    for (uint64_t lane_seq = first; lane_seq <= written; ++lane_seq) {
      const auto* slot =
          reinterpret_cast<const TextSlot*>(TextLaneSlotAt(header, lane,
                                                           lane_seq));
      // 道内校验：lane_seq 对不上 = 已被本道后来的行覆盖，或还没发布完。
      // 原子读：写侧用 Interlocked 发布，读侧照样不能裸读（x86 上 64 位裸读会撕裂）。
      if (slot == nullptr ||
          AtomicLoadPreview64(&slot->lane_seq) != lane_seq) {
        continue;
      }
      const uint64_t seq = slot->seq;
      if (seq <= after_seq) continue;
      if (count < capacity) {
        out[count++] = slot;
        // 从尾部往前冒泡到位（out 始终按 seq 升序，out[0] 恒为最旧）。
        for (uint32_t i = count - 1; i > 0; --i) {
          if (out[i - 1]->seq <= out[i]->seq) break;
          const TextSlot* tmp = out[i - 1];
          out[i - 1] = out[i];
          out[i] = tmp;
        }
      } else if (out[0]->seq < seq) {
        out[0] = slot;  // 满了就顶掉当前最旧的那条，再从头冒泡回位
        for (uint32_t i = 0; i + 1 < capacity; ++i) {
          if (out[i]->seq <= out[i + 1]->seq) break;
          const TextSlot* tmp = out[i];
          out[i] = out[i + 1];
          out[i + 1] = tmp;
        }
      }
    }
  }
  return count;
}

// 一次文本事件写入的全部输入。三个写侧（injector 的 Luna 回调、游戏内 GDI/TextRender、
// 游戏内 Unity）字段集合不同，但**寻址与发布纪律必须只有一份实现**，否则分道的不变量
// （只能覆盖自己那条道）会随第四个写侧被悄悄破坏。
struct TextLaneWrite {
  uint64_t thread_id = 0;
  uint64_t face_id = 0;
  uint64_t thread_address = 0;
  uint64_t thread_context = 0;
  uint64_t thread_context2 = 0;
  uint32_t process_id = 0;
  uint32_t source_kind = kTextSourceUnknown;
  uint32_t event_kind = kTextEventLine;
  uint32_t event_flags = 0;
  uint32_t is_utf8 = 0;
  const void* text = nullptr;  // 文本字节（按 is_utf8 解释）；线程发现事件可为空
  uint32_t byte_len = 0;
  const char* hook_name = nullptr;
  const wchar_t* hook_code = nullptr;
};

// 把一条文本事件写进 [thread_id] 自己那条道。返回全局发布序（0 = 没写成：道满/参数非法）。
//
// 调用方持**自己进程内**的 writer 锁（认领与道内占号要互斥）；跨进程隔离靠 [lane_begin,
// lane_end) 区段划分，不靠锁。写序：认领道 → 原子占全局序 → 原子占道内序 → 填字段与文本 →
// **最后**写 lane_seq 作完成标记（reader 校验 lane_seq 才取该槽；x86/x64 store 有序，
// 前面的数据写对 reader 先于 lane_seq 可见）。
inline uint64_t WriteTextLaneEvent(SharedHeader* header, uint32_t lane_begin,
                                   uint32_t lane_end,
                                   const TextLaneWrite& write) {
  if (header == nullptr || write.thread_id == 0) return 0;
  TextLane* lanes = TextLanesOf(header);
  if (lanes == nullptr || header->text_lane_count == 0) return 0;
  const uint32_t end = (lane_end < header->text_lane_count)
                           ? lane_end
                           : header->text_lane_count;
  if (lane_begin >= end) return 0;
  uint32_t lane_index = 0;
  TextLane* lane = FindTextLane(lanes, lane_begin, end, write.thread_id,
                                &lane_index);
  if (lane == nullptr) {
    // 道用尽。**绝不静默丢弃**：那样的症状（某些线程的台词就是不来）与 v13 要根治的
    // 256 槽挤压完全同形，真机上分不出是分道没生效还是道不够用。
    //
    // 处置分两级，两级都留计数：
    //  ① 回收最久没写过的**非选定**道 —— 选定线程那条道是配对路径的输入，任何情况下
    //     都不能被顶掉；被回收的线程只是暂时失去历史，它下一行会重新认领一条道，仍然
    //     在预览区里看得见、仍然可选（预览区另有自己的槽，不受此处影响）。
    //  ② 连一条可回收的都没有（全被选定线程占着，理论上只有 1 条）才丢弃本行。
    // write_count 跨回收保持单调：重置它会让新占用者的 lane_seq 与上一任的残留槽撞号，
    // reader 会把旧行当成新行的有效槽。残留槽本身无害——每个槽自带 thread_id，消费方
    // 按线程过滤，不会张冠李戴。
    const uint64_t selected = SelectedTextThreadId(header);
    TextLane* victim = nullptr;
    uint32_t victim_index = 0;
    for (uint32_t i = lane_begin; i < end; ++i) {
      if (lanes[i].thread_id == selected) continue;
      if (victim == nullptr || lanes[i].last_write_ms < victim->last_write_ms) {
        victim = &lanes[i];
        victim_index = i;
      }
    }
    if (victim == nullptr) {
      InterlockedIncrement64(reinterpret_cast<volatile LONGLONG*>(
          &header->text_lane_overflow_count));
      return 0;
    }
    InterlockedIncrement64(reinterpret_cast<volatile LONGLONG*>(
        &header->text_lane_recycle_count));
    lane = victim;
    lane_index = victim_index;
  }
  lane->thread_id = write.thread_id;
  const uint64_t global_seq = static_cast<uint64_t>(InterlockedIncrement64(
      reinterpret_cast<volatile LONGLONG*>(&header->text_write_count)));
  const uint64_t lane_seq = static_cast<uint64_t>(InterlockedIncrement64(
      reinterpret_cast<volatile LONGLONG*>(&lane->write_count)));
  uint8_t* slot = TextLaneSlotAt(header, lane_index, lane_seq);
  if (slot == nullptr) return 0;
  auto* ts = reinterpret_cast<TextSlot*>(slot);
  memset(ts, 0, sizeof(TextSlot));
  uint32_t max_bytes = kTextSlotBytes - static_cast<uint32_t>(sizeof(TextSlot));
  max_bytes -= (max_bytes % static_cast<uint32_t>(sizeof(wchar_t)));
  uint32_t byte_len = write.text == nullptr ? 0 : write.byte_len;
  if (byte_len > max_bytes) byte_len = max_bytes;
  if (byte_len != 0) memcpy(slot + sizeof(TextSlot), write.text, byte_len);
  ts->seq = global_seq;
  ts->timestamp_ms = GetTickCount64();
  ts->byte_len = byte_len;
  ts->is_utf8 = write.is_utf8;
  ts->thread_id = write.thread_id;
  ts->face_id = write.face_id;
  ts->thread_address = write.thread_address;
  ts->thread_context = write.thread_context;
  ts->thread_context2 = write.thread_context2;
  ts->process_id = write.process_id;
  ts->source_kind = write.source_kind;
  ts->event_kind = write.event_kind;
  ts->event_flags = write.event_flags;
  if (write.hook_name != nullptr) {
    size_t n = 0;
    while (n < kTextHookNameChars - 1 && write.hook_name[n] != '\0') ++n;
    memcpy(ts->hook_name, write.hook_name, n);
    ts->hook_name[n] = '\0';
    ts->hook_name_len = static_cast<uint32_t>(n);
  }
  if (write.hook_code != nullptr) {
    size_t n = 0;
    while (n < kTextHookCodeChars - 1 && write.hook_code[n] != L'\0') ++n;
    memcpy(ts->hook_code, write.hook_code, n * sizeof(wchar_t));
    ts->hook_code[n] = L'\0';
    ts->hook_code_len = static_cast<uint32_t>(n);
  }
  lane->last_write_ms = ts->timestamp_ms;
  // 完成标记，**最后**写：Interlocked 是全栅栏（前面的 payload 写对 reader 必先可见）
  // 且 64 位不可撕裂（x86 上普通写会被拆成两次 32 位写）。与预览槽 seq 同一套纪律。
  AtomicStorePreview64(&ts->lane_seq, lane_seq);
  if (header->text_hooked == 0) header->text_hooked = 1;
  return global_seq;
}

// ── v14 查词区寻址（写侧/读侧唯一实现，谁都不许自己再算一遍偏移）────────────────
//
// 整区布局：[LookupHitSlot][LookupInputSlot × N][LookupFrame × F][位图 × F]
inline constexpr uint64_t LookupRegionBytes(uint32_t input_slot_count,
                                            uint32_t frame_count,
                                            uint32_t bitmap_bytes) {
  return sizeof(LookupHitSlot) +
         static_cast<uint64_t>(input_slot_count) * sizeof(LookupInputSlot) +
         static_cast<uint64_t>(frame_count) * sizeof(LookupFrame) +
         static_cast<uint64_t>(frame_count) * bitmap_bytes;
}

inline bool HasLookupRegion(const SharedHeader* header) {
  return header != nullptr && header->lookup_region_offset != 0 &&
         header->lookup_frame_count != 0 && header->lookup_bitmap_bytes != 0 &&
         header->lookup_input_slot_count != 0;
}

inline LookupHitSlot* LookupHitOf(SharedHeader* header) {
  if (!HasLookupRegion(header)) return nullptr;
  return reinterpret_cast<LookupHitSlot*>(reinterpret_cast<uint8_t*>(header) +
                                          header->lookup_region_offset);
}

inline const LookupHitSlot* LookupHitOf(const SharedHeader* header) {
  if (!HasLookupRegion(header)) return nullptr;
  return reinterpret_cast<const LookupHitSlot*>(
      reinterpret_cast<const uint8_t*>(header) + header->lookup_region_offset);
}

inline LookupInputSlot* LookupInputsOf(SharedHeader* header) {
  if (!HasLookupRegion(header)) return nullptr;
  return reinterpret_cast<LookupInputSlot*>(
      reinterpret_cast<uint8_t*>(header) + header->lookup_region_offset +
      sizeof(LookupHitSlot));
}

inline const LookupInputSlot* LookupInputsOf(const SharedHeader* header) {
  if (!HasLookupRegion(header)) return nullptr;
  return reinterpret_cast<const LookupInputSlot*>(
      reinterpret_cast<const uint8_t*>(header) + header->lookup_region_offset +
      sizeof(LookupHitSlot));
}

// 区内偏移一律用 size_t 而不是 uint64_t：这些值按构造都装得下 uint32_t（header 里的偏移
// 字段本身就是 uint32_t），而 x86 构建下拿 uint64_t 去做指针算术会被截断并在 /W4 /WX 的
// runner 上直接变成编译错误。整区**总字节数**仍用 uint64_t（LookupRegionBytes），因为它要
// 参与 injector 的 total_size 求和，那里确实可能超 4GB 语义上限。
inline size_t LookupFramesByteOffset(const SharedHeader* header) {
  return static_cast<size_t>(header->lookup_region_offset) +
         sizeof(LookupHitSlot) +
         static_cast<size_t>(header->lookup_input_slot_count) *
             sizeof(LookupInputSlot);
}

inline size_t LookupBitmapsByteOffset(const SharedHeader* header) {
  return LookupFramesByteOffset(header) +
         static_cast<size_t>(header->lookup_frame_count) * sizeof(LookupFrame);
}

inline LookupFrame* LookupFrameAt(SharedHeader* header, uint32_t index) {
  if (!HasLookupRegion(header) || index >= header->lookup_frame_count) {
    return nullptr;
  }
  return reinterpret_cast<LookupFrame*>(reinterpret_cast<uint8_t*>(header) +
                                        LookupFramesByteOffset(header)) +
         index;
}

inline const LookupFrame* LookupFrameAt(const SharedHeader* header,
                                        uint32_t index) {
  if (!HasLookupRegion(header) || index >= header->lookup_frame_count) {
    return nullptr;
  }
  return reinterpret_cast<const LookupFrame*>(
             reinterpret_cast<const uint8_t*>(header) +
             LookupFramesByteOffset(header)) +
         index;
}

inline uint8_t* LookupBitmapAt(SharedHeader* header, uint32_t index) {
  if (!HasLookupRegion(header) || index >= header->lookup_frame_count) {
    return nullptr;
  }
  return reinterpret_cast<uint8_t*>(header) + LookupBitmapsByteOffset(header) +
         static_cast<size_t>(index) * header->lookup_bitmap_bytes;
}

inline const uint8_t* LookupBitmapAt(const SharedHeader* header,
                                     uint32_t index) {
  if (!HasLookupRegion(header) || index >= header->lookup_frame_count) {
    return nullptr;
  }
  return reinterpret_cast<const uint8_t*>(header) +
         LookupBitmapsByteOffset(header) +
         static_cast<size_t>(index) * header->lookup_bitmap_bytes;
}

// 「这帧该不该应用」的**唯一判据**。注入侧与 replay 测试共用同一份——判据一旦各写各的，
// replay 绿了也只证明参照实现自洽，证明不了生产代码对。收卡曾经整条不通就是死在这个判据上
// （详见 LookupFrame 注释），那种错必须能被离线回归抓住，而不是等真机。
//
// ready 位不在这里判：它是「host 写完没有」的内存可见性问题，归调用点，与「这帧是否过期」
// 是两件事。seq 由调用点原子读出后传进来，同理。
inline bool ShouldApplyLookupFrame(uint64_t frame_seq, uint64_t frame_hit_seq,
                                   uint32_t frame_flags,
                                   uint64_t presented_seq,
                                   uint64_t current_any_hit_seq,
                                   uint64_t current_submit_hit_seq) {
  // 发布序不比已处理的新 → 这帧我处理过了。
  if (frame_seq <= presented_seq) return false;
  // hover 只控制游戏线程即时绘制的字形高亮；卡片内容、收卡与 dismiss 都属于最近一次
  // submit。两种身份混用会让查词期间经过的 hover 把正确结果判成陈旧帧。
  const uint64_t fence = frame_flags == kLookupFrameHighlightOnly
                             ? current_any_hit_seq
                             : current_submit_hit_seq;
  // 只接受精确身份。大于 fence 的 frame 同样没有合法来源，不能把“host 抢跑”当成功。
  return frame_hit_seq == fence;
}

// 帧自洽校验。**注入侧必须先过这一关再拷贝**：跨进程来的 width/height/pitch 全是不可信
// 输入，按它们盲拷就是把共享内存越界写进游戏进程。host 侧同样用它自检，避免投出废帧。
inline bool IsLookupFrameSane(const SharedHeader* header,
                              const LookupFrame* frame) {
  if (header == nullptr || frame == nullptr) return false;
  if (frame->width == 0 || frame->height == 0) return false;
  if (frame->width > 0x4000u || frame->height > 0x4000u) return false;
  const uint64_t min_pitch = static_cast<uint64_t>(frame->width) * 4u;
  if (frame->pitch < min_pitch) return false;
  const uint64_t needed =
      static_cast<uint64_t>(frame->pitch) * frame->height;
  if (needed != frame->byte_len) return false;
  return needed <= header->lookup_bitmap_bytes;
}

static_assert(sizeof(SharedHeader) % 8 == 0, "SharedHeader must stay 8-aligned");
static_assert(sizeof(LookupHitSlot) % 8 == 0, "LookupHitSlot must stay 8-aligned");
static_assert(sizeof(LookupFrame) % 8 == 0, "LookupFrame must stay 8-aligned");
static_assert(sizeof(LookupInputSlot) % 8 == 0,
              "LookupInputSlot must stay 8-aligned");
// 双缓冲是防撕裂的**结构前提**：单缓冲时 host 写下一帧与 hook 拷当前帧必然重叠。
static_assert(kLookupFrameCount >= 2, "lookup frames must be double-buffered");
static_assert(sizeof(TextSlot) % 8 == 0, "TextSlot must stay 8-aligned");
static_assert(sizeof(TextLane) % 8 == 0, "TextLane must stay 8-aligned");
// 道数与预览槽数必须同值：两者共用同一套下标与同一套跨进程互斥分区，分开就会有一侧
// 越界或两个进程认领到同一条道。
static_assert(kTextLaneCount == kThreadPreviewCount,
              "text lanes and thread previews must share one index space");
static_assert(sizeof(TextSlot) < kTextSlotBytes,
              "TextSlot header must leave room for payload bytes");
static_assert(sizeof(VoiceClip) % 8 == 0, "VoiceClip must stay 8-aligned");
static_assert(sizeof(UnityVoiceEvent) % 8 == 0,
              "UnityVoiceEvent must stay 8-aligned");
static_assert(sizeof(LoopbackMarker) % 8 == 0, "LoopbackMarker must stay 8-aligned");

// 命名对象（同会话跨进程）。以目标 PID 区分，支持同时对多个游戏进程各挂一份。
// injector 创建、hook DLL 打开：共享内存 + 「就绪」事件（DLL 装好后 SetEvent，injector 据此
// 确认注入成功并读回格式）。
//
// Fushi 改名后的 host 使用 FushiVoiceHook；旧 Hibiki host 仍只会打开 HibikiVoiceHook。
// helper/DLL 可能被部署到旧安装中做兼容修复，因此两侧都按实际组件文件名选同一命名空间，
// 而不是让新版默认名静默破坏旧 host。严格只认完整 basename，避免任意路径子串误判。
inline bool ComponentUsesLegacyHibikiIpc(const std::wstring& component_path) {
  const size_t slash = component_path.find_last_of(L"\\/");
  const wchar_t* basename = slash == std::wstring::npos
                                ? component_path.c_str()
                                : component_path.c_str() + slash + 1;
  return _wcsicmp(basename, L"hibiki_voice_injector.exe") == 0 ||
         _wcsicmp(basename, L"hibiki_voice_hook.dll") == 0;
}

inline std::wstring SharedMemoryName(DWORD target_pid,
                                     bool legacy_hibiki = false) {
  return std::wstring(legacy_hibiki ? L"Local\\HibikiVoiceHook_"
                                    : L"Local\\FushiVoiceHook_") +
         std::to_wstring(target_pid);
}
inline std::wstring ReadyEventName(DWORD target_pid,
                                   bool legacy_hibiki = false) {
  return std::wstring(legacy_hibiki ? L"Local\\HibikiVoiceHookReady_"
                                    : L"Local\\FushiVoiceHookReady_") +
         std::to_wstring(target_pid);
}

}  // namespace fushi_voice_hook

#endif  // FUSHI_VOICE_HOOK_IPC_H_
