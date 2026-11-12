//! Extract the ramdisk payload from an Android boot image.
//!
//! Recent emulator system images ship `ramdisk.img` as an Android boot image
//! (the `ANDROID!` container) instead of the bare ramdisk the patcher used to
//! assume; even then `kernel_size` is usually 0 and the ramdisk payload is a
//! raw cpio archive. This module recognises the container and slices out the
//! ramdisk so `Ramdisk::parse` sees the format it expects. A file that is not
//! a boot image (gzip/lz4/xz/raw cpio) is returned unchanged.
//!
//! Header layouts implemented (AOSP `boot_image_header`):
//! - v0/v1/v2: fixed fields, `page_size` at offset 36, header is one page,
//!   kernel then ramdisk are page-aligned (`ramdisk_size` at offset 16).
//! - v3/v4: header is padded to 4096 bytes, kernel then ramdisk follow it
//!   (`ramdisk_size` at offset 12 in the AOSP layout; headers built with the
//!   v0-style offset 16 are tolerated when offset 12 is empty or out of
//!   bounds). A v4 signature after the ramdisk does not affect extraction.
//!
//! Errors are [`JidrError::root_failed`] and say whether the boot image is
//! unsupported or truncated; callers keep the underlying ramdisk error context
//! for a non-boot image.

use jidr_core::{JidrError, JidrResult};

const ANDROID_MAGIC: &[u8; 8] = b"ANDROID!";
/// v3/v4 headers are padded to one 4096-byte page before the payload.
const V3_HEADER_SIZE: u64 = 4096;

/// True when `image` starts with the Android boot image magic.
pub fn is_boot_image(image: &[u8]) -> bool {
    image.starts_with(ANDROID_MAGIC)
}

/// Returns the embedded ramdisk bytes of an Android boot image, or the same
/// slice when `image` is not a boot image.
pub fn extract_ramdisk(image: &[u8]) -> JidrResult<&[u8]> {
    if !is_boot_image(image) {
        return Ok(image);
    }
    let version = u32_at(image, 40).ok_or_else(|| truncated("missing header version"))?;
    let (kernel_size, header_size, sizes) = match version {
        0..=2 => {
            let page_size = u32_at(image, 36).ok_or_else(|| truncated("missing page size"))?;
            let page = u64::from(page_size);
            if page < 512 || !page.is_power_of_two() || page > 65536 {
                return Err(unsupported(format!("page size {page_size}")));
            }
            let kernel = u32_at(image, 8).map(u64::from).unwrap_or(0);
            let size = u32_at(image, 16).map(u64::from).unwrap_or(0);
            (kernel, page, vec![size])
        }
        3..=4 => {
            if (image.len() as u64) < V3_HEADER_SIZE {
                return Err(truncated("header is shorter than one 4096-byte page"));
            }
            let kernel = u32_at(image, 8).map(u64::from).unwrap_or(0);
            // AOSP stores ramdisk_size at offset 12 here. Some headers built
            // with the v0 field order leave 12 at zero (or a value that cannot
            // fit) and put the size at 16; accept that as a fallback.
            let mut sizes = Vec::new();
            if let Some(size) = u32_at(image, 12).map(u64::from).filter(|s| *s > 0) {
                sizes.push(size);
            }
            if let Some(size) = u32_at(image, 16).map(u64::from).filter(|s| *s > 0) {
                sizes.push(size);
            }
            (kernel, V3_HEADER_SIZE, sizes)
        }
        other => return Err(unsupported(format!("header version {other}"))),
    };

    let offset = header_size
        .checked_add(align_up(kernel_size, header_size))
        .ok_or_else(|| truncated("ramdisk offset overflows"))?;
    let total = image.len() as u64;
    if offset > total {
        return Err(truncated("ramdisk offset is past the end of the file"));
    }
    let size = sizes
        .into_iter()
        .find(|size| {
            size.checked_add(offset)
                .is_some_and(|end| end <= total && *size > 0)
        })
        .ok_or_else(|| {
            truncated("ramdisk payload is missing or extends past the end of the file")
        })?;
    let start = usize::try_from(offset).map_err(|_| truncated("ramdisk offset is too large"))?;
    let end =
        usize::try_from(offset + size).map_err(|_| truncated("ramdisk payload is too large"))?;
    image
        .get(start..end)
        .ok_or_else(|| truncated("ramdisk payload is outside the file"))
}

fn u32_at(image: &[u8], offset: usize) -> Option<u32> {
    let bytes: [u8; 4] = image.get(offset..offset.checked_add(4)?)?.try_into().ok()?;
    Some(u32::from_le_bytes(bytes))
}

/// Rounds `value` up to `align` bytes; `align` is a validated power of two.
fn align_up(value: u64, align: u64) -> u64 {
    value.div_ceil(align) * align
}

fn unsupported(what: impl std::fmt::Display) -> JidrError {
    JidrError::root_failed(format!("unsupported Android boot image: {what}"))
}

fn truncated(what: impl std::fmt::Display) -> JidrError {
    JidrError::root_failed(format!("truncated Android boot image: {what}"))
}

