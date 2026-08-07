// hibiki_torrent C ABI bridge implementation（阶段1b：真实下载管线）。
//
// 设计原则：
// - C 层不存**种子**状态：种子按 infohash 每次现查（get_torrents() 线性扫，
//   任务数为个位数，够用且消灭状态同步）。句柄是 ht_session_ctx*，它只拥有
//   lt::session 与**已收割待取的 alert 队列**（见 drain_alerts 的注释：
//   pop_alerts 是破坏性的，队列是它唯一正确的去处，不是可选的缓存）。
// - 出参一律 malloc 的 UTF-8 JSON（手写生成 + 转义，零第三方依赖，
//   不引 GPL/非 BSD 传染）；入参路径一律 UTF-8（libtorrent 原生约定）。
// - 所有入口 try/catch 到边界：C ABI 绝不向 Dart 泄异常。

#include "hibiki_torrent.h"

#include <libtorrent/add_torrent_params.hpp>
#include <libtorrent/address.hpp>
#include <libtorrent/alert_types.hpp>
#include <libtorrent/announce_entry.hpp>
#include <libtorrent/bencode.hpp>
#include <libtorrent/create_torrent.hpp>
#include <libtorrent/download_priority.hpp>
#include <libtorrent/error_code.hpp>
#include <libtorrent/ip_filter.hpp>
#include <libtorrent/magnet_uri.hpp>
#include <libtorrent/peer_class.hpp>
#include <libtorrent/read_resume_data.hpp>
#include <libtorrent/portmap.hpp>
#include <libtorrent/session.hpp>
#include <libtorrent/session_params.hpp>
#include <libtorrent/session_stats.hpp>
#include <libtorrent/settings_pack.hpp>
#include <libtorrent/socket.hpp>
#include <libtorrent/torrent_flags.hpp>
#include <libtorrent/torrent_info.hpp>
#include <libtorrent/torrent_status.hpp>
#include <libtorrent/version.hpp>
#include <libtorrent/write_resume_data.hpp>

#include <algorithm>
#include <cctype>
#include <chrono>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <map>
#include <string>
#include <utility>
#include <vector>

namespace {

// ── JSON 输出helpers ────────────────────────────────────────────────

// 把 [s] 以 JSON 字符串字面量（不含引号）追加到 [out]，转义控制字符。
// 非 ASCII 的 UTF-8 字节原样通过（合法 JSON）。
void append_json_escaped(std::string& out, const std::string& s) {
  for (const char c : s) {
    switch (c) {
      case '"': out += "\\\""; break;
      case '\\': out += "\\\\"; break;
      case '\b': out += "\\b"; break;
      case '\f': out += "\\f"; break;
      case '\n': out += "\\n"; break;
      case '\r': out += "\\r"; break;
      case '\t': out += "\\t"; break;
      default:
        if (static_cast<unsigned char>(c) < 0x20) {
          char buf[8];
          std::snprintf(buf, sizeof(buf), "\\u%04x", c);
          out += buf;
        } else {
          out += c;
        }
    }
  }
}

void append_json_str_field(std::string& out, const char* key,
                           const std::string& value) {
  out += '"';
  out += key;
  out += "\":\"";
  append_json_escaped(out, value);
  out += '"';
}

// std::string → malloc 拷贝（Dart 侧用完 ht_free_string 释放）。
char* dup_string(const std::string& s) {
  char* p = static_cast<char*>(std::malloc(s.size() + 1));
  if (p == nullptr) return nullptr;
  std::memcpy(p, s.c_str(), s.size() + 1);
  return p;
}

char* json_error(const std::string& message) {
  std::string out = "{\"ok\":false,";
  append_json_str_field(out, "error", message);
  out += '}';
  return dup_string(out);
}

char* json_ok_id(const std::string& id) {
  std::string out = "{\"ok\":true,";
  append_json_str_field(out, "id", id);
  out += '}';
  return dup_string(out);
}

// ── libtorrent helpers ──────────────────────────────────────────────

// 一条 piece 完成事件（收割后待 ht_poll_piece_events 取走）。
struct PieceEvent {
  std::string id;
  int piece;
};

// piece 事件队列上限（超出丢**最旧**的）。
//
// 必须有上限：生产端只有边下边播/测试才会调 ht_poll_piece_events，而
// ht_save_resume_data 每分钟也会 drain 一次 —— 没有消费者时队列会无限涨。
// 语义与 libtorrent 自身的 alert_queue_size 溢出丢弃一致：piece 事件是
// 「进度提示」，丢了不影响正确性（真相在 ht_torrent_pieces 的位图里）。
constexpr std::size_t kMaxQueuedPieceEvents = 4096;

// TODO-1961-c：一次异步存储操作（改名 / 移动）的回执槽。
//
// `pending` 是「已发出、还没回执」；`ok` 只有在 `pending == 0` 时才有意义。
// `detail` 成功时装新路径（move）、失败时装引擎给的错误串 —— 失败原因必须原样
// 带回 Dart，不能吞成一个光秃秃的 false（用户要知道是「目标已存在」还是
// 「权限不足」）。
struct StorageOp {
  int pending = 0;
  bool ok = false;
  std::string detail;
  lt::torrent_handle handle;
  int file_index = -1;

  bool arm(lt::torrent_handle target, int index = -1) {
    // 超时只代表调用方不再等，不代表 libtorrent 已取消操作。迟到 alert 在被
    // drain 之前必须继续占着槽；否则下一次调用会把它误认成自己的回执。
    if (pending > 0) return false;
    pending = 1;
    ok = false;
    detail.clear();
    handle = std::move(target);
    file_index = index;
    return true;
  }

  void settle(bool success, std::string message) {
    if (pending <= 0) return;
    pending = 0;
    ok = success;
    detail = std::move(message);
  }
};

// session 句柄的真身：拥有 lt::session + 已收割待取的 alert 队列。
//
// TODO-1961-b：为什么必须有队列 —— `pop_alerts` 是**破坏性**的（取走即从
// libtorrent 内部消失）。以前只有 ht_poll_piece_events 一个消费者，它 pop 完
// 把非 piece 的 alert 全丢掉，看起来「无状态」；一旦再有第二个消费者
// （resume data 的完成信号），两个消费者就会互相吃掉对方的事件，且丢失是静默
// 的。正解不是加第二个 pop 点，而是**一个 session 只有一个收割点**
// （[drain_alerts]），收割后按类型分派进各自队列，各 poll 函数只读自己的队列。
struct ht_session_ctx {
  explicit ht_session_ctx(lt::settings_pack sp) : ses(std::move(sp)) {}

  lt::session ses;

  // 已收割待取的 piece 完成事件。
  std::vector<PieceEvent> pieces;

  // 已收割的 resume data（infohash → bencode 后的字节）。
  std::vector<std::pair<std::string, std::vector<char>>> resumes;

  // 已发出 save_resume_data 但尚未收到回执的种子数（收齐即可停止等待）。
  int resume_pending = 0;

  // 本轮 save_resume_data 失败的个数（诊断用，随每轮保存清零）。
  int resume_failed = 0;

  // TODO-1961-c：改名 / 移动的回执槽。两者都是**异步**的：调用只是把请求排进
  // libtorrent，成没成只能从 file_renamed_alert / file_rename_failed_alert /
  // storage_moved_alert / storage_moved_failed_alert 得知。同一时刻只允许一个
  // 在飞（Dart 侧是同步 FFI 调用，天然串行），故一个槽足够，不必建队列。
  StorageOp rename_op;
  StorageOp move_op;

  // ── TODO-2482：会话统计快照（drain_alerts 收割，ht_session_status 读）──

  // 最近一次 dht_stats_alert 的路由表节点总数（-1 = 尚未收到过）。
  int dht_nodes = -1;

  // 最近一次 session_stats_alert 的累计收发字节（-1 = 尚未采样过）与采样
  // 时刻；相邻两次采样差分出会话级速率（含协议开销，正是「session 级」
  // 想要的口径）。
  std::int64_t last_recv_bytes = -1;
  std::int64_t last_sent_bytes = -1;
  lt::clock_type::time_point last_stats_at{};
  int down_rate = -1;
  int up_rate = -1;

  // 一次端口映射回执（portmap_alert / portmap_error_alert）。
  struct PortMapResult {
    bool ok = false;
    int external_port = 0;
    std::string error;
  };

  // (transport, protocol) → 最近一次回执。error 回执不带协议，protocol 记
  // -1。条目表达「最近状态」：同键覆盖；此外**同 transport 的成功回执会
  // 删掉该 transport 的失败条目**（TODO-2526）—— 失败键 (transport,-1) 与
  // 成功键 (transport,proto) 不同，光靠覆盖清不掉，一次瞬时失败会在详情
  // 页永久残留一条陈旧失败行。
  std::map<std::pair<int, int>, PortMapResult> portmaps;

