"""Native root-solver evidence on fixed polynomials, without speech scoring.

The default baseline embeds the exact prior root function. A preserved
formant.rs can override it with --baseline. Baseline and candidate modules
are copied into an isolated directory and compiled into one Rust executable.
The candidate must expose checked_poly_roots.
No Praat implementation source is used. This checks numerical acceptance,
not formant accuracy or recovery of information lost in LPC estimation.
"""

import argparse
import hashlib
import json
import math
import subprocess
import tempfile
from datetime import datetime, timezone
from pathlib import Path

HERE = Path(__file__).resolve().parent
CORE = HERE.parent / "core"

# Exact prior pub fn poly_roots from the preserved full formant.rs with SHA-256
# e72a7a760848e7198e43cb0e2b3da2c908585e107821c001f3ec5b277c01d724.
# Only its Complex64 import is added; waveform preprocessing is not used here.
LEGACY_FULL_SOURCE_SHA256 = "e72a7a760848e7198e43cb0e2b3da2c908585e107821c001f3ec5b277c01d724"
LEGACY_ROOT_SOURCE = r'''use rustfft::num_complex::Complex64;

pub fn poly_roots(coeffs: &[f64]) -> Vec<Complex64> {
    let p = coeffs.len();
    if p == 0 {
        return Vec::new();
    }
    let eval = |z: Complex64| -> Complex64 {
        let mut v = Complex64::new(1.0, 0.0);
        for &c in coeffs {
            v = v * z + Complex64::new(c, 0.0);
        }
        v
    };
    // Standard initialization: powers of a non-real seed of modulus ≈ 1.
    let seed = Complex64::new(0.4, 0.9);
    let mut roots: Vec<Complex64> = (0..p).map(|k| seed.powu(k as u32 + 1)).collect();
    for _ in 0..200 {
        let mut max_step = 0.0f64;
        for i in 0..p {
            let mut denom = Complex64::new(1.0, 0.0);
            for j in 0..p {
                if i != j {
                    denom *= roots[i] - roots[j];
                }
            }
            if denom.norm() < 1e-30 {
                continue;
            }
            let step = eval(roots[i]) / denom;
            roots[i] -= step;
            max_step = max_step.max(step.norm());
        }
        if max_step < 1e-12 {
            break;
        }
    }
    roots
}
'''

