//! Device audio for recordings (#28): the emulator's gRPC
//! `streamAudio(AudioFormat) → stream AudioPacket`, laid on the video's
//! timeline.
//!
//! Video and audio share one clock: the instant the recording started. A
//! frame is stamped by when the encoder took it, and an audio packet by when
//! it arrived, less its own length. The emulator sends packets every
//! 20–30 ms while the guest plays sound and nothing at all while it's
//! silent, so [`Timeline`] keeps the track continuous:
//!
//! - a packet that lands within [`TOLERANCE`] of where the track ends is
//!   appended as is (arrival jitter is not a gap, and padding it would click);
//! - a later packet is preceded by silence up to its place;
//! - a packet whose place the track has already passed by more than
//!   [`TOLERANCE`] loses its overlapping start (it arrived too late);
//! - with no packets, silence is written up to [`HOLD`] behind the clock, so
//!   the audio never lags the video by more than that (AVAssetWriter
//!   interleaves the two) and a late packet still finds its place.
//!
//! So the audio never drifts from the video by more than [`TOLERANCE`].
//!
//! The stream itself comes through a [`Feed`]. The emulator doesn't even
//! answer the `streamAudio` call until the guest first plays a sound (a
//! headless emulator with no audio may never answer), so nothing ever waits
//! on it: a task opens and pumps it, and dropping the feed aborts that task.

use std::future::Future;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc;
use std::time::{Duration, Instant};

use jidr_core::JidrResult;
use jidr_proto::control as pb;
use tokio_stream::{Stream, StreamExt as _};

/// Sample rate asked of the emulator and written to the file.
pub const RATE: u32 = 48_000;
/// Stereo.
pub const CHANNELS: u32 = 2;
/// Signed 16-bit little-endian, interleaved.
pub const FRAME_BYTES: usize = 2 * CHANNELS as usize;
/// How far a packet may sit from the track's end and still be appended
/// without padding or trimming.
pub const TOLERANCE: Duration = Duration::from_millis(40);
/// How far behind the clock silence is written while no packets come.
pub const HOLD: Duration = Duration::from_millis(300);

/// The format asked of `streamAudio`.
// The build may use the installed SDK's newer protos, which can add fields.
#[allow(clippy::needless_update)]
pub fn format_pb() -> pb::AudioFormat {
    pb::AudioFormat {
        sampling_rate: u64::from(RATE),
        channels: pb::audio_format::Channels::Stereo as i32,
        format: pb::audio_format::SampleFormat::AudFmtS16 as i32,
        ..Default::default()
    }
}

/// A packet's samples as 16-bit stereo at [`RATE`], or `None` when the
/// emulator sent another rate or 8-bit samples (it honours the requested
/// format, so this only guards against a surprise). Mono is doubled. A
/// packet without a format is in the requested one.
pub fn to_stereo(format: Option<&pb::AudioFormat>, pcm: &[u8]) -> Option<Vec<u8>> {
    let Some(f) = format else {
        return Some(whole_frames(pcm, FRAME_BYTES).to_vec());
    };
    let rate_ok = f.sampling_rate == 0 || f.sampling_rate == u64::from(RATE);
    if !rate_ok || f.format != pb::audio_format::SampleFormat::AudFmtS16 as i32 {
        return None;
    }
    if f.channels == pb::audio_format::Channels::Stereo as i32 {
        return Some(whole_frames(pcm, FRAME_BYTES).to_vec());
    }
    let mono = whole_frames(pcm, 2);
    let mut out = Vec::with_capacity(mono.len() * 2);
    for s in mono.as_chunks::<2>().0 {
        out.extend_from_slice(s);
        out.extend_from_slice(s);
    }
    Some(out)
}

fn whole_frames(pcm: &[u8], frame: usize) -> &[u8] {
    &pcm[..pcm.len() - pcm.len() % frame]
}

/// An audio packet as it arrived: when, and 16-bit stereo PCM.
pub type Packet = (Instant, Vec<u8>);

/// The device's audio for one recording. `open` (the `streamAudio` call)
/// and the stream run on a task; the encoder only takes what has arrived
/// ([`Feed::drain`]) and never waits. Dropping the feed aborts the task, so
/// an open that never answers or a stream that never yields can't outlive
/// the recording.
pub struct Feed {
    rx: mpsc::Receiver<Packet>,
    failed: Arc<AtomicBool>,
    received: Arc<AtomicBool>,
    task: tokio::task::JoinHandle<()>,
}

