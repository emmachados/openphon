"""Diagnostic formant scoring that retains displayed slot labels and missingness.

Agreement uses paired, finite positive values only; every absent slot remains
in its own denominator. Truth scoring reports labelled error first, then a
separate monotone assignment diagnostic. Neither changes release gates.
"""

import numpy as np


def filter_candidates(frequencies, bandwidths, max_bandwidth_hz=400.0):
    """Apply the shipped selection rule to a reference, before frame alignment.

    Returns compact ascending survivors and their original zero-based slots.
    The latter records renumbering; it does not infer resonance identity.
    """
    frequencies = np.asarray(frequencies, dtype=float)
    bandwidths = np.asarray(bandwidths, dtype=float)
    if frequencies.shape != bandwidths.shape or frequencies.ndim != 2:
        raise ValueError("Frequency and bandwidth matrices must have the same 2D shape")
    if not np.isfinite(max_bandwidth_hz) or max_bandwidth_hz < 0:
        raise ValueError("Bandwidth cutoff must be finite and nonnegative")
    out = np.zeros_like(frequencies)
    slots = np.full(frequencies.shape, -1, dtype=int)
    for i, (freq, bw) in enumerate(zip(frequencies, bandwidths)):
        selected = np.flatnonzero(np.isfinite(freq) & (freq > 0)
                                 & np.isfinite(bw) & (bw >= 0)
                                 & (bw <= max_bandwidth_hz))
        selected = selected[np.argsort(freq[selected], kind="stable")]
        out[i, :len(selected)] = freq[selected]
        slots[i, :len(selected)] = selected
    return out, slots


def summarize_errors(errors, n_eligible):
    errors = np.asarray(errors, dtype=float)
    absolute = np.abs(errors)
    n = len(errors)
    return {
        "n": n,
        "n_eligible": int(n_eligible),
        "n_missing": int(n_eligible - n),
        "missing_pct": 100.0 * (n_eligible - n) / n_eligible if n_eligible else None,
        "median_abs_err_hz": float(np.median(absolute)) if n else None,
        "rmse_hz": float(np.sqrt(np.mean(errors ** 2))) if n else None,
        "median_signed_err_hz": float(np.median(errors)) if n else None,
        "p95_abs_err_hz": float(np.percentile(absolute, 95)) if n else None,
        "p99_abs_err_hz": float(np.percentile(absolute, 99)) if n else None,
        "max_abs_err_hz": float(np.max(absolute)) if n else None,
    }


class SlotAgreement:
    """Accumulate signed got-minus-reference errors without moving Fk slots."""

    def __init__(self):
        self.errors = []
        self.n_eligible = self.n_reference_missing = self.n_reported_missing = 0
        self.n_both_missing = self.n_reference_present_reported_missing = 0

    def add(self, reference, reported):
        reference, reported = np.asarray(reference), np.asarray(reported)
        if reference.shape != reported.shape:
            raise ValueError("Formant slot arrays must have the same shape")
        ref_present = np.isfinite(reference) & (reference > 0)
        got_present = np.isfinite(reported) & (reported > 0)
        paired = ref_present & got_present
        self.errors.extend((reported[paired] - reference[paired]).tolist())
        self.n_eligible += len(reference)
        self.n_reference_missing += int(np.sum(~ref_present))
        self.n_reported_missing += int(np.sum(~got_present))
        self.n_both_missing += int(np.sum(~ref_present & ~got_present))
        self.n_reference_present_reported_missing += int(np.sum(ref_present & ~got_present))

    def result(self):
        out = summarize_errors(self.errors, self.n_eligible)
        # "Missing" in an agreement statistic means an unpaired comparison;
        # report each method's absence independently to expose that distinction.
        out["n_unpaired"] = out.pop("n_missing")
        out["unpaired_pct"] = out.pop("missing_pct")
        for field in ("n_reference_missing", "n_reported_missing", "n_both_missing",
                      "n_reference_present_reported_missing"):
            out[field] = getattr(self, field)
        out["reported_missing_pct"] = (
            100.0 * self.n_reported_missing / self.n_eligible if self.n_eligible else None)
        return out


