//! `ffc_pano_*`：媒体库全景（首页「媒体库全景」与分享用 16 秒开场动画）的胖核心。
//!
//! 状态全在本模块：作品 / 词的三套布局（大爆炸星系、球幕、环绕轨道）、交互镜头（拖拽惯性、
//! 缩放）、锁定飞入、每帧投影与远近样式。Dart 侧只在建图时交一次「图集格子 + 作品 + 词 +
//! 字形」表，之后每帧一次 [ffc_pano_frame]，拿回按远到近排好的 `drawRawAtlas` 批数据
//! （RSTransform / 源矩形 / 调制色 / 分页批次）直接画，不另存镜像状态。
//!
//! 坐标系：右手系，y 朝上；星系盘在 xz 平面，球幕球心在原点。镜头由 yaw（绕 y）、pitch（俯仰）
//! 与 dist（沿视线反方向离球心的距离）描述：dist = 0 即站在球心环顾。
//!
//! 输出缓冲区由本模块持有、容量建图时定死（[ffc_pano_buffers] 取一次指针即可，帧间不变）。

use std::f32::consts::{PI, TAU};

use crate::{guard, status};

/// 分享动画总长（秒）。
pub const CINEMATIC_SECONDS: f32 = 16.0;
const T_BANG_END: f32 = 1.2;
const T_GALAXY_END: f32 = 5.5;
const T_SPHERE_END: f32 = 8.0;
const T_LOOK_END: f32 = 11.0;
/// 锁定开始到封面停在眼前（秒）：前 [LOCK_TURN] 秒转向，其余沿半径飞来。
const LOCK_SECONDS: f32 = 2.5;
const LOCK_TURN: f32 = 0.9;
/// 封面停稳后交给 Flutter 翻开的时刻。
pub const T_HANDOFF: f32 = T_LOOK_END + LOCK_SECONDS;

const SPHERE_RADIUS: f32 = 12.0;
const SHELL_MIN: f32 = 15.0;
const SHELL_MAX: f32 = 19.0;
const GALAXY_RADIUS: f32 = 30.0;
const GALAXY_CAMERA_DIST: f32 = 46.0;
const GALAXY_CAMERA_PITCH: f32 = -0.62;
const MAX_DIST: f32 = 34.0;
const NEAR_PLANE: f32 = 0.25;
/// 远近样式：距离 ≤ NEAR 视为最近（粗、大、气泡字），≥ FAR 视为最远（细、小、淡）。
const STYLE_NEAR: f32 = 3.0;
const STYLE_FAR: f32 = 16.0;
/// 其他元素在锁定后的亮度。
const DIM_LEVEL: f32 = 0.1;
/// 飞到眼前的封面高度占视口高度的比例。
const TARGET_SCREEN_HEIGHT: f32 = 0.62;
const FOV_Y: f32 = 1.05;

/// 帧信息槽位（`info` 数组下标），Dart 侧 `PanoInfo` 同表。
pub mod info {
    pub const HALO_X: usize = 0;
    pub const HALO_Y: usize = 1;
    pub const HALO_R: usize = 2;
    pub const HALO_ALPHA: usize = 3;
    pub const FORWARD: usize = 4; // 4..7
    pub const RIGHT: usize = 7; // 7..10
    pub const UP: usize = 10; // 10..13
    pub const FOCAL: usize = 13;
    pub const TARGET_VISIBLE: usize = 14;
    pub const TARGET_RECT: usize = 15; // x, y, w, h（封面本体，不含辉光留边）
    pub const LOCK_PROGRESS: usize = 19;
    pub const PHASE: usize = 20;
    pub const HANDOFF: usize = 21;
    pub const DIM: usize = 22;
    pub const TARGET_COLOR: usize = 23;
    pub const LEN: usize = 32;
}

/// 输入事件种类（[ffc_pano_input]）。
pub mod input {
    /// 拖拽：a = dx 像素，b = dy 像素。
    pub const DRAG: i32 = 0;
    /// 松手：a / b = 像素每秒的速度。
    pub const RELEASE: i32 = 1;
    /// 缩放：a = 比例（>1 拉近）。
    pub const ZOOM: i32 = 2;
    /// 按下：停住惯性。
    pub const HOLD: i32 = 3;
}

pub const MODE_INTERACTIVE: i32 = 0;
pub const MODE_CINEMATIC: i32 = 1;

/// splitmix64：确定性、无依赖的伪随机。
struct Rng(u64);

impl Rng {
    fn next_u64(&mut self) -> u64 {
        self.0 = self.0.wrapping_add(0x9E37_79B9_7F4A_7C15);
        let mut z = self.0;
        z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
        z ^ (z >> 31)
    }

    /// [0, 1)
    fn unit(&mut self) -> f32 {
        (self.next_u64() >> 40) as f32 / (1u64 << 24) as f32
    }

    fn range(&mut self, lo: f32, hi: f32) -> f32 {
        lo + (hi - lo) * self.unit()
    }

    fn gauss(&mut self) -> f32 {
        let u = self.unit().max(1e-6);
        let v = self.unit();
        (-2.0 * u.ln()).sqrt() * (TAU * v).cos()
    }

    fn unit_vector(&mut self) -> V3 {
        let z = self.range(-1.0, 1.0);
        let a = self.range(0.0, TAU);
        let r = (1.0 - z * z).max(0.0).sqrt();
        V3(r * a.cos(), r * a.sin(), z)
    }
}

#[derive(Clone, Copy, Debug, Default, PartialEq)]
struct V3(f32, f32, f32);

impl V3 {
    fn add(self, o: V3) -> V3 {
        V3(self.0 + o.0, self.1 + o.1, self.2 + o.2)
    }
    fn sub(self, o: V3) -> V3 {
        V3(self.0 - o.0, self.1 - o.1, self.2 - o.2)
    }
    fn scale(self, s: f32) -> V3 {
        V3(self.0 * s, self.1 * s, self.2 * s)
    }
    fn dot(self, o: V3) -> f32 {
        self.0 * o.0 + self.1 * o.1 + self.2 * o.2
    }
    fn cross(self, o: V3) -> V3 {
        V3(
            self.1 * o.2 - self.2 * o.1,
            self.2 * o.0 - self.0 * o.2,
            self.0 * o.1 - self.1 * o.0,
        )
    }
    fn len(self) -> f32 {
        self.dot(self).sqrt()
    }
    fn norm(self) -> V3 {
        let l = self.len();
        if l < 1e-9 {
            V3(0.0, 0.0, 1.0)
        } else {
            self.scale(1.0 / l)
        }
    }
    fn lerp(self, o: V3, t: f32) -> V3 {
        self.add(o.sub(self).scale(t))
    }
}

fn clamp01(x: f32) -> f32 {
    x.clamp(0.0, 1.0)
}

fn smooth(x: f32) -> f32 {
    let x = clamp01(x);
    x * x * (3.0 - 2.0 * x)
}

fn ease_in_out(x: f32) -> f32 {
    let x = clamp01(x);
    if x < 0.5 {
        4.0 * x * x * x
    } else {
        1.0 - (-2.0 * x + 2.0).powi(3) / 2.0
    }
}

fn ease_out_expo(x: f32) -> f32 {
    let x = clamp01(x);
    if x >= 1.0 {
        1.0
    } else {
        1.0 - 2f32.powf(-10.0 * x)
    }
}

/// 最短角差（-π, π]。
fn angle_delta(from: f32, to: f32) -> f32 {
    let mut d = (to - from) % TAU;
    if d > PI {
        d -= TAU;
    } else if d <= -PI {
        d += TAU;
    }
    d
}

