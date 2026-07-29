# AI-6 / T-03 验收记录

规格基线：AI-3 SDD-r3，aggregate SHA-256
`7711eca19ef7c255a729adad4c48f97ac3b94639356f1a5a9d07723c49e5863e`。

## 自动化证据

- 2026-07-29，`swift test`，arm64e-apple-macos14.0：5 tests / 1 suite 全部通过。
- 覆盖 `notDetermined`、`denied`、`restricted`、`authorized`、无设备、启动失败后的 retry、中断、停止幂等。
- 静态扫描 `ScreenCaptureKit|CGRequestScreenCaptureAccess|SCShareableContent|URLSession`：源码、测试、配置中 0 命中。
- `Info.plist` 仅声明 `NSMicrophoneUsageDescription`；文件 SHA-256：
  `253a77135a0c9560b6e6fc419baaad802a7ca050594cdeba07f38d14c54eba53`。

## 手工验收（待执行）

必须在独立 app bundle / 当前 M5 Max 实机执行并附截图或录像；不能用单元测试替代 TCC：

1. 重置麦克风 TCC；点击开始前无权限弹窗，点击后仅出现麦克风请求。
2. 允许：UI 进入“正在录音”，红色状态点可见；停止回到“未录音”。
3. 拒绝：不启动捕获，显示设置入口；再次点击不自动弹窗。
4. restricted：不启动捕获，显示安全错误码与设置入口。
5. 录音时拔出/切换输入设备：进入 interrupted → stopping → idle，终止原因可见，无静默继续。
6. 无输入设备或 engine 启动失败：进入 failed，可重试。

## 停止条件

若需要 ScreenCaptureKit、系统音频、未批准 entitlement、目录例外或绕过用户授权，停止并升级 Board。
