# AI-4 / T-01：ASR 模型基准与许可证锁定

- 规格基线：AI-3 SDD-r3
- aggregate SHA-256：`7711eca19ef7c255a729adad4c48f97ac3b94639356f1a5a9d07723c49e5863e`
- 执行日期：2026-07-29
- 结论：**本轮不锁定任何 ASR adapter。WhisperKit 与 sherpa-onnx 均未通过完整 T-01 门槛。**

## 1. 状态

- 规格状态：SDD-r3 未修改；T-01 的隔离范围例外与官方来源下载已由 Board 分别接受。
- 实现状态：未做产品集成，未修改产品源码，未创建或执行 T-04～T-07。
- 验证状态：完成 runtime/模型来源与哈希锁定、许可证初审，以及 sherpa-onnx 的 M5 Max 三轮短样本性能探针；未完成固定 60 分钟语料、CER、partial/final latency 与 3 人可理解度门。
- 风险：WhisperKit 转换权重无明确 license 元数据；sherpa 短样本不能代表 SDD 质量门或真实会议场景。
- 下一步：Board 决定是否提供/批准符合 SDD 的固定公开语料与中文母语评审资源，或以新规格修订取消/调整门槛；在此之前禁止进入 T-05。

## 2. 目标环境

| 字段 | 值 |
|---|---|
| 设备 | MacBook Pro `Mac17,6` |
| SoC / CPU | Apple M5 Max，18 cores |
| Unified memory | 48 GiB（51,539,607,552 bytes） |
| OS | macOS 26.5.2 build `25F84`，Darwin 25.5.0 |
| 架构 | arm64 |
| Xcode | 26.6 build `17F113` |
| Swift | 6.3.3 (`swiftlang-6.3.3.1.3 clang-2100.1.1.101`) |
| SDK | macOS 26.5 |
| 构建/运行配置 | 官方 Release binary；CPU provider；2 threads；greedy search |
| 电源 | AC attached，battery 80%，not charging |
| 温控 | `pmset -g therm`：无 thermal/performance warning 记录 |

序列号、Hardware UUID、UDID、用户名和计算机名未写入证据。

## 3. 候选 manifest

| 候选 | Runtime 锁定 | 模型锁定 | 状态 |
|---|---|---|---|
| WhisperKit | Argmax OSS `v1.0.0`, commit `25c62997041c134b03ca82731ce2f6fd2cae1eb9` | `argmaxinc/whisperkit-coreml`, revision `97a5bf9bbc74c7d9c12c755d04dea59e672e3808`, `openai_whisper-small`（未下载） | 未通过：模型权重/转换工件许可证链不足；未进入性能执行 |
| sherpa-onnx | `v1.13.2`, commit `13d0ae6c539d2809d32f5eaa3ef1db0c459d0b24` | `sherpa-onnx-streaming-zipformer-zh-14M-2023-02-23`, archive SHA-256 `2cbd71b640d9c37d3784f29367333a4577b0398b62e9deeed418170b081cba8b` | 短样本性能探针通过；完整 T-01 未通过 |

Runtime archive：

- sherpa macOS arm64 shared/no-TTS archive SHA-256：`d880aaa79d36b784168a0398b278813d57ba8e135f468894b8f134b664e2e225`
- 解压 runtime：81,932 KiB
- 解压模型：80,200 KiB
- 压缩模型：约 70.5 MiB
- 均远低于下载 2.0 GB、落盘 4.0 GB 门槛。

## 4. 样本与参数

本次只使用 sherpa 官方模型归档内附的公开测试 WAV，不使用、不读取、不上传任何用户录音。

| 文件 | SHA-256 | 时长 |
|---|---|---:|
| `test_wavs/0.wav` | `668bf8df51a10027b84d5d8816a1ce11ae93545538dc05cfe2aa6811d399c250` | 5.6115 s |
| `test_wavs/1.wav` | `30edbabea84ca4c076f5b43bb44495f436f6711319c32a200d3fc5c67c1fee1d` | 约 5.2 s |
| `test_wavs/8k.wav` | `0ed3bddacf0a23477d2b3c07ff9c24ad9c1fc3b31cdd47cb0773441e8e045cde` | 约 4.5 s |

参数固定为 CPU provider、2 threads、`greedy_search`、int8 encoder、fp32 decoder、int8 joiner。三轮均为独立进程启动。

## 5. 原始结果摘要

| 轮次 | wall | max RSS | 占 48 GiB | 0.wav RTF | 1.wav RTF | 8k.wav RTF | 输出一致 |
|---:|---:|---:|---:|---:|---:|---:|---|
| 1 | 0.30 s | 128,270,336 B | 0.249% | 0.020 | 0.021 | 0.022 | 是 |
| 2 | 0.29 s | 128,335,872 B | 0.249% | 0.020 | 0.021 | 0.022 | 是 |
| 3 | 0.29 s | 127,451,136 B | 0.247% | 0.020 | 0.021 | 0.022 | 是 |

