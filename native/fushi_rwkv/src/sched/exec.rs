// Copyright: Fushi contributors
// License: GNU AGPL, version 3 or later; http://www.gnu.org/licenses/agpl.html
//
//! 排程内核用的单线程协作式执行器。
//!
//! 内核的每个流程（准备、对齐、打分……）是一个 `async` 任务；任务只会停在三种地方：等宿主回复
//! （[`super::host::Host`] 的 effect）、等 FIFO 锁（[`Lock`]）、等另一个任务跑完（[`Flag`]）。
//! 没有真正的唤醒器：[`Exec::run`] 一遍遍轮询全部任务，直到一整遍里没有任何「信号」（有回复被取走、
//! 有锁被放开、有任务结束 / 新建）为止。同时活着的任务只有个位数，这样写比维护唤醒队列简单得多。

use std::cell::{Cell, RefCell};
use std::future::Future;
use std::pin::Pin;
use std::rc::Rc;
use std::task::{Context, Poll, RawWaker, RawWakerVTable, Waker};

type Task = Pin<Box<dyn Future<Output = ()>>>;

fn noop_waker() -> Waker {
    fn clone(_: *const ()) -> RawWaker {
        RawWaker::new(std::ptr::null(), &VTABLE)
    }
    fn noop(_: *const ()) {}
    static VTABLE: RawWakerVTable = RawWakerVTable::new(clone, noop, noop, noop);
    // SAFETY: 四个函数都不碰数据指针。
    unsafe { Waker::from_raw(RawWaker::new(std::ptr::null(), &VTABLE)) }
}

fn poll_once(task: &mut Task) -> Poll<()> {
    let waker = noop_waker();
    task.as_mut().poll(&mut Context::from_waker(&waker))
}

#[derive(Default)]
pub struct Exec {
    tasks: RefCell<Vec<Task>>,
    /// 轮询途中新建、还没并进 `tasks` 的任务。
    spawned: RefCell<Vec<Task>>,
    signals: Cell<u64>,
    /// 有任务要求把已有输出先交给宿主（[`Exec::flush`]）：这一遍剩下的任务不再轮询，`run` 返回。
    yielding: Cell<bool>,
}

impl Exec {
    /// 有东西变了：再轮询一遍。
    pub fn signal(&self) {
        self.signals.set(self.signals.get() + 1);
    }

    /// 新建任务并当场跑到它第一次停下（与 Dart 的 async 函数一样：调用时同步执行到第一个真正的等待）。
    /// 调用方不得持有内核状态的借用。
    pub fn spawn(&self, future: impl Future<Output = ()> + 'static) {
        let mut task: Task = Box::pin(future);
        if poll_once(&mut task).is_pending() {
            self.spawned.borrow_mut().push(task);
        }
        self.signal();
    }

    /// 轮询到没有任务还能往前走（或有任务要求先交出输出）。返回 true = 是后者，宿主应立刻再调一次。
    pub fn run(&self) -> bool {
        // 喂输入时新建的任务已经要求先交出输出（任务在 spawn 里就跑到了那一步）。
        if self.yielding.replace(false) {
            return true;
        }
        loop {
            let before = self.signals.get();
            let mut tasks = std::mem::take(&mut *self.tasks.borrow_mut());
            // 上一遍之后（喂输入时）新建的任务。
            tasks.append(&mut self.spawned.borrow_mut());
            let mut kept: Vec<Task> = Vec::with_capacity(tasks.len());
            for mut task in tasks {
                if self.yielding.get() || poll_once(&mut task).is_pending() {
                    kept.push(task);
                } else {
                    self.signal();
                }
            }
            kept.append(&mut self.spawned.borrow_mut());
            *self.tasks.borrow_mut() = kept;
            if self.yielding.replace(false) {
                return true;
            }
            if self.signals.get() == before {
                return false;
            }
        }
    }

    /// 丢掉全部任务（内核销毁时：任务握着内核的引用，不清就成环）。
    pub fn clear(&self) {
        // 先取出来再丢：任务析构时会放锁、发信号，那时不能还借着任务表。
        let tasks = std::mem::take(&mut *self.tasks.borrow_mut());
        let spawned = std::mem::take(&mut *self.spawned.borrow_mut());
        drop(tasks);
        drop(spawned);
    }

    /// 还有没跑完的任务。
    #[cfg(test)]
    pub fn busy(&self) -> bool {
        !self.tasks.borrow().is_empty() || !self.spawned.borrow().is_empty()
    }

    /// 把已经攒下的输出先交给宿主，再接着跑（长时间的原生调用之前用：宿主先看到「开始」）。
    pub fn flush(self: &Rc<Self>) -> Flush {
        Flush {
            exec: self.clone(),
            armed: false,
        }
    }
}

