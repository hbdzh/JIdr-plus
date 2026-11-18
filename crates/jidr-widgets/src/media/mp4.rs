//! MP4/H.264 writer on AVFoundation's `AVAssetWriter`, which encodes with
//! VideoToolbox in hardware (D13). Frames come in as RGBA, are copied into
//! BGRA pixel buffers from the writer's pool and stamped at a fixed rate.
//! The device's audio (#28) is a second input: 16-bit stereo PCM in
//! `CMSampleBuffer`s stamped in samples, encoded to AAC by AVFoundation.
//!
//! `unsafe` is allowed here only: these are FFI calls into Apple frameworks
//! through the `objc2` bindings. Every call keeps to the documented API:
//! objects are created and used on one thread, pixel buffers are locked
//! while written, and the writer is finished before it's dropped.
#![allow(unsafe_code)]

use std::ffi::c_void;
use std::path::Path;
use std::ptr::NonNull;
use std::sync::mpsc;
use std::time::{Duration, Instant};

use jidr_core::{JidrError, JidrResult};
use objc2::rc::Retained;
use objc2::runtime::AnyObject;
use objc2_av_foundation::{
    AVAssetWriter, AVAssetWriterInput, AVAssetWriterInputPixelBufferAdaptor, AVAssetWriterStatus,
    AVFileTypeMPEG4, AVMediaTypeAudio, AVMediaTypeVideo, AVVideoAverageBitRateKey, AVVideoCodecKey,
    AVVideoCodecTypeH264, AVVideoCompressionPropertiesKey, AVVideoHeightKey, AVVideoWidthKey,
};
use objc2_avf_audio::{AVEncoderBitRateKey, AVFormatIDKey, AVNumberOfChannelsKey, AVSampleRateKey};
use objc2_core_audio_types::{
    AudioStreamBasicDescription, kAudioFormatFlagIsPacked, kAudioFormatFlagIsSignedInteger,
    kAudioFormatLinearPCM, kAudioFormatMPEG4AAC,
};
use objc2_core_foundation::{CFRetained, CFString};
use objc2_core_media::{
    CMAudioFormatDescriptionCreate, CMAudioSampleBufferCreateReadyWithPacketDescriptions,
    CMBlockBuffer, CMFormatDescription, CMSampleBuffer, CMTime, CMTimeFlags,
    kCMBlockBufferAssureMemoryNowFlag,
};
use objc2_core_video::{
    CVPixelBuffer, CVPixelBufferGetBaseAddress, CVPixelBufferGetBytesPerRow,
    CVPixelBufferLockBaseAddress, CVPixelBufferLockFlags, CVPixelBufferPool,
    CVPixelBufferUnlockBaseAddress, kCVPixelBufferHeightKey, kCVPixelBufferPixelFormatTypeKey,
    kCVPixelBufferWidthKey, kCVPixelFormatType_32BGRA, kCVReturnSuccess,
};
use objc2_foundation::{NSDictionary, NSNumber, NSString, NSURL};

fn err(what: impl Into<String>) -> JidrError {
    JidrError::unexpected(format!("recording: {}", what.into()))
}

/// CF strings are toll-free bridged to `NSString`.
fn ns(key: &CFString) -> &NSString {
    // SAFETY: CFString and NSString are toll-free bridged; same object.
    unsafe { &*(std::ptr::from_ref(key).cast::<NSString>()) }
}

fn time(frame: i64, fps: i32) -> CMTime {
    CMTime {
        value: frame,
        timescale: fps,
        flags: CMTimeFlags::Valid,
        epoch: 0,
    }
}

/// PCM the audio input takes: interleaved signed 16-bit at `rate`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct AudioSpec {
    pub rate: u32,
    pub channels: u32,
}

/// AAC bit rate.
const AAC_BITRATE: u32 = 128_000;

struct AudioInput {
    input: Retained<AVAssetWriterInput>,
    format: CFRetained<CMFormatDescription>,
    spec: AudioSpec,
    /// Marked finished (after a failed append): takes nothing more.
    done: bool,
}

