//! The bounded per-follower queue.
//!
//! A slow follower must never hold up the leader or the others, and it must
//! never end up with a finger stuck down. So under load the queue gives up
//! only what a later event makes unnecessary: *touch moves*. A touch down, a
//! touch up, a key, text or a tool key is never dropped. When the queue is
//! full of those, the new event is rejected ([`PushOutcome::Overflow`]) and
//! the follower is reported as failing.

use std::collections::VecDeque;

use miko_automation::Event;

use crate::session::FollowerStatus;

/// This many rejected events turn a lagging follower into a failed one.
pub const OVERFLOW_LIMIT: u32 = 8;

/// One queued event with its stream sequence number.
#[derive(Debug, Clone, PartialEq)]
pub struct Queued {
    pub seq: u64,
    pub event: Event,
}

/// What happened to a pushed event.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PushOutcome {
    /// Added to the queue.
    Queued,
    /// A move took the place of an older move of the same finger.
    Coalesced,
    /// A move was discarded because the queue is full of events that cannot
    /// be dropped.
    Dropped,
    /// The queue is full of events that cannot be dropped, and this one is
    /// not a move: it was rejected and the follower is now out of step.
    Overflow,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Finger {
    Touch,
    Mapped(i32),
}

fn finger_of(event: &Event) -> Option<(Finger, bool)> {
    match event {
        Event::Touch { down, .. } => Some((Finger::Touch, *down)),
        Event::MappedTouch { id, down, .. } => Some((Finger::Mapped(*id), *down)),
        _ => None,
    }
}

#[derive(Debug, Clone)]
struct Entry {
    queued: Queued,
    /// The event is a move of `finger`: the finger was already down.
    finger_move: Option<Finger>,
}

/// A bounded FIFO that coalesces touch moves.
#[derive(Debug, Clone)]
pub struct FollowerQueue {
    capacity: usize,
    items: VecDeque<Entry>,
    /// Fingers currently down in the pushed stream.
    down: Vec<Finger>,
    dropped: u64,
    overflows: u32,
}

impl FollowerQueue {
    /// A queue holding at most `capacity` events (at least 1).
    pub fn new(capacity: usize) -> Self {
        Self {
            capacity: capacity.max(1),
            items: VecDeque::new(),
            down: Vec::new(),
            dropped: 0,
            overflows: 0,
        }
    }

    pub fn len(&self) -> usize {
        self.items.len()
    }

    pub fn is_empty(&self) -> bool {
        self.items.is_empty()
    }

    /// Moves discarded or merged so far.
    pub fn dropped(&self) -> u64 {
        self.dropped
    }

    /// Events rejected so far because nothing could be dropped.
    pub fn overflows(&self) -> u32 {
        self.overflows
    }

    pub fn pop(&mut self) -> Option<Queued> {
        self.items.pop_front().map(|e| e.queued)
    }

    /// The follower's health as the daemon reports it.
    pub fn status(&self) -> FollowerStatus {
        if self.overflows >= OVERFLOW_LIMIT {
            FollowerStatus::Error {
                message: "the follower fell too far behind and lost input".into(),
            }
        } else if self.overflows > 0 || self.items.len() * 2 > self.capacity {
            FollowerStatus::Lagging
        } else {
            FollowerStatus::Ready
        }
    }

