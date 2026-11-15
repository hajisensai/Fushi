#include "deck_buttons.h"

#include <fcntl.h>
#include <glib.h>
#include <poll.h>
#include <unistd.h>

#include <array>
#include <chrono>
#include <utility>

#include "main_loop.h"

namespace fushi::deck_buttons {

namespace {

constexpr char kControllerId[] = "HID_ID=0003:000028DE:00001205";
constexpr size_t kReportSize = 64;
constexpr uint8_t kDeckState = 9;

struct Mask {
  int word;  // 0 = low dword (bytes 8-11), 1 = high dword (bytes 12-15)
  uint32_t bits;
};

Mask MaskFor(BackButton button) {
  using enum BackButton;
  switch (button) {
    case kL4:
      return {1, 0x00000200u};
    case kR4:
      return {1, 0x00000400u};
    case kL5:
      return {0, 0x00008000u};
    case kR5:
      return {0, 0x00010000u};
  }
  return {1, 0x00000400u};
}

uint32_t LittleEndian32(const uint8_t* bytes) {
  return static_cast<uint32_t>(bytes[0]) |
         static_cast<uint32_t>(bytes[1]) << 8 |
         static_cast<uint32_t>(bytes[2]) << 16 |
         static_cast<uint32_t>(bytes[3]) << 24;
}

}  // namespace

std::optional<bool> IsHeld(const uint8_t* report, size_t length,
                           BackButton button) {
  if (report == nullptr || length < 16 || report[2] != kDeckState) {
    return std::nullopt;
  }
  const Mask mask = MaskFor(button);
  const uint32_t word = LittleEndian32(report + (mask.word == 0 ? 8 : 12));
  return (word & mask.bits) != 0;
}

std::vector<std::string> ControllerNodes() {
  std::vector<std::string> nodes;
  GDir* dir = g_dir_open("/sys/class/hidraw", 0, nullptr);
  if (dir == nullptr) return nodes;
  while (const gchar* name = g_dir_read_name(dir)) {
    gchar* uevent_path =
        g_build_filename("/sys/class/hidraw", name, "device", "uevent", nullptr);
    gchar* uevent = nullptr;
    if (g_file_get_contents(uevent_path, &uevent, nullptr, nullptr) &&
        uevent != nullptr) {
      gchar* upper = g_ascii_strup(uevent, -1);
      if (g_strstr_len(upper, -1, kControllerId) != nullptr) {
        nodes.push_back(std::string("/dev/") + name);
      }
      g_free(upper);
    }
    g_free(uevent);
    g_free(uevent_path);
  }
  g_dir_close(dir);
  return nodes;
}

Watcher::~Watcher() { Stop(); }

void Watcher::Start(BackButton button, PressCallback on_press) {
  Stop();
  button_ = button;
  on_press_ = std::move(on_press);
  thread_ = std::jthread([this](const std::stop_token& stop) { Run(stop); });
}

void Watcher::Stop() noexcept {
  thread_.request_stop();
  if (thread_.joinable()) thread_.join();
}

void Watcher::Run(const std::stop_token& stop) const {
  while (!stop.stop_requested()) {
    ReadUntilError(stop);
    // Controller asleep or reconnecting: try again shortly.
    for (int i = 0; i < 20 && !stop.stop_requested(); ++i) {
      std::this_thread::sleep_for(std::chrono::milliseconds(100));
    }
  }
}

bool Watcher::ReadUntilError(const std::stop_token& stop) const {
  std::vector<pollfd> fds;
  for (const std::string& node : ControllerNodes()) {
    const int fd = open(node.c_str(), O_RDONLY | O_NONBLOCK | O_CLOEXEC);
    if (fd >= 0) fds.push_back(pollfd{fd, POLLIN, 0});
  }
  if (fds.empty()) return false;
  // One held state per node: the controller exposes several interfaces and
  // only one of them sends Deck state reports.
  std::vector<bool> held(fds.size(), false);
  bool ok = true;
  while (!stop.stop_requested() && ok) {
    // Short timeout so Stop() is noticed quickly.
    if (poll(fds.data(), fds.size(), 250) <= 0) continue;
    for (size_t i = 0; i < fds.size() && ok; ++i) {
      const std::optional<bool> now = ReadReport(fds[i], held[i]);
      if (now.has_value()) {
        held[i] = *now;
      } else {
        ok = false;
      }
    }
  }
  for (const pollfd& fd : fds) close(fd.fd);
  return true;
}

std::optional<bool> Watcher::ReadReport(const pollfd& node,
                                        bool was_held) const {
  if (node.revents & (POLLERR | POLLHUP | POLLNVAL)) return std::nullopt;
  if (!(node.revents & POLLIN)) return was_held;
  std::array<uint8_t, kReportSize> report{};
  const ssize_t n = read(node.fd, report.data(), report.size());
  if (n < 0) return was_held;
  const std::optional<bool> now =
      IsHeld(report.data(), static_cast<size_t>(n), button_);
  if (!now.has_value()) return was_held;
  // Hand the press to the GTK main thread.
  if (*now && !was_held) PostToMainLoop(on_press_);
  return *now;
}

}  // namespace fushi::deck_buttons