三个短样本逐轮文本完全一致。该一致性仅作为功能/确定性代理，不是 CER；归档没有在本证据包中提供可独立核验的 reference transcript manifest。

未测且不得宣称通过：

- clean 30 分钟 / noise 30 分钟、至少 10 名说话人；
- clean/noise CER；
- 20 条盲测、3 名中文母语评审与 90% 可理解度；
- 固定 60 秒流的 partial p95 / finalized p95；
- M1 8 GB 实机（状态：待目标设备验证）。

## 6. 可复现命令

下载：

```sh
git clone --depth 1 --branch v1.13.2 https://github.com/k2-fsa/sherpa-onnx.git runtime/sherpa-onnx
curl -fL -o runtime/sherpa-runtime.tar.bz2 \
  https://github.com/k2-fsa/sherpa-onnx/releases/download/v1.13.2/sherpa-onnx-v1.13.2-osx-arm64-shared-no-tts.tar.bz2
curl -fL -o models/sherpa-model.tar.bz2 \
  https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-streaming-zipformer-zh-14M-2023-02-23.tar.bz2
```

每轮执行：

```sh
/usr/bin/time -lp runtime/sherpa-onnx-v1.13.2-osx-arm64-shared-no-tts/bin/sherpa-onnx \
  --tokens=models/sherpa-onnx-streaming-zipformer-zh-14M-2023-02-23/tokens.txt \
  --encoder=models/sherpa-onnx-streaming-zipformer-zh-14M-2023-02-23/encoder-epoch-99-avg-1.int8.onnx \
  --decoder=models/sherpa-onnx-streaming-zipformer-zh-14M-2023-02-23/decoder-epoch-99-avg-1.onnx \
  --joiner=models/sherpa-onnx-streaming-zipformer-zh-14M-2023-02-23/joiner-epoch-99-avg-1.int8.onnx \
  --provider=cpu --num-threads=2 --decoding-method=greedy_search \
  models/sherpa-onnx-streaming-zipformer-zh-14M-2023-02-23/test_wavs/0.wav \
  models/sherpa-onnx-streaming-zipformer-zh-14M-2023-02-23/test_wavs/1.wav \
  models/sherpa-onnx-streaming-zipformer-zh-14M-2023-02-23/test_wavs/8k.wav
```

## 7. 许可证与再分发结论

| 工件 | 官方证据 | 文件 SHA-256 | 结论 |
|---|---|---|---|
| Argmax OSS / WhisperKit runtime | repo `LICENSE`（MIT）与 `NOTICES` | LICENSE `b8673adf…85c4`; NOTICES `8af554e9…9913` | runtime 可按 MIT 使用/再分发并保留声明；vendored 依赖须遵守 NOTICES |
| `argmaxinc/whisperkit-coreml` | model card revision `97a5bf9…` 无 `license` 字段、README 无权重许可文本 | 不适用（未下载） | **证据不足，不允许进入集成或再分发** |
| sherpa-onnx runtime | repo `LICENSE`（Apache-2.0） | `cfc7749b…3d30` | 可按 Apache-2.0 使用/再分发；分发时保留 LICENSE/NOTICE 与修改声明 |
| sherpa 14M 转换模型 | 归档 `README.md` 明确 `license: apache-2.0` 并指向转换来源 | archive `2cbd71b…ba8b` | 许可证证据可追溯；实际分发仍需把模型 card/LICENSE/NOTICE 纳入 SBOM |

本报告不是法律意见。WhisperKit 的问题不是已证明“不允许”，而是具体转换权重缺乏足够证据；按 T-01 停止条件必须视为未通过。

## 8. 原始证据索引

- `results/sherpa-round-{1,2,3}.stdout.txt`
- `results/sherpa-round-{1,2,3}.stderr.txt`
- runtime/model Git checkout、LICENSE/NOTICES、模型 README、下载归档与三条 WAV 均保留在本目录下。

原始结果文件 SHA-256：

- r1 stderr `6bf5b3c3…4ecd`; stdout `22a46033…68a9`
- r2 stderr `766806e7…0a9`; stdout `ddd29ac2…24b`
- r3 stderr `7aa65c26…405`; stdout `d9202ad9…ce1`

## 9. 验收结论与停止条件

输入：SDD-r3 门槛、批准的隔离范围、锁定官方候选与公开短样本。

输出：候选 manifest、环境、下载/模型/runtime hash、三轮原始性能数据、许可证链初审、ADR。

验收证据：本报告、六份逐轮原始日志、runtime/model/LICENSE/NOTICE/model card 与哈希。

停止条件已触发：

1. WhisperKit 具体 Core ML 权重许可证证据不清；
2. sherpa 虽通过短样本 RTF/内存/体积探针，但没有满足 SDD 的固定 60 分钟质量语料、reference manifest、partial/final latency fixture 与 3 人评审。

因此不得锁定 engine，不得把“探针通过”写成“T-01 已验证通过”，不得进入 T-05。