fn hsv_to_rgb(h: f32, s: f32, v: f32) -> (f32, f32, f32) {
    let h = (h.rem_euclid(1.0)) * 6.0;
    let i = h.floor();
    let f = h - i;
    let p = v * (1.0 - s);
    let q = v * (1.0 - s * f);
    let t = v * (1.0 - s * (1.0 - f));
    match i as i32 {
        0 => (v, t, p),
        1 => (q, v, p),
        2 => (p, v, t),
        3 => (p, q, v),
        4 => (t, p, v),
        _ => (v, p, q),
    }
}

/// ARGB 打包（Flutter `Color.value` 的位序；Dart 侧按 Int32List 读）。
fn argb(a: f32, r: f32, g: f32, b: f32) -> i32 {
    let c = |x: f32| (clamp01(x) * 255.0 + 0.5) as u32;
    ((c(a) << 24) | (c(r) << 16) | (c(g) << 8) | c(b)) as i32
}

/// 镜头：yaw / pitch / 离球心距离。
#[derive(Clone, Copy, Debug, PartialEq)]
struct Camera {
    yaw: f32,
    pitch: f32,
    dist: f32,
}

struct Basis {
    pos: V3,
    forward: V3,
    right: V3,
    up: V3,
}

impl Camera {
    fn basis(&self) -> Basis {
        let (sy, cy) = self.yaw.sin_cos();
        let (sp, cp) = self.pitch.sin_cos();
        let forward = V3(sy * cp, sp, -cy * cp);
        let right = V3(cy, 0.0, sy);
        let up = right.cross(forward).norm();
        Basis {
            pos: forward.scale(-self.dist),
            forward,
            right,
            up,
        }
    }

    /// 从球心看向 [dir] 的 yaw / pitch。
    fn facing(dir: V3) -> (f32, f32) {
        let d = dir.norm();
        let pitch = d.1.clamp(-1.0, 1.0).asin();
        let yaw = d.0.atan2(-d.2);
        (yaw, pitch)
    }
}

struct Work {
    /// 宽 / 高（建图后只有测试读它核对比例）。
    #[cfg_attr(not(test), allow(dead_code))]
    aspect: f32,
    cell: usize,
    /// 封面本体在格子里的像素宽（不含辉光留边）。
    cover_px_w: f32,
    /// 世界尺寸（面积统一）。
    w: f32,
    h: f32,
    hue: f32,
    // 星系参数
    arm_angle: f32,
    galaxy_r: f32,
    galaxy_y: f32,
    // 球幕位置
    sphere: V3,
    /// 进场错峰（0..1）。
    stagger: f32,
}

struct Word {
    owner: Option<usize>,
    glyph_start: usize,
    glyph_count: usize,
    /// 字身世界高度。
    em: f32,
    hue: f32,
    // 环绕轨道（有主）：轨道平面两轴、半径、角速度、初相
    orbit_a: V3,
    orbit_b: V3,
    orbit_r: f32,
    orbit_w: f32,
    orbit_phase: f32,
    // 无主：星系尘埃 + 外壳
    arm_angle: f32,
    galaxy_r: f32,
    galaxy_y: f32,
    shell: V3,
    stagger: f32,
    /// 字形总宽（em 倍数）。
    advance: f32,
}

struct Glyph {
    thin: usize,
    fill: usize,
    outline: usize,
    advance: f32,
}

#[derive(Clone, Copy)]
struct Lock {
    target: usize,
    t0: f32,
    from: Camera,
    to: Camera,
}

/// 一个待画元素（排序用）。
#[derive(Clone, Copy)]
struct Item {
    depth: f32,
    /// 作品下标；词为 `!0 - 词下标`。
    id: u32,
}

const WORD_FLAG: u32 = 1 << 31;

pub struct Pano {
    cells: Vec<[f32; 4]>,
    cell_page: Vec<i32>,
    /// 字形格子的字身像素高（Dart 绘制图集时的 em 像素）。
    glyph_em_px: f32,
    works: Vec<Work>,
    words: Vec<Word>,
    glyphs: Vec<Glyph>,

    mode: i32,
    cinematic_target: Option<usize>,
    camera: Camera,
    vel_yaw: f32,
    vel_pitch: f32,
    holding: bool,
    lock: Option<Lock>,
    /// 交互模式下的动画时钟（秒，供轨道旋转）。
    clock: f32,
    last_t: Option<f32>,

    items: Vec<Item>,
    /// 上一帧每个作品在屏幕上的封面矩形（拾取用；不可见为 w = 0）。
    pick_rects: Vec<[f32; 4]>,

    out_xform: Vec<f32>,
    out_rect: Vec<f32>,
    out_color: Vec<i32>,
    out_batch: Vec<i32>,
    out_info: Vec<f32>,
    sprites: usize,
    batches: usize,
}

/// 帧状态（一帧内的布局求值上下文）。
struct Frame {
    clock: f32,
    /// 0 = 星系，1 = 球幕。
    morph: f32,
    /// 大爆炸展开（0 = 全部在原点，1 = 展开完）。
    bang: f32,
    dim: f32,
    target: Option<usize>,
    /// 目标从球面飞向镜头的进度（0..1）。
    fly: f32,
    fly_to: V3,
}

