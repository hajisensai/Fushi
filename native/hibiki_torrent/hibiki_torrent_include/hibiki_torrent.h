#pragma once

// hibiki_torrent — C ABI bridge over libtorrent 2.x.
//
// 阶段1b：真实下载管线（磁力 → 元数据 → 顺序下载 → 进度 → 完成）+ 本地
// 做种/测试支撑（make_torrent / connect_peer）+ 边下边播原语
// （sequential + set_piece_deadline + 首尾 piece 提优）。
// 阶段3：反吸血支撑（torrent_peers 导出 peer_info、apply_ip_filter 执行封禁）。
// C ABI 手写（不被 libtorrent 的 BSD 之外任何依赖传染），Dart 侧用 ffigen
// 从本头文件生成绑定，与 hoshidicts 同一 FFI 范式。
//
// 约定：
// - 返回 `char*` 的函数一律返回 malloc 分配的 UTF-8 JSON 串，调用方用完
//   必须 ht_free_string() 释放；内部错误也以 {"ok":false,"error":"..."}
//   形式返回，绝不返回 NULL（除非 malloc 本身失败）。
// - infohash 参数/字段一律小写十六进制（v1 40 字符；纯 v2 种子为截断
//   sha256 的 40 字符，与 libtorrent get_best() 一致）。
// - 路径一律 UTF-8。

// ── Symbol export（与 hoshidicts platform.hpp 一致的做法）────────────
#ifdef _WIN32
#define HT_EXPORT __declspec(dllexport)
#else
#define HT_EXPORT __attribute__((visibility("default")))
#endif