pub struct Mp4Writer {
    writer: Retained<AVAssetWriter>,
    input: Retained<AVAssetWriterInput>,
    adaptor: Retained<AVAssetWriterInputPixelBufferAdaptor>,
    audio: Option<AudioInput>,
    width: u32,
    height: u32,
    fps: i32,
    frames: i64,
}

/// The LPCM description of what [`Mp4Writer::push_audio`] takes.
fn pcm_format(spec: AudioSpec) -> JidrResult<CFRetained<CMFormatDescription>> {
    let frame = 2 * spec.channels;
    let asbd = AudioStreamBasicDescription {
        mSampleRate: f64::from(spec.rate),
        mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
        mBytesPerPacket: frame,
        mFramesPerPacket: 1,
        mBytesPerFrame: frame,
        mChannelsPerFrame: spec.channels,
        mBitsPerChannel: 16,
        mReserved: 0,
    };
    let mut out: *const CMFormatDescription = std::ptr::null();
    // SAFETY: valid ASBD and out-pointer; no layout, cookie or extensions.
    // On success we own the description (+1).
    let rc = unsafe {
        CMAudioFormatDescriptionCreate(
            None,
            NonNull::from(&asbd),
            0,
            std::ptr::null(),
            0,
            std::ptr::null(),
            None,
            NonNull::from(&mut out),
        )
    };
    let out = NonNull::new(out.cast_mut()).filter(|_| rc == 0);
    let out = out.ok_or_else(|| err(format!("no audio format ({rc})")))?;
    // SAFETY: created above with a +1 retain count.
    Ok(unsafe { CFRetained::from_raw(out) })
}

/// An AAC input for `spec`, or `None` when this writer can't take one.
fn audio_input(writer: &AVAssetWriter, spec: AudioSpec) -> Option<AudioInput> {
    let format = match pcm_format(spec) {
        Ok(f) => f,
        Err(e) => {
            tracing::warn!("recording without audio: {}", e.message);
            return None;
        }
    };
    // SAFETY: documented AVFoundation calls with valid, retained arguments.
    unsafe {
        let (Some(id), Some(rate), Some(channels), Some(bitrate), Some(media)) = (
            AVFormatIDKey,
            AVSampleRateKey,
            AVNumberOfChannelsKey,
            AVEncoderBitRateKey,
            AVMediaTypeAudio,
        ) else {
            tracing::warn!("recording without audio: AVFoundation lacks the audio keys");
            return None;
        };
        let aac = NSNumber::new_u32(kAudioFormatMPEG4AAC);
        let r = NSNumber::new_f64(f64::from(spec.rate));
        let ch = NSNumber::new_u32(spec.channels);
        let br = NSNumber::new_u32(AAC_BITRATE);
        let settings = NSDictionary::<NSString, AnyObject>::from_slices(
            &[id, rate, channels, bitrate],
            &[
                &*aac as &AnyObject,
                &*r as &AnyObject,
                &*ch as &AnyObject,
                &*br as &AnyObject,
            ],
        );
        let input = AVAssetWriterInput::assetWriterInputWithMediaType_outputSettings(
            media,
            Some(&settings),
        );
        input.setExpectsMediaDataInRealTime(true);
        if !writer.canAddInput(&input) {
            tracing::warn!("recording without audio: the writer refused the AAC input");
            return None;
        }
        writer.addInput(&input);
        Some(AudioInput {
            input,
            format,
            spec,
            done: false,
        })
    }
}

/// Waits (briefly) until `input` takes more data.
fn wait_ready(input: &AVAssetWriterInput) -> bool {
    let deadline = Instant::now() + Duration::from_millis(500);
    // SAFETY: plain property read on an input we own.
    while !unsafe { input.isReadyForMoreMediaData() } {
        if Instant::now() > deadline {
            return false;
        }
        std::thread::sleep(Duration::from_millis(1));
    }
    true
}