  // TODO-2526：drain_alerts 收到 file_prio_alert 的累计数。
  // ht_set_file_priority 用它有界等待「文件优先级已在磁盘线程落地」的回执
  // （回执处理里会重放首尾提优），保证函数返回时重放已排队。
  std::uint64_t file_prio_events = 0;
};

ht_session_ctx* as_ctx(void* session) {
  return static_cast<ht_session_ctx*>(session);
}

// 兼容既有 21 处调用点：它们只要 lt::session*。
lt::session* as_session(void* session) {
  return session == nullptr ? nullptr : &as_ctx(session)->ses;
}

// 种子身份：v1 sha1 优先、纯 v2 用截断 sha256（与 magnet btih 一致）。
// 手写 hex（lt::aux::to_hex 是内部符号，DLL 构建下不导出）。
std::string best_hash_hex(const lt::info_hash_t& ih) {
  static const char kHex[] = "0123456789abcdef";
  const lt::sha1_hash h = ih.get_best();
  std::string out;
  out.reserve(std::size_t(h.size()) * 2);
  for (const char byte : h) {
    const unsigned char b = static_cast<unsigned char>(byte);
    out += kHex[b >> 4];
    out += kHex[b & 0x0f];
  }
  return out;
}

// 首尾 piece 提优公共实现（起播优化，qb firstLastPiecePrio 等价物）。
// **跳过 priority=0（不下载）的文件**：对已跳过文件的首尾块提优等于强制
// 下载用户明确不要的内容（TODO-2526 复核点名的陷阱）。
// 返回 1 = 已应用、0 = 元数据未就绪。
int apply_first_last_boost(lt::torrent_handle& h) {
  std::shared_ptr<const lt::torrent_info> ti = h.torrent_file();
  if (!ti) return 0;
  const lt::file_storage& fs = ti->files();
  const std::int64_t piece_len = ti->piece_length();
  if (piece_len <= 0) return 0;
  const std::vector<lt::download_priority_t> file_prios =
      h.get_file_priorities();
  for (int i = 0; i < ti->num_files(); ++i) {
    const lt::file_index_t idx(i);
    if (std::size_t(i) < file_prios.size() &&
        file_prios[std::size_t(i)] == lt::dont_download) {
      continue;
    }
    const std::int64_t size = fs.file_size(idx);
    if (size <= 0) continue;
    const std::int64_t offset = fs.file_offset(idx);
    const int first = int(offset / piece_len);
    const int last = int((offset + size - 1) / piece_len);
    h.piece_priority(lt::piece_index_t(first), lt::top_priority);
    h.piece_priority(lt::piece_index_t(last), lt::top_priority);
  }
  return 1;
}

// **唯一**的 alert 收割点：pop 一次，按类型分派进 ctx 的各队列，其余丢弃。
// 任何需要 alert 的入口都只调它，绝不自己 pop_alerts（理由见 ht_session_ctx）。
void drain_alerts(ht_session_ctx* ctx) {
  if (ctx == nullptr) return;
  std::vector<lt::alert*> alerts;
  ctx->ses.pop_alerts(&alerts);
  for (const lt::alert* a : alerts) {
    if (const auto* pf = lt::alert_cast<lt::piece_finished_alert>(a)) {
      if (pf->handle.is_valid()) {
        // 队列满了先丢最旧的，保证「没有消费者」时占用有上限。
        if (ctx->pieces.size() >= kMaxQueuedPieceEvents) {
          ctx->pieces.erase(ctx->pieces.begin());
        }
        ctx->pieces.push_back(PieceEvent{
            best_hash_hex(pf->handle.info_hashes()), int(pf->piece_index)});
      }
      continue;
    }
    if (const auto* sr = lt::alert_cast<lt::save_resume_data_alert>(a)) {
      if (ctx->resume_pending > 0) ctx->resume_pending--;
      ctx->resumes.emplace_back(best_hash_hex(sr->params.info_hashes),
                                lt::write_resume_data_buf(sr->params));
      continue;
    }
    if (lt::alert_cast<lt::save_resume_data_failed_alert>(a) != nullptr) {
      if (ctx->resume_pending > 0) ctx->resume_pending--;
      ctx->resume_failed++;
      continue;
    }
    // TODO-1961-c：改名 / 移动的回执。
    if (const auto* fr = lt::alert_cast<lt::file_renamed_alert>(a)) {
      if (ctx->rename_op.pending > 0 &&
          ctx->rename_op.handle == fr->handle &&
          ctx->rename_op.file_index == int(fr->index)) {
        ctx->rename_op.settle(true, fr->new_name());
      }
      continue;
    }
    if (const auto* rf = lt::alert_cast<lt::file_rename_failed_alert>(a)) {
      if (ctx->rename_op.pending > 0 &&
          ctx->rename_op.handle == rf->handle &&
          ctx->rename_op.file_index == int(rf->index)) {
        ctx->rename_op.settle(false, rf->error.message());
      }
      continue;
    }
    if (const auto* sm = lt::alert_cast<lt::storage_moved_alert>(a)) {
      if (ctx->move_op.pending > 0 && ctx->move_op.handle == sm->handle) {
        ctx->move_op.settle(true, sm->storage_path());
      }
      continue;
    }
    if (const auto* mf = lt::alert_cast<lt::storage_moved_failed_alert>(a)) {
      if (ctx->move_op.pending > 0 && ctx->move_op.handle == mf->handle) {
        ctx->move_op.settle(false, mf->error.message());
      }
      continue;
    }
    // TODO-2482：会话统计（ht_session_status 的数据面）。
    if (const auto* ds = lt::alert_cast<lt::dht_stats_alert>(a)) {
      int nodes = 0;
      for (const lt::dht_routing_bucket& b : ds->routing_table) {
        nodes += b.num_nodes;
      }
      ctx->dht_nodes = nodes;
      continue;
    }
    if (const auto* ss = lt::alert_cast<lt::session_stats_alert>(a)) {
      // metric 下标在同一 libtorrent 版本内恒定，查一次缓存住。
      static const int recv_idx = lt::find_metric_idx("net.recv_bytes");
      static const int sent_idx = lt::find_metric_idx("net.sent_bytes");
      const auto counters = ss->counters();
      if (recv_idx >= 0 && sent_idx >= 0 &&
          recv_idx < int(counters.size()) && sent_idx < int(counters.size())) {
        const std::int64_t recv = counters[recv_idx];
        const std::int64_t sent = counters[sent_idx];
        const lt::clock_type::time_point now = ss->timestamp();
        if (ctx->last_recv_bytes >= 0) {
          const std::int64_t dt_ms =
              std::chrono::duration_cast<std::chrono::milliseconds>(
                  now - ctx->last_stats_at)
                  .count();
          if (dt_ms > 0) {
            const std::int64_t down =
                (recv - ctx->last_recv_bytes) * 1000 / dt_ms;
            const std::int64_t up = (sent - ctx->last_sent_bytes) * 1000 / dt_ms;
            ctx->down_rate = down > 0 ? int(down) : 0;
            ctx->up_rate = up > 0 ? int(up) : 0;
          }
        }
        ctx->last_recv_bytes = recv;
        ctx->last_sent_bytes = sent;
        ctx->last_stats_at = now;
      }
      continue;
    }
    if (const auto* fp = lt::alert_cast<lt::file_prio_alert>(a)) {
      // TODO-2526：文件优先级在磁盘线程落地后的完成回执。libtorrent 随
      // 落地按新文件优先级重算该文件覆盖的 piece 优先级，会把首尾提优
      // （起播优化）冲掉 —— 收到回执说明重算已发生，在这里重放。
      // 无条件重放（不查「这个种子是否开过 firstLastPiecePrio」）：宿主
      // 所有 add 路径一律开启该开关，桥不为不存在的组合维护 per-torrent
      // 状态；helper 自己会跳过 priority=0 的文件（含刚设为 0 的），
      // 不会强制下载用户已跳过的内容。
      ctx->file_prio_events++;
      if (fp->handle.is_valid()) {
        lt::torrent_handle h = fp->handle;
        apply_first_last_boost(h);
      }
      continue;
    }
    if (const auto* pm = lt::alert_cast<lt::portmap_alert>(a)) {
      // 成功 = 该 transport 的映射已恢复；把它此前的失败条目（键
      // (transport,-1)，见 portmaps 注释）一并清掉，否则永久残留。
      ctx->portmaps.erase({int(pm->map_transport), -1});
      ctx->portmaps[{int(pm->map_transport), int(pm->map_protocol)}] =
          ht_session_ctx::PortMapResult{true, pm->external_port, std::string()};
      continue;
    }
    if (const auto* pe = lt::alert_cast<lt::portmap_error_alert>(a)) {
      // error 回执不带协议，协议位记 -1（JSON 侧导出为空串）。
      ctx->portmaps[{int(pe->map_transport), -1}] =
          ht_session_ctx::PortMapResult{false, 0, pe->error.message()};
      continue;
    }
  }
}

// 等一个异步存储操作落地（或超时）。挂在 wait_for_alert 上，**不** sleep 轮询。
// 返回 true = 已落地（成没成看 op.ok）；false = 超时。
bool await_storage_op(ht_session_ctx* ctx, const StorageOp& op, int timeout_ms) {
  const int budget_ms = timeout_ms > 0 ? timeout_ms : 15000;
  const std::chrono::steady_clock::time_point deadline =
      std::chrono::steady_clock::now() + std::chrono::milliseconds(budget_ms);
  while (op.pending > 0) {
    const std::chrono::steady_clock::time_point now =
        std::chrono::steady_clock::now();
    if (now >= deadline) return false;
    ctx->ses.wait_for_alert(
        std::chrono::duration_cast<lt::time_duration>(deadline - now));
    drain_alerts(ctx);
  }
  return true;
}

// 按小写十六进制 infohash 找种子；找不到返回无效 handle。
lt::torrent_handle find_torrent(lt::session* ses, const char* info_hash) {
  if (ses == nullptr || info_hash == nullptr) return {};
  const std::string want(info_hash);
  for (const lt::torrent_handle& h : ses->get_torrents()) {
    if (h.is_valid() && best_hash_hex(h.info_hashes()) == want) return h;
  }
  return {};
}

const char* state_label(const lt::torrent_status& st) {
  if (st.errc) return "error";
  switch (st.state) {
    case lt::torrent_status::checking_files:
    case lt::torrent_status::checking_resume_data:
      return "checking";
    case lt::torrent_status::downloading_metadata:
      return "metadata";
    case lt::torrent_status::downloading:
      return "downloading";
    case lt::torrent_status::finished:
      return "finished";
    case lt::torrent_status::seeding:
      return "seeding";
    default:
      return "downloading";
  }
}

// 内容根路径：qb 语义 —— 单文件种子 = 文件路径、多文件 = 内容根目录。
// 元数据未就绪返回空串。分隔符统一 '/'（Windows API/Dart 双兼容）。
std::string content_path_of(const lt::torrent_status& st,
                            const lt::torrent_handle& h) {
  std::shared_ptr<const lt::torrent_info> ti = h.torrent_file();
  if (!ti) return std::string();
  std::string root = st.save_path;
  if (!root.empty() && root.back() != '/' && root.back() != '\\') root += '/';
  if (ti->num_files() == 1) {
    return root + ti->files().file_path(lt::file_index_t(0));
  }
  return root + ti->name();
}

// 磁力/.torrent 添加共用尾段：设 save_path/flags、入 session、返回 JSON。
char* add_with_params(lt::session* ses, lt::add_torrent_params params,
                      const char* save_path, int sequential) {
  params.save_path = save_path != nullptr ? save_path : "";
  if (params.save_path.empty()) return json_error("save_path is empty");
  if (sequential != 0) params.flags |= lt::torrent_flags::sequential_download;
  // add 即启动：默认旗标带 paused，起始瞬间会丢弃 connect_peer 且无
  // tracker/DHT 时无从再发现 peer；本引擎的 add 语义就是「开始下载」。
  params.flags &= ~lt::torrent_flags::paused;
  // BUG-1293：upload_mode = 「只上不下」（停止下载）。旧版本误用它表达
  // 「关上传」，用户的 resume/重复 add 参数里可能带着残留，进来一律清掉。
  params.flags &= ~lt::torrent_flags::upload_mode;
  lt::error_code ec;
  lt::torrent_handle h = ses->add_torrent(std::move(params), ec);
  if (ec == lt::errors::duplicate_torrent && h.is_valid()) {
    return json_ok_id(best_hash_hex(h.info_hashes()));
  }
  if (ec) return json_error(ec.message());
  if (!h.is_valid()) return json_error("add_torrent returned invalid handle");
  return json_ok_id(best_hash_hex(h.info_hashes()));
}

}  // namespace

