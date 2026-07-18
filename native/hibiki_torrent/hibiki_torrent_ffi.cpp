// hibiki_torrent C ABI bridge implementation（阶段1a walking skeleton）。
//
// 只做工具链证明：暴露 libtorrent 版本串 + 空壳 session 生命周期。真正的
// 磁力/元数据/文件优先级/边下边播在阶段1b实现 EmbeddedTorrentBackend 时再加。

#include "hibiki_torrent.h"

#include <libtorrent/session.hpp>
#include <libtorrent/session_params.hpp>
#include <libtorrent/settings_pack.hpp>
#include <libtorrent/version.hpp>

#include <utility>

extern "C" {

HT_EXPORT const char* ht_libtorrent_version(void) {
  // lt::version() 返回指向静态存储的 C 字符串，跨 FFI 边界安全、无需释放。
  return lt::version();
}

HT_EXPORT void* ht_session_create(void) {
  try {
    lt::settings_pack sp;
    // 不绑定/监听任何端口，也不启用发现协议：walking skeleton 只验证
    // session 能构造，不产生任何网络副作用（避免防火墙弹窗）。
    sp.set_str(lt::settings_pack::listen_interfaces, "");
    sp.set_bool(lt::settings_pack::enable_dht, false);
    sp.set_bool(lt::settings_pack::enable_lsd, false);
    sp.set_bool(lt::settings_pack::enable_upnp, false);
    sp.set_bool(lt::settings_pack::enable_natpmp, false);
    return new lt::session(std::move(sp));
  } catch (...) {
    return nullptr;
  }
}

HT_EXPORT void ht_session_destroy(void* session) {
  delete static_cast<lt::session*>(session);
}

}  // extern "C"
