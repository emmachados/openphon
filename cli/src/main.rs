//! openphon-cli: the app's validated DSP core behind a scriptable interface.
//!
//! Subcommands mirror the analyses of the app (identical defaults, same
//! code), writing CSV to stdout or `--out FILE` so shell loops and R/Python
//! pipelines can consume them without Praat.

mod measure;

use openphon_core::{formant, intensity, pitch, spectrogram, textgrid, voice_quality, wav};
use std::collections::HashMap;
use std::fmt::Write as _;
use std::process::ExitCode;

const USAGE: &str = "openphon <command> [options] <file>

Commands:
  info <file.wav>                      summary: format, duration, F0, intensity
  pitch <file.wav>                     CSV time_s,f0_hz (0 = unvoiced)
      [--step S] [--floor HZ] [--ceiling HZ]
  intensity <file.wav>                 CSV time_s,intensity_db
      [--step S] [--min-pitch HZ]
  voice <file.wav>                     voice report (sustained vowels):
      [--floor HZ] [--ceiling HZ]      mean HNR (dB), jitter/shimmer (local),
                                       period count. Praat-validated.
  formants <file.wav>                  CSV time_s,f1_hz..fN_hz (0 = missing)
      [--step S] [--max N] [--ceiling HZ] [--window S]
      [--pre-emphasis HZ] [--raw]      --raw: report every pole in band
                                       (bandwidth filter off, Praat burg-like)
  spectrogram <file.wav>               CSV matrix: time_s, then one column
      [--window S] [--step S]          per frequency bin (header in Hz)
      [--max-freq HZ] [--pre-emphasis HZ]
  textgrid <file.TextGrid>             parse and summarize tiers
      [--write OUT]                    re-emit as long-form UTF-8 TextGrid
  measure <file.wav | dir>             CSV of per-interval measures over an
      [--textgrid FILE]                annotation (default: sibling
      [--tier NAME]                    <stem>.TextGrid; default tier: first
      [--all]                          interval tier). Labelled intervals
      [--step S] [--floor HZ]          only unless --all. Columns: label,
      [--ceiling HZ]                   times, duration, mean/median F0,
      [--mid50]                        F1..F3 at midpoint, mean intensity.
      [--contour] [--moments]          Naming a point tier with --tier lists
      [--join TIER]                    its points instead: time, F0,
      [--rel-tier TIER]                intensity, F1..F3 at each point.
                                       --mid50: aggregate F0/intensity over
                                       the middle 50% of each interval.
                                       --contour: add F0/intensity at
                                       20/50/80% of the interval.
                                       --moments: add spectral moments
                                       (CoG, SD, skewness, kurtosis) over
                                       the middle 50% of each interval.
                                       --join: add the containing label
                                       from another interval tier.
                                       --rel-tier (point tiers): add the
                                       containing interval's label and the
                                       distances to its boundaries.
                                       Directory input: measure every WAV
                                       with a sibling TextGrid (adds a
                                       leading `file` column)

Common options:
  --out FILE                           write output to FILE instead of stdout

Defaults match the app and the Praat-validated core parameters.";

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    match run(&args) {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("error: {e}");
            eprintln!("\n{USAGE}");
            ExitCode::FAILURE
        }
    }
}

/// Tiny flag parser: `--key value` pairs, listed boolean flags, one
/// positional.
pub(crate) struct Opts {
    pub(crate) file: String,
    pub(crate) flags: HashMap<String, String>,
    pub(crate) bools: Vec<String>,
}

impl Opts {
    pub(crate) fn has(&self, flag: &str) -> bool {
        self.bools.iter().any(|b| b == flag)
    }
}

pub(crate) fn parse_opts(args: &[String], allowed: &[&str], bool_flags: &[&str]) -> Result<Opts, String> {
    let mut flags = HashMap::new();
    let mut bools = Vec::new();
    let mut positional = Vec::new();
    let mut it = args.iter();
    while let Some(a) = it.next() {
        if let Some(key) = a.strip_prefix("--").filter(|k| bool_flags.contains(k)) {
            bools.push(key.to_string());
        } else if let Some(key) = a.strip_prefix("--") {
            if !allowed.contains(&key) {
                return Err(format!("unknown option --{key}"));
            }
            let v = it.next().ok_or(format!("--{key} needs a value"))?;
            flags.insert(key.to_string(), v.clone());
        } else {
            positional.push(a.clone());
        }
    }
    match positional.len() {
        0 => Err("missing input file".into()),
        1 => Ok(Opts {
            file: positional.remove(0),
            flags,
            bools,
        }),
        _ => Err(format!("unexpected argument '{}'", positional[1])),
    }
}

impl Opts {
    pub(crate) fn f64(&self, key: &str, default: f64) -> Result<f64, String> {
        match self.flags.get(key) {
            None => Ok(default),
            Some(v) => v
                .parse()
                .map_err(|_| format!("--{key}: '{v}' is not a number")),
        }
    }

    fn usize(&self, key: &str, default: usize) -> Result<usize, String> {
        match self.flags.get(key) {
            None => Ok(default),
            Some(v) => v
                .parse()
                .map_err(|_| format!("--{key}: '{v}' is not an integer")),
        }
    }

