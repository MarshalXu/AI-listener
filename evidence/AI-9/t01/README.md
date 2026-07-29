# T-01 deterministic benchmark harness

`aggregate_release_rounds.py` is the final automatic evidence boundary for the
three required M5 Max Release executions. It accepts exactly three distinct raw
result files, re-validates every round against the same hashed corpus manifest,
requires explicit OS/toolchain/power/thermal/model/runtime/installed-size
evidence plus one positive peak-RSS measurement per round, and records absolute
RSS and unified-memory fraction. It intentionally keeps `t01Passed=false`
because the separate three-native-speaker review cannot be inferred from
automatic metrics.

```sh
python3 aggregate_release_rounds.py \
  --manifest /path/to/corpus/manifest.json \
  --results /path/to/round-{1,2,3}.json \
  --environment /path/to/environment.json \
  --output /path/to/three-round-report.json
```

Latest checkpoint: `../t01-license-source-snapshot.md` locks the official
OpenSLR license declaration and complete accompanying description byte-for-byte,
and makes source archive verification fail closed when any license evidence or
review status changes. This is evidence locking only; T-01 remains incomplete.

This directory contains the candidate inventory plus the measurement harness for the
approved AI-3 SDD-r3 T-01 gates. It never downloads audio, invokes cloud ASR, or
reads files outside the corpus directory.

Run:

```sh
cd evidence/AI-9/t01
PYTHONPYCACHEPREFIX="$PAPERCLIP_RUN_SCRATCH_DIR/python-cache" \
  python3 -m unittest -v test_benchmark.py

PYTHONPYCACHEPREFIX="$PAPERCLIP_RUN_SCRATCH_DIR/python-cache" \
  python3 benchmark.py \
  --manifest /path/to/fixed-corpus/manifest.json \
  --results /path/to/round-1-results.json \
  --output /path/to/round-1-report.json
```

The corpus validator fails closed unless:

- clean and office-noise audio each total at least 30 minutes;
- each group has at least 10 distinct speakers and both female/male labels;
- every noise item records SNR in the approved 10–20 dB range;
- every audio file stays below the manifest directory and matches its SHA-256;
- the manifest explicitly records redistribution permission and its evidence URL;
- result IDs exactly match corpus IDs.

`build_corpus_manifest.py` is the deterministic assembly boundary for the fixed
corpus. It does not download, synthesize, copy, or modify audio. Given an explicit
inventory beside locally staged audio, it accepts only 16 kHz mono 16-bit PCM WAV,
measures duration from the WAV header, computes SHA-256 itself, rejects path
escapes, and requires an HTTPS license-evidence URL plus an explicit redistribution
attestation. The inventory must also name a non-empty local license-evidence
snapshot below the corpus root; the builder computes and records its SHA-256 so the
reviewed license text is immutable and auditable:

```sh
python3 build_corpus_manifest.py \
  --inventory /path/to/staged-corpus/inventory.json \
  --output /path/to/staged-corpus/manifest.json
```

This deliberately prevents metadata supplied by a corpus preparation step from
claiming an unmeasured duration or hash. It does not establish that a particular
voice/audio license permits redistribution; that evidence must be reviewed before
the inventory can truthfully set `redistributionAllowed=true`.

CER is Levenshtein distance over normalized CJK/ASCII characters. Latency p95 uses
the nearest-rank definition. RTF is total processing milliseconds divided by total
audio milliseconds. The generated report always keeps `t01Passed=false`, even when
all automatic thresholds pass, because the separate three-native-speaker
intelligibility gate cannot be inferred from automated metrics.

## 2026-07-29 validation checkpoint

Input: the candidate manifest/SBOM and the deterministic benchmark validator.

Output: the validator now fails closed on duplicate or missing corpus/result IDs,
unknown corpus groups, empty normalized group references, and non-positive total
audio duration. This prevents malformed fixtures from being collapsed by a
dictionary lookup and reported as a valid benchmark.

Reproduce:

