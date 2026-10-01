//! The `measure` subcommand: per-interval and per-point measurement
//! recipes over an annotation, plus batch mode over a directory.
//!
//! The default interval columns are byte-identical to the app's in-app
//! "Export measurements" CSV; every extension below is opt-in via a flag
//! so existing pipelines never see a changed header:
//!
//!   --mid50          aggregate F0/intensity over the middle 50% of each
//!                    interval only (voweltarget practice: skips the
//!                    coarticulated edges); duration and the formant
//!                    midpoint are unaffected
//!   --contour        append F0 and intensity sampled at 20/50/80% of the
//!                    interval (rise/fall shape in three points)
//!   --moments        append spectral moments (CoG, SD, skewness, excess
//!                    kurtosis; fricative measures) computed over the
//!                    middle 50% of each interval — always the middle
//!                    50%, independent of --mid50, because moments of a
//!                    whole interval are dominated by its edges
//!   --join TIER      append the label of the interval in TIER containing
//!                    this interval's midpoint (phone rows carry their word)
//!   --rel-tier TIER  (point tiers) append the containing interval's label
//!                    in TIER and the distances from the point to that
//!                    interval's start/end boundaries (VOT-style measures)
//!
//! Batch: when the input is a directory, every *.wav in it with a sibling
//! TextGrid is measured with the same options; rows gain a leading `file`
//! column. Files that fail are reported on stderr and skipped.
//!
//! Manual pitch corrections: a sibling `<stem>.pitchedits.csv` written by
//! the app is applied to the F0 track before measuring, and the output
//! gains a final column counting edited frames (`f0_edited_frames` per
//! interval, `f0_edited` 0/1 per point). Without such a file the header is
//! unchanged. Edits made at other pitch settings are an error, because the
//! app would not apply them either; `--ignore-pitch-edits` measures the
//! automatic track.

use openphon_core::{formant, intensity, pitch, pitch_edits, spectral, textgrid, wav};
use std::fmt::Write as _;

use crate::{load_wav, parse_opts, Opts};

/// CSV-escape a label: quote when it contains a comma, quote, or newline.
fn csv_escape(s: &str) -> String {
    if s.contains(',') || s.contains('"') || s.contains('\n') {
        format!("\"{}\"", s.replace('"', "\"\""))
    } else {
        s.to_string()
    }
}

/// Nearest-frame value lookup; `None` when the track is empty.
fn nearest_idx(times: &[f64], t: f64) -> Option<usize> {
    (0..times.len()).min_by(|&a, &b| (times[a] - t).abs().total_cmp(&(times[b] - t).abs()))
}

/// Voiced F0 values on frames inside [t0, t1).
fn voiced_in(f0: &pitch::F0Track, t0: f64, t1: f64) -> Vec<f64> {
    f0.times_s
        .iter()
        .zip(&f0.f0_hz)
        .filter(|(t, f)| **t >= t0 && **t < t1 && **f > 0.0)
        .map(|(_, f)| *f)
        .collect()
}

/// Finite intensity values on frames inside [t0, t1).
fn db_in(int: &intensity::IntensityTrack, t0: f64, t1: f64) -> Vec<f64> {
    int.times_s
        .iter()
        .zip(&int.db)
        .filter(|(t, v)| **t >= t0 && **t < t1 && v.is_finite())
        .map(|(_, v)| *v)
        .collect()
}

fn mean(v: &[f64]) -> f64 {
    if v.is_empty() {
        0.0
    } else {
        v.iter().sum::<f64>() / v.len() as f64
    }
}

fn median(v: &mut [f64]) -> f64 {
    if v.is_empty() {
        0.0
    } else {
        v.sort_by(|a, b| a.total_cmp(b));
        v[v.len() / 2]
    }
}

/// The interval of `tier` containing time `t` ([xmin, xmax) except the
/// last interval, which is closed), if any.
fn containing_interval(tier: &textgrid::IntervalTier, t: f64) -> Option<&textgrid::Interval> {
    tier.intervals
        .iter()
        .find(|iv| (t >= iv.xmin && t < iv.xmax) || (t == iv.xmax && iv.xmax >= tier.xmax))
}

