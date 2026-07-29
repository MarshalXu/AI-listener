# AI-8 T-01 Continuation Checkpoint

日期：2026-07-29  
规格基线：AI-3 SDD-r3  
aggregate SHA-256：`7711eca19ef7c255a729adad4c48f97ac3b94639356f1a5a9d07723c49e5863e`

## 规格状态

规格未修改。T-01 仍受批准门槛约束；本检查点没有以短样本或 manifest/SBOM
完整性替代 60 分钟质量、streaming latency 或三名中文母语评审。

## 实现状态

复用了 `evidence/AI-9/t01/` 已形成的 sherpa-onnx v1.13.2 candidate manifest、
SPDX 2.3 SBOM 和 hash verifier。候选配置为 CPU、2 threads、greedy search、
int8 encoder、fp32 decoder、int8 joiner。

该候选仍明确标记为 `candidate-not-locked`、`t05Allowed=false`；本次未进入 T-05，
未修改产品 ASR 集成代码。

## 验证状态

执行：

```sh
evidence/AI-9/t01/verify-candidate.sh
git diff --check
CLANG_MODULE_CACHE_PATH="$PAPERCLIP_RUN_SCRATCH_DIR/clang-module-cache" \
SWIFTPM_MODULECACHE_OVERRIDE="$PAPERCLIP_RUN_SCRATCH_DIR/swiftpm-module-cache" \
swift test --disable-sandbox \
  --scratch-path "$PAPERCLIP_RUN_SCRATCH_DIR/swift-build"
```

结果：

- runtime archive、model archive、runtime LICENSE、model card、tokens、
  encoder/decoder/joiner 共 8 个工件 SHA-256 全部匹配；
- candidate manifest 与 SPDX SBOM JSON 均可解析；
- `git diff --check` 通过；
- Debug build 完成，Swift Testing `25 tests / 3 suites` 全通过；
- target platform 报告为 `arm64e-apple-macos14.0`。

这些结果只验证 candidate inventory/hash 与 T-02～T-04 自动回归，不代表
T-01、Release、M5 Max 完整性能、真人 TCC 或最终 Demo 通过。

## 风险与下一步

- 剩余门槛：固定、许可清晰的 60 分钟中文 reference corpus（clean/noise 各
  30 分钟、至少 10 speakers）、三轮 CER/RTF、streaming partial/final p95、
  三名中文母语评审。
- 下一条 live continuation path：固化公开/合成 corpus manifest 与许可证，
  先执行可自动完成的 CER/RTF/streaming latency；人工可理解度保留为指定评审动作。
- 若 corpus/合成输出许可证不清、需要私人录音、云 ASR、付费服务或放宽门槛，
  触发 T-01 停止条件并升级 Board。

## Result-integrity 增量

输入：现有 deterministic benchmark harness 与 T-01 fail-closed 门槛。

输出：结果字段现在拒绝非字符串 hypothesis、负数/非有限 processing time，以及
空、负数或非有限 partial/final latency 样本；新增 2 项测试覆盖负 processing time、
空 latency 与 NaN latency。停止条件未变化，仍未进入 T-05。

验收证据：

```sh
cd evidence/AI-9/t01
PYTHONPYCACHEPREFIX="$PAPERCLIP_RUN_SCRATCH_DIR/python-cache" \
  python3 -m unittest -v test_benchmark.py
./verify-candidate.sh
git diff --check
```

2026-07-29 当前实机结果：`8 tests` 全通过；8 个 runtime/model/license 工件 hash
匹配；candidate manifest 与 SPDX SBOM 可解析；`git diff --check` 通过。测试期间
出现 Xcode `DVTFilePathFSEvents` / cache directory warning，但命令退出码为 0，
不影响 Python 测试或 hash 复核。

停止条件/边界：本增量仅防止畸形结果污染 CER/RTF/latency 报告，不代表已取得
60 分钟许可语料、三轮 M5 Max Release 指标或三人评审；`t05Allowed=false`。