impl Feed {
    /// Starts `open` on the current runtime. If it fails, [`Feed::failed`]
    /// turns true (with a warning naming `device`): the recording goes on
    /// video-only. `stop` silences the warning when the stream ends because
    /// the recording did.
    pub fn spawn<F, S>(device: String, open: F, stop: Arc<AtomicBool>) -> Self
    where
        F: Future<Output = JidrResult<S>> + Send + 'static,
        S: Stream<Item = Result<pb::AudioPacket, tonic::Status>> + Unpin + Send + 'static,
    {
        let (tx, rx) = mpsc::channel();
        let failed = Arc::new(AtomicBool::new(false));
        let flag = failed.clone();
        let received = Arc::new(AtomicBool::new(false));
        let received_flag = received.clone();
        let task = tokio::spawn(async move {
            match open.await {
                Ok(stream) => pump(stream, tx, stop, received_flag).await,
                Err(e) => {
                    tracing::warn!("recording {device} without audio: {}", e.message);
                    flag.store(true, Ordering::Relaxed);
                }
            }
        });
        Self {
            rx,
            failed,
            received,
            task,
        }
    }

    /// The stream couldn't be opened.
    pub fn failed(&self) -> bool {
        self.failed.load(Ordering::Relaxed)
    }

    /// Whether the emulator supplied at least one valid, nonempty packet.
    pub fn received(&self) -> bool {
        self.received.load(Ordering::Relaxed)
    }

    /// The packets that arrived since the last call; never blocks.
    pub fn drain(&self) -> impl Iterator<Item = Packet> + '_ {
        self.rx.try_iter()
    }
}

impl Drop for Feed {
    fn drop(&mut self) {
        self.task.abort();
    }
}

/// Sends each packet, stamped with its arrival, until the stream ends.
/// Packets in another format are dropped (with one warning); the timeline
/// fills their place with silence.
async fn pump<S>(
    mut packets: S,
    tx: mpsc::Sender<Packet>,
    stop: Arc<AtomicBool>,
    received: Arc<AtomicBool>,
) where
    S: Stream<Item = Result<pb::AudioPacket, tonic::Status>> + Unpin,
{
    let mut warned = false;
    let mut first = true;
    let end = loop {
        match packets.next().await {
            Some(Ok(p)) => {
                let at = Instant::now();
                if first {
                    first = false;
                    tracing::info!(
                        "recording: device audio started ({:?}, {} bytes a packet)",
                        p.format,
                        p.audio.len()
                    );
                }
                match to_stereo(p.format.as_ref(), &p.audio) {
                    Some(pcm) => {
                        if !pcm.is_empty() {
                            received.store(true, Ordering::Relaxed);
                        }
                        if tx.send((at, pcm)).is_err() {
                            return;
                        }
                    }
                    None if !warned => {
                        warned = true;
                        tracing::warn!(
                            "recording: the emulator sent audio as {:?}; it's left out",
                            p.format
                        );
                    }
                    None => {}
                }
            }
            Some(Err(e)) => break e.message().to_string(),
            None => break "it ended".to_string(),
        }
    };
    if !stop.load(Ordering::Relaxed) {
        tracing::warn!("recording: the device's audio stream stopped ({end}); the rest is silent");
    }
}

/// Frames in `d` at [`RATE`].
pub fn frames_in(d: Duration) -> u64 {
    (d.as_secs_f64() * f64::from(RATE)).round() as u64
}

/// Samples to write at `start` (in frames from the recording's start).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Chunk {
    pub start: u64,
    pub pcm: Vec<u8>,
}

impl Chunk {
    pub fn frames(&self) -> u64 {
        (self.pcm.len() / FRAME_BYTES) as u64
    }

    fn silence(start: u64, frames: u64) -> Self {
        Self {
            start,
            pcm: vec![0; frames as usize * FRAME_BYTES],
        }
    }
}

/// Places packets and silence on the shared timeline; see the module docs.
#[derive(Debug, Default)]
pub struct Timeline {
    /// Frames written so far: where the track ends.
    end: u64,
}

impl Timeline {
    pub fn end(&self) -> u64 {
        self.end
    }

    /// A packet whose first sample belongs at `at` (since the recording's
    /// start), 16-bit stereo. Returns what to write, in order.
    pub fn place(&mut self, at: Duration, pcm: &[u8]) -> Vec<Chunk> {
        let pcm = whole_frames(pcm, FRAME_BYTES);
        let frames = (pcm.len() / FRAME_BYTES) as u64;
        if frames == 0 {
            return Vec::new();
        }
        let want = frames_in(at);
        let tol = frames_in(TOLERANCE);
        let mut out = Vec::new();
        let skip = if want > self.end + tol {
            out.push(Chunk::silence(self.end, want - self.end));
            self.end = want;
            0
        } else if self.end > want + tol {
            // Late: what overlaps the track is dropped.
            (self.end - want).min(frames)
        } else {
            0
        };
        if skip < frames {
            let rest = pcm[skip as usize * FRAME_BYTES..].to_vec();
            let chunk = Chunk {
                start: self.end,
                pcm: rest,
            };
            self.end += chunk.frames();
            out.push(chunk);
        }
        out
    }

