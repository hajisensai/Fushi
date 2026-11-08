#ifndef RUNNER_MAIN_LOOP_H_
#define RUNNER_MAIN_LOOP_H_

#include <glib.h>

#include <memory>
#include <utility>

namespace fushi {

// Runs |task| once from the GTK main loop, never inline. Safe from any thread:
// GLib owns the task until it has run (or the source is dropped) and then
// destroys it.
template <typename Task>
void PostToMainLoop(Task task) {
  g_idle_add_full(
      G_PRIORITY_DEFAULT,
      [](gpointer data) {
        (*static_cast<Task*>(data))();
        return G_SOURCE_REMOVE;
      },
      std::make_unique<Task>(std::move(task)).release(),
      [](gpointer data) {
        const std::unique_ptr<Task> owned(static_cast<Task*>(data));
      });
}

}  // namespace fushi

#endif  // RUNNER_MAIN_LOOP_H_
