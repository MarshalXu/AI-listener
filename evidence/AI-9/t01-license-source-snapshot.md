# AI-9 T-01 License Source Snapshot Checkpoint

日期：2026-07-29  
规格基线：AI-3 SDD-r3  
aggregate SHA-256：`7711eca19ef7c255a729adad4c48f97ac3b94639356f1a5a9d07723c49e5863e`

## 规格状态

无规格变化。T-01 未锁定，`t05Allowed=false`。本检查点只锁定 AISHELL-1
许可证来源证据，不把许可证来源声明等同于完整 T-01、M-01 或产品分发验收。

## 实现状态

输入：

- 已选择但未组装的 AISHELL-1 / OpenSLR SLR33 source lock；
- 官方 OpenSLR `info.txt`、`about.html`；
- AI-4 已锁定的 Apache License 2.0 完整条款。

输出：

- `licenses/AISHELL-1-OpenSLR-info.txt`：官方机器可读元数据快照，明确声明
  `license: Apache License v.2.0`；
- `licenses/AISHELL-1-OpenSLR-about.html`：同目录完整描述快照，保留
  “free for academic use”原文，避免选择性取证；
- `corpus-source-lock.json`：记录取得时间、URL、三个证据文件及 SHA-256，并保持
  `evidence-locked-pending-final-corpus-review`；
- `verify_source_artifacts.py`：archive 校验前 fail closed 核验 license declaration、
  description 和完整 terms 的 hash、SPDX 声明及 review status；
- `test_verify_source_artifacts.py`：增加证据篡改和错误 review status 拒绝测试。

停止条件：本检查点没有把 description 的用途说明解释为新许可证，也没有设置
`redistributionAllowed=true`。最终 corpus inventory 仍须在 archive 内容与来源证据
联合复核后显式确认。若发现 archive 内条款冲突或不允许再分发，停止 AISHELL 路径并
升级 Board。

## 验证状态

官方快照取得命令：

```sh
curl -L --fail --retry 3 \
  -o "$PAPERCLIP_RUN_SCRATCH_DIR/t01-license/info.txt" \
  https://www.openslr.org/resources/33/info.txt
curl -L --fail --retry 3 \
  -o "$PAPERCLIP_RUN_SCRATCH_DIR/t01-license/about.html" \
  https://www.openslr.org/resources/33/about.html
```

HTTP 时间：`2026-07-29T11:39:52Z`，两项均成功。仓库副本用 `cmp` 与下载内容
逐字节相同：

- declaration SHA-256:
  `f9e49e4ca0d67be4f0dcc21baee5e6c26dad15b9be1b9fd7f487729edbe532a9`
- description SHA-256:
  `e9647af0026404f4d37e5d918ddb14019439668b1bcd9d5b70db34584b7af4a9`
- Apache-2.0 terms SHA-256:
  `cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30`

自动验证：

```sh
cd evidence/AI-9/t01
PYTHONPYCACHEPREFIX="$PAPERCLIP_RUN_SCRATCH_DIR/python-cache" \
  python3 -m unittest -v \
    test_benchmark.py test_build_corpus_manifest.py \
    test_prepare_aishell1_corpus.py test_verify_source_artifacts.py
./verify-candidate.sh
cmp licenses/AISHELL-1-OpenSLR-info.txt \
  "$PAPERCLIP_RUN_SCRATCH_DIR/t01-license/info.txt"
cmp licenses/AISHELL-1-OpenSLR-about.html \
  "$PAPERCLIP_RUN_SCRATCH_DIR/t01-license/about.html"
git -C ../../.. diff --check
```

原始结论：`Ran 25 tests ... OK`；8 个既有 runtime/model/license 工件 SHA-256
匹配；candidate manifest 与 SPDX SBOM 可解析；两个 `cmp` 及
`git diff --check` 均退出 0。

未执行：15 GB archive 下载/核验、60 分钟 corpus assembly、三轮 Release
CER/RTF/streaming latency/memory、三名中文母语评审、真人 TCC、最终 Demo。

## 风险与下一步

- 许可证声明证据已不可变锁定，但最终 corpus review 尚未完成，因此不宣称许可证门
  或 T-01 通过。
- 下一 live continuation path：分段下载
  `https://www.openslr.org/resources/33/data_aishell.tgz` 到
  `PAPERCLIP_RUN_SCRATCH_DIR`，核对锁定 MD5
  `2f494334227864a8a8fec932999db9d8`，运行离线 archive verifier，再组装固定
  clean/noise 各 30 分钟 corpus。