DRIVER = r'''#![allow(dead_code)]
mod baseline;
mod candidate;
use rustfft::num_complex::Complex64;
use std::f64::consts::PI;
// The full formant modules refer to this symbol, but this driver invokes only
// polynomial root functions. Accidentally adding waveform analysis must fail.
mod spectrogram {
    pub fn pre_emphasize(_: &mut [f64], _: f64, _: f64) {
        panic!("root-only driver must not analyze waveforms");
    }
}
fn number(value: Option<f64>) -> String {
    value.filter(|v| v.is_finite()).map(|v| format!("{v:.17e}")).unwrap_or("null".into())
}
fn roots_json(roots: &[Complex64]) -> String {
    format!("[{}]", roots.iter().map(|z| format!("[{},{}]", number(Some(z.re)), number(Some(z.im))))
        .collect::<Vec<_>>().join(","))
}
fn resonances(frequencies: &[f64], bandwidth: f64) -> (Vec<f64>, Vec<Complex64>) {
    let radius = (-PI * bandwidth / 11000.0).exp();
    let mut coefficients = vec![1.0];
    let mut roots = Vec::new();
    for &frequency in frequencies {
        let root = Complex64::from_polar(radius, 2.0 * PI * frequency / 11000.0);
        roots.extend([root, root.conj()]);
        let quadratic = [1.0, -2.0 * root.re, radius * radius];
        let mut next = vec![0.0; coefficients.len() + 2];
        for (i, a) in coefficients.iter().enumerate() {
            for (j, b) in quadratic.iter().enumerate() { next[i + j] += a * b; }
        }
        coefficients = next;
    }
    (coefficients[1..].to_vec(), roots)
}
fn emit(name: &str, coefficients: &[f64], expected: &[Complex64]) {
    let old = baseline::poly_roots(coefficients);
    let (accepted, reason, roots, d) = match candidate::checked_poly_roots(coefficients) {
        Ok(solution) => (true, "null".to_owned(), solution.roots, solution.diagnostics),
        Err(failure) => (false, format!("\"{:?}\"", failure.reason), Vec::new(), failure.diagnostics),
    };
    let compatibility_count = candidate::poly_roots(coefficients).len();
    println!("{{\"case\":\"{}\",\"coefficients\":{:?},\"expected_roots\":{},\"baseline_roots\":{},\"candidate_roots\":{},\"candidate_accepted\":{},\"failure_reason\":{},\"compatibility_root_count\":{},\"diagnostics\":{{\"iterations\":{},\"max_relative_step\":{},\"max_relative_residual\":{},\"max_conjugate_mismatch\":{},\"unpaired_nonreal_roots\":{},\"coefficient_backward_error\":{}}}}}",
        name, coefficients, roots_json(expected), roots_json(&old), roots_json(&roots), accepted,
        reason, compatibility_count, d.iterations, number(d.max_relative_step),
        number(d.max_relative_residual), number(d.max_conjugate_mismatch),
        d.unpaired_nonreal_roots, number(d.coefficient_backward_error));
}
fn main() {
    for (name, frequencies, bandwidth) in [
        ("well_separated", [500.0,1500.0,2500.0,3500.0,4500.0], 100.0),
        ("close_pairs", [500.0,510.0,2500.0,2510.0,4500.0], 20.0),
        ("clustered_low", [50.0,70.0,90.0,110.0,130.0], 10.0),
        ("wider_low_cluster", [100.0,200.0,300.0,400.0,500.0], 60.0),
        ("repeated_pairs", [300.0,300.0,300.0,300.0,300.0], 60.0),
    ] {
        let (coefficients, expected) = resonances(&frequencies, bandwidth);
        emit(name, &coefficients, &expected);
    }
    emit("real_and_complex_quartic", &[1.0,-5.0,1.0,-6.0], &[
        Complex64::new(-3.0,0.0),Complex64::new(2.0,0.0),
        Complex64::new(0.0,1.0),Complex64::new(0.0,-1.0)]);
    emit("zero_linear_root", &[0.0], &[Complex64::new(0.0,0.0)]);
}
'''


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def matching_error(expected, reported):
    """Minimum maximum root error over bijections, retaining multiplicities."""
    if len(expected) != len(reported) or not expected:
        return None
    states = {0: 0.0}
    for got in reported:
        next_states = {}
        for mask, previous in states.items():
            for j, wanted in enumerate(expected):
                if mask & (1 << j):
                    continue
                key = mask | (1 << j)
                value = max(previous, abs(got - wanted))
                next_states[key] = min(next_states.get(key, math.inf), value)
        states = next_states
    return states[(1 << len(expected)) - 1]


def root_metrics(coefficients, expected, values):
    finite = all(value is not None and math.isfinite(value) for pair in values for value in pair)
    result = {"n_roots": len(values), "finite": finite,
              "complete": len(values) == len(coefficients)}
    if not finite or not values:
        result.update({"n_upper_half": 0, "max_matching_root_error": None,
                       "max_matching_conjugate_error": None,
                       "max_relative_residual": None, "coefficient_backward_error": None})
        return result
    roots = [complex(*pair) for pair in values]
    result["n_upper_half"] = sum(root.imag > 0 for root in roots)
    result["max_matching_root_error"] = matching_error([complex(*pair) for pair in expected], roots)
    result["max_matching_conjugate_error"] = matching_error([z.conjugate() for z in roots], roots)
    residuals = []
    for root in roots:
        value, scale = 1.0 + 0j, 1.0
        for coefficient in coefficients:
            value = value * root + coefficient
            scale = scale * abs(root) + abs(coefficient)
        residuals.append(abs(value) / scale if scale else 0.0 if value == 0 else math.inf)
    result["max_relative_residual"] = max(residuals)
    reconstructed = [1.0 + 0j]
    for root in roots:
        reconstructed.append(0j)
        for j in range(len(reconstructed) - 1, 0, -1):
            reconstructed[j] -= root * reconstructed[j - 1]
    result["coefficient_backward_error"] = (
        max(abs(got - wanted) for got, wanted in zip(reconstructed[1:], coefficients))
        / max([1.0, *map(abs, coefficients)]) if result["complete"] else None)
    return result


