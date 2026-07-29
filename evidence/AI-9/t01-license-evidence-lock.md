# AI-9 T-01 License Evidence Lock Checkpoint

日期：2026-07-29  
规格基线：AI-3 SDD-r3  
aggregate SHA-256：`7711eca19ef7c255a729adad4c48f97ac3b94639356f1a5a9d07723c49e5863e`

## 规格状态

规格未修改。T-01 的公开/合成、允许再分发语料与许可证/SBOM 门仍保持原值；
T-01 未锁定，T-05 仍禁止进入。

## 实现状态

输入：现有 deterministic corpus builder、benchmark validator 与待审许可证证据。

输出：

- corpus inventory 必须指定语料根内非空的本地许可证快照；
- builder 自行计算 `license.evidenceSHA256`，不信任调用者提供的 hash；
- benchmark 重验快照路径和 hash，快照被替换时 fail closed；
- JSON Schema 同步要求 `evidenceFile/evidenceSHA256`；
- 新增路径逃逸、缺失、空文件、hash mismatch 测试。

停止条件：本增量没有选择具体 corpus，也没有判断任何许可证兼容。若后续许可
不清、需要私人录音、云 ASR、付费服务或放宽 SDD 门槛，停止并升级 Board。

## 验证状态

可复现命令：

```sh
mkdir -p "$PAPERCLIP_RUN_SCRATCH_DIR/python-cache"
(cd evidence/AI-9/t01 &&
  PYTHONPYCACHEPREFIX="$PAPERCLIP_RUN_SCRATCH_DIR/python-cache" \
  python3 -m unittest -v test_benchmark.py test_build_corpus_manifest.py)
evidence/AI-9/t01/verify-candidate.sh
git diff --check
shasum -a 256 \
  evidence/AI-9/t01/benchmark.py \
  evidence/AI-9/t01/test_benchmark.py \
  evidence/AI-9/t01/build_corpus_manifest.py \
  evidence/AI-9/t01/test_build_corpus_manifest.py \
  evidence/AI-9/t01/corpus-manifest.schema.json
```

原始结论：19 tests 全通过；8 个既有 candidate runtime/model/license artifact
hash 全匹配；candidate manifest 与 SPDX SBOM 可解析；`git diff --check` 通过。
源码/Schema hash 见 `evidence/AI-9/t01/README.md`。

未验证：60 分钟固定语料、具体 corpus 许可证兼容、三轮 Release ASR、CER、
partial/final latency、RTF、内存/磁盘、三名中文母语评审、T-01/M-01。

## 风险与下一步

- 当前风险仍是固定语料与评审资源尚未取得，不能锁定 adapter。
- 下一 live continuation path：选择公开且可再分发的普通话 corpus 来源，保存
  精确许可证快照并组装满足 clean/noise、speaker/gender/SNR 约束的 60 分钟
  inventory；先运行 builder/validator，再决定能否进入三轮 Release 测量。
