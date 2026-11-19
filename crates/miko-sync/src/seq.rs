//! Ordering checks for the relayed event stream.

/// What one observed sequence number means.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SeqCheck {
    /// The next expected number (or the first one seen).
    Ok,
    /// Numbers were skipped: `missed` events never arrived.
    Gap { missed: u64 },
    /// A repeat or an older number: ignore the event.
    Stale,
}

/// Tracks strictly increasing sequence numbers for one follower.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct SeqTracker {
    last: Option<u64>,
}

impl SeqTracker {
    pub fn new() -> Self {
        Self::default()
    }

    /// Records `seq`. A stale number does not move the tracker.
    pub fn observe(&mut self, seq: u64) -> SeqCheck {
        let check = match self.last {
            None => SeqCheck::Ok,
            Some(last) if seq <= last => return SeqCheck::Stale,
            Some(last) if last.checked_add(1) == Some(seq) => SeqCheck::Ok,
            Some(last) => SeqCheck::Gap {
                missed: seq - last - 1,
            },
        };
        self.last = Some(seq);
        check
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_first_number_is_accepted_whatever_it_is() {
        assert_eq!(SeqTracker::new().observe(40), SeqCheck::Ok);
    }

    #[test]
    fn consecutive_numbers_are_ok() {
        let mut t = SeqTracker::new();
        assert_eq!(t.observe(1), SeqCheck::Ok);
        assert_eq!(t.observe(2), SeqCheck::Ok);
    }

    #[test]
    fn a_skip_reports_how_many_were_missed() {
        let mut t = SeqTracker::new();
        t.observe(1);
        assert_eq!(t.observe(5), SeqCheck::Gap { missed: 3 });
        assert_eq!(t.observe(6), SeqCheck::Ok);
    }

    #[test]
    fn repeats_and_older_numbers_are_stale_and_do_not_rewind() {
        let mut t = SeqTracker::new();
        t.observe(10);
        assert_eq!(t.observe(10), SeqCheck::Stale);
        assert_eq!(t.observe(3), SeqCheck::Stale);
        assert_eq!(t.observe(11), SeqCheck::Ok);
    }
}
