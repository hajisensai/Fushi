//! 二维码**定位图形**检测（只判「有没有一组三个定位图形」，不解码码内容）。
//!
//! 逐行移植自已删除的 Dart 实现 `web_comic_ad_filter.dart` 的 `containsQrFinderPatterns`：
//! Otsu 二值化 → 每行找 1:1:3:1:1 的黑白游程 → 竖直方向复核 → 候选聚类 → 取命中最多的
//! 前 12 个，看有没有三个中心构成等腰直角三角形。浮点运算顺序与 Dart 保持一致，
//! 排序用 Dart 的不稳定排序（见 `dart_sort`），回归向量逐张对得上。

use super::dart_sort::dart_sort;

/// 灰度图 `gray`（宽 `width`、高 `height`）里有没有一组二维码定位图形。
pub fn contains_qr_finder_patterns(gray: &[u8], width: usize, height: usize) -> bool {
    if gray.len() != width * height || width < 21 || height < 21 {
        return false;
    }
    let threshold = otsu_threshold(gray);
    let dark: Vec<u8> = gray
        .iter()
        .map(|&v| u8::from((v as i32) < threshold))
        .collect();

    let mut clusters: Vec<FinderCluster> = Vec::new();
    let mut run_lengths: Vec<usize> = Vec::with_capacity(64);
    let mut run_starts: Vec<usize> = Vec::with_capacity(64);
    let mut run_colors: Vec<u8> = Vec::with_capacity(64);
    for y in 0..height {
        run_lengths.clear();
        run_starts.clear();
        run_colors.clear();
        let row = &dark[y * width..(y + 1) * width];
        let mut start = 0usize;
        for x in 1..=width {
            if x == width || row[x] != row[start] {
                run_lengths.push(x - start);
                run_starts.push(start);
                run_colors.push(row[start]);
                start = x;
            }
        }
        if run_lengths.len() < 5 {
            continue;
        }
        for r in 0..run_lengths.len() - 4 {
            if run_colors[r] != 1 {
                continue;
            }
            let counts = &run_lengths[r..r + 5];
            if !finder_ratio(counts) {
                continue;
            }
            let h_total: usize = counts.iter().sum();
            let cx = run_starts[r + 2] as f64 + run_lengths[r + 2] as f64 / 2.0;
            let Some((v_center, v_total)) =
                cross_check_vertical(&dark, width, height, cx.floor() as usize, y, h_total)
            else {
                continue;
            };
            add_candidate(
                &mut clusters,
                cx,
                v_center,
                (h_total + v_total) as f64 / 14.0,
            );
        }
    }

    let mut confirmed: Vec<FinderCluster> = clusters.into_iter().filter(|c| c.hits >= 2).collect();
    dart_sort(&mut confirmed, |a, b| b.hits.cmp(&a.hits));
    let top = if confirmed.len() > 12 {
        &confirmed[..12]
    } else {
        &confirmed[..]
    };
    for a in 0..top.len() {
        for b in a + 1..top.len() {
            for c in b + 1..top.len() {
                if forms_qr_triangle(&top[a], &top[b], &top[c]) {
                    return true;
                }
            }
        }
    }
    false
}

/// 1:1:3:1:1（每格允许半个模块的误差，中间那格 1.5 个模块）。
fn finder_ratio(counts: &[usize]) -> bool {
    let mut total = 0usize;
    for &count in counts {
        if count == 0 {
            return false;
        }
        total += count;
    }
    if total < 7 {
        return false;
    }
    let module = total as f64 / 7.0;
    let variance = module / 2.0;
    (counts[0] as f64 - module).abs() < variance
        && (counts[1] as f64 - module).abs() < variance
        && (counts[2] as f64 - 3.0 * module).abs() < 3.0 * variance
        && (counts[3] as f64 - module).abs() < variance
        && (counts[4] as f64 - module).abs() < variance
}

