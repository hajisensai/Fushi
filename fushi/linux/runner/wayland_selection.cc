#include "wayland_selection.h"

#include <fcntl.h>
#include <poll.h>
#include <unistd.h>
#include <wayland-client.h>

#include <chrono>
#include <cstring>
#include <map>
#include <set>

#include "ext-data-control-v1-client-protocol.h"

namespace {

using Clock = std::chrono::steady_clock;

constexpr size_t kMaxSelectionBytes = 1 << 20;

// Text mime types, most preferred first.
constexpr const char* kTextMimes[] = {"text/plain;charset=utf-8",
                                      "UTF8_STRING", "text/plain", "TEXT",
                                      "STRING"};

struct Session {
  wl_display* display = nullptr;
  wl_registry* registry = nullptr;
  wl_seat* seat = nullptr;
  ext_data_control_manager_v1* manager = nullptr;
  ext_data_control_device_v1* device = nullptr;
  std::map<ext_data_control_offer_v1*, std::set<std::string>> offers;
  ext_data_control_offer_v1* primary = nullptr;
  bool primary_known = false;

  ~Session() {
    for (auto& [offer, mimes] : offers) {
      ext_data_control_offer_v1_destroy(offer);
    }
    if (device != nullptr) ext_data_control_device_v1_destroy(device);
    if (manager != nullptr) ext_data_control_manager_v1_destroy(manager);
    if (seat != nullptr) wl_seat_destroy(seat);
    if (registry != nullptr) wl_registry_destroy(registry);
    if (display != nullptr) wl_display_disconnect(display);
  }
};

int RemainingMs(Clock::time_point deadline) {
  const auto left = std::chrono::duration_cast<std::chrono::milliseconds>(
      deadline - Clock::now());
  return left.count() > 0 ? static_cast<int>(left.count()) : 0;
}

// wl_display_roundtrip with a deadline (a stuck compositor must not hang the
// capture forever).
bool Roundtrip(wl_display* display, Clock::time_point deadline) {
  bool done = false;
  wl_callback* callback = wl_display_sync(display);
  static const wl_callback_listener kListener = {
      [](void* data, wl_callback*, uint32_t) {
        *static_cast<bool*>(data) = true;
      }};
  wl_callback_add_listener(callback, &kListener, &done);
  bool ok = true;
  while (!done) {
    while (wl_display_prepare_read(display) != 0) {
      if (wl_display_dispatch_pending(display) < 0) {
        ok = false;
        break;
      }
    }
    if (!ok || done) {
      if (ok) wl_display_cancel_read(display);
      break;
    }
    wl_display_flush(display);
    pollfd fd = {wl_display_get_fd(display), POLLIN, 0};
    if (poll(&fd, 1, RemainingMs(deadline)) <= 0) {
      wl_display_cancel_read(display);
      ok = false;
      break;
    }
    if (wl_display_read_events(display) < 0 ||
        wl_display_dispatch_pending(display) < 0) {
      ok = false;
      break;
    }
  }
  wl_callback_destroy(callback);
  return ok && done;
}

void OnOffer(void* data, ext_data_control_offer_v1* offer, const char* mime) {
  static_cast<Session*>(data)->offers[offer].insert(mime);
}

const ext_data_control_offer_v1_listener kOfferListener = {OnOffer};

void OnDataOffer(void* data, ext_data_control_device_v1*,
                 ext_data_control_offer_v1* offer) {
  auto* session = static_cast<Session*>(data);
  session->offers[offer];
  ext_data_control_offer_v1_add_listener(offer, &kOfferListener, session);
}

void OnSelection(void*, ext_data_control_device_v1*,
                 ext_data_control_offer_v1*) {}

void OnFinished(void*, ext_data_control_device_v1*) {}

void OnPrimarySelection(void* data, ext_data_control_device_v1*,
                        ext_data_control_offer_v1* offer) {
  auto* session = static_cast<Session*>(data);
  session->primary = offer;
  session->primary_known = true;
}

const ext_data_control_device_v1_listener kDeviceListener = {
    OnDataOffer, OnSelection, OnFinished, OnPrimarySelection};

void OnGlobal(void* data, wl_registry* registry, uint32_t name,
              const char* interface, uint32_t) {
  auto* session = static_cast<Session*>(data);
  if (strcmp(interface, ext_data_control_manager_v1_interface.name) == 0 &&
      session->manager == nullptr) {
    session->manager = static_cast<ext_data_control_manager_v1*>(
        wl_registry_bind(registry, name, &ext_data_control_manager_v1_interface,
                         1));
  } else if (strcmp(interface, wl_seat_interface.name) == 0 &&
             session->seat == nullptr) {
    session->seat = static_cast<wl_seat*>(
        wl_registry_bind(registry, name, &wl_seat_interface, 1));
  }
}

void OnGlobalRemove(void*, wl_registry*, uint32_t) {}

const wl_registry_listener kRegistryListener = {OnGlobal, OnGlobalRemove};

// Reads the source app's end of the pipe until EOF, the size cap or the
// deadline.
std::string ReadPipe(int fd, Clock::time_point deadline) {
  std::string text;
  char buffer[4096];
  while (text.size() < kMaxSelectionBytes) {
    pollfd p = {fd, POLLIN, 0};
    if (poll(&p, 1, RemainingMs(deadline)) <= 0) {
      break;
    }
    const ssize_t got = read(fd, buffer, sizeof(buffer));
    if (got <= 0) {
      break;
    }
    text.append(buffer, static_cast<size_t>(got));
  }
  return text;
}

}  // namespace

std::optional<std::string> ReadWaylandPrimarySelection(int timeout_ms) {
  const Clock::time_point deadline =
      Clock::now() + std::chrono::milliseconds(timeout_ms);
  Session session;
  session.display = wl_display_connect(nullptr);
  if (session.display == nullptr) {
    return std::nullopt;
  }
  session.registry = wl_display_get_registry(session.display);
  wl_registry_add_listener(session.registry, &kRegistryListener, &session);
  if (!Roundtrip(session.display, deadline) || session.manager == nullptr ||
      session.seat == nullptr) {
    return std::nullopt;
  }
  session.device =
      ext_data_control_manager_v1_get_data_device(session.manager, session.seat);
  ext_data_control_device_v1_add_listener(session.device, &kDeviceListener,
                                          &session);
  // The device announces the current selections (offers, their mime types,
  // then primary_selection) right after it is created.
  if (!Roundtrip(session.display, deadline)) {
    return std::nullopt;
  }
  if (!session.primary_known) {
    Roundtrip(session.display, deadline);
  }
  if (session.primary == nullptr) {
    return std::string();
  }
  const std::set<std::string>& mimes = session.offers[session.primary];
  const char* mime = nullptr;
  for (const char* candidate : kTextMimes) {
    if (mimes.count(candidate) != 0) {
      mime = candidate;
      break;
    }
  }
  if (mime == nullptr) {
    return std::string();
  }
  int fds[2];
  if (pipe2(fds, O_CLOEXEC) != 0) {
    return std::nullopt;
  }
  ext_data_control_offer_v1_receive(session.primary, mime, fds[1]);
  wl_display_flush(session.display);
  close(fds[1]);
  std::string text = ReadPipe(fds[0], deadline);
  close(fds[0]);
  return text;
}
