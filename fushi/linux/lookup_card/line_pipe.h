#ifndef FUSHI_LOOKUP_CARD_LINE_PIPE_H_
#define FUSHI_LOOKUP_CARD_LINE_PIPE_H_

// Newline-framed messages over a pair of GIO streams: the link between the
// runner (linux/runner/global_lookup_channel.cc) and the lookup card helper
// (linux/lookup_card/main.cc). One message per line; JSON never contains a raw
// newline, so no further framing is needed.
//
// Both directions are asynchronous on the GLib main loop. A blocking write
// could deadlock: the runner writes a large render script while the helper is
// writing a large jsMessage back, and each waits for the other to read.
//
// The LinePipe object may be deleted from inside its own callbacks (the owner
// typically drops it in on_closed). Everything the pending async operations
// touch lives in a shared State that each operation keeps alive.

#include <gio/gio.h>

#include <deque>
#include <functional>
#include <memory>
#include <string>
#include <utility>

namespace fushi::lookup_card {

class LinePipe {
 public:
  using LineHandler = std::function<void(const std::string& line)>;
  using ClosedHandler = std::function<void()>;

  // Takes new references to |in| and |out|.
  LinePipe(GInputStream* in, GOutputStream* out, LineHandler on_line,
           ClosedHandler on_closed)
      : state_(std::make_shared<State>()) {
    state_->in = g_data_input_stream_new(in);
    g_data_input_stream_set_newline_type(state_->in,
                                         G_DATA_STREAM_NEWLINE_TYPE_LF);
    state_->out = G_OUTPUT_STREAM(g_object_ref(out));
    state_->cancellable = g_cancellable_new();
    state_->on_line = std::move(on_line);
    state_->on_closed = std::move(on_closed);
    ReadNext(state_);
  }

  ~LinePipe() {
    state_->on_line = nullptr;
    state_->on_closed = nullptr;
    state_->closed = true;
    g_cancellable_cancel(state_->cancellable);
  }

  LinePipe(const LinePipe&) = delete;
  LinePipe& operator=(const LinePipe&) = delete;

  // Queues |line| (without its trailing newline). Dropped once closed.
  void Send(std::string line) {
    if (state_->closed) {
      return;
    }
    line.push_back('\n');
    state_->queue.push_back(std::move(line));
    if (!state_->writing) {
      WriteNext(state_);
    }
  }

 private:
  struct State {
    GDataInputStream* in = nullptr;
    GOutputStream* out = nullptr;
    GCancellable* cancellable = nullptr;
    LineHandler on_line;
    ClosedHandler on_closed;
    std::deque<std::string> queue;
    bool writing = false;
    bool closed = false;

    State() = default;
    State(const State&) = delete;
    State& operator=(const State&) = delete;
    ~State() {
      g_clear_object(&in);
      g_clear_object(&out);
      g_clear_object(&cancellable);
    }
  };
  using StateRef = std::shared_ptr<State>;

  // Called once, on EOF or the first read / write error.
  static void Close(const StateRef& state) {
    if (state->closed) {
      return;
    }
    // The queue stays: an in-flight write may still read its front buffer
    // until its (cancelled) callback runs. State frees it with the last ref.
    state->closed = true;
    g_cancellable_cancel(state->cancellable);
    ClosedHandler on_closed = std::move(state->on_closed);
    state->on_line = nullptr;
    if (on_closed) {
      on_closed();
    }
  }

  static void ReadNext(const StateRef& state) {
    g_data_input_stream_read_line_async(state->in, G_PRIORITY_DEFAULT,
                                        state->cancellable, OnRead,
                                        new StateRef(state));
  }

  static void OnRead(GObject* source, GAsyncResult* result, gpointer data) {
    std::unique_ptr<StateRef> holder(static_cast<StateRef*>(data));
    StateRef state = *holder;
    GError* error = nullptr;
    gsize length = 0;
    gchar* line = g_data_input_stream_read_line_finish(
        G_DATA_INPUT_STREAM(source), result, &length, &error);
    if (line == nullptr) {
      g_clear_error(&error);
      Close(state);
      return;
    }
    if (!state->closed && state->on_line) {
      // Copy the handler: it may delete the LinePipe, which clears on_line.
      LineHandler on_line = state->on_line;
      on_line(std::string(line, length));
    }
    g_free(line);
    if (!state->closed) {
      ReadNext(state);
    }
  }

  static void WriteNext(const StateRef& state) {
    if (state->closed || state->queue.empty()) {
      state->writing = false;
      return;
    }
    state->writing = true;
    const std::string& front = state->queue.front();
    g_output_stream_write_all_async(state->out, front.data(), front.size(),
                                    G_PRIORITY_DEFAULT, state->cancellable,
                                    OnWritten, new StateRef(state));
  }

  static void OnWritten(GObject* source, GAsyncResult* result, gpointer data) {
    std::unique_ptr<StateRef> holder(static_cast<StateRef*>(data));
    StateRef state = *holder;
    GError* error = nullptr;
    const gboolean ok = g_output_stream_write_all_finish(
        G_OUTPUT_STREAM(source), result, nullptr, &error);
    g_clear_error(&error);
    if (!ok) {
      Close(state);
      return;
    }
    if (!state->queue.empty()) {
      state->queue.pop_front();
    }
    WriteNext(state);
  }

  StateRef state_;
};

}  // namespace fushi::lookup_card

#endif  // FUSHI_LOOKUP_CARD_LINE_PIPE_H_
