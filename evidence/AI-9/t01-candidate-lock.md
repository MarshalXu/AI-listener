# AI-9 T-01 Candidate Manifest / SBOM Checkpoint

日期：2026-07-29  
规格基线：AI-3 SDD-r3  
aggregate SHA-256：`7711eca19ef7c255a729adad4c48f97ac3b94639356f1a5a9d07723c49e5863e`

## 规格状态

规格未修改。AI-4 已记录的 T-01 停止条件仍成立：固定 60 分钟质量语料、
partial/final latency 和三名中文母语评审尚未完成，因此本增量不锁定 adapter，
也不允许进入 T-05。

## 输入

- AI-4 锁定的 sherpa-onnx v1.13.2 runtime、14M 中文 streaming Zipformer 模型；
- AI-4 三轮 M5 Max 短样本原始探针；
- runtime Apache-2.0 LICENSE、模型 README 中的 Apache-2.0 声明；
- SDD T-01 对 candidate manifest、模型 hash、许可证和 SBOM 的要求。

## 输出

- `evidence/AI-9/t01/adapter-candidate.json`：机器可读 runtime/model/config/hash，
  显式标记 `candidate-not-locked` 与 `t05Allowed=false`；
- `evidence/AI-9/t01/sbom.spdx.json`：SPDX 2.3 runtime/model inventory；
- `evidence/AI-9/t01/verify-candidate.sh`：解析两份 JSON 并复核 runtime archive、
  model archive、LICENSE、model card、tokens 与三个 ONNX 文件的 SHA-256。

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

- 8 个锁定工件 hash 全部匹配，JSON 均可解析；
- `git diff --check` 通过；
- Debug build 完成，Swift Testing `25 tests / 3 suites` 全通过。

这些结果验证的是 inventory/hash 与既有 T-02～T-04 自动回归，不代表 T-01、
Release、M5 Max 完整性能、真人 TCC 或最终 Demo 已通过。

## 风险与下一步

- 当前真正缺口是可复现的固定公开/合成 60 分钟中文 reference corpus、
  clean/noise CER、streaming partial/final latency 与三人可理解度。
- 下一检查点：在不使用私人录音的前提下构建并固化许可清晰的合成中文 corpus
  manifest，先执行自动可完成的 CER/RTF/latency 三轮指标；三人评审保留为明确的
  local-board/指定评审验收动作。
- 停止条件：许可证不清、需要真实用户录音、云 ASR、付费服务或放宽 SDD 门槛时停止并升级。