impl Pano {
    #[allow(clippy::too_many_arguments)]
    fn build(
        cells: Vec<[f32; 4]>,
        cell_page: Vec<i32>,
        works_f: &[f32],
        works_cell: &[i32],
        words_i: &[i32],
        glyph_cells: &[i32],
        glyph_adv: &[f32],
        glyph_em_px: f32,
        seed: u64,
    ) -> Result<Pano, i32> {
        let n_cells = cells.len();
        let n_works = works_cell.len();
        let n_words = words_i.len() / 3;
        let n_glyphs = glyph_adv.len();
        if works_f.len() != n_works * 3
            || words_i.len() != n_words * 3
            || glyph_cells.len() != n_glyphs * 3
            || cell_page.len() != n_cells
            || glyph_em_px <= 0.0
        {
            return Err(status::INVALID_ARGUMENT);
        }
        let cell_of = |c: i32| -> Result<usize, i32> {
            if c < 0 || c as usize >= n_cells {
                Err(status::INVALID_ARGUMENT)
            } else {
                Ok(c as usize)
            }
        };
        let mut glyphs = Vec::with_capacity(n_glyphs);
        for g in 0..n_glyphs {
            glyphs.push(Glyph {
                thin: cell_of(glyph_cells[g * 3])?,
                fill: cell_of(glyph_cells[g * 3 + 1])?,
                outline: cell_of(glyph_cells[g * 3 + 2])?,
                advance: glyph_adv[g].max(0.0),
            });
        }

        let mut rng = Rng(seed ^ 0x5DEE_CE66_D1CE_4E5B);
        // 卡片面积统一：覆盖球面约 35%，上下限防止极少 / 极多作品时失真。
        let sphere_area = 4.0 * PI * SPHERE_RADIUS * SPHERE_RADIUS;
        let card_area = (0.35 * sphere_area / n_works.max(1) as f32).clamp(0.5, 7.0);
        let golden = PI * (3.0 - 5f32.sqrt());

        let mut works = Vec::with_capacity(n_works);
        for i in 0..n_works {
            let aspect = works_f[i * 3].clamp(0.2, 5.0);
            let cover_px_w = works_f[i * 3 + 1];
            let hue = works_f[i * 3 + 2];
            if !cover_px_w.is_finite() || cover_px_w <= 0.0 || !hue.is_finite() {
                return Err(status::INVALID_ARGUMENT);
            }
            let w = (card_area * aspect).sqrt();
            let h = (card_area / aspect).sqrt();
            // 斐波那契球：均匀铺满且确定。
            let y = if n_works == 1 {
                0.0
            } else {
                1.0 - 2.0 * (i as f32 + 0.5) / n_works as f32
            };
            let r = (1.0 - y * y).max(0.0).sqrt();
            let a = golden * i as f32;
            let sphere = V3(r * a.cos(), y, r * a.sin()).scale(SPHERE_RADIUS);
            let arm = (i % 3) as f32 * TAU / 3.0;
            let galaxy_r = 2.5 + (GALAXY_RADIUS - 2.5) * rng.unit().sqrt();
            works.push(Work {
                aspect,
                cell: cell_of(works_cell[i])?,
                cover_px_w,
                w,
                h,
                hue,
                arm_angle: arm + rng.gauss() * 0.22,
                galaxy_r,
                galaxy_y: rng.gauss() * (1.6 - galaxy_r / GALAXY_RADIUS),
                sphere,
                stagger: rng.unit(),
            });
        }

        let mean_h = if works.is_empty() {
            1.5
        } else {
            works.iter().map(|w| w.h).sum::<f32>() / works.len() as f32
        };
        let mut words = Vec::with_capacity(n_words);
        let unowned_total = words_i
            .chunks_exact(3)
            .filter(|c| c[0] < 0 || c[0] as usize >= n_works)
            .count()
            .max(1);
        let mut unowned_seen = 0usize;
        for i in 0..n_words {
            let owner_raw = words_i[i * 3];
            let start = words_i[i * 3 + 1];
            let count = words_i[i * 3 + 2];
            if start < 0 || count < 0 || (start as usize + count as usize) > n_glyphs {
                return Err(status::INVALID_ARGUMENT);
            }
            let (start, count) = (start as usize, count as usize);
            let owner = if owner_raw >= 0 && (owner_raw as usize) < n_works {
                Some(owner_raw as usize)
            } else {
                None
            };
            let advance: f32 = glyphs[start..start + count].iter().map(|g| g.advance).sum();
            // 随机倾斜的轨道平面：法向随机，两轴正交。
            let normal = rng.unit_vector();
            let helper = if normal.1.abs() < 0.9 {
                V3(0.0, 1.0, 0.0)
            } else {
                V3(1.0, 0.0, 0.0)
            };
            let orbit_a = normal.cross(helper).norm();
            let orbit_b = normal.cross(orbit_a).norm();
            let (em, hue, orbit_r) = match owner {
                Some(o) => {
                    let wk = &works[o];
                    let size = wk.w.max(wk.h);
                    (
                        mean_h * 0.08,
                        (wk.hue + rng.gauss() * 0.04).rem_euclid(1.0),
                        size * rng.range(0.62, 1.15),
                    )
                }
                None => (mean_h * 0.2, rng.unit(), 0.0),
            };
            let shell = if owner.is_none() {
                let k = unowned_seen;
                unowned_seen += 1;
                let y = 1.0 - 2.0 * (k as f32 + 0.5) / unowned_total as f32;
                let r = (1.0 - y * y).max(0.0).sqrt();
                let a = golden * k as f32 + rng.gauss() * 0.05;
                V3(r * a.cos(), y, r * a.sin()).scale(rng.range(SHELL_MIN, SHELL_MAX))
            } else {
                V3::default()
            };
            let arm = (rng.next_u64() % 3) as f32 * TAU / 3.0;
            let galaxy_r = 4.0 + (GALAXY_RADIUS * 1.15 - 4.0) * rng.unit().sqrt();
            words.push(Word {
                owner,
                glyph_start: start,
                glyph_count: count,
                em,
                hue,
                orbit_a,
                orbit_b,
                orbit_r,
                orbit_w: rng.range(0.25, 0.6) * if rng.unit() < 0.5 { -1.0 } else { 1.0 },
                orbit_phase: rng.range(0.0, TAU),
                arm_angle: arm + rng.gauss() * 0.35,
                galaxy_r,
                galaxy_y: rng.gauss() * 2.2,
                shell,
                stagger: rng.unit(),
                advance,
            });
        }

        // 容量：每作品 1 张；每字形最多 3 张（细 / 描边 / 字心交叉淡化时同时出）。
        let capacity = n_works + n_glyphs * 3;
        let batch_capacity = (capacity + 1).max(1);
        Ok(Pano {
            cells,
            cell_page,
            glyph_em_px,
            pick_rects: vec![[0.0; 4]; n_works],
            works,
            words,
            glyphs,
            mode: MODE_INTERACTIVE,
            cinematic_target: None,
            camera: Camera {
                yaw: 0.0,
                pitch: 0.0,
                dist: 0.0,
            },
            vel_yaw: 0.0,
            vel_pitch: 0.0,
            holding: false,
            lock: None,
            clock: 0.0,
            last_t: None,
            items: Vec::with_capacity(n_works + n_words),
            out_xform: vec![0.0; capacity.max(1) * 4],
            out_rect: vec![0.0; capacity.max(1) * 4],
            out_color: vec![0; capacity.max(1)],
            out_batch: vec![0; batch_capacity * 3],
            out_info: vec![0.0; info::LEN],
            sprites: 0,
            batches: 0,
        })
    }

    fn set_mode(&mut self, mode: i32, target: i32) -> i32 {
        if mode != MODE_INTERACTIVE && mode != MODE_CINEMATIC {
            return status::INVALID_ARGUMENT;
        }
        self.mode = mode;
        self.lock = None;
        self.last_t = None;
        self.vel_yaw = 0.0;
        self.vel_pitch = 0.0;
        self.cinematic_target = if target >= 0 && (target as usize) < self.works.len() {
            Some(target as usize)
        } else {
            None
        };
        if mode == MODE_INTERACTIVE {
            self.camera = Camera {
                yaw: 0.0,
                pitch: 0.0,
                dist: 0.0,
            };
        }
        status::OK
    }

    /// 像素 → 弧度：视口高度对应约一个视场角。
    fn drag_gain(&self) -> f32 {
        0.0042
    }

    fn input(&mut self, kind: i32, a: f32, b: f32) -> i32 {
        if !a.is_finite() || !b.is_finite() {
            return status::INVALID_ARGUMENT;
        }
        if self.mode != MODE_INTERACTIVE || self.lock.is_some() {
            return status::OK;
        }
        let g = self.drag_gain();
        match kind {
            input::DRAG => {
                self.camera.yaw -= a * g;
                self.camera.pitch = (self.camera.pitch + b * g).clamp(-1.45, 1.45);
                self.holding = true;
            }
            input::RELEASE => {
                self.vel_yaw = -a * g;
                self.vel_pitch = b * g;
                self.holding = false;
            }
            input::HOLD => {
                self.vel_yaw = 0.0;
                self.vel_pitch = 0.0;
                self.holding = true;
            }
            input::ZOOM => {
                if a <= 0.0 {
                    return status::INVALID_ARGUMENT;
                }
                // 球心（dist = 0）拉远到球外：按比例换算成距离增量，球心附近也能推出去。
                let d = self.camera.dist + 1.0;
                self.camera.dist = (d / a - 1.0).clamp(0.0, MAX_DIST);
            }
            _ => return status::INVALID_ARGUMENT,
        }
        status::OK
    }

