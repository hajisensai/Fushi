#undef NDEBUG
#include <cstdint>
#include <iostream>

#include "../game_stream_audio_feed_clock.h"

namespace {

int g_assertions = 0;

bool Expect(bool condition, const char* message) {
  ++g_assertions;
  if (!condition) {
    std::cerr << "FAIL: " << message << "\n";
    return false;
  }
  return true;
}

constexpr int64_t kChunkUs = 10000;

// Feeds the clock from a timer that ticks every [tick_us] for [seconds] and
// returns how many chunks were delivered.
int64_t Deliver(int64_t tick_us, int seconds) {
  fushi::AudioFeedClock clock(kChunkUs, 8, 300000);
  clock.Start(0);
  int64_t delivered = 0;
  for (int64_t now = tick_us; now <= seconds * 1000000LL; now += tick_us) {
    for (int due = clock.Due(now); due > 0; --due) {
      clock.Delivered();
      ++delivered;
    }
  }
  return delivered;
}

bool TestSlowTimersStillDeliverRealTime() {
  bool ok = true;
  // Upstream fed one chunk per tick: a 10.3 ms timer delivered 97 % and a
  // 15.6 ms one 64 % of real time. Owing chunks by elapsed time must deliver
  // the full 1000 chunks in 10 s whatever the tick rate.
  for (int64_t tick : {5000LL, 10000LL, 10300LL, 15625LL, 33000LL}) {
    const int64_t delivered = Deliver(tick, 10);
    ok &= Expect(delivered >= 997 && delivered <= 1000,
                 "10 s of ticks deliver 10 s of audio");
  }
  return ok;
}

bool TestNeverRunsAhead() {
  fushi::AudioFeedClock clock(kChunkUs, 8, 300000);
  clock.Start(0);
  bool ok = Expect(clock.Due(9999) == 0, "nothing owed before one chunk");
  ok &= Expect(clock.Due(10000) == 1, "one chunk owed after 10 ms");
  clock.Delivered();
  ok &= Expect(clock.Due(15000) == 0, "delivered chunk is not owed again");
  return ok;
}

bool TestBurstIsBounded() {
  fushi::AudioFeedClock clock(kChunkUs, 8, 300000);
  clock.Start(0);
  bool ok = Expect(clock.Due(150000) == 8, "a 150 ms debt is paid 8 at a time");
  for (int i = 0; i < 8; ++i) clock.Delivered();
  ok &= Expect(clock.Due(150000) == 7, "the rest follows on the next wake");
  return ok;
}

bool TestLongStallResyncs() {
  fushi::AudioFeedClock clock(kChunkUs, 8, 300000);
  clock.Start(0);
  bool ok = Expect(clock.Due(2000000) == 1, "a 2 s stall re-anchors");
  clock.Delivered();
  ok &= Expect(clock.Due(2000000) == 0, "and owes nothing afterwards");
  ok &= Expect(clock.Due(2010000) == 1, "then resumes at real time");
  return ok;
}

bool TestNotStarted() {
  fushi::AudioFeedClock clock(kChunkUs, 8, 300000);
  return Expect(clock.Due(1000000) == 0, "an unstarted clock owes nothing");
}

}  // namespace

int main() {
  bool ok = true;
  ok &= TestSlowTimersStillDeliverRealTime();
  ok &= TestNeverRunsAhead();
  ok &= TestBurstIsBounded();
  ok &= TestLongStallResyncs();
  ok &= TestNotStarted();
  if (!ok) return 1;
  std::cout << "game_stream_audio_feed_clock_test: " << g_assertions
            << " assertions passed\n";
  return 0;
}