```sh
cd evidence/AI-9/t01
PYTHONPYCACHEPREFIX="$PAPERCLIP_RUN_SCRATCH_DIR/python-cache" \
  python3 -m unittest -v test_benchmark.py
./verify-candidate.sh
git diff --check
```

Observed result (superseded by the checkpoint below): `6 tests` passed, all eight locked runtime/model/license artifacts
matched their SHA-256 values, both JSON documents parsed, and `git diff --check`
passed. Checkpoint source hashes:

- `benchmark.py`: `d00881a73771a463b150bc2eb0ac05bc736420d47cddf9c529ae5b003d0acc29`
- `test_benchmark.py`: `b79d3e5f1d1d648a01898eb7ad2aa69a49a3d1766ce004c551150de0942f52d9`
- `adapter-candidate.json`: `e23c603233eea4b82fd3d657e24eecb82d8fb6be7e57666cf6b5452a25949dc8`
- `sbom.spdx.json`: `d1967a12097b05e90e547579548b76b38f9b82145288f38221e6e049f581d4c0`

Acceptance boundary: this validates the harness and candidate inventory only.
`t01Passed` remains false and T-05 remains prohibited until the fixed 60-minute
corpus, three Release rounds on the primary M5 Max, and the three-native-speaker
review are complete. Stop if corpus licensing is unclear or completion would
require private recordings, cloud ASR, paid services, or relaxed SDD thresholds.

## 2026-07-29 result-integrity checkpoint

The result validator now rejects non-string hypotheses, negative/non-finite
processing durations, and empty/negative/non-finite partial or final latency
samples. These values can no longer produce an apparently passing metric report.

Observed result: `8 tests` passed; all eight locked runtime/model/license artifacts
matched; candidate manifest and SPDX SBOM parsed; `git diff --check` passed.

- `benchmark.py`: `8abcfce66042df33b3905436071fce32daea56ee690e3ed2fc9c29f0f44393f2`
- `test_benchmark.py`: `999e3bf0e2c182c35a25bb2759bb8139fa091655437e56fb9d9741c9da46670d`
- `adapter-candidate.json`: `e23c603233eea4b82fd3d657e24eecb82d8fb6be7e57666cf6b5452a25949dc8`
- `sbom.spdx.json`: `d1967a12097b05e90e547579548b76b38f9b82145288f38221e6e049f581d4c0`

This checkpoint still validates only measurement integrity and inventory. It does
not supply the missing licensed corpus or M5 Max Release benchmark, and therefore
does not unlock T-05.

## 2026-07-29 corpus-field integrity checkpoint

Input: the approved corpus contract and deterministic benchmark validator.

Output: runtime validation now rejects non-positive or non-integer durations
(including JSON booleans), empty speaker IDs, unknown gender values, missing audio
paths, malformed SHA-256 values, and non-string references. The benchmark fails
closed even when a caller does not separately execute the JSON Schema validator.

Reproduce:

```sh
cd evidence/AI-9/t01
PYTHONPYCACHEPREFIX="$PAPERCLIP_RUN_SCRATCH_DIR/python-cache" \
  python3 -m unittest -v test_benchmark.py
./verify-candidate.sh
git diff --check
shasum -a 256 benchmark.py test_benchmark.py adapter-candidate.json sbom.spdx.json
```

Observed result: `10 tests` passed; all eight locked runtime/model/license artifacts
matched; candidate manifest and SPDX SBOM parsed; `git diff --check` passed.

- `benchmark.py`: `687e078d7fa1440fabe9769df8d0dcc272ba5ebc4b93b3512640c033ca4cdea5`
- `test_benchmark.py`: `50c1f6969ae5d92950cbdc6940e377e1b9ac5d22f48be2b14a70ab09d4492a91`
- `adapter-candidate.json`: `e23c603233eea4b82fd3d657e24eecb82d8fb6be7e57666cf6b5452a25949dc8`
- `sbom.spdx.json`: `d1967a12097b05e90e547579548b76b38f9b82145288f38221e6e049f581d4c0`