    fn select(&mut self, work: i32, t: f32) -> i32 {
        if work < 0 || work as usize >= self.works.len() {
            return status::INVALID_ARGUMENT;
        }
        let target = work as usize;
        let (yaw, pitch) = Camera::facing(self.works[target].sphere);
        let from = self.camera;
        self.lock = Some(Lock {
            target,
            t0: t,
            from,
            to: Camera {
                yaw: from.yaw + angle_delta(from.yaw, yaw),
                pitch,
                dist: 0.0,
            },
        });
        self.vel_yaw = 0.0;
        self.vel_pitch = 0.0;
        status::OK
    }

    fn pick(&self, x: f32, y: f32) -> i32 {
        // 后画的在前：倒序找第一个命中。
        let mut best: Option<(usize, f32)> = None;
        for (i, r) in self.pick_rects.iter().enumerate() {
            if r[2] <= 0.0 {
                continue;
            }
            if x >= r[0] && x <= r[0] + r[2] && y >= r[1] && y <= r[1] + r[3] {
                let area = r[2] * r[3];
                // 重叠时取屏幕上更大（更近）的那张。
                if best.is_none_or(|(_, a)| area > a) {
                    best = Some((i, area));
                }
            }
        }
        best.map(|(i, _)| i as i32).unwrap_or(-1)
    }

    /// 镜头 + 阶段（分享动画按时间轴；交互模式按状态与惯性）。
    fn advance(&mut self, t: f32, dt: f32) -> Frame {
        let dt = if dt.is_finite() {
            dt.clamp(0.0, 0.1)
        } else {
            0.0
        };
        let mut frame = Frame {
            clock: t,
            morph: 1.0,
            bang: 1.0,
            dim: 1.0,
            target: None,
            fly: 0.0,
            fly_to: V3::default(),
        };
        if self.mode == MODE_CINEMATIC {
            frame.bang = ease_out_expo(t / T_BANG_END);
            frame.morph = ease_in_out((t - T_GALAXY_END) / (T_SPHERE_END - T_GALAXY_END));
            let galaxy_yaw = 0.35 + t * 0.12;
            let galaxy = Camera {
                yaw: galaxy_yaw,
                pitch: GALAXY_CAMERA_PITCH,
                dist: GALAXY_CAMERA_DIST,
            };
            let sphere_yaw0 = 0.35 + T_GALAXY_END * 0.12;
            let k = ease_in_out((t - T_GALAXY_END) / (T_SPHERE_END - T_GALAXY_END));
            let mut cam = Camera {
                yaw: if t < T_GALAXY_END {
                    galaxy.yaw
                } else {
                    sphere_yaw0 + (t - T_GALAXY_END) * 0.12 * (1.0 - k)
                },
                pitch: GALAXY_CAMERA_PITCH * (1.0 - k),
                dist: GALAXY_CAMERA_DIST * (1.0 - k),
            };
            if t >= T_SPHERE_END {
                let look = ease_in_out((t - T_SPHERE_END) / (T_LOOK_END - T_SPHERE_END));
                cam = Camera {
                    yaw: sphere_yaw0 + TAU * look,
                    pitch: 0.12 * (look * TAU).sin(),
                    dist: 0.0,
                };
            }
            match self.cinematic_target {
                Some(target) if t >= T_LOOK_END => {
                    let (yaw, pitch) = Camera::facing(self.works[target].sphere);
                    let from = cam;
                    let to = Camera {
                        yaw: from.yaw + angle_delta(from.yaw, yaw),
                        pitch,
                        dist: 0.0,
                    };
                    self.camera = from;
                    self.lock = Some(Lock {
                        target,
                        t0: T_LOOK_END,
                        from,
                        to,
                    });
                }
                _ => {
                    self.camera = cam;
                    self.lock = None;
                }
            }
        } else {
            self.clock += dt;
            frame.clock = self.clock;
            if self.lock.is_none() && !self.holding {
                self.camera.yaw += self.vel_yaw * dt;
                self.camera.pitch = (self.camera.pitch + self.vel_pitch * dt).clamp(-1.45, 1.45);
                let decay = (-3.2 * dt).exp();
                self.vel_yaw *= decay;
                self.vel_pitch *= decay;
                // 静止时缓慢自转，让球幕「活着」。
                if self.vel_yaw.abs() < 0.02 {
                    self.camera.yaw += 0.03 * dt;
                }
            }
        }
        if let Some(lock) = self.lock {
            let lt = t - lock.t0;
            let turn = ease_in_out(lt / LOCK_TURN);
            self.camera = Camera {
                yaw: lock.from.yaw + (lock.to.yaw - lock.from.yaw) * turn,
                pitch: lock.from.pitch + (lock.to.pitch - lock.from.pitch) * turn,
                dist: lock.from.dist + (lock.to.dist - lock.from.dist) * turn,
            };
            frame.dim = 1.0 - (1.0 - DIM_LEVEL) * smooth(lt / LOCK_TURN);
            frame.target = Some(lock.target);
            frame.fly = ease_in_out((lt - LOCK_TURN) / (LOCK_SECONDS - LOCK_TURN));
        }
        self.last_t = Some(t);
        frame
    }

    /// 作品 [i] 在本帧的世界位置（含锁定飞入）。
    fn work_pos(&self, i: usize, f: &Frame) -> V3 {
        self.apply_fly(i, self.work_base(i, f), f)
    }

    /// 作品 [i] 在本帧的布局位置（不含锁定飞入）：它的环绕词绕这里转——目标飞到眼前时
    /// 词留在原处随其余一起变暗，不跟到镜头前糊成巨大的气泡字。
    fn work_base(&self, i: usize, f: &Frame) -> V3 {
        let w = &self.works[i];
        let sphere = w.sphere;
        if f.morph >= 1.0 && f.bang >= 1.0 {
            return sphere;
        }
        let ang = w.arm_angle + w.galaxy_r * 0.16 + f.clock * 0.9 / w.galaxy_r.sqrt();
        let galaxy = V3(ang.cos() * w.galaxy_r, w.galaxy_y, ang.sin() * w.galaxy_r);
        let galaxy = galaxy.scale(f.bang);
        let m = smooth((f.morph * 1.35 - w.stagger * 0.35).clamp(0.0, 1.0));
        galaxy.lerp(sphere, m)
    }

    fn apply_fly(&self, i: usize, p: V3, f: &Frame) -> V3 {
        if f.target == Some(i) && f.fly > 0.0 {
            p.lerp(f.fly_to, f.fly)
        } else {
            p
        }
    }

    fn word_pos(&self, i: usize, f: &Frame, owner_pos: Option<V3>) -> V3 {
        let wd = &self.words[i];
        match (wd.owner, owner_pos) {
            (Some(_), Some(center)) => {
                let a = wd.orbit_phase + f.clock * wd.orbit_w;
                let (s, c) = a.sin_cos();
                let r = wd.orbit_r * (0.3 + 0.7 * f.bang);
                center
                    .add(wd.orbit_a.scale(c * r))
                    .add(wd.orbit_b.scale(s * r))
            }
            _ => {
                let shell = wd.shell;
                if f.morph >= 1.0 && f.bang >= 1.0 {
                    return shell;
                }
                let ang = wd.arm_angle + wd.galaxy_r * 0.16 + f.clock * 0.7 / wd.galaxy_r.sqrt();
                let galaxy = V3(
                    ang.cos() * wd.galaxy_r,
                    wd.galaxy_y,
                    ang.sin() * wd.galaxy_r,
                )
                .scale(f.bang);
                let m = smooth((f.morph * 1.35 - wd.stagger * 0.35).clamp(0.0, 1.0));
                galaxy.lerp(shell, m)
            }
        }
    }