    pub fn push(&mut self, seq: u64, event: Event) -> PushOutcome {
        let classified = finger_of(&event);
        let finger_move = match classified {
            Some((finger, true)) if self.down.contains(&finger) => Some(finger),
            _ => None,
        };
        let entry = Entry {
            queued: Queued { seq, event },
            finger_move,
        };

        if let Some(finger) = finger_move
            && let Some(tail) = self.items.back_mut()
            && tail.finger_move == Some(finger)
        {
            *tail = entry;
            self.dropped += 1;
            return PushOutcome::Coalesced;
        }

        if self.items.len() >= self.capacity
            && let Some(index) = self.items.iter().position(|e| e.finger_move.is_some())
        {
            self.items.remove(index);
            self.dropped += 1;
        }
        if self.items.len() >= self.capacity {
            if finger_move.is_some() {
                self.dropped += 1;
                return PushOutcome::Dropped;
            }
            self.overflows += 1;
            return PushOutcome::Overflow;
        }

        if let Some((finger, down)) = classified {
            if down {
                if !self.down.contains(&finger) {
                    self.down.push(finger);
                }
            } else {
                self.down.retain(|f| *f != finger);
            }
        }
        self.items.push_back(entry);
        PushOutcome::Queued
    }
}

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]

    use super::*;
    use proptest::prelude::*;

    fn touch(x: f64, down: bool) -> Event {
        Event::Touch { x, y: 0.5, down }
    }

    fn mapped(id: i32, x: f64, down: bool) -> Event {
        Event::MappedTouch {
            id,
            x,
            y: 0.5,
            down,
        }
    }

    fn key(k: &str) -> Event {
        Event::Key {
            key: k.into(),
            down: true,
        }
    }

    fn drain(q: &mut FollowerQueue) -> Vec<Queued> {
        std::iter::from_fn(|| q.pop()).collect()
    }

    #[test]
    fn events_leave_in_the_order_they_came() {
        let mut q = FollowerQueue::new(8);
        q.push(1, touch(0.1, true));
        q.push(2, key("A"));
        q.push(3, touch(0.1, false));
        let seqs: Vec<u64> = drain(&mut q).into_iter().map(|e| e.seq).collect();
        assert_eq!(seqs, [1, 2, 3]);
    }

    #[test]
    fn consecutive_moves_of_a_finger_merge_but_the_down_stays() {
        let mut q = FollowerQueue::new(8);
        assert_eq!(q.push(1, touch(0.1, true)), PushOutcome::Queued);
        assert_eq!(q.push(2, touch(0.2, true)), PushOutcome::Queued);
        assert_eq!(q.push(3, touch(0.3, true)), PushOutcome::Coalesced);
        assert_eq!(q.push(4, touch(0.4, true)), PushOutcome::Coalesced);
        assert_eq!(q.push(5, touch(0.4, false)), PushOutcome::Queued);
        let out = drain(&mut q);
        assert_eq!(out.iter().map(|e| e.seq).collect::<Vec<_>>(), [1, 4, 5]);
        assert_eq!(out[0].event, touch(0.1, true));
        assert_eq!(out[1].event, touch(0.4, true));
        assert_eq!(q.dropped(), 2);
    }

    #[test]
    fn a_move_after_another_event_is_not_merged_across_it() {
        let mut q = FollowerQueue::new(8);
        q.push(1, touch(0.1, true));
        q.push(2, touch(0.2, true));
        q.push(3, key("A"));
        assert_eq!(q.push(4, touch(0.3, true)), PushOutcome::Queued);
        assert_eq!(q.len(), 4);
    }

    #[test]
    fn different_fingers_do_not_merge() {
        let mut q = FollowerQueue::new(8);
        q.push(1, mapped(3, 0.1, true));
        q.push(2, mapped(4, 0.1, true));
        q.push(3, mapped(3, 0.2, true));
        q.push(4, mapped(4, 0.2, true));
        assert_eq!(q.len(), 4);
    }

    #[test]
    fn a_full_queue_drops_the_oldest_move_for_a_new_event() {
        let mut q = FollowerQueue::new(4);
        q.push(1, touch(0.1, true));
        q.push(2, touch(0.2, true));
        q.push(3, key("A"));
        q.push(4, key("B"));
        assert_eq!(q.push(5, key("C")), PushOutcome::Queued);
        let seqs: Vec<u64> = drain(&mut q).into_iter().map(|e| e.seq).collect();
        assert_eq!(seqs, [1, 3, 4, 5]);
        assert_eq!(q.dropped(), 1);
    }

    #[test]
    fn a_full_queue_of_essential_events_rejects_and_degrades() {
        let mut q = FollowerQueue::new(3);
        q.push(1, key("A"));
        q.push(2, key("B"));
        q.push(3, key("C"));
        assert_eq!(q.push(4, key("D")), PushOutcome::Overflow);
        assert_eq!(q.status(), FollowerStatus::Lagging);
        assert_eq!(q.len(), 3);
        for seq in 5..5 + u64::from(OVERFLOW_LIMIT) {
            q.push(seq, touch(0.1, false));
        }
        assert!(matches!(q.status(), FollowerStatus::Error { .. }));
    }

    #[test]
    fn a_rejected_up_does_not_forget_the_finger() {
        let mut q = FollowerQueue::new(2);
        q.push(1, touch(0.1, true));
        q.push(2, key("A"));
        assert_eq!(q.push(3, touch(0.1, false)), PushOutcome::Overflow);
        // The finger is still tracked as down: a later move is a move.
        q.pop();
        q.pop();
        q.push(4, touch(0.2, true));
        assert_eq!(q.push(5, touch(0.3, true)), PushOutcome::Coalesced);
    }

    #[test]
    fn a_move_into_a_queue_of_essential_events_is_dropped_not_an_overflow() {
        let mut q = FollowerQueue::new(2);
        q.push(1, touch(0.1, true));
        q.push(2, key("A"));
        assert_eq!(q.push(3, touch(0.2, true)), PushOutcome::Dropped);
        assert_eq!(q.overflows(), 0);
    }

    #[test]
    fn status_is_lagging_past_half_full_and_ready_again_when_drained() {
        let mut q = FollowerQueue::new(4);
        assert_eq!(q.status(), FollowerStatus::Ready);
        q.push(1, key("A"));
        q.push(2, key("B"));
        assert_eq!(q.status(), FollowerStatus::Ready);
        q.push(3, key("C"));
        assert_eq!(q.status(), FollowerStatus::Lagging);
        drain(&mut q);
        assert_eq!(q.status(), FollowerStatus::Ready);
    }

    #[test]
    fn capacity_is_at_least_one() {
        let mut q = FollowerQueue::new(0);
        assert_eq!(q.push(1, key("A")), PushOutcome::Queued);
    }

    #[derive(Debug, Clone)]
    enum Op {
        Down(u8),
        Move(u8),
        Up(u8),
        Key,
        Pop,
    }

    fn op() -> impl Strategy<Value = Op> {
        prop_oneof![
            (3u8..6).prop_map(Op::Down),
            (3u8..6).prop_map(Op::Move),
            (3u8..6).prop_map(Op::Up),
            Just(Op::Key),
            Just(Op::Pop),
        ]
    }

    proptest! {
        /// Whatever the load, every touch down, touch up and key that the
        /// queue accepted comes out, in order and exactly once. Only moves
        /// disappear.
        #[test]
        fn essential_events_are_never_lost_or_reordered(
            ops in proptest::collection::vec(op(), 0..300),
            capacity in 1usize..16,
        ) {
            let mut q = FollowerQueue::new(capacity);
            let mut seq = 0u64;
            let mut accepted_essential: Vec<u64> = Vec::new();
            let mut out: Vec<Queued> = Vec::new();
            let mut held: Vec<u8> = Vec::new();
            for op in ops {
                seq += 1;
                // A "down" or "move" of a finger that is not down is a down.
                let (event, essential, id, is_down) = match op {
                    Op::Down(id) | Op::Move(id) => {
                        (mapped(i32::from(id), 0.1, true), !held.contains(&id), Some(id), true)
                    }
                    Op::Up(id) => (mapped(i32::from(id), 0.3, false), true, Some(id), false),
                    Op::Key => (key("A"), true, None, false),
                    Op::Pop => {
                        out.extend(q.pop());
                        continue;
                    }
                };
                let outcome = q.push(seq, event);
                if essential && outcome == PushOutcome::Queued {
                    accepted_essential.push(seq);
                }
                if let Some(id) = id
                    && matches!(outcome, PushOutcome::Queued | PushOutcome::Coalesced)
                {
                    if is_down {
                        if !held.contains(&id) {
                            held.push(id);
                        }
                    } else {
                        held.retain(|h| *h != id);
                    }
                }
            }
            out.extend(std::iter::from_fn(|| q.pop()));
            let seqs: Vec<u64> = out.iter().map(|e| e.seq).collect();
            prop_assert!(seqs.windows(2).all(|w| w[0] < w[1]), "order: {seqs:?}");
            for wanted in accepted_essential {
                prop_assert!(seqs.contains(&wanted), "lost {wanted}");
            }
        }
    }
}
