//! WAV (RIFF) reader: 16/24/32-bit integer PCM and 32-bit IEEE float,
//! plain or WAVE_FORMAT_EXTENSIBLE, arbitrary sample rate.
//!
//! Tolerates real-world files: unknown chunks are skipped, odd chunk sizes
//! are padded per RIFF, a truncated final chunk is clamped, and the header
//! duplicated inside the data payload by `record_windows` (a few junk bytes,
//! then a second `fmt ` + `data` header before the samples) is detected and
//! stripped.

#[derive(Debug)]
pub struct WavData {
    pub sample_rate: u32,
    pub channels: u16,
    /// Mono mixdown (channel mean), one value per frame, in [-1, 1].
    pub samples: Vec<f64>,
}

/// Longest file the in-memory model accepts, in mono samples after
/// mixdown. Samples are held as f64 (8 bytes each), so this cap is
/// 800 MB of samples — about 35 minutes at 48 kHz — chosen to leave
/// headroom for the spectrogram and tracks on phones. Longer field
/// recordings must be trimmed first; streaming analysis is future work.
pub const MAX_SAMPLES: usize = 100_000_000;

#[derive(Debug, PartialEq, Eq)]
pub enum WavError {
    NotRiffWave,
    NoFmtChunk,
    NoDataChunk,
    UnsupportedFormat(u16),
    UnsupportedBitDepth(u16),
    ZeroChannels,
    /// File longer than the in-memory model supports.
    TooLong { minutes: u32, limit_minutes: u32 },
}

impl std::fmt::Display for WavError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            WavError::NotRiffWave => write!(f, "not a RIFF/WAVE file"),
            WavError::NoFmtChunk => write!(f, "missing fmt chunk"),
            WavError::NoDataChunk => write!(f, "missing data chunk"),
            WavError::UnsupportedFormat(tag) => {
                write!(f, "unsupported audio format tag {tag} (PCM or IEEE float)")
            }
            WavError::UnsupportedBitDepth(bits) => {
                write!(f, "unsupported bit depth {bits} (16/24/32 PCM or 32 float)")
            }
            WavError::ZeroChannels => write!(f, "fmt chunk declares zero channels"),
            WavError::TooLong {
                minutes,
                limit_minutes,
            } => write!(
                f,
                "recording is about {minutes} min; openphon can open up to \
                 ~{limit_minutes} min at this sample rate. Trim the file and retry"
            ),
        }
    }
}

impl std::error::Error for WavError {}

struct Fmt {
    format_tag: u16,
    channels: u16,
    sample_rate: u32,
    bits_per_sample: u16,
}

fn u16le(b: &[u8], at: usize) -> u16 {
    u16::from_le_bytes([b[at], b[at + 1]])
}

fn u32le(b: &[u8], at: usize) -> u32 {
    u32::from_le_bytes([b[at], b[at + 1], b[at + 2], b[at + 3]])
}

fn parse_fmt(payload: &[u8]) -> Option<Fmt> {
    if payload.len() < 16 {
        return None;
    }
    let mut format_tag = u16le(payload, 0);
    // WAVE_FORMAT_EXTENSIBLE: the effective format is the first two bytes
    // of the SubFormat GUID at offset 24. Field recorders routinely write
    // 24-bit and 32-bit-float files this way.
    if format_tag == 0xFFFE && payload.len() >= 26 {
        format_tag = u16le(payload, 24);
    }
    Some(Fmt {
        format_tag,
        channels: u16le(payload, 2),
        sample_rate: u32le(payload, 4),
        bits_per_sample: u16le(payload, 14),
    })
}

/// The [MAX_SAMPLES] guard as a pure function, so it can be tested
/// without allocating a hundred-megabyte buffer.
fn too_long(n_frames: usize, sample_rate: u32) -> Option<WavError> {
    if n_frames <= MAX_SAMPLES {
        return None;
    }
    let per_min = (sample_rate as usize * 60).max(1);
    Some(WavError::TooLong {
        minutes: (n_frames / per_min) as u32,
        limit_minutes: (MAX_SAMPLES / per_min) as u32,
    })
}

