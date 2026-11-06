//! Dart VM `List.sort` 的逐行移植（`dart:_internal` 的 `Sort`：≤32 个元素插入排序，
//! 否则双轴快排）。
//!
//! 为什么不用 `sort_by`：定位图形候选按命中数排序后只取前 12 个，命中数相同的候选谁排在
//! 前面决定了取到哪 12 个。Dart 的快排**不稳定**，Rust 的 `sort_by` 稳定，候选超过 32 个
//! 时两边会取到不同的子集、结论可能不同。回归向量以 Dart 实现为准，所以排序也按 Dart 来。

use std::cmp::Ordering;

const INSERTION_SORT_THRESHOLD: isize = 32;

/// 与 Dart `list.sort(compare)` 完全相同的元素排列。
pub fn dart_sort<T: Clone, F: Fn(&T, &T) -> Ordering>(a: &mut [T], compare: F) {
    if a.len() < 2 {
        return;
    }
    let cmp = |x: &T, y: &T| -> i32 {
        match compare(x, y) {
            Ordering::Less => -1,
            Ordering::Equal => 0,
            Ordering::Greater => 1,
        }
    };
    do_sort(a, 0, a.len() as isize - 1, &cmp);
}

fn do_sort<T: Clone>(a: &mut [T], left: isize, right: isize, cmp: &dyn Fn(&T, &T) -> i32) {
    if right - left <= INSERTION_SORT_THRESHOLD {
        insertion_sort(a, left, right, cmp);
    } else {
        dual_pivot_quicksort(a, left, right, cmp);
    }
}

fn insertion_sort<T: Clone>(a: &mut [T], left: isize, right: isize, cmp: &dyn Fn(&T, &T) -> i32) {
    let mut i = left + 1;
    while i <= right {
        let el = a[i as usize].clone();
        let mut j = i;
        while j > left && cmp(&a[(j - 1) as usize], &el) > 0 {
            a[j as usize] = a[(j - 1) as usize].clone();
            j -= 1;
        }
        a[j as usize] = el;
        i += 1;
    }
}

