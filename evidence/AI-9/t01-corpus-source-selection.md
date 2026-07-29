# AI-9 T-01 Corpus Source Selection Checkpoint

日期：2026-07-29  
规格基线：AI-3 SDD-r3  
aggregate SHA-256：`7711eca19ef7c255a729adad4c48f97ac3b94639356f1a5a9d07723c49e5863e`

## 规格状态

无规格变化。固定门槛仍为 clean/noise 各至少 30 分钟、每组至少 10 speakers 且
男女均有、noise SNR 10–20 dB。T-01 未锁定，T-05 仍禁止进入。

## 实现状态

输入：既有 corpus builder/license evidence fail-closed 边界，以及公开、允许再分发
的普通话语料要求。

输出：

- `evidence/AI-9/t01/corpus-source-lock.json` 选择 AISHELL-1
  `AISHELL-ASR0009-OS1` test split；官方发布页标示 Apache-2.0，OpenSLR SLR33
  提供公开 archive，并锁定官方 checksum 清单中的两个 MD5；
- `prepare_aishell1_corpus.py` 新增完全离线、确定性的组装步骤：从 test split
  按 speaker round-robin 选择 5 female + 5 male，达到 30 分钟 clean 后，为每条
  生成独立 15 dB synthetic office ambience derivative；
- 输出仍交由 `build_corpus_manifest.py` 重新测时长、hash 和许可证快照，不信任
  preparation metadata；
- 新增测试覆盖噪声确定性/非同一性与 speaker gender metadata 解析。

停止条件：精确许可证快照尚未取证；在 archive 与许可证落盘验证前，source lock
保持 `selected-not-assembled`，不得声称 corpus 或许可证门通过。

## 验证状态

```sh
cd evidence/AI-9/t01
PYTHONPYCACHEPREFIX="$PAPERCLIP_RUN_SCRATCH_DIR/python-cache" \
  python3 -m unittest -v \
    test_benchmark.py test_build_corpus_manifest.py \
    test_prepare_aishell1_corpus.py
./verify-candidate.sh
git diff --check
shasum -a 256 \
  corpus-source-lock.json prepare_aishell1_corpus.py \
  test_prepare_aishell1_corpus.py
```

原始结果：`21 tests` 全通过；8 个 runtime/model/license 工件 hash 匹配；
candidate manifest 与 SPDX SBOM 可解析；`git diff --check` 通过。

检查点 SHA-256：

- `corpus-source-lock.json`: `5488b58cb84d47dc456dddbde3ef7bd061a1a999dbaa51d8bed69d2fa26da5d4`
- `prepare_aishell1_corpus.py`: `b75874aebae49fe810e97cab922c348ad539e7f55251029fb2d6c877fe10a94b`
- `test_prepare_aishell1_corpus.py`: `3a81ccb544911db645f2a7428224d07d2f86eb7811953cb04c9a97a36c1f44e9`

未执行：15G archive 下载/校验、license snapshot 落盘、60 分钟 manifest、
三轮 Release CER/RTF/latency/memory、三名中文母语评审。因此不宣称 T-01/M-01
通过。

## 风险与下一步

- 下载体积约 15G，下一 heartbeat 使用 run/task scratch 分段下载并按 OpenSLR
  MD5 校验；不把 archive 提交进产品仓库。
- 先从 archive 内/官方发布页保存精确许可证快照并复核 Apache-2.0 权利范围；
  若不明确允许派生/再分发，owner 为 Founding macOS Engineer，解除动作是停止
  AISHELL 路径并升级 Board，不设置假 inventory。
- 许可证通过后运行 preparation + manifest builder，固定 60 分钟清单与逐文件
  SHA-256，再进入三轮自动测量。