def make_report(rows):
    checks = []
    accepted_controls = {"well_separated", "close_pairs", "real_and_complex_quartic", "zero_linear_root"}
    required_cases = accepted_controls | {"clustered_low", "wider_low_cluster", "repeated_pairs"}
    names = [row["case"] for row in rows]
    if set(names) != required_cases or len(names) != len(required_cases):
        raise ValueError("Native evidence must contain every fixed case exactly once")
    for row in rows:
        row["baseline"] = root_metrics(row["coefficients"], row["expected_roots"], row["baseline_roots"])
        row["candidate"] = root_metrics(row["coefficients"], row["expected_roots"], row["candidate_roots"])
        if row["case"] in accepted_controls:
            error = row["candidate"]["max_matching_root_error"]
            checks.append({"case": row["case"], "check": "complete accurate control accepted",
                           "root_error_tolerance": 1e-10,
                           "passed": row["candidate_accepted"] and error is not None and error < 1e-10})
        if row["case"] == "clustered_low":
            checks.append({"case": row["case"], "check": "unresolved cluster rejected without emitted roots",
                           "passed": not row["candidate_accepted"] and bool(row["failure_reason"])
                           and row["compatibility_root_count"] == 0 and not row["candidate_roots"]})
    return {"cases": rows, "checks": checks, "passed": all(check["passed"] for check in checks)}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline", type=Path,
                        help="Optional preserved formant.rs; default uses the embedded frozen legacy root function")
    parser.add_argument("--current", type=Path, default=CORE / "src/formant.rs")
    parser.add_argument("--expected-current-sha256")
    parser.add_argument("--out", type=Path, default=HERE / "release_root_solver_check.json")
    parser.add_argument("--work-directory", type=Path)
    args = parser.parse_args(argv)
    baseline = args.baseline.read_bytes() if args.baseline else LEGACY_ROOT_SOURCE.encode()
    candidate = args.current.read_bytes()
    candidate_hash = sha256(candidate)
    if args.expected_current_sha256 and candidate_hash != args.expected_current_sha256:
        raise ValueError("Candidate source differs from the frozen SHA-256")
    libraries = sorted((CORE / "target/release/deps").glob("librustfft-*.rlib"), key=lambda p: p.stat().st_mtime)
    if not libraries:
        raise RuntimeError("Build the release core first: cargo build --release --manifest-path core/Cargo.toml")
    library = libraries[-1]
    work = args.work_directory or Path(tempfile.mkdtemp(prefix="openphon-root-proof-"))
    work.mkdir(parents=True, exist_ok=True)
    for name, data in (("baseline.rs", baseline), ("candidate.rs", candidate), ("main.rs", DRIVER.encode())):
        target = work / name
        if target.exists() and target.read_bytes() != data:
            raise ValueError(f"Evidence directory contains a different {name}")
        target.write_bytes(data)
    command = ["rustc", "--edition=2021", "-O", str(work / "main.rs"), "--extern",
               f"rustfft={library}", "-L", f"dependency={library.parent}", "-o", str(work / "root-proof")]
    subprocess.run(command, check=True)
    native_output = subprocess.check_output([str(work / "root-proof")], text=True)
    (work / "native.jsonl").write_text(native_output)
    if args.current.read_bytes() != candidate:
        raise RuntimeError("Candidate source changed while the native check was running")
    report = make_report([json.loads(line) for line in native_output.splitlines()])
    report.update({
        "generated_at_utc": datetime.now(timezone.utc).isoformat(),
        "purpose": "Numerical acceptance on fixed polynomials, not speech or formant-identity accuracy",
        "limitations": "Coefficient rounding changes clustered roots; backward error does not bound forward error. "
                        "Wider low-frequency and repeated-pair cases are descriptive controls, not acceptance targets.",
        "resonance_construction": "Conjugate pairs at sample rate 11000 Hz, radius exp(-pi*bandwidth/11000). "
                                  "Real polynomial coefficients are multiplied in f64; intended roots are retained separately.",
        "source_sha256": {"baseline": sha256(baseline), "candidate": candidate_hash,
                          "baseline_root_source": sha256(LEGACY_ROOT_SOURCE.encode()) if not args.baseline else None,
                          "baseline_original_full_source": LEGACY_FULL_SOURCE_SHA256 if not args.baseline else sha256(baseline),
                          "driver": sha256(DRIVER.encode()), "script": sha256(Path(__file__).read_bytes()),
                          "rustfft_rlib": sha256(library.read_bytes())},
        "baseline_source_kind": "provided_full_module" if args.baseline else "embedded_frozen_root_function",
        "rustc": subprocess.check_output(["rustc", "--version"], text=True).strip(),
        "compile_command": command, "artifact_directory": str(work),
    })
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(report, indent=2, allow_nan=False) + "\n")
    print(f"Root solver evidence: {args.out}; checks passed: {report['passed']}")
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