    fn frame(&mut self, t: f32, dt: f32, vw: f32, vh: f32) -> i32 {
        if !(t.is_finite() && vw > 0.0 && vh > 0.0 && vw.is_finite() && vh.is_finite()) {
            return status::INVALID_ARGUMENT;
        }
        let mut f = self.advance(t, dt);
        let basis = self.camera.basis();
        let focal = (vh * 0.5) / (FOV_Y * 0.5).tan();
        let (cx, cy) = (vw * 0.5, vh * 0.5);

        // 目标飞到镜头正前方：距离按「封面高度占视口 62%」反推。
        if let Some(target) = f.target {
            let wk = &self.works[target];
            let d = wk.h * focal / (TARGET_SCREEN_HEIGHT * vh);
            let (yaw, pitch) = Camera::facing(wk.sphere);
            let dir = Camera {
                yaw,
                pitch,
                dist: 0.0,
            }
            .basis()
            .forward;
            f.fly_to = dir.scale(d.max(NEAR_PLANE * 2.0));
        }

        let project = |p: V3| -> Option<(f32, f32, f32, f32)> {
            let rel = p.sub(basis.pos);
            let z = rel.dot(basis.forward);
            if z <= NEAR_PLANE {
                return None;
            }
            let x = rel.dot(basis.right);
            let y = rel.dot(basis.up);
            let s = focal / z;
            Some((cx + x * s, cy - y * s, s, rel.len()))
        };

        // 1. 收集可见元素与深度。
        self.items.clear();
        let mut work_screen: Vec<Option<(f32, f32, f32, f32)>> =
            Vec::with_capacity(self.works.len());
        let mut work_world: Vec<V3> = Vec::with_capacity(self.works.len());
        for i in 0..self.works.len() {
            let base = self.work_base(i, &f);
            let p = self.apply_fly(i, base, &f);
            work_world.push(base);
            let pr = project(p);
            work_screen.push(pr);
            self.pick_rects[i] = [0.0; 4];
            if let Some((sx, sy, s, dist)) = pr {
                let wk = &self.works[i];
                let (hw, hh) = (wk.w * s * 0.5, wk.h * s * 0.5);
                if sx + hw * 1.3 < 0.0
                    || sx - hw * 1.3 > vw
                    || sy + hh * 1.3 < 0.0
                    || sy - hh * 1.3 > vh
                {
                    continue;
                }
                if hh < 0.4 {
                    continue;
                }
                self.pick_rects[i] = [sx - hw, sy - hh, hw * 2.0, hh * 2.0];
                self.items.push(Item {
                    depth: dist,
                    id: i as u32,
                });
            }
        }
        for i in 0..self.words.len() {
            let owner = self.words[i].owner;
            let p = self.word_pos(i, &f, owner.map(|o| work_world[o]));
            if let Some((sx, sy, s, dist)) = project(p) {
                let wd = &self.words[i];
                let half_w = wd.advance * wd.em * s * 0.75;
                let half_h = wd.em * s * 0.75;
                if half_h < 0.5
                    || sx + half_w < 0.0
                    || sx - half_w > vw
                    || sy + half_h < 0.0
                    || sy - half_h > vh
                {
                    continue;
                }
                self.items.push(Item {
                    depth: dist,
                    id: WORD_FLAG | i as u32,
                });
            }
        }
        // 远 → 近。
        self.items.sort_unstable_by(|a, b| {
            b.depth
                .partial_cmp(&a.depth)
                .unwrap_or(std::cmp::Ordering::Equal)
        });

        // 2. 依序写精灵，并按图集分页切批。
        let mut n = 0usize;
        let mut batches = 0usize;
        let mut cur_page = i32::MIN;
        let target_external = f.target.is_some();
        let target_id = f.target;
        let items = std::mem::take(&mut self.items);
        for item in &items {
            if item.id & WORD_FLAG == 0 {
                let i = item.id as usize;
                if target_external && target_id == Some(i) {
                    // 锁定后的目标由 Dart 用高清原图画在 TARGET_RECT，保证与翻开的书同一张图。
                    continue;
                }
                let (sx, sy, s, _) = work_screen[i].unwrap();
                let wk = &self.works[i];
                let cell = self.cells[wk.cell];
                let k = wk.w * s / wk.cover_px_w;
                let alpha = clamp01(f.bang * 1.4 - wk.stagger * 0.4);
                let c = f.dim;
                self.push_sprite(
                    &mut n,
                    &mut batches,
                    &mut cur_page,
                    wk.cell,
                    [k, 0.0, sx - k * cell[2] * 0.5, sy - k * cell[3] * 0.5],
                    argb(alpha, c, c, c),
                );
            } else {
                let i = (item.id & !WORD_FLAG) as usize;
                let owner = self.words[i].owner;
                let p = self.word_pos(i, &f, owner.map(|o| work_world[o]));
                let Some((sx, sy, s, dist)) = project(p) else {
                    continue;
                };
                // 远近：0 = 最远（细、小、淡），1 = 最近（粗、大、白字心 + 彩色描边）。
                let near = smooth((STYLE_FAR - dist) / (STYLE_FAR - STYLE_NEAR));
                let wd = &self.words[i];
                // 镜头穿过词云时近处的词会无限放大：屏幕字号封顶在视口高 5%（气泡样式照常）。
                let px_em = (wd.em * s * (0.7 + 0.9 * near)).min(vh * 0.05);
                let k = px_em / self.glyph_em_px;
                let x0 = sx - wd.advance * px_em * 0.5;
                let alpha = clamp01(f.bang * 1.3 - wd.stagger * 0.3) * (0.4 + 0.6 * near);
                let (hr, hg, hb) = hsv_to_rgb(wd.hue, 0.35 + 0.45 * near, 1.0);
                // 淡色：越远越接近灰白、越透明。
                let pale = (0.55 + 0.45 * near) * f.dim;
                let thin_a = alpha * (1.0 - near);
                let bold_a = alpha * near;
                let (start, count) = (wd.glyph_start, wd.glyph_count);
                let dim = f.dim;
                let mut pen = x0;
                for g in start..start + count {
                    let (thin, fill, outline, adv) = {
                        let gl = &self.glyphs[g];
                        (gl.thin, gl.fill, gl.outline, gl.advance)
                    };
                    let cell = self.cells[thin];
                    let gx = pen;
                    let gy = sy - cell[3] * k * 0.5;
                    if thin_a > 0.01 {
                        self.push_sprite(
                            &mut n,
                            &mut batches,
                            &mut cur_page,
                            thin,
                            [k, 0.0, gx, gy],
                            argb(thin_a, hr * pale, hg * pale, hb * pale),
                        );
                    }
                    if bold_a > 0.01 {
                        let oc = self.cells[outline];
                        // 描边格子比字心大一圈：按格子中心对齐。
                        let ox = gx + (cell[2] - oc[2]) * k * 0.5;
                        let oy = sy - oc[3] * k * 0.5;
                        self.push_sprite(
                            &mut n,
                            &mut batches,
                            &mut cur_page,
                            outline,
                            [k, 0.0, ox, oy],
                            argb(bold_a, hr * dim, hg * dim, hb * dim),
                        );
                        let fc = self.cells[fill];
                        let fx = gx + (cell[2] - fc[2]) * k * 0.5;
                        let fy = sy - fc[3] * k * 0.5;
                        self.push_sprite(
                            &mut n,
                            &mut batches,
                            &mut cur_page,
                            fill,
                            [k, 0.0, fx, fy],
                            argb(bold_a, dim, dim, dim),
                        );
                    }
                    pen += adv * px_em;
                }
            }
        }
        self.items = items;
        self.sprites = n;
        self.batches = batches;

        // 3. 帧信息。
        let info_buf = &mut self.out_info;
        info_buf.iter_mut().for_each(|v| *v = 0.0);
        let world_halo = 6.0;
        if let Some((hx, hy, s, _)) = project(V3::default()) {
            info_buf[info::HALO_X] = hx;
            info_buf[info::HALO_Y] = hy;
            info_buf[info::HALO_R] = world_halo * s;
            // 强度固定；只在镜头离开光晕所在处（进到球心）时按距离收掉，避免在镜头内糊屏。
            info_buf[info::HALO_ALPHA] = smooth((self.camera.dist - 2.0) / 10.0) * f.bang.max(0.15);
        } else if self.mode == MODE_CINEMATIC && t < T_BANG_END {
            info_buf[info::HALO_ALPHA] = 0.0;
        }
        let put = |buf: &mut Vec<f32>, at: usize, v: V3| {
            buf[at] = v.0;
            buf[at + 1] = v.1;
            buf[at + 2] = v.2;
        };
        put(info_buf, info::FORWARD, basis.forward);
        put(info_buf, info::RIGHT, basis.right);
        put(info_buf, info::UP, basis.up);
        info_buf[info::FOCAL] = focal;
        info_buf[info::DIM] = f.dim;
        info_buf[info::PHASE] = if self.mode == MODE_INTERACTIVE {
            4.0
        } else if t < T_BANG_END {
            0.0
        } else if t < T_GALAXY_END {
            1.0
        } else if t < T_LOOK_END {
            2.0
        } else {
            3.0
        };
        if let Some(target) = f.target {
            let lock = self.lock.unwrap();
            let lt = t - lock.t0;
            info_buf[info::LOCK_PROGRESS] = clamp01(lt / LOCK_SECONDS);
            info_buf[info::HANDOFF] = if lt >= LOCK_SECONDS { 1.0 } else { 0.0 };
            info_buf[info::TARGET_COLOR] = 1.0;
            if let Some((sx, sy, s, _)) = work_screen[target] {
                let wk = &self.works[target];
                let (w, h) = (wk.w * s, wk.h * s);
                info_buf[info::TARGET_VISIBLE] = 1.0;
                info_buf[info::TARGET_RECT] = sx - w * 0.5;
                info_buf[info::TARGET_RECT + 1] = sy - h * 0.5;
                info_buf[info::TARGET_RECT + 2] = w;
                info_buf[info::TARGET_RECT + 3] = h;
            }
        }
        status::OK
    }