/// Iterate RIFF chunks in `bytes`, returning (fmt, data payload).
fn scan_chunks(bytes: &[u8]) -> (Option<Fmt>, Option<&[u8]>) {
    let mut fmt = None;
    let mut data = None;
    let mut pos = 0usize;
    while pos + 8 <= bytes.len() {
        let id = &bytes[pos..pos + 4];
        let size = u32le(bytes, pos + 4) as usize;
        let start = pos + 8;
        let end = (start + size).min(bytes.len()); // clamp truncated final chunk
        match id {
            b"fmt " => fmt = parse_fmt(&bytes[start..end]),
            b"data" => {
                data = Some(&bytes[start..end]);
                break; // first data chunk wins
            }
            _ => {}
        }
        pos = end + (size & 1); // RIFF pads odd-sized chunks
    }
    (fmt, data)
}

/// Detect a header block duplicated at the start of the data payload
/// (record_windows writes a few junk bytes followed by a second
/// `fmt ` + `data` header). Returns the payload with it stripped.
fn strip_embedded_header(payload: &[u8]) -> &[u8] {
    let search = payload.len().min(8);
    let Some(k) = (0..search).find(|&k| payload[k..].starts_with(b"fmt ")) else {
        return payload;
    };
    // Parse the nested chunk stream; require it to yield a data chunk,
    // otherwise assume the bytes were coincidental sample data.
    let (fmt, data) = scan_chunks(&payload[k..]);
    match (fmt, data) {
        (Some(_), Some(inner)) => inner,
        _ => payload,
    }
}

impl WavData {
    pub fn parse(bytes: &[u8]) -> Result<WavData, WavError> {
        if bytes.len() < 12 || &bytes[0..4] != b"RIFF" || &bytes[8..12] != b"WAVE" {
            return Err(WavError::NotRiffWave);
        }
        let (fmt, data) = scan_chunks(&bytes[12..]);
        let fmt = fmt.ok_or(WavError::NoFmtChunk)?;
        let data = data.ok_or(WavError::NoDataChunk)?;
        if fmt.format_tag != 1 && fmt.format_tag != 3 {
            return Err(WavError::UnsupportedFormat(fmt.format_tag));
        }
        // Decoder per (format, depth); 32-bit float values are kept as-is
        // (they can legitimately exceed [-1, 1]; the analyses are amplitude
        // scale invariant and the quality report clamps its own dBFS math).
        let decode: fn(&[u8], usize) -> f64 = match (fmt.format_tag, fmt.bits_per_sample) {
            (1, 16) => |d, at| i16::from_le_bytes([d[at], d[at + 1]]) as f64 / 32768.0,
            (1, 24) => |d, at| {
                let v = ((d[at + 2] as i32) << 24 | (d[at + 1] as i32) << 16 | (d[at] as i32) << 8)
                    >> 8;
                v as f64 / 8_388_608.0
            },
            (1, 32) => |d, at| {
                i32::from_le_bytes([d[at], d[at + 1], d[at + 2], d[at + 3]]) as f64
                    / 2_147_483_648.0
            },
            (3, 32) => {
                |d, at| f32::from_le_bytes([d[at], d[at + 1], d[at + 2], d[at + 3]]) as f64
            }
            _ => return Err(WavError::UnsupportedBitDepth(fmt.bits_per_sample)),
        };
        if fmt.channels == 0 {
            return Err(WavError::ZeroChannels);
        }
        let data = strip_embedded_header(data);

        let ch = fmt.channels as usize;
        let bytes_per_sample = fmt.bits_per_sample as usize / 8;
        let frame_bytes = bytes_per_sample * ch;
        let n_frames = data.len() / frame_bytes;
        if let Some(e) = too_long(n_frames, fmt.sample_rate) {
            return Err(e);
        }
        let mut samples = Vec::with_capacity(n_frames);
        for i in 0..n_frames {
            let mut acc = 0.0f64;
            for c in 0..ch {
                acc += decode(data, i * frame_bytes + bytes_per_sample * c);
            }
            samples.push(acc / ch as f64);
        }
        Ok(WavData {
            sample_rate: fmt.sample_rate,
            channels: fmt.channels,
            samples,
        })
    }

    pub fn from_file(path: &str) -> Result<WavData, String> {
        let bytes = std::fs::read(path).map_err(|e| format!("{path}: {e}"))?;
        WavData::parse(&bytes).map_err(|e| format!("{path}: {e}"))
    }

