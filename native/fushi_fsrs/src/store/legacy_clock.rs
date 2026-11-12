//! 旧版 HLC 时钟与旧版写入者（收掉 Dart 写路径第 6 步）。
//!
//! 本机复习日志的排序键是日志自带的 HLC `<物理毫秒>:<计数器>:<写入者>`（[super::sync2::log_row] 原样保留，不是
//! 同步 v2 操作的 HLC），写入者是旧协议的写入者 ID `<设备>#<化身号>`。这只时钟以前由 Dart 持有
//! （`SrsDbStore._clock` / `HlcClock`，状态存在本机状态行的 `hlc` / `writerId`）：作答时 Dart 打 HLC，手动排程操作
//! （`sched`）把时钟交进来让内核接着推进再交回去。现在状态与推进规则都在这里：`apply` / `sched` 在命令的同一个
//! SAVEPOINT 里 [LegacyClock::load] → 推进 → [LegacyClock::save]，命令回滚时钟随之回滚。Dart 不再有时钟的内存副本：
//! 同一个库上开着两个副本对象（备份并入 / 档案并入各自另开一个）、或写入回滚时，以前两份内存时钟各走
//! 各的、回滚后要靠 `reloadLocal` 对齐，现在只有库里这一份。
//!
//! **推进规则与 Dart 旧实现逐值相同**（已落库的 HLC 的字节表示与排序语义不变）：[LegacyClock::tick] /
//! [LegacyClock::receive] 对拍 `tests/fixtures/legacy_clock_vectors.json`——搬之前用 Dart `HlcClock` 跑出来冻结的
//! 向量（生成器 packages/fushi_engine/test/srs/fixtures/gen_legacy_clock_vectors.dart.txt）。
//!
//! 本机状态行里的键（整行只有内核写，store/local_state.rs；这几个键只有这里写）：
//! - `hlc`、`writerId`：这里读写。
//! - `incarnation`：只读（没有 `writerId` 时拼缺省写入者）。它与 `lastSeq` / `applied` / `outboxSeq` 是旧版 Dart
//!   写入者的状态，现在没有写入方：存量行里的值原样留着（降级回旧版本还读得到），新行没有这几个键（旧版本按缺省
//!   读，等价于新设备）。
//!
//! 行里的 `hlc` 解析不了（损坏）时 [LegacyClock::load] 报错：`apply` / `sched` 明确失败、什么都不落。以前是 Dart 打开
//! 副本时 `Hlc.decode` 抛错（打不开）；现在副本打得开、读照常，写入失败。

use rusqlite::{Connection, OptionalExtension, params};
use serde_json::Value;

use super::sync2::sql;

/// 本机状态行里旧版时钟 / 写入者的键（内核持有）。
pub(crate) const HLC_KEY: &str = "hlc";
pub(crate) const WRITER_KEY: &str = "writerId";
/// 旧版 Dart 写入者留下、现在没有写入方的键（见模块文档）。
pub(crate) const FROZEN_KEYS: [&str; 4] = ["incarnation", "lastSeq", "applied", "outboxSeq"];

/// 排序与 HLC 推进共用的容差：发布时服务器时间 S 之后最多 10 分钟（Dart `srsClockToleranceMs`）。
pub(crate) const TOLERANCE_MS: i64 = 10 * 60 * 1000;

/// 一个旧版 HLC 值。线格式 `<physical>:<counter>:<writer>`，写入者可含冒号，只切前两段（Dart `Hlc.decode`）。
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct LegacyHlc {
    pub physical: i64,
    pub counter: i64,
    pub writer: String,
}

impl LegacyHlc {
    pub(crate) fn parse(text: &str) -> Result<LegacyHlc, String> {
        let mut parts = text.splitn(3, ':');
        let (Some(p), Some(c), Some(w)) = (parts.next(), parts.next(), parts.next()) else {
            return Err(format!("bad hlc: {text}"));
        };
        Ok(LegacyHlc {
            physical: p.parse().map_err(|_| format!("bad hlc: {text}"))?,
            counter: c.parse().map_err(|_| format!("bad hlc: {text}"))?,
            writer: w.to_owned(),
        })
    }

    pub(crate) fn encode(&self) -> String {
        format!("{}:{}:{}", self.physical, self.counter, self.writer)
    }
}