impl Mp4Writer {
    /// Starts an H.264 MP4 at `path` (must not exist). Sides are rounded
    /// down to even numbers, as H.264 requires. With `audio`, the file also
    /// gets an AAC track fed by [`Self::push_audio`]; if AVFoundation
    /// refuses it, the file is video-only and [`Self::has_audio`] says so.
    pub fn create(
        path: &Path,
        width: u32,
        height: u32,
        fps: i32,
        audio: Option<AudioSpec>,
    ) -> JidrResult<Self> {
        let (width, height) = (width & !1, height & !1);
        if width < 16 || height < 16 {
            return Err(err("frame too small"));
        }
        let path_str = path.to_str().ok_or_else(|| err("path isn't UTF-8"))?;
        // SAFETY: documented AVFoundation calls with valid, retained arguments.
        unsafe {
            let url = NSURL::fileURLWithPath(&NSString::from_str(path_str));
            let file_type = AVFileTypeMPEG4.ok_or_else(|| err("no MPEG-4 file type"))?;
            let writer = AVAssetWriter::assetWriterWithURL_fileType_error(&url, file_type)
                .map_err(|e| err(e.localizedDescription().to_string()))?;

            let bitrate = NSNumber::new_u32((width * height * 4).clamp(2_000_000, 16_000_000));
            let compression = NSDictionary::<NSString, AnyObject>::from_slices(
                &[AVVideoAverageBitRateKey.ok_or_else(|| err("no bitrate key"))?],
                &[&*bitrate as &AnyObject],
            );
            let w = NSNumber::new_u32(width);
            let h = NSNumber::new_u32(height);
            let codec = AVVideoCodecTypeH264.ok_or_else(|| err("no H.264 codec"))?;
            let settings = NSDictionary::<NSString, AnyObject>::from_slices(
                &[
                    AVVideoCodecKey.ok_or_else(|| err("no codec key"))?,
                    AVVideoWidthKey.ok_or_else(|| err("no width key"))?,
                    AVVideoHeightKey.ok_or_else(|| err("no height key"))?,
                    AVVideoCompressionPropertiesKey.ok_or_else(|| err("no compression key"))?,
                ],
                &[
                    &**codec as &AnyObject,
                    &*w as &AnyObject,
                    &*h as &AnyObject,
                    &*compression as &AnyObject,
                ],
            );
            let media = AVMediaTypeVideo.ok_or_else(|| err("no video media type"))?;
            let input = AVAssetWriterInput::assetWriterInputWithMediaType_outputSettings(
                media,
                Some(&settings),
            );
            input.setExpectsMediaDataInRealTime(true);

            let fmt = NSNumber::new_u32(kCVPixelFormatType_32BGRA);
            let attrs = NSDictionary::<NSString, AnyObject>::from_slices(
                &[
                    ns(kCVPixelBufferPixelFormatTypeKey),
                    ns(kCVPixelBufferWidthKey),
                    ns(kCVPixelBufferHeightKey),
                ],
                &[&*fmt as &AnyObject, &*w as &AnyObject, &*h as &AnyObject],
            );
            let adaptor = AVAssetWriterInputPixelBufferAdaptor::assetWriterInputPixelBufferAdaptorWithAssetWriterInput_sourcePixelBufferAttributes(
                &input,
                Some(&attrs),
            );
            if !writer.canAddInput(&input) {
                return Err(err("the writer refused the video input"));
            }
            writer.addInput(&input);
            let audio = audio.and_then(|spec| audio_input(&writer, spec));
            if !writer.startWriting() {
                return Err(err(writer
                    .error()
                    .map(|e| e.localizedDescription().to_string())
                    .unwrap_or_else(|| "can't start writing".into())));
            }
            writer.startSessionAtSourceTime(time(0, fps));
            Ok(Self {
                writer,
                input,
                adaptor,
                audio,
                width,
                height,
                fps,
                frames: 0,
            })
        }
    }

    pub fn size(&self) -> (u32, u32) {
        (self.width, self.height)
    }

