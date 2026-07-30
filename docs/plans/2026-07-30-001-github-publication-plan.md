# AI Listener GitHub 发布整理计划

## 1. 背景与目标

将当前 `checkpoint/ai-7-governance-20260729` 上的 AI Listener MVP 原型整理并发布到空仓库
`git@github.com:MarshalXu/AI-listener.git` 的 `main` 分支。

目标是让接手者能快速理解、构建和验证当前成果，同时如实披露原型限制，不把本地下载物、
私人数据或尚未完成的验收项推送到 GitHub。

## 2. 当前证据

- 最新实现基线：`519167a Fix transcript persistence and release refresh`。
- 本地 `main` 仍停留在初始基线 `21a85b1`，实际成果位于 checkpoint 分支。
- 目标远端 `git ls-remote` 无输出，当前为空仓库。
- 未提交内容：
  - `specs/AI-3/SDD-r3/05-tasks.md`
  - `specs/AI-3/SDD-r3/06-acceptance-traceability.md`
  - `evidence/AI-12/`（含被 `.gitignore` 排除的约 1 GB 下载语料，以及一份小型 continuation 文档）
- 仓库未发现常见私钥、GitHub token、OpenAI key 或 AWS key 模式。
- `dist/AIListener.app` 已被历史提交跟踪，最大单文件约 25 MB，未超过 GitHub 单文件 100 MB 限制。

## 3. 范围

### 包含

1. 增加项目级 README，说明功能、架构、构建/测试/打包方式、平台要求和已知限制。
2. 收紧 `.gitignore`，避免后续误提交本地数据库、录音、构建目录和重新生成的发行产物。
3. 核对并提交 Board 已批准的阶段性 T-01/T-07 规格 disposition。
4. 仅保留必要的小型文本证据；不提交 AI-12 下载语料和运行目录。
5. 复跑自动测试、Release build、diff/敏感信息/大文件检查。
6. 将整理后的当前分支发布为 GitHub `main`。

### 不包含

- 新功能开发或新的 ASR 模型选择。
- 完整 60 分钟三轮性能基准、三名母语评审或 M1 8 GB 验证。
- Developer ID 签名、公证或通用安装器。
- 上传用户录音、Application Support 数据库或任何私人音频。

## 4. 实施步骤

1. **仓库说明**
   - 新增根 `README.md`。
   - 明确当前为 arm64/macOS 14+ 本地原型。
   - 标注 sherpa-onnx 模型、构建命令、Release 打包命令及已知验收债务。

2. **仓库卫生**
   - 更新 `.gitignore`，忽略 `dist/` 的后续生成物、本地录音/数据库/日志及通用缓存。
   - 由于 `dist/AIListener.app` 已在历史中，最新树中移除生成的 app bundle，改由脚本重建。
   - 保留许可证、SBOM 和构建脚本来源；README 指向生成方法。

3. **规格与证据**
   - 提交两份已存在的 SDD disposition 修改。
   - 检查 `evidence/AI-12/t01-download-continuation.md` 是否包含有用且可公开的复现信息；若只是运行过程记录，则不纳入源码发布。

4. **验证**
   - 使用独立 scratch/cache 运行 `swift test --disable-sandbox`。
   - 使用独立 scratch/cache 运行 `swift build -c release --disable-sandbox`。
   - 运行 `git diff --check`。
   - 复查 Git 跟踪文件体积和常见密钥模式。
   - 确认 `git status` 仅包含本次计划内变更。

5. **提交与发布**
   - 创建一个发布整理提交。
   - 添加目标远端（若无现有 remote，则使用 `origin`）。
   - 将当前 HEAD 推送为远端 `main`，不强推、不覆盖非空历史。
   - 读取远端 refs 核对推送结果。

## 5. 验收标准

- GitHub `main` 指向本地验证过的发布整理 commit。
- 根 README 可独立指导构建、测试和打包。
- Git 索引中没有 GB 级语料、私人音频、数据库、密钥或本地缓存。
- 自动测试与 Release build 结果被如实报告。
- README 明确说明 ad-hoc/未公证发行限制及未完成验收债务。

## 6. 风险与回滚

- **远端非空**：停止推送，先报告差异；不使用 force push。
- **测试失败**：不掩盖失败；若属于本次整理引入则修复，否则在 README/交付说明中记录并决定是否推送。
- **误纳入大文件或敏感内容**：在首次远端推送前从索引移除；如果已经推送则停止并执行历史清理方案。
- **本地 checkpoint 分支命名**：不改写本地历史；通过 `HEAD:main` 发布，保留本地恢复路径。

## 7. 执行记录

- 已将 `evidence/AI-12/` 与 `evidence/AI-14/source/` 共约 2.2 GB 可重新下载语料缓存
  移至 macOS 废纸篓，未删除构建所需的锁定 runtime/模型。
- 已从最新 Git 树移除可重建的 `dist/AIListener.app`，并将 `dist/` 加入忽略规则。
- `swift test --disable-sandbox`：46 tests / 5 suites passed。
- `swift build -c release --disable-sandbox`：passed。
- 当前跟踪文件总量约 0.9 MiB，无超过 20 MiB 的当前跟踪文件。
