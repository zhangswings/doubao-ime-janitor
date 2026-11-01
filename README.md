# doubao-ime-janitor（暂定名）

> macOS 上的「输入法管家」：**语音识别用豆包输入法，打字永远用微信输入法**。
> 按住右⌘（或 FN）说话，松手即上屏；说完约 1~6 秒（按录音时长自适应）自动切回微信输入法。

基于 [Paxxs/Doubao-ime-hammerspoon](https://github.com/Paxxs/Doubao-ime-hammerspoon) 的场景重构，架构与上游完全不同（见下文）。

## 工作原理

豆包输入法自带两种语音模式（长按/免按）和「全局唤起语音」（跨输入法调起），**它自己就能完成语音输入的全流程**。但它有个顽疾：语音结束上屏时会把系统输入源劫持成自己，从此卡住不切回。

本脚本因此只做一件事——**当好输入法管家**：

1. 轮询（0.25s）检测**麦克风占用**：只要有 App 在录音，绝不碰输入法
2. 录音结束后，按 `clamp(1.2, 0.3×录音秒数, 6)` 秒的延迟，把输入源送回微信输入法
3. 非录音状态下豆包滞留（劫持残留、FN 触发后等），同样送回

不模拟任何按键、不主动切换输入法、不打扰任何正常录音。

## 与上游的差异

| | 上游 Doubao-ime-hammerspoon | 本项目 |
|---|---|---|
| 语音触发 | 脚本模拟双击 Option | 豆包原生手势（右⌘长按/FN/免按） |
| 输入法切换 | 脚本切到豆包再"恢复上一次" | 完全不切，只做劫持后的回切 |
| 录音判断 | 右 Command 按键事件（易漏） | 麦克风占用轮询（对所有触发方式生效） |
| 恢复目标 | "上一次输入法"（记录会被劫持污染） | 强制回指定 HOME 输入法 |
| 长语音 | — | 自适应延迟，避免打断「智能文字整理」 |

上游「恢复上一次输入法」的设计在本机实测有缺陷：语音结束时豆包劫持输入源，会把"上一次"的记录污染成豆包自己，导致永远切不回。

## 安装

```bash
brew install --cask hammerspoon
mkdir -p ~/.hammerspoon && cp init.lua ~/.hammerspoon/init.lua
open -a Hammerspoon   # 首次启动授予「辅助功能」权限
```

前置条件：已安装豆包输入法，并在其设置中开启「长按模式」（建议绑定右⌘）与「全局唤起语音」；建议解绑「免按模式」避免单击误触发。

（install.sh 安装脚本待补充。）

## 配置

`init.lua` 顶部常量：

| 常量 | 默认值 | 说明 |
|---|---|---|
| `TARGET_SOURCE_ID` | `com.bytedance.inputmethod.doubaoime.pinyin` | 豆包输入法源 ID |
| `HOME_SOURCE_ID` | `com.tencent.inputmethod.wetype.pinyin` | 打字主力输入法源 ID |
| `BACK_HOME_DELAY_MIN / FACTOR / MAX` | 1.2 / 0.3 / 6.0 | 回切延迟 = clamp(MIN, FACTOR×录音秒数, MAX) |
| `POLL_INTERVAL` | 0.25 | 麦克风轮询间隔 |

## 调试

- 日志：`tail -f /tmp/hs-doubao-debug.log`
- URL 通道：`open "hammerspoon://doubaoime?cmd=check|home|switch"`
- 菜单栏图标（麦克风）里有：强制回微信输入法 / 打开豆包设置 / 重载脚本

## 踩坑记录（改代码前必读）

1. **不要自己切 IME、不要模拟按键**——会和豆包原生手势打架（v1~v3 的教训）
2. **右 Command 的 flagsChanged 事件可能收不到**（被豆包全局监听拦截），录音判断只能靠麦克风占用
3. **语音文字以预编辑态（下划线）插入，切换输入法会丢弃未提交文字**——只能在松手提交后再切
4. 长语音的润色需要数秒，回切延迟必须按录音时长自适应

## 关于自动更新

本项目**不包含、也不需要**任何自动更新机制（上游亦无）。Hammerspoon 自身的更新检查建议保持关闭（`SUEnableAutomaticChecks = 0`）。豆包输入法 App 内置的更新器属于字节跳动的 App，与本项目无关。

## License

上游仓库未声明 License。本项目为个人使用重构，发布前需确定开源协议（建议 MIT 并注明上游启发）。
