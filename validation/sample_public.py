"""Build a *public* real-speech sub-tier that anyone can reproduce.

The main real-speech tier (`sample_real.py`) draws on participant recordings
that cannot be redistributed. That makes the tier unverifiable by a reader:
they can read the numbers but cannot regenerate them. This script builds a
parallel tier from corpora that carry redistributable licences, so the
real-speech gates can be re-run from a clean checkout with no local corpus
and no data agreement.

Supported sources
-----------------

ciempiess_hf   CIEMPIESS Light, Mexican Spanish radio speech, CC BY-SA 4.0,
               fetched clip by clip from the `ciempiess/ciempiess_light`
               dataset on the Hugging Face hub (the corpus authors' own
               account, ungated). Spontaneous broadcast speech at 16 kHz.
               Extends the tier beyond the Peninsular variety of the private
               corpora, which is the geographic limitation Section 5.2
               acknowledges. This is the source continuous integration uses:
               it needs no local corpus and no credential, and a run fetches
               a few megabytes rather than a release tarball.

common_voice_hf
               The same Common Voice Spanish material, taken from the
               `fsicoli/common_voice_17_0` mirror at a pinned revision
               instead of a local copy. The dataset is too large for the
               rows API, so the split arrives as its published transcript
               and tarball, cached under `.corpus_cache/` and re-used across
               runs; only the selected clips are extracted. This is the
               source continuous integration uses for the Common Voice half,
               and it is what makes the whole gated tier rebuildable from a
               network connection.

common_voice   Mozilla Common Voice, Spanish (`es`). Released CC0, i.e.
               public domain. Crowd-sourced read speech over consumer
               microphones: noisier and more variable than a laboratory
               corpus, which is a fair proxy for the recording conditions
               openphon is actually used in. MP3 source, decoded to WAV.
               Expects an already-extracted local copy: a directory holding
               a transcript TSV and a `clips/` directory. Mozilla's own
               distribution requires accepting the terms in a browser, so
               this path is deliberately local-only and stays out of CI.

ciempiess     A local CIEMPIESS-style tree (speaker directories of wavs),
               for anyone who already holds the full corpus.

Determinism
-----------

Selection is a fixed BLAKE2b rank over speaker and clip identifiers, never a
random seed, so two people pointing this at the same corpus release obtain
byte-identical tiers. Speakers are ranked *within gender* where the corpus
reports it, because both corpora are heavily male-skewed and an unstratified
rank would inherit the skew.

Every selected clip's SHA-256 goes into the manifest. `--from-manifest`
re-fetches exactly that list and verifies each hash, which is what lets CI
assert it is analysing the same audio the committed numbers describe rather
than whatever the corpus contains today.

Usage
-----
    python sample_public.py --source ciempiess_hf --speakers 20 --per-speaker 12
    python sample_public.py --source common_voice --root /path/to/cv-corpus-es \\
        --tsv test.tsv --speakers 20 --per-speaker 3 --append
    python sample_public.py --from-manifest wavs/public/manifest.csv   # CI

Then, as for any tier:
    python generate_references.py
    python compare.py
"""

import argparse
import csv
import datetime as _dt
import hashlib
import json
import shutil
import subprocess
import sys
import tarfile
import time
import urllib.error
import urllib.parse
import urllib.request
import wave
from collections import defaultdict
from pathlib import Path

HERE = Path(__file__).parent
DEST = HERE / "wavs" / "public"

TARGET_RATE = 16000

# Both sub-corpora are resampled to 16 kHz. CIEMPIESS is already there and
# Common Voice is not, so bringing Common Voice down puts the whole tier on
# one sample rate and keeps the corpus comparison of the gate table from
# confounding variety with bandwidth. 16 kHz leaves an 8 kHz Nyquist,
# comfortably above the 5500 Hz formant ceiling both tools analyse at, so
# nothing the comparison measures is lost.