/// Applies the sibling `<stem>.pitchedits.csv` to `f0` unless `ignore`,
/// returning the edited-frame mask; `None` when there is no such file.
pub(crate) fn apply_sidecar_edits(
    wav_path: &str,
    params: &pitch::F0Params,
    ignore: bool,
    f0: &mut pitch::F0Track,
) -> Result<Option<Vec<bool>>, String> {
    let edits_path = pitch_edits::sidecar_path(wav_path);
    if ignore || !std::path::Path::new(&edits_path).exists() {
        return Ok(None);
    }
    let edits = pitch_edits::PitchEdits::parse_file(&edits_path)?;
    if !edits.matches(params) {
        return Err(format!(
            "{edits_path} was made at time step {} s, floor {} Hz, ceiling {} Hz; \
             use those settings or pass --ignore-pitch-edits",
            edits.time_step_s, edits.f0_min_hz, edits.f0_max_hz
        ));
    }
    Ok(Some(edits.apply(f0)))
}

/// Analysis tracks computed once per file.
struct Tracks {
    f0: pitch::F0Track,
    /// Per-frame mask of manually corrected F0 frames, when edits applied.
    f0_edited: Option<Vec<bool>>,
    int: intensity::IntensityTrack,
    fmn: formant::FormantTrack,
}

struct MeasureConfig {
    tier: Option<String>,
    all: bool,
    mid50: bool,
    contour: bool,
    moments: bool,
    join: Option<String>,
    rel_tier: Option<String>,
    pitch_params: pitch::F0Params,
    ignore_pitch_edits: bool,
}

/// One file's rows, before the optional edited-frames column is appended.
struct Measured {
    is_point: bool,
    rows: Vec<String>,
    /// Edited-frame count per row; `None` when no edits applied.
    edited: Option<Vec<usize>>,
}

impl Measured {
    /// Rows with the edited-frames column when `with_column`; files without
    /// edits then contribute 0.
    fn finish(self, with_column: bool) -> Vec<String> {
        if !with_column {
            return self.rows;
        }
        let counts = self.edited.unwrap_or_else(|| vec![0; self.rows.len()]);
        self.rows
            .into_iter()
            .zip(counts)
            .map(|(r, c)| format!("{r},{c}"))
            .collect()
    }
}
impl MeasureConfig {
    fn from_opts(opts: &Opts) -> Result<MeasureConfig, String> {
        let d = pitch::F0Params::default();
        Ok(MeasureConfig {
            tier: opts.flags.get("tier").cloned(),
            all: opts.has("all"),
            mid50: opts.has("mid50"),
            contour: opts.has("contour"),
            moments: opts.has("moments"),
            join: opts.flags.get("join").cloned(),
            rel_tier: opts.flags.get("rel-tier").cloned(),
            pitch_params: pitch::F0Params {
                time_step_s: opts.f64("step", d.time_step_s)?,
                f0_min_hz: opts.f64("floor", d.f0_min_hz)?,
                f0_max_hz: opts.f64("ceiling", d.f0_max_hz)?,
                ..d
            },
            ignore_pitch_edits: opts.has("ignore-pitch-edits"),
        })
    }

    fn header(&self, is_point: bool, edited: bool) -> String {
        let mut h = if is_point {
            self.point_header()
        } else {
            self.interval_header()
        };
        if edited {
            h.push_str(if is_point { ",f0_edited" } else { ",f0_edited_frames" });
        }
        h
    }

    fn interval_header(&self) -> String {
        let mut h = String::from(
            "tier,label,tmin_s,tmax_s,duration_s,mean_f0_hz,median_f0_hz,\
             f1_mid_hz,f2_mid_hz,f3_mid_hz,mean_intensity_db",
        );
        if self.contour {
            h.push_str(",f0_20_hz,f0_50_hz,f0_80_hz,int_20_db,int_50_db,int_80_db");
        }
        if self.moments {
            h.push_str(",cog_hz,spec_sd_hz,skewness,kurtosis");
        }
        if self.join.is_some() {
            h.push_str(",join_label");
        }
        h
    }

    fn point_header(&self) -> String {
        let mut h = String::from("tier,label,time_s,f0_hz,intensity_db,f1_hz,f2_hz,f3_hz");
        if self.rel_tier.is_some() {
            h.push_str(",rel_label,to_start_s,to_end_s");
        }
        h
    }
}

fn sibling_textgrid(wav_path: &str) -> Option<String> {
    let base = wav_path.trim_end_matches(".wav").trim_end_matches(".WAV");
    for ext in ["TextGrid", "textgrid"] {
        let p = format!("{base}.{ext}");
        if std::path::Path::new(&p).exists() {
            return Some(p);
        }
    }
    None
}