Acceptance boundary: this is measurement-integrity evidence only. It does not
provide the licensed 60-minute corpus, three M5 Max Release rounds, streaming
latency observations, or three-native-speaker review. `t01Passed` remains false
and T-05 remains prohibited.

## 2026-07-29 deterministic corpus assembly checkpoint

Input: locally staged, non-private PCM WAV files plus an explicit inventory and
reviewed redistribution-license evidence.

Output: `build_corpus_manifest.py` measures audio duration and SHA-256 rather than
trusting supplied metadata; rejects files outside the inventory root; accepts only
16 kHz mono 16-bit PCM WAV; and fails closed without an HTTPS license evidence URL
and affirmative redistribution attestation. `test_build_corpus_manifest.py`
covers measured duration/hash, path escape, license rejection, and audio-format
rejection.

Reproduce:

```sh
cd evidence/AI-9/t01
PYTHONPYCACHEPREFIX="$PAPERCLIP_RUN_SCRATCH_DIR/python-cache" \
  python3 -m unittest -v test_benchmark.py test_build_corpus_manifest.py
./verify-candidate.sh
git diff --check
```

Observed result: `14 tests` passed; all eight locked runtime/model/license
artifacts matched; candidate manifest and SPDX SBOM parsed; `git diff --check`
passed.

- `build_corpus_manifest.py`: `67df895049f2a8f6bc21c3218abd79d0be50e941d684a9e68de7309c9868c445`
- `test_build_corpus_manifest.py`: `a77dc71e8a70be922be669050bdb40a4273f80044ba34f4bb900ec54e1d32801`
- `benchmark.py`: `687e078d7fa1440fabe9769df8d0dcc272ba5ebc4b93b3512640c033ca4cdea5`
- `test_benchmark.py`: `50c1f6969ae5d92950cbdc6940e377e1b9ac5d22f48be2b14a70ab09d4492a91`

Acceptance boundary: no corpus audio was created or accepted in this checkpoint.
Apple system voices were detected locally, but their output-redistribution rights
were not assumed. T-01 remains unlocked until a license-cleared 60-minute corpus,
three Release rounds, latency/RTF/memory/disk evidence, and three-native-speaker
review complete; T-05 remains prohibited.

## 2026-07-29 corpus anti-inflation checkpoint

Input: the deterministic corpus assembly boundary and the SDD requirement that
duration and speaker/gender coverage describe the fixed corpus rather than repeated
metadata.

Output: the builder now rejects two inventory entries that resolve to the same WAV
file and rejects a speaker ID whose gender changes between utterances. This prevents
one audio asset from inflating measured duration or speaker metadata from creating
an internally contradictory coverage claim.

Reproduce:

```sh
cd evidence/AI-9/t01
PYTHONPYCACHEPREFIX="$PAPERCLIP_RUN_SCRATCH_DIR/python-cache" \
  python3 -m unittest -v test_benchmark.py test_build_corpus_manifest.py
./verify-candidate.sh
git diff --check
shasum -a 256 build_corpus_manifest.py test_build_corpus_manifest.py
```

Acceptance boundary: these checks validate corpus inventory integrity only. They do
not provide or license the missing corpus, execute the three M5 Max Release rounds,
or satisfy the native-speaker review. `t01Passed=false` and T-05 remains prohibited.

Observed result: `16 tests` passed; all eight locked runtime/model/license artifact
hashes matched; candidate manifest and SPDX SBOM parsed; `git diff --check` passed.
The Xcode cache/FSEvents warnings did not change the zero exit status.

- `build_corpus_manifest.py`: `b6b649c057717867f437ec241a198ba078c6f6b92584a9855a48ff78b0a41b39`
- `test_build_corpus_manifest.py`: `0b0f03aa0ed41fa359a5caa853090c87957508da04a665e0bf6b38cfa80a41fa`

## 2026-07-29 license-evidence immutability checkpoint

Input: the deterministic corpus assembly boundary and T-01's requirement for
reproducible license evidence.