HF_API = "https://datasets-server.huggingface.co"
HF_FILES = "https://huggingface.co/datasets"
CIEMPIESS_DATASET = "ciempiess/ciempiess_light"
CIEMPIESS_CONFIG = "ciempiess_light"
CIEMPIESS_SPLIT = "train"

# Common Voice over the hub. The dataset is too large for the rows API to
# serve clip by clip (`/splits` answers 501), so the split is taken as the
# two files the mirror publishes: a 5 MB transcript and a 750 MB tarball of
# MP3s, both pinned to one revision and cached between runs. Only the
# selected clips are extracted from the tarball.
CV_DATASET = "fsicoli/common_voice_17_0"
CV_REVISION = "8262c16bf297c87a9cd88c51997c4758ed7a8ba2"
CV_SPLIT = "test"
CV_LOCALE = "es"
CACHE = HERE / ".corpus_cache"

MANIFEST_FIELDS = [
    "stem", "speaker", "gender", "corpus", "corpus_version", "licence",
    "source_id", "sample_rate", "duration_s", "sha256", "transcript",
]

# Both corpora ship an orthographic transcript with every clip, which is
# what lets the segmental analysis (disagreement.py --phones) force-align
# this tier without a recognition step in between. Carrying the transcript
# in the manifest keeps the alignment reproducible from the committed file
# alone, and keeps a later run from having to query the hub again.


def _rank(key):
    return hashlib.blake2b(str(key).encode("utf-8"), digest_size=8).hexdigest()


def have_ffmpeg():
    return shutil.which("ffmpeg") is not None


def to_wav(src, dest, rate=TARGET_RATE):
    """Decode/resample to mono 16-bit PCM WAV."""
    subprocess.run(
        ["ffmpeg", "-y", "-loglevel", "error", "-i", str(src),
         "-ac", "1", "-ar", str(rate), "-sample_fmt", "s16", str(dest)],
        check=True,
    )


def wav_duration(path):
    with wave.open(str(path)) as w:
        return w.getnframes() / float(w.getframerate())


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


# The hub's rows API answers 5xx intermittently under load, on requests it
# serves correctly moments later. Without a retry a tier rebuild fails on
# transport noise rather than on anything about the corpus, which in CI is
# indistinguishable from a real provenance failure. Retries are confined to
# transient statuses; a 404 or a 401 still fails immediately, because those
# say the corpus moved and that is exactly what the run should report.
_RETRY_STATUS = {408, 425, 429, 500, 502, 503, 504}
# Measured failure rate on the rows API is around one call in ten, and the
# failures arrive in bursts rather than independently: a rebuild can meet
# five consecutive 500s on the same query and then succeed. The retry
# budget is therefore sized to ride out a bad window of a few minutes
# rather than to cover independent one-off failures.
_RETRIES = 8
_MAX_DELAY = 60.0


def _with_retry(fn, what):
    delay = 2.0
    for attempt in range(1, _RETRIES + 1):
        try:
            return fn()
        except urllib.error.HTTPError as exc:
            if exc.code not in _RETRY_STATUS or attempt == _RETRIES:
                raise
            reason = f"HTTP {exc.code}"
        except urllib.error.URLError as exc:
            if attempt == _RETRIES:
                raise
            reason = f"{type(exc).__name__}: {exc.reason}"
        print(f"    {what}: {reason}, retrying in {delay:.0f}s "
              f"({attempt}/{_RETRIES - 1})", file=sys.stderr, flush=True)
        time.sleep(delay)
        delay = min(delay * 2, _MAX_DELAY)


def _get_json(url, params=None, timeout=120):
    if params:
        url = f"{url}?{urllib.parse.urlencode(params)}"

    def once():
        with urllib.request.urlopen(url, timeout=timeout) as r:
            return json.loads(r.read().decode("utf-8"))

    return _with_retry(once, url.split("?")[0].rsplit("/", 1)[-1])


def _download(url, dest, timeout=180):
    def once():
        with urllib.request.urlopen(url, timeout=timeout) as r, \
                open(dest, "wb") as f:
            shutil.copyfileobj(r, f)

    return _with_retry(once, "download")