    pub fn duration_s(&self) -> f64 {
        self.samples.len() as f64 / self.sample_rate as f64
    }
}

/// Write mono samples as a canonical 16-bit PCM WAV. Values are clamped
/// to [-1, 1] and rounded; used for extracting stretches of an already
/// 16-bit-domain recording, so no dither is applied.
pub fn write_wav_16(path: &str, samples: &[f64], sample_rate: u32) -> Result<(), String> {
    let data_len = (samples.len() * 2) as u32;
    let mut b = Vec::with_capacity(44 + samples.len() * 2);
    b.extend_from_slice(b"RIFF");
    b.extend_from_slice(&(36 + data_len).to_le_bytes());
    b.extend_from_slice(b"WAVE");
    b.extend_from_slice(b"fmt ");
    b.extend_from_slice(&16u32.to_le_bytes());
    b.extend_from_slice(&1u16.to_le_bytes()); // PCM
    b.extend_from_slice(&1u16.to_le_bytes()); // mono
    b.extend_from_slice(&sample_rate.to_le_bytes());
    b.extend_from_slice(&(sample_rate * 2).to_le_bytes());
    b.extend_from_slice(&2u16.to_le_bytes());
    b.extend_from_slice(&16u16.to_le_bytes());
    b.extend_from_slice(b"data");
    b.extend_from_slice(&data_len.to_le_bytes());
    for &s in samples {
        let v = (s.clamp(-1.0, 1.0) * 32767.0).round() as i16;
        b.extend_from_slice(&v.to_le_bytes());
    }
    std::fs::write(path, b).map_err(|e| format!("{path}: {e}"))
}

#[cfg(test)]
pub(crate) mod test_support {
    /// Build a canonical 16-bit PCM WAV file in memory.
    pub fn wav_bytes(sample_rate: u32, channels: u16, interleaved: &[i16]) -> Vec<u8> {
        let data_len = (interleaved.len() * 2) as u32;
        let byte_rate = sample_rate * channels as u32 * 2;
        let block_align = channels * 2;
        let mut b = Vec::new();
        b.extend_from_slice(b"RIFF");
        b.extend_from_slice(&(36 + data_len).to_le_bytes());
        b.extend_from_slice(b"WAVE");
        b.extend_from_slice(b"fmt ");
        b.extend_from_slice(&16u32.to_le_bytes());
        b.extend_from_slice(&1u16.to_le_bytes());
        b.extend_from_slice(&channels.to_le_bytes());
        b.extend_from_slice(&sample_rate.to_le_bytes());
        b.extend_from_slice(&byte_rate.to_le_bytes());
        b.extend_from_slice(&block_align.to_le_bytes());
        b.extend_from_slice(&16u16.to_le_bytes());
        b.extend_from_slice(b"data");
        b.extend_from_slice(&data_len.to_le_bytes());
        for s in interleaved {
            b.extend_from_slice(&s.to_le_bytes());
        }
        b
    }

    /// Build a WAV around an arbitrary fmt-chunk payload and raw data bytes.
    pub fn wav_bytes_raw(fmt_payload: &[u8], data: &[u8]) -> Vec<u8> {
        let mut b = Vec::new();
        b.extend_from_slice(b"RIFF");
        b.extend_from_slice(&((4 + 8 + fmt_payload.len() + 8 + data.len()) as u32).to_le_bytes());
        b.extend_from_slice(b"WAVE");
        b.extend_from_slice(b"fmt ");
        b.extend_from_slice(&(fmt_payload.len() as u32).to_le_bytes());
        b.extend_from_slice(fmt_payload);
        b.extend_from_slice(b"data");
        b.extend_from_slice(&(data.len() as u32).to_le_bytes());
        b.extend_from_slice(data);
        b
    }

    /// Minimal 16-byte fmt payload.
    pub fn fmt_payload(format_tag: u16, channels: u16, sample_rate: u32, bits: u16) -> Vec<u8> {
        let bytes = bits as u32 / 8;
        let mut p = Vec::new();
        p.extend_from_slice(&format_tag.to_le_bytes());
        p.extend_from_slice(&channels.to_le_bytes());
        p.extend_from_slice(&sample_rate.to_le_bytes());
        p.extend_from_slice(&(sample_rate * channels as u32 * bytes).to_le_bytes());
        p.extend_from_slice(&(channels * bytes as u16).to_le_bytes());
        p.extend_from_slice(&bits.to_le_bytes());
        p
    }
}

