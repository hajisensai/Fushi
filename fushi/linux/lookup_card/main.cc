// fushi_lookup_card: the Linux global lookup card process (card_overlay.h says
// why it is a separate process). Started by the runner
// (linux/runner/global_lookup_channel.cc) and driven over stdin / stdout, one
// JSON object per line:
//
//   runner -> card  {"id":N,"method":"showAt","args":{...}}   channel call
//                   {"mediaReply":K,"data":"<base64>"}         getMedia answer
//                                                              (no data = none)
//   card -> runner  {"id":N,"result":...}                     call answered
//                   {"id":N,"notImplemented":true}
//                   {"id":N,"error":{"code":"..","message":".."}}
//                   {"event":"jsMessage","args":{...}}         reverse call
//                   {"event":"getMedia","cid":K,"args":{"url":".."}}
//
// Exits when stdin closes (the app quit or died), so it never outlives Fushi.

#include <gio/gunixinputstream.h>
#include <gio/gunixoutputstream.h>
#include <gtk/gtk.h>
#include <json-glib/json-glib.h>

#include <cstdint>
#include <map>
#include <memory>
#include <string>
#include <utility>

#include "card_overlay.h"
#include "line_pipe.h"

namespace {

using fushi::lookup_card::CardOverlay;
using fushi::lookup_card::LinePipe;
using fushi::lookup_card::Reply;

class CardProcess {
 public:
  CardProcess() {
    GInputStream* in = g_unix_input_stream_new(0, FALSE);
    GOutputStream* out = g_unix_output_stream_new(1, FALSE);
    pipe_ = std::make_unique<LinePipe>(
        in, out, [this](const std::string& line) { OnLine(line); },
        [] { gtk_main_quit(); });
    g_object_unref(in);
    g_object_unref(out);
    overlay_ = std::make_unique<CardOverlay>(
        [this](const char* method, JsonNode* args) { Emit(method, args); },
        [this](const std::string& url, CardOverlay::MediaReply reply) {
          RequestMedia(url, std::move(reply));
        });
  }

 private:
  void Send(JsonObject* object) {
    JsonNode* node = json_node_new(JSON_NODE_OBJECT);
    json_node_take_object(node, object);
    gchar* text = json_to_string(node, FALSE);
    pipe_->Send(text);
    g_free(text);
    json_node_unref(node);
  }

  void Emit(const char* method, JsonNode* args) {
    JsonObject* object = json_object_new();
    json_object_set_string_member(object, "event", method);
    json_object_set_member(object, "args",
                           args != nullptr ? args : json_node_new(JSON_NODE_NULL));
    Send(object);
  }

  void RequestMedia(const std::string& url, CardOverlay::MediaReply reply) {
    const int64_t cid = ++next_media_id_;
    media_replies_[cid] = std::move(reply);
    JsonObject* args = json_object_new();
    json_object_set_string_member(args, "url", url.c_str());
    JsonObject* object = json_object_new();
    json_object_set_string_member(object, "event", "getMedia");
    json_object_set_int_member(object, "cid", cid);
    json_object_set_object_member(object, "args", args);
    Send(object);
  }

  void OnLine(const std::string& line) {
    JsonParser* parser = json_parser_new();
    if (json_parser_load_from_data(parser, line.data(),
                                   static_cast<gssize>(line.size()), nullptr)) {
      JsonNode* root = json_parser_get_root(parser);
      if (root != nullptr && JSON_NODE_HOLDS_OBJECT(root)) {
        JsonObject* message = json_node_get_object(root);
        if (json_object_has_member(message, "mediaReply")) {
          OnMediaReply(message);
        } else if (json_object_has_member(message, "method")) {
          OnCall(message);
        }
      }
    }
    g_object_unref(parser);
  }

  void OnMediaReply(JsonObject* message) {
    const int64_t cid = json_object_get_int_member(message, "mediaReply");
    auto it = media_replies_.find(cid);
    if (it == media_replies_.end()) {
      return;
    }
    CardOverlay::MediaReply reply = std::move(it->second);
    media_replies_.erase(it);
    GBytes* bytes = nullptr;
    const gchar* data =
        json_object_has_member(message, "data")
            ? json_object_get_string_member(message, "data")
            : nullptr;
    if (data != nullptr && data[0] != '\0') {
      gsize length = 0;
      guchar* decoded = g_base64_decode(data, &length);
      bytes = g_bytes_new_take(decoded, length);
    }
    reply(bytes);
    if (bytes != nullptr) {
      g_bytes_unref(bytes);
    }
  }

  void OnCall(JsonObject* message) {
    const int64_t id = json_object_has_member(message, "id")
                           ? json_object_get_int_member(message, "id")
                           : 0;
    const gchar* method = json_object_get_string_member(message, "method");
    JsonNode* args_node = json_object_has_member(message, "args")
                              ? json_object_get_member(message, "args")
                              : nullptr;
    JsonObject* args = args_node != nullptr && JSON_NODE_HOLDS_OBJECT(args_node)
                           ? json_node_get_object(args_node)
                           : nullptr;
    Reply reply = overlay_->Handle(method != nullptr ? method : "", args);
    if (id == 0) {
      // Replayed call after a restart: nobody waits for the answer.
      if (reply.value != nullptr) {
        json_node_unref(reply.value);
      }
      return;
    }
    JsonObject* object = json_object_new();
    json_object_set_int_member(object, "id", id);
    switch (reply.kind) {
      case Reply::Kind::kValue:
        json_object_set_member(object, "result",
                               reply.value != nullptr
                                   ? reply.value
                                   : json_node_new(JSON_NODE_NULL));
        break;
      case Reply::Kind::kNotImplemented:
        json_object_set_boolean_member(object, "notImplemented", TRUE);
        break;
      case Reply::Kind::kError: {
        JsonObject* error = json_object_new();
        json_object_set_string_member(error, "code", reply.error_code.c_str());
        json_object_set_string_member(error, "message",
                                      reply.error_message.c_str());
        json_object_set_object_member(object, "error", error);
        break;
      }
    }
    Send(object);
  }

  std::unique_ptr<LinePipe> pipe_;
  std::unique_ptr<CardOverlay> overlay_;
  int64_t next_media_id_ = 0;
  std::map<int64_t, CardOverlay::MediaReply> media_replies_;
};

}  // namespace

int main(int argc, char** argv) {
  // Temporary compatibility layer for an external limitation: WebKitGTK's
  // DMA-BUF renderer draws the host document but leaves the popup iframes'
  // compositing layers empty in this window (X11 via XWayland, inside the
  // Flatpak, Steam Deck GPU; reproduced on SteamOS 3.9 with the GNOME 49
  // runtime's WebKitGTK 4.1, 2026-11-05), so
  // the card showed as an empty dark shell. Scope: this helper process only
  // (the app's WPE web views are unaffected); the card is small, so the
  // non-DMA-BUF path costs nothing visible. Remove once a WebKitGTK release
  // renders the card's iframes with DMA-BUF in this setup. A user-set value
  // still wins (overwrite = FALSE).
  g_setenv("WEBKIT_DISABLE_DMABUF_RENDERER", "1", FALSE);
  gtk_init(&argc, &argv);
  CardProcess process;
  gtk_main();
  return 0;
}
