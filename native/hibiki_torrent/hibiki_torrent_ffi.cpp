// hibiki_torrent C ABI bridge implementation（阶段1b：真实下载管线）。
//
// 设计原则：
// - C 层无自有状态：句柄即 lt::session*，种子按 infohash 每次现查
//   （get_torrents() 线性扫，任务数为个位数，够用且消灭状态同步）。
// - 出参一律 malloc 的 UTF-8 JSON（手写生成 + 转义，零第三方依赖，
//   不引 GPL/非 BSD 传染）；入参路径一律 UTF-8（libtorrent 原生约定）。
// - 所有入口 try/catch 到边界：C ABI 绝不向 Dart 泄异常。

#include "hibiki_torrent.h"

#include <libtorrent/add_torrent_params.hpp>
#include <libtorrent/address.hpp>
#include <libtorrent/alert_types.hpp>
#include <libtorrent/bencode.hpp>
#include <libtorrent/create_torrent.hpp>
#include <libtorrent/download_priority.hpp>
#include <libtorrent/error_code.hpp>
#include <libtorrent/ip_filter.hpp>
#include <libtorrent/magnet_uri.hpp>
#include <libtorrent/session.hpp>
#include <libtorrent/session_params.hpp>
#include <libtorrent/settings_pack.hpp>
#include <libtorrent/socket.hpp>
#include <libtorrent/torrent_flags.hpp>
#include <libtorrent/torrent_info.hpp>
#include <libtorrent/torrent_status.hpp>
#include <libtorrent/version.hpp>

#include <cctype>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <fstream>
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

lt::session* as_session(void* session) {
  return static_cast<lt::session*>(session);
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
    // piece 完成事件（下载顺序证据/边下边播缓冲）+ 状态/错误告警。
    sp.set_int(lt::settings_pack::alert_mask,
               lt::alert_category::status | lt::alert_category::error |
                   lt::alert_category::piece_progress);
    return new lt::session(std::move(sp));
  } catch (...) {
    return nullptr;
  }
}

HT_EXPORT void ht_session_destroy(void* session) {
  delete as_session(session);
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

HT_EXPORT int ht_apply_limits(void* session, int download_bps, int upload_bps,
                              int connections_limit) {
  if (session == nullptr) return 0;
  try {
    lt::settings_pack sp;
    sp.set_int(lt::settings_pack::download_rate_limit,
               download_bps > 0 ? download_bps : 0);
    sp.set_int(lt::settings_pack::upload_rate_limit,
               upload_bps > 0 ? upload_bps : 0);
    // <=0 时不动 connections_limit（保持 libtorrent 默认），避免把用户
    // "不限"误设成 0（0 会禁止所有连接）。
    if (connections_limit > 0) {
      sp.set_int(lt::settings_pack::connections_limit, connections_limit);
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
    const bool allow = upload_enabled != 0;
    // upload_mode = 只下不上：allow 时清除、否则置位。
    const auto apply = [allow](lt::torrent_handle h) {
      if (!h.is_valid()) return;
      if (allow) {
        h.unset_flags(lt::torrent_flags::upload_mode);
      } else {
        h.set_flags(lt::torrent_flags::upload_mode);
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
    std::vector<lt::alert*> alerts;
    as_session(session)->pop_alerts(&alerts);
    std::string out = "[";
    bool first = true;
    for (const lt::alert* a : alerts) {
      const auto* pf = lt::alert_cast<lt::piece_finished_alert>(a);
      if (pf == nullptr || !pf->handle.is_valid()) continue;
      if (!first) out += ',';
      first = false;
      out += "{";
      append_json_str_field(out, "id", best_hash_hex(pf->handle.info_hashes()));
      out += ",\"piece\":" + std::to_string(int(pf->piece_index)) + '}';
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
    std::shared_ptr<const lt::torrent_info> ti = h.torrent_file();
    if (!ti) return 0;
    const lt::file_storage& fs = ti->files();
    const std::int64_t piece_len = ti->piece_length();
    if (piece_len <= 0) return 0;
    for (int i = 0; i < ti->num_files(); ++i) {
      const lt::file_index_t idx(i);
      const std::int64_t size = fs.file_size(idx);
      if (size <= 0) continue;
      const std::int64_t offset = fs.file_offset(idx);
      const int first = int(offset / piece_len);
      const int last = int((offset + size - 1) / piece_len);
      h.piece_priority(lt::piece_index_t(first), lt::top_priority);
      h.piece_priority(lt::piece_index_t(last), lt::top_priority);
    }
    return 1;
  } catch (...) {
    return -1;
  }
}

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

HT_EXPORT void ht_free_string(char* s) {
  std::free(s);
}

}  // extern "C"