#[cfg(test)]
mod tests {
    use super::test_support::wav_bytes;
    use super::*;

    #[test]
    fn parses_canonical_mono() {
        let w = WavData::parse(&wav_bytes(44100, 1, &[0, 16384, -16384, 32767])).unwrap();
        assert_eq!(w.sample_rate, 44100);
        assert_eq!(w.channels, 1);
        assert_eq!(w.samples.len(), 4);
        assert!((w.samples[1] - 0.5).abs() < 1e-4);
        assert!((w.samples[2] + 0.5).abs() < 1e-4);
    }

    #[test]
    fn mixes_stereo_to_mono() {
        let w = WavData::parse(&wav_bytes(48000, 2, &[16384, -16384, 8192, 8192])).unwrap();
        assert_eq!(w.channels, 2);
        assert_eq!(w.samples.len(), 2);
        assert!(w.samples[0].abs() < 1e-4);
        assert!((w.samples[1] - 0.25).abs() < 1e-4);
    }

    #[test]
    fn skips_unknown_chunks() {
        let mut b = wav_bytes(22050, 1, &[100, 200]);
        // Splice a LIST chunk between fmt and data (fmt ends at byte 36).
        let mut spliced = b[..36].to_vec();
        spliced.extend_from_slice(b"LIST");
        spliced.extend_from_slice(&4u32.to_le_bytes());
        spliced.extend_from_slice(b"INFO");
        spliced.extend_from_slice(&b[36..]);
        b = spliced;
        let w = WavData::parse(&b).unwrap();
        assert_eq!(w.samples.len(), 2);
    }

    #[test]
    fn strips_record_windows_embedded_header() {
        // Real layout observed from record_windows 1.0.7: the outer data
        // payload starts with 2 junk bytes, then fmt + data headers again.
        let inner = wav_bytes(44100, 1, &[1000, 2000, 3000]);
        let embedded = &inner[12..]; // fmt..data+samples, no RIFF prefix
        let mut payload = vec![0u8, 0u8];
        payload.extend_from_slice(embedded);

        let mut b = Vec::new();
        b.extend_from_slice(b"RIFF");
        b.extend_from_slice(&((4 + 24 + 8 + payload.len()) as u32).to_le_bytes());
        b.extend_from_slice(b"WAVE");
        b.extend_from_slice(&inner[12..36]); // outer fmt chunk (8-byte header + 16 bytes)
        b.extend_from_slice(b"data");
        b.extend_from_slice(&(payload.len() as u32).to_le_bytes());
        b.extend_from_slice(&payload);

        let w = WavData::parse(&b).unwrap();
        assert_eq!(w.samples.len(), 3);
        assert!((w.samples[0] - 1000.0 / 32768.0).abs() < 1e-6);
    }

    #[test]
    fn clamps_truncated_data_chunk() {
        let mut b = wav_bytes(44100, 1, &[1, 2, 3, 4]);
        b.truncate(b.len() - 4); // drop last two samples
        let w = WavData::parse(&b).unwrap();
        assert_eq!(w.samples.len(), 2);
    }

    #[test]
    fn rejects_non_wav() {
        assert_eq!(
            WavData::parse(b"OggS\0\0\0\0\0\0\0\0\0\0\0\0").unwrap_err(),
            WavError::NotRiffWave
        );
    }

    #[test]
    fn rejects_unsupported_bit_depth() {
        let mut b = wav_bytes(44100, 1, &[1, 2]);
        b[34] = 8; // bits_per_sample lives at offset 34
        assert_eq!(
            WavData::parse(&b).unwrap_err(),
            WavError::UnsupportedBitDepth(8)
        );
    }

    use super::test_support::{fmt_payload, wav_bytes_raw};

    fn i24le(v: i32) -> [u8; 3] {
        let b = v.to_le_bytes();
        [b[0], b[1], b[2]]
    }

