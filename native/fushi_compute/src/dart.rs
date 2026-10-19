//! Dart VM 数值语义的逐位复刻（迁过来的内核要与旧 Dart 实现逐位一致时用）。
//!
//! Rust 标准库的 `f64::max` / `min` / `clamp` / `sort_by` 在 NaN、`-0.0`、并列元素上的
//! 行为与 Dart 不同：
//! - `dart:math` 的 `max` / `min`（`sdk/lib/_internal/vm/lib/math_patch.dart`）：任一边 NaN 返回
//!   NaN，`max(-0.0, 0.0) == 0.0`、`min(0.0, -0.0) == -0.0`；
//! - `double.compareTo`（`_internal/vm/lib/double.dart`）：`-0.0 < 0.0`，NaN 比一切都大且等于自身；
//! - `num.clamp` 用 `compareTo` 判断，所以 `(-0.0).clamp(0.0, x) == 0.0`、`NaN.clamp(a, b) == b`；
//! - `List.sort` 是 `dart:_internal` 的 `Sort`（≤32 个元素插入排序，否则双枢轴快排）——
//!   **不稳定**，并列元素的去向由这套算法决定，按下标 / 对象排序时必须照搬它。
//!
//! 只对按值排序（排完只读值）的场合可以用任意正确排序 + [compare_f64]：值的排列唯一。

use std::cmp::Ordering;

/// `double.compareTo`。
#[inline]
pub fn compare_f64(a: f64, b: f64) -> i32 {
    if a < b {
        -1
    } else if a > b {
        1
    } else if a == b {
        if a == 0.0 {
            let (na, nb) = (a.is_sign_negative(), b.is_sign_negative());
            if na == nb {
                0
            } else if na {
                -1
            } else {
                1
            }
        } else {
            0
        }
    } else if a.is_nan() {
        if b.is_nan() {
            0
        } else {
            1
        }
    } else {
        -1
    }
}

/// `int.compareTo`。
#[inline]
pub fn compare_i64(a: i64, b: i64) -> i32 {
    match a.cmp(&b) {
        Ordering::Less => -1,
        Ordering::Equal => 0,
        Ordering::Greater => 1,
    }
}

/// `math.max<double>`。
#[inline]
pub fn max_f64(a: f64, b: f64) -> f64 {
    if a > b {
        return a;
    }
    if a < b {
        return b;
    }
    if a == 0.0 {
        // a 是 ±0，b 是 ±0 或 NaN。
        return a + b;
    }
    if b.is_nan() {
        return b;
    }
    a
}

/// `math.min<double>`。
#[inline]
pub fn min_f64(a: f64, b: f64) -> f64 {
    if a > b {
        return b;
    }
    if a < b {
        return a;
    }
    if a == 0.0 {
        return (a + b) * a * b;
    }
    if (a == 0.0 && b.is_sign_negative()) || b.is_nan() {
        return b;
    }
    a
}

/// `double.clamp(lower, upper)`（`lower`、`upper` 都是 double、`lower <= upper`、非 NaN）。
#[inline]
pub fn clamp_f64(v: f64, lower: f64, upper: f64) -> f64 {
    if compare_f64(v, lower) < 0 {
        return lower;
    }
    if compare_f64(v, upper) > 0 {
        return upper;
    }
    v
}

/// `double.toInt()`：截断，越界饱和到 i64（NaN / ±inf 由调用方先判，Dart 会抛）。
#[inline]
pub fn to_int(v: f64) -> i64 {
    v as i64
}

/// `double.round()`：四舍五入、.5 远离零（Dart 语义），越界饱和。
#[inline]
pub fn round(v: f64) -> i64 {
    v.round() as i64
}

const INSERTION_SORT_THRESHOLD: usize = 32;

/// `List.sort(compare)`（`dart:_internal` `Sort.sort`）的逐步复刻：同样的比较序列、同样的
/// 交换，所以并列元素落在与 Dart 相同的位置。
pub fn sort<T: Copy>(a: &mut [T], compare: &mut impl FnMut(T, T) -> i32) {
    if a.len() > 1 {
        do_sort(a, 0, a.len() as isize - 1, compare);
    }
}