/// [profile] 的本机状态行（没有这一行、或那一行解析不了 = `Null`，各键按缺省读）。
fn read_state(c: &Connection, profile: &str) -> Result<Value, String> {
    let row: Option<String> = c
        .prepare_cached("SELECT json FROM srs_local_state WHERE profile_uid = srs_id(?1)")
        .map_err(sql)?
        .query_row([profile], |r| r.get(0))
        .optional()
        .map_err(sql)?;
    Ok(row
        .as_deref()
        .and_then(|j| serde_json::from_str::<Value>(j).ok())
        .unwrap_or(Value::Null))
}

/// 本机旧版写入者：行里的 `writerId`，没有则 `<device>#<行里的 incarnation，缺省 1>`（[device] 是宿主的设备 ID，
/// Dart `SrsDbStore.deviceId`）。
fn writer_in(state: &Value, device: &str) -> String {
    match state.get(WRITER_KEY).and_then(Value::as_str) {
        Some(w) => w.to_owned(),
        None => {
            let incarnation = state
                .get(FROZEN_KEYS[0])
                .and_then(Value::as_i64)
                .unwrap_or(1);
            format!("{device}#{incarnation}")
        }
    }
}

/// [profile] 的本机旧版写入者 ID（`identity` 回包的 `legacyWriter`）。只读；不看 `hlc`（损坏的时钟不影响认写入者）。
pub(crate) fn writer_of(c: &Connection, profile: &str, device: &str) -> Result<String, String> {
    Ok(writer_in(&read_state(c, profile)?, device))
}

/// 本机旧版时钟：已见过的最大 HLC（写入者恒为本机旧版写入者）。
pub(crate) struct LegacyClock {
    last: LegacyHlc,
    /// 库里的值与 [last] 不一致（推进过，或行里还没有 `hlc` / `writerId`）。
    dirty: bool,
    /// 行里已有 `writerId`。
    writer_stored: bool,
}

impl LegacyClock {
    /// 从 [start] 起的时钟（对拍与单测用；[load] 是唯一的生产入口）。
    #[cfg(test)]
    pub(crate) fn starting_at(start: LegacyHlc) -> LegacyClock {
        LegacyClock {
            last: start,
            dirty: false,
            writer_stored: true,
        }
    }

    /// 读 [profile] 的本机状态行。写入者见 [writer_in]；时钟 = 行里的 `hlc`（写入者换成本机写入者，Dart 旧
    /// `_rehome`），没有则 `(0, 0, 写入者)`。只读，不建行。
    pub(crate) fn load(c: &Connection, profile: &str, device: &str) -> Result<LegacyClock, String> {
        let state = read_state(c, profile)?;
        let stored_writer = state.get(WRITER_KEY).and_then(Value::as_str);
        let writer = writer_in(&state, device);
        let stored_hlc = state.get(HLC_KEY).and_then(Value::as_str);
        let last = match stored_hlc {
            Some(h) => {
                let h = LegacyHlc::parse(h)
                    .map_err(|e| format!("srs local state: stored legacy clock: {e}"))?;
                LegacyHlc {
                    physical: h.physical,
                    counter: h.counter,
                    writer: writer.clone(),
                }
            }
            None => LegacyHlc {
                physical: 0,
                counter: 0,
                writer: writer.clone(),
            },
        };
        Ok(LegacyClock {
            dirty: stored_hlc != Some(last.encode().as_str()),
            writer_stored: stored_writer.is_some(),
            last,
        })
    }

    #[cfg(test)]
    pub(crate) fn last(&self) -> &LegacyHlc {
        &self.last
    }

    /// 本机发出事件：取 max(可信时间, 已见过的最大 HLC)（Dart `HlcClock.tick`）。返回新值的线格式。
    pub(crate) fn tick(&mut self, now: i64) -> String {
        if now > self.last.physical {
            self.last.physical = now;
            self.last.counter = 0;
        } else {
            // Dart `int` 的加法溢出回绕，这里同样回绕（不 panic）；实际到不了。
            self.last.counter = self.last.counter.wrapping_add(1);
        }
        self.dirty = true;
        self.last.encode()
    }

