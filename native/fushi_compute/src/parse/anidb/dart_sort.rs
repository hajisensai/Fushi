//! Dart `List.sort`（`dart:_internal` 的 `Sort`：≤32 个元素插入排序，否则双轴快排）的
//! 逐步复刻。
//!
//! 它**不稳定**：比较器打平的元素最终顺序取决于算法本身。AniDB 索引里有两处靠它定序
//! （按归一化标题排的前缀表、按 n-gram 命中数排的模糊候选；后者再 `take(20000)` 截断），
//! 换成 Rust 的 `sort_by` 会让打平元素换位，进而换掉最终选中的标题，所以必须照抄。

/// `Sort.sort(a, compare)`；`compare` 返回值只看正负零（同 Dart）。
pub fn dart_sort<T: Copy>(a: &mut [T], compare: &mut impl FnMut(T, T) -> i32) {
    if a.is_empty() {
        return;
    }
    do_sort(a, 0, a.len() as isize - 1, compare);
}

const INSERTION_SORT_THRESHOLD: isize = 32;

fn do_sort<T: Copy>(a: &mut [T], left: isize, right: isize, compare: &mut impl FnMut(T, T) -> i32) {
    if right - left <= INSERTION_SORT_THRESHOLD {
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

fn dual_pivot_quicksort<T: Copy>(
    a: &mut [T],
    left: isize,
    right: isize,
    compare: &mut impl FnMut(T, T) -> i32,
) {
    macro_rules! g {
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

    let mut el1 = g!(index1);
    let mut el2 = g!(index2);
    let mut el3 = g!(index3);
    let mut el4 = g!(index4);
    let mut el5 = g!(index5);

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

    g!(index1) = el1;
    g!(index3) = el3;
    g!(index5) = el5;

    g!(index2) = g!(left);
    g!(index4) = g!(right);

    let mut less = left + 1;
    let mut great = right - 1;

    let pivots_are_equal = compare(pivot1, pivot2) == 0;
    if pivots_are_equal {
        let pivot = pivot1;
        let mut k = less;
        while k <= great {
            let ak = g!(k);
            let mut comp = compare(ak, pivot);
            if comp == 0 {
                k += 1;
                continue;
            }
            if comp < 0 {
                if k != less {
                    g!(k) = g!(less);
                    g!(less) = ak;
                }
                less += 1;
            } else {
                loop {
                    comp = compare(g!(great), pivot);
                    if comp > 0 {
                        great -= 1;
                        continue;
                    } else if comp < 0 {
                        g!(k) = g!(less);
                        g!(less) = g!(great);
                        less += 1;
                        g!(great) = ak;
                        great -= 1;
                        break;
                    } else {
                        g!(k) = g!(great);
                        g!(great) = ak;
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
            let ak = g!(k);
            let comp_pivot1 = compare(ak, pivot1);
            if comp_pivot1 < 0 {
                if k != less {
                    g!(k) = g!(less);
                    g!(less) = ak;
                }
                less += 1;
            } else {
                let comp_pivot2 = compare(ak, pivot2);
                if comp_pivot2 > 0 {
                    loop {
                        let mut comp = compare(g!(great), pivot2);
                        if comp > 0 {
                            great -= 1;
                            if great < k {
                                break;
                            }
                            continue;
                        } else {
                            comp = compare(g!(great), pivot1);
                            if comp < 0 {
                                g!(k) = g!(less);
                                g!(less) = g!(great);
                                less += 1;
                                g!(great) = ak;
                                great -= 1;
                            } else {
                                g!(k) = g!(great);
                                g!(great) = ak;
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

    g!(left) = g!(less - 1);
    g!(less - 1) = pivot1;
    g!(right) = g!(great + 1);
    g!(great + 1) = pivot2;

    do_sort(a, left, less - 2, compare);
    do_sort(a, great + 2, right, compare);

    if pivots_are_equal {
        return;
    }

    if less < index1 && great > index5 {
        while compare(g!(less), pivot1) == 0 {
            less += 1;
        }
        while compare(g!(great), pivot2) == 0 {
            great -= 1;
        }
        let mut k = less;
        while k <= great {
            let ak = g!(k);
            let comp_pivot1 = compare(ak, pivot1);
            if comp_pivot1 == 0 {
                if k != less {
                    g!(k) = g!(less);
                    g!(less) = ak;
                }
                less += 1;
            } else {
                let comp_pivot2 = compare(ak, pivot2);
                if comp_pivot2 == 0 {
                    loop {
                        let mut comp = compare(g!(great), pivot2);
                        if comp == 0 {
                            great -= 1;
                            if great < k {
                                break;
                            }
                            continue;
                        } else {
                            comp = compare(g!(great), pivot1);
                            if comp < 0 {
                                g!(k) = g!(less);
                                g!(less) = g!(great);
                                less += 1;
                                g!(great) = ak;
                                great -= 1;
                            } else {
                                g!(k) = g!(great);
                                g!(great) = ak;
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn matches_dart_vm_unstable_order() {
        // 期望值由 Dart VM 生成：同一 LCG 序列 `List<int>.sort((a, b) =>
        // (a ~/ 10).compareTo(b ~/ 10))` 后的逐元素 FNV-1a（打平元素的相对顺序取决于算法）。
        for &(n, expected) in &[
            (20usize, 0x56263809u32),
            (33, 0x81c402e2),
            (34, 0x32c000b1),
            (500, 0xecf67026),
            (5000, 0xfc3fc304),
        ] {
            let mut seed: u64 = 7;
            let mut v: Vec<i64> = (0..n)
                .map(|_| {
                    seed = seed
                        .wrapping_mul(6364136223846793005)
                        .wrapping_add(1442695040888963407);
                    ((seed >> 33) % 1000) as i64
                })
                .collect();
            dart_sort(&mut v, &mut |a: i64, b: i64| (a / 10).cmp(&(b / 10)) as i32);
            let mut h: u32 = 0x811c9dc5;
            for &x in &v {
                h ^= (x & 0xffff) as u32;
                h = h.wrapping_mul(0x01000193);
            }
            assert_eq!(h, expected, "n={n}");
        }
    }
}