#[allow(clippy::too_many_lines)]
fn dual_pivot_quicksort<T: Clone>(
    a: &mut [T],
    left: isize,
    right: isize,
    cmp: &dyn Fn(&T, &T) -> i32,
) {
    let at = |i: isize| i as usize;
    let sixth = (right - left + 1) / 6;
    let index1 = left + sixth;
    let index5 = right - sixth;
    let index3 = (left + right) / 2;
    let index2 = index3 - sixth;
    let index4 = index3 + sixth;

    let mut el1 = a[at(index1)].clone();
    let mut el2 = a[at(index2)].clone();
    let mut el3 = a[at(index3)].clone();
    let mut el4 = a[at(index4)].clone();
    let mut el5 = a[at(index5)].clone();

    if cmp(&el1, &el2) > 0 {
        std::mem::swap(&mut el1, &mut el2);
    }
    if cmp(&el4, &el5) > 0 {
        std::mem::swap(&mut el4, &mut el5);
    }
    if cmp(&el1, &el3) > 0 {
        std::mem::swap(&mut el1, &mut el3);
    }
    if cmp(&el2, &el3) > 0 {
        std::mem::swap(&mut el2, &mut el3);
    }
    if cmp(&el1, &el4) > 0 {
        std::mem::swap(&mut el1, &mut el4);
    }
    if cmp(&el3, &el4) > 0 {
        std::mem::swap(&mut el3, &mut el4);
    }
    if cmp(&el2, &el5) > 0 {
        std::mem::swap(&mut el2, &mut el5);
    }
    if cmp(&el2, &el3) > 0 {
        std::mem::swap(&mut el2, &mut el3);
    }
    if cmp(&el4, &el5) > 0 {
        std::mem::swap(&mut el4, &mut el5);
    }

    let pivot1 = el2;
    let pivot2 = el4;

    a[at(index1)] = el1;
    a[at(index3)] = el3;
    a[at(index5)] = el5;

    a[at(index2)] = a[at(left)].clone();
    a[at(index4)] = a[at(right)].clone();

    let mut less = left + 1;
    let mut great = right - 1;

    let pivots_are_equal = cmp(&pivot1, &pivot2) == 0;
    if pivots_are_equal {
        let pivot = pivot1.clone();
        let mut k = less;
        while k <= great {
            let ak = a[at(k)].clone();
            let comp = cmp(&ak, &pivot);
            if comp == 0 {
                k += 1;
                continue;
            }
            if comp < 0 {
                if k != less {
                    a[at(k)] = a[at(less)].clone();
                    a[at(less)] = ak;
                }
                less += 1;
            } else {
                loop {
                    let comp = cmp(&a[at(great)], &pivot);
                    if comp > 0 {
                        great -= 1;
                        continue;
                    } else if comp < 0 {
                        a[at(k)] = a[at(less)].clone();
                        a[at(less)] = a[at(great)].clone();
                        less += 1;
                        a[at(great)] = ak;
                        great -= 1;
                        break;
                    } else {
                        a[at(k)] = a[at(great)].clone();
                        a[at(great)] = ak;
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
            let ak = a[at(k)].clone();
            let comp_pivot1 = cmp(&ak, &pivot1);
            if comp_pivot1 < 0 {
                if k != less {
                    a[at(k)] = a[at(less)].clone();
                    a[at(less)] = ak;
                }
                less += 1;
            } else {
                let comp_pivot2 = cmp(&ak, &pivot2);
                if comp_pivot2 > 0 {
                    loop {
                        let comp = cmp(&a[at(great)], &pivot2);
                        if comp > 0 {
                            great -= 1;
                            if great < k {
                                break;
                            }
                            continue;
                        } else {
                            let comp = cmp(&a[at(great)], &pivot1);
                            if comp < 0 {
                                a[at(k)] = a[at(less)].clone();
                                a[at(less)] = a[at(great)].clone();
                                less += 1;
                                a[at(great)] = ak;
                                great -= 1;
                            } else {
                                a[at(k)] = a[at(great)].clone();
                                a[at(great)] = ak;
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

    a[at(left)] = a[at(less - 1)].clone();
    a[at(less - 1)] = pivot1.clone();
    a[at(right)] = a[at(great + 1)].clone();
    a[at(great + 1)] = pivot2.clone();

    do_sort(a, left, less - 2, cmp);
    do_sort(a, great + 2, right, cmp);

    if pivots_are_equal {
        return;
    }

    if less < index1 && great > index5 {
        while cmp(&a[at(less)], &pivot1) == 0 {
            less += 1;
        }
        while cmp(&a[at(great)], &pivot2) == 0 {
            great -= 1;
        }
        let mut k = less;
        while k <= great {
            let ak = a[at(k)].clone();
            let comp_pivot1 = cmp(&ak, &pivot1);
            if comp_pivot1 == 0 {
                if k != less {
                    a[at(k)] = a[at(less)].clone();
                    a[at(less)] = ak;
                }
                less += 1;
            } else {
                let comp_pivot2 = cmp(&ak, &pivot2);
                if comp_pivot2 == 0 {
                    loop {
                        let comp = cmp(&a[at(great)], &pivot2);
                        if comp == 0 {
                            great -= 1;
                            if great < k {
                                break;
                            }
                            continue;
                        } else {
                            let comp = cmp(&a[at(great)], &pivot1);
                            if comp < 0 {
                                a[at(k)] = a[at(less)].clone();
                                a[at(less)] = a[at(great)].clone();
                                less += 1;
                                a[at(great)] = ak;
                                great -= 1;
                            } else {
                                a[at(k)] = a[at(great)].clone();
                                a[at(great)] = ak;
                                great -= 1;
                            }
                            break;
                        }
                    }
                }
            }
            k += 1;
        }
        do_sort(a, less, great, cmp);
    } else {
        do_sort(a, less, great, cmp);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sorts_like_a_sort_and_is_deterministic() {
        // 大于阈值、带大量相等键：走双轴快排的两个分支。
        let mut v: Vec<(i32, usize)> = (0..500).map(|i| (((i * 7919) % 13) as i32, i)).collect();
        dart_sort(&mut v, |a, b| b.0.cmp(&a.0));
        for w in v.windows(2) {
            assert!(w[0].0 >= w[1].0);
        }
        let mut again: Vec<(i32, usize)> =
            (0..500).map(|i| (((i * 7919) % 13) as i32, i)).collect();
        dart_sort(&mut again, |a, b| b.0.cmp(&a.0));
        assert_eq!(v, again);
    }

    #[test]
    fn small_lists_are_stable_insertion_sort() {
        let mut v = vec![(1, 'a'), (2, 'b'), (1, 'c'), (2, 'd')];
        dart_sort(&mut v, |a, b| b.0.cmp(&a.0));
        assert_eq!(v, vec![(2, 'b'), (2, 'd'), (1, 'a'), (1, 'c')]);
    }
}