# ------------------------------------------------------- CIEMPIESS over HF --

def _ciempiess_revision(asset_url):
    """The dataset revision is a path segment of the signed asset URL.

    Recording it is what makes the tier pinnable: if the corpus is
    re-uploaded, the revision changes and the committed SHA-256 checks fail
    loudly instead of the tier silently becoming different audio.
    """
    for part in urllib.parse.urlparse(asset_url).path.split("/"):
        if len(part) == 40 and all(c in "0123456789abcdef" for c in part):
            return part
    return None


def _ciempiess_rows_for(speaker, limit):
    d = _get_json(f"{HF_API}/filter", {
        "dataset": CIEMPIESS_DATASET, "config": CIEMPIESS_CONFIG,
        "split": CIEMPIESS_SPLIT, "where": f"\"speaker_id\"='{speaker}'",
        "offset": 0, "length": min(limit, 100),
    })
    return [r["row"] for r in d.get("rows", [])]


def collect_ciempiess_hf(args):
    """Pick clips from CIEMPIESS Light on the hub, stratified by gender.

    One `/statistics` call returns every speaker_id with its clip count, so
    the speaker pool is enumerated without downloading the corpus. Speakers
    are then ranked by hash within each gender and taken alternately.
    """
    stats = _get_json(f"{HF_API}/statistics", {
        "dataset": CIEMPIESS_DATASET, "config": CIEMPIESS_CONFIG,
        "split": CIEMPIESS_SPLIT,
    })
    counts = {}
    for col in stats.get("statistics", []):
        if col["column_name"] == "speaker_id":
            counts = col["column_statistics"]["frequencies"]
    if not counts:
        sys.exit("could not enumerate CIEMPIESS speakers from the hub")

    eligible = [s for s, n in counts.items() if n >= args.per_speaker]
    # CIEMPIESS speaker ids carry gender as their first character (F_/M_),
    # which the row-level `gender` column confirms.
    by_gender = defaultdict(list)
    for s in eligible:
        by_gender["female" if s.startswith("F") else "male"].append(s)
    for g in by_gender:
        by_gender[g].sort(key=_rank)

    chosen = []
    while len(chosen) < args.speakers and any(by_gender.values()):
        for g in ("female", "male"):
            if by_gender[g] and len(chosen) < args.speakers:
                chosen.append((by_gender[g].pop(0), g))
    print(f"{len(eligible)} eligible speakers, taking {len(chosen)} "
          f"({sum(1 for _, g in chosen if g == 'female')} female)")

    picks = []
    for i, (spk, gender) in enumerate(chosen, start=1):
        rows = _ciempiess_rows_for(spk, max(args.per_speaker * 2, 20))
        rows.sort(key=lambda r: _rank(r["audio_id"]))
        for j, row in enumerate(rows[:args.per_speaker], start=1):
            picks.append({
                "stem": f"cp{i:02d}_{j:02d}",
                "url": row["audio"][0]["src"],
                "speaker": spk,
                "gender": gender,
                "corpus": "ciempiess_light",
                "corpus_version": None,   # filled from the revision below
                "licence": "CC-BY-SA-4.0",
                "source_id": row["audio_id"],
                "transcript": (row.get("normalized_text") or "").strip(),
            })
        print(f"  {spk}: {min(len(rows), args.per_speaker)} clips", flush=True)
    if picks:
        rev = _ciempiess_revision(picks[0]["url"])
        for p in picks:
            p["corpus_version"] = rev
    return picks


# ------------------------------------------------------------ Common Voice --