pub struct Flush {
    exec: Rc<Exec>,
    armed: bool,
}

impl Future for Flush {
    type Output = ();
    fn poll(mut self: Pin<&mut Self>, _: &mut Context<'_>) -> Poll<()> {
        if self.armed {
            return Poll::Ready(());
        }
        self.armed = true;
        self.exec.yielding.set(true);
        self.exec.signal();
        Poll::Pending
    }
}

/// 一次性完成标记：一个任务跑完后置位，别的任务等它。
#[derive(Clone)]
pub struct Flag(Rc<Cell<bool>>);

impl Flag {
    pub fn new() -> Self {
        Self(Rc::new(Cell::new(false)))
    }

    pub fn set(&self, exec: &Exec) {
        self.0.set(true);
        exec.signal();
    }

    pub fn wait(&self) -> FlagWait {
        FlagWait(self.0.clone())
    }
}

pub struct FlagWait(Rc<Cell<bool>>);

impl Future for FlagWait {
    type Output = ();
    fn poll(self: Pin<&mut Self>, _: &mut Context<'_>) -> Poll<()> {
        if self.0.get() {
            Poll::Ready(())
        } else {
            Poll::Pending
        }
    }
}

/// 先到先得的锁（Dart 侧原来的 `_queue.then(...)` 串行队列）：排队位置在调用 [`Lock::lock`] 的那一刻
/// 定下，不是在第一次轮询时。
pub struct Lock {
    exec: Rc<Exec>,
    next: Cell<u64>,
    serving: Rc<Cell<u64>>,
}

impl Lock {
    pub fn new(exec: Rc<Exec>) -> Self {
        Self {
            exec,
            next: Cell::new(0),
            serving: Rc::new(Cell::new(0)),
        }
    }

    pub fn lock(&self) -> LockWait {
        let ticket = self.next.get();
        self.next.set(ticket + 1);
        LockWait {
            exec: self.exec.clone(),
            serving: self.serving.clone(),
            ticket,
            taken: false,
        }
    }
}

pub struct LockWait {
    exec: Rc<Exec>,
    serving: Rc<Cell<u64>>,
    ticket: u64,
    taken: bool,
}

impl Future for LockWait {
    type Output = Guard;
    fn poll(mut self: Pin<&mut Self>, _: &mut Context<'_>) -> Poll<Guard> {
        if self.serving.get() != self.ticket {
            return Poll::Pending;
        }
        self.taken = true;
        Poll::Ready(Guard {
            exec: self.exec.clone(),
            serving: self.serving.clone(),
        })
    }
}

impl Drop for LockWait {
    fn drop(&mut self) {
        // 排了队却没等到就被丢掉（任务随内核一起销毁）：让出位置，不卡住后面的。
        if !self.taken && self.serving.get() == self.ticket {
            self.serving.set(self.ticket + 1);
            self.exec.signal();
        }
    }
}

pub struct Guard {
    exec: Rc<Exec>,
    serving: Rc<Cell<u64>>,
}

impl Drop for Guard {
    fn drop(&mut self) {
        self.serving.set(self.serving.get() + 1);
        self.exec.signal();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn lock_is_fifo_and_spawn_runs_eagerly() {
        let exec = Rc::new(Exec::default());
        let lock = Rc::new(Lock::new(exec.clone()));
        let order = Rc::new(RefCell::new(Vec::<u32>::new()));
        let gate = Flag::new();
        for id in 0..3u32 {
            let (lock, order, gate) = (lock.clone(), order.clone(), gate.clone());
            exec.spawn(async move {
                let _guard = lock.lock().await;
                order.borrow_mut().push(id);
                gate.wait().await;
                order.borrow_mut().push(10 + id);
            });
        }
        // 第一个任务在 spawn 里就拿到了锁，停在 gate 上。
        assert_eq!(*order.borrow(), vec![0]);
        assert!(!exec.run());
        assert_eq!(*order.borrow(), vec![0]);
        gate.set(&exec);
        assert!(!exec.run());
        assert_eq!(*order.borrow(), vec![0, 10, 1, 11, 2, 12]);
        assert!(!exec.busy());
    }

    #[test]
    fn flush_returns_control_once() {
        let exec = Rc::new(Exec::default());
        let steps = Rc::new(Cell::new(0));
        let (e, s) = (exec.clone(), steps.clone());
        exec.spawn(async move {
            s.set(1);
            e.flush().await;
            s.set(2);
        });
        assert_eq!(steps.get(), 1);
        assert!(exec.run());
        assert_eq!(steps.get(), 1);
        assert!(!exec.run());
        assert_eq!(steps.get(), 2);
    }
}
