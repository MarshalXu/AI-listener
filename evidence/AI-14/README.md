# AI-14 / T-01 execution record

- Date: 2026-07-29
- Specification: AI-3 SDD-r3
- Aggregate SHA-256:
  `7711eca19ef7c255a729adad4c48f97ac3b94639356f1a5a9d07723c49e5863e`
- Current disposition: in progress; adapter is not locked and T-05 is not
  unlocked.

## Specification status

No specification change. The approved clean/noise corpus, quality, streaming
latency, RTF, memory, size, licensing, and three-native-speaker gates remain
unchanged.

## Implementation status

Input:

- AI-8/AI-9 candidate lock, SPDX SBOM, deterministic corpus builder, source
  archive verifier, and benchmark validator;
- official AISHELL-1 / OpenSLR SLR33 source selected by
  `../AI-9/t01/corpus-source-lock.json`;
- sherpa-onnx 1.13.2 and
  `sherpa-onnx-streaming-zipformer-zh-14M-2023-02-23`.

Output in this checkpoint:

- resumable official source download at `source/data_aishell.tgz`; archives and
  generated audio remain git-ignored;
- fail-closed three-round Release aggregator at
  `../AI-9/t01/aggregate_release_rounds.py`, with tests. It requires exactly
  three distinct result files, revalidates every round against one corpus hash,
  and records peak RSS as bytes and unified-memory fraction;
- this execution record, including exact commands and the claim boundary.

Download:

```sh
mkdir -p evidence/AI-14/source
curl -L --fail --retry 8 --retry-delay 5 -C - \
  -o evidence/AI-14/source/data_aishell.tgz \
  https://www.openslr.org/resources/33/data_aishell.tgz
```

The official HTTP response reported `Content-Length: 15582913665`,
`Last-Modified: Tue, 03 Oct 2017 23:41:05 GMT`, and byte-range support. The
locked OpenSLR MD5 remains `2f494334227864a8a8fec932999db9`. A 100 MiB range
probe averaged 4,181,723 bytes/second.

The 2026-07-29 20:13 CST continuation resumed at `1,090,846,720` bytes and
stopped cleanly at `1,260,171,264` bytes. The official-source transfer averaged
approximately 5.2 MiB/s. `curl --continue-at -` remains the live continuation;
no partial-archive hash is treated as acceptance evidence.

## Verification status

Executed on the primary M5 Max:

```sh
mkdir -p "$PAPERCLIP_RUN_SCRATCH_DIR/python-cache"
(cd evidence/AI-9/t01 &&
  PYTHONPYCACHEPREFIX="$PAPERCLIP_RUN_SCRATCH_DIR/python-cache" \
  python3 -m unittest -v \
    test_benchmark.py \
    test_build_corpus_manifest.py \
    test_prepare_aishell1_corpus.py \
    test_verify_source_artifacts.py \
    test_aggregate_release_rounds.py)
evidence/AI-9/t01/verify-candidate.sh
git diff --check
```

Observed:

- 28 tests passed;
- all eight locked sherpa runtime/model/license artifacts matched SHA-256;
- candidate JSON and SPDX SBOM parsed, with the adapter still explicitly
  `candidate-not-locked`;
- `git diff --check` passed before this record was added.

Environment:

- MacBook Pro `Mac17,6`, Apple M5 Max, 18 cores, 48 GB unified memory;
- macOS 26.5.2 build `25F84`, arm64;
- AC connected, Low Power Mode off;
- 1.4 TiB free at the start of download.

Hardware serials, UUIDs, user names, and device identifiers are intentionally
excluded.

## Risks and next actions

Still unverified and not claimed:

- complete archive MD5/SHA-256 and safe-member verification;
- exact 60-minute generated corpus and per-file manifest hashes;
- three Release CER/RTF/partial/final rounds and peak RSS;
- three Chinese-native-speaker reviews;
- final license compatibility decision and adapter-lock ADR.

After the archive completes: run `verify_source_artifacts.py`, extract only after
safe-member verification, prepare/build the fixed corpus, execute the three
measurement rounds, and stage the blinded 20-sentence review packet.

Automatic aggregation after all three raw Release rounds exist:

```sh
cd evidence/AI-9/t01
python3 aggregate_release_rounds.py \
  --manifest /path/to/corpus/manifest.json \
  --results /path/to/round-{1,2,3}.json \
  --environment /path/to/environment.json \
  --output /path/to/three-round-report.json
```

Aggregator SHA-256:
`5f3ee8de5205673f657f0636d9c70d96b0da337d73d5cfda5e83c916dfef4cee`.
Test SHA-256:
`9728097bb5fcaca0fcbb5bd4eccfe698e5dd4ef43aebe534f53ff8cf71ba0d3b`.

Stop only if the evidence shows license incompatibility/ambiguity, a gate requires
private audio, cloud ASR, a paid service, or a threshold change. License
incompatibility is a Board-owned blocker; none is asserted by this checkpoint.