def collect_common_voice(args):
    """Pick clips from a Common Voice transcript TSV, grouped by client_id.

    `validated.tsv` (clips confirmed by community review) is the default;
    `--tsv test.tsv` selects from the test split alone, which is what a
    partial download of the corpus provides. Whichever is used is recorded
    in the provenance, because the selection is only reproducible relative
    to the file it drew from.
    """
    root = Path(args.root)
    tsv = root / args.tsv
    clips = root / "clips"
    if not tsv.exists():
        sys.exit(f"expected {tsv}; point --root at an extracted Common Voice "
                 f"language directory containing {args.tsv} and clips/")

    by_speaker = defaultdict(list)
    with open(tsv, encoding="utf-8", newline="") as f:
        for row in csv.DictReader(f, delimiter="\t"):
            cid, path = row.get("client_id"), row.get("path")
            if cid and path:
                by_speaker[cid].append(row)

    eligible = [s for s, rows in by_speaker.items() if len(rows) >= args.per_speaker]
    # Common Voice records self-reported gender sparsely; stratify on it
    # where all of a speaker's clips agree, and pool the rest.
    def gender_of(rows):
        vals = {(r.get("gender") or "").strip().lower() for r in rows}
        vals.discard("")
        for g in ("female_feminine", "female"):
            if g in vals:
                return "female"
        for g in ("male_masculine", "male"):
            if g in vals:
                return "male"
        return "unknown"

    by_gender = defaultdict(list)
    for s in eligible:
        by_gender[gender_of(by_speaker[s])].append(s)
    for g in by_gender:
        by_gender[g].sort(key=_rank)

    chosen = []
    order = [g for g in ("female", "male", "unknown") if by_gender[g]]
    while len(chosen) < args.speakers and any(by_gender[g] for g in order):
        for g in order:
            if by_gender[g] and len(chosen) < args.speakers:
                chosen.append((by_gender[g].pop(0), g))
    print(f"{len(eligible)} eligible speakers in {args.tsv}, taking "
          f"{len(chosen)} ({sum(1 for _, g in chosen if g == 'female')} female, "
          f"{sum(1 for _, g in chosen if g == 'unknown')} unreported)")

    picks = []
    for i, (spk, gender) in enumerate(chosen, start=1):
        rows = sorted(by_speaker[spk], key=lambda r: _rank(r["path"]))
        for j, row in enumerate(rows[:args.per_speaker], start=1):
            picks.append({
                "stem": f"cv{i:02d}_{j:02d}",
                "src": clips / row["path"],
                "speaker": spk[:16],
                "gender": gender,
                "corpus": "common_voice_es",
                "corpus_version": args.corpus_version,
                "licence": "CC0-1.0",
                "source_id": row["path"],
                "transcript": (row.get("sentence") or "").strip(),
            })
    return picks


# ------------------------------------------------- Common Voice over HF --

def _cv_cache_files():
    """Fetch (and keep) the pinned transcript and audio tarball.

    Both are re-fetched only when absent, because the tarball is 750 MB and
    a sampling run that changed the speaker count should not re-download the
    corpus to do it.
    """
    CACHE.mkdir(parents=True, exist_ok=True)
    base = f"{HF_FILES}/{CV_DATASET}/resolve/{CV_REVISION}/"
    tsv = CACHE / f"cv17_{CV_LOCALE}_{CV_SPLIT}.tsv"
    tar = CACHE / f"cv17_{CV_LOCALE}_{CV_SPLIT}_0.tar"
    for remote, dest in (
        (f"transcript/{CV_LOCALE}/{CV_SPLIT}.tsv", tsv),
        (f"audio/{CV_LOCALE}/{CV_SPLIT}/{CV_LOCALE}_{CV_SPLIT}_0.tar", tar),
    ):
        if dest.exists():
            continue
        print(f"  fetching {remote} -> {dest.name}", flush=True)
        with urllib.request.urlopen(base + remote, timeout=1800) as r, \
                open(dest, "wb") as f:
            shutil.copyfileobj(r, f, 1024 * 1024)
    return tsv, tar