    /// Silence up to [`HOLD`] behind `now` (since the recording's start).
    pub fn fill(&mut self, now: Duration) -> Option<Chunk> {
        self.pad_to(frames_in(now.saturating_sub(HOLD)))
    }

    /// Silence up to `end` (the video's length), when the recording stops.
    pub fn finish(&mut self, end: Duration) -> Option<Chunk> {
        self.pad_to(frames_in(end))
    }

    fn pad_to(&mut self, frame: u64) -> Option<Chunk> {
        if frame <= self.end {
            return None;
        }
        let c = Chunk::silence(self.end, frame - self.end);
        self.end = frame;
        Some(c)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Sets its flag when dropped: shows a future or stream was torn down.
    struct Dropped(Arc<AtomicBool>);

    impl Drop for Dropped {
        fn drop(&mut self) {
            self.0.store(true, Ordering::Relaxed);
        }
    }

    type PacketStream =
        std::pin::Pin<Box<dyn Stream<Item = Result<pb::AudioPacket, tonic::Status>> + Send>>;

    fn packet(n: usize) -> pb::AudioPacket {
        pb::AudioPacket {
            format: Some(format_pb()),
            audio: vec![1; n * FRAME_BYTES],
            ..Default::default()
        }
    }

    /// Lets the feed's task run.
    async fn settle() {
        for _ in 0..20 {
            tokio::task::yield_now().await;
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }

    /// Regression (CI on PR #109): a headless emulator never answers
    /// `streamAudio`, and waiting for it hung the recording test for
    /// 30 minutes. The feed doesn't wait, isn't failed (the track is
    /// silence) and drops the pending call with itself.
    #[tokio::test]
    async fn an_open_that_never_answers_blocks_nothing_and_ends_with_the_feed() {
        let gone = Arc::new(AtomicBool::new(false));
        let guard = Dropped(gone.clone());
        let open = async move {
            let _guard = guard;
            std::future::pending::<JidrResult<PacketStream>>().await
        };
        let feed = Feed::spawn("d".into(), open, Arc::default());
        settle().await;
        assert_eq!(feed.drain().count(), 0);
        assert!(!feed.failed());
        assert!(!feed.received());
        assert!(!gone.load(Ordering::Relaxed));
        drop(feed);
        settle().await;
        assert!(
            gone.load(Ordering::Relaxed),
            "the pending open outlived the feed"
        );
    }

    /// A stream that opens and then never yields (or never closes) is torn
    /// down with the feed too.
    #[tokio::test]
    async fn a_stream_that_never_yields_ends_with_the_feed() {
        let gone = Arc::new(AtomicBool::new(false));
        let guard = Dropped(gone.clone());
        let stream: PacketStream = Box::pin(
            tokio_stream::iter([Ok(packet(960))])
                .chain(tokio_stream::pending())
                .map(move |p| {
                    let _ = &guard;
                    p
                }),
        );
        let feed = Feed::spawn("d".into(), async { Ok(stream) }, Arc::default());
        settle().await;
        assert!(feed.received());
        assert_eq!(
            feed.drain().map(|(_, pcm)| pcm.len()).sum::<usize>(),
            960 * FRAME_BYTES
        );
        assert_eq!(feed.drain().count(), 0, "nothing more, and no wait");
        drop(feed);
        settle().await;
        assert!(
            gone.load(Ordering::Relaxed),
            "the stalled stream outlived the feed"
        );
    }

    #[tokio::test]
    async fn a_failed_open_makes_the_recording_video_only() {
        let open = async {
            Err::<PacketStream, _>(jidr_core::JidrError::sdk("streamAudio: transport error"))
        };
        let feed = Feed::spawn("d".into(), open, Arc::default());
        settle().await;
        assert!(feed.failed());
        assert_eq!(feed.drain().count(), 0);
    }

    fn ms(n: u64) -> Duration {
        Duration::from_millis(n)
    }

    /// `n` frames of a constant sample.
    fn pcm(n: usize, v: u8) -> Vec<u8> {
        vec![v; n * FRAME_BYTES]
    }

    /// Every chunk starts where the previous one ended.
    fn contiguous(chunks: &[Chunk]) -> bool {
        chunks
            .windows(2)
            .all(|w| w[0].start + w[0].frames() == w[1].start)
    }

    #[test]
    fn packets_on_time_are_appended_back_to_back() {
        let mut t = Timeline::default();
        let mut all = Vec::new();
        // 20 ms packets (960 frames) arriving with ±10 ms of jitter.
        for (i, jitter) in [0i64, 8, -6, 10, -10, 3].iter().enumerate() {
            let at = (i as i64 * 20 + jitter).max(0) as u64;
            all.extend(t.place(ms(at), &pcm(960, 1)));
        }
        assert!(contiguous(&all));
        assert_eq!(all.len(), 6, "no silence was inserted: {all:?}");
        assert_eq!(all[0].start, 0);
        assert_eq!(t.end(), 6 * 960);
    }

    #[test]
    fn a_gap_is_filled_with_silence_so_the_sound_stays_in_place() {
        let mut t = Timeline::default();
        let mut all = t.place(ms(0), &pcm(960, 1));
        // Nothing for 2 s, then sound again.
        all.extend(t.place(ms(2_000), &pcm(960, 1)));
        assert!(contiguous(&all));
        assert_eq!(all.len(), 3);
        assert!(all[1].pcm.iter().all(|b| *b == 0));
        assert_eq!(all[2].start, frames_in(ms(2_000)));
    }

    #[test]
    fn the_first_packet_after_a_quiet_start_is_padded_from_zero() {
        let mut t = Timeline::default();
        let all = t.place(ms(1_500), &pcm(960, 1));
        assert_eq!(all[0], Chunk::silence(0, 72_000));
        assert_eq!(all[1].start, 72_000);
    }

    #[test]
    fn silence_follows_the_clock_while_nothing_plays() {
        let mut t = Timeline::default();
        assert_eq!(t.fill(ms(200)), None, "still inside the hold");
        let c = t.fill(ms(1_300)).unwrap();
        assert_eq!((c.start, c.frames()), (0, frames_in(ms(1_000))));
        assert_eq!(t.fill(ms(1_300)), None);
        // A packet that arrives inside the hold still lands in place.
        let all = t.place(ms(1_100), &pcm(960, 1));
        assert_eq!(all[0].start, frames_in(ms(1_000)));
        assert_eq!(all.last().unwrap().start, frames_in(ms(1_100)));
    }

    #[test]
    fn a_late_packet_loses_only_what_overlaps() {
        let mut t = Timeline::default();
        t.fill(ms(1_300)); // track ends at 1.0 s
        // Belongs at 0.9 s, 200 ms long: the first 100 ms is dropped.
        let all = t.place(ms(900), &pcm(9_600, 1));
        assert_eq!(all.len(), 1);
        assert_eq!(all[0].start, frames_in(ms(1_000)));
        assert_eq!(all[0].frames(), 4_800);
        // Entirely in the past: nothing.
        assert!(t.place(ms(0), &pcm(960, 1)).is_empty());
    }

    /// The track never drifts from the clock by more than the tolerance,
    /// even when the emulator's packets run a little fast or slow.
    #[test]
    fn drift_stays_within_the_tolerance() {
        for speed in [0.97f64, 1.03] {
            let mut t = Timeline::default();
            for i in 0..3_000u64 {
                // Packets hold 20 ms but arrive every 20 ms × speed.
                let at = Duration::from_secs_f64(i as f64 * 0.020 * speed);
                for c in t.place(at, &pcm(960, 1)) {
                    if c.pcm[0] == 1 {
                        // A trimmed packet starts `960 - frames` samples in.
                        let want = (frames_in(at) + 960 - c.frames()) as i64;
                        let off = c.start as i64 - want;
                        assert!(
                            off.unsigned_abs() <= frames_in(TOLERANCE),
                            "speed {speed}: packet {i} off by {off} frames"
                        );
                    }
                }
            }
        }
    }

    #[test]
    fn finishing_pads_to_the_video_length() {
        let mut t = Timeline::default();
        t.place(ms(0), &pcm(960, 1));
        let c = t.finish(ms(1_000)).unwrap();
        assert_eq!(c.start, 960);
        assert_eq!(t.end(), RATE as u64);
        assert_eq!(t.finish(ms(500)), None);
    }

    #[test]
    fn packets_are_converted_to_stereo_or_refused() {
        let stereo = format_pb();
        assert_eq!(
            to_stereo(Some(&stereo), &[1, 2, 3, 4, 5]),
            Some(vec![1, 2, 3, 4])
        );
        assert_eq!(to_stereo(None, &[1, 2, 3, 4]), Some(vec![1, 2, 3, 4]));
        let mono = pb::AudioFormat {
            channels: pb::audio_format::Channels::Mono as i32,
            ..format_pb()
        };
        assert_eq!(to_stereo(Some(&mono), &[1, 2, 3]), Some(vec![1, 2, 1, 2]));
        let other_rate = pb::AudioFormat {
            sampling_rate: 44_100,
            ..format_pb()
        };
        assert_eq!(to_stereo(Some(&other_rate), &[0; 4]), None);
        let u8_fmt = pb::AudioFormat {
            format: pb::audio_format::SampleFormat::AudFmtU8 as i32,
            ..format_pb()
        };
        assert_eq!(to_stereo(Some(&u8_fmt), &[0; 4]), None);
    }
}
