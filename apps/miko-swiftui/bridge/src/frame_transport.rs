//! Bounded JFR1 output. One writer owns stdout, including both header and payload.
use std::io::{self, Write};
use std::sync::Arc;
use tokio::sync::mpsc;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum FrameTransport {
    Shared,
    Legacy,
}

impl FrameTransport {
    pub(crate) fn parse(value: &str) -> Option<Self> {
        match value {
            "shared" => Some(Self::Shared),
            "legacy" => Some(Self::Legacy),
            _ => None,
        }
    }

    /// Keep the old drop-new-on-full policy and update input orientation only
    /// after acceptance. Shared mode reserves before doing pixel-sized work.
    pub(crate) fn offer(
        self,
        sender: &mpsc::Sender<FramePacket>,
        size: (u32, u32),
        pose: u32,
        logical: u32,
        pixels: &Arc<Vec<u8>>,
    ) -> Option<u32> {
        let (width, height) = size;
        match self {
            Self::Legacy => {
                let (shown, bytes) = super::oriented_packet(width, height, pose, logical, pixels)?;
                sender.try_send(FramePacket::Legacy(bytes)).ok()?;
                Some(shown)
            }
            Self::Shared => offer_when_ready(sender, || {
                let shown = if logical < 4 { logical } else { pose };
                let turns = (shown + 4 - pose) % 4;
                let (width, height, payload) = if turns == 0 {
                    (width, height, Arc::clone(pixels))
                } else {
                    let (width, height, rotated) =
                        super::orient_frame(width, height, turns, pixels)?;
                    (width, height, Arc::new(rotated))
                };
                Some((shown, FramePacket::shared(width, height, shown, payload)?))
            }),
        }
    }
}

fn offer_when_ready(
    sender: &mpsc::Sender<FramePacket>,
    prepare: impl FnOnce() -> Option<(u32, FramePacket)>,
) -> Option<u32> {
    let permit = sender.try_reserve().ok()?;
    let (shown, packet) = prepare()?;
    permit.send(packet);
    Some(shown)
}

pub(crate) enum FramePacket {
    Legacy(Vec<u8>),
    Shared {
        header: [u8; 20],
        pixels: Arc<Vec<u8>>,
    },
}

impl FramePacket {
    fn shared(width: u32, height: u32, quarter: u32, pixels: Arc<Vec<u8>>) -> Option<Self> {
        let len = (width as usize)
            .checked_mul(height as usize)?
            .checked_mul(4)?;
        if width == 0 || height == 0 || pixels.len() != len || len > 32 * 1024 * 1024 {
            return None;
        }
        let mut header = [0; 20];
        header[..4].copy_from_slice(b"JFR1");
        for (slot, value) in header[4..].as_chunks_mut::<4>().0.iter_mut().zip([
            width,
            height,
            quarter % 4,
            len as u32,
        ]) {
            slot.copy_from_slice(&value.to_be_bytes());
        }
        Some(Self::Shared { header, pixels })
    }

