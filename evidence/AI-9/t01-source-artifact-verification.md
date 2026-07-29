# AI-9 T-01 Source Artifact Verification Checkpoint

日期：2026-07-29  
规格基线：AI-3 SDD-r3  
aggregate SHA-256：`7711eca19ef7c255a729adad4c48f97ac3b94639356f1a5a9d07723c49e5863e`

## 规格状态

无规格变化。T-01 未锁定，`t05Allowed=false`；本检查点不把 archive 完整性等同于
许可证兼容、60 分钟质量基准或三名中文母语评审。

## 实现状态

输入：

- `corpus-source-lock.json` 中已选定的 AISHELL-1 / OpenSLR SLR33 archive 名称和
  官方 MD5；
- 只允许公开/合成音频、不得读取私人录音的边界；
- 后续 archive 解压必须保持在 staging root 内的要求。

输出：

- `verify_source_artifacts.py`：完全离线核验全部锁定 archive；复核 MD5、记录
  SHA-256、解析 gzip tar 但不解压，并拒绝绝对路径、`..`、symbolic link 和
  hard link；
- `test_verify_source_artifacts.py`：覆盖正常报告、内容改变、缺失 archive 与 tar
  路径穿越；
- `README.md`：记录从零命令与“partial download 必须 fail closed”的边界。

## 验证状态

公开小型工件下载与独立核验：

```sh
curl -L --fail --retry 3 \
  -o "$PAPERCLIP_RUN_SCRATCH_DIR/t01-source-evidence/resource_aishell.tgz" \
  https://www.openslr.org/resources/33/resource_aishell.tgz
md5 "$PAPERCLIP_RUN_SCRATCH_DIR/t01-source-evidence/resource_aishell.tgz"
shasum -a 256 \
  "$PAPERCLIP_RUN_SCRATCH_DIR/t01-source-evidence/resource_aishell.tgz"
tar -tzf \
  "$PAPERCLIP_RUN_SCRATCH_DIR/t01-source-evidence/resource_aishell.tgz"
```

原始结果：

- MD5 `957d480a0fcac85fc18e550756f624e5`，与 source lock 一致；
- SHA-256 `1a6749854456e9402bc7295767937367afed1327799a5e1df0ed64baa5f77409`；
- tar 可读，包含 `resource_aishell/lexicon.txt` 与
  `resource_aishell/speaker.info`。

自动回归：

```sh
cd evidence/AI-9/t01
PYTHONPYCACHEPREFIX="$PAPERCLIP_RUN_SCRATCH_DIR/python-cache" \
  python3 -m unittest -v \
    test_benchmark.py test_build_corpus_manifest.py \
    test_prepare_aishell1_corpus.py test_verify_source_artifacts.py
./verify-candidate.sh
git -C ../../.. diff --check
```

结果：24 tests 全通过；8 个 runtime/model/license 工件 SHA-256 匹配；
candidate manifest 与 SPDX SBOM 可解析；`git diff --check` 通过。

检查点 SHA-256：

- `verify_source_artifacts.py`:
  `bf79d9278a09c23ed960d88332a19e3c38f8a5a2061a2b13a58a6c18dd084bd2`
- `test_verify_source_artifacts.py`:
  `a96d45bcfaa55aa2baa9136e95a0d438c5be3d7cf368bfa0081ffc5f7b4b488b`
- `README.md`:
  `b05f5983a2b6cb1b3a65f87af9a8d8d9b13daba4d7467e3625736eca1e1afd73`

## 风险与下一步

官方 AISHELL 产品页许可证快照请求返回 HTTP 429，未取得内容；这不是产品 blocker，
但许可证门仍未验证。15 GB `data_aishell.tgz` 也尚未下载/核验。因此未执行固定
60 分钟 corpus assembly、三轮 Release CER/RTF/latency/memory 或三人评审。

下一 live continuation path：从官方可复现端点取得精确 Apache-2.0 许可证快照并
记录响应来源/hash；分段下载 `data_aishell.tgz` 至 Paperclip scratch，核对锁定
MD5 后运行本 verifier。若权利范围仍不清，owner 为 Founding macOS Engineer，
解除动作是停止 AISHELL 路径并升级 Board；不得自行设置
`redistributionAllowed=true`。