/// 在第 `x` 列从 `y` 起上下各走一遍，确认竖直方向也是 1:1:3:1:1；返回竖直中心与总长。
fn cross_check_vertical(
    dark: &[u8],
    width: usize,
    height: usize,
    x: usize,
    y: usize,
    h_total: usize,
) -> Option<(f64, usize)> {
    let is_dark = |yy: isize| dark[yy as usize * width + x] == 1;
    let y = y as isize;
    let height = height as isize;
    if !is_dark(y) {
        return None;
    }
    let mut counts = [0usize; 5];
    let mut yy = y;
    while yy >= 0 && is_dark(yy) {
        counts[2] += 1;
        yy -= 1;
    }
    while yy >= 0 && !is_dark(yy) {
        counts[1] += 1;
        yy -= 1;
    }
    while yy >= 0 && is_dark(yy) {
        counts[0] += 1;
        yy -= 1;
    }
    if counts[1] == 0 || counts[0] == 0 {
        return None;
    }
    yy = y + 1;
    let mut center_bottom = y;
    while yy < height && is_dark(yy) {
        counts[2] += 1;
        center_bottom = yy;
        yy += 1;
    }
    while yy < height && !is_dark(yy) {
        counts[3] += 1;
        yy += 1;
    }
    while yy < height && is_dark(yy) {
        counts[4] += 1;
        yy += 1;
    }
    if counts[3] == 0 || counts[4] == 0 {
        return None;
    }
    if !finder_ratio(&counts) {
        return None;
    }
    let v_total: usize = counts.iter().sum();
    if 5 * (v_total as isize - h_total as isize).unsigned_abs() >= 2 * h_total {
        return None;
    }
    let center_top = center_bottom - counts[2] as isize + 1;
    Some(((center_top + center_bottom) as f64 / 2.0, v_total))
}

#[derive(Clone, Debug)]
struct FinderCluster {
    x: f64,
    y: f64,
    module: f64,
    hits: i64,
}

fn add_candidate(clusters: &mut Vec<FinderCluster>, x: f64, y: f64, module: f64) {
    for cluster in clusters.iter_mut() {
        let tolerance = cluster.module.max(module) * 2.0;
        if (cluster.x - x).abs() <= tolerance
            && (cluster.y - y).abs() <= tolerance
            && (cluster.module - module).abs() <= cluster.module.max(module)
        {
            let n = cluster.hits as f64;
            cluster.x = (cluster.x * n + x) / (n + 1.0);
            cluster.y = (cluster.y * n + y) / (n + 1.0);
            cluster.module = (cluster.module * n + module) / (n + 1.0);
            cluster.hits += 1;
            return;
        }
    }
    clusters.push(FinderCluster {
        x,
        y,
        module,
        hits: 1,
    });
}

/// 三个定位图形：模块尺寸相近，中心呈等腰直角三角形，腰长 12..=200 个模块。
fn forms_qr_triangle(a: &FinderCluster, b: &FinderCluster, c: &FinderCluster) -> bool {
    let min_module = a.module.min(b.module.min(c.module));
    let max_module = a.module.max(b.module.max(c.module));
    if min_module <= 0.0 || max_module / min_module > 1.5 {
        return false;
    }
    let dist =
        |p: &FinderCluster, q: &FinderCluster| ((p.x - q.x).powi(2) + (p.y - q.y).powi(2)).sqrt();
    let mut sides = [dist(a, b), dist(b, c), dist(a, c)];
    // Dart 对三个元素用插入排序；三元素的结果与任何正确排序相同。
    sides.sort_by(|p, q| p.partial_cmp(q).unwrap_or(std::cmp::Ordering::Equal));
    let leg1 = sides[0];
    let leg2 = sides[1];
    let hypotenuse = sides[2];
    if leg1 <= 0.0 || leg1 / leg2 < 0.8 {
        return false;
    }
    let expected = (leg1 * leg1 + leg2 * leg2).sqrt();
    if (hypotenuse - expected).abs() / hypotenuse > 0.12 {
        return false;
    }
    let module = (a.module + b.module + c.module) / 3.0;
    let leg_modules = leg1 / module;
    (12.0..=200.0).contains(&leg_modules)
}

/// Otsu 阈值（返回 `t + 1`：像素 `< 阈值` 为黑）。
fn otsu_threshold(gray: &[u8]) -> i32 {
    let mut histogram = [0i64; 256];
    for &value in gray {
        histogram[value as usize] += 1;
    }
    let total = gray.len() as i64;
    let mut sum = 0.0f64;
    for (i, &h) in histogram.iter().enumerate() {
        sum += (i as i64 * h) as f64;
    }
    let mut sum_background = 0.0f64;
    let mut weight_background = 0i64;
    let mut best_variance = -1.0f64;
    let mut best = 128i32;
    for (t, &count) in histogram.iter().enumerate() {
        weight_background += count;
        if weight_background == 0 {
            continue;
        }
        let weight_foreground = total - weight_background;
        if weight_foreground == 0 {
            break;
        }
        sum_background += (t as i64 * count) as f64;
        let mean_background = sum_background / weight_background as f64;
        let mean_foreground = (sum - sum_background) / weight_foreground as f64;
        let between = (weight_background * weight_foreground) as f64
            * (mean_background - mean_foreground).powi(2);
        if between > best_variance {
            best_variance = between;
            best = t as i32 + 1;
        }
    }
    best
}
