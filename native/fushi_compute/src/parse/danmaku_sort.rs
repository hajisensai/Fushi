//! Dart `List.sort` 的逐步复刻：`dart:_internal` `Sort`（Dart SDK 3.47.6
//! `lib/internal/sort.dart`，插入排序阈值 32 + Yaroslavskiy 双枢轴快排）。
//!
//! 它**不稳定**：同键元素的最终先后由算法每一步的交换决定。弹幕按 `startMs` 排序、
//! 同一毫秒的弹幕很常见，要与旧 Dart 实现逐条一致就只能把同一个算法、同一个比较函数
//! 原样搬过来，不能换成 `sort_by_key`（稳定）或 `sort_unstable_by_key`（另一种不稳定）。
//! 变量名、分支顺序与 SDK 源码一一对应，改动前先对照源码。

use std::cmp::Ordering;

const INSERTION_SORT_THRESHOLD: isize = 32;

/// 原地排序 [a]，[compare] 返回 Dart `compareTo` 语义的 [Ordering]。
pub fn dart_sort<T: Copy, F: Fn(&T, &T) -> Ordering>(a: &mut [T], compare: &F) {
    if a.is_empty() {
        return;
    }
    do_sort(a, 0, a.len() as isize - 1, compare);
}

/// `compare(x, y)` 的 Dart 整数结果（-1 / 0 / 1）。
#[inline]
fn cmp<T, F: Fn(&T, &T) -> Ordering>(compare: &F, x: &T, y: &T) -> i32 {
    match compare(x, y) {
        Ordering::Less => -1,
        Ordering::Equal => 0,
        Ordering::Greater => 1,
    }
}

fn do_sort<T: Copy, F: Fn(&T, &T) -> Ordering>(
    a: &mut [T],
    left: isize,
    right: isize,
    compare: &F,
) {
    if right - left <= INSERTION_SORT_THRESHOLD {
        insertion_sort(a, left, right, compare);
    } else {
        dual_pivot_quicksort(a, left, right, compare);
    }
}

fn insertion_sort<T: Copy, F: Fn(&T, &T) -> Ordering>(
    a: &mut [T],
    left: isize,
    right: isize,
    compare: &F,
) {
    let mut i = left + 1;
    while i <= right {
        let el = a[i as usize];
        let mut j = i;
        while j > left && cmp(compare, &a[(j - 1) as usize], &el) > 0 {
            a[j as usize] = a[(j - 1) as usize];
            j -= 1;
        }
        a[j as usize] = el;
        i += 1;
    }
}

#[allow(clippy::cognitive_complexity)]
fn dual_pivot_quicksort<T: Copy, F: Fn(&T, &T) -> Ordering>(
    a: &mut [T],
    left: isize,
    right: isize,
    compare: &F,
) {
    debug_assert!(right - left > INSERTION_SORT_THRESHOLD);
    macro_rules! at {
        ($i:expr) => {
            a[($i) as usize]
        };
    }

    let sixth = (right - left + 1) / 6;
    let index1 = left + sixth;
    let index5 = right - sixth;
    let index3 = (left + right) / 2; // 两端非负，`~/` 与 `/` 相同。
    let index2 = index3 - sixth;
    let index4 = index3 + sixth;

    let mut el1 = at!(index1);
    let mut el2 = at!(index2);
    let mut el3 = at!(index3);
    let mut el4 = at!(index4);
    let mut el5 = at!(index5);

    if cmp(compare, &el1, &el2) > 0 {
        std::mem::swap(&mut el1, &mut el2);
    }
    if cmp(compare, &el4, &el5) > 0 {
        std::mem::swap(&mut el4, &mut el5);
    }
    if cmp(compare, &el1, &el3) > 0 {
        std::mem::swap(&mut el1, &mut el3);
    }
    if cmp(compare, &el2, &el3) > 0 {
        std::mem::swap(&mut el2, &mut el3);
    }
    if cmp(compare, &el1, &el4) > 0 {
        std::mem::swap(&mut el1, &mut el4);
    }
    if cmp(compare, &el3, &el4) > 0 {
        std::mem::swap(&mut el3, &mut el4);
    }
    if cmp(compare, &el2, &el5) > 0 {
        std::mem::swap(&mut el2, &mut el5);
    }
    if cmp(compare, &el2, &el3) > 0 {
        std::mem::swap(&mut el2, &mut el3);
    }
    if cmp(compare, &el4, &el5) > 0 {
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

    let pivots_are_equal = cmp(compare, &pivot1, &pivot2) == 0;
    if pivots_are_equal {
        let pivot = pivot1;
        let mut k = less;
        while k <= great {
            let ak = at!(k);
            let mut comp = cmp(compare, &ak, &pivot);
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
                    comp = cmp(compare, &at!(great), &pivot);
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
            let comp_pivot1 = cmp(compare, &ak, &pivot1);
            if comp_pivot1 < 0 {
                if k != less {
                    at!(k) = at!(less);
                    at!(less) = ak;
                }
                less += 1;
            } else {
                let comp_pivot2 = cmp(compare, &ak, &pivot2);
                if comp_pivot2 > 0 {
                    loop {
                        let mut comp = cmp(compare, &at!(great), &pivot2);
                        if comp > 0 {
                            great -= 1;
                            if great < k {
                                break;
                            }
                            continue;
                        } else {
                            comp = cmp(compare, &at!(great), &pivot1);
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
        while cmp(compare, &at!(less), &pivot1) == 0 {
            less += 1;
        }
        while cmp(compare, &at!(great), &pivot2) == 0 {
            great -= 1;
        }

        let mut k = less;
        while k <= great {
            let ak = at!(k);
            let comp_pivot1 = cmp(compare, &ak, &pivot1);
            if comp_pivot1 == 0 {
                if k != less {
                    at!(k) = at!(less);
                    at!(less) = ak;
                }
                less += 1;
            } else {
                let comp_pivot2 = cmp(compare, &ak, &pivot2);
                if comp_pivot2 == 0 {
                    loop {
                        let mut comp = cmp(compare, &at!(great), &pivot2);
                        if comp == 0 {
                            great -= 1;
                            if great < k {
                                break;
                            }
                            continue;
                        } else {
                            comp = cmp(compare, &at!(great), &pivot1);
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sorts_by_key() {
        let mut v: Vec<(i32, u32)> = (0..500u32).map(|i| (((i * 7919) % 37) as i32, i)).collect();
        dart_sort(&mut v, &|a: &(i32, u32), b: &(i32, u32)| a.0.cmp(&b.0));
        assert!(v.windows(2).all(|w| w[0].0 <= w[1].0));
        let mut ids: Vec<u32> = v.iter().map(|e| e.1).collect();
        ids.sort_unstable();
        assert_eq!(ids, (0..500).collect::<Vec<_>>());
    }
}