    pub(crate) fn emit(&self, content: &str) -> Result<(), String> {
        match self.flags.get("out") {
            None => {
                print!("{content}");
                Ok(())
            }
            Some(path) => std::fs::write(path, content).map_err(|e| format!("writing {path}: {e}")),
        }
    }
}

pub(crate) fn load_wav(path: &str) -> Result<wav::WavData, String> {
    // Core errors already name the file.
    wav::WavData::from_file(path).map_err(|e| e.to_string())
}

fn run(args: &[String]) -> Result<(), String> {
    let (cmd, rest) = args.split_first().ok_or("no command given")?;
    match cmd.as_str() {
        "info" => info(rest),
        "pitch" => pitch_cmd(rest),
        "voice" => voice_cmd(rest),
        "intensity" => intensity_cmd(rest),
        "formants" => formants_cmd(rest),
        "spectrogram" => spectrogram_cmd(rest),
        "textgrid" => textgrid_cmd(rest),
        "measure" => measure::measure_cmd(rest),
        "--help" | "-h" | "help" => {
            println!("{USAGE}");
            Ok(())
        }
        other => Err(format!("unknown command '{other}'")),
    }
}

fn info(args: &[String]) -> Result<(), String> {
    let opts = parse_opts(args, &["out"], &[])?;
    let w = load_wav(&opts.file)?;
    let mut out = String::new();
    writeln!(
        out,
        "{}: {} Hz, {} ch, {} samples, {:.3} s",
        opts.file,
        w.sample_rate,
        w.channels,
        w.samples.len(),
        w.duration_s()
    )
    .unwrap();
    let peak = w.samples.iter().fold(0.0f64, |m, s| m.max(s.abs()));
    writeln!(out, "peak |sample| = {peak:.4}").unwrap();

    let f0 = pitch::track_f0(&w.samples, w.sample_rate, &Default::default());
    let mut voiced: Vec<f64> = f0.f0_hz.iter().copied().filter(|&f| f > 0.0).collect();
    writeln!(
        out,
        "F0: {} frames, {} voiced ({:.0}%)",
        f0.f0_hz.len(),
        voiced.len(),
        100.0 * voiced.len() as f64 / f0.f0_hz.len().max(1) as f64
    )
    .unwrap();
    if !voiced.is_empty() {
        voiced.sort_by(|a, b| a.partial_cmp(b).unwrap());
        writeln!(out, "F0 median = {:.1} Hz", voiced[voiced.len() / 2]).unwrap();
    }
    let int = intensity::compute(&w.samples, w.sample_rate, &Default::default());
    let max_db = int.db.iter().fold(f64::NEG_INFINITY, |m, &d| m.max(d));
    writeln!(
        out,
        "intensity: {} frames, max {max_db:.1} dB",
        int.db.len()
    )
    .unwrap();
    opts.emit(&out)
}

fn pitch_cmd(args: &[String]) -> Result<(), String> {
    let opts = parse_opts(args, &["out", "step", "floor", "ceiling"], &[])?;
    let d = pitch::F0Params::default();
    let params = pitch::F0Params {
        time_step_s: opts.f64("step", d.time_step_s)?,
        f0_min_hz: opts.f64("floor", d.f0_min_hz)?,
        f0_max_hz: opts.f64("ceiling", d.f0_max_hz)?,
        ..d
    };
    let w = load_wav(&opts.file)?;
    let t = pitch::track_f0(&w.samples, w.sample_rate, &params);
    let mut csv = String::from("time_s,f0_hz\n");
    for (time, f0) in t.times_s.iter().zip(&t.f0_hz) {
        writeln!(csv, "{time:.6},{f0:.3}").unwrap();
    }
    opts.emit(&csv)
}

fn voice_cmd(args: &[String]) -> Result<(), String> {
    let opts = parse_opts(args, &["out", "floor", "ceiling"], &[])?;
    let d = pitch::F0Params::default();
    let params = pitch::F0Params {
        f0_min_hz: opts.f64("floor", d.f0_min_hz)?,
        f0_max_hz: opts.f64("ceiling", d.f0_max_hz)?,
        ..d
    };
    let w = load_wav(&opts.file)?;
    let r = voice_quality::analyze(&w.samples, w.sample_rate, &params);
    let na = |v: Option<f64>, p: usize| v.map_or("nan".into(), |x| format!("{x:.p$}"));
    let mut csv = String::from("metric,value\n");
    writeln!(csv, "mean_hnr_db,{}", na(r.mean_hnr_db, 3)).unwrap();
    writeln!(csv, "jitter_local,{}", na(r.jitter_local, 6)).unwrap();
    writeln!(csv, "shimmer_local,{}", na(r.shimmer_local, 6)).unwrap();
    writeln!(csv, "n_periods,{}", r.n_periods).unwrap();
    writeln!(csv, "median_f0_hz,{}", na(r.median_f0_hz, 3)).unwrap();
    writeln!(csv, "mean_f0_hz,{}", na(r.mean_f0_hz, 3)).unwrap();
    writeln!(csv, "sd_f0_hz,{}", na(r.sd_f0_hz, 3)).unwrap();
    opts.emit(&csv)
}

