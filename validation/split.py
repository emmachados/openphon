"""Speaker-disjoint partition of a real-speech tier.

Any parameter tuned against a real tier (notably the pitch tracker's
unvoiced candidate cost, Section 4.7 of the paper) must be tuned on one half
of the speakers and gated on the other, or the reported gate is a tuned
quantity presented as a held-out one.

The partition is:

  deterministic   a fixed BLAKE2b hash of the speaker id, not a random seed,
                  so the split is identical on every machine and in every
                  release without storing a seed or a file list;
  speaker-disjoint  every recording by a speaker lands in the same half;
  corpus-stratified  each corpus is split separately, so both halves keep a
                  similar mix of broadcast and consumer-microphone speech.

Speaker identity is derived from the recording stem, which encodes it:
`cp04_07` and `cv12_02` are speakers `cp04` and `cv12` in the public tier,
whose stems `sample_public.py` numbers per speaker; `sp3_002` is speaker
`sp3` in the secondary spontaneous tier.

The public tier is the gated one and is what this partition exists for. The
secondary spontaneous tier holds 8 speakers, too few to divide into halves
that would mean anything, so it is reported rather than gated and is not
partitioned; `speaker_of` still recognises its stems, because the bootstrap
and the divergence measurement group by speaker on every tier.

Usage:
    python split.py --dir wavs/public   # the gated tier's partition
    python split.py --dir wavs/public --save baseline.json
    python split.py --dir wavs/public --against baseline.json
    from split import half_for, speaker_of
"""

import hashlib
import json
import re
from collections import defaultdict
from pathlib import Path

HERE = Path(__file__).parent
PUBLIC = HERE / "wavs" / "public"
REAL = HERE / "wavs" / "real"

# Public tier: "cp<NN>_<MM>" (CIEMPIESS Light) and "cv<NN>_<MM>" (Common
# Voice), numbered per speaker by sample_public.py. Secondary spontaneous
# tier: "sp<N>_<MM>", numbered per speaker by sample_real.py. The older
# "sp<N>_short"/"sp<N>_long" stems are still recognised so that caches
# written before the resampling remain readable.
_PATTERNS = (
    (re.compile(r"^(sp\d+)_(?:\d+|short|long)$"), "spontaneous"),
    (re.compile(r"^(cp\d+)_\d+$"), "ciempiess_light"),
    (re.compile(r"^(cv\d+)_\d+$"), "common_voice_es"),
)


def speaker_of(stem):
    """Speaker identifier for a recording stem, or None if unrecognised."""
    for pat, _ in _PATTERNS:
        m = pat.match(stem)
        if m:
            return m.group(1)
    return None


def corpus_of(stem):
    for pat, corpus in _PATTERNS:
        if pat.match(stem):
            return corpus
    return None


def _rank(speaker):
    """Stable pseudo-random ordering key for a speaker."""
    return hashlib.blake2b(speaker.encode("utf-8"), digest_size=8).hexdigest()


def _bit(speaker):
    """One hash bit per speaker: 0 -> calib, 1 -> eval."""
    h = hashlib.blake2b(speaker.encode("utf-8"), digest_size=8).digest()
    return h[0] & 1


def partition(stems, rule="hashbit"):
    """Return {speaker: 'calib'|'eval'}, stratified by corpus.

    Two rules, because the change between them is itself a result.

    `alternate` orders the speakers of each corpus by their hash and
    assigns them alternately. It balances the halves exactly, and it is not
    monotone under growth: inserting one speaker into the hash order flips
    the parity of everyone below them. When the public tier grew from 40
    speakers to 120, 22 of the original 40 changed halves. A held-out gate
    whose held-out set is redefined by adding data is not held out in any
    useful sense.

    `hashbit` assigns each speaker independently from one bit of their own
    hash. Adding, removing or reordering speakers cannot move anyone else,
    so the partition is stable under growth. The cost is that the halves
    are only balanced in expectation; the observed imbalance is reported by
    the command-line summary rather than corrected, since correcting it
    would reintroduce a dependence between speakers.
    """
    by_corpus = defaultdict(set)
    for s in stems:
        spk, cor = speaker_of(s), corpus_of(s)
        if spk and cor:
            by_corpus[cor].add(spk)

    assignment = {}
    for corpus, speakers in sorted(by_corpus.items()):
        if rule == "alternate":
            for i, spk in enumerate(sorted(speakers, key=_rank)):
                assignment[spk] = "calib" if i % 2 == 0 else "eval"
        elif rule == "hashbit":
            for spk in sorted(speakers):
                assignment[spk] = "eval" if _bit(spk) else "calib"
        else:
            raise ValueError(f"unknown partition rule {rule!r}")
    return assignment


