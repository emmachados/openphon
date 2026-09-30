//! FFI surface for the app. Thin delegation to `openphon_core`; no DSP here.
//!
//! Analysis functions are async (they run on the bridge worker pool) so a
//! long file never blocks the Dart UI isolate.

use openphon_core::{
    formant, intensity, pitch, pitch_edits, quality, spectrogram, textgrid, voice_quality, wav,
    waveform,
};

#[flutter_rust_bridge::frb(sync)]
pub fn core_version() -> String {
    openphon_core::core_version()
}

#[flutter_rust_bridge::frb(sync)]
pub fn echo(input: String) -> String {
    openphon_core::echo(input)
}

pub struct WavInfo {
    pub sample_rate: u32,
    pub channels: u16,
    pub n_samples: u64,
    pub duration_s: f64,
}

pub fn wav_info(path: String) -> Result<WavInfo, String> {
    let w = wav::WavData::from_file(&path)?;
    Ok(WavInfo {
        sample_rate: w.sample_rate,
        channels: w.channels,
        n_samples: w.samples.len() as u64,
        duration_s: w.duration_s(),
    })
}

pub struct QualityData {
    /// Highest sample magnitude, dB re full scale (<= 0; -120 = silence).
    pub peak_dbfs: f64,
    /// Percentage of samples at or above one step below full scale.
    pub clipped_pct: f64,
    /// Percentile-based SNR estimate in dB; None for silent/too-short files.
    pub est_snr_db: Option<f64>,
}

pub fn wav_quality(path: String) -> Result<QualityData, String> {
    let w = wav::WavData::from_file(&path)?;
    let r = quality::assess(&w.samples, w.sample_rate);
    Ok(QualityData {
        peak_dbfs: r.peak_dbfs,
        clipped_pct: r.clipped_pct,
        est_snr_db: r.est_snr_db,
    })
}

pub struct VoiceReportData {
    /// Mean harmonics-to-noise ratio over voiced frames, dB; None if none.
    pub mean_hnr_db: Option<f64>,
    pub n_periods: u64,
    /// Jitter (local); None with too few period pairs.
    pub jitter_local: Option<f64>,
    /// Shimmer (local); None with too few pulses.
    pub shimmer_local: Option<f64>,
    /// Median / mean / SD of F0 over voiced frames, Hz.
    pub median_f0_hz: Option<f64>,
    pub mean_f0_hz: Option<f64>,
    pub sd_f0_hz: Option<f64>,
}

fn voice_report_data(r: voice_quality::VoiceReport) -> VoiceReportData {
    VoiceReportData {
        mean_hnr_db: r.mean_hnr_db,
        n_periods: r.n_periods as u64,
        jitter_local: r.jitter_local,
        shimmer_local: r.shimmer_local,
        median_f0_hz: r.median_f0_hz,
        mean_f0_hz: r.mean_f0_hz,
        sd_f0_hz: r.sd_f0_hz,
    }
}

pub fn voice_report(
    path: String,
    f0_min_hz: f64,
    f0_max_hz: f64,
) -> Result<VoiceReportData, String> {
    let w = wav::WavData::from_file(&path)?;
    let d = pitch::F0Params::default();
    let r = voice_quality::analyze(
        &w.samples,
        w.sample_rate,
        &pitch::F0Params {
            f0_min_hz,
            f0_max_hz,
            ..d
        },
    );
    Ok(voice_report_data(r))
}

pub struct F0TrackData {
    pub times_s: Vec<f64>,
    /// F0 in Hz; 0.0 marks an unvoiced frame.
    pub f0_hz: Vec<f64>,
}

pub fn f0_track(
    path: String,
    time_step_s: f64,
    f0_min_hz: f64,
    f0_max_hz: f64,
) -> Result<F0TrackData, String> {
    let w = wav::WavData::from_file(&path)?;
    let t = pitch::track_f0(
        &w.samples,
        w.sample_rate,
        &pitch::F0Params {
            time_step_s,
            f0_min_hz,
            f0_max_hz,
            ..Default::default()
        },
    );
    Ok(F0TrackData {
        times_s: t.times_s,
        f0_hz: t.f0_hz,
    })
}

/// F0 path plus each frame's voiced candidates, for manual correction.
pub struct F0CandidatesData {
    pub times_s: Vec<f64>,
    /// Selected path; 0.0 marks an unvoiced frame.
    pub f0_hz: Vec<f64>,
    /// Row-major, `max_candidates` per frame, cheapest first; 0.0 pads.
    pub candidates_hz: Vec<f64>,
    pub max_candidates: u32,
}

