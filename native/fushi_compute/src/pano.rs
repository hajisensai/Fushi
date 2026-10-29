//! `ffc_pano_*`：媒体库全景（首页「媒体库全景」与分享用 16 秒开场动画）的胖核心。
//!
//! 状态全在本模块：作品 / 词的布局（大爆炸 → 三旋臂星系 → 半径 12 球幕）、封面的 3D 姿态、
//! 词的环绕轨道、交互镜头（拖拽惯性、缩放）、锁定飞入、每帧投影与远近样式。Dart 侧只在建图时
//! 交一次「图集格子 + 作品 + 词 + 字形」表，之后每帧一次 [ffc_pano_frame]，拿回按远到近排好、
//! 按图集页切批的三角网格（屏幕坐标 / 图集纹理坐标 / 调制色 / 索引）直接 `drawVertices`，
//! 不另存镜像状态。
//!
//! 封面是真正的 3D 平面（不是正对镜头的贴片）：
//! - 星系：面朝上躺在盘面上（盘面过原点，厚度 ±0.7、越往外越薄），随旋臂公转（越靠中心越快），
//!   同时绕自身法线在盘面里慢慢自转；放大 1.25 倍。
//! - 过渡：每张从平放姿态（四元数 slerp）转到球面朝向、同时飞到球面位置，起始时间错开约 1.2 秒。
//! - 球幕：斐波那契球面均匀分布在半径 12 上，正面朝球心，上方向取世界上方向在卡面上的投影
//!   （两极附近自然倾斜）；放大 1.5 倍。
//! - 双面：背面可见时画正向（水平翻转纹理坐标，字不反）、略暗的封面。
//! - 每张卡切成 4×4 小格再投影，斜看时纹理不会沿对角线折开。
//! 词仍是正对镜头的字形片（屏幕空间四边形），与封面一起按深度排序。
//!
//! 坐标系：右手系，y 朝上；镜头由 yaw（绕 y）、pitch（俯仰）与 dist（沿视线反方向离原点的
//! 距离）描述。交互模式下布局由镜头距离决定：远（≥ 30）是星系、近（≤ 6）是球幕，拉近 / 拉远
//! 连续变形；开场停在星系俯视。
//!
//! 输出缓冲区由本模块持有、容量建图时定死（[ffc_pano_buffers] 取一次指针即可，帧间不变）。

use std::f32::consts::{PI, TAU};

use crate::{guard, status};

/// 分享动画总长（秒）。
pub const CINEMATIC_SECONDS: f32 = 16.0;
const T_BANG_END: f32 = 1.2;
const T_GALAXY_END: f32 = 5.5;
const T_SPHERE_END: f32 = 8.5;
const T_LOOK_END: f32 = 11.0;
/// 锁定：先转向（交互模式从远处来时更长），再沿半径飞到眼前。
const LOCK_TURN: f32 = 0.9;
const LOCK_FLY: f32 = 1.6;
/// 封面停稳后交给 Flutter 翻开的时刻。
pub const T_HANDOFF: f32 = T_LOOK_END + LOCK_TURN + LOCK_FLY;
/// 过渡里每张卡起始时间的最大错开（秒）与过渡总长。
const MORPH_STAGGER: f32 = 1.2;
const MORPH_SECONDS: f32 = T_SPHERE_END - T_GALAXY_END;

const SPHERE_RADIUS: f32 = 12.0;
const SHELL_MIN: f32 = 15.0;
const SHELL_MAX: f32 = 19.0;
const GALAXY_RADIUS: f32 = 30.0;
const GALAXY_THICKNESS: f32 = 0.7;
const GALAXY_SCALE: f32 = 1.25;
const SPHERE_SCALE: f32 = 1.5;
/// 封面面积上限（宽高按原图比例，竖版约 1.2 × 1.68）；作品多时按数量缩小，球幕上覆盖不超过约 42%。
const MAX_CARD_AREA: f32 = 2.0;
const SPHERE_COVERAGE: f32 = 0.42;
const GALAXY_CAMERA_DIST: f32 = 46.0;
const GALAXY_CAMERA_PITCH: f32 = -0.62;
const GALAXY_CAMERA_YAW: f32 = 0.35;
const MAX_DIST: f32 = 46.0;
/// 交互模式：镜头距离 ≥ MORPH_FAR 为星系、≤ MORPH_NEAR 为球幕。
const MORPH_FAR: f32 = 30.0;
const MORPH_NEAR: f32 = 6.0;
const NEAR_PLANE: f32 = 0.25;
/// 远近样式：距离 ≤ NEAR 视为最近（粗、大、气泡字），≥ FAR 视为最远（细、小、淡）。
const STYLE_NEAR: f32 = 3.0;
const STYLE_FAR: f32 = 16.0;
/// 其他元素在锁定后的亮度。
const DIM_LEVEL: f32 = 0.1;
/// 背面可见时的亮度。
const BACK_LEVEL: f32 = 0.6;
/// 飞到眼前的封面高度占视口高度的比例。
const TARGET_SCREEN_HEIGHT: f32 = 0.62;
const FOV_Y: f32 = 1.05;
/// 封面网格：每边 GRID 格（(GRID+1)² 个顶点）。
const GRID: usize = 4;
const CARD_VERTS: usize = (GRID + 1) * (GRID + 1);
const CARD_INDICES: usize = GRID * GRID * 6;
/// 一批最多顶点数（索引是 u16）。
const BATCH_VERTS: usize = 65_535;

/// 帧信息槽位（`info` 数组下标），Dart 侧 `FfcPanoInfo` 同表。
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
    /// 封面本体（不含辉光留边）投影后的外接矩形 x, y, w, h。
    pub const TARGET_RECT: usize = 15;
    pub const LOCK_PROGRESS: usize = 19;
    pub const PHASE: usize = 20;
    pub const HANDOFF: usize = 21;
    pub const DIM: usize = 22;
    /// 0 = 星系，1 = 球幕。
    pub const MORPH: usize = 23;
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

/// 批次表里锁定目标那一批的页号：Dart 用高清带框封面画它（纹理坐标是 0..1 的归一值）。
pub const TARGET_PAGE: i32 = -1;

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

/// 单位四元数 (x, y, z, w)：封面姿态插值用。
#[derive(Clone, Copy, Debug, PartialEq)]
struct Quat(f32, f32, f32, f32);

impl Quat {
    /// 由右手正交基（列 = 右 / 上 / 法线）构造。
    fn from_basis(r: V3, u: V3, n: V3) -> Quat {
        let (m00, m10, m20) = (r.0, r.1, r.2);
        let (m01, m11, m21) = (u.0, u.1, u.2);
        let (m02, m12, m22) = (n.0, n.1, n.2);
        let trace = m00 + m11 + m22;
        let q = if trace > 0.0 {
            let s = (trace + 1.0).sqrt() * 2.0;
            Quat((m21 - m12) / s, (m02 - m20) / s, (m10 - m01) / s, 0.25 * s)
        } else if m00 > m11 && m00 > m22 {
            let s = (1.0 + m00 - m11 - m22).sqrt() * 2.0;
            Quat(0.25 * s, (m01 + m10) / s, (m02 + m20) / s, (m21 - m12) / s)
        } else if m11 > m22 {
            let s = (1.0 + m11 - m00 - m22).sqrt() * 2.0;
            Quat((m01 + m10) / s, 0.25 * s, (m12 + m21) / s, (m02 - m20) / s)
        } else {
            let s = (1.0 + m22 - m00 - m11).sqrt() * 2.0;
            Quat((m02 + m20) / s, (m12 + m21) / s, 0.25 * s, (m10 - m01) / s)
        };
        q.normalized()
    }