    fn push_sprite(
        &mut self,
        n: &mut usize,
        batches: &mut usize,
        cur_page: &mut i32,
        cell: usize,
        xform: [f32; 4],
        color: i32,
    ) {
        if *n * 4 >= self.out_xform.len() {
            return;
        }
        let page = self.cell_page[cell];
        if page != *cur_page {
            *cur_page = page;
            let b = *batches;
            self.out_batch[b * 3] = page;
            self.out_batch[b * 3 + 1] = *n as i32;
            self.out_batch[b * 3 + 2] = 0;
            *batches += 1;
        }
        let r = self.cells[cell];
        let at = *n * 4;
        self.out_xform[at..at + 4].copy_from_slice(&xform);
        self.out_rect[at] = r[0];
        self.out_rect[at + 1] = r[1];
        self.out_rect[at + 2] = r[0] + r[2];
        self.out_rect[at + 3] = r[1] + r[3];
        self.out_color[*n] = color;
        self.out_batch[(*batches - 1) * 3 + 2] += 1;
        *n += 1;
    }
}

unsafe fn slice_in<'a, T>(ptr: *const T, len: usize) -> Option<&'a [T]> {
    if len == 0 {
        Some(&[])
    } else if ptr.is_null() {
        None
    } else {
        Some(std::slice::from_raw_parts(ptr, len))
    }
}

/// 建图。
///
/// - `cells_rect[n_cells * 4]`：图集格子 (x, y, w, h) 像素；`cells_page[n_cells]`：所在图集页。
/// - `works_f[n_works * 3]`：(宽高比, 封面本体在格子里的像素宽, 色相 0..1)；
///   `works_cell[n_works]`：封面格子（格子含辉光留边，封面本体居中）。
/// - `words[n_words * 3]`：(所属作品下标或 -1, 字形起点, 字形数)。
/// - `glyph_cells[n_glyphs * 3]`：(细体, 粗体字心, 粗体描边) 格子；`glyph_adv[n_glyphs]`：
///   字宽（em 倍数）。细体与字心格子同尺寸，描边格子居中外扩。
/// - `glyph_em_px`：字形格子绘制时的 em 像素。
///
/// # Safety
/// 各指针在给定长度内可读；`out` 可写。成功后用 [ffc_pano_free] 释放。
#[no_mangle]
#[allow(clippy::too_many_arguments)]
pub unsafe extern "C" fn ffc_pano_new(
    cells_rect: *const f32,
    cells_page: *const i32,
    n_cells: usize,
    works_f: *const f32,
    works_cell: *const i32,
    n_works: usize,
    words: *const i32,
    n_words: usize,
    glyph_cells: *const i32,
    glyph_adv: *const f32,
    n_glyphs: usize,
    glyph_em_px: f32,
    seed: u64,
    out: *mut *mut Pano,
) -> i32 {
    guard(|| {
        if out.is_null() {
            return status::NULL_ARGUMENT;
        }
        *out = std::ptr::null_mut();
        let (Some(rects), Some(pages), Some(wf), Some(wc), Some(wd), Some(gc), Some(ga)) = (
            slice_in(cells_rect, n_cells * 4),
            slice_in(cells_page, n_cells),
            slice_in(works_f, n_works * 3),
            slice_in(works_cell, n_works),
            slice_in(words, n_words * 3),
            slice_in(glyph_cells, n_glyphs * 3),
            slice_in(glyph_adv, n_glyphs),
        ) else {
            return status::NULL_ARGUMENT;
        };
        let cells: Vec<[f32; 4]> = rects
            .chunks_exact(4)
            .map(|c| [c[0], c[1], c[2], c[3]])
            .collect();
        if cells
            .iter()
            .any(|c| c.iter().any(|v| !v.is_finite()) || c[2] < 0.0 || c[3] < 0.0)
        {
            return status::INVALID_ARGUMENT;
        }
        match Pano::build(cells, pages.to_vec(), wf, wc, wd, gc, ga, glyph_em_px, seed) {
            Ok(p) => {
                *out = Box::into_raw(Box::new(p));
                status::OK
            }
            Err(e) => e,
        }
    })
}

/// 释放（NULL 无操作）。
///
/// # Safety
/// `p` 来自 [ffc_pano_new] 且未释放。
#[no_mangle]
pub unsafe extern "C" fn ffc_pano_free(p: *mut Pano) {
    if !p.is_null() {
        drop(Box::from_raw(p));
    }
}

