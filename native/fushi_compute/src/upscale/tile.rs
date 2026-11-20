//! 分块推理：整页切成固定大小的块，每块四周带上下文（边界反射填充）送进超分网络，只取中心有效区。
//!
//! **块的输入形状恒定**（`tile + 2 * pad` 再按网络对齐取整）：边缘块不足的部分同样反射填充。这样
//! 一页的输出与「这页在哪个尺寸的块里」无关，DirectML 也只编译一种形状。
//!
//! 接缝：waifu2x 的 swin_unet 里有全局池化一类的算子，输出对块的取法不是严格不变的（上下文从 16 加到
//! 128 都消不掉点状差异），但**交界处的台阶**取决于块大小：实测（设计文档 §4.2）块 256 / 上下文 64 时
//! 交界一像素跳变是非交界列的 10 倍（可见接缝），块 384 / 上下文 64 时与非交界列持平。所以块尺寸与上下文
//! 按模型给（[TileSpec]），回归测试见本文件的 `tests` 与 `super::tests::real_model_*`。

/// 超分网络：平面 f32（`channels × h × w`，0..1）进，平面 f32 出。
pub(crate) trait SrNet {
    /// 网络吃的通道数（1 = 亮度，3 = RGB）。
    fn channels(&self) -> usize;
    /// 放大倍数。
    fn scale(&self) -> usize;
    /// 输出每边比 `scale × 输入` 少掉的像素（waifu2x 的模型会裁边）。
    fn offset(&self) -> usize;
    /// 输入宽高须是它的倍数。
    fn align(&self) -> usize;
    /// 推理一块：返回 `(数据, 输出高, 输出宽)`。
    fn infer(&mut self, input: &[f32], h: usize, w: usize) -> Result<(Vec<f32>, usize, usize), String>;
}

/// 分块参数（输入像素）。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct TileSpec {
    /// 每块的有效区边长。
    pub tile: usize,
    /// 有效区四周额外带上的上下文。
    pub ctx: usize,
}

/// 反射下标（不重复边缘像素）：`-1 → 1`、`n → n - 2`；`n == 1` 恒为 0。
fn reflect(i: isize, n: usize) -> usize {
    if n == 1 {
        return 0;
    }
    let period = 2 * (n as isize - 1);
    let mut m = i.rem_euclid(period);
    if m >= n as isize {
        m = period - m;
    }
    m as usize
}

/// 一块的输入边长（有效区 + 两侧填充，按对齐取整）与填充量。
pub(crate) fn tile_geometry(net: &dyn SrNet, spec: TileSpec) -> (usize, usize) {
    let s = net.scale();
    let pad = spec.ctx + net.offset().div_ceil(s);
    let a = net.align().max(1);
    let size = (spec.tile + 2 * pad).div_ceil(a) * a;
    (size, pad)
}