def collect_common_voice_hf(args):
    """Same selection as `common_voice`, over the mirror's own files.

    This exists so the gated tier is reproducible from a network connection
    alone. Mozilla's distribution requires accepting terms in a browser, so
    the previous version of this tier needed a local corpus for its Common
    Voice half and continuous integration could verify only the CIEMPIESS
    half of the manifest it was asked to rebuild.
    """
    tsv, tar = _cv_cache_files()
    member_prefix = f"{CV_LOCALE}_{CV_SPLIT}_0/"

    class _Shim:
        pass

    shim = _Shim()
    shim.__dict__.update(vars(args))
    shim.root = str(tsv.parent)
    shim.tsv = tsv.name
    shim.corpus_version = (f"hf:{CV_DATASET}@{CV_REVISION} "
                           f"({CV_LOCALE} {CV_SPLIT} split)")
    picks = collect_common_voice(shim)
    for p in picks:
        p["tar"] = tar
        p["tar_member"] = member_prefix + p["source_id"]
        p.pop("src", None)
    return picks


# ------------------------------------------------- local CIEMPIESS-like tree --

def collect_ciempiess(args):
    """Pick wavs from a CIEMPIESS-style tree (speaker directories of wavs)."""
    root = Path(args.root)
    wavs = sorted(root.rglob("*.wav"))
    if not wavs:
        sys.exit(f"no .wav under {root}")
    by_speaker = defaultdict(list)
    for w in wavs:
        by_speaker[w.parent.name].append(w)

    eligible = [s for s, ws in by_speaker.items() if len(ws) >= args.per_speaker]
    eligible.sort(key=_rank)
    picks = []
    for i, spk in enumerate(eligible[:args.speakers], start=1):
        for j, w in enumerate(sorted(by_speaker[spk], key=_rank)[:args.per_speaker],
                              start=1):
            picks.append({
                "stem": f"cp{i:02d}_{j:02d}",
                "src": w,
                "speaker": spk,
                "gender": "unknown",
                "corpus": "ciempiess",
                "corpus_version": args.corpus_version,
                "licence": "CC-BY-SA-4.0",
                "source_id": w.name,
            })
    return picks


COLLECTORS = {
    "ciempiess_hf": collect_ciempiess_hf,
    "common_voice": collect_common_voice,
    "common_voice_hf": collect_common_voice_hf,
    "ciempiess": collect_ciempiess,
}

# Sources that need no local corpus, only a network connection. Everything
# in the gated tier has to come from one of these, or the tier stops being
# reproducible by a reader.
HUB_SOURCES = {"ciempiess_hf", "common_voice_hf"}


# ---------------------------------------------------------------- materialise --

def _extract_member(tar_path, member, dest, handles={}):
    """Pull one member out of a cached tarball, keeping the handle open.

    Opening a 750 MB tar once per clip would re-scan it every time; the
    handle cache makes a 100-clip extraction one pass instead of a hundred.
    """
    t = handles.get(str(tar_path))
    if t is None:
        t = handles[str(tar_path)] = tarfile.open(tar_path)
    src = t.extractfile(member)
    if src is None:
        raise KeyError(member)
    with open(dest, "wb") as f:
        shutil.copyfileobj(src, f)


def materialise(picks, dest, rate, work):
    """Fetch/decode each pick into dest, returning manifest rows."""
    rows = []
    for n, p in enumerate(picks, start=1):
        out = dest / f"{p['stem']}.wav"
        try:
            if "url" in p:
                tmp = work / f"{p['stem']}.src"
                _download(p["url"], tmp)
                to_wav(tmp, out, rate)
                tmp.unlink(missing_ok=True)
            elif "tar_member" in p:
                tmp = work / f"{p['stem']}.src"
                _extract_member(p["tar"], p["tar_member"], tmp)
                to_wav(tmp, out, rate)
                tmp.unlink(missing_ok=True)
            else:
                to_wav(p["src"], out, rate)
        except Exception as exc:                      # noqa: BLE001
            print(f"  fetch/decode failed, skipping {p['source_id']}: {exc}",
                  file=sys.stderr)
            continue
        rows.append({
            "stem": p["stem"],
            "speaker": p["speaker"],
            "gender": p["gender"],
            "corpus": p["corpus"],
            "corpus_version": p["corpus_version"] or "",
            "licence": p["licence"],
            "source_id": p["source_id"],
            "sample_rate": rate,
            "duration_s": round(wav_duration(out), 2),
            "sha256": sha256(out),
            "transcript": p.get("transcript", ""),
        })
        if n % 25 == 0 or n == len(picks):
            print(f"  {n}/{len(picks)} clips", flush=True)
    return rows


