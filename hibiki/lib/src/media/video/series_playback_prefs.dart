// 同系列（合集）播放偏好解析（schema v52，恢复统一合集迁移前「多集共享一个音轨 /
// 一个字幕调轴」的行为）。统一合集把多集视频从「一行 VideoBooks 共享偏好」拆成「每集
// 独立行」，换集不再共享 → 同系列音轨/调轴记忆退化。修根方向是把偏好提升回系列容器
// （MediaCollections.audioTrackId / subtitleDelayMs）。
//
// 这里只放**纯函数**的「系列级优先、回退 per-book」解析规则，与 DB / widget 状态解耦，
// 便于单测覆盖优先级语义。加载某集时：系列级值非 null → 用系列级（同系列共享）；系列级
// 为 null（系列内没人设过）→ 回退该集自己行的 per-book 值（兼容迁移前已存的各集值，
// Never break userspace）。

/// 解析生效的音轨 id。
/// [collectionValue] 系列（合集）级音轨偏好；null = 系列内没人选过。
/// [perBookValue] 本集自己行的 [VideoBooks.audioTrackId]；null = 本集没选过。
/// 系列级优先，回退 per-book；两者皆 null → null（跟随 libmpv 默认）。
String? effectiveSeriesAudioTrackId(
  String? collectionValue,
  String? perBookValue,
) =>
    collectionValue ?? perBookValue;

/// 解析生效的字幕调轴（音画延迟毫秒）。
/// [collectionValue] 系列（合集）级调轴；null = 系列内没人调过（区别于「显式调成 0」）。
/// [perBookValue] 本集自己行的 [VideoBooks.delayMs]（withDefault(0)，非 null）。
/// 系列级非 null 优先，否则回退 per-book。
int effectiveSeriesDelayMs(int? collectionValue, int perBookValue) =>
    collectionValue ?? perBookValue;