    pub fn frames(&self) -> i64 {
        self.frames
    }

    /// The file has an audio track.
    pub fn has_audio(&self) -> bool {
        self.audio.is_some()
    }

    /// Appends interleaved 16-bit PCM whose first sample is `start` samples
    /// into the recording. Errors leave the video untouched: the caller
    /// stops sending audio, and [`Self::end_audio`] closes the track.
    pub fn push_audio(&mut self, start: u64, pcm: &[u8]) -> JidrResult<()> {
        let Some(a) = self.audio.as_ref().filter(|a| !a.done) else {
            return Ok(());
        };
        let frame = 2 * a.spec.channels as usize;
        let n = pcm.len() / frame;
        if n == 0 {
            return Ok(());
        }
        let len = n * frame;
        if !wait_ready(&a.input) {
            return Err(err("the audio encoder stopped taking samples"));
        }
        let mut block: *mut CMBlockBuffer = std::ptr::null_mut();
        // SAFETY: the block buffer allocates and owns `len` bytes now
        // (AssureMemoryNow); on success we own it (+1).
        let rc = unsafe {
            CMBlockBuffer::create_with_memory_block(
                None,
                std::ptr::null_mut(),
                len,
                None,
                std::ptr::null(),
                0,
                len,
                kCMBlockBufferAssureMemoryNowFlag,
                NonNull::from(&mut block),
            )
        };
        let block = NonNull::new(block).filter(|_| rc == 0);
        let block = block.ok_or_else(|| err(format!("no audio block buffer ({rc})")))?;
        // SAFETY: created above with a +1 retain count.
        let block: CFRetained<CMBlockBuffer> = unsafe { CFRetained::from_raw(block) };
        // SAFETY: copies `len` bytes of `pcm` (len <= pcm.len()) into the
        // block's own `len`-byte memory.
        let rc = unsafe {
            CMBlockBuffer::replace_data_bytes(NonNull::from(pcm).cast::<c_void>(), &block, 0, len)
        };
        if rc != 0 {
            return Err(err(format!("can't fill the audio block buffer ({rc})")));
        }
        let pts = CMTime {
            value: i64::try_from(start).map_err(|_| err("audio too long"))?,
            timescale: i32::try_from(a.spec.rate).map_err(|_| err("bad sample rate"))?,
            flags: CMTimeFlags::Valid,
            epoch: 0,
        };
        let mut sample: *mut CMSampleBuffer = std::ptr::null_mut();
        // SAFETY: a ready block buffer of `n` packed frames in `format`; no
        // packet descriptions (constant-size LPCM). On success we own it.
        let rc = unsafe {
            CMAudioSampleBufferCreateReadyWithPacketDescriptions(
                None,
                &block,
                &a.format,
                n as isize,
                pts,
                std::ptr::null(),
                NonNull::from(&mut sample),
            )
        };
        let sample = NonNull::new(sample).filter(|_| rc == 0);
        let sample = sample.ok_or_else(|| err(format!("no audio sample buffer ({rc})")))?;
        // SAFETY: created above with a +1 retain count.
        let sample: CFRetained<CMSampleBuffer> = unsafe { CFRetained::from_raw(sample) };
        // SAFETY: append from the writer's own thread with a valid buffer.
        if unsafe { a.input.appendSampleBuffer(&sample) } {
            Ok(())
        } else {
            Err(err(self.failure()))
        }
    }

    /// Ends the audio track early (its stream failed); the video goes on.
    pub fn end_audio(&mut self) {
        if let Some(a) = self.audio.as_mut().filter(|a| !a.done) {
            // SAFETY: documented; no appends follow on this input.
            unsafe { a.input.markAsFinished() };
            a.done = true;
        }
    }

    fn pool(&self) -> JidrResult<Retained<CVPixelBufferPool>> {
        // SAFETY: the pool exists once writing has started.
        unsafe { self.adaptor.pixelBufferPool() }.ok_or_else(|| err("no pixel buffer pool"))
    }