    fn normalized(self) -> Quat {
        let l = (self.0 * self.0 + self.1 * self.1 + self.2 * self.2 + self.3 * self.3).sqrt();
        if l < 1e-9 {
            Quat(0.0, 0.0, 0.0, 1.0)
        } else {
            Quat(self.0 / l, self.1 / l, self.2 / l, self.3 / l)
        }
    }

    fn rotate(self, v: V3) -> V3 {
        let q = V3(self.0, self.1, self.2);
        let t = q.cross(v).scale(2.0);
        v.add(t.scale(self.3)).add(q.cross(t))
    }

    fn basis(self) -> (V3, V3, V3) {
        (
            self.rotate(V3(1.0, 0.0, 0.0)),
            self.rotate(V3(0.0, 1.0, 0.0)),
            self.rotate(V3(0.0, 0.0, 1.0)),
        )
    }

    fn slerp(self, other: Quat, t: f32) -> Quat {
        let mut b = other;
        let mut d = self.0 * b.0 + self.1 * b.1 + self.2 * b.2 + self.3 * b.3;
        if d < 0.0 {
            b = Quat(-b.0, -b.1, -b.2, -b.3);
            d = -d;
        }
        if d > 0.9995 {
            return Quat(
                self.0 + (b.0 - self.0) * t,
                self.1 + (b.1 - self.1) * t,
                self.2 + (b.2 - self.2) * t,
                self.3 + (b.3 - self.3) * t,
            )
            .normalized();
        }
        let theta = d.clamp(-1.0, 1.0).acos();
        let s = theta.sin();
        let wa = ((1.0 - t) * theta).sin() / s;
        let wb = (t * theta).sin() / s;
        Quat(
            self.0 * wa + b.0 * wb,
            self.1 * wa + b.1 * wb,
            self.2 * wa + b.2 * wb,
            self.3 * wa + b.3 * wb,
        )
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

/// 镜头：yaw / pitch / 离原点距离。
#[derive(Clone, Copy, Debug, PartialEq)]
struct Camera {
    yaw: f32,
    pitch: f32,
    dist: f32,
}

const INTERACTIVE_HOME: Camera = Camera {
    yaw: GALAXY_CAMERA_YAW,
    pitch: GALAXY_CAMERA_PITCH,
    dist: GALAXY_CAMERA_DIST,
};

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

    /// 从原点看向 [dir] 的 yaw / pitch。
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
    /// 基础世界尺寸（面积统一）；星系 / 球幕再乘各自倍数。
    w: f32,
    h: f32,
    hue: f32,
    // 星系参数
    arm_angle: f32,
    galaxy_r: f32,
    galaxy_y: f32,
    spin0: f32,
    spin_w: f32,
    // 球幕位置与姿态
    sphere: V3,
    sphere_q: Quat,
    /// 过渡起始错开（0..1，乘 [MORPH_STAGGER]）。
    stagger: f32,
}

struct Word {
    owner: Option<usize>,
    glyph_start: usize,
    glyph_count: usize,
    /// 字身世界高度。
    em: f32,
    hue: f32,
    // 环绕轨道（有主）：轨道平面两轴、半径倍数（乘封面尺寸）、角速度、初相
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
    turn: f32,
    from: Camera,
    to: Camera,
}

impl Lock {
    fn total(&self) -> f32 {
        self.turn + LOCK_FLY
    }
}

/// 一个待画元素（排序用）。
#[derive(Clone, Copy)]
struct Item {
    depth: f32,
    /// 作品下标；词为 `WORD_FLAG | 词下标`。
    id: u32,
}

const WORD_FLAG: u32 = 1 << 31;

/// 一张封面本帧的位姿（世界坐标）。
#[derive(Clone, Copy)]
struct Pose {
    center: V3,
    right: V3,
    up: V3,
    normal: V3,
    /// 封面本体半宽 / 半高（世界单位，已乘阶段倍数）。
    hw: f32,
    hh: f32,
}

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
    /// 交互模式下的动画时钟（秒，供公转 / 自转 / 轨道）。
    clock: f32,

    items: Vec<Item>,
    poses: Vec<Pose>,
    /// 上一帧每个作品封面本体投影后的四角（拾取用）与深度；不可见为 None。
    pick_quads: Vec<Option<([f32; 8], f32)>>,

    out_pos: Vec<f32>,
    out_uv: Vec<f32>,
    out_color: Vec<i32>,
    out_index: Vec<u16>,
    out_batch: Vec<i32>,
    out_info: Vec<f32>,
    verts: usize,
    indices: usize,
    batches: usize,
}

/// 帧状态（一帧内的布局求值上下文）。
struct Frame {
    clock: f32,
    /// 0 = 星系，1 = 球幕（全局进度，每张卡再按 stagger 错开）。
    morph: f32,
    /// 大爆炸展开（0 = 全部在原点，1 = 展开完）。
    bang: f32,
    dim: f32,
    target: Option<usize>,
    /// 目标从球面飞向镜头的进度（0..1）。
    fly: f32,
    fly_to: V3,
    fly_q: Quat,
}