/// 取输出缓冲区指针（建图后不变）：xform / rect 各 `capacity * 4` 个 f32，color `capacity` 个
/// i32，batch `batch_capacity * 3` 个 i32（页, 起点, 张数），info [info::LEN] 个 f32。
///
/// # Safety
/// `p` 有效；各输出指针可写。
#[no_mangle]
#[allow(clippy::too_many_arguments)]
pub unsafe extern "C" fn ffc_pano_buffers(
    p: *mut Pano,
    xform: *mut *mut f32,
    rect: *mut *mut f32,
    color: *mut *mut i32,
    batch: *mut *mut i32,
    info_out: *mut *mut f32,
    capacity: *mut usize,
    batch_capacity: *mut usize,
) -> i32 {
    guard(|| {
        if p.is_null()
            || xform.is_null()
            || rect.is_null()
            || color.is_null()
            || batch.is_null()
            || info_out.is_null()
            || capacity.is_null()
            || batch_capacity.is_null()
        {
            return status::NULL_ARGUMENT;
        }
        let pano = &mut *p;
        *xform = pano.out_xform.as_mut_ptr();
        *rect = pano.out_rect.as_mut_ptr();
        *color = pano.out_color.as_mut_ptr();
        *batch = pano.out_batch.as_mut_ptr();
        *info_out = pano.out_info.as_mut_ptr();
        *capacity = pano.out_color.len();
        *batch_capacity = pano.out_batch.len() / 3;
        status::OK
    })
}

/// 切模式：[MODE_INTERACTIVE]（镜头归位到球心）或 [MODE_CINEMATIC]（`target` 为动画最后
/// 锁定的作品，-1 表示不锁定）。
///
/// # Safety
/// `p` 有效。
#[no_mangle]
pub unsafe extern "C" fn ffc_pano_set_mode(p: *mut Pano, mode: i32, target: i32) -> i32 {
    guard(|| {
        if p.is_null() {
            return status::NULL_ARGUMENT;
        }
        (*p).set_mode(mode, target)
    })
}

/// 交互输入（见 [input]）；分享动画或锁定中忽略。
///
/// # Safety
/// `p` 有效。
#[no_mangle]
pub unsafe extern "C" fn ffc_pano_input(p: *mut Pano, kind: i32, a: f32, b: f32) -> i32 {
    guard(|| {
        if p.is_null() {
            return status::NULL_ARGUMENT;
        }
        (*p).input(kind, a, b)
    })
}

/// 交互模式下选中作品：从当前镜头转向并把它飞到眼前（时刻 `t` 与 [ffc_pano_frame] 同一时钟）。
///
/// # Safety
/// `p` 有效。
#[no_mangle]
pub unsafe extern "C" fn ffc_pano_select(p: *mut Pano, work: i32, t: f32) -> i32 {
    guard(|| {
        if p.is_null() {
            return status::NULL_ARGUMENT;
        }
        (*p).select(work, t)
    })
}

/// 上一帧屏幕坐标 (x, y) 处的作品下标，没有为 -1（负数之外的错误码不会出现）。
///
/// # Safety
/// `p` 有效。
#[no_mangle]
pub unsafe extern "C" fn ffc_pano_pick(p: *const Pano, x: f32, y: f32) -> i32 {
    if p.is_null() {
        return -1;
    }
    std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| (*p).pick(x, y))).unwrap_or(-1)
}

