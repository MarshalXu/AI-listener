# AI-9 T-01 Resource Archive Checkpoint

日期：2026-07-29  
规格基线：AI-3 SDD-r3  
aggregate SHA-256：`7711eca19ef7c255a729adad4c48f97ac3b94639356f1a5a9d07723c49e5863e`

## 规格状态

无规格变化。T-01 仍未锁定，`t05Allowed=false`。本检查点只验证
AISHELL-1 的小型 metadata archive 和主归档下载路径，不把部分下载或 metadata
archive 等同于固定 60 分钟语料。

## 实现状态

输入：

- `evidence/AI-9/t01/corpus-source-lock.json` 中锁定的 OpenSLR SLR33 URL、
  archive 名称及 MD5；
- 已获授权的公开数据下载；
- `PAPERCLIP_RUN_SCRATCH_DIR`，不读取或写入真实用户录音。

输出：

- 完整下载 `resource_aishell.tgz` 到 run scratch；
- 建立 `data_aishell.tgz` 的官方 HTTPS 下载和 `curl --continue-at -` 续传路径；
- 主归档在 123 秒内取得约 609 MiB 后主动停止；该不完整 scratch 文件不是验收
  工件，未进入 verifier 或 corpus assembly。

停止条件：只有主归档完整下载、MD5 匹配
`2f494334227864a8a8fec932999db9d8`、离线 tar member 安全扫描通过后，才允许解包
和组装 corpus。任一 hash 或 archive 检查失败则停止 AISHELL 路径并调查来源。

## 验证状态

下载命令：

```sh
mkdir -p "$PAPERCLIP_RUN_SCRATCH_DIR/t01-aishell"
curl -L --fail --retry 5 --retry-all-errors --continue-at - \
  --output "$PAPERCLIP_RUN_SCRATCH_DIR/t01-aishell/resource_aishell.tgz" \
  https://www.openslr.org/resources/33/resource_aishell.tgz
curl -L --fail --retry 5 --retry-all-errors --continue-at - \
  --output "$PAPERCLIP_RUN_SCRATCH_DIR/t01-aishell/data_aishell.tgz" \
  https://www.openslr.org/resources/33/data_aishell.tgz
```

完整 resource archive 原始结果：

- size：`1246920 bytes`
- MD5：`957d480a0fcac85fc18e550756f624e5`，与 source lock 匹配
- SHA-256：`1a6749854456e9402bc7295767937367afed1327799a5e1df0ed64baa5f77409`
- `tar -tzf ... | wc -l`：`3`

自动验证：

```sh
cd evidence/AI-9/t01
PYTHONPYCACHEPREFIX="$PAPERCLIP_RUN_SCRATCH_DIR/python-cache" \
  python3 -m unittest -v \
    test_verify_source_artifacts.py test_prepare_aishell1_corpus.py \
    test_build_corpus_manifest.py test_benchmark.py
```

原始结论：`Ran 25 tests in 0.100s`，`OK`。这只证明下载前后的 fail-closed
工具与合成夹具，没有证明真实 AISHELL 主归档、CER、latency、RTF、memory 或
intelligibility 门。

## 风险与下一步

- OpenSLR 主归档服务器报告约 14.5 GiB；本次稳定吞吐约 5 MiB/s，预计单次完整
  传输约 50 分钟。这是耗时输入，不是产品 blocker。
- 下一 live continuation：在一个允许至少 60 分钟执行的 heartbeat 中完整下载两项
  archive 到 run scratch，执行 `verify_source_artifacts.py` 生成完整 MD5/SHA-256/
  tar member report；通过后再解包并运行 `prepare_aishell1_corpus.py`。
- 未执行：主归档完整 hash/archive 扫描、固定 corpus assembly、三轮 Release
  benchmark、三名中文母语评审、真人 TCC、最终 Demo。