/// Manual F0 corrections as stored in `<stem>.pitchedits.csv`.
pub struct PitchEditsData {
    pub time_step_s: f64,
    pub f0_min_hz: f64,
    pub f0_max_hz: f64,
    pub times_s: Vec<f64>,
    /// 0.0 marks a frame set to unvoiced.
    pub f0_hz: Vec<f64>,
}

#[flutter_rust_bridge::frb(sync)]
pub fn pitch_edits_path(wav_path: String) -> String {
    pitch_edits::sidecar_path(&wav_path)
}

#[flutter_rust_bridge::frb(sync)]
pub fn parse_pitch_edits(text: String) -> Result<PitchEditsData, String> {
    let e = pitch_edits::PitchEdits::parse(&text)?;
    Ok(PitchEditsData {
        time_step_s: e.time_step_s,
        f0_min_hz: e.f0_min_hz,
        f0_max_hz: e.f0_max_hz,
        times_s: e.times_s,
        f0_hz: e.f0_hz,
    })
}

#[flutter_rust_bridge::frb(sync)]
pub fn format_pitch_edits(data: PitchEditsData) -> String {
    pitch_edits::PitchEdits {
        time_step_s: data.time_step_s,
        f0_min_hz: data.f0_min_hz,
        f0_max_hz: data.f0_max_hz,
        times_s: data.times_s,
        f0_hz: data.f0_hz,
    }
    .to_text()
}

pub struct IntensityTrackData {
    pub times_s: Vec<f64>,
    pub db: Vec<f64>,
}

pub fn intensity_track(
    path: String,
    time_step_s: f64,
    min_pitch_hz: f64,
) -> Result<IntensityTrackData, String> {
    let w = wav::WavData::from_file(&path)?;
    let t = intensity::compute(
        &w.samples,
        w.sample_rate,
        &intensity::IntensityParams {
            min_pitch_hz,
            time_step_s,
        },
    );
    Ok(IntensityTrackData {
        times_s: t.times_s,
        db: t.db,
    })
}

pub struct SpectrogramData {
    pub n_frames: u32,
    pub n_bins: u32,
    pub first_time_s: f64,
    pub time_step_s: f64,
    pub freq_step_hz: f64,
    /// Power in dB, frame-major: `values_db[frame * n_bins + bin]`.
    pub values_db: Vec<f32>,
}

pub fn compute_spectrogram(
    path: String,
    window_s: f64,
    time_step_s: f64,
    max_freq_hz: f64,
    pre_emphasis_hz: f64,
) -> Result<SpectrogramData, String> {
    let w = wav::WavData::from_file(&path)?;
    let sg = spectrogram::compute(
        &w.samples,
        w.sample_rate,
        &spectrogram::SpectrogramParams {
            window_s,
            time_step_s,
            max_freq_hz,
            pre_emphasis_hz,
            window: spectrogram::WindowShape::Gaussian,
        },
    );
    Ok(spectrogram_to_data(sg))
}

fn spectrogram_to_data(sg: spectrogram::Spectrogram) -> SpectrogramData {
    SpectrogramData {
        n_frames: sg.n_frames as u32,
        n_bins: sg.n_bins as u32,
        first_time_s: sg.first_time_s,
        time_step_s: sg.time_step_s,
        freq_step_hz: sg.freq_step_hz,
        values_db: sg.values_db,
    }
}

pub struct FormantTrackData {
    pub times_s: Vec<f64>,
    pub max_formants: u32,
    /// Frame-major matrix `[frame * max_formants + i]`; 0.0 = no formant.
    pub formants_hz: Vec<f64>,
    /// Same layout as `formants_hz`.
    pub bandwidths_hz: Vec<f64>,
}

pub fn formant_track(
    path: String,
    time_step_s: f64,
    max_formants: u32,
    ceiling_hz: f64,
) -> Result<FormantTrackData, String> {
    let w = wav::WavData::from_file(&path)?;
    let t = formant::track_formants(
        &w.samples,
        w.sample_rate,
        &formant::FormantParams {
            time_step_s,
            max_formants: max_formants as usize,
            ceiling_hz,
            ..Default::default()
        },
    );
    Ok(formant_to_data(t, max_formants))
}

fn formant_to_data(t: formant::FormantTrack, max_formants: u32) -> FormantTrackData {
    let n = max_formants as usize;
    let mut times_s = Vec::with_capacity(t.frames.len());
    let mut formants_hz = vec![0.0; t.frames.len() * n];
    let mut bandwidths_hz = vec![0.0; t.frames.len() * n];
    for (fi, fr) in t.frames.iter().enumerate() {
        times_s.push(fr.time_s);
        for (i, (&f, &b)) in fr.formants_hz.iter().zip(&fr.bandwidths_hz).enumerate() {
            formants_hz[fi * n + i] = f;
            bandwidths_hz[fi * n + i] = b;
        }
    }
    FormantTrackData {
        times_s,
        max_formants,
        formants_hz,
        bandwidths_hz,
    }
}