fn intensity_cmd(args: &[String]) -> Result<(), String> {
    let opts = parse_opts(args, &["out", "step", "min-pitch"], &[])?;
    let d = intensity::IntensityParams::default();
    let params = intensity::IntensityParams {
        min_pitch_hz: opts.f64("min-pitch", d.min_pitch_hz)?,
        time_step_s: opts.f64("step", d.time_step_s)?,
    };
    let w = load_wav(&opts.file)?;
    let t = intensity::compute(&w.samples, w.sample_rate, &params);
    let mut csv = String::from("time_s,intensity_db\n");
    for (time, db) in t.times_s.iter().zip(&t.db) {
        writeln!(csv, "{time:.6},{db:.3}").unwrap();
    }
    opts.emit(&csv)
}

fn formants_cmd(args: &[String]) -> Result<(), String> {
    let opts = parse_opts(
        args,
        &["out", "step", "max", "ceiling", "window", "pre-emphasis"],
        &["raw"],
    )?;
    let d = formant::FormantParams::default();
    let params = formant::FormantParams {
        time_step_s: opts.f64("step", d.time_step_s)?,
        max_formants: opts.usize("max", d.max_formants)?,
        ceiling_hz: opts.f64("ceiling", d.ceiling_hz)?,
        window_s: opts.f64("window", d.window_s)?,
        pre_emphasis_hz: opts.f64("pre-emphasis", d.pre_emphasis_hz)?,
        max_bandwidth_hz: if opts.has("raw") {
            f64::INFINITY
        } else {
            d.max_bandwidth_hz
        },
    };
    let w = load_wav(&opts.file)?;
    let t = formant::track_formants(&w.samples, w.sample_rate, &params);
    let mut csv = String::from("time_s");
    for i in 1..=params.max_formants {
        write!(csv, ",f{i}_hz").unwrap();
    }
    csv.push('\n');
    for fr in &t.frames {
        write!(csv, "{:.6}", fr.time_s).unwrap();
        for i in 0..params.max_formants {
            let f = fr.formants_hz.get(i).copied().unwrap_or(0.0);
            write!(csv, ",{f:.3}").unwrap();
        }
        csv.push('\n');
    }
    opts.emit(&csv)
}

fn spectrogram_cmd(args: &[String]) -> Result<(), String> {
    let opts = parse_opts(
        args,
        &["out", "window", "step", "max-freq", "pre-emphasis"],
        &[],
    )?;
    let d = spectrogram::SpectrogramParams::default();
    let params = spectrogram::SpectrogramParams {
        window_s: opts.f64("window", d.window_s)?,
        time_step_s: opts.f64("step", d.time_step_s)?,
        max_freq_hz: opts.f64("max-freq", d.max_freq_hz)?,
        pre_emphasis_hz: opts.f64("pre-emphasis", d.pre_emphasis_hz)?,
        window: d.window,
    };
    let w = load_wav(&opts.file)?;
    let sg = spectrogram::compute(&w.samples, w.sample_rate, &params);
    let mut csv = String::from("time_s");
    for bin in 0..sg.n_bins {
        write!(csv, ",{:.1}", bin as f64 * sg.freq_step_hz).unwrap();
    }
    csv.push('\n');
    for frame in 0..sg.n_frames {
        write!(
            csv,
            "{:.6}",
            sg.first_time_s + frame as f64 * sg.time_step_s
        )
        .unwrap();
        for bin in 0..sg.n_bins {
            write!(csv, ",{:.2}", sg.values_db[frame * sg.n_bins + bin]).unwrap();
        }
        csv.push('\n');
    }
    opts.emit(&csv)
}

fn textgrid_cmd(args: &[String]) -> Result<(), String> {
    let opts = parse_opts(args, &["out", "write"], &[])?;
    let tg = textgrid::parse_file(&opts.file)?;
    let mut out = String::new();
    writeln!(
        out,
        "{}: {:.6} .. {:.6} s, {} tier(s)",
        opts.file,
        tg.xmin,
        tg.xmax,
        tg.tiers.len()
    )
    .unwrap();
    for (i, tier) in tg.tiers.iter().enumerate() {
        match tier {
            textgrid::Tier::Interval(t) => {
                let non_empty = t.intervals.iter().filter(|iv| !iv.text.is_empty()).count();
                writeln!(
                    out,
                    "  {}: interval tier \"{}\": {} intervals ({} labelled)",
                    i + 1,
                    t.name,
                    t.intervals.len(),
                    non_empty
                )
                .unwrap();
            }
            textgrid::Tier::Point(t) => {
                writeln!(
                    out,
                    "  {}: point tier \"{}\": {} points",
                    i + 1,
                    t.name,
                    t.points.len()
                )
                .unwrap();
            }
        }
    }
    if let Some(dest) = opts.flags.get("write") {
        textgrid::write_file(dest, &tg)?;
        writeln!(out, "wrote long-form UTF-8 TextGrid to {dest}").unwrap();
    }
    opts.emit(&out)
}