    #[test]
    fn parses_24bit_pcm() {
        let mut data = Vec::new();
        for v in [0i32, 4_194_304, -4_194_304, 8_388_607] {
            data.extend_from_slice(&i24le(v));
        }
        let w = WavData::parse(&wav_bytes_raw(&fmt_payload(1, 1, 48000, 24), &data)).unwrap();
        assert_eq!(w.samples.len(), 4);
        assert!((w.samples[1] - 0.5).abs() < 1e-6);
        assert!((w.samples[2] + 0.5).abs() < 1e-6);
        assert!((w.samples[3] - 1.0).abs() < 1e-4);
    }

    #[test]
    fn parses_32bit_pcm() {
        let mut data = Vec::new();
        for v in [0i32, 1 << 30, -(1 << 30)] {
            data.extend_from_slice(&v.to_le_bytes());
        }
        let w = WavData::parse(&wav_bytes_raw(&fmt_payload(1, 1, 44100, 32), &data)).unwrap();
        assert!((w.samples[1] - 0.5).abs() < 1e-9);
        assert!((w.samples[2] + 0.5).abs() < 1e-9);
    }

    #[test]
    fn parses_32bit_float() {
        let mut data = Vec::new();
        for v in [0.0f32, 0.5, -0.25, 1.5] {
            data.extend_from_slice(&v.to_le_bytes());
        }
        let w = WavData::parse(&wav_bytes_raw(&fmt_payload(3, 1, 48000, 32), &data)).unwrap();
        assert!((w.samples[1] - 0.5).abs() < 1e-7);
        assert!((w.samples[2] + 0.25).abs() < 1e-7);
        // Float files may exceed full scale; values pass through unclamped.
        assert!((w.samples[3] - 1.5).abs() < 1e-7);
    }

    #[test]
    fn parses_extensible_24bit_stereo() {
        // WAVE_FORMAT_EXTENSIBLE: tag 0xFFFE, effective tag in the
        // SubFormat GUID's first two bytes at offset 24.
        let mut p = fmt_payload(0xFFFE, 2, 48000, 24);
        p.extend_from_slice(&22u16.to_le_bytes()); // cbSize
        p.extend_from_slice(&24u16.to_le_bytes()); // valid bits
        p.extend_from_slice(&0u32.to_le_bytes()); // channel mask
        p.extend_from_slice(&1u16.to_le_bytes()); // sub-format: PCM
        p.extend_from_slice(&[0u8; 14]); // rest of the GUID
        let mut data = Vec::new();
        for v in [4_194_304i32, -4_194_304, 2_097_152, 2_097_152] {
            data.extend_from_slice(&i24le(v));
        }
        let w = WavData::parse(&wav_bytes_raw(&p, &data)).unwrap();
        assert_eq!(w.channels, 2);
        assert_eq!(w.samples.len(), 2);
        assert!(w.samples[0].abs() < 1e-6); // 0.5 and -0.5 mix to 0
        assert!((w.samples[1] - 0.25).abs() < 1e-6);
    }

    #[test]
    fn write_read_round_trip() {
        let dir = std::env::temp_dir().join("openphon_wav_rt");
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("rt.wav");
        let path = path.to_str().unwrap();
        let samples = [0.0, 0.5, -0.5, 1.0, -1.0, 1.5]; // 1.5 clamps to 1.0
        write_wav_16(path, &samples, 22050).unwrap();
        let w = WavData::from_file(path).unwrap();
        assert_eq!(w.sample_rate, 22050);
        assert_eq!(w.samples.len(), 6);
        for (got, want) in w.samples.iter().zip([0.0, 0.5, -0.5, 1.0, -1.0, 1.0]) {
            assert!((got - want).abs() < 1e-4, "{got} vs {want}");
        }
        std::fs::remove_file(path).ok();
    }

    #[test]
    fn length_guard_math() {
        assert!(too_long(MAX_SAMPLES, 48000).is_none());
        let e = too_long(48000 * 60 * 60, 48000).unwrap(); // one hour
        assert_eq!(
            e,
            WavError::TooLong {
                minutes: 60,
                limit_minutes: 34,
            }
        );
        let msg = e.to_string();
        assert!(msg.contains("60 min"), "{msg}");
        assert!(msg.contains("Trim"), "{msg}");
    }

    #[test]
    fn rejects_unknown_format_tag() {
        let b = wav_bytes_raw(&fmt_payload(85, 1, 44100, 16), &[0, 0]);
        assert_eq!(WavData::parse(&b).unwrap_err(), WavError::UnsupportedFormat(85));
    }
}