pub struct WaveformEnvelope {
    /// Per-bucket minima; same length as `max`.
    pub min: Vec<f32>,
    pub max: Vec<f32>,
}

/// A WAV loaded once into memory; analysis methods reuse the samples so
/// interactive viewport queries never re-read or re-parse the file.
#[flutter_rust_bridge::frb(opaque)]
pub struct Sound {
    wav: wav::WavData,
}

impl Sound {
    pub fn load(path: String) -> Result<Sound, String> {
        Ok(Sound {
            wav: wav::WavData::from_file(&path)?,
        })
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn sample_rate(&self) -> u32 {
        self.wav.sample_rate
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn duration_s(&self) -> f64 {
        self.wav.duration_s()
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn channels(&self) -> u16 {
        self.wav.channels
    }

    pub fn envelope(&self, t0_s: f64, t1_s: f64, n_buckets: u32) -> WaveformEnvelope {
        let (min, max) = waveform::min_max_envelope(
            &self.wav.samples,
            self.wav.sample_rate,
            t0_s,
            t1_s,
            n_buckets as usize,
        );
        WaveformEnvelope { min, max }
    }

    pub fn spectrogram_range(
        &self,
        t0_s: f64,
        t1_s: f64,
        window_s: f64,
        time_step_s: f64,
        max_freq_hz: f64,
        pre_emphasis_hz: f64,
    ) -> SpectrogramData {
        let sg = spectrogram::compute_range(
            &self.wav.samples,
            self.wav.sample_rate,
            &spectrogram::SpectrogramParams {
                window_s,
                time_step_s,
                max_freq_hz,
                pre_emphasis_hz,
                window: spectrogram::WindowShape::Gaussian,
            },
            t0_s,
            t1_s,
        );
        spectrogram_to_data(sg)
    }

    pub fn f0(&self, time_step_s: f64, f0_min_hz: f64, f0_max_hz: f64) -> F0TrackData {
        let t = pitch::track_f0(
            &self.wav.samples,
            self.wav.sample_rate,
            &pitch::F0Params {
                time_step_s,
                f0_min_hz,
                f0_max_hz,
                ..Default::default()
            },
        );
        F0TrackData {
            times_s: t.times_s,
            f0_hz: t.f0_hz,
        }
    }

    pub fn f0_candidates(
        &self,
        time_step_s: f64,
        f0_min_hz: f64,
        f0_max_hz: f64,
    ) -> F0CandidatesData {
        let c = pitch::track_f0_candidates(
            &self.wav.samples,
            self.wav.sample_rate,
            &pitch::F0Params {
                time_step_s,
                f0_min_hz,
                f0_max_hz,
                ..Default::default()
            },
        );
        let k = pitch::MAX_VOICED_CANDIDATES;
        let mut flat = vec![0.0; c.times_s.len() * k];
        for (i, cands) in c.candidates_hz.iter().enumerate() {
            flat[i * k..i * k + cands.len()].copy_from_slice(cands);
        }
        F0CandidatesData {
            times_s: c.times_s,
            f0_hz: c.f0_hz,
            candidates_hz: flat,
            max_candidates: k as u32,
        }
    }

    pub fn intensity(&self, time_step_s: f64, min_pitch_hz: f64) -> IntensityTrackData {
        let t = intensity::compute(
            &self.wav.samples,
            self.wav.sample_rate,
            &intensity::IntensityParams {
                min_pitch_hz,
                time_step_s,
            },
        );
        IntensityTrackData {
            times_s: t.times_s,
            db: t.db,
        }
    }

    /// Voice report over `[t0_s, t1_s]` (clamped to the file). An empty or
    /// inverted range yields an empty report rather than an error, so the
    /// UI can treat "nothing analyzable" uniformly with "too short".
    pub fn voice_report(
        &self,
        t0_s: f64,
        t1_s: f64,
        f0_min_hz: f64,
        f0_max_hz: f64,
    ) -> VoiceReportData {
        let sr = self.wav.sample_rate as f64;
        let n = self.wav.samples.len();
        let i0 = ((t0_s * sr).round().max(0.0) as usize).min(n);
        let i1 = ((t1_s * sr).round().max(0.0) as usize).min(n);
        if i1 <= i0 {
            return VoiceReportData {
                mean_hnr_db: None,
                n_periods: 0,
                jitter_local: None,
                shimmer_local: None,
                median_f0_hz: None,
                mean_f0_hz: None,
                sd_f0_hz: None,
            };
        }
        let d = pitch::F0Params::default();
        let r = voice_quality::analyze(
            &self.wav.samples[i0..i1],
            self.wav.sample_rate,
            &pitch::F0Params {
                f0_min_hz,
                f0_max_hz,
                ..d
            },
        );
        voice_report_data(r)
    }

    /// Write `[t0_s, t1_s]` (clamped) as a 16-bit mono WAV at `path` —
    /// Praat's "extract selection", for building stimuli and examples.
    pub fn export_range_wav(&self, t0_s: f64, t1_s: f64, path: String) -> Result<(), String> {
        let sr = self.wav.sample_rate as f64;
        let n = self.wav.samples.len();
        let i0 = ((t0_s * sr).round().max(0.0) as usize).min(n);
        let i1 = ((t1_s * sr).round().max(0.0) as usize).min(n);
        if i1 <= i0 {
            return Err("empty selection".into());
        }
        wav::write_wav_16(&path, &self.wav.samples[i0..i1], self.wav.sample_rate)
    }

    pub fn formants(&self, time_step_s: f64, max_formants: u32, ceiling_hz: f64) -> FormantTrackData {
        let t = formant::track_formants(
            &self.wav.samples,
            self.wav.sample_rate,
            &formant::FormantParams {
                time_step_s,
                max_formants: max_formants as usize,
                ceiling_hz,
                ..Default::default()
            },
        );
        formant_to_data(t, max_formants)
    }
}

/// One annotation tier, flattened for the bridge. For interval tiers,
/// `xmins`/`xmaxs`/`texts` run in parallel; for point tiers `xmins` holds
/// the point times and `xmaxs` is empty.
pub struct TextGridTierData {
    pub is_point: bool,
    pub name: String,
    pub xmin: f64,
    pub xmax: f64,
    pub xmins: Vec<f64>,
    pub xmaxs: Vec<f64>,
    pub texts: Vec<String>,
}

pub struct TextGridData {
    pub xmin: f64,
    pub xmax: f64,
    pub tiers: Vec<TextGridTierData>,
}

pub fn read_text_grid(path: String) -> Result<TextGridData, String> {
    let g = textgrid::parse_file(&path)?;
    Ok(TextGridData {
        xmin: g.xmin,
        xmax: g.xmax,
        tiers: g
            .tiers
            .into_iter()
            .map(|tier| match tier {
                textgrid::Tier::Interval(t) => TextGridTierData {
                    is_point: false,
                    name: t.name,
                    xmin: t.xmin,
                    xmax: t.xmax,
                    xmins: t.intervals.iter().map(|i| i.xmin).collect(),
                    xmaxs: t.intervals.iter().map(|i| i.xmax).collect(),
                    texts: t.intervals.into_iter().map(|i| i.text).collect(),
                },
                textgrid::Tier::Point(t) => TextGridTierData {
                    is_point: true,
                    name: t.name,
                    xmin: t.xmin,
                    xmax: t.xmax,
                    xmins: t.points.iter().map(|p| p.time).collect(),
                    xmaxs: Vec::new(),
                    texts: t.points.into_iter().map(|p| p.mark).collect(),
                },
            })
            .collect(),
    })
}

pub fn write_text_grid(path: String, data: TextGridData) -> Result<(), String> {
    let grid = textgrid::TextGrid {
        xmin: data.xmin,
        xmax: data.xmax,
        tiers: data
            .tiers
            .into_iter()
            .map(|t| {
                if t.is_point {
                    textgrid::Tier::Point(textgrid::PointTier {
                        name: t.name,
                        xmin: t.xmin,
                        xmax: t.xmax,
                        points: t
                            .xmins
                            .iter()
                            .zip(t.texts)
                            .map(|(&time, mark)| textgrid::Point { time, mark })
                            .collect(),
                    })
                } else {
                    textgrid::Tier::Interval(textgrid::IntervalTier {
                        name: t.name,
                        xmin: t.xmin,
                        xmax: t.xmax,
                        intervals: t
                            .xmins
                            .iter()
                            .zip(&t.xmaxs)
                            .zip(t.texts)
                            .map(|((&xmin, &xmax), text)| textgrid::Interval {
                                xmin,
                                xmax,
                                text,
                            })
                            .collect(),
                    })
                }
            })
            .collect(),
    };
    textgrid::write_file(&path, &grid)
}

#[flutter_rust_bridge::frb(init)]
pub fn init_app() {
    flutter_rust_bridge::setup_default_user_utils();
}
