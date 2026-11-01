-- janitor-config.example.lua · 个人配置示例
--
-- 用法：把本文件复制为 ~/.hammerspoon/janitor-config.lua，然后按需修改。
-- 只需要写你想覆盖的字段，其余字段沿用 init.lua 内置默认值。
-- 修改后在 Hammerspoon 菜单选「重载脚本」（或运行 hs.reload()）生效。
--
-- 如何查某个输入法的源 ID：先在菜单栏切到那个输入法，然后运行
--   defaults read com.apple.HIToolbox AppleSelectedInputSources
-- 其中的 "Input Mode"（或 Bundle ID）即源 ID；
-- 也可以运行 open "hammerspoon://doubaoime?cmd=check" 后查看调试日志。

return {
    ------------------------------------------------------------------
    -- 输入法（必改项：换成你自己的输入法）
    ------------------------------------------------------------------
    -- 语音用的输入法源 ID（默认：豆包输入法）
    -- targetSourceID = "com.bytedance.inputmethod.doubaoime.pinyin",

    -- 打字主力输入法源 ID（默认：微信输入法）
    -- homeSourceID = "com.tencent.inputmethod.wetype.pinyin",

    ------------------------------------------------------------------
    -- 回切节奏
    ------------------------------------------------------------------
    -- 录音结束后等多久回主力输入法（秒）
    -- 实际延迟 = clamp(backHomeDelayMin, backHomeDelayFactor × 录音秒数, backHomeDelayMax)
    -- 说得越久等得越久（给豆包「智能文字整理」润色留时间）。
    -- 想要"说完马上能打字"：把 factor 和 max 调小（如 0.1 / 2.0），
    -- 或直接在豆包设置里关闭「智能文字整理」。
    -- backHomeDelayMin = 1.2,
    -- backHomeDelayFactor = 0.3,
    -- backHomeDelayMax = 6.0,

    -- 麦克风占用轮询间隔（秒），越小检测越跟手
    -- pollInterval = 0.25,

    ------------------------------------------------------------------
    -- 界面与行为
    ------------------------------------------------------------------
    -- 菜单栏图标与快捷菜单
    -- menuBarEnabled = true,
    -- 启动时屏幕提示
    -- alertOnStart = true,
    -- 开机自启
    -- launchAtLogin = true,

    ------------------------------------------------------------------
    -- 路径（非苹果中文环境下豆包路径可能不同）
    ------------------------------------------------------------------
    -- debugLogPath = "/tmp/hs-doubao-debug.log",
    -- doubaoSettingsApp = "/Library/Input Methods/DoubaoIme.app/Contents/Applications/DoubaoImeSettings.app",
}