extern "C" {

HT_EXPORT const char* ht_libtorrent_version(void) {
  // lt::version() 返回指向静态存储的 C 字符串，跨 FFI 边界安全、无需释放。
  return lt::version();
}

HT_EXPORT void* ht_session_create(const char* listen_interfaces,
                                  int enable_dht) {
  try {
    lt::settings_pack sp;
    const std::string listen =
        listen_interfaces != nullptr ? listen_interfaces : "";
    // 空串 = 不绑定/监听任何端口（阶段1a 空壳语义，零网络副作用）。
    sp.set_str(lt::settings_pack::listen_interfaces, listen);
    sp.set_bool(lt::settings_pack::enable_dht, enable_dht != 0);
    // 发现协议按阶段1b范围保持关闭；后续阶段随设置开放。
    sp.set_bool(lt::settings_pack::enable_lsd, false);
    sp.set_bool(lt::settings_pack::enable_upnp, false);
    sp.set_bool(lt::settings_pack::enable_natpmp, false);
    // piece 完成事件（下载顺序证据/边下边播缓冲）+ 状态/错误告警 +
    // storage（save_resume_data_alert 属此类，TODO-1961-a 的完成信号）。
    // port_mapping：UPnP/NAT-PMP 映射回执（TODO-2482 ht_session_status）。
    sp.set_int(lt::settings_pack::alert_mask,
               lt::alert_category::status | lt::alert_category::error |
                   lt::alert_category::piece_progress |
                   lt::alert_category::storage |
                   lt::alert_category::port_mapping);
    return new ht_session_ctx(std::move(sp));
  } catch (...) {
    return nullptr;
  }
}

HT_EXPORT void ht_session_destroy(void* session) {
  delete as_ctx(session);
}

HT_EXPORT int ht_session_listen_port(void* session) {
  if (session == nullptr) return 0;
  try {
    return int(as_session(session)->listen_port());
  } catch (...) {
    return 0;
  }
}

HT_EXPORT int ht_session_set_rate_limits(void* session, int download_bps,
                                         int upload_bps) {
  if (session == nullptr) return 0;
  try {
    lt::settings_pack sp;
    sp.set_int(lt::settings_pack::download_rate_limit,
               download_bps > 0 ? download_bps : 0);
    sp.set_int(lt::settings_pack::upload_rate_limit,
               upload_bps > 0 ? upload_bps : 0);
    as_session(session)->apply_settings(std::move(sp));
    return 1;
  } catch (...) {
    return 0;
  }
}

// ht_apply_limits / ht_apply_limits_ex 的共用实现。
//
// [limit_local_peers] 为真时，把同一组速率上限套到 libtorrent 的 **local peer
// class**（内置 class id 2，局域网/链路本地/回环 peer 归属它）。这是必须的：
// libtorrent 文档明写「download_rate_limit/upload_rate_limit 设的是 session
// 全局上限，**默认局域网 peer 不受限速**；要让限速也作用于本地 peer，见
// peer-classes」。旧的 settings_pack::local_*_rate_limit /
// ignore_limits_on_local_network 在 2.x 已废弃，peer class 是唯一正规入口。
//
// 为假时把该 class 的上下行上限写回 0（= 不限），即 libtorrent 的出厂默认，
// 从而「关掉开关」能真正还原原始行为，而不是留着上一次的限速。
//
// 注意 set_peer_class() 是**整体覆盖**（无单字段更新），所以必须先
// get_peer_class 拿到现值，只改两个 rate 字段再写回——否则会把 local class
// 的 ignore_unchoke_slots / connection_limit_factor 等默认值一起抹掉。
static int ht_apply_limits_impl(void* session, int download_bps, int upload_bps,
                                int connections_limit, bool limit_local_peers) {
  if (session == nullptr) return 0;
  try {
    const int download_limit = download_bps > 0 ? download_bps : 0;
    const int upload_limit = upload_bps > 0 ? upload_bps : 0;

    lt::settings_pack sp;
    sp.set_int(lt::settings_pack::download_rate_limit, download_limit);
    sp.set_int(lt::settings_pack::upload_rate_limit, upload_limit);
    // <=0 时不动 connections_limit（保持 libtorrent 默认），避免把用户
    // "不限"误设成 0（0 会禁止所有连接）。
    if (connections_limit > 0) {
      sp.set_int(lt::settings_pack::connections_limit, connections_limit);
    }
    lt::session* const ses = as_session(session);
    ses->apply_settings(std::move(sp));

    lt::peer_class_info pci =
        ses->get_peer_class(lt::session::local_peer_class_id);
    pci.download_limit = limit_local_peers ? download_limit : 0;
    pci.upload_limit = limit_local_peers ? upload_limit : 0;
    ses->set_peer_class(lt::session::local_peer_class_id, pci);
    return 1;
  } catch (...) {
    return 0;
  }
}

HT_EXPORT int ht_apply_limits(void* session, int download_bps, int upload_bps,
                              int connections_limit) {
  // 历史入口，语义不变：局域网 peer 不受限速（libtorrent 出厂默认）。
  return ht_apply_limits_impl(session, download_bps, upload_bps,
                              connections_limit, false);
}

HT_EXPORT int ht_apply_limits_ex(void* session, int download_bps,
                                 int upload_bps, int connections_limit,
                                 int limit_local_peers) {
  return ht_apply_limits_impl(session, download_bps, upload_bps,
                              connections_limit, limit_local_peers != 0);
}

HT_EXPORT int ht_apply_memory_settings(void* session, int connections_limit,
                                       int max_queued_disk_bytes,
                                       int send_buffer_watermark,
                                       int max_peerlist_size) {
  if (session == nullptr) return 0;
  try {
    lt::settings_pack sp;
    if (connections_limit > 0) {
      sp.set_int(lt::settings_pack::connections_limit, connections_limit);
    }
    if (max_queued_disk_bytes > 0) {
      sp.set_int(lt::settings_pack::max_queued_disk_bytes,
                 max_queued_disk_bytes);
    }
    if (send_buffer_watermark > 0) {
      sp.set_int(lt::settings_pack::send_buffer_watermark,
                 send_buffer_watermark);
    }
    if (max_peerlist_size > 0) {
      sp.set_int(lt::settings_pack::max_peerlist_size, max_peerlist_size);
    }
    as_session(session)->apply_settings(std::move(sp));
    return 1;
  } catch (...) {
    return 0;
  }
}

HT_EXPORT int ht_apply_session_settings(
    void* session, int listen_port, int enable_dht, int enable_lsd,
    int enable_upnp, int enable_natpmp, int enc_policy, int anonymous_mode,
    int active_downloads, int active_seeds, int max_upload_slots) {
  if (session == nullptr) return 0;
  try {
    lt::settings_pack sp;
    if (listen_port > 0) {
      const std::string port = std::to_string(listen_port);
      sp.set_str(lt::settings_pack::listen_interfaces,
                 "0.0.0.0:" + port + ",[::]:" + port);
    }
    sp.set_bool(lt::settings_pack::enable_dht, enable_dht != 0);
    sp.set_bool(lt::settings_pack::enable_lsd, enable_lsd != 0);
    sp.set_bool(lt::settings_pack::enable_upnp, enable_upnp != 0);
    sp.set_bool(lt::settings_pack::enable_natpmp, enable_natpmp != 0);
    // config 0=首选/1=强制/2=禁用 → libtorrent enc_policy 枚举。
    const int policy = enc_policy == 1
        ? lt::settings_pack::pe_forced
        : (enc_policy == 2 ? lt::settings_pack::pe_disabled
                           : lt::settings_pack::pe_enabled);
    sp.set_int(lt::settings_pack::out_enc_policy, policy);
    sp.set_int(lt::settings_pack::in_enc_policy, policy);
    sp.set_bool(lt::settings_pack::anonymous_mode, anonymous_mode != 0);
    if (active_downloads > 0) {
      sp.set_int(lt::settings_pack::active_downloads, active_downloads);
    }
    if (active_seeds > 0) {
      sp.set_int(lt::settings_pack::active_seeds, active_seeds);
    }
    if (max_upload_slots > 0) {
      sp.set_int(lt::settings_pack::unchoke_slots_limit, max_upload_slots);
    }
    as_session(session)->apply_settings(std::move(sp));
    return 1;
  } catch (...) {
    return 0;
  }
}

HT_EXPORT int ht_set_upload_mode(void* session, const char* info_hash,
                                 int upload_enabled) {
  if (session == nullptr) return 0;
  try {
    // BUG-1293：torrent_flags::upload_mode 的 libtorrent 语义是「不再发出任何
    // piece 请求」= 只上不下（磁盘写失败时引擎自己会置它以停止下载保做种），
    // 与旧实现宣称的「只下不上」正好相反 —— 置上它 = 掐死下载。
    // 因此本函数：允许上传时**清除**该 flag（治愈历史 resume/旧版本留下的
    // 残留）；禁止上传时 no-op 恒成功（正确原语是 ht_set_unchoke_slots /
    // ht_pause_torrent，旧 Dart 调进来时宁可继续上传也绝不掐死下载）。
    const bool allow = upload_enabled != 0;
    const auto apply = [allow](lt::torrent_handle h) {
      if (!h.is_valid()) return;
      if (allow) h.unset_flags(lt::torrent_flags::upload_mode);
    };
    const bool all = info_hash == nullptr || info_hash[0] == '\0';
    if (all) {
      for (lt::torrent_handle h : as_session(session)->get_torrents()) {
        apply(h);
      }
      return 1;
    }
    lt::torrent_handle h = find_torrent(as_session(session), info_hash);
    if (!h.is_valid()) return 0;
    apply(h);
    return 1;
  } catch (...) {
    return 0;
  }
}

HT_EXPORT int ht_set_unchoke_slots(void* session, int slots) {
  if (session == nullptr) return 0;
  try {
    lt::settings_pack sp;
    if (slots < 0) {
      sp.set_int(lt::settings_pack::unchoke_slots_limit,
                 lt::default_settings().get_int(
                     lt::settings_pack::unchoke_slots_limit));
    } else {
      // 0 = 不给任何 peer unchoke 槽位 = 会话级停止上传 payload。我们发出的
      // piece 请求是协议消息、不占 unchoke 槽，下载不受影响（BUG-1293 的
      // 「关上传」正确原语；upload_mode 是反的，见 ht_set_upload_mode）。
      sp.set_int(lt::settings_pack::unchoke_slots_limit, slots);
    }
    as_session(session)->apply_settings(std::move(sp));
    return 1;
  } catch (...) {
    return 0;
  }
}

HT_EXPORT int ht_pause_torrent(void* session, const char* info_hash,
                               int pause) {
  if (session == nullptr) return 0;
  try {
    const bool want_pause = pause != 0;
    const auto apply = [want_pause](lt::torrent_handle h) {
      if (!h.is_valid()) return;
      if (want_pause) {
        // auto_managed 的种子会被队列管理器自动 resume，必须先清。
        h.unset_flags(lt::torrent_flags::auto_managed);
        h.pause();
      } else {
        h.set_flags(lt::torrent_flags::auto_managed);
        h.resume();
      }
    };
    const bool all = info_hash == nullptr || info_hash[0] == '\0';
    if (all) {
      for (lt::torrent_handle h : as_session(session)->get_torrents()) {
        apply(h);
      }
      return 1;
    }
    lt::torrent_handle h = find_torrent(as_session(session), info_hash);
    if (!h.is_valid()) return 0;
    apply(h);
    return 1;
  } catch (...) {
    return 0;
  }
}

HT_EXPORT char* ht_add_magnet(void* session, const char* magnet_uri,
                              const char* save_path, int sequential) {
  if (session == nullptr) return json_error("session is null");
  if (magnet_uri == nullptr) return json_error("magnet_uri is null");
  try {
    lt::error_code ec;
    lt::add_torrent_params params = lt::parse_magnet_uri(magnet_uri, ec);
    if (ec) return json_error(std::string("bad magnet: ") + ec.message());
    return add_with_params(as_session(session), std::move(params), save_path,
                           sequential);
  } catch (const std::exception& e) {
    return json_error(e.what());
  } catch (...) {
    return json_error("unknown error in ht_add_magnet");
  }
}

HT_EXPORT char* ht_add_torrent_file(void* session, const char* torrent_path,
                                    const char* save_path, int sequential) {
  if (session == nullptr) return json_error("session is null");
  if (torrent_path == nullptr) return json_error("torrent_path is null");
  try {
    lt::error_code ec;
    auto ti = std::make_shared<lt::torrent_info>(std::string(torrent_path), ec);
    if (ec) return json_error(std::string("bad torrent file: ") + ec.message());
    lt::add_torrent_params params;
    params.ti = std::move(ti);
    return add_with_params(as_session(session), std::move(params), save_path,
                           sequential);
  } catch (const std::exception& e) {
    return json_error(e.what());
  } catch (...) {
    return json_error("unknown error in ht_add_torrent_file");
  }
}

HT_EXPORT char* ht_make_torrent(const char* content_path,
                                const char* out_torrent_path) {
  if (content_path == nullptr || out_torrent_path == nullptr) {
    return json_error("content_path/out_torrent_path is null");
  }
  try {
    lt::file_storage fs;
    lt::add_files(fs, content_path);
    if (fs.num_files() == 0) return json_error("no files under content_path");
    lt::create_torrent ct(fs);
    // set_piece_hashes 的第二参是内容父目录（file_storage 内是相对路径）。
    const std::filesystem::path parent =
        std::filesystem::u8path(content_path).parent_path();
    lt::error_code ec;
    lt::set_piece_hashes(ct, parent.u8string(), ec);
    if (ec) return json_error(std::string("hashing failed: ") + ec.message());

    std::vector<char> buf;
    lt::bencode(std::back_inserter(buf), ct.generate());
    std::ofstream out(std::filesystem::u8path(out_torrent_path),
                      std::ios::binary | std::ios::trunc);
    if (!out) return json_error("cannot open out_torrent_path for write");
    out.write(buf.data(), std::streamsize(buf.size()));
    out.close();
    if (!out) return json_error("failed writing torrent file");

    const lt::torrent_info ti(buf, lt::from_span);
    return json_ok_id(best_hash_hex(ti.info_hashes()));
  } catch (const std::exception& e) {
    return json_error(e.what());
  } catch (...) {
    return json_error("unknown error in ht_make_torrent");
  }
}

HT_EXPORT int ht_connect_peer(void* session, const char* info_hash,
                              const char* ip, int port) {
  if (session == nullptr || ip == nullptr || port <= 0 || port > 65535) {
    return 0;
  }
  try {
    lt::torrent_handle h = find_torrent(as_session(session), info_hash);
    if (!h.is_valid()) return 0;
    lt::error_code ec;
    const auto addr = lt::make_address(ip, ec);
    if (ec) return 0;
    h.connect_peer(lt::tcp::endpoint(addr, std::uint16_t(port)));
    return 1;
  } catch (...) {
    return 0;
  }
}

HT_EXPORT char* ht_list_torrents(void* session) {
  if (session == nullptr) return dup_string("[]");
  try {
    std::string out = "[";
    bool first = true;
    for (const lt::torrent_handle& h : as_session(session)->get_torrents()) {
      if (!h.is_valid()) continue;
      const lt::torrent_status st = h.status();
      if (!first) out += ',';
      first = false;
      out += '{';
      append_json_str_field(out, "id", best_hash_hex(st.info_hashes));
      out += ',';
      append_json_str_field(out, "name", st.name);
      out += ",\"progress\":" + std::to_string(st.progress);
      out += ',';
      append_json_str_field(out, "state", state_label(st));
      out += ',';
      append_json_str_field(out, "save_path", st.save_path);
      out += ',';
      append_json_str_field(out, "content_path", content_path_of(st, h));
      out += ",\"total\":" + std::to_string(st.total_wanted);
      out += ",\"done\":" + std::to_string(st.total_wanted_done);
      // 元数据未就绪时 total_wanted=0，剩余量未知 → -1（Dart 侧不当完成）。
      const std::int64_t left =
          st.has_metadata ? st.total_wanted - st.total_wanted_done
                          : std::int64_t(-1);
      out += ",\"left\":" + std::to_string(left);
      out += ",\"down_rate\":" + std::to_string(st.download_payload_rate);
      out += ",\"up_rate\":" + std::to_string(st.upload_payload_rate);
      // 累计上传/下载字节（做种时长/分享率上限判定，见 Dart 侧 host tick）。
      out += ",\"uploaded\":" + std::to_string(st.all_time_upload);
      out += ",\"downloaded\":" + std::to_string(st.all_time_download);
      out += ",\"num_peers\":" + std::to_string(st.num_peers);
      // TODO-2482 详情批次：连接拆分 + swarm scrape + 引擎侧暂停 + 时长。
      out += ",\"num_seeds\":" + std::to_string(st.num_seeds);
      out += ",\"num_connections\":" + std::to_string(st.num_connections);
      out += ",\"num_complete\":" + std::to_string(st.num_complete);
      out += ",\"num_incomplete\":" + std::to_string(st.num_incomplete);
      const bool paused = bool(st.flags & lt::torrent_flags::paused);
      out += std::string(",\"is_paused\":") + (paused ? "true" : "false");
      out += ",\"active_duration\":" +
             std::to_string(std::int64_t(st.active_duration.count()));
      out += ",\"seeding_duration\":" +
             std::to_string(std::int64_t(st.seeding_duration.count()));
      out += ",\"finished_duration\":" +
             std::to_string(std::int64_t(st.finished_duration.count()));
      out += std::string(",\"has_metadata\":") +
             (st.has_metadata ? "true" : "false");
      out += std::string(",\"is_finished\":") +
             (st.is_finished ? "true" : "false");
      out += std::string(",\"is_seeding\":") +
             (st.is_seeding ? "true" : "false");
      const bool sequential =
          bool(st.flags & lt::torrent_flags::sequential_download);
      out += std::string(",\"sequential\":") + (sequential ? "true" : "false");
      out += '}';
    }
    out += ']';
    return dup_string(out);
  } catch (const std::exception& e) {
    return json_error(e.what());
  } catch (...) {
    return json_error("unknown error in ht_list_torrents");
  }
}

HT_EXPORT char* ht_torrent_files(void* session, const char* info_hash) {
  if (session == nullptr) return json_error("session is null");
  try {
    lt::torrent_handle h = find_torrent(as_session(session), info_hash);
    if (!h.is_valid()) return json_error("torrent not found");
    std::shared_ptr<const lt::torrent_info> ti = h.torrent_file();
    if (!ti) return json_error("no metadata");
    const std::vector<std::int64_t> done =
        h.file_progress(lt::torrent_handle::piece_granularity);
    std::string out = "{\"ok\":true,\"files\":[";
    const lt::file_storage& fs = ti->files();
    for (int i = 0; i < ti->num_files(); ++i) {
      const lt::file_index_t idx(i);
      if (i > 0) out += ',';
      out += "{\"index\":" + std::to_string(i) + ',';
      append_json_str_field(out, "path", fs.file_path(idx));
      out += ",\"size\":" + std::to_string(fs.file_size(idx));
      const std::int64_t d =
          i < int(done.size()) ? done[std::size_t(i)] : std::int64_t(0);
      out += ",\"done\":" + std::to_string(d);
      out += '}';
    }
    out += "]}";
    return dup_string(out);
  } catch (const std::exception& e) {
    return json_error(e.what());
  } catch (...) {
    return json_error("unknown error in ht_torrent_files");
  }
}

HT_EXPORT char* ht_torrent_pieces(void* session, const char* info_hash) {
  if (session == nullptr) return json_error("session is null");
  try {
    lt::torrent_handle h = find_torrent(as_session(session), info_hash);
    if (!h.is_valid()) return json_error("torrent not found");
    const lt::torrent_status st = h.status();
    if (!st.has_metadata) return json_error("no metadata");
    std::string have;
    have.reserve(std::size_t(st.pieces.size()));
    for (int i = 0; i < st.pieces.size(); ++i) {
      have += st.pieces[lt::piece_index_t(i)] ? '1' : '0';
    }
    std::string out = "{\"ok\":true,\"num_pieces\":";
    out += std::to_string(st.pieces.size());
    out += ",\"have\":\"" + have + "\"}";
    return dup_string(out);
  } catch (const std::exception& e) {
    return json_error(e.what());
  } catch (...) {
    return json_error("unknown error in ht_torrent_pieces");
  }
}

HT_EXPORT char* ht_poll_piece_events(void* session) {
  if (session == nullptr) return dup_string("[]");
  try {
    ht_session_ctx* ctx = as_ctx(session);
    // 收割一次（会把非 piece 的 alert 分派进各自队列，不再静默丢弃），
    // 然后**取走**本队列：取走即清空，语义与改造前逐字节一致。
    drain_alerts(ctx);
    std::vector<PieceEvent> events;
    events.swap(ctx->pieces);
    std::string out = "[";
    bool first = true;
    for (const PieceEvent& e : events) {
      if (!first) out += ',';
      first = false;
      out += "{";
      append_json_str_field(out, "id", e.id);
      out += ",\"piece\":" + std::to_string(e.piece) + '}';
    }
    out += ']';
    return dup_string(out);
  } catch (const std::exception& e) {
    return json_error(e.what());
  } catch (...) {
    return json_error("unknown error in ht_poll_piece_events");
  }
}

HT_EXPORT int ht_set_piece_deadline(void* session, const char* info_hash,
                                    int piece, int deadline_ms) {
  if (session == nullptr || piece < 0) return 0;
  try {
    lt::torrent_handle h = find_torrent(as_session(session), info_hash);
    if (!h.is_valid()) return 0;
    h.set_piece_deadline(lt::piece_index_t(piece), deadline_ms);
    return 1;
  } catch (...) {
    return 0;
  }
}

HT_EXPORT int ht_apply_first_last_priority(void* session,
                                           const char* info_hash) {
  if (session == nullptr) return -1;
  try {
    lt::torrent_handle h = find_torrent(as_session(session), info_hash);
    if (!h.is_valid()) return -1;
    return apply_first_last_boost(h);
  } catch (...) {
    return -1;
  }
}

namespace {

// TODO-2482：把 libtorrent 的 peer flags 重映射成**本桥自定义的稳定位掩码**
// （契约见头文件 ht_torrent_peers 注释）。不直接导出 libtorrent 内部位值：
// 那是实现细节，上游挪位（历史上发生过，如 queued 废弃）会静默改变 wire
// 含义；这里逐位显式点名，桥的契约就钉死了。
std::uint32_t stable_peer_flags(const lt::peer_info& pi) {
  std::uint32_t out = 0;
  const auto put = [&](lt::peer_flags_t bit, int shift) {
    if (pi.flags & bit) out |= std::uint32_t(1) << shift;
  };
  put(lt::peer_info::interesting, 0);
  put(lt::peer_info::choked, 1);
  put(lt::peer_info::remote_interested, 2);
  put(lt::peer_info::remote_choked, 3);
  put(lt::peer_info::supports_extensions, 4);
  put(lt::peer_info::outgoing_connection, 5);
  put(lt::peer_info::handshake, 6);
  put(lt::peer_info::connecting, 7);
  put(lt::peer_info::on_parole, 8);
  put(lt::peer_info::seed, 9);
  put(lt::peer_info::optimistic_unchoke, 10);
  put(lt::peer_info::snubbed, 11);
  put(lt::peer_info::upload_only, 12);
  put(lt::peer_info::endgame_mode, 13);
  put(lt::peer_info::holepunched, 14);
  put(lt::peer_info::utp_socket, 15);
  put(lt::peer_info::ssl_socket, 16);
  put(lt::peer_info::rc4_encrypted, 17);
  put(lt::peer_info::plaintext_encrypted, 18);
  return out;
}

// 同上：peer 来源位掩码（bit4 = fastResume，命名对齐 qb）。
std::uint32_t stable_peer_source(const lt::peer_info& pi) {
  std::uint32_t out = 0;
  const auto put = [&](lt::peer_source_flags_t bit, int shift) {
    if (pi.source & bit) out |= std::uint32_t(1) << shift;
  };
  put(lt::peer_info::tracker, 0);
  put(lt::peer_info::dht, 1);
  put(lt::peer_info::pex, 2);
  put(lt::peer_info::lsd, 3);
  put(lt::peer_info::resume_data, 4);
  put(lt::peer_info::incoming, 5);
  return out;
}

}  // namespace

HT_EXPORT char* ht_torrent_peers(void* session, const char* info_hash) {
  if (session == nullptr) return json_error("session is null");
  try {
    lt::torrent_handle h = find_torrent(as_session(session), info_hash);
    if (!h.is_valid()) return json_error("torrent not found");
    std::vector<lt::peer_info> peers;
    h.get_peer_info(peers);
    std::string out = "{\"ok\":true,\"peers\":[";
    bool first = true;
    for (const lt::peer_info& pi : peers) {
      if (!first) out += ',';
      first = false;
      out += '{';
      append_json_str_field(out, "ip", pi.ip.address().to_string());
      out += ",\"port\":" + std::to_string(pi.ip.port()) + ',';
      // peer_id：20 字节，前 8 字节常是 ASCII 客户端指纹（如 "-XL0012-"）；
      // 不可打印字节转 '.'，黑名单前缀匹配仍成立。
      std::string pid;
      pid.reserve(20);
      for (const char byte : pi.pid) {
        const unsigned char b = static_cast<unsigned char>(byte);
        pid += (b >= 0x20 && b < 0x7f) ? char(b) : '.';
      }
      append_json_str_field(out, "peer_id", pid);
      out += ',';
      append_json_str_field(out, "client", pi.client);
      out += ",\"progress\":" + std::to_string(pi.progress);
      out += ",\"total_upload\":" + std::to_string(pi.total_upload);
      out += ",\"total_download\":" + std::to_string(pi.total_download);
      out += ",\"up_speed\":" + std::to_string(pi.up_speed);
      out += ",\"down_speed\":" + std::to_string(pi.down_speed);
      out += std::string(",\"remote_interested\":") +
             (bool(pi.flags & lt::peer_info::remote_interested) ? "true"
                                                                : "false");
      // TODO-2482：详情页 Peers tab 的 flags/source 稳定位掩码。
      out += ",\"flags\":" + std::to_string(stable_peer_flags(pi));
      out += ",\"source\":" + std::to_string(stable_peer_source(pi));
      out += '}';
    }
    out += "]}";
    return dup_string(out);
  } catch (const std::exception& e) {
    return json_error(e.what());
  } catch (...) {
    return json_error("unknown error in ht_torrent_peers");
  }
}

namespace {

// "a.b.c.d/nn" / "x::y/nn" → 该 CIDR 段的 [first, last] 地址对；解析失败
// 返回 false。前缀缺省当 /32（v4）或 /128（v6）单地址。
bool cidr_range(const std::string& cidr, lt::address& first,
                lt::address& last) {
  std::string ip = cidr;
  int prefix = -1;
  const std::size_t slash = cidr.rfind('/');
  if (slash != std::string::npos) {
    ip = cidr.substr(0, slash);
    try {
      prefix = std::stoi(cidr.substr(slash + 1));
    } catch (...) {
      return false;
    }
  }
  lt::error_code ec;
  const lt::address addr = lt::make_address(ip, ec);
  if (ec) return false;
  if (addr.is_v4()) {
    if (prefix < 0 || prefix > 32) prefix = 32;
    const std::uint32_t base = addr.to_v4().to_uint();
    const std::uint32_t mask =
        prefix == 0 ? 0u : ~std::uint32_t(0) << (32 - prefix);
    first = boost::asio::ip::address_v4(base & mask);
    last = boost::asio::ip::address_v4((base & mask) | ~mask);
    return true;
  }
  if (prefix < 0 || prefix > 128) prefix = 128;
  auto bytes_first = addr.to_v6().to_bytes();
  auto bytes_last = bytes_first;
  for (int i = 0; i < 16; ++i) {
    const int bit_start = i * 8;
    if (prefix <= bit_start) {
      bytes_first[std::size_t(i)] = 0x00;
      bytes_last[std::size_t(i)] = 0xff;
    } else if (prefix < bit_start + 8) {
      const unsigned char mask =
          static_cast<unsigned char>(0xff << (bit_start + 8 - prefix));
      bytes_first[std::size_t(i)] &= mask;
      bytes_last[std::size_t(i)] |= static_cast<unsigned char>(~mask);
    }
  }
  first = boost::asio::ip::address_v6(bytes_first);
  last = boost::asio::ip::address_v6(bytes_last);
  return true;
}

}  // namespace

HT_EXPORT int ht_apply_ip_filter(void* session, const char* cidrs) {
  if (session == nullptr) return 0;
  try {
    lt::ip_filter filter;
    if (cidrs != nullptr) {
      const std::string all(cidrs);
      std::size_t pos = 0;
      while (pos <= all.size()) {
        std::size_t end = all.find('\n', pos);
        if (end == std::string::npos) end = all.size();
        std::string line = all.substr(pos, end - pos);
        // 去首尾空白（含 \r）。
        while (!line.empty() && std::isspace(
                                    static_cast<unsigned char>(line.back()))) {
          line.pop_back();
        }
        while (!line.empty() && std::isspace(static_cast<unsigned char>(
                                    line.front()))) {
          line.erase(line.begin());
        }
        if (!line.empty()) {
          lt::address first, last;
          if (cidr_range(line, first, last)) {
            filter.add_rule(first, last, lt::ip_filter::blocked);
          }
        }
        pos = end + 1;
      }
    }
    as_session(session)->set_ip_filter(filter);
    return 1;
  } catch (...) {
    return 0;
  }
}

HT_EXPORT int ht_remove_torrent(void* session, const char* info_hash,
                                int delete_files) {
  if (session == nullptr) return 0;
  try {
    lt::session* ses = as_session(session);
    lt::torrent_handle h = find_torrent(ses, info_hash);
    if (!h.is_valid()) return 0;
    ses->remove_torrent(h, delete_files != 0 ? lt::session::delete_files
                                             : lt::remove_flags_t{});
    return 1;
  } catch (...) {
    return 0;
  }
}

HT_EXPORT char* ht_rename_file(void* session, const char* info_hash,
                               int file_index, const char* new_path,
                               int timeout_ms) {
  if (session == nullptr) return json_error("session is null");
  if (new_path == nullptr || *new_path == '\0') {
    return json_error("new_path is empty");
  }
  if (file_index < 0) return json_error("file_index is negative");
  try {
    ht_session_ctx* ctx = as_ctx(session);
    lt::torrent_handle h = find_torrent(&ctx->ses, info_hash);
    if (!h.is_valid()) return json_error("torrent not found");
    if (!h.torrent_file()) return json_error("no metadata");

    // 先把之前可能残留的回执清掉再发，避免读到上一次的结果。
    drain_alerts(ctx);
    if (!ctx->rename_op.arm(h, file_index)) {
      return json_error("previous rename is still pending");
    }
    h.rename_file(lt::file_index_t(file_index), std::string(new_path));
    if (!await_storage_op(ctx, ctx->rename_op, timeout_ms)) {
      return json_error("rename timed out");
    }
    if (!ctx->rename_op.ok) return json_error(ctx->rename_op.detail);
    std::string out = "{\"ok\":true,";
    append_json_str_field(out, "path", ctx->rename_op.detail);
    out += '}';
    return dup_string(out);
  } catch (const std::exception& e) {
    return json_error(e.what());
  } catch (...) {
    return json_error("unknown error in ht_rename_file");
  }
}

HT_EXPORT char* ht_move_storage(void* session, const char* info_hash,
                                const char* new_save_path, int timeout_ms) {
  if (session == nullptr) return json_error("session is null");
  if (new_save_path == nullptr || *new_save_path == '\0') {
    return json_error("new_save_path is empty");
  }
  try {
    ht_session_ctx* ctx = as_ctx(session);
    lt::torrent_handle h = find_torrent(&ctx->ses, info_hash);
    if (!h.is_valid()) return json_error("torrent not found");

    drain_alerts(ctx);
    if (!ctx->move_op.arm(h)) {
      return json_error("previous move is still pending");
    }
    // fail_if_exist：目标已有同名文件就**整体失败**，绝不覆盖用户数据、也绝不
    // 「跳过已存在的、搬走其余的」留下半个内容目录。用户拿到明确错误后自己决定
    // （libtorrent 的默认 always_replace_files 会直接覆盖，对用户数据太危险）。
    h.move_storage(std::string(new_save_path), lt::move_flags_t::fail_if_exist);
    if (!await_storage_op(ctx, ctx->move_op, timeout_ms)) {
      return json_error("move timed out");
    }
    if (!ctx->move_op.ok) return json_error(ctx->move_op.detail);
    std::string out = "{\"ok\":true,";
    append_json_str_field(out, "path", ctx->move_op.detail);
    out += '}';
    return dup_string(out);
  } catch (const std::exception& e) {
    return json_error(e.what());
  } catch (...) {
    return json_error("unknown error in ht_move_storage");
  }
}

HT_EXPORT char* ht_save_resume_data(void* session, const char* out_dir,
                                    int timeout_ms) {
  if (session == nullptr) return json_error("session is null");
  if (out_dir == nullptr || *out_dir == '\0') {
    return json_error("out_dir is empty");
  }
  try {
    ht_session_ctx* ctx = as_ctx(session);
    std::error_code fs_ec;
    std::filesystem::create_directories(
        std::filesystem::u8path(std::string(out_dir)), fs_ec);

    // 前一轮的残留（超时未收齐）不该算进本轮：清账再发。
    ctx->resumes.clear();
    ctx->resume_pending = 0;
    ctx->resume_failed = 0;

    for (const lt::torrent_handle& h : ctx->ses.get_torrents()) {
      if (!h.is_valid()) continue;
      // 无元数据的种子（磁力刚加、还没拿到 info dict）存了也无法重建，
      // libtorrent 会直接回 failed_alert —— 不发，省一轮等待。
      if (!h.torrent_file()) continue;
      // save_info_dict：把 info dict 一并写进 resume，重启后磁力种子无需
      // 重新向 DHT/peer 取元数据即可直接续传/做种。
      h.save_resume_data(lt::torrent_handle::save_info_dict);
      ctx->resume_pending++;
    }

    const int budget_ms = timeout_ms > 0 ? timeout_ms : 5000;
    const std::chrono::steady_clock::time_point deadline =
        std::chrono::steady_clock::now() + std::chrono::milliseconds(budget_ms);
    while (ctx->resume_pending > 0) {
      const std::chrono::steady_clock::time_point now =
          std::chrono::steady_clock::now();
      if (now >= deadline) break;
      // 等到有 alert 再收割（而不是 sleep 轮询猜）。返回 nullptr = 本段
      // 时间窗内无 alert，继续判超时。
      ctx->ses.wait_for_alert(
          std::chrono::duration_cast<lt::time_duration>(deadline - now));
      drain_alerts(ctx);
    }

    int saved = 0;
    int write_failed = 0;
    for (const std::pair<std::string, std::vector<char>>& entry :
         ctx->resumes) {
      const std::filesystem::path target =
          std::filesystem::u8path(std::string(out_dir)) /
          std::filesystem::u8path(entry.first + ".resume");
      // 原子落盘：先写 .tmp 再 rename，避免断电/崩溃留半个 resume 文件
      // （半个文件会让下次启动整个种子加不回来）。
      const std::filesystem::path tmp =
          std::filesystem::path(target).concat(".tmp");
      {
        std::ofstream os(tmp, std::ios::binary | std::ios::trunc);
        if (!os) {
          write_failed++;
          continue;
        }
        os.write(entry.second.data(),
                 static_cast<std::streamsize>(entry.second.size()));
        if (!os) {
          write_failed++;
          continue;
        }
      }
      std::error_code ren_ec;
      std::filesystem::rename(tmp, target, ren_ec);
      if (ren_ec) {
        write_failed++;
        std::error_code rm_ec;
        std::filesystem::remove(tmp, rm_ec);
        continue;
      }
      saved++;
    }
    const int alert_failed = ctx->resume_failed;
    const int pending_left = ctx->resume_pending;
    ctx->resumes.clear();
    ctx->resume_pending = 0;
    ctx->resume_failed = 0;

    std::string out = "{\"ok\":true,\"saved\":";
    out += std::to_string(saved);
    out += ",\"failed\":";
    out += std::to_string(alert_failed + write_failed);
    out += ",\"timed_out\":";
    out += std::to_string(pending_left);
    out += '}';
    return dup_string(out);
  } catch (const std::exception& e) {
    return json_error(e.what());
  } catch (...) {
    return json_error("unknown error in ht_save_resume_data");
  }
}

HT_EXPORT char* ht_load_resume_dir(void* session, const char* dir) {
  if (session == nullptr) return json_error("session is null");
  if (dir == nullptr || *dir == '\0') return json_error("dir is empty");
  try {
    lt::session* ses = as_session(session);
    const std::filesystem::path root =
        std::filesystem::u8path(std::string(dir));
    std::error_code exists_ec;
    if (!std::filesystem::exists(root, exists_ec)) {
      // 首次运行没有 resume 目录是正常态，不是错误。
      return dup_string("{\"ok\":true,\"added\":0,\"failed\":0,\"ids\":[]}");
    }
    int added = 0;
    int failed = 0;
    std::string ids;
    std::error_code iter_ec;
    for (const std::filesystem::directory_entry& entry :
         std::filesystem::directory_iterator(root, iter_ec)) {
      if (iter_ec) break;
      if (!entry.is_regular_file()) continue;
      if (entry.path().extension() != ".resume") continue;
      std::ifstream is(entry.path(), std::ios::binary);
      if (!is) {
        failed++;
        continue;
      }
      const std::vector<char> buf((std::istreambuf_iterator<char>(is)),
                                  std::istreambuf_iterator<char>());
      if (buf.empty()) {
        failed++;
        continue;
      }
      lt::error_code ec;
      lt::add_torrent_params params = lt::read_resume_data(buf, ec);
      if (ec) {
        failed++;
        continue;
      }
      // 与 add_with_params 同一语义：本引擎的 add = 「开始跑」。resume 里
      // 存的 paused 旗标必须清掉，否则加回来是暂停态，既不续传也不做种。
      params.flags &= ~lt::torrent_flags::paused;
      // BUG-1293：旧版本把「关上传」误写成置 upload_mode（实际语义是停止
      // 下载），已升级用户的 resume 里可能带着残留 flag，加载时一律治愈。
      params.flags &= ~lt::torrent_flags::upload_mode;
      lt::error_code add_ec;
      lt::torrent_handle h = ses->add_torrent(std::move(params), add_ec);
      if ((add_ec && add_ec != lt::errors::duplicate_torrent) ||
          !h.is_valid()) {
        failed++;
        continue;
      }
      if (added > 0) ids += ',';
      ids += '"';
      append_json_escaped(ids, best_hash_hex(h.info_hashes()));
      ids += '"';
      added++;
    }
    std::string out = "{\"ok\":true,\"added\":";
    out += std::to_string(added);
    out += ",\"failed\":";
    out += std::to_string(failed);
    out += ",\"ids\":[" + ids + "]}";
    return dup_string(out);
  } catch (const std::exception& e) {
    return json_error(e.what());
  } catch (...) {
    return json_error("unknown error in ht_load_resume_dir");
  }
}

// ── TODO-2482：任务详情批次 ─────────────────────────────────────────

HT_EXPORT char* ht_torrent_trackers(void* session, const char* info_hash) {
  if (session == nullptr) return json_error("session is null");
  try {
    lt::torrent_handle h = find_torrent(as_session(session), info_hash);
    if (!h.is_valid()) return json_error("torrent not found");
    const std::vector<lt::announce_entry> trackers = h.trackers();
    std::string out = "{\"ok\":true,\"trackers\":[";
    bool first = true;
    for (const lt::announce_entry& ae : trackers) {
      if (!first) out += ',';
      first = false;
      // 逐 endpoint（多网卡）× 协议（v1/v2）聚合：working 取「任一成功」、
      // fails/scrape 取最大、错误文本取首个非空 —— 详情页要的是「这个
      // tracker 整体好不好使」，不是逐 socket 的调试细节。
      bool working = false;
      bool updating = false;
      int fails = 0;
      int scrape_complete = -1;
      int scrape_incomplete = -1;
      int scrape_downloaded = -1;
      std::string last_error;
      std::string message;
      for (const lt::announce_endpoint& ep : ae.endpoints) {
        for (const lt::protocol_version v :
             {lt::protocol_version::V1, lt::protocol_version::V2}) {
          const lt::announce_infohash& ih = ep.info_hashes[v];
          // start_sent = 至少成功 announce 过一次；无错且不在失败计数中
          // 才算「当前工作」。从未联系过的协议槽（纯 v1 种子的 v2 槽）
          // start_sent 恒 false，自然不计入。
          if (ih.start_sent && ih.fails == 0 && !ih.last_error) working = true;
          if (ih.updating) updating = true;
          fails = std::max(fails, int(ih.fails));
          scrape_complete = std::max(scrape_complete, ih.scrape_complete);
          scrape_incomplete = std::max(scrape_incomplete, ih.scrape_incomplete);
          scrape_downloaded = std::max(scrape_downloaded, ih.scrape_downloaded);
          if (last_error.empty() && ih.last_error) {
            last_error = ih.last_error.message();
          }
          if (message.empty()) message = ih.message;
        }
      }
      out += '{';
      append_json_str_field(out, "url", ae.url);
      out += ",\"tier\":" + std::to_string(int(ae.tier));
      out += std::string(",\"working\":") + (working ? "true" : "false");
      out += std::string(",\"updating\":") + (updating ? "true" : "false");
      out += ",\"fails\":" + std::to_string(fails);
      out += ',';
      append_json_str_field(out, "last_error", last_error);
      out += ',';
      append_json_str_field(out, "message", message);
      out += ",\"scrape_complete\":" + std::to_string(scrape_complete);
      out += ",\"scrape_incomplete\":" + std::to_string(scrape_incomplete);
      out += ",\"scrape_downloaded\":" + std::to_string(scrape_downloaded);
      out += '}';
    }
    out += "]}";
    return dup_string(out);
  } catch (const std::exception& e) {
    return json_error(e.what());
  } catch (...) {
    return json_error("unknown error in ht_torrent_trackers");
  }
}

HT_EXPORT char* ht_get_file_priorities(void* session, const char* info_hash) {
  if (session == nullptr) return json_error("session is null");
  try {
    lt::torrent_handle h = find_torrent(as_session(session), info_hash);
    if (!h.is_valid()) return json_error("torrent not found");
    if (!h.torrent_file()) return json_error("no metadata");
    const std::vector<lt::download_priority_t> priorities =
        h.get_file_priorities();
    std::string out = "{\"ok\":true,\"priorities\":[";
    for (std::size_t i = 0; i < priorities.size(); ++i) {
      if (i > 0) out += ',';
      out += std::to_string(int(static_cast<std::uint8_t>(priorities[i])));
    }
    out += "]}";
    return dup_string(out);
  } catch (const std::exception& e) {
    return json_error(e.what());
  } catch (...) {
    return json_error("unknown error in ht_get_file_priorities");
  }
}

HT_EXPORT char* ht_get_piece_priorities(void* session, const char* info_hash) {
  if (session == nullptr) return json_error("session is null");
  try {
    lt::torrent_handle h = find_torrent(as_session(session), info_hash);
    if (!h.is_valid()) return json_error("torrent not found");
    if (!h.torrent_file()) return json_error("no metadata");
    const std::vector<lt::download_priority_t> priorities =
        h.get_piece_priorities();
    std::string out = "{\"ok\":true,\"priorities\":[";
    for (std::size_t i = 0; i < priorities.size(); ++i) {
      if (i > 0) out += ',';
      out += std::to_string(int(static_cast<std::uint8_t>(priorities[i])));
    }
    out += "]}";
    return dup_string(out);
  } catch (const std::exception& e) {
    return json_error(e.what());
  } catch (...) {
    return json_error("unknown error in ht_get_piece_priorities");
  }
}

HT_EXPORT int ht_set_file_priority(void* session, const char* info_hash,
                                   int file_index, int priority) {
  if (session == nullptr || file_index < 0 || priority < 0 || priority > 7) {
    return 0;
  }
  try {
    lt::torrent_handle h = find_torrent(as_session(session), info_hash);
    if (!h.is_valid()) return 0;
    std::shared_ptr<const lt::torrent_info> ti = h.torrent_file();
    if (!ti) return 0;
    if (file_index >= ti->num_files()) return 0;
    ht_session_ctx* ctx = as_ctx(session);
    const std::uint64_t seen = ctx->file_prio_events;
    h.file_priority(lt::file_index_t(file_index),
                    lt::download_priority_t(std::uint8_t(priority)));
    // TODO-2526：libtorrent 2.x 的文件优先级经**磁盘线程**异步落地，随后
    // 才重算该文件覆盖的 piece 优先级、把首尾提优（起播优化）冲掉；完成
    // 回执是 file_prio_alert，drain_alerts 收到它时重放提优（那是「重算
    // 已发生」的唯一可靠信号 —— 写完立即重放会先落地、再被重算覆盖，
    // 实测顺序如此）。这里有界等待回执，保证本函数返回时重放已排队，
    // 不依赖调用方之后是否轮询某个会收割 alert 的入口。
    //
    // 预算 1s 而不是更长：正常回执毫秒级；但 libtorrent 契约（alert_types
    // 的 file_prio_alert 注释）写明磁盘操作**失败时不发本 alert**、改发
    // file_error_alert —— 该路径必吃满预算，而本调用跑在 UI isolate 上，
    // 长预算就是长冻结（BUG-1285 同型教训）。超时本就非致命：优先级已
    // 写入，重放由后续任意收割（详情页秒级轮询）兜底。
    //
    // 释放条件是**全局**计数器 file_prio_events，不按种子配对：多种子并发
    // 改优先级时 A 的回执会提前放行 B 的调用 —— 后果与超时路径相同（B 的
    // 重放由后续 drain 兜底），且 Dart 侧同 isolate 同步 FFI 天然串行，
    // 不为不存在的并发建 per-torrent 回执簿。
    const std::chrono::steady_clock::time_point deadline =
        std::chrono::steady_clock::now() + std::chrono::milliseconds(1000);
    while (ctx->file_prio_events == seen) {
      const std::chrono::steady_clock::time_point now =
          std::chrono::steady_clock::now();
      if (now >= deadline) break;
      ctx->ses.wait_for_alert(
          std::chrono::duration_cast<lt::time_duration>(deadline - now));
      drain_alerts(ctx);
    }
    return 1;
  } catch (...) {
    return 0;
  }
}

HT_EXPORT char* ht_session_status(void* session) {
  if (session == nullptr) return json_error("session is null");
  try {
    ht_session_ctx* ctx = as_ctx(session);
    // 发出统计请求（回执异步）后只收割已到的 alert —— 本函数**不等待**
    // （同步等会卡 UI isolate）。dht_nodes 首轮 -1、下一轮即有值；速率要到
    // **第三轮**才有值：首轮回执未到、第二轮收割到首个采样只够建基线，
    // 第三轮才差分得出（契约见头文件）。
    ctx->ses.post_dht_stats();
    ctx->ses.post_session_stats();
    drain_alerts(ctx);
    const lt::settings_pack sp = ctx->ses.get_settings();
    std::string out = "{\"ok\":true";
    out += ",\"listen_port\":" + std::to_string(int(ctx->ses.listen_port()));
    out += std::string(",\"dht_running\":") +
           (ctx->ses.is_dht_running() ? "true" : "false");
    out += ",\"dht_nodes\":" + std::to_string(ctx->dht_nodes);
    out += std::string(",\"lsd_enabled\":") +
           (sp.get_bool(lt::settings_pack::enable_lsd) ? "true" : "false");
    out += std::string(",\"upnp_enabled\":") +
           (sp.get_bool(lt::settings_pack::enable_upnp) ? "true" : "false");
    out += std::string(",\"natpmp_enabled\":") +
           (sp.get_bool(lt::settings_pack::enable_natpmp) ? "true" : "false");
    // 本桥建 session 一律带默认插件（含 ut_pex），无运行时开关。
    out += ",\"pex_enabled\":true";
    out += ",\"down_rate\":" + std::to_string(ctx->down_rate);
    out += ",\"up_rate\":" + std::to_string(ctx->up_rate);
    out += ",\"port_mappings\":[";
    bool first = true;
    for (const auto& entry : ctx->portmaps) {
      if (!first) out += ',';
      first = false;
      const int transport = entry.first.first;
      const int protocol = entry.first.second;
      out += '{';
      append_json_str_field(
          out, "transport",
          transport == int(lt::portmap_transport::upnp) ? "upnp" : "natpmp");
      out += ',';
      const char* proto_label =
          protocol == int(lt::portmap_protocol::tcp)
              ? "tcp"
              : (protocol == int(lt::portmap_protocol::udp) ? "udp" : "");
      append_json_str_field(out, "protocol", proto_label);
      out += ",\"external_port\":" + std::to_string(entry.second.external_port);
      out += std::string(",\"ok\":") + (entry.second.ok ? "true" : "false");
      out += ',';
      append_json_str_field(out, "error", entry.second.error);
      out += '}';
    }
    out += "]}";
    return dup_string(out);
  } catch (const std::exception& e) {
    return json_error(e.what());
  } catch (...) {
    return json_error("unknown error in ht_session_status");
  }
}

HT_EXPORT void ht_free_string(char* s) {
  std::free(s);
}

}  // extern "C"
