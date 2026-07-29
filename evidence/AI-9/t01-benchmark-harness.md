# AI-9 T-01 Benchmark Harness Checkpoint

日期：2026-07-29  
规格基线：AI-3 SDD-r3  
aggregate SHA-256：`7711eca19ef7c255a729adad4c48f97ac3b94639356f1a5a9d07723c49e5863e`

## 规格状态

规格未修改，T-01 仍未锁定，T-05 仍禁止进入。本增量只固化批准门槛的测量链，
没有以测试夹具替代固定 60 分钟语料或三名中文母语评审。

## 实现状态

### 输入

- SDD-r3 T-01/M-01：clean/noise 语料规模、speaker/gender/SNR、CER、RTF、
  partial/final p95 门槛；
- AI-4 sherpa-onnx v1.13.2 候选与 AI-9 candidate manifest/SBOM；
- 仅公开或合成音频，不允许私人录音、云 ASR、付费服务。

### 输出

- `t01/benchmark.py`：fail-closed corpus/result validator、中文字符 CER、nearest-rank
  p95、RTF 与机器可读 gate report；
- `t01/corpus-manifest.schema.json`：固定语料 manifest 格式；
- `t01/test_benchmark.py`：4 个确定性自动测试；
- `t01/README.md`：从零执行命令和口径。

报告即使 automatic gates 全通过也固定 `t01Passed=false`，原因字段明确指向尚需
单独执行的三名中文母语可理解度门，防止自动化结果被误写成 T-01 已验收。

## 验证状态

执行：

```sh
mkdir -p "$PAPERCLIP_RUN_SCRATCH_DIR/python-cache"
PYTHONPYCACHEPREFIX="$PAPERCLIP_RUN_SCRATCH_DIR/python-cache" \
  python3 -m unittest -v test_benchmark.py
PYTHONPYCACHEPREFIX="$PAPERCLIP_RUN_SCRATCH_DIR/python-cache" \
  python3 -m py_compile benchmark.py test_benchmark.py
./verify-candidate.sh
git -C ../../.. diff --check
```

结果：

- 4 tests 全通过：中文规范化/edit distance、nearest-rank p95、完整合成 manifest
  自动指标、缺失/未许可 corpus fail-closed；
- Python compile 通过；
- sherpa runtime/model/license/model card/tokens/3 个 ONNX 共 8 项 hash 复核通过；
- candidate JSON/SPDX 可解析且仍标记 `candidate-not-locked`；
- `git diff --check` 通过。

首次未重定向 bytecode cache 的 `py_compile` 因系统 Python 尝试写
`~/Library/Caches` 被 sandbox 拒绝；重定向到 run scratch 后通过。这不是产品
测试失败。

本检查点未运行真实 60 分钟 corpus、三轮 Release ASR、M5 Max 内存/温控/电源
测量或三人评审，不声称 CER/latency/RTF/T-01/M-01 已通过。

## 风险与下一步

- 风险：尚无满足“允许再分发、clean/noise 各 30 分钟、每组 ≥10 speakers”
  的固定音频 manifest；合成器输出也必须先有清晰的许可证据，不能假设可分发。
- 下一检查点：选定许可明确的公开/合成 corpus，生成并 hash-lock manifest；
  用 sherpa streaming API 产生逐 utterance hypothesis、processingMs 和
  partial/final events，按本 harness 连续执行三轮。
- 停止条件：许可证不清、需要私人录音/云 ASR/付费服务、或需要放宽批准门槛时，
  停止并升级 Board；否则继续普通工程实施。
