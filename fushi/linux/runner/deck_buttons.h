#ifndef RUNNER_DECK_BUTTONS_H_
#define RUNNER_DECK_BUTTONS_H_

#include <poll.h>

#include <cstddef>
#include <cstdint>
#include <functional>
#include <optional>
#include <stop_token>
#include <string>
#include <thread>
#include <vector>

// Watches one Steam Deck back button (L4 / R4 / L5 / R5) for Game Mode: in
// Gamescope, Fushi's windows only get input while they hold Steam's overlay
// slot (gamescope_overlay.h), so a button press is what starts screen OCR.
//
// The Deck's built-in controller (Valve 28DE:1205) sends 64-byte reports on
// hidraw. The logged-in user can read its nodes (logind ACL; Flatpak needs
// --device=all), and hidraw allows many readers: watching it never takes input
// away from Steam or the game, and nothing is written to the device. Steam's
// default controller layout leaves the back buttons unbound, so the game does
// not react to them.
//
// Report layout (SDL's SDL_hidapi_steamdeck.c, ValveInReportHeader_t):
//   byte 2 = 9 (Deck state), bytes 8-11 = buttons low dword, 12-15 = high.
//   L5 = low 0x8000, R5 = low 0x10000, L4 = high 0x200, R4 = high 0x400.
// Same table as tools/decky-fushi-lens/py_modules/fushi_lens/paddles.py.
namespace fushi::deck_buttons {

enum class BackButton { kL4, kR4, kL5, kR5 };

// Whether |button| is held in one report; nullopt when the report is not a
// Deck state report.
std::optional<bool> IsHeld(const uint8_t* report, size_t length,
                           BackButton button);

// /dev/hidrawN nodes of the Deck controller, from /sys/class/hidraw.
std::vector<std::string> ControllerNodes();

class Watcher {
 public:
  // Runs on the GTK main thread on every press edge.
  using PressCallback = std::function<void()>;

  Watcher() = default;
  ~Watcher();

  Watcher(const Watcher&) = delete;
  Watcher& operator=(const Watcher&) = delete;

  // Starts a reader thread. Reopens the controller after suspend or a
  // reconnect. Calling Start again replaces the button and callback.
  void Start(BackButton button, PressCallback on_press);
  void Stop() noexcept;

 private:
  void Run(const std::stop_token& stop) const;
  // Reads until Stop or a read error; false when no node could be opened.
  bool ReadUntilError(const std::stop_token& stop) const;
  // Handles one poll result: the button's new held state, or nullopt when the
  // node is gone. Posts |on_press_| on the press edge.
  std::optional<bool> ReadReport(const pollfd& node, bool was_held) const;

  BackButton button_ = BackButton::kR4;
  PressCallback on_press_;
  std::jthread thread_;
};

}  // namespace fushi::deck_buttons

#endif  // RUNNER_DECK_BUTTONS_H_
