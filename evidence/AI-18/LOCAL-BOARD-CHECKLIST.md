# local-board 真人麦克风与最终 Demo 验收清单

仅使用测试人员现场口述内容，不使用或上传真实用户录音。开始前确认网络可断开，
系统设置中只涉及 Microphone；不得授予 Screen Recording。

本清单必须使用修复首轮空 `frameSink` 缺陷之后的 Release；先核对
`dist/AIListener.app.sha256` 自身 SHA-256 为
`94722659b1e315e903896137dd4319577bab5b6452e9a65ba9408a95b2348a0a`。

## TCC 与闭环

- [ ] 校验 `dist/AIListener.app.sha256`，确认 `codesign --verify --deep --strict` 成功。
- [ ] 首次启动后、点击录音前没有权限弹窗，也没有 Session。
- [ ] 明确点击“开始录音”后只出现 Microphone TCC；确认无 Screen Recording。
- [ ] 先执行拒绝路径：不开始捕获、不创建空 Session，UI 可打开麦克风设置。
- [ ] 授予 Microphone 后重启 app，口述一段非私人中文测试句。
- [ ] 录音时能看到 partial 更新与 finalized 滚动字幕；ASR 不可用时须明确 degraded，
      但录音仍继续。
- [ ] 连续产生至少 3 条 finalized，确认无 `TRANSCRIPT_PERSIST_FAILED`；若失败，UI
      须显示冒号后的具体安全底层错误码。
- [ ] 点击“清屏”后主页面字幕清空；记录页中的 finalized transcript 和音频仍存在。
- [ ] 停止后无需手动刷新，“记录”页立即出现本地音频与完整 finalized transcript；
      退出并重启 App 后仍可打开。
- [ ] 点击开头/中间/结尾 finalized 时间点各 10 次，保存 30 行 target/actual/error；
      使用批准算法确认 p95 ≤250 ms、max ≤500 ms。
- [ ] 模型临时不可用的恢复演示不得删除已有 Session 或音频。
- [ ] Activity Monitor / `lsof` 确认录音与转写期间无产品网络连接。

## 记录

填写设备型号、hardware identifier、macOS version/build、Xcode/Swift、arm64、
app/清单 SHA-256、电源状态、温控状态、执行时间、TCC 截图/录像路径、30 行 seek
结果路径以及 pass/fail。任何失败保留原始日志并退回 AI-18 修复；不要删除用户数据
来“恢复”。真人 TCC 和最终 Demo 的接受人：`local-board`。