## Corpus 字段完整性增量

输入：批准的固定语料约束与现有 deterministic benchmark harness。

输出：harness 运行时现会拒绝非正整数/布尔/字符串 `durationMs`、空
`speakerId`、非法 `gender`、缺失音频路径、非 64 位小写十六进制 SHA-256、
非字符串 reference。调用方即使没有另行运行 JSON Schema validator，也不能让
畸形 corpus metadata 进入门槛计算。新增 2 项测试，其中参数化覆盖 7 类非法字段。

可复现命令：

```sh
cd evidence/AI-9/t01
PYTHONPYCACHEPREFIX="$PAPERCLIP_RUN_SCRATCH_DIR/python-cache" \
  python3 -m unittest -v test_benchmark.py
./verify-candidate.sh
git diff --check
shasum -a 256 benchmark.py test_benchmark.py adapter-candidate.json sbom.spdx.json
```

原始结果摘要：`Ran 10 tests ... OK`；8 个锁定工件 hash 匹配；candidate manifest
与 SPDX SBOM 解析成功；`git diff --check` 成功。验证时 `xcodebuild` 报告无法启动
FSEvents/读取 `DARWIN_USER_CACHE_DIR` 并回退到 caches directory，但进程退出 0，
不影响 Python harness 结果。

检查点 hash：

- `benchmark.py`: `687e078d7fa1440fabe9769df8d0dcc272ba5ebc4b93b3512640c033ca4cdea5`
- `test_benchmark.py`: `50c1f6969ae5d92950cbdc6940e377e1b9ac5d22f48be2b14a70ab09d4492a91`
- `adapter-candidate.json`: `e23c603233eea4b82fd3d657e24eecb82d8fb6be7e57666cf6b5452a25949dc8`
- `sbom.spdx.json`: `d1967a12097b05e90e547579548b76b38f9b82145288f38221e6e049f581d4c0`

停止条件/边界：本增量仍只是 measurement integrity；缺失的 60 分钟许可语料、
三轮 M5 Max Release CER/RTF/streaming latency 与三名中文母语评审均未执行。
因此 `t01Passed=false`、T-05 未解锁，未宣称 Release/TCC/Demo 通过。

## Corpus anti-inflation 增量

输入：确定性 corpus assembly boundary，以及固定语料的时长和 speaker/gender
覆盖门槛。

输出：builder 现在拒绝多个 inventory entry 指向同一实际 WAV，并拒绝同一
`speakerId` 在不同 utterance 使用冲突 gender。新增 2 项回归，防止重复音频虚增
30+30 分钟门槛，或矛盾 speaker metadata 污染覆盖结论。

可复现命令：

```sh
cd evidence/AI-9/t01
PYTHONPYCACHEPREFIX="$PAPERCLIP_RUN_SCRATCH_DIR/python-cache" \
  python3 -m unittest -v test_benchmark.py test_build_corpus_manifest.py
./verify-candidate.sh
git diff --check
shasum -a 256 build_corpus_manifest.py test_build_corpus_manifest.py
```

停止条件/边界：该增量仅验证 inventory 完整性；没有取得或生成 corpus audio，
没有执行三轮 M5 Max Release 指标或三人评审。`t01Passed=false`、T-05 未解锁。

原始结果摘要：`Ran 16 tests ... OK`；8 个锁定 runtime/model/license 工件 hash
匹配；candidate manifest 与 SPDX SBOM 可解析；`git diff --check` 通过。Xcode
cache/FSEvents warning 不改变命令退出码 0。

- `build_corpus_manifest.py`: `b6b649c057717867f437ec241a198ba078c6f6b92584a9855a48ff78b0a41b39`
- `test_build_corpus_manifest.py`: `0b0f03aa0ed41fa359a5caa853090c87957508da04a665e0bf6b38cfa80a41fa`