Output: an inventory can no longer rely only on a mutable HTTPS license URL. It
must reference a non-empty local evidence snapshot below the corpus root; the
builder independently hashes that file into `license.evidenceSHA256` and preserves
its relative path. Missing, empty, or path-escaping snapshots fail closed.

Reproduce:

```sh
cd evidence/AI-9/t01
PYTHONPYCACHEPREFIX="$PAPERCLIP_RUN_SCRATCH_DIR/python-cache" \
  python3 -m unittest -v test_benchmark.py test_build_corpus_manifest.py
./verify-candidate.sh
git diff --check
shasum -a 256 build_corpus_manifest.py test_build_corpus_manifest.py
```

Acceptance boundary: this locks the exact license evidence reviewed for a future
corpus; it does not assert that any particular license is compatible, supply the
missing 60-minute corpus, run Release benchmarks, or complete native-speaker
review. `t01Passed=false` and T-05 remains prohibited.

Observed result: `19 tests` passed; all eight existing candidate runtime/model
artifacts matched; candidate manifest and SPDX SBOM parsed; `git diff --check`
passed.

- `benchmark.py`: `916f1689cda02afb62efe01c242149f60adbd559920a6f7530a9ec8d6e5daf56`
- `test_benchmark.py`: `ae81c747a41291488593b71c796eb62656f8ea31b2603ca683d30cb68a580549`
- `build_corpus_manifest.py`: `83f7aa6f2717d6e29224188ae9d4ef5cd9514e7e2a366ef101c6e7c8000f5f5a`
- `test_build_corpus_manifest.py`: `9f6227ffc6c204050e25dfcb777bba3f9e4fa3bc0b6690f9e82c3f07f678793b`
- `corpus-manifest.schema.json`: `eb733416bcbfde13cbc90297e1821afd7aa17176335b908c2968de152da8906e`

## 2026-07-29 corpus source-selection checkpoint

Input: the still-open fixed 60-minute corpus gate and the requirement to use only
public or synthetic, redistribution-permitted material.

Output:

- `corpus-source-lock.json` selects official AISHELL-1 / SLR33 test audio under
  Apache-2.0, locks the OpenSLR archive MD5 values, and remains explicitly
  `selected-not-assembled`;
- `prepare_aishell1_corpus.py` is an offline deterministic preparation step. It
  requires an already extracted source and local license snapshot, selects five
  female plus five male test speakers round-robin until clean duration reaches
  30 minutes, and produces a separate 15 dB synthetic office-ambience derivative;
- `test_prepare_aishell1_corpus.py` verifies deterministic/distinct noise output
  and speaker metadata parsing.

The preparation step refuses non-PCM input, silent audio, missing transcripts,
insufficient gender coverage, and a non-empty output directory. It does not
download the 15G source archive or assert that selection alone passes T-01.

Downloaded source archives must first pass the offline source-lock verifier. The
verifier checks every locked MD5, records a SHA-256 for the local artifact, parses
the gzip tar without extracting it, and rejects absolute paths, `..` traversal,
symbolic links, and hard links:

```sh
python3 verify_source_artifacts.py \
  --lock corpus-source-lock.json \
  --archive-directory /path/to/downloads \
  --output /path/to/source-verification.json
```

All archives in the lock are required, so a partial download intentionally fails
closed. A verification report is source-integrity evidence only; it is not a
license compatibility decision and does not unlock T-01.

Reproduce the currently executable checks:

```sh
cd evidence/AI-9/t01
PYTHONPYCACHEPREFIX="$PAPERCLIP_RUN_SCRATCH_DIR/python-cache" \
  python3 -m unittest -v \
    test_benchmark.py test_build_corpus_manifest.py \
    test_prepare_aishell1_corpus.py
./verify-candidate.sh
git diff --check
```

Observed result: `21 tests` passed; eight locked runtime/model artifacts matched;
candidate JSON/SBOM parsed; `git diff --check` passed.

Acceptance boundary: the archive and exact license snapshot are not staged, so no
60-minute inventory/manifest exists yet. Three Release rounds and the native
speaker review also remain. `t01Passed=false`; `t05Allowed=false`.