def from_manifest(args, dest, work):
    """Re-fetch exactly the committed clip list and verify every hash.

    This is the CI path, and the reader's path. It is the difference between
    a tier that is reproducible in principle and one that is checked on
    every commit: if the upstream corpus is re-uploaded or a clip changes,
    the hashes stop matching and the build fails rather than quietly
    reporting numbers about different audio.
    """
    with open(args.from_manifest, encoding="utf-8", newline="") as f:
        want = list(csv.DictReader(f))
    if not want:
        sys.exit(f"{args.from_manifest} is empty")

    fetchable = [r for r in want if r["corpus"] == "ciempiess_light"]
    cv = [r for r in want if r["corpus"] == "common_voice_es"]
    skipped = [r for r in want
               if r["corpus"] not in ("ciempiess_light", "common_voice_es")]
    if skipped:
        print(f"{len(skipped)} clips are not hub-fetchable "
              f"({sorted({r['corpus'] for r in skipped})}); they need a local "
              f"corpus and are skipped")

    by_speaker = defaultdict(list)
    for r in fetchable:
        by_speaker[r["speaker"]].append(r)

    ok, bad, missing = 0, [], []
    for spk, wanted in sorted(by_speaker.items()):
        rows = {r["audio_id"]: r for r in _ciempiess_rows_for(spk, 100)}
        for w in wanted:
            row = rows.get(w["source_id"])
            if row is None:
                missing.append(w["source_id"])
                continue
            out = dest / f"{w['stem']}.wav"
            tmp = work / f"{w['stem']}.src"
            _download(row["audio"][0]["src"], tmp)
            to_wav(tmp, out, int(w["sample_rate"]))
            tmp.unlink(missing_ok=True)
            got = sha256(out)
            if got != w["sha256"]:
                bad.append((w["stem"], w["sha256"], got))
            else:
                ok += 1
        print(f"  {spk}: {len(wanted)} clips", flush=True)

    if cv:
        # The Common Voice half comes out of the pinned tarball rather than
        # a rows API, but it is verified against the same committed hashes.
        _, tar = _cv_cache_files()
        prefix = f"{CV_LOCALE}_{CV_SPLIT}_0/"
        for n, w in enumerate(cv, start=1):
            out = dest / f"{w['stem']}.wav"
            tmp = work / f"{w['stem']}.src"
            try:
                _extract_member(tar, prefix + w["source_id"], tmp)
            except KeyError:
                missing.append(w["source_id"])
                continue
            to_wav(tmp, out, int(w["sample_rate"]))
            tmp.unlink(missing_ok=True)
            got = sha256(out)
            if got != w["sha256"]:
                bad.append((w["stem"], w["sha256"], got))
            else:
                ok += 1
            if n % 25 == 0 or n == len(cv):
                print(f"  common_voice_es: {n}/{len(cv)} clips", flush=True)

    print(f"\n{ok}/{len(fetchable) + len(cv)} clips fetched and hash-verified")
    if missing:
        print(f"MISSING upstream: {len(missing)} ({missing[:5]} ...)")
    if bad:
        print(f"HASH MISMATCH on {len(bad)} clips; the upstream corpus is not "
              f"the one this manifest describes:")
        for stem, want_h, got_h in bad[:10]:
            print(f"  {stem}: expected {want_h[:16]}... got {got_h[:16]}...")
    return 0 if (ok and not bad and not missing) else 1


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--source", choices=sorted(COLLECTORS))
    ap.add_argument("--root", help="extracted corpus directory (local sources)")
    ap.add_argument("--tsv", default="validated.tsv",
                    help="Common Voice transcript file to select from")
    ap.add_argument("--corpus-version", default="",
                    help="corpus release identifier to record in the manifest, "
                         "e.g. 'cv-corpus-17.0-2024-03-15'. Fetched sources "
                         "fill this in themselves.")
    ap.add_argument("--speakers", type=int, default=20)
    ap.add_argument("--per-speaker", type=int, default=2)
    ap.add_argument("--rate", type=int, default=TARGET_RATE)
    ap.add_argument("--dest", default=str(DEST))
    ap.add_argument("--append", action="store_true",
                    help="add to the existing tier and manifest instead of "
                         "replacing them (used to combine two corpora)")
    ap.add_argument("--from-manifest",
                    help="re-fetch and hash-verify an existing manifest "
                         "instead of selecting a new sample (the CI path)")
    args = ap.parse_args()

    if not have_ffmpeg():
        sys.exit("ffmpeg not found on PATH; needed to decode and resample")

    dest = Path(args.dest)
    dest.mkdir(parents=True, exist_ok=True)
    work = dest / "_work"
    work.mkdir(exist_ok=True)

    try:
        if args.from_manifest:
            return from_manifest(args, dest, work)

        if not args.source:
            ap.error("--source is required unless --from-manifest is given")
        if args.source not in HUB_SOURCES and not args.root:
            ap.error(f"--root is required for --source {args.source}")

        picks = COLLECTORS[args.source](args)
        if not picks:
            sys.exit("no clips selected")
        print(f"selected {len(picks)} clips; fetching")

        rows = materialise(picks, dest, args.rate, work)
        if not rows:
            sys.exit("nothing was fetched")
    finally:
        shutil.rmtree(work, ignore_errors=True)

    manifest = dest / "manifest.csv"
    prov_path = dest / "provenance.json"
    # The provenance entry describes THIS run, so it has to be built from
    # this run's rows. Reading it off the merged manifest would attribute
    # whichever corpus sorts first to every source.
    new_rows = list(rows)
    if args.append and manifest.exists():
        with open(manifest, encoding="utf-8", newline="") as f:
            rows = [r for r in csv.DictReader(f)
                    if r["stem"] not in {x["stem"] for x in new_rows}] + rows
        prov = json.loads(prov_path.read_text()) if prov_path.exists() else {}
        sources = prov.get("sources", [])
    else:
        sources = []

    rows.sort(key=lambda r: r["stem"])
    with open(manifest, "w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=MANIFEST_FIELDS)
        w.writeheader()
        w.writerows(rows)

    total = sum(float(r["duration_s"]) for r in rows)
    sources = [s for s in sources if s["source"] != args.source]
    sources.append({
        "source": args.source,
        # For hub sources the dataset id is the reproducible locator. For
        # local sources it is not: the path is this machine's, so only its
        # final component is recorded, and --corpus-version carries what a
        # reader would actually need to obtain the same corpus.
        "dataset": (CIEMPIESS_DATASET if args.source == "ciempiess_hf"
                    else CV_DATASET if args.source == "common_voice_hf"
                    else Path(args.root).name if args.root else None),
        "corpus_version": next(
            (r["corpus_version"] for r in new_rows if r["corpus_version"]), ""),
        "selection_from": (f"{CV_SPLIT}.tsv"
                           if args.source == "common_voice_hf"
                           else args.tsv if args.source == "common_voice"
                           else None),
        "downloaded": _dt.date.today().isoformat(),
        "clips": len(new_rows),
    })
    prov_path.write_text(json.dumps({
        "sources": sources,
        "selection": "deterministic blake2b rank over speaker and clip id, "
                     "speakers stratified by gender",
        "verification": "sha256 per clip in manifest.csv; "
                        "sample_public.py --from-manifest re-fetches and checks",
        "speakers": len({r["speaker"] for r in rows}),
        "recordings": len(rows),
        "total_audio_s": round(total, 1),
        "target_rate_hz": args.rate,
    }, indent=2))

    print(f"\n{len(rows)} recordings, {len({r['speaker'] for r in rows})} "
          f"speakers, {total / 60:.1f} min -> {dest}")
    print("next: python generate_references.py && python compare.py")
    return 0


if __name__ == "__main__":
    sys.exit(main())