fn do_sort<T: Copy>(a: &mut [T], left: isize, right: isize, compare: &mut impl FnMut(T, T) -> i32) {
    if right - left <= INSERTION_SORT_THRESHOLD as isize {
        insertion_sort(a, left, right, compare);
    } else {
        dual_pivot_quicksort(a, left, right, compare);
    }
}

fn insertion_sort<T: Copy>(
    a: &mut [T],
    left: isize,
    right: isize,
    compare: &mut impl FnMut(T, T) -> i32,
) {
    let mut i = left + 1;
    while i <= right {
        let el = a[i as usize];
        let mut j = i;
        while j > left && compare(a[(j - 1) as usize], el) > 0 {
            a[j as usize] = a[(j - 1) as usize];
            j -= 1;
        }
        a[j as usize] = el;
        i += 1;
    }
}

#[allow(clippy::cognitive_complexity)]
fn dual_pivot_quicksort<T: Copy>(
    a: &mut [T],
    left: isize,
    right: isize,
    compare: &mut impl FnMut(T, T) -> i32,
) {
    macro_rules! at {
        ($i:expr) => {
            a[($i) as usize]
        };
    }
    let sixth = (right - left + 1) / 6;
    let index1 = left + sixth;
    let index5 = right - sixth;
    let index3 = (left + right) / 2;
    let index2 = index3 - sixth;
    let index4 = index3 + sixth;

    let mut el1 = at!(index1);
    let mut el2 = at!(index2);
    let mut el3 = at!(index3);
    let mut el4 = at!(index4);
    let mut el5 = at!(index5);

    if compare(el1, el2) > 0 {
        std::mem::swap(&mut el1, &mut el2);
    }
    if compare(el4, el5) > 0 {
        std::mem::swap(&mut el4, &mut el5);
    }
    if compare(el1, el3) > 0 {
        std::mem::swap(&mut el1, &mut el3);
    }
    if compare(el2, el3) > 0 {
        std::mem::swap(&mut el2, &mut el3);
    }
    if compare(el1, el4) > 0 {
        std::mem::swap(&mut el1, &mut el4);
    }
    if compare(el3, el4) > 0 {
        std::mem::swap(&mut el3, &mut el4);
    }
    if compare(el2, el5) > 0 {
        std::mem::swap(&mut el2, &mut el5);
    }
    if compare(el2, el3) > 0 {
        std::mem::swap(&mut el2, &mut el3);
    }
    if compare(el4, el5) > 0 {
        std::mem::swap(&mut el4, &mut el5);
    }

    let pivot1 = el2;
    let pivot2 = el4;

    at!(index1) = el1;
    at!(index3) = el3;
    at!(index5) = el5;

    at!(index2) = at!(left);
    at!(index4) = at!(right);

    let mut less = left + 1;
    let mut great = right - 1;

    let pivots_are_equal = compare(pivot1, pivot2) == 0;
    if pivots_are_equal {
        let pivot = pivot1;
        let mut k = less;
        while k <= great {
            let ak = at!(k);
            let comp = compare(ak, pivot);
            if comp == 0 {
                k += 1;
                continue;
            }
            if comp < 0 {
                if k != less {
                    at!(k) = at!(less);
                    at!(less) = ak;
                }
                less += 1;
            } else {
                loop {
                    let comp = compare(at!(great), pivot);
                    if comp > 0 {
                        great -= 1;
                        continue;
                    } else if comp < 0 {
                        at!(k) = at!(less);
                        at!(less) = at!(great);
                        less += 1;
                        at!(great) = ak;
                        great -= 1;
                        break;
                    } else {
                        at!(k) = at!(great);
                        at!(great) = ak;
                        great -= 1;
                        break;
                    }
                }
            }
            k += 1;
        }
    } else {
        let mut k = less;
        while k <= great {
            let ak = at!(k);
            let comp_pivot1 = compare(ak, pivot1);
            if comp_pivot1 < 0 {
                if k != less {
                    at!(k) = at!(less);
                    at!(less) = ak;
                }
                less += 1;
            } else {
                let comp_pivot2 = compare(ak, pivot2);
                if comp_pivot2 > 0 {
                    loop {
                        let comp = compare(at!(great), pivot2);
                        if comp > 0 {
                            great -= 1;
                            if great < k {
                                break;
                            }
                            continue;
                        } else {
                            let comp = compare(at!(great), pivot1);
                            if comp < 0 {
                                at!(k) = at!(less);
                                at!(less) = at!(great);
                                less += 1;
                                at!(great) = ak;
                                great -= 1;
                            } else {
                                at!(k) = at!(great);
                                at!(great) = ak;
                                great -= 1;
                            }
                            break;
                        }
                    }
                }
            }
            k += 1;
        }
    }

    at!(left) = at!(less - 1);
    at!(less - 1) = pivot1;
    at!(right) = at!(great + 1);
    at!(great + 1) = pivot2;

    do_sort(a, left, less - 2, compare);
    do_sort(a, great + 2, right, compare);

    if pivots_are_equal {
        return;
    }

    if less < index1 && great > index5 {
        while compare(at!(less), pivot1) == 0 {
            less += 1;
        }
        while compare(at!(great), pivot2) == 0 {
            great -= 1;
        }
        let mut k = less;
        while k <= great {
            let ak = at!(k);
            let comp_pivot1 = compare(ak, pivot1);
            if comp_pivot1 == 0 {
                if k != less {
                    at!(k) = at!(less);
                    at!(less) = ak;
                }
                less += 1;
            } else {
                let comp_pivot2 = compare(ak, pivot2);
                if comp_pivot2 == 0 {
                    loop {
                        let comp = compare(at!(great), pivot2);
                        if comp == 0 {
                            great -= 1;
                            if great < k {
                                break;
                            }
                            continue;
                        } else {
                            let comp = compare(at!(great), pivot1);
                            if comp < 0 {
                                at!(k) = at!(less);
                                at!(less) = at!(great);
                                less += 1;
                                at!(great) = ak;
                                great -= 1;
                            } else {
                                at!(k) = at!(great);
                                at!(great) = ak;
                                great -= 1;
                            }
                            break;
                        }
                    }
                }
            }
            k += 1;
        }
        do_sort(a, less, great, compare);
    } else {
        do_sort(a, less, great, compare);
    }
}