#ifdef __cplusplus
extern "C" {
#endif

// 返回 libtorrent 运行时版本串（如 "2.0.11.0"）。指向 libtorrent 内部静态
// 存储，调用方**不得** free。
HT_EXPORT const char* ht_libtorrent_version(void);

// 创建 libtorrent session，返回不透明句柄；失败返回 NULL。
// [listen_interfaces]：libtorrent 语法（如 "0.0.0.0:6881" / "127.0.0.1:0"，
// 端口 0 = 系统分配）；NULL 或空串 = 完全不监听、不产生网络副作用（阶段1a
// 空壳语义，冒烟测试用）。[enable_dht] 非 0 开 DHT（公网磁力元数据获取
// 需要；本地测试关闭保证确定性）。LSD/UPnP/NAT-PMP 始终关闭（后续阶段
// 按设置开放）。
HT_EXPORT void* ht_session_create(const char* listen_interfaces,
                                  int enable_dht);

// 销毁 ht_session_create 返回的句柄；传 NULL 为 no-op。
HT_EXPORT void ht_session_destroy(void* session);

// 实际监听端口；未监听 / session 无效返回 0。
HT_EXPORT int ht_session_listen_port(void* session);

// 全局速率上限（字节/秒；<=0 = 不限）。返回 1 成功、0 失败。
HT_EXPORT int ht_session_set_rate_limits(void* session, int download_bps,
                                         int upload_bps);

// 一次设全局资源限制（用户可调，控制内置引擎占用）：
// [download_bps]/[upload_bps] 速率上限（字节/秒，<=0 = 不限）；
// [connections_limit] 全局最大连接数（<=0 = 保持 libtorrent 默认）。
// 返回 1 成功、0 失败。（速率部分与 ht_session_set_rate_limits 等价，这里
// 合成一个入口让 app 从配置一次性应用。）
HT_EXPORT int ht_apply_limits(void* session, int download_bps, int upload_bps,
                              int connections_limit);

// 同 ht_apply_limits，外加一个「限速是否也作用于局域网 peer」开关。
// [limit_local_peers] 非 0 = 把同一组速率上限同时套到 libtorrent 的 local peer
// class（局域网 / 链路本地 / 回环 peer 所属的内置 class）；0 = 把该 class 的
// 上限写回「不限」，即 libtorrent 出厂默认。
// 背景：libtorrent 的 download_rate_limit/upload_rate_limit 只是 session 全局
// 上限，**默认不约束局域网 peer**（官方文档原话），要让限速覆盖本地 peer 只能
// 走 peer class。故 ht_apply_limits(...) === ht_apply_limits_ex(..., 0)，
// 老调用点语义完全不变。返回 1 成功、0 失败。
HT_EXPORT int ht_apply_limits_ex(void* session, int download_bps,
                                 int upload_bps, int connections_limit,
                                 int limit_local_peers);

// 【已废弃，勿在新代码调用】历史上传开关。BUG-1293：旧实现把「关上传」翻译成
// 置 torrent_flags::upload_mode，但该 flag 的 libtorrent 语义是「不再发出任何
// piece 请求」= **只上不下、停止下载**，与本函数宣称的「只下不上」正好相反 ——
// 默认关上传的用户所有种子在 add 后 20s 内被打上此 flag，下载速率归零。
// 现实现：[upload_enabled] 非 0 = 清除 upload_mode（治愈历史 resume 里的残留
// flag）；0 = **no-op 恒成功**（绝不再置 upload_mode——宁可上传也不能掐死下载；
// 旧 Dart + 新 DLL 的组合按此降级）。正确原语见 ht_set_unchoke_slots（会话级
// 停上传）与 ht_pause_torrent（做种停止）。返回 1 成功、0 失败。
HT_EXPORT int ht_set_upload_mode(void* session, const char* info_hash,
                                 int upload_enabled);

// 会话级 unchoke 槽位（BUG-1293 的「关上传」正确原语）：
// [slots] >= 0 精确设置 settings_pack::unchoke_slots_limit（0 = 不给任何 peer
// unchoke 槽位 = 会话级停止上传 payload；我们发出的 piece 请求是协议消息，
// 不占 unchoke 槽，下载不受影响）；[slots] < 0 恢复 libtorrent 出厂默认。
// 返回 1 成功、0 失败。
HT_EXPORT int ht_set_unchoke_slots(void* session, int slots);

// 种子暂停/恢复（做种停止的正确原语；per-torrent 或全量）：
// [info_hash] 空串/NULL = 对 session 内所有种子生效；否则仅该种子。
// [pause] 非 0 = 清 auto_managed 再 pause（不清的话队列管理器会自动恢复）；
// 0 = 恢复 auto_managed 并 resume。返回 1 成功、0 失败（种子不存在）。
HT_EXPORT int ht_pause_torrent(void* session, const char* info_hash,
                               int pause);

// 应用内存占用相关 session 设置（把 libtorrent 压进内存预算，避免「有多少内存
// 吃多少」）：各字段 <=0 时保持 libtorrent 默认，>0 时设置。
// [connections_limit] 全局最大连接数；[max_queued_disk_bytes] 磁盘写缓冲上限；
// [send_buffer_watermark] 每连接发送缓冲高水位；[max_peerlist_size] 每种子 peer
// 列表最大条目数。返回 1 成功 0 失败。
HT_EXPORT int ht_apply_memory_settings(void* session, int connections_limit,
                                       int max_queued_disk_bytes,
                                       int send_buffer_watermark,
                                       int max_peerlist_size);

// 应用会话级设置（抄 qBittorrent 关键项）。[listen_port]>0 时重设监听端口；
// [enable_dht]/[enable_lsd]/[enable_upnp]/[enable_natpmp] 0/1 开关；[enc_policy]
// 0=首选(pe_enabled) 1=强制(pe_forced) 2=禁用(pe_disabled)（出入站同设）；
// [anonymous_mode] 0/1；[active_downloads]/[active_seeds]/[max_upload_slots]
// >0 时设、<=0 保持默认。返回 1 成功 0 失败。
HT_EXPORT int ht_apply_session_settings(
    void* session, int listen_port, int enable_dht, int enable_lsd,
    int enable_upnp, int enable_natpmp, int enc_policy, int anonymous_mode,
    int active_downloads, int active_seeds, int max_upload_slots);

// 添加磁力链接，落盘到 [save_path]；[sequential] 非 0 开顺序下载。
// 成功 {"ok":true,"id":"<infohash>"}；失败 {"ok":false,"error":"..."}。
// 重复添加同一种子返回已有种子的 id（ok:true）。
HT_EXPORT char* ht_add_magnet(void* session, const char* magnet_uri,
                              const char* save_path, int sequential);

// 添加本地 .torrent 文件（本地做种 / 恢复下载）。语义同 ht_add_magnet；
// save_path 里已有完整数据时 libtorrent 校验后直接进入做种。
HT_EXPORT char* ht_add_torrent_file(void* session, const char* torrent_path,
                                    const char* save_path, int sequential);

// 从本地文件或目录生成 .torrent 写到 [out_torrent_path]（本地做种与
// 确定性测试支撑）。成功 {"ok":true,"id":"<infohash>"}。
HT_EXPORT char* ht_make_torrent(const char* content_path,
                                const char* out_torrent_path);

// 手动连接 peer（本地测试 / LAN 直连；绕过 DHT/tracker）。1 成功 0 失败。
HT_EXPORT int ht_connect_peer(void* session, const char* info_hash,
                              const char* ip, int port);

// 列出 session 内所有种子。返回 JSON 数组，每项：
// {"id","name","progress"(0~1),"state"("metadata"|"checking"|"downloading"|
//  "finished"|"seeding"|"error"),"save_path","content_path"(单文件=文件路径、
//  多文件=内容根目录、无元数据=""),"total","done","left"(无元数据=-1),
//  "down_rate","up_rate","uploaded"(累计上传字节，做种上限判定用),
//  "downloaded"(累计下载字节，分享率分母),"num_peers","has_metadata",
//  "is_finished","is_seeding","sequential",
//  TODO-2482 详情批次新增：
//  "num_seeds"(已连接 seed 数),"num_connections"(连接数，含握手中，
//  >= num_peers；leecher 数 = num_peers - num_seeds 由调用方导出),
//  "num_complete"/"num_incomplete"(tracker scrape 的 swarm 总 seed/leecher
//  数，未 scrape 到为 -1),"is_paused"(引擎侧 paused flag；注意宿主的用户
//  暂停真相在 Dart 侧，这里只是引擎观测),"active_duration"/
//  "seeding_duration"/"finished_duration"(秒，跨会话由 resume 累计)}
HT_EXPORT char* ht_list_torrents(void* session);

// 某种子的文件列表：{"ok":true,"files":[{"index","path","size","done"}]}；
// 元数据未就绪 {"ok":false,"error":"no metadata"}。
HT_EXPORT char* ht_torrent_files(void* session, const char* info_hash);

// 分片持有位图：{"ok":true,"num_pieces":N,"have":"0101..."}（'1'=已校验
// 持有）。流式缓冲显示 / 顺序性验证用。
HT_EXPORT char* ht_torrent_pieces(void* session, const char* info_hash);

// 排空本 session 累积的 piece 完成事件（piece_finished_alert），按发生序：
// [{"id":"<infohash>","piece":N},...]。下载顺序证据 / 边下边播缓冲推进用。
HT_EXPORT char* ht_poll_piece_events(void* session);

// 流式播放原语：给单个 piece 设截止期（毫秒），libtorrent 会优先调度。
// 返回 1 成功、0 失败（种子不存在等）。
HT_EXPORT int ht_set_piece_deadline(void* session, const char* info_hash,
                                    int piece, int deadline_ms);

// 元数据就绪后把每个文件的首尾 piece 提到最高优先级（qb 的
// firstLastPiecePrio 等价物，视频容器头尾元数据先到才能起播）。
// 返回 1 = 已应用、0 = 元数据未就绪（稍后重试）、-1 = 种子不存在。
HT_EXPORT int ht_apply_first_last_priority(void* session,
                                           const char* info_hash);

// 某种子当前连接的 peer 列表（反吸血判定输入 + 详情页 Peers tab）：
// {"ok":true,"peers":[{"ip","port","peer_id"(20 字节可打印化，不可打印字节
// 转 '.'),"client","progress"(peer 自报 0~1，可伪造),"total_upload"(我实际
// 喂给该 peer 的字节，可信),"total_download","up_speed","down_speed",
// "remote_interested",
// TODO-2482："flags"(本桥自定义的稳定位掩码，与 libtorrent 内部表示解耦：
// bit0 interesting/bit1 choked/bit2 remote_interested/bit3 remote_choked/
// bit4 supports_extensions/bit5 outgoing/bit6 handshake/bit7 connecting/
// bit8 on_parole/bit9 seed/bit10 optimistic_unchoke/bit11 snubbed/
// bit12 upload_only/bit13 endgame/bit14 holepunched/bit15 utp/bit16 ssl/
// bit17 rc4_encrypted/bit18 plaintext_encrypted)，
// "source"(bit0 tracker/bit1 dht/bit2 pex/bit3 lsd/bit4 fastResume/
// bit5 incoming)}]}
HT_EXPORT char* ht_torrent_peers(void* session, const char* info_hash);

// 用 CIDR 列表整体重建 session 的 ip_filter（换行分隔，如
// "1.2.3.0/24\n5.6.7.8/32"；空串 = 清空）。已连接的命中 peer 会被断开，
// 新连接直接拒绝。封禁真相源在 Dart 侧 AntiLeechEngine（bannedCidrs），
// 每次全量重建消除增量同步状态。1 成功 0 失败。
HT_EXPORT int ht_apply_ip_filter(void* session, const char* cidrs);

// 移除种子；[delete_files] 非 0 连已下载数据一起删。1 成功 0 失败。
HT_EXPORT int ht_remove_torrent(void* session, const char* info_hash,
                                int delete_files);

// 释放本库返回的 char* 串；传 NULL 为 no-op。
// TODO-1961-c：把种子内第 [file_index] 个文件改名成 [new_path]（种子内相对
// 路径，可含子目录；分隔符用 '/'）。**引擎侧改名**，所以做种不断 —— 引擎自己
// 知道数据换了名字，继续从新名字读盘上传。
//
// 同步语义：libtorrent 的 rename_file 是异步的（回执走 file_renamed_alert /
// file_rename_failed_alert），本函数挂在 wait_for_alert 上等回执，最多
// [timeout_ms] 毫秒（<=0 取默认 15000）。
//
// 返回 {"ok":true,"path":"<种子内新相对路径>"}；失败
// {"ok":false,"error":"..."}，error 原样带回引擎给的原因（如目标已存在、
// 权限不足），调用方必须显示给用户，不得吞掉。
HT_EXPORT char* ht_rename_file(void* session, const char* info_hash,
                               int file_index, const char* new_path,
                               int timeout_ms);

// TODO-1961-c：把种子的内容整体移动到 [new_save_path]（新的 save_path）。
// 同样是**引擎侧移动**，做种不断。
//
// 用 libtorrent 的 `fail_if_exist`：目标已有同名文件就整体失败，**绝不覆盖**
// 用户数据，也绝不「跳过已存在的、搬走其余的」留下半个内容目录。
// （libtorrent 默认的 always_replace_files 会直接覆盖，对用户数据太危险。）
//
// 同步语义同 ht_rename_file（回执走 storage_moved_alert /
// storage_moved_failed_alert）。返回 {"ok":true,"path":"<新 save_path>"}。
HT_EXPORT char* ht_move_storage(void* session, const char* info_hash,
                                const char* new_save_path, int timeout_ms);

// TODO-1961-a：把当前 session 里**所有已有元数据**的种子的 resume data 落盘到
// [out_dir]（每种子一个 `<infohash>.resume`，先写 .tmp 再 rename，绝不留半个
// 文件）。resume 里带 info dict，故磁力添加的种子重启后无需再取元数据。
//
// 同步语义：发出请求后最多阻塞 [timeout_ms] 毫秒等回执（<=0 取默认 5000），
// 期间靠 wait_for_alert 挂起而**不是** sleep 轮询。收齐即提前返回，通常几十
// 毫秒内完成。调用方应在退出前与周期性（如每分钟）各调一次。
//
// 返回 JSON：{"ok":true,"saved":N,"failed":M,"timed_out":K}。
// `timed_out` > 0 表示这么多种子在预算内没回执，本次没存（下轮再存即可，
// 不是错误）。session 为 NULL / out_dir 为空 → {"ok":false,...}。
HT_EXPORT char* ht_save_resume_data(void* session, const char* out_dir,
                                    int timeout_ms);

// TODO-1961-a：把 [dir] 下所有 `*.resume` 读回来重新 add 进 session
// （启动时调用 = 「继续上次的下载与做种」）。目录不存在视为首次运行，返回
// added=0 而非错误。坏文件逐个跳过并计入 failed，绝不因一个坏文件整批失败。
//
// add 语义与 ht_add_magnet 一致：清 paused 旗标，加回来即开始跑。已在 session
// 里的重复种子按成功计（幂等，可重复调用）。
//
// 返回 JSON：{"ok":true,"added":N,"failed":M,"ids":["<infohash>",...]}。
HT_EXPORT char* ht_load_resume_dir(void* session, const char* dir);

// ── TODO-2482：任务详情批次 ─────────────────────────────────────────

// 某种子的 tracker 列表（详情页 Trackers tab）：
// {"ok":true,"trackers":[{"url","tier",
//  "working"(任一 endpoint 已成功 announce 且当前无错),
//  "updating"(任一 endpoint 等 tracker 响应中),"fails"(连续失败次数最大值),
//  "last_error"(最近失败的 error_code 文本，空=无),
//  "message"(tracker 返回的错误/警告原文，空=无),
//  "scrape_complete"/"scrape_incomplete"/"scrape_downloaded"(各 endpoint
//  取最大值；-1 = 该 tracker 未返回 scrape 数据)}]}
// 种子不存在 {"ok":false,...}；无 tracker（纯 DHT 磁力）trackers 为空数组。
HT_EXPORT char* ht_torrent_trackers(void* session, const char* info_hash);

// 每个文件的下载优先级（详情页 Files tab）：
// {"ok":true,"priorities":[4,0,7,...]}（下标 = 文件 index；libtorrent
// download_priority 值域 0~7：0 = 不下载、4 = 默认、7 = 最高）。
// 元数据未就绪 {"ok":false,"error":"no metadata"}。
HT_EXPORT char* ht_get_file_priorities(void* session, const char* info_hash);

// 设置单个文件的下载优先级：[priority] 0~7（0 = 不下载）。
// 1 成功、0 失败（种子不存在/元数据未就绪/参数越界）。
HT_EXPORT int ht_set_file_priority(void* session, const char* info_hash,
                                   int file_index, int priority);

// 会话协议状态（详情页 Overview 的协议区）：
// {"ok":true,"listen_port","dht_running"(bool),
//  "dht_nodes"(DHT 路由表节点数，-1 = 尚未统计到),
//  "lsd_enabled","upnp_enabled","natpmp_enabled"(settings 现值),
//  "pex_enabled"(恒 true：本桥建 session 一律带默认插件，含 ut_pex),
//  "down_rate"/"up_rate"(会话级全局速率，字节/秒，含协议开销；由相邻两次
//  session_stats 采样差分，-1 = 未知),
//  "port_mappings":[{"transport":"upnp"|"natpmp","protocol":"tcp"|"udp"|""
//   (error 回执不带协议),"external_port"(失败为 0),"ok","error"}]}
//
// **非阻塞**：本函数发出 post_dht_stats/post_session_stats 请求后只收割
// 已到的 alert 即返回 —— 首次调用 dht_nodes/速率是 -1，下一轮轮询即有值
// （详情页本就秒级轮询；同步等待会把 UI isolate 卡住）。
// 需要 session 的 alert_mask 含 port_mapping 类别（ht_session_create 已设）。
HT_EXPORT char* ht_session_status(void* session);

HT_EXPORT void ht_free_string(char* s);

#ifdef __cplusplus
}
#endif
