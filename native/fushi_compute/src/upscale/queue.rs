//! 超分任务队列：按「离当前页多远」排优先级——当前页最先，然后往后翻的方向逐页（预取），往回的页
//! 代价翻四倍；当前页往后超出预取窗口、或往前超过一页的任务直接丢掉（读者已经翻走了）。

/// 一页的超分任务。
pub(crate) struct Job {
    /// 调用方给的令牌，事件原样带回。
    pub token: u64,
    /// 缓存键（调用方保证包含页身份、档位、文字框签名、模型版本）。
    pub key: String,
    pub page: i32,
    /// 原图字节（编码过的图片）。
    pub data: Vec<u8>,
    /// 归一化文字框。
    pub boxes: Vec<[f32; 4]>,
}

pub(crate) struct Queue {
    jobs: Vec<Job>,
    focus: i32,
    window: i32,
}

/// 被丢掉的任务（令牌），由引擎发「已取消」事件。
pub(crate) type Dropped = Vec<u64>;

impl Queue {
    pub(crate) fn new() -> Self {
        Self {
            jobs: Vec::new(),
            focus: 0,
            window: 3,
        }
    }

    fn keep(&self, page: i32) -> bool {
        page >= self.focus - 1 && page <= self.focus + self.window
    }

    fn priority(&self, page: i32) -> i64 {
        let d = page as i64 - self.focus as i64;
        if d >= 0 { d * 2 } else { -d * 8 + 1 }
    }

    /// 入队；同键的旧任务被替换（返回它的令牌）。窗口外的任务不入队，令牌原样返回。
    pub(crate) fn push(&mut self, job: Job) -> Dropped {
        let mut dropped = Vec::new();
        if let Some(i) = self.jobs.iter().position(|j| j.key == job.key) {
            dropped.push(self.jobs.remove(i).token);
        }
        if self.keep(job.page) {
            self.jobs.push(job);
        } else {
            dropped.push(job.token);
        }
        dropped
    }

    /// 换当前页与预取窗口，丢掉窗口外的任务。
    pub(crate) fn set_focus(&mut self, page: i32, window: i32) -> Dropped {
        self.focus = page;
        self.window = window.max(0);
        let (keep, drop): (Vec<Job>, Vec<Job>) = std::mem::take(&mut self.jobs)
            .into_iter()
            .partition(|j| j.page >= page - 1 && j.page <= page + window.max(0));
        self.jobs = keep;
        drop.into_iter().map(|j| j.token).collect()
    }

    pub(crate) fn contains(&self, key: &str) -> bool {
        self.jobs.iter().any(|j| j.key == key)
    }

    pub(crate) fn clear(&mut self) -> Dropped {
        std::mem::take(&mut self.jobs)
            .into_iter()
            .map(|j| j.token)
            .collect()
    }

    /// 取优先级最高的任务（同优先级先来先做）。
    pub(crate) fn pop(&mut self) -> Option<Job> {
        let best = self
            .jobs
            .iter()
            .enumerate()
            .min_by_key(|(i, j)| (self.priority(j.page), *i))
            .map(|(i, _)| i)?;
        Some(self.jobs.remove(best))
    }

    #[cfg(test)]
    pub(crate) fn len(&self) -> usize {
        self.jobs.len()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn job(token: u64, page: i32) -> Job {
        Job {
            token,
            key: format!("k{page}"),
            page,
            data: Vec::new(),
            boxes: Vec::new(),
        }
    }

    #[test]
    fn current_page_first_then_forward_then_back() {
        let mut q = Queue::new();
        q.set_focus(10, 3);
        for (t, p) in [(1, 12), (2, 9), (3, 10), (4, 11), (5, 13)] {
            assert!(q.push(job(t, p)).is_empty());
        }
        let order: Vec<i32> = std::iter::from_fn(|| q.pop()).map(|j| j.page).collect();
        assert_eq!(order, vec![10, 11, 12, 13, 9]);
    }

    #[test]
    fn turning_pages_drops_jobs_left_behind_and_beyond_the_window() {
        let mut q = Queue::new();
        q.set_focus(0, 3);
        for p in 0..4 {
            q.push(job(p as u64, p));
        }
        assert_eq!(
            q.push(job(99, 9)),
            vec![99],
            "beyond the window is not queued"
        );
        let mut dropped = q.set_focus(3, 2);
        dropped.sort();
        assert_eq!(dropped, vec![0, 1]);
        assert_eq!(q.len(), 2);
        // 同键替换
        assert_eq!(
            q.push(Job {
                token: 7,
                ..job(0, 3)
            }),
            vec![3]
        );
        assert_eq!(q.clear().len(), 2);
    }
}