/// 中位数（`values.sort()` 后取中间；偶数个取两中间的均值）。空表返回 NaN。
pub fn median(values: &mut [f64]) -> f64 {
    if values.is_empty() {
        return f64::NAN;
    }
    sort(values, &mut |a, b| compare_f64(a, b));
    let m = values.len() / 2;
    if values.len() % 2 == 1 {
        values[m]
    } else {
        (values[m - 1] + values[m]) / 2.0
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn max_min_follow_dart() {
        assert!(max_f64(f64::NAN, 1.0).is_nan());
        assert!(max_f64(1.0, f64::NAN).is_nan());
        assert!(max_f64(-0.0, 0.0).is_sign_positive());
        assert!(min_f64(0.0, -0.0).is_sign_negative());
        assert!(min_f64(1.0, f64::NAN).is_nan());
        assert_eq!(clamp_f64(-0.0, 0.0, 1.0).to_bits(), 0.0f64.to_bits());
        assert_eq!(clamp_f64(f64::NAN, 0.0, 1.0), 1.0);
    }

    #[test]
    fn sort_orders_like_any_correct_sort() {
        let mut rng = 12345u32;
        for n in [0usize, 1, 2, 5, 31, 33, 34, 100, 1000] {
            let mut v: Vec<i64> = (0..n)
                .map(|_| {
                    rng = rng.wrapping_mul(1664525).wrapping_add(1013904223);
                    (rng >> 20) as i64 % 17
                })
                .collect();
            let mut expect = v.clone();
            expect.sort();
            sort(&mut v, &mut |a, b| compare_i64(a, b));
            assert_eq!(v, expect);
        }
    }
}