def half_for(stem, assignment):
    spk = speaker_of(stem)
    return assignment.get(spk) if spk else None


def load_assignment(wav_dir=REAL, rule="hashbit"):
    stems = sorted(p.stem for p in Path(wav_dir).glob("*.wav"))
    return partition(stems, rule), stems


def main():
    import argparse
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--dir", default=str(PUBLIC), help="directory of recordings")
    ap.add_argument("--rule", choices=["hashbit", "alternate"],
                    default="hashbit",
                    help="hashbit assigns each speaker from one bit of "
                         "their own hash and is stable under growth; "
                         "alternate is the earlier rule, balanced but not "
                         "monotone, kept so the change can be reported")
    ap.add_argument("--quiet", action="store_true",
                    help="summary only, without the per-recording table")
    ap.add_argument("--save", metavar="PATH",
                    help="write {speaker: half} as JSON, to be compared "
                         "against a later partition with --against")
    ap.add_argument("--against", metavar="PATH",
                    help="a partition saved earlier by --save. Prints which "
                         "speakers kept their half and which moved when the "
                         "tier changed size. Alternate-by-hash assignment is "
                         "deterministic but not monotone: inserting a speaker "
                         "into the hash order shifts the parity of everyone "
                         "below them, so this reports the churn rather than "
                         "assuming there is none.")
    args = ap.parse_args()

    assignment, stems = load_assignment(args.dir, args.rule)
    if not stems:
        print("no recordings in", args.dir)
        return 1
    if not args.quiet:
        print(f"{'stem':<14}{'speaker':<10}{'corpus':<18}{'half':<8}")
        for s in stems:
            print(f"{s:<14}{str(speaker_of(s)):<10}{str(corpus_of(s)):<18}"
                  f"{str(half_for(s, assignment)):<8}")
    for half in ("calib", "eval"):
        spks = sorted(k for k, v in assignment.items() if v == half)
        recs = [s for s in stems if half_for(s, assignment) == half]
        print(f"\n{half}: {len(spks)} speakers, {len(recs)} recordings")
        print("  speakers:", " ".join(spks))

    # What changing the rule is worth, on the tier as it stands. Reporting
    # it here means the move to a growth-stable rule cannot be read as
    # choosing a partition after seeing results.
    other = "alternate" if args.rule == "hashbit" else "hashbit"
    alt = partition(stems, other)
    moved_rule = sorted(s for s in assignment if alt.get(s) != assignment[s])
    print(f"\nagainst the '{other}' rule on these same speakers: "
          f"{len(moved_rule)} of {len(assignment)} differ")

    if args.against:
        before = json.loads(Path(args.against).read_text())
        old = set(before)
        new = set(assignment)
        kept = sorted(s for s in old & new if before[s] == assignment[s])
        moved = sorted(s for s in old & new if before[s] != assignment[s])
        added = sorted(new - old)
        dropped = sorted(old - new)
        print(f"\ndiff against {args.against}:")
        print(f"  {len(old)} speakers before, {len(new)} after "
              f"({len(added)} added, {len(dropped)} dropped)")
        print(f"  of the {len(old & new)} in both: {len(kept)} kept their "
              f"half, {len(moved)} moved")
        if moved:
            print("  moved: " + " ".join(
                f"{s}({before[s]}->{assignment[s]})" for s in moved))
        if dropped:
            print("  dropped: " + " ".join(dropped))

    if args.save:
        Path(args.save).write_text(json.dumps(assignment, indent=1, sort_keys=True))
        print("\nwrote", args.save)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
