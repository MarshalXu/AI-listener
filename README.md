# AI Listener

AI Listener 是一个原生、离线、本地优先的 macOS 中文听记原型。它从麦克风采集音频，
通过本地 sherpa-onnx streaming ASR 生成 partial/finalized 字幕，并将音频、逐字稿和
会话元数据保存在本机。

> 当前状态：MVP 原型。实时中文识别、录音落盘、会话列表、重开和按字幕时间点回听已经
> 接入；尚未完成正式产品签名、公证、跨机器分发和完整质量基准。

## 已实现

- 仅麦克风采集，不使用系统音频或 Screen Recording 权限
- 本地 sherpa-onnx 中文流式识别，无云 ASR
- 有界 ASR fan-out、背压隔离和 writer-first 音频写入
- partial 修正与 finalized 顺序/幂等持久化
- SQLite 会话存储、异常恢复和幂等删除
- 会话列表、重开、字幕时间点定位回听
- arm64 Release app 打包脚本、模型许可证与 SPDX SBOM

## 环境要求

- Apple Silicon Mac
- macOS 14 或更高版本
- Xcode Command Line Tools / Swift 6
- 系统 SQLite

当前模型为
[`sherpa-onnx-streaming-zipformer-zh-14M-2023-02-23`](https://github.com/k2-fsa/sherpa-onnx)。
仓库不会提交下载缓存；打包前需要准备与证据清单一致的 sherpa-onnx v1.13.2 arm64
runtime 和模型文件。

## 构建与测试

```bash
swift build
swift test
swift build -c release
```

如果受管执行环境禁止 Swift/Clang 写入默认缓存，可以指定项目外的临时缓存和 scratch
目录后再运行：

```bash
scratch="$(mktemp -d)"
CLANG_MODULE_CACHE_PATH="$scratch/clang" \
SWIFTPM_MODULECACHE_OVERRIDE="$scratch/swift" \
swift test --disable-sandbox --scratch-path "$scratch/swiftpm"
```

## 运行

开发运行：

```bash
swift run AIListenerApp
```

首次录音时 macOS 会请求麦克风权限。音频、逐字稿和数据库只写入本机 Application
Support 目录，不应提交到 Git。

## 打包 Release App

下载并校验锁定的 runtime/模型后运行：

```bash
./scripts/package-release-app.sh
```

输出位于 `dist/AIListener.app`，该目录是生成物，不纳入源码版本控制。

生成的 app 当前是：

- arm64 only
- 最低 macOS 14
- ad-hoc signed
- 未 Developer ID 签名、未 notarize

因此直接把 `.app` 发给另一台 Mac 可能被 Gatekeeper 拦截，或者因架构/系统版本不匹配
而无法运行。正式分发需要 Developer ID Application 签名、公证，并重新验证 dylib、
模型资源和 rpath。

## 项目结构

```text
Sources/AIListenerApp/          SwiftUI 应用
Sources/AIListenerCore/         采集、ASR、存储、恢复与回放核心
Sources/CSherpaShim/            sherpa-onnx 动态加载 C shim
Tests/AIListenerCoreTests/      自动测试
scripts/                        Release 验证与打包脚本
specs/AI-3/SDD-r3/              当前权威设计规格
evidence/                       可复现测试与许可证证据（不含下载缓存）
```

## 当前限制与未完成项

- 完整固定 60 分钟普通话语料、三轮 Release CER/RTF/延迟/峰值内存基准尚未完成。
- 三名中文母语评审尚未完成。
- M1 8 GB 设备验证尚未完成。
- 自动测试曾有一项 `AVAudioPlayer.playerUnavailable` 在受管运行环境不可执行，需在普通
  macOS 用户会话中复核。
- 当前发行包未签名/公证，不是面向外部用户的安装版本。

详细规格和验收债务见
[`specs/AI-3/SDD-r3/`](specs/AI-3/SDD-r3/) 与
[`evidence/AI-18/README.md`](evidence/AI-18/README.md)。

## 隐私边界

项目设计为本地处理，不需要账户、云同步或云 ASR。请勿将真实用户录音、Application
Support 数据库、私钥、签名证书或生产凭据提交到仓库。

## 许可证

第三方 runtime、模型和相关许可证证据位于 `evidence/` 及打包脚本引用的位置。本仓库
目前尚未声明项目自身的开源许可证；在选择许可证前，不应假定源代码可自由再分发。