    /// Appends one RGBA frame of exactly `size()` as the next frame.
    pub fn push(&mut self, rgba: &[u8]) -> JidrResult<()> {
        let (w, h) = (self.width as usize, self.height as usize);
        if rgba.len() < w * h * 4 {
            return Err(err("short frame"));
        }
        // Wait (briefly) for the encoder to take more data.
        if !wait_ready(&self.input) {
            return Err(err("the encoder stopped taking frames"));
        }
        let pool = self.pool()?;
        let mut out: *mut CVPixelBuffer = std::ptr::null_mut();
        // SAFETY: valid pool and out-pointer; on success we own the buffer (+1).
        let rc =
            unsafe { CVPixelBufferPool::create_pixel_buffer(None, &pool, NonNull::from(&mut out)) };
        if rc != kCVReturnSuccess {
            return Err(err(format!("no pixel buffer ({rc})")));
        }
        let buf: CFRetained<CVPixelBuffer> = unsafe {
            // SAFETY: created above with a +1 retain count.
            CFRetained::from_raw(NonNull::new(out).ok_or_else(|| err("null pixel buffer"))?)
        };
        // SAFETY: lock, write within bytes_per_row × height, unlock.
        unsafe {
            if CVPixelBufferLockBaseAddress(&buf, CVPixelBufferLockFlags(0)) != kCVReturnSuccess {
                return Err(err("can't lock the pixel buffer"));
            }
            let base = CVPixelBufferGetBaseAddress(&buf).cast::<u8>();
            let stride = CVPixelBufferGetBytesPerRow(&buf);
            if base.is_null() || stride < w * 4 {
                CVPixelBufferUnlockBaseAddress(&buf, CVPixelBufferLockFlags(0));
                return Err(err("bad pixel buffer"));
            }
            for y in 0..h {
                let dst = std::slice::from_raw_parts_mut(base.add(y * stride), w * 4);
                let src = &rgba[y * w * 4..(y + 1) * w * 4];
                for (d, s) in dst
                    .as_chunks_mut::<4>()
                    .0
                    .iter_mut()
                    .zip(src.as_chunks::<4>().0)
                {
                    *d = [s[2], s[1], s[0], 255];
                }
            }
            CVPixelBufferUnlockBaseAddress(&buf, CVPixelBufferLockFlags(0));
        }
        // SAFETY: append from the writer's own thread with a valid buffer.
        let ok = unsafe {
            self.adaptor
                .appendPixelBuffer_withPresentationTime(&buf, time(self.frames, self.fps))
        };
        if !ok {
            return Err(err(self.failure()));
        }
        self.frames += 1;
        Ok(())
    }

    fn failure(&self) -> String {
        // SAFETY: property reads.
        unsafe {
            self.writer
                .error()
                .map(|e| e.localizedDescription().to_string())
                .unwrap_or_else(|| format!("writer status {:?}", self.writer.status()))
        }
    }

    /// Finishes the file and waits for it to be written.
    pub fn finish(mut self) -> JidrResult<()> {
        let (tx, rx) = mpsc::channel::<()>();
        let block = block2::RcBlock::new(move || {
            let _ = tx.send(());
        });
        self.end_audio();
        // SAFETY: all appends returned; the block only signals a channel.
        unsafe {
            self.input.markAsFinished();
            self.writer
                .endSessionAtSourceTime(time(self.frames.max(1), self.fps));
            self.writer.finishWritingWithCompletionHandler(&block);
        }
        rx.recv_timeout(Duration::from_secs(60))
            .map_err(|_| err("finishing the file timed out"))?;
        // SAFETY: property read.
        if unsafe { self.writer.status() } == AVAssetWriterStatus::Completed {
            Ok(())
        } else {
            Err(err(self.failure()))
        }
    }

    /// Abandons the file.
    pub fn cancel(self) {
        // SAFETY: documented cancel.
        unsafe { self.writer.cancelWriting() };
    }
}