    /// 收到来源自带 HLC 的事件（导入的日志 / 记录、并入的外来事件）：**先钳位再推进**（Dart `HlcClock.receive`）。
    /// 用 `min(远端物理时间, S(e) + 10 分钟)` 推进；S 未知（[server] 为 None）时只推进到 `本机可信时间 + 10 分钟`。
    /// 不钳位的话，一台时钟快一年的设备会把所有收到它数据的设备的 HLC 推到一年后。
    pub(crate) fn receive(&mut self, remote: &LegacyHlc, server: Option<i64>, now: i64) {
        // 回绕加：与 Dart `int` 相同（S 来自旧备份的 `server_times.json`，不可信；饱和加会让一个极大的 S 把钳位放开）。
        let bound = server.unwrap_or(now).wrapping_add(TOLERANCE_MS);
        let effective = remote.physical.min(bound);
        if effective > self.last.physical {
            self.last.physical = effective;
            self.last.counter = 0;
            self.dirty = true;
        } else if effective == self.last.physical && remote.physical == effective {
            let counter = remote.counter.max(self.last.counter);
            if counter != self.last.counter {
                self.last.counter = counter;
                self.dirty = true;
            }
        }
    }

    /// 把时钟（与还没存过的写入者）写进本机状态行；库里已是这个值就不写。行还不存在时先建行（local_state.rs `ensure_row`：当前缓存
    /// 版本 + 新纪元），再写自己的键——不动别的键。`apply` / `sched` 每次都调：行里还没有
    /// `hlc` / `writerId`（新库第一次写、覆盖恢复之后）时即使时钟没推进也会写下 `(0, 0, 写入者)`，与以前 Dart 随
    /// 命令交来的整行相同。
    pub(crate) fn save(&mut self, c: &Connection, profile: &str) -> Result<(), String> {
        if !self.dirty && self.writer_stored {
            return Ok(());
        }
        crate::store::local_state::ensure_row(c, profile)?;
        c.prepare_cached(
            "UPDATE srs_local_state SET json = json_set(json, '$.hlc', ?2, '$.writerId', ?3) \
             WHERE profile_uid = srs_id(?1)",
        )
        .map_err(sql)?
        .execute(params![profile, self.last.encode(), self.last.writer])
        .map_err(sql)?;
        self.dirty = false;
        self.writer_stored = true;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    /// 搬之前用 Dart `HlcClock` 跑出来冻结的向量（见模块文档）：每一步之后时钟的值逐个相等。
    #[test]
    fn tick_and_receive_match_the_frozen_dart_vectors() {
        let doc: Value = serde_json::from_str(include_str!(
            "../../tests/fixtures/legacy_clock_vectors.json"
        ))
        .unwrap();
        assert_eq!(doc["toleranceMs"], json!(TOLERANCE_MS));
        let mut steps = 0;
        for (ci, case) in doc["cases"].as_array().unwrap().iter().enumerate() {
            let start = LegacyHlc::parse(case["start"].as_str().unwrap()).unwrap();
            assert_eq!(start.writer, case["writer"].as_str().unwrap());
            let mut clock = LegacyClock::starting_at(start);
            for (si, s) in case["steps"].as_array().unwrap().iter().enumerate() {
                let now = s["now"].as_i64().unwrap();
                let want = s["out"].as_str().unwrap();
                match s["op"].as_str().unwrap() {
                    "tick" => {
                        assert_eq!(clock.tick(now), want, "case {ci} step {si}: {s}");
                    }
                    "recv" => {
                        let remote = LegacyHlc::parse(s["remote"].as_str().unwrap()).unwrap();
                        clock.receive(&remote, s["server"].as_i64(), now);
                    }
                    other => panic!("unknown op {other}"),
                }
                assert_eq!(clock.last().encode(), want, "case {ci} step {si}: {s}");
                steps += 1;
            }
        }
        assert!(steps > 1000, "vectors were not loaded ({steps} steps)");
    }

    #[test]
    fn the_wire_form_only_splits_the_first_two_colons() {
        let h = LegacyHlc::parse("12:3:a:b#1").unwrap();
        assert_eq!((h.physical, h.counter, h.writer.as_str()), (12, 3, "a:b#1"));
        assert_eq!(h.encode(), "12:3:a:b#1");
        assert_eq!(LegacyHlc::parse("-7:0:").unwrap().writer, "");
        assert!(LegacyHlc::parse("12:3").is_err());
        assert!(LegacyHlc::parse("x:3:w").is_err());
    }
}