class SelectionComparison:
    """Compare selection policies on exactly the same observed frame triples."""

    def __init__(self):
        self.n_eligible = self.n_common = self.n_renumbered = 0
        self.raw = SlotAgreement()
        self.matched = SlotAgreement()

    def add(self, raw_reference, filtered_reference, reported, source_slots, slot):
        raw, filtered, got = (np.asarray(v) for v in
                              (raw_reference, filtered_reference, reported))
        if not (raw.shape == filtered.shape == got.shape == np.shape(source_slots)):
            raise ValueError("Selection comparisons require matching arrays")
        common = (np.isfinite(raw) & (raw > 0) & np.isfinite(filtered)
                  & (filtered > 0) & np.isfinite(got) & (got > 0))
        self.n_eligible += len(raw)
        self.n_common += int(np.sum(common))
        self.n_renumbered += int(np.sum(np.asarray(source_slots)[common] != slot))
        self.raw.add(raw[common], got[common])
        self.matched.add(filtered[common], got[common])

    def result(self):
        return {"n_eligible": self.n_eligible, "n_common": self.n_common,
                "n_excluded_from_common": self.n_eligible - self.n_common,
                "n_reference_renumbered_on_common": self.n_renumbered,
                "raw_reference_on_common": self.raw.result(),
                "matched_reference_on_common": self.matched.result()}


class AgreementEvidence:
    def __init__(self):
        self.accumulators = {}
        self.per_file = []

    def add(self, stem, tier, reference, configurations, eligible, coverage):
        row = {"stem": stem, "tier": tier, "coverage": coverage, "configurations": {}}
        for name, columns in configurations.items():
            pooled = self.accumulators.setdefault((tier, name),
                                                  {k: SlotAgreement() for k in (1, 2, 3)})
            result = {}
            for k in (1, 2, 3):
                ref, got = reference[k][eligible], columns[k][eligible]
                cell = SlotAgreement()
                cell.add(ref, got)
                pooled[k].add(ref, got)
                result[f"F{k}"] = cell.result()
            row["configurations"][name] = result
        self.per_file.append(row)

    def report(self, synthetic_gates, public_gates):
        aggregate = {}
        checks = []
        for (tier, name), slots in self.accumulators.items():
            result = {f"F{k}": slot.result() for k, slot in slots.items()}
            aggregate.setdefault(tier, {})[name] = result
            if name != "shipped" or tier not in ("synth", "public"):
                continue
            for k in (1, 2, 3):
                metric = "rmse_hz" if tier == "synth" else "median_abs_err_hz"
                gate_key = f"f{k}_rmse_hz" if tier == "synth" else f"f{k}_median_dev_hz"
                threshold = (synthetic_gates if tier == "synth" else public_gates)[gate_key]
                value = result[f"F{k}"][metric]
                checks.append({"tier": tier, "slot": f"F{k}", "metric": metric,
                               "value": value, "threshold": threshold, "relation": "<",
                               "passed": value is not None and value < threshold,
                               "enforced_in_ci": False})
        return {
            "scoring": "Labelled Fk versus the same Praat Fk; no pole reassignment. "
                       "Errors require both slots present; missingness retains all eligible frames.",
            "configurations": {"raw": {"max_bandwidth_hz": None},
                               "shipped": {"max_bandwidth_hz": 400.0}},
            "aggregates": aggregate, "per_file": self.per_file,
            "same_target_diagnostics": checks,
            "all_same_targets_passed": all(c["passed"] for c in checks),
            "enforced_in_ci": False,
        }


def truth_errors(reported, truth):
    """Return labelled/assigned samples, preserving original column indices."""
    from compare import assign_poles

    reported, truth = np.asarray(reported), np.asarray(truth)
    if reported.ndim != 2 or truth.ndim != 2 or len(reported) != len(truth):
        raise ValueError("Truth and reported formants require equally many matrix rows")
    n_true = truth.shape[1]
    labelled = {k: [] for k in range(n_true)}
    assigned = {k: [] for k in range(n_true)}
    n_shift = n_unmatched = 0
    for row, poles in zip(reported, truth):
        slots = [j for j, v in enumerate(row) if np.isfinite(v) and v > 0]
        present = [row[j] for j in slots]
        for k in range(n_true):
            if k in slots:
                labelled[k].append(float(row[k] - poles[k]))
        pick = assign_poles(present, poles)
        n_shift += any(j is not None and slots[j] != k for k, j in enumerate(pick))
        n_unmatched += any(j is None for j in pick)
        for k, j in enumerate(pick):
            if j is not None:
                assigned[k].append(float(present[j] - poles[k]))
    return labelled, assigned, n_shift, n_unmatched


def score_truth(reported, truth):
    labelled, assigned, shifted, unmatched = truth_errors(reported, truth)
    n = len(reported)
    return {
        "n_frames": n,
        "pct_label_shift": 100.0 * shifted / n if n else None,
        "pct_pole_unmatched": 100.0 * unmatched / n if n else None,
        "labelled": {f"F{k + 1}": summarize_errors(e, n) for k, e in labelled.items()},
        "assigned": {f"F{k + 1}": summarize_errors(e, n) for k, e in assigned.items()},
    }