#[cfg(test)]
mod tests {
    use super::*;

    const PAGE: usize = 2048;

    /// A minimal v0 header page plus `kernel` and `payload` on page boundaries.
    fn boot_v0(kernel: &[u8], payload: &[u8]) -> Vec<u8> {
        let mut image = vec![0u8; PAGE];
        image[..8].copy_from_slice(ANDROID_MAGIC);
        image[8..12].copy_from_slice(&(kernel.len() as u32).to_le_bytes());
        image[16..20].copy_from_slice(&(payload.len() as u32).to_le_bytes());
        image[36..40].copy_from_slice(&(PAGE as u32).to_le_bytes());
        let padded_kernel = align_up(kernel.len() as u64, PAGE as u64) as usize;
        image.resize(PAGE + padded_kernel, 0);
        image[PAGE..PAGE + kernel.len()].copy_from_slice(kernel);
        image.extend_from_slice(payload);
        image
    }

    /// A v3/v4 header page plus payload; `size_offset` is 12 (AOSP) or 16.
    fn boot_v3(version: u32, size_offset: usize, payload: &[u8]) -> Vec<u8> {
        let mut image = vec![0u8; V3_HEADER_SIZE as usize];
        image[..8].copy_from_slice(ANDROID_MAGIC);
        image[size_offset..size_offset + 4].copy_from_slice(&(payload.len() as u32).to_le_bytes());
        image[40..44].copy_from_slice(&version.to_le_bytes());
        image.extend_from_slice(payload);
        image
    }

    #[test]
    fn non_boot_images_are_returned_unchanged() {
        let cpio = b"07070100000000trailer";
        assert_eq!(extract_ramdisk(cpio).unwrap(), cpio);
        let gzip = [0x1f, 0x8b, 8, 0, 0, 0, 0, 0, 0, 3, 0, 0];
        assert_eq!(extract_ramdisk(&gzip).unwrap(), gzip);
        assert!(!is_boot_image(cpio));
    }

    #[test]
    fn extracts_the_v0_ramdisk_after_a_kernel_and_page_padding() {
        let payload = b"07070100000000ramdisk-payload";
        for kernel in [&b""[..], &[0x42u8; 100][..], &[0x42u8; PAGE][..]] {
            let image = boot_v0(kernel, payload);
            assert!(is_boot_image(&image));
            assert_eq!(extract_ramdisk(&image).unwrap(), payload, "{kernel:?}");
        }
    }

    #[test]
    fn v1_and_v2_share_the_v0_layout() {
        let payload = b"07070100000000ramdisk-payload";
        for version in 1u32..=2 {
            let mut image = boot_v0(&[0x42; 64], payload);
            image[40..44].copy_from_slice(&version.to_le_bytes());
            assert_eq!(extract_ramdisk(&image).unwrap(), payload, "v{version}");
        }
    }

    #[test]
    fn extracts_v3_spec_and_v0_style_sizes_and_ignores_a_v4_signature() {
        let payload = b"07070100000000ramdisk-payload";

        // AOSP layout: ramdisk_size at offset 12.
        let image = boot_v3(3, 12, payload);
        assert_eq!(extract_ramdisk(&image).unwrap(), payload);

        // Header written with the v0-style offset 16, plus a v4 signature after
        // the ramdisk: neither changes where the payload is.
        for version in [3, 4] {
            let mut image = boot_v3(version, 16, payload);
            image.extend_from_slice(&[0xaa; 4096]);
            assert_eq!(extract_ramdisk(&image).unwrap(), payload);
        }
    }

    #[test]
    fn rejects_truncated_and_unsupported_boot_images() {
        // Magic only: not even a header version.
        let error = extract_ramdisk(b"ANDROID!").unwrap_err();
        assert_eq!(error.code, jidr_core::ErrorCode::RootFailed);
        assert!(
            error.message.contains("truncated Android boot image"),
            "{error}"
        );

        // A v0 header whose ramdisk size runs past the file.
        let mut image = boot_v0(&[], b"payload");
        image.truncate(image.len() - 3);
        let error = extract_ramdisk(&image).unwrap_err();
        assert!(
            error.message.contains("truncated Android boot image"),
            "{error}"
        );

        // A header page claiming an invalid page size.
        let mut image = boot_v0(&[], b"payload");
        image[36..40].copy_from_slice(&3u32.to_le_bytes());
        let error = extract_ramdisk(&image).unwrap_err();
        assert!(
            error.message.contains("unsupported Android boot image"),
            "{error}"
        );

        // A future header version.
        let image = boot_v3(5, 12, b"payload");
        let error = extract_ramdisk(&image).unwrap_err();
        assert!(error.message.contains("header version 5"), "{error}");

        // No ramdisk payload at all (size 0 / no candidate fits).
        let image = boot_v0(&[], b"");
        let error = extract_ramdisk(&image).unwrap_err();
        assert!(
            error.message.contains("truncated Android boot image"),
            "{error}"
        );
    }
}