/// 把 `img`（`c × h × w` 平面，`c` 须等于网络通道数）放大 `scale` 倍。`want` 给出时只算与它相交的块
/// （输入像素矩形 `[x0, y0, x1, y1)`），其余块输出保持 0——给「只在文字框附近跑文字模型」用。
pub(crate) fn upscale_tiled(
    net: &mut dyn SrNet,
    img: &[f32],
    h: usize,
    w: usize,
    spec: TileSpec,
    want: Option<&[[usize; 4]]>,
) -> Result<Vec<f32>, String> {
    let c = net.channels();
    if img.len() != c * h * w || h == 0 || w == 0 || spec.tile == 0 {
        return Err("bad tile input".into());
    }
    let s = net.scale();
    let off = net.offset();
    let (size, pad) = tile_geometry(net, spec);
    let (oh, ow) = (h * s, w * s);
    let mut out = vec![0f32; c * oh * ow];
    let mut patch = vec![0f32; c * size * size];
    for ty in (0..h).step_by(spec.tile) {
        for tx in (0..w).step_by(spec.tile) {
            let th = spec.tile.min(h - ty);
            let tw = spec.tile.min(w - tx);
            if let Some(rects) = want {
                let hit = rects
                    .iter()
                    .any(|r| r[0] < tx + tw && r[2] > tx && r[1] < ty + th && r[3] > ty);
                if !hit {
                    continue;
                }
            }
            let y0 = ty as isize - pad as isize;
            let x0 = tx as isize - pad as isize;
            for ch in 0..c {
                let plane = &img[ch * h * w..(ch + 1) * h * w];
                let dst = &mut patch[ch * size * size..(ch + 1) * size * size];
                for py in 0..size {
                    let sy = reflect(y0 + py as isize, h);
                    let row = &plane[sy * w..(sy + 1) * w];
                    for px in 0..size {
                        dst[py * size + px] = row[reflect(x0 + px as isize, w)];
                    }
                }
            }
            let (res, rh, rw) = net.infer(&patch, size, size)?;
            if res.len() != c * rh * rw || rh + 2 * off != size * s || rw + 2 * off != size * s {
                return Err(format!("unexpected output {rh}x{rw} for input {size}"));
            }
            // 输出坐标 = 输入坐标 × s − off；有效区从 pad × s − off 开始。
            let o = pad * s - off;
            for ch in 0..c {
                let src = &res[ch * rh * rw..(ch + 1) * rh * rw];
                let dst = &mut out[ch * oh * ow..(ch + 1) * oh * ow];
                for yy in 0..th * s {
                    let srow = (o + yy) * rw + o;
                    let drow = (ty * s + yy) * ow + tx * s;
                    dst[drow..drow + tw * s].copy_from_slice(&src[srow..srow + tw * s]);
                }
            }
        }
    }
    Ok(out)
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;

    /// 测试网络：2 倍最近邻放大后做半径 `r`（输出像素）的盒式模糊，感受野有限；可选「全局池化」
    /// （输出加上整块均值 × k），模拟 swin_unet 那种与取块方式有关的算子。
    pub(crate) struct MockNet {
        pub r: usize,
        pub global: f32,
        pub off: usize,
        pub align: usize,
        pub calls: usize,
    }

    impl SrNet for MockNet {
        fn channels(&self) -> usize {
            1
        }
        fn scale(&self) -> usize {
            2
        }
        fn offset(&self) -> usize {
            self.off
        }
        fn align(&self) -> usize {
            self.align
        }
        fn infer(&mut self, x: &[f32], h: usize, w: usize) -> Result<(Vec<f32>, usize, usize), String> {
            self.calls += 1;
            let (uh, uw) = (2 * h, 2 * w);
            let up: Vec<f32> = (0..uh * uw).map(|i| x[(i / uw / 2) * w + (i % uw) / 2]).collect();
            let mean = x.iter().sum::<f32>() / x.len() as f32;
            let r = self.r as isize;
            let mut out = vec![0f32; uh * uw];
            for y in 0..uh as isize {
                for xx in 0..uw as isize {
                    let (mut acc, mut n) = (0f32, 0f32);
                    for dy in -r..=r {
                        for dx in -r..=r {
                            let (yy, xq) = (y + dy, xx + dx);
                            if yy >= 0 && yy < uh as isize && xq >= 0 && xq < uw as isize {
                                acc += up[yy as usize * uw + xq as usize];
                                n += 1.0;
                            }
                        }
                    }
                    out[y as usize * uw + xx as usize] = acc / n + mean * self.global;
                }
            }
            let o = self.off;
            let (rh, rw) = (uh - 2 * o, uw - 2 * o);
            let cropped: Vec<f32> = (0..rh * rw).map(|i| out[(i / rw + o) * uw + i % rw + o]).collect();
            Ok((cropped, rh, rw))
        }
    }

    fn page(h: usize, w: usize) -> Vec<f32> {
        (0..h * w)
            .map(|i| {
                let (y, x) = (i / w, i % w);
                (((x * 7 + y * 13) % 17) as f32 / 16.0 + if (x / 5 + y / 3) % 2 == 0 { 0.3 } else { 0.0 }).min(1.0)
            })
            .collect()
    }

    #[test]
    fn reflect_mirrors_without_repeating_the_edge() {
        let got: Vec<usize> = (-3..7).map(|i| reflect(i, 4)).collect();
        assert_eq!(got, vec![3, 2, 1, 0, 1, 2, 3, 2, 1, 0]);
        assert_eq!(reflect(-5, 1), 0);
    }

    /// 接缝回归：感受野在上下文之内时，分块结果与整张推理逐像素一致（交界没有台阶），且与块大小无关。
    #[test]
    fn tiles_with_enough_context_have_no_seams() {
        let (h, w) = (70usize, 53usize);
        let img = page(h, w);
        let mut whole_net = MockNet { r: 6, global: 0.0, off: 2, align: 4, calls: 0 };
        let whole = upscale_tiled(&mut whole_net, &img, h, w, TileSpec { tile: 256, ctx: 8 }, None).unwrap();
        for tile in [16usize, 24, 31] {
            let mut net = MockNet { r: 6, global: 0.0, off: 2, align: 4, calls: 0 };
            let tiled = upscale_tiled(&mut net, &img, h, w, TileSpec { tile, ctx: 8 }, None).unwrap();
            let max = whole.iter().zip(&tiled).map(|(a, b)| (a - b).abs()).fold(0f32, f32::max);
            assert!(max < 1e-5, "tile {tile}: max diff {max}");
            assert!(net.calls > 1);
        }
        // 对照：上下文不够（感受野 6 输出像素 = 3 输入像素 > 上下文 1 + 裁边 1）就会在交界出台阶。
        let mut short = MockNet { r: 6, global: 0.0, off: 2, align: 4, calls: 0 };
        let tiled = upscale_tiled(&mut short, &img, h, w, TileSpec { tile: 16, ctx: 1 }, None).unwrap();
        let max = whole.iter().zip(&tiled).map(|(a, b)| (a - b).abs()).fold(0f32, f32::max);
        assert!(max > 1e-3, "short context should show seams, got {max}");
    }

    #[test]
    fn want_limits_inference_to_intersecting_tiles() {
        let (h, w) = (64usize, 64usize);
        let img = page(h, w);
        let mut net = MockNet { r: 2, global: 0.0, off: 0, align: 1, calls: 0 };
        let out = upscale_tiled(&mut net, &img, h, w, TileSpec { tile: 16, ctx: 4 }, Some(&[[20, 20, 30, 30]])).unwrap();
        assert_eq!(net.calls, 1);
        let ow = 2 * w;
        assert!(out[50 * ow + 50] > 0.0);
        assert_eq!(out[5 * ow + 5], 0.0);
    }

    #[test]
    fn rejects_mismatched_input() {
        let mut net = MockNet { r: 1, global: 0.0, off: 0, align: 1, calls: 0 };
        assert!(upscale_tiled(&mut net, &[0.0; 10], 3, 3, TileSpec { tile: 4, ctx: 1 }, None).is_err());
    }
}