    /// write_all handles short/interrupted writes. On any error the sole
    /// writer must stop: appending another header would corrupt this stream.
    pub(crate) fn write_to(&self, out: &mut impl Write) -> io::Result<()> {
        match self {
            Self::Legacy(bytes) => out.write_all(bytes),
            Self::Shared { header, pixels } => {
                out.write_all(header)?;
                out.write_all(pixels)
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::Cell;

    #[test]
    fn shared_bytes_match_legacy_for_all_poses_and_logical_orientations() {
        // Include RGBA channel/alpha distinctions, odd dimensions and both
        // portrait/landscape; byte equality protects colors and pixel order.
        for (w, h) in [(1, 1), (3, 2), (2, 5), (7, 3)] {
            let pixels = Arc::new((0..w * h * 4).map(|n| (n * 37 % 256) as u8).collect());
            for pose in 0..4 {
                for logical in 0..=4 {
                    let (tx, mut rx) = mpsc::channel(1);
                    let shown = FrameTransport::Shared
                        .offer(&tx, (w, h), pose, logical, &pixels)
                        .unwrap();
                    let mut actual = Vec::new();
                    rx.try_recv().unwrap().write_to(&mut actual).unwrap();
                    let (old_shown, expected) =
                        super::super::oriented_packet(w, h, pose, logical, &pixels).unwrap();
                    assert_eq!(shown, old_shown);
                    assert_eq!(
                        actual, expected,
                        "size={w}x{h}, pose={pose}, logical={logical}"
                    );
                }
            }
        }
    }

    #[test]
    fn unrotated_packet_shares_source_and_owns_it_until_write_finishes() {
        let pixels = Arc::new(vec![1, 2, 3, 4]);
        let original_pointer = pixels.as_ptr();
        let (tx, mut rx) = mpsc::channel(1);
        assert_eq!(
            FrameTransport::Shared.offer(&tx, (1, 1), 2, 2, &pixels),
            Some(2)
        );
        let packet = rx.try_recv().unwrap();
        let FramePacket::Shared {
            pixels: retained, ..
        } = &packet
        else {
            panic!("shared packet expected")
        };
        assert!(Arc::ptr_eq(retained, &pixels));
        assert_eq!(retained.as_ptr(), original_pointer);
        drop(pixels);
        let mut actual = Vec::new();
        packet.write_to(&mut actual).unwrap();
        assert_eq!(
            actual,
            super::super::frame_packet(1, 1, 2, &[1, 2, 3, 4]).unwrap()
        );
    }

    #[test]
    fn backpressure_skips_preparation_and_keeps_first_queued_frame() {
        let (tx, mut rx) = mpsc::channel(1);
        let prepared = Cell::new(0);
        let prepare = || {
            prepared.set(prepared.get() + 1);
            Some((3, FramePacket::Legacy(vec![9])))
        };
        assert_eq!(offer_when_ready(&tx, prepare), Some(3));
        assert_eq!(offer_when_ready(&tx, prepare), None);
        assert_eq!(prepared.get(), 1);
        let mut output = Vec::new();
        rx.try_recv().unwrap().write_to(&mut output).unwrap();
        assert_eq!(output, [9]);
        assert_eq!(offer_when_ready(&tx, prepare), Some(3));
        drop(rx);
        assert_eq!(offer_when_ready(&tx, prepare), None);
        assert_eq!(prepared.get(), 2);
    }

    #[test]
    fn invalid_frame_releases_reserved_capacity() {
        let (tx, mut rx) = mpsc::channel(1);
        for (w, h) in [(0, 1), (1, 0), (2, 1), (u32::MAX, u32::MAX)] {
            assert_eq!(
                FrameTransport::Shared.offer(&tx, (w, h), 0, 0, &Arc::new(vec![0; 4])),
                None
            );
        }
        assert_eq!(
            FrameTransport::Shared.offer(&tx, (1, 1), 0, 0, &Arc::new(vec![0; 4])),
            Some(0)
        );
        assert!(rx.try_recv().is_ok());
    }

    #[test]
    fn short_interrupted_writes_preserve_complete_frame_boundaries() {
        #[derive(Default)]
        struct ShortWriter {
            bytes: Vec<u8>,
            calls: usize,
        }
        impl Write for ShortWriter {
            fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
                self.calls += 1;
                if self.calls.is_multiple_of(3) {
                    return Err(io::ErrorKind::Interrupted.into());
                }
                let count = bytes.len().min(3);
                self.bytes.extend_from_slice(&bytes[..count]);
                Ok(count)
            }
            fn flush(&mut self) -> io::Result<()> {
                Ok(())
            }
        }
        let mut writer = ShortWriter::default();
        let mut expected = Vec::new();
        for color in [[1, 2, 3, 4], [255, 0, 21, 127]] {
            FramePacket::shared(1, 1, 1, Arc::new(color.to_vec()))
                .unwrap()
                .write_to(&mut writer)
                .unwrap();
            expected.extend(super::super::frame_packet(1, 1, 1, &color).unwrap());
        }
        assert_eq!(writer.bytes, expected);
    }

    #[test]
    fn payload_write_failure_is_reported() {
        struct FailedPayload;
        impl Write for FailedPayload {
            fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
                if bytes.starts_with(b"JFR1") {
                    Ok(bytes.len())
                } else {
                    Err(io::ErrorKind::BrokenPipe.into())
                }
            }
            fn flush(&mut self) -> io::Result<()> {
                Ok(())
            }
        }
        let packet = FramePacket::shared(1, 1, 0, Arc::new(vec![1; 4])).unwrap();
        assert_eq!(
            packet.write_to(&mut FailedPayload).unwrap_err().kind(),
            io::ErrorKind::BrokenPipe
        );
    }

    #[test]
    fn rollback_selector_is_explicit() {
        assert_eq!(
            FrameTransport::parse("legacy"),
            Some(FrameTransport::Legacy)
        );
        assert_eq!(
            FrameTransport::parse("shared"),
            Some(FrameTransport::Shared)
        );
        assert_eq!(FrameTransport::parse("other"), None);
    }
}