/// 批写入游标。
struct Emit {
    verts: usize,
    indices: usize,
    batches: usize,
    cur_page: i32,
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
            || cell_page.iter().any(|&p| p < 0)
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
        let sphere_area = 4.0 * PI * SPHERE_RADIUS * SPHERE_RADIUS;
        let card_area = (SPHERE_COVERAGE * sphere_area
            / (SPHERE_SCALE * SPHERE_SCALE * n_works.max(1) as f32))
            .min(MAX_CARD_AREA);
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
            // 越往外越薄。
            let thin = 1.0 - 0.6 * galaxy_r / GALAXY_RADIUS;
            works.push(Work {
                aspect,
                cell: cell_of(works_cell[i])?,
                cover_px_w,
                w,
                h,
                hue,
                arm_angle: arm + rng.gauss() * 0.22,
                galaxy_r,
                galaxy_y: (rng.gauss() * 0.35).clamp(-GALAXY_THICKNESS, GALAXY_THICKNESS) * thin,
                spin0: rng.range(0.0, TAU),
                spin_w: rng.range(0.12, 0.35) * if rng.unit() < 0.5 { -1.0 } else { 1.0 },
                sphere,
                sphere_q: sphere_orientation(sphere),
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
                Some(o) => (
                    mean_h * 0.08,
                    (works[o].hue + rng.gauss() * 0.04).rem_euclid(1.0),
                    rng.range(0.62, 1.15),
                ),
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
                galaxy_y: (rng.gauss() * 0.5).clamp(-1.2, 1.2),
                shell,
                stagger: rng.unit(),
                advance,
            });
        }

        // 容量：每作品一张网格（+ 锁定目标再一张）；每字形最多 3 片（细 / 描边 / 字心交叉淡化）。
        let vcap = (n_works + 1) * CARD_VERTS + n_glyphs * 3 * 4;
        let icap = (n_works + 1) * CARD_INDICES + n_glyphs * 3 * 6;
        // 批次：每元素至多换一次页，另加按顶点上限切的批与目标批。
        let bcap = n_works + n_words + vcap / BATCH_VERTS + 4;
        Ok(Pano {
            cells,
            cell_page,
            glyph_em_px,
            pick_quads: vec![None; n_works],
            poses: Vec::with_capacity(n_works),
            works,
            words,
            glyphs,
            mode: MODE_INTERACTIVE,
            cinematic_target: None,
            camera: INTERACTIVE_HOME,
            vel_yaw: 0.0,
            vel_pitch: 0.0,
            holding: false,
            lock: None,
            clock: 0.0,
            items: Vec::with_capacity(n_works + n_words),
            out_pos: vec![0.0; vcap.max(1) * 2],
            out_uv: vec![0.0; vcap.max(1) * 2],
            out_color: vec![0; vcap.max(1)],
            out_index: vec![0; icap.max(1)],
            out_batch: vec![0; bcap * 5],
            out_info: vec![0.0; info::LEN],
            verts: 0,
            indices: 0,
            batches: 0,
        })
    }

    fn set_mode(&mut self, mode: i32, target: i32) -> i32 {
        if mode != MODE_INTERACTIVE && mode != MODE_CINEMATIC {
            return status::INVALID_ARGUMENT;
        }
        self.mode = mode;
        self.lock = None;
        self.vel_yaw = 0.0;
        self.vel_pitch = 0.0;
        self.holding = false;
        self.cinematic_target = if target >= 0 && (target as usize) < self.works.len() {
            Some(target as usize)
        } else {
            None
        };
        if mode == MODE_INTERACTIVE {
            self.camera = INTERACTIVE_HOME;
        }
        status::OK
    }

    /// 像素 → 弧度。
    const DRAG_GAIN: f32 = 0.0042;

    fn input(&mut self, kind: i32, a: f32, b: f32) -> i32 {
        if !a.is_finite() || !b.is_finite() {
            return status::INVALID_ARGUMENT;
        }
        if self.mode != MODE_INTERACTIVE || self.lock.is_some() {
            return status::OK;
        }
        let g = Self::DRAG_GAIN;
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
                // 比例换算成距离：原点附近（dist = 0）也能推出去。
                let d = self.camera.dist + 1.0;
                self.camera.dist = (d / a - 1.0).clamp(0.0, MAX_DIST);
            }
            _ => return status::INVALID_ARGUMENT,
        }
        status::OK
    }

    fn make_lock(&self, target: usize, t0: f32, from: Camera) -> Lock {
        let (yaw, pitch) = Camera::facing(self.works[target].sphere);
        Lock {
            target,
            t0,
            // 从远处（星系）来时多给一点转向 / 收拢时间。
            turn: LOCK_TURN + 1.2 * clamp01(from.dist / GALAXY_CAMERA_DIST),
            from,
            to: Camera {
                yaw: from.yaw + angle_delta(from.yaw, yaw),
                pitch,
                dist: 0.0,
            },
        }
    }

    fn select(&mut self, work: i32, t: f32) -> i32 {
        if work < 0 || work as usize >= self.works.len() {
            return status::INVALID_ARGUMENT;
        }
        self.lock = Some(self.make_lock(work as usize, t, self.camera));
        self.vel_yaw = 0.0;
        self.vel_pitch = 0.0;
        status::OK
    }

    fn pick(&self, x: f32, y: f32) -> i32 {
        // 命中多张时取最近（深度最小）的。
        let mut best: Option<(usize, f32)> = None;
        for (i, q) in self.pick_quads.iter().enumerate() {
            let Some((c, depth)) = q else { continue };
            if point_in_quad(x, y, c) && best.is_none_or(|(_, d)| *depth < d) {
                best = Some((i, *depth));
            }
        }
        best.map(|(i, _)| i as i32).unwrap_or(-1)
    }

    /// 镜头 + 阶段（分享动画按时间轴；交互模式按状态与惯性，布局随镜头距离变形）。
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
            fly_q: Quat(0.0, 0.0, 0.0, 1.0),
        };
        if self.mode == MODE_CINEMATIC {
            frame.bang = ease_out_expo(t / T_BANG_END);
            frame.morph = clamp01((t - T_GALAXY_END) / MORPH_SECONDS);
            let k = ease_in_out(frame.morph);
            let yaw0 = GALAXY_CAMERA_YAW + T_GALAXY_END * 0.12;
            let yaw_look = yaw0 + MORPH_SECONDS * 0.12 * 0.5;
            let cam = if t < T_GALAXY_END {
                Camera {
                    yaw: GALAXY_CAMERA_YAW + t * 0.12,
                    pitch: GALAXY_CAMERA_PITCH,
                    dist: GALAXY_CAMERA_DIST,
                }
            } else if t < T_SPHERE_END {
                // 过渡段：从星系俯视推进到球心，yaw 连续接上环顾段起点。
                Camera {
                    yaw: yaw0 + (yaw_look - yaw0) * k,
                    pitch: GALAXY_CAMERA_PITCH * (1.0 - k),
                    dist: GALAXY_CAMERA_DIST * (1.0 - k),
                }
            } else {
                let look = ease_in_out((t - T_SPHERE_END) / (T_LOOK_END - T_SPHERE_END));
                Camera {
                    yaw: yaw_look + TAU * look,
                    pitch: 0.12 * (look * TAU).sin(),
                    dist: 0.0,
                }
            };
            match self.cinematic_target {
                Some(target) if t >= T_LOOK_END => {
                    let look_end = Camera {
                        yaw: yaw_look + TAU,
                        pitch: 0.0,
                        dist: 0.0,
                    };
                    self.lock = Some(self.make_lock(target, T_LOOK_END, look_end));
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
            }
        }
        if let Some(lock) = self.lock {
            let lt = t - lock.t0;
            let turn = ease_in_out(lt / lock.turn);
            self.camera = Camera {
                yaw: lock.from.yaw + (lock.to.yaw - lock.from.yaw) * turn,
                pitch: lock.from.pitch + (lock.to.pitch - lock.from.pitch) * turn,
                dist: lock.from.dist + (lock.to.dist - lock.from.dist) * turn,
            };
            frame.dim = 1.0 - (1.0 - DIM_LEVEL) * smooth(lt / lock.turn);
            frame.target = Some(lock.target);
            frame.fly = ease_in_out((lt - lock.turn) / LOCK_FLY);
        }
        if self.mode == MODE_INTERACTIVE {
            frame.morph = clamp01((MORPH_FAR - self.camera.dist) / (MORPH_FAR - MORPH_NEAR));
        }
        frame
    }

    /// 作品 [i] 的过渡进度（0 = 星系，1 = 球幕），按 stagger 错开约 1.2 秒。
    fn work_morph(&self, i: usize, f: &Frame) -> f32 {
        let s = MORPH_STAGGER / MORPH_SECONDS;
        ease_in_out((f.morph * (1.0 + s) - self.works[i].stagger * s).clamp(0.0, 1.0))
    }

    /// 作品 [i] 的布局位姿（不含锁定飞入）：它的环绕词绕这里转。
    fn work_pose(&self, i: usize, f: &Frame) -> Pose {
        let w = &self.works[i];
        let m = self.work_morph(i, f);
        // 星系：随旋臂公转（越靠中心越快），面朝上，绕法线自转。
        let ang = w.arm_angle + w.galaxy_r * 0.16 + f.clock * 0.9 / w.galaxy_r.sqrt();
        let galaxy = V3(ang.cos() * w.galaxy_r, w.galaxy_y, ang.sin() * w.galaxy_r).scale(f.bang);
        let phi = w.spin0 + f.clock * w.spin_w;
        let (sp, cp) = phi.sin_cos();
        let flat = Quat::from_basis(V3(cp, 0.0, sp), V3(sp, 0.0, -cp), V3(0.0, 1.0, 0.0));
        let q = if m <= 0.0 {
            flat
        } else if m >= 1.0 {
            w.sphere_q
        } else {
            flat.slerp(w.sphere_q, m)
        };
        let (right, up, normal) = q.basis();
        let scale = GALAXY_SCALE + (SPHERE_SCALE - GALAXY_SCALE) * m;
        Pose {
            center: galaxy.lerp(w.sphere, m),
            right,
            up,
            normal,
            hw: w.w * scale * 0.5,
            hh: w.h * scale * 0.5,
        }
    }

    fn word_pos(&self, i: usize, f: &Frame, owner: Option<&Pose>) -> V3 {
        let wd = &self.words[i];
        match (wd.owner, owner) {
            (Some(_), Some(p)) => {
                let a = wd.orbit_phase + f.clock * wd.orbit_w;
                let (s, c) = a.sin_cos();
                let r = wd.orbit_r * p.hw.max(p.hh) * 2.0 * (0.3 + 0.7 * f.bang);
                p.center
                    .add(wd.orbit_a.scale(c * r))
                    .add(wd.orbit_b.scale(s * r))
            }
            _ => {
                let ang = wd.arm_angle + wd.galaxy_r * 0.16 + f.clock * 0.7 / wd.galaxy_r.sqrt();
                let galaxy = V3(
                    ang.cos() * wd.galaxy_r,
                    wd.galaxy_y,
                    ang.sin() * wd.galaxy_r,
                )
                .scale(f.bang);
                let s = MORPH_STAGGER / MORPH_SECONDS;
                let m = ease_in_out((f.morph * (1.0 + s) - wd.stagger * s).clamp(0.0, 1.0));
                galaxy.lerp(wd.shell, m)
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

        // 目标飞到镜头正前方、正对镜头：距离按「封面高度占视口 62%」反推。
        if let Some(target) = f.target {
            let p = self.work_pose(target, &f);
            let d = (p.hh * 2.0) * focal / (TARGET_SCREEN_HEIGHT * vh);
            let (yaw, pitch) = Camera::facing(self.works[target].sphere);
            let tb = Camera {
                yaw,
                pitch,
                dist: 0.0,
            }
            .basis();
            f.fly_to = tb.forward.scale(d.max(NEAR_PLANE * 2.0));
            // 正对镜头：法线指回镜头，上 = 镜头上，右 = 镜头右（不镜像）。
            f.fly_q = Quat::from_basis(tb.right, tb.up, tb.forward.scale(-1.0));
        }

        let project = |p: V3| -> Option<(f32, f32, f32)> {
            let rel = p.sub(basis.pos);
            let z = rel.dot(basis.forward);
            if z <= NEAR_PLANE {
                return None;
            }
            let s = focal / z;
            Some((cx + rel.dot(basis.right) * s, cy - rel.dot(basis.up) * s, z))
        };

        // 1. 位姿与可见元素。
        self.poses.clear();
        for i in 0..self.works.len() {
            let p = self.work_pose(i, &f);
            self.poses.push(p);
        }
        self.items.clear();
        for i in 0..self.works.len() {
            self.pick_quads[i] = None;
            let mut pose = self.poses[i];
            if f.target == Some(i) {
                pose = self.fly_pose(pose, &f);
            }
            let mut quad = [0f32; 8];
            let mut ok = true;
            let mut min_x = f32::MAX;
            let mut max_x = f32::MIN;
            let mut min_y = f32::MAX;
            let mut max_y = f32::MIN;
            for (k, (sx, sy)) in [(-1.0, 1.0), (1.0, 1.0), (1.0, -1.0), (-1.0, -1.0)]
                .into_iter()
                .enumerate()
            {
                let corner = pose
                    .center
                    .add(pose.right.scale(sx * pose.hw))
                    .add(pose.up.scale(sy * pose.hh));
                match project(corner) {
                    Some((x, y, _)) => {
                        quad[k * 2] = x;
                        quad[k * 2 + 1] = y;
                        min_x = min_x.min(x);
                        max_x = max_x.max(x);
                        min_y = min_y.min(y);
                        max_y = max_y.max(y);
                    }
                    None => ok = false,
                }
            }
            if !ok || max_x < 0.0 || min_x > vw || max_y < 0.0 || min_y > vh {
                continue;
            }
            if (max_x - min_x) < 0.6 && (max_y - min_y) < 0.6 {
                continue;
            }
            let depth = pose.center.sub(basis.pos).len();
            self.pick_quads[i] = Some((quad, depth));
            self.items.push(Item {
                depth,
                id: i as u32,
            });
        }
        for i in 0..self.words.len() {
            let owner = self.words[i].owner.map(|o| &self.poses[o]);
            let p = self.word_pos(i, &f, owner);
            if let Some((sx, sy, z)) = project(p) {
                let wd = &self.words[i];
                let half_w = wd.advance * wd.em * focal / z * 0.8;
                let half_h = wd.em * focal / z * 0.8;
                if half_h < 0.75
                    || sx + half_w < 0.0
                    || sx - half_w > vw
                    || sy + half_h < 0.0
                    || sy - half_h > vh
                {
                    continue;
                }
                self.items.push(Item {
                    depth: p.sub(basis.pos).len(),
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

        // 2. 依序写网格，按图集页 / 顶点上限切批。锁定目标最后单独一批（Dart 画高清图）。
        let mut e = Emit {
            verts: 0,
            indices: 0,
            batches: 0,
            cur_page: i32::MIN,
        };
        let items = std::mem::take(&mut self.items);
        for item in &items {
            if item.id & WORD_FLAG == 0 {
                let i = item.id as usize;
                if f.target == Some(i) {
                    continue;
                }
                let pose = self.poses[i];
                let alpha = clamp01(f.bang * 1.4 - self.works[i].stagger * 0.4);
                self.emit_card(&mut e, i, &pose, &basis, focal, cx, cy, alpha, f.dim, false);
            } else {
                let i = (item.id & !WORD_FLAG) as usize;
                let owner = self.words[i].owner.map(|o| self.poses[o]);
                let p = self.word_pos(i, &f, owner.as_ref());
                let Some((sx, sy, z)) = project(p) else {
                    continue;
                };
                self.emit_word(&mut e, i, sx, sy, focal / z, item.depth, vh, f.bang, f.dim);
            }
        }
        self.items = items;
        if let Some(target) = f.target {
            let pose = self.fly_pose(self.poses[target], &f);
            e.cur_page = i32::MIN;
            self.emit_card(&mut e, target, &pose, &basis, focal, cx, cy, 1.0, 1.0, true);
        }
        self.verts = e.verts;
        self.indices = e.indices;
        self.batches = e.batches;

        // 3. 帧信息。
        let info_buf = &mut self.out_info;
        info_buf.iter_mut().for_each(|v| *v = 0.0);
        if let Some((hx, hy, z)) = project(V3::default()) {
            info_buf[info::HALO_X] = hx;
            info_buf[info::HALO_Y] = hy;
            info_buf[info::HALO_R] = 6.0 * focal / z;
            // 强度固定；只在镜头进到光晕所在处（原点附近）时按距离收掉，避免糊屏。
            info_buf[info::HALO_ALPHA] = smooth((self.camera.dist - 2.0) / 10.0) * f.bang.max(0.15);
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
        info_buf[info::MORPH] = f.morph;
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
            info_buf[info::LOCK_PROGRESS] = clamp01(lt / lock.total());
            info_buf[info::HANDOFF] = if lt >= lock.total() { 1.0 } else { 0.0 };
            if let Some((q, _)) = self.pick_quads[target] {
                let xs = [q[0], q[2], q[4], q[6]];
                let ys = [q[1], q[3], q[5], q[7]];
                let min_x = xs.iter().cloned().fold(f32::MAX, f32::min);
                let max_x = xs.iter().cloned().fold(f32::MIN, f32::max);
                let min_y = ys.iter().cloned().fold(f32::MAX, f32::min);
                let max_y = ys.iter().cloned().fold(f32::MIN, f32::max);
                info_buf[info::TARGET_VISIBLE] = 1.0;
                info_buf[info::TARGET_RECT] = min_x;
                info_buf[info::TARGET_RECT + 1] = min_y;
                info_buf[info::TARGET_RECT + 2] = max_x - min_x;
                info_buf[info::TARGET_RECT + 3] = max_y - min_y;
            }
        }
        status::OK
    }

    /// 锁定目标的位姿：沿半径飞向镜头正前方，同时转成正对镜头。
    fn fly_pose(&self, base: Pose, f: &Frame) -> Pose {
        if f.fly <= 0.0 {
            return base;
        }
        let q0 = Quat::from_basis(base.right, base.up, base.normal);
        let (right, up, normal) = q0.slerp(f.fly_q, f.fly).basis();
        Pose {
            center: base.center.lerp(f.fly_to, f.fly),
            right,
            up,
            normal,
            ..base
        }
    }

    /// 开新批（换页或顶点将满时）。
    fn ensure_batch(&mut self, e: &mut Emit, page: i32, need_verts: usize) -> bool {
        if e.verts + need_verts > self.out_color.len() || e.batches * 5 + 5 > self.out_batch.len() {
            return false;
        }
        let full = e.batches > 0 && {
            let b = e.batches - 1;
            self.out_batch[b * 5 + 2] as usize + need_verts > BATCH_VERTS
        };
        if page != e.cur_page || full {
            e.cur_page = page;
            let b = e.batches;
            self.out_batch[b * 5] = page;
            self.out_batch[b * 5 + 1] = e.verts as i32;
            self.out_batch[b * 5 + 2] = 0;
            self.out_batch[b * 5 + 3] = e.indices as i32;
            self.out_batch[b * 5 + 4] = 0;
            e.batches += 1;
        }
        true
    }

    /// 写一张封面网格（含辉光留边的整格映射到四边形外扩处）。[target] 时进 [TARGET_PAGE]
    /// 批、纹理坐标为整张高清图的 0..1。
    #[allow(clippy::too_many_arguments)]
    fn emit_card(
        &mut self,
        e: &mut Emit,
        i: usize,
        pose: &Pose,
        basis: &Basis,
        focal: f32,
        cx: f32,
        cy: f32,
        alpha: f32,
        dim: f32,
        target: bool,
    ) {
        let wk = &self.works[i];
        let cell = self.cells[wk.cell];
        let page = if target {
            TARGET_PAGE
        } else {
            self.cell_page[wk.cell]
        };
        let cover_px_w = wk.cover_px_w;
        if !self.ensure_batch(e, page, CARD_VERTS)
            || e.indices + CARD_INDICES > self.out_index.len()
        {
            return;
        }
        // 整格（含留边）相对封面本体的外扩倍数。
        let k = (pose.hw * 2.0) / cover_px_w;
        let (fw, fh) = (cell[2] * k * 0.5, cell[3] * k * 0.5);
        let back = pose.normal.dot(basis.pos.sub(pose.center)) < 0.0;
        let c = dim * if back { BACK_LEVEL } else { 1.0 };
        let color = argb(alpha, c, c, c);
        let b = e.batches - 1;
        let base = self.out_batch[b * 5 + 2] as usize;
        for gy in 0..=GRID {
            for gx in 0..=GRID {
                let u = gx as f32 / GRID as f32;
                let v = gy as f32 / GRID as f32;
                let world = pose
                    .center
                    .add(pose.right.scale((u * 2.0 - 1.0) * fw))
                    .add(pose.up.scale((1.0 - v * 2.0) * fh));
                let rel = world.sub(basis.pos);
                let z = rel.dot(basis.forward).max(NEAR_PLANE);
                let s = focal / z;
                let at = e.verts;
                self.out_pos[at * 2] = cx + rel.dot(basis.right) * s;
                self.out_pos[at * 2 + 1] = cy - rel.dot(basis.up) * s;
                // 背面：水平翻转纹理，字是正的。
                let tu = if back { 1.0 - u } else { u };
                if target {
                    self.out_uv[at * 2] = tu;
                    self.out_uv[at * 2 + 1] = v;
                } else {
                    self.out_uv[at * 2] = cell[0] + tu * cell[2];
                    self.out_uv[at * 2 + 1] = cell[1] + v * cell[3];
                }
                self.out_color[at] = color;
                e.verts += 1;
            }
        }
        let row = GRID + 1;
        for gy in 0..GRID {
            for gx in 0..GRID {
                let a = (base + gy * row + gx) as u16;
                let bb = a + 1;
                let cc = a + row as u16;
                let d = cc + 1;
                self.out_index[e.indices..e.indices + 6].copy_from_slice(&[a, bb, cc, bb, d, cc]);
                e.indices += 6;
            }
        }
        self.out_batch[b * 5 + 2] += CARD_VERTS as i32;
        self.out_batch[b * 5 + 4] += CARD_INDICES as i32;
    }

    /// 写一个词：屏幕空间字形片（远：细小淡；近：粗大 + 白字心彩色描边，连续过渡）。
    #[allow(clippy::too_many_arguments)]
    fn emit_word(
        &mut self,
        e: &mut Emit,
        i: usize,
        sx: f32,
        sy: f32,
        s: f32,
        dist: f32,
        vh: f32,
        bang: f32,
        dim: f32,
    ) {
        let near = smooth((STYLE_FAR - dist) / (STYLE_FAR - STYLE_NEAR));
        let (em, advance, hue, stagger, start, count) = {
            let wd = &self.words[i];
            (
                wd.em,
                wd.advance,
                wd.hue,
                wd.stagger,
                wd.glyph_start,
                wd.glyph_count,
            )
        };
        // 镜头穿过词云时近处的词会无限放大：屏幕字号封顶在视口高 5%（气泡样式照常）。
        let px_em = (em * s * (0.7 + 0.9 * near)).min(vh * 0.05);
        let k = px_em / self.glyph_em_px;
        let x0 = sx - advance * px_em * 0.5;
        let alpha = clamp01(bang * 1.3 - stagger * 0.3) * (0.4 + 0.6 * near);
        let (hr, hg, hb) = hsv_to_rgb(hue, 0.35 + 0.45 * near, 1.0);
        let pale = (0.55 + 0.45 * near) * dim;
        let thin_a = alpha * (1.0 - near);
        let bold_a = alpha * near;
        let mut pen = x0;
        for g in start..start + count {
            let (thin, fill, outline, adv) = {
                let gl = &self.glyphs[g];
                (gl.thin, gl.fill, gl.outline, gl.advance)
            };
            let cell = self.cells[thin];
            let gx = pen + cell[2] * k * 0.5;
            if thin_a > 0.01 {
                self.emit_glyph(
                    e,
                    thin,
                    gx,
                    sy,
                    k,
                    argb(thin_a, hr * pale, hg * pale, hb * pale),
                );
            }
            if bold_a > 0.01 {
                self.emit_glyph(
                    e,
                    outline,
                    gx,
                    sy,
                    k,
                    argb(bold_a, hr * dim, hg * dim, hb * dim),
                );
                self.emit_glyph(e, fill, gx, sy, k, argb(bold_a, dim, dim, dim));
            }
            pen += adv * px_em;
        }
    }

    /// 一片字形：以 (cx, cy) 为中心、按 k 缩放的格子。
    fn emit_glyph(&mut self, e: &mut Emit, cell_i: usize, cx: f32, cy: f32, k: f32, color: i32) {
        let page = self.cell_page[cell_i];
        if !self.ensure_batch(e, page, 4) || e.indices + 6 > self.out_index.len() {
            return;
        }
        let cell = self.cells[cell_i];
        let (hw, hh) = (cell[2] * k * 0.5, cell[3] * k * 0.5);
        let b = e.batches - 1;
        let base = self.out_batch[b * 5 + 2] as u16;
        let corners = [
            (cx - hw, cy - hh, cell[0], cell[1]),
            (cx + hw, cy - hh, cell[0] + cell[2], cell[1]),
            (cx - hw, cy + hh, cell[0], cell[1] + cell[3]),
            (cx + hw, cy + hh, cell[0] + cell[2], cell[1] + cell[3]),
        ];
        for (x, y, u, v) in corners {
            let at = e.verts;
            self.out_pos[at * 2] = x;
            self.out_pos[at * 2 + 1] = y;
            self.out_uv[at * 2] = u;
            self.out_uv[at * 2 + 1] = v;
            self.out_color[at] = color;
            e.verts += 1;
        }
        self.out_index[e.indices..e.indices + 6].copy_from_slice(&[
            base,
            base + 1,
            base + 2,
            base + 1,
            base + 3,
            base + 2,
        ]);
        e.indices += 6;
        self.out_batch[b * 5 + 2] += 4;
        self.out_batch[b * 5 + 4] += 6;
    }
}

/// 球面上 [p] 处的封面姿态：正面朝球心，上方向取世界上方向在卡面上的投影（两极附近自然倾斜）。
fn sphere_orientation(p: V3) -> Quat {
    let n = p.scale(-1.0).norm();
    let y = V3(0.0, 1.0, 0.0);
    let mut up = y.sub(n.scale(n.dot(y)));
    if up.len() < 1e-4 {
        // 正好在极点：退回世界 z 轴的投影。
        let z = V3(0.0, 0.0, 1.0);
        up = z.sub(n.scale(n.dot(z)));
    }
    let up = up.norm();
    let right = up.cross(n).norm();
    Quat::from_basis(right, up, n)
}

/// 点是否在凸四边形内（四角按顺时针或逆时针给出）。
fn point_in_quad(x: f32, y: f32, q: &[f32; 8]) -> bool {
    let mut sign = 0.0f32;
    for k in 0..4 {
        let (ax, ay) = (q[k * 2], q[k * 2 + 1]);
        let (bx, by) = (q[(k * 2 + 2) % 8], q[(k * 2 + 3) % 8]);
        let cross = (bx - ax) * (y - ay) - (by - ay) * (x - ax);
        if cross.abs() < 1e-6 {
            continue;
        }
        if sign == 0.0 {
            sign = cross.signum();
        } else if cross.signum() != sign {
            return false;
        }
    }
    sign != 0.0
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
/// - `cells_rect[n_cells * 4]`：图集格子 (x, y, w, h) 像素；`cells_page[n_cells]`：所在图集页（≥ 0）。
/// - `works_f[n_works * 3]`：(宽高比, 封面本体在格子里的像素宽, 色相 0..1)；
///   `works_cell[n_works]`：封面格子（格子含辉光留边，封面本体居中）。
/// - `words[n_words * 3]`：(所属作品下标或 -1, 字形起点, 字形数)。
/// - `glyph_cells[n_glyphs * 3]`：(细体, 粗体字心, 粗体描边) 格子；`glyph_adv[n_glyphs]`：
///   字宽（em 倍数）。
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

/// 取输出缓冲区指针（建图后不变）：pos / uv 各 `vcap * 2` 个 f32（屏幕坐标 / 图集像素坐标，
/// 目标批为 0..1），color `vcap` 个 i32，index `icap` 个 u16（相对所在批的起始顶点），
/// batch `bcap * 5` 个 i32（页, 顶点起点, 顶点数, 索引起点, 索引数），info [info::LEN] 个 f32。
/// `caps[0..3]` 写 vcap / icap / bcap。
///
/// # Safety
/// `p` 有效；各输出指针可写，`caps` 至少 3 个。
#[no_mangle]
#[allow(clippy::too_many_arguments)]
pub unsafe extern "C" fn ffc_pano_buffers(
    p: *mut Pano,
    pos: *mut *mut f32,
    uv: *mut *mut f32,
    color: *mut *mut i32,
    index: *mut *mut u16,
    batch: *mut *mut i32,
    info_out: *mut *mut f32,
    caps: *mut usize,
) -> i32 {
    guard(|| {
        if p.is_null()
            || pos.is_null()
            || uv.is_null()
            || color.is_null()
            || index.is_null()
            || batch.is_null()
            || info_out.is_null()
            || caps.is_null()
        {
            return status::NULL_ARGUMENT;
        }
        let pano = &mut *p;
        *pos = pano.out_pos.as_mut_ptr();
        *uv = pano.out_uv.as_mut_ptr();
        *color = pano.out_color.as_mut_ptr();
        *index = pano.out_index.as_mut_ptr();
        *batch = pano.out_batch.as_mut_ptr();
        *info_out = pano.out_info.as_mut_ptr();
        *caps = pano.out_color.len();
        *caps.add(1) = pano.out_index.len();
        *caps.add(2) = pano.out_batch.len() / 5;
        status::OK
    })
}

/// 切模式：[MODE_INTERACTIVE]（镜头回到星系俯视）或 [MODE_CINEMATIC]（`target` 为动画最后
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

/// 交互模式下选中作品：从当前镜头转向（布局随之收拢成球幕）并把它飞到眼前（时刻 `t` 与
/// [ffc_pano_frame] 同一时钟）。
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

/// 上一帧屏幕坐标 (x, y) 处的作品下标（多张重叠取最近的），没有为 -1。
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
/// `vw` / `vh` 为视口逻辑像素。写出顶点数 / 索引数 / 批次数（`counts[0..3]`），数据在
/// [ffc_pano_buffers] 的缓冲区里。
///
/// # Safety
/// `p` 有效；`counts` 至少 3 个可写。
#[no_mangle]
pub unsafe extern "C" fn ffc_pano_frame(
    p: *mut Pano,
    t: f64,
    dt: f32,
    vw: f32,
    vh: f32,
    counts: *mut usize,
) -> i32 {
    guard(|| {
        if p.is_null() || counts.is_null() {
            return status::NULL_ARGUMENT;
        }
        let pano = &mut *p;
        let rc = pano.frame(t as f32, dt, vw, vh);
        *counts = pano.verts;
        *counts.add(1) = pano.indices;
        *counts.add(2) = pano.batches;
        rc
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 造一个 n 部作品、每部 m 个词（每词 3 字形）+ u 个无主词的全景（封面页 0，字形页 1）。
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
            }
        }
        let ga = vec![1.0f32; total * 3];
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

    fn frame_at(m: f32, clock: f32) -> Frame {
        Frame {
            clock,
            morph: m,
            bang: 1.0,
            dim: 1.0,
            target: None,
            fly: 0.0,
            fly_to: V3::default(),
            fly_q: Quat(0.0, 0.0, 0.0, 1.0),
        }
    }

    fn close(a: V3, b: V3) -> bool {
        a.sub(b).len() < 1e-3
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
        let r = Pano::build(
            vec![[0.0; 4]],
            vec![-1],
            &[1.0, 10.0, 0.0],
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
    fn quat_roundtrip_and_slerp_endpoints() {
        let q = sphere_orientation(V3(3.0, 5.0, -7.0));
        let (r, u, n) = q.basis();
        let q2 = Quat::from_basis(r, u, n);
        let (r2, u2, n2) = q2.basis();
        assert!(close(r, r2) && close(u, u2) && close(n, n2));
        assert!(close(r.cross(u), n), "right-handed");
        let flat = Quat::from_basis(V3(1.0, 0.0, 0.0), V3(0.0, 0.0, -1.0), V3(0.0, 1.0, 0.0));
        assert!(close(flat.slerp(q, 0.0).basis().2, V3(0.0, 1.0, 0.0)));
        assert!(close(flat.slerp(q, 1.0).basis().2, n));
    }

    #[test]
    fn deterministic_for_same_seed() {
        let mut a = make(20, 5, 30);
        let mut b = make(20, 5, 30);
        a.set_mode(MODE_CINEMATIC, 3);
        b.set_mode(MODE_CINEMATIC, 3);
        a.frame(4.0, 0.016, 800.0, 600.0);
        b.frame(4.0, 0.016, 800.0, 600.0);
        assert_eq!(a.verts, b.verts);
        assert_eq!(&a.out_pos[..a.verts * 2], &b.out_pos[..b.verts * 2]);
        assert_eq!(&a.out_color[..a.verts], &b.out_color[..b.verts]);
    }

    #[test]
    fn galaxy_cards_lie_flat_face_up_in_a_thin_disc() {
        let p = make(200, 0, 0);
        let f = frame_at(0.0, 2.0);
        for i in 0..p.works.len() {
            let pose = p.work_pose(i, &f);
            assert!(close(pose.normal, V3(0.0, 1.0, 0.0)), "face up");
            assert!(pose.center.1.abs() <= GALAXY_THICKNESS + 1e-4);
            let w = &p.works[i];
            assert!((pose.hw * 2.0 - w.w * GALAXY_SCALE).abs() < 1e-3);
        }
        // 自转：同一张卡不同时刻在盘面里的角度不同。
        let a = p.work_pose(0, &frame_at(0.0, 0.0)).right;
        let b = p.work_pose(0, &frame_at(0.0, 3.0)).right;
        assert!(!close(a, b));
    }

    #[test]
    fn sphere_cards_face_the_centre_upright_with_uniform_area() {
        let p = make(120, 0, 0);
        let f = frame_at(1.0, 0.0);
        let area0 = p.works[0].w * p.works[0].h;
        for i in 0..p.works.len() {
            let pose = p.work_pose(i, &f);
            assert!((pose.center.len() - SPHERE_RADIUS).abs() < 1e-3);
            assert!(
                close(pose.normal, pose.center.scale(-1.0).norm()),
                "faces centre"
            );
            // 上方向不朝下（大致直立）。
            assert!(pose.up.1 >= -1e-4);
            assert!((pose.hw * 2.0 - p.works[i].w * SPHERE_SCALE).abs() < 1e-3);
            assert!((p.works[i].w * p.works[i].h - area0).abs() < 1e-3);
            assert!((p.works[i].w / p.works[i].h - p.works[i].aspect).abs() < 1e-3);
        }
    }

    #[test]
    fn card_area_shrinks_for_big_libraries() {
        let small = make(50, 0, 0);
        assert!((small.works[0].w * small.works[0].h - MAX_CARD_AREA).abs() < 1e-3);
        let big = make(1000, 0, 0);
        let area = big.works[0].w * big.works[0].h;
        assert!(area < MAX_CARD_AREA);
        let covered = 1000.0 * area * SPHERE_SCALE * SPHERE_SCALE;
        assert!(covered <= SPHERE_COVERAGE * 4.0 * PI * 144.0 + 1.0);
    }

    #[test]
    fn morph_is_staggered_by_about_one_point_two_seconds() {
        let p = make(300, 0, 0);
        let early = p.works.iter().position(|w| w.stagger < 0.05).unwrap();
        let late = p.works.iter().position(|w| w.stagger > 0.95).unwrap();
        // 过渡开始 0.6 秒时：早的已在动，晚的还没动。
        let f = frame_at(0.6 / MORPH_SECONDS, 0.0);
        assert!(p.work_morph(early, &f) > 0.0);
        assert_eq!(p.work_morph(late, &f), 0.0);
        let f = frame_at(1.0, 0.0);
        assert_eq!(p.work_morph(late, &f), 1.0);
    }

    #[test]
    fn big_bang_starts_from_a_point() {
        let mut p = make(30, 2, 10);
        p.set_mode(MODE_CINEMATIC, -1);
        let f = p.advance(0.0, 0.0);
        for i in 0..p.works.len() {
            assert!(p.work_pose(i, &f).center.len() < 1e-3);
        }
    }

    #[test]
    fn batches_partition_vertices_and_indices() {
        let mut p = make(40, 6, 50);
        p.set_mode(MODE_INTERACTIVE, -1);
        p.frame(0.0, 0.016, 1280.0, 720.0);
        assert!(p.verts > 0);
        let (mut v, mut ix) = (0, 0);
        for b in 0..p.batches {
            let o = b * 5;
            assert_eq!(p.out_batch[o + 1] as usize, v);
            assert_eq!(p.out_batch[o + 3] as usize, ix);
            let n = p.out_batch[o + 2] as usize;
            let ni = p.out_batch[o + 4] as usize;
            assert!(n <= BATCH_VERTS);
            for &k in &p.out_index[ix..ix + ni] {
                assert!((k as usize) < n, "index relative to batch");
            }
            v += n;
            ix += ni;
        }
        assert_eq!(v, p.verts);
        assert_eq!(ix, p.indices);
    }

    #[test]
    fn interactive_starts_on_the_galaxy_and_zooming_in_becomes_the_sphere() {
        let mut p = make(30, 0, 0);
        p.set_mode(MODE_INTERACTIVE, -1);
        p.frame(0.0, 0.0, 800.0, 600.0);
        assert_eq!(p.out_info[info::MORPH], 0.0);
        assert!(
            p.out_info[info::HALO_ALPHA] > 0.5,
            "halo visible over the galaxy"
        );
        p.input(input::ZOOM, 100.0, 0.0);
        assert_eq!(p.camera.dist, 0.0);
        p.frame(0.1, 0.1, 800.0, 600.0);
        assert_eq!(p.out_info[info::MORPH], 1.0);
        p.input(input::DRAG, 100.0, 0.0);
        assert!(p.camera.yaw < GALAXY_CAMERA_YAW);
    }

    #[test]
    fn lock_brings_target_to_screen_centre_and_dims_others() {
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
            "x centre {}",
            x + w / 2.0
        );
        assert!(
            ((y + h / 2.0) - 400.0).abs() < 1.0,
            "y centre {}",
            y + h / 2.0
        );
        assert!((h - 0.62 * 800.0).abs() < 2.0, "h {h}");
        assert!((w / h - p.works[17].aspect).abs() < 1e-2);
        assert!((i[info::DIM] - DIM_LEVEL).abs() < 1e-4);
        // 目标是最后一批、页号 TARGET_PAGE、纹理坐标 0..1 且不翻转（正面）。
        let b = (p.batches - 1) * 5;
        assert_eq!(p.out_batch[b], TARGET_PAGE);
        assert_eq!(p.out_batch[b + 2] as usize, CARD_VERTS);
        let v0 = p.out_batch[b + 1] as usize;
        assert_eq!(&p.out_uv[v0 * 2..v0 * 2 + 2], &[0.0, 0.0]);
        // 左上角顶点在屏幕左上。
        assert!(p.out_pos[v0 * 2] < 500.0 && p.out_pos[v0 * 2 + 1] < 400.0);
    }

    #[test]
    fn interactive_select_from_the_galaxy_ends_at_the_centre() {
        let mut p = make(40, 2, 0);
        p.set_mode(MODE_INTERACTIVE, -1);
        p.frame(0.0, 0.0, 800.0, 600.0);
        p.select(5, 0.0);
        p.frame(10.0, 0.1, 800.0, 600.0);
        assert_eq!(p.out_info[info::HANDOFF], 1.0);
        assert_eq!(p.camera.dist, 0.0);
        assert_eq!(p.out_info[info::MORPH], 1.0);
    }

    #[test]
    fn back_faces_are_unmirrored_and_darker() {
        let mut p = make(60, 0, 0);
        p.set_mode(MODE_INTERACTIVE, -1);
        // 球幕布局、镜头在球外：近半球露背面。
        p.camera.dist = 5.0;
        p.input(input::ZOOM, 1.0, 0.0);
        p.frame(0.0, 0.0, 800.0, 600.0);
        p.camera = Camera {
            yaw: 0.0,
            pitch: 0.0,
            dist: 30.0,
        };
        let f = frame_at(1.0, 0.0);
        let basis = p.camera.basis();
        let mut e = Emit {
            verts: 0,
            indices: 0,
            batches: 0,
            cur_page: i32::MIN,
        };
        // 镜头正前方、球前侧的卡：法线朝球心（背向镜头）→ 背面。
        let front = (0..60)
            .min_by(|&a, &b| {
                let da = p.work_pose(a, &f).center.sub(basis.pos).len();
                let db = p.work_pose(b, &f).center.sub(basis.pos).len();
                da.partial_cmp(&db).unwrap()
            })
            .unwrap();
        let pose = p.work_pose(front, &f);
        p.emit_card(
            &mut e, front, &pose, &basis, 500.0, 400.0, 300.0, 1.0, 1.0, false,
        );
        let c = p.out_color[0] as u32;
        assert_eq!((c >> 16) & 0xFF, (BACK_LEVEL * 255.0 + 0.5) as u32);
        // 背面：u = 0 的顶点取格子右边缘（字不反）。
        let cell = p.cells[p.works[front].cell];
        assert!((p.out_uv[0] - (cell[0] + cell[2])).abs() < 1e-3);
    }

    #[test]
    fn far_words_are_thin_and_near_words_are_bubbled() {
        let mut p = make(1, 0, 0);
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
        let mut e = Emit {
            verts: 0,
            indices: 0,
            batches: 0,
            cur_page: i32::MIN,
        };
        p.words = vec![Word {
            owner: None,
            glyph_start: 0,
            glyph_count: 1,
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
            shell: V3::default(),
            stagger: 0.0,
            advance: 1.0,
        }];
        p.out_pos = vec![0.0; 64];
        p.out_uv = vec![0.0; 64];
        p.out_color = vec![0; 32];
        p.out_index = vec![0; 64];
        p.out_batch = vec![0; 40];
        p.emit_word(&mut e, 0, 400.0, 400.0, 30.0, 30.0, 800.0, 1.0, 1.0);
        assert_eq!(e.verts, 4, "far: thin only");
        assert_eq!(p.out_uv[0], 0.0);
        let far_w = p.out_pos[2] - p.out_pos[0];
        p.emit_word(&mut e, 0, 400.0, 400.0, 30.0, 2.0, 800.0, 1.0, 1.0);
        assert_eq!(e.verts, 12, "near: outline + fill");
        let near_w = p.out_pos[9 * 2] - p.out_pos[8 * 2];
        assert!(near_w > far_w);
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
    fn pick_returns_card_under_pointer() {
        let mut p = make(30, 0, 0);
        p.set_mode(MODE_INTERACTIVE, -1);
        p.frame(0.0, 0.0, 800.0, 600.0);
        let q = (0..30)
            .find_map(|i| p.pick_quads[i].map(|(q, _)| q))
            .unwrap();
        let cx = (q[0] + q[2] + q[4] + q[6]) / 4.0;
        let cy = (q[1] + q[3] + q[5] + q[7]) / 4.0;
        assert!(p.pick(cx, cy) >= 0);
        assert_eq!(p.pick(-100.0, -100.0), -1);
    }

    #[test]
    fn target_words_stay_on_the_sphere_while_the_cover_flies_in() {
        let p = make(40, 5, 0);
        let mut f = frame_at(1.0, 0.0);
        f.target = Some(3);
        f.fly = 1.0;
        f.fly_to = V3(0.0, 0.0, -3.0);
        let base = p.work_pose(3, &f);
        assert!(close(p.fly_pose(base, &f).center, f.fly_to));
        for w in 0..p.words.len() {
            if p.words[w].owner == Some(3) {
                let wp = p.word_pos(w, &f, Some(&base));
                assert!(wp.len() > SPHERE_RADIUS * 0.7);
            }
        }
    }

    /// 大库一帧的耗时上限（release 下 400 部作品 + 1.38 万词应远低于 6 ms；debug 放宽）。
    #[test]
    fn big_library_frame_budget() {
        let mut p = make(400, 30, 1800);
        p.set_mode(MODE_CINEMATIC, 5);
        let start = std::time::Instant::now();
        let mut t = 0.0;
        let mut frames = 0;
        let mut max_verts = 0;
        while t < CINEMATIC_SECONDS {
            p.frame(t, 1.0 / 60.0, 1920.0, 1080.0);
            max_verts = max_verts.max(p.verts);
            t += 0.25;
            frames += 1;
        }
        let per = start.elapsed().as_secs_f64() * 1000.0 / frames as f64;
        let limit = if cfg!(debug_assertions) { 200.0 } else { 6.0 };
        assert!(per < limit, "per frame {per:.2} ms");
        eprintln!("pano frame: {per:.3} ms (max {max_verts} verts)");
    }
}