fn find_interval_tier<'a>(
    tg: &'a textgrid::TextGrid,
    name: &str,
    role: &str,
) -> Result<&'a textgrid::IntervalTier, String> {
    tg.tiers
        .iter()
        .find_map(|t| match t {
            textgrid::Tier::Interval(it) if it.name == name => Some(it),
            _ => None,
        })
        .ok_or(format!("no interval tier named \"{name}\" ({role})"))
}

/// Measurement rows (no header) for one WAV + TextGrid pair.
fn measure_file(
    wav_path: &str,
    grid_path: &str,
    cfg: &MeasureConfig,
) -> Result<Measured, String> {
    let tg = textgrid::parse_file(grid_path)?;

    enum Chosen<'a> {
        Interval(&'a textgrid::IntervalTier),
        Point(&'a textgrid::PointTier),
    }
    let chosen = match &cfg.tier {
        Some(name) => tg
            .tiers
            .iter()
            .find_map(|t| match t {
                textgrid::Tier::Interval(it) if &it.name == name => Some(Chosen::Interval(it)),
                textgrid::Tier::Point(pt) if &pt.name == name => Some(Chosen::Point(pt)),
                _ => None,
            })
            .ok_or(format!("no tier named \"{name}\" in {grid_path}"))?,
        None => tg
            .tiers
            .iter()
            .find_map(|t| match t {
                textgrid::Tier::Interval(it) => Some(Chosen::Interval(it)),
                _ => None,
            })
            .ok_or(format!("{grid_path} has no interval tier"))?,
    };

    let join_tier = match &cfg.join {
        Some(name) => Some(find_interval_tier(&tg, name, "--join")?),
        None => None,
    };
    let rel_tier = match &cfg.rel_tier {
        Some(name) => Some(find_interval_tier(&tg, name, "--rel-tier")?),
        None => None,
    };

    let w = load_wav(wav_path)?;
    let mut f0 = pitch::track_f0(&w.samples, w.sample_rate, &cfg.pitch_params);
    let f0_edited =
        apply_sidecar_edits(wav_path, &cfg.pitch_params, cfg.ignore_pitch_edits, &mut f0)?;
    let tracks = Tracks {
        f0,
        f0_edited,
        int: intensity::compute(&w.samples, w.sample_rate, &Default::default()),
        fmn: formant::track_formants(&w.samples, w.sample_rate, &Default::default()),
    };

    let (is_point, rows, edited) = match chosen {
        Chosen::Interval(it) => {
            let (rows, edited) = interval_rows(it, &w, &tracks, cfg, join_tier);
            (false, rows, edited)
        }
        Chosen::Point(pt) => {
            let (rows, edited) = point_rows(pt, &tracks, cfg, rel_tier);
            (true, rows, edited)
        }
    };
    Ok(Measured {
        is_point,
        rows,
        edited: tracks.f0_edited.as_ref().map(|_| edited),
    })
}

/// Manually corrected frames inside [t0, t1).
fn edited_in(tracks: &Tracks, t0: f64, t1: f64) -> usize {
    let Some(mask) = &tracks.f0_edited else {
        return 0;
    };
    tracks
        .f0
        .times_s
        .iter()
        .zip(mask)
        .filter(|(t, e)| **e && **t >= t0 && **t < t1)
        .count()
}

fn interval_rows(
    tier: &textgrid::IntervalTier,
    wav: &wav::WavData,
    tracks: &Tracks,
    cfg: &MeasureConfig,
    join_tier: Option<&textgrid::IntervalTier>,
) -> (Vec<String>, Vec<usize>) {
    let mut rows = Vec::new();
    let mut edited = Vec::new();
    for iv in &tier.intervals {
        if iv.text.is_empty() && !cfg.all {
            continue;
        }
        let dur = iv.xmax - iv.xmin;
        // Aggregation window: whole interval, or its middle 50%.
        let (a0, a1) = if cfg.mid50 {
            (iv.xmin + 0.25 * dur, iv.xmin + 0.75 * dur)
        } else {
            (iv.xmin, iv.xmax)
        };
        edited.push(edited_in(tracks, a0, a1));
        let mut voiced = voiced_in(&tracks.f0, a0, a1);
        let mean_f0 = mean(&voiced);
        let median_f0 = median(&mut voiced);
        let mean_db = mean(&db_in(&tracks.int, a0, a1));

        let mid = 0.5 * (iv.xmin + iv.xmax);
        let mut f_mid = [0.0f64; 3];
        if let Some(frame) = tracks
            .fmn
            .frames
            .iter()
            .min_by(|a, b| (a.time_s - mid).abs().total_cmp(&(b.time_s - mid).abs()))
        {
            for (slot, val) in f_mid.iter_mut().zip(&frame.formants_hz) {
                *slot = *val;
            }
        }

        let mut row = format!(
            "{},{},{:.6},{:.6},{:.6},{:.3},{:.3},{:.3},{:.3},{:.3},{:.3}",
            csv_escape(&tier.name),
            csv_escape(&iv.text),
            iv.xmin,
            iv.xmax,
            dur,
            mean_f0,
            median_f0,
            f_mid[0],
            f_mid[1],
            f_mid[2],
            mean_db
        );
        if cfg.contour {
            for frac in [0.2, 0.5, 0.8] {
                let t = iv.xmin + frac * dur;
                let f = nearest_idx(&tracks.f0.times_s, t).map_or(0.0, |i| tracks.f0.f0_hz[i]);
                write!(row, ",{f:.3}").unwrap();
            }
            for frac in [0.2, 0.5, 0.8] {
                let t = iv.xmin + frac * dur;
                let v = nearest_idx(&tracks.int.times_s, t).map_or(0.0, |i| tracks.int.db[i]);
                let v = if v.is_finite() { v } else { 0.0 };
                write!(row, ",{v:.3}").unwrap();
            }
        }
        if cfg.moments {
            // Always the interval's middle 50%: moments over the whole
            // interval are dominated by boundary transitions.
            let sr = wav.sample_rate as f64;
            let i0 = ((iv.xmin + 0.25 * dur) * sr).round().max(0.0) as usize;
            let i1 = (((iv.xmin + 0.75 * dur) * sr).round() as usize).min(wav.samples.len());
            let m = if i1 > i0 {
                spectral::moments(&wav.samples[i0..i1], wav.sample_rate)
            } else {
                None
            };
            match m {
                Some(m) => write!(
                    row,
                    ",{:.3},{:.3},{:.4},{:.4}",
                    m.cog_hz, m.sd_hz, m.skewness, m.kurtosis
                )
                .unwrap(),
                None => row.push_str(",0,0,0,0"),
            }
        }
        if let Some(jt) = join_tier {
            let label = containing_interval(jt, mid).map_or("", |j| j.text.as_str());
            write!(row, ",{}", csv_escape(label)).unwrap();
        }
        rows.push(row);
    }
    (rows, edited)
}

fn point_rows(
    tier: &textgrid::PointTier,
    tracks: &Tracks,
    cfg: &MeasureConfig,
    rel_tier: Option<&textgrid::IntervalTier>,
) -> (Vec<String>, Vec<usize>) {
    let mut rows = Vec::new();
    let mut edited = Vec::new();
    for point in &tier.points {
        if point.mark.is_empty() && !cfg.all {
            continue;
        }
        let fi = nearest_idx(&tracks.f0.times_s, point.time);
        let f = fi.map_or(0.0, |i| tracks.f0.f0_hz[i]);
        edited.push(match (&tracks.f0_edited, fi) {
            (Some(mask), Some(i)) => usize::from(mask[i]),
            _ => 0,
        });
        let db = nearest_idx(&tracks.int.times_s, point.time).map_or(0.0, |i| tracks.int.db[i]);
        let db = if db.is_finite() { db } else { 0.0 };
        let mut fs = [0.0f64; 3];
        if let Some(frame) = tracks.fmn.frames.iter().min_by(|a, b| {
            (a.time_s - point.time)
                .abs()
                .total_cmp(&(b.time_s - point.time).abs())
        }) {
            for (slot, val) in fs.iter_mut().zip(&frame.formants_hz) {
                *slot = *val;
            }
        }
        let mut row = format!(
            "{},{},{:.6},{:.3},{:.3},{:.3},{:.3},{:.3}",
            csv_escape(&tier.name),
            csv_escape(&point.mark),
            point.time,
            f,
            db,
            fs[0],
            fs[1],
            fs[2]
        );
        if let Some(rt) = rel_tier {
            match containing_interval(rt, point.time) {
                Some(iv) => write!(
                    row,
                    ",{},{:.6},{:.6}",
                    csv_escape(&iv.text),
                    point.time - iv.xmin,
                    iv.xmax - point.time
                )
                .unwrap(),
                // No containing interval: label and distances stay empty
                // (0.0 would read as a legitimate zero distance).
                None => row.push_str(",,,"),
            }
        }
        rows.push(row);
    }
    (rows, edited)
}

pub fn measure_cmd(args: &[String]) -> Result<(), String> {
    let opts = parse_opts(
        args,
        &[
            "out", "textgrid", "tier", "step", "floor", "ceiling", "join", "rel-tier",
        ],
        &["all", "mid50", "contour", "moments", "ignore-pitch-edits"],
    )?;
    let cfg = MeasureConfig::from_opts(&opts)?;

    if std::path::Path::new(&opts.file).is_dir() {
        return batch(&opts, &cfg);
    }

    let grid_path = match opts.flags.get("textgrid") {
        Some(p) => p.clone(),
        None => sibling_textgrid(&opts.file).ok_or(format!(
            "no sibling TextGrid for {}; pass --textgrid FILE",
            opts.file
        ))?,
    };
    let m = measure_file(&opts.file, &grid_path, &cfg)?;
    let with_column = m.edited.is_some();
    let mut csv = cfg.header(m.is_point, with_column);
    csv.push('\n');
    for r in m.finish(with_column) {
        csv.push_str(&r);
        csv.push('\n');
    }
    opts.emit(&csv)
}

/// Every *.wav in the directory with a sibling TextGrid, measured with the
/// same options; rows gain a leading `file` column. `--textgrid` makes no
/// sense here and is rejected; failures are reported and skipped so one
/// bad file never loses a whole corpus run.
fn batch(opts: &Opts, cfg: &MeasureConfig) -> Result<(), String> {
    if opts.flags.contains_key("textgrid") {
        return Err("--textgrid cannot be combined with a directory input".into());
    }
    let mut wavs: Vec<std::path::PathBuf> = std::fs::read_dir(&opts.file)
        .map_err(|e| format!("{}: {e}", opts.file))?
        .filter_map(|e| e.ok())
        .map(|e| e.path())
        .filter(|p| {
            p.extension()
                .and_then(|x| x.to_str())
                .is_some_and(|x| x.eq_ignore_ascii_case("wav"))
        })
        .collect();
    wavs.sort();

    let mut kind: Option<bool> = None;
    let mut results: Vec<(String, Measured)> = Vec::new();
    for wav_path in &wavs {
        let wav_str = wav_path.to_string_lossy().to_string();
        let Some(grid_path) = sibling_textgrid(&wav_str) else {
            continue; // un-annotated audio is expected in a corpus dir
        };
        let name = wav_path
            .file_name()
            .map(|n| n.to_string_lossy().to_string())
            .unwrap_or(wav_str.clone());
        match measure_file(&wav_str, &grid_path, cfg) {
            Ok(m) => {
                match kind {
                    None => kind = Some(m.is_point),
                    Some(prev) if prev != m.is_point => {
                        eprintln!(
                            "skipping {name}: its tier kind produces different \
                             columns than earlier files"
                        );
                        continue;
                    }
                    Some(_) => {}
                }
                results.push((name, m));
            }
            Err(e) => eprintln!("skipping {name}: {e}"),
        }
    }
    let is_point = kind.ok_or("no WAV with a sibling TextGrid found in the directory")?;
    let with_column = results.iter().any(|(_, m)| m.edited.is_some());
    let mut csv = format!("file,{}\n", cfg.header(is_point, with_column));
    let measured = results.len();
    for (name, m) in results {
        for r in m.finish(with_column) {
            csv.push_str(&format!("{},{r}\n", csv_escape(&name)));
        }
    }
    eprintln!("measured {measured} file(s)");
    opts.emit(&csv)
}

#[cfg(test)]
mod tests {
    use super::*;
    use openphon_core::textgrid::{Interval, IntervalTier};

    fn tier() -> IntervalTier {
        IntervalTier {
            name: "words".into(),
            xmin: 0.0,
            xmax: 1.0,
            intervals: vec![
                Interval {
                    xmin: 0.0,
                    xmax: 0.4,
                    text: "casa".into(),
                },
                Interval {
                    xmin: 0.4,
                    xmax: 1.0,
                    text: "sol".into(),
                },
            ],
        }
    }

    #[test]
    fn containing_interval_uses_half_open_intervals() {
        let t = tier();
        assert_eq!(containing_interval(&t, 0.0).unwrap().text, "casa");
        assert_eq!(containing_interval(&t, 0.4).unwrap().text, "sol");
        // The tier's end time belongs to the last interval.
        assert_eq!(containing_interval(&t, 1.0).unwrap().text, "sol");
        assert!(containing_interval(&t, 1.5).is_none());
    }

    #[test]
    fn mean_and_median_of_empty_are_zero() {
        assert_eq!(mean(&[]), 0.0);
        assert_eq!(median(&mut []), 0.0);
        assert_eq!(mean(&[2.0, 4.0]), 3.0);
        assert_eq!(median(&mut [5.0, 1.0, 3.0]), 3.0);
    }

    #[test]
    fn nearest_idx_picks_closest_frame() {
        let times = [0.0, 0.1, 0.2];
        assert_eq!(nearest_idx(&times, 0.14), Some(1));
        assert_eq!(nearest_idx(&times, 0.19), Some(2));
        assert_eq!(nearest_idx(&[], 0.1), None);
    }

    #[test]
    fn headers_grow_only_with_flags() {
        let base = MeasureConfig {
            tier: None,
            all: false,
            mid50: false,
            contour: false,
            moments: false,
            join: None,
            rel_tier: None,
            pitch_params: Default::default(),
            ignore_pitch_edits: false,
        };
        assert_eq!(
            base.interval_header(),
            "tier,label,tmin_s,tmax_s,duration_s,mean_f0_hz,median_f0_hz,\
             f1_mid_hz,f2_mid_hz,f3_mid_hz,mean_intensity_db"
        );
        assert_eq!(base.header(false, false), base.interval_header());
        assert!(base.header(false, true).ends_with(",mean_intensity_db,f0_edited_frames"));
        assert!(base.header(true, true).ends_with(",f3_hz,f0_edited"));
        let full = MeasureConfig {
            contour: true,
            moments: true,
            join: Some("words".into()),
            rel_tier: Some("words".into()),
            ..base
        };
        assert!(full.interval_header().ends_with(
            ",f0_20_hz,f0_50_hz,f0_80_hz,int_20_db,int_50_db,int_80_db,\
             cog_hz,spec_sd_hz,skewness,kurtosis,join_label"
        ));
        assert!(full.point_header().ends_with(",rel_label,to_start_s,to_end_s"));
    }

    #[test]
    fn sidecar_edits_apply_only_at_their_settings() {
        let dir = std::env::temp_dir().join(format!("openphon-edits-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let wav = dir.join("take.wav").to_string_lossy().into_owned();
        let params = pitch::F0Params::default();
        let track = || pitch::F0Track {
            times_s: vec![0.01, 0.02, 0.03],
            f0_hz: vec![200.0, 400.0, 200.0],
        };
        let mut f0 = track();
        assert_eq!(apply_sidecar_edits(&wav, &params, false, &mut f0), Ok(None));
        std::fs::write(
            pitch_edits::sidecar_path(&wav),
            "# openphon pitch edits 1; time_step_s=0.01; f0_min_hz=75; f0_max_hz=600\n\
             time_s,f0_hz\n0.020000,200.000\n",
        )
        .unwrap();
        let mask = apply_sidecar_edits(&wav, &params, false, &mut f0).unwrap();
        assert_eq!(mask, Some(vec![false, true, false]));
        assert_eq!(f0.f0_hz, vec![200.0, 200.0, 200.0]);
        let mut f0 = track();
        assert_eq!(apply_sidecar_edits(&wav, &params, true, &mut f0), Ok(None));
        assert_eq!(f0.f0_hz[1], 400.0);
        let other = pitch::F0Params {
            f0_max_hz: 500.0,
            ..params
        };
        let err = apply_sidecar_edits(&wav, &other, false, &mut f0).unwrap_err();
        assert!(err.contains("--ignore-pitch-edits"), "{err}");
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn rows_gain_the_edited_column_only_when_asked() {
        let m = || Measured {
            is_point: false,
            rows: vec!["a".into(), "b".into()],
            edited: None,
        };
        assert_eq!(m().finish(false), vec!["a", "b"]);
        assert_eq!(m().finish(true), vec!["a,0", "b,0"]);
        let e = Measured {
            edited: Some(vec![3, 0]),
            ..m()
        };
        assert_eq!(e.finish(true), vec!["a,3", "b,0"]);
    }
}