/// 算一帧：`t` 为秒（分享动画从 0 起；交互模式任意单调时钟），`dt` 为距上一帧秒数，
/// `vw` / `vh` 为视口逻辑像素。写出精灵数与批次数，数据在 [ffc_pano_buffers] 的缓冲区里。
///
/// # Safety
/// `p` 有效；`sprites` / `batches` 可写。
#[no_mangle]
pub unsafe extern "C" fn ffc_pano_frame(
    p: *mut Pano,
    t: f64,
    dt: f32,
    vw: f32,
    vh: f32,
    sprites: *mut usize,
    batches: *mut usize,
) -> i32 {
    guard(|| {
        if p.is_null() || sprites.is_null() || batches.is_null() {
            return status::NULL_ARGUMENT;
        }
        let pano = &mut *p;
        let rc = pano.frame(t as f32, dt, vw, vh);
        *sprites = pano.sprites;
        *batches = pano.batches;
        rc
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 造一个 n 部作品、每部 m 个词（每词 3 字形）+ u 个无主词的全景。
    fn make(n: usize, m: usize, u: usize) -> Pano {
        let mut cells = Vec::new();
        let mut pages = Vec::new();
        let mut works_f = Vec::new();
        let mut works_cell = Vec::new();
        for i in 0..n {
            cells.push([i as f32 * 130.0, 0.0, 120.0, 160.0]);
            pages.push(0);
            works_f.extend_from_slice(&[0.7 + (i % 3) as f32 * 0.3, 100.0, i as f32 / n as f32]);
            works_cell.push(i as i32);
        }
        let glyph_base = cells.len();
        cells.push([0.0, 0.0, 32.0, 32.0]);
        cells.push([32.0, 0.0, 32.0, 32.0]);
        cells.push([64.0, 0.0, 40.0, 40.0]);
        pages.extend_from_slice(&[1, 1, 1]);
        let mut words = Vec::new();
        let mut gc = Vec::new();
        let mut ga = Vec::new();
        let total = n * m + u;
        for w in 0..total {
            let owner = if w < n * m { (w / m) as i32 } else { -1 };
            words.extend_from_slice(&[owner, (w * 3) as i32, 3]);
            for _ in 0..3 {
                gc.extend_from_slice(&[
                    glyph_base as i32,
                    glyph_base as i32 + 1,
                    glyph_base as i32 + 2,
                ]);
                ga.push(1.0f32);
            }
        }
        Pano::build(
            cells,
            pages,
            &works_f,
            &works_cell,
            &words,
            &gc,
            &ga,
            32.0,
            7,
        )
        .unwrap()
    }

    #[test]
    fn rejects_bad_tables() {
        let r = Pano::build(
            vec![[0.0; 4]],
            vec![0],
            &[1.0, 10.0, 0.0],
            &[3],
            &[],
            &[],
            &[],
            32.0,
            1,
        );
        assert_eq!(r.err(), Some(status::INVALID_ARGUMENT));
        let r = Pano::build(
            vec![[0.0; 4]],
            vec![0],
            &[1.0, 10.0],
            &[0],
            &[],
            &[],
            &[],
            32.0,
            1,
        );
        assert_eq!(r.err(), Some(status::INVALID_ARGUMENT));
    }

    #[test]
    fn deterministic_for_same_seed() {
        let mut a = make(20, 5, 30);
        let mut b = make(20, 5, 30);
        a.set_mode(MODE_CINEMATIC, 3);
        b.set_mode(MODE_CINEMATIC, 3);
        a.frame(4.0, 0.016, 800.0, 600.0);
        b.frame(4.0, 0.016, 800.0, 600.0);
        assert_eq!(a.sprites, b.sprites);
        assert_eq!(&a.out_xform[..a.sprites * 4], &b.out_xform[..b.sprites * 4]);
        assert_eq!(&a.out_color[..a.sprites], &b.out_color[..b.sprites]);
    }

    #[test]
    fn sphere_layout_has_radius_twelve_and_uniform_card_area() {
        let p = make(50, 0, 0);
        for w in &p.works {
            assert!((w.sphere.len() - SPHERE_RADIUS).abs() < 1e-3);
            assert!((w.w * w.h - p.works[0].w * p.works[0].h).abs() < 1e-3);
            assert!((w.w / w.h - w.aspect).abs() < 1e-3);
        }
    }

    #[test]
    fn big_bang_starts_from_a_point() {
        let mut p = make(30, 2, 10);
        p.set_mode(MODE_CINEMATIC, -1);
        let f = p.advance(0.0, 0.0);
        for i in 0..p.works.len() {
            assert!(p.work_pos(i, &f).len() < 1e-3);
        }
    }

    #[test]
    fn batches_cover_all_sprites_and_pages_are_contiguous() {
        let mut p = make(40, 6, 50);
        p.set_mode(MODE_INTERACTIVE, -1);
        p.frame(0.0, 0.016, 1280.0, 720.0);
        assert!(p.sprites > 0);
        let mut sum = 0;
        for b in 0..p.batches {
            assert_eq!(p.out_batch[b * 3 + 1] as usize, sum);
            sum += p.out_batch[b * 3 + 2] as usize;
            if b > 0 {
                assert_ne!(p.out_batch[b * 3], p.out_batch[(b - 1) * 3]);
            }
        }
        assert_eq!(sum, p.sprites);
    }

    #[test]
    fn lock_brings_target_to_screen_center_and_dims_others() {
        let mut p = make(60, 3, 20);
        p.set_mode(MODE_CINEMATIC, 17);
        p.frame(T_HANDOFF + 0.1, 0.016, 1000.0, 800.0);
        let i = &p.out_info;
        assert_eq!(i[info::TARGET_VISIBLE], 1.0);
        assert_eq!(i[info::HANDOFF], 1.0);
        let (x, y, w, h) = (
            i[info::TARGET_RECT],
            i[info::TARGET_RECT + 1],
            i[info::TARGET_RECT + 2],
            i[info::TARGET_RECT + 3],
        );
        assert!(
            ((x + w / 2.0) - 500.0).abs() < 1.0,
            "x center {}",
            x + w / 2.0
        );
        assert!(
            ((y + h / 2.0) - 400.0).abs() < 1.0,
            "y center {}",
            y + h / 2.0
        );
        assert!((h - 0.62 * 800.0).abs() < 2.0, "h {h}");
        assert!((w / h - p.works[17].aspect).abs() < 1e-3);
        assert!((i[info::DIM] - DIM_LEVEL).abs() < 1e-4);
        // 目标不在图集精灵里（由 Dart 画高清图）。
        let target_cell = p.cells[p.works[17].cell];
        for s in 0..p.sprites {
            assert_ne!(p.out_rect[s * 4], target_cell[0]);
        }
    }

    #[test]
    fn target_words_stay_on_the_sphere_while_the_cover_flies_in() {
        let mut p = make(40, 5, 0);
        p.set_mode(MODE_CINEMATIC, 3);
        let f = p.advance(T_HANDOFF + 0.1, 0.0);
        let mut f = f;
        f.fly_to = V3(0.0, 0.0, -3.0);
        let base = p.work_base(3, &f);
        assert!((p.work_pos(3, &f).sub(f.fly_to)).len() < 1e-3);
        for w in 0..p.words.len() {
            if p.words[w].owner == Some(3) {
                let wp = p.word_pos(w, &f, Some(base));
                assert!((wp.sub(base)).len() <= p.words[w].orbit_r + 1e-3);
                assert!(wp.len() > SPHERE_RADIUS * 0.7);
            }
        }
    }

    #[test]
    fn far_words_are_thin_and_near_words_are_bubbled() {
        let mut p = make(1, 0, 0);
        // 手工放一个无主词在远处与近处，比较输出样式。
        let mut words = Vec::new();
        for (k, z) in [(0usize, -30.0f32), (1, -3.0)] {
            let _ = k;
            words.push(Word {
                owner: None,
                glyph_start: 0,
                glyph_count: 0,
                em: 0.5,
                hue: 0.5,
                orbit_a: V3::default(),
                orbit_b: V3::default(),
                orbit_r: 0.0,
                orbit_w: 0.0,
                orbit_phase: 0.0,
                arm_angle: 0.0,
                galaxy_r: 1.0,
                galaxy_y: 0.0,
                shell: V3(0.0, 0.0, z),
                stagger: 0.0,
                advance: 1.0,
            });
        }
        let base = p.cells.len();
        p.cells.extend_from_slice(&[
            [0.0, 0.0, 32.0, 32.0],
            [32.0, 0.0, 32.0, 32.0],
            [64.0, 0.0, 40.0, 40.0],
        ]);
        p.cell_page.extend_from_slice(&[1, 1, 1]);
        p.glyphs.push(Glyph {
            thin: base,
            fill: base + 1,
            outline: base + 2,
            advance: 1.0,
        });
        for w in &mut words {
            w.glyph_count = 1;
        }
        p.words = words;
        p.out_xform = vec![0.0; 64];
        p.out_rect = vec![0.0; 64];
        p.out_color = vec![0; 16];
        p.out_batch = vec![0; 48];
        p.set_mode(MODE_INTERACTIVE, -1);
        p.frame(0.0, 0.0, 800.0, 800.0);
        let rects: Vec<f32> = (0..p.sprites).map(|s| p.out_rect[s * 4]).collect();
        // 远词只出细体（x=0），近词出描边（64）+ 字心（32）。
        assert!(rects.contains(&0.0));
        assert!(rects.contains(&64.0) && rects.contains(&32.0));
        // 近词更大。
        let scale_of = |x: f32| {
            (0..p.sprites)
                .find(|&s| p.out_rect[s * 4] == x)
                .map(|s| p.out_xform[s * 4])
                .unwrap()
        };
        assert!(scale_of(32.0) > scale_of(0.0) * 3.0);
    }

    #[test]
    fn near_style_is_continuous() {
        let mut prev = smooth((STYLE_FAR - 0.0) / (STYLE_FAR - STYLE_NEAR));
        let mut d = 0.0;
        while d < 30.0 {
            d += 0.05;
            let v = smooth((STYLE_FAR - d) / (STYLE_FAR - STYLE_NEAR));
            assert!((v - prev).abs() < 0.01);
            prev = v;
        }
    }

    #[test]
    fn drag_rotates_and_zoom_moves_out_of_the_sphere() {
        let mut p = make(10, 0, 0);
        p.set_mode(MODE_INTERACTIVE, -1);
        p.input(input::DRAG, 100.0, 0.0);
        assert!(p.camera.yaw < 0.0);
        p.input(input::ZOOM, 0.25, 0.0);
        assert!(p.camera.dist > 2.0);
        p.input(input::ZOOM, 100.0, 0.0);
        assert_eq!(p.camera.dist, 0.0);
    }

    #[test]
    fn pick_returns_card_under_pointer() {
        let mut p = make(30, 0, 0);
        p.set_mode(MODE_INTERACTIVE, -1);
        p.frame(0.0, 0.0, 800.0, 600.0);
        let hit = (0..30).find(|&i| p.pick_rects[i][2] > 0.0).unwrap();
        let r = p.pick_rects[hit];
        assert!(p.pick(r[0] + r[2] / 2.0, r[1] + r[3] / 2.0) >= 0);
        assert_eq!(p.pick(-100.0, -100.0), -1);
    }

    /// 大库一帧的耗时上限（release 下几百部作品 + 1.3 万词应远低于 4 ms；debug 放宽）。
    #[test]
    fn big_library_frame_budget() {
        let mut p = make(400, 30, 1800);
        p.set_mode(MODE_CINEMATIC, 5);
        let start = std::time::Instant::now();
        let mut t = 0.0;
        let mut frames = 0;
        while t < CINEMATIC_SECONDS {
            p.frame(t, 1.0 / 60.0, 1920.0, 1080.0);
            t += 0.25;
            frames += 1;
        }
        let per = start.elapsed().as_secs_f64() * 1000.0 / frames as f64;
        let limit = if cfg!(debug_assertions) { 120.0 } else { 6.0 };
        assert!(per < limit, "per frame {per:.2} ms");
        eprintln!("pano frame: {per:.3} ms ({} sprites)", p.sprites);
    }
}
