-- ============================================
-- Right Command -> 切到豆包输入法 -> 双击左 Option 唤起语音 -> 结束后回到微信输入法
-- 基于 https://github.com/Paxxs/Doubao-ime-hammerspoon 适配本机：
--   日常打字 = 微信输入法(HOME)，豆包输入法只用于语音(TARGET)
--   v2 修复：实测发现语音结束时豆包会把输入源"劫持"回自己，
--   原版"恢复上一次输入法"的记录会被污染（记成豆包），导致永远卡在豆包。
--   改为：
--     1. 语音会话结束后强制回 HOME（微信输入法）
--     2. 监听输入源变化，凡是"非脚本主动"切到豆包（语音结束劫持 / FN 触发），
--        延迟 1 秒自动回 HOME
--     3. 松开右 Command 3 秒后仍在豆包则兜底回 HOME
-- ============================================
local log = hs.logger.new("RightCmdIME", "debug")
local alert = hs.alert

-- 目标输入法：豆包（语音用）
local TARGET_SOURCE_ID = "com.bytedance.inputmethod.doubaoime.pinyin"

-- 日常打字输入法：语音结束后回到这里
local HOME_SOURCE_ID = "com.tencent.inputmethod.wetype.pinyin"

-- 右侧 Command 按下后，多久再执行双击左 Option（秒）
local OPTION_PRESS_DELAY = 0.30

-- 两次 Option 点击之间的间隔（秒）
local OPTION_DOUBLE_TAP_INTERVAL = 0.18

-- 松开右 Command 后的兜底恢复延迟（秒）：仍在豆包就强制回 HOME
local RESTORE_IME_DELAY = 3.0

-- 被劫持到豆包后，等多久自动回 HOME（秒）
local BACK_HOME_DELAY = 1.0

-- 自己主动切到豆包后的保护期（秒），期内不算被劫持
local HIJACK_GRACE = 1.5

-- 物理按键 keycode
local KEYCODE_RIGHT_CMD = 54

-- 状态变量
local rightCmdIsDown = false
local optionPressTimer = nil
local restoreImeTimer = nil
local backHomeTimer = nil
local lastSelfSwitchAt = 0

-- 调试日志：同时进 Hammerspoon 控制台和文件
local DEBUG_LOG = "/tmp/hs-doubao-debug.log"
local function trace(msg)
    log.df("%s", msg)
    local f = io.open(DEBUG_LOG, "a")
    if f then
        f:write(os.date("%Y-%m-%d %H:%M:%S") .. "  " .. msg .. "\n")
        f:close()
    end
end

local function cancelOptionTimer()
    if optionPressTimer then
        optionPressTimer:stop()
        optionPressTimer = nil
    end
end

local function cancelRestoreImeTimer()
    if restoreImeTimer then
        restoreImeTimer:stop()
        restoreImeTimer = nil
    end
end

local function cancelBackHomeTimer()
    if backHomeTimer then
        backHomeTimer:stop()
        backHomeTimer = nil
    end
end

local function backHome(reason)
    if hs.keycodes.currentSourceID() == HOME_SOURCE_ID then
        trace("已在微信输入法，无需回家")
        return
    end
    local ok = hs.keycodes.currentSourceID(HOME_SOURCE_ID)
    trace(string.format("回到微信输入法(%s) => %s  原因: %s", HOME_SOURCE_ID, tostring(ok), reason or "-"))
end

local function scheduleBackHome(reason)
    cancelBackHomeTimer()
    backHomeTimer = hs.timer.doAfter(BACK_HOME_DELAY, function()
        backHomeTimer = nil
        if hs.keycodes.currentSourceID() == TARGET_SOURCE_ID and not rightCmdIsDown then
            backHome(reason)
        end
    end)
end

-- 输入源变化监听：豆包在"非脚本主动"的情况下成为当前输入法，
-- 说明是语音结束劫持或 FN 等外部触发，稍后自动回微信输入法
local function onInputSourceChanged()
    local id = hs.keycodes.currentSourceID()
    if id == TARGET_SOURCE_ID then
        local since = hs.timer.secondsSinceEpoch() - lastSelfSwitchAt
        if not rightCmdIsDown and since > HIJACK_GRACE then
            trace(string.format("输入源被切到豆包(非脚本主动, 距上次主动切换 %.1fs)，%.1f 秒后自动回微信输入法", since, BACK_HOME_DELAY))
            scheduleBackHome("劫持自动回切")
        end
    else
        cancelBackHomeTimer()
    end
end

local function tapLeftOptionOnce()
    hs.eventtap.event.newKeyEvent(hs.keycodes.map.alt, true):post()
    hs.eventtap.event.newKeyEvent(hs.keycodes.map.alt, false):post()
end

local function doubleTapLeftOption()
    trace("开始模拟双击左 Option")
    tapLeftOptionOnce()

    hs.timer.doAfter(OPTION_DOUBLE_TAP_INTERVAL, function()
        tapLeftOptionOnce()
        trace("已完成双击左 Option")
    end)
end

local function switchToDoubao()
    -- 无论是否已是豆包都刷新保护期、取消回切，保护进行中的语音会话
    lastSelfSwitchAt = hs.timer.secondsSinceEpoch()
    cancelBackHomeTimer()

    if hs.keycodes.currentSourceID() == TARGET_SOURCE_ID then
        trace("当前已经是豆包输入法，无需切换")
        return
    end

    local ok = hs.keycodes.currentSourceID(TARGET_SOURCE_ID)
    trace(string.format("切换到豆包输入法(%s) => %s", TARGET_SOURCE_ID, tostring(ok)))

    if ok == false then
        alert.show("切换豆包输入法失败：请到 系统设置 → 键盘 → 输入法，添加并启用「豆包输入法」", 4)
    end
end

local function scheduleFallbackRestore()
    cancelRestoreImeTimer()

    restoreImeTimer = hs.timer.doAfter(RESTORE_IME_DELAY, function()
        restoreImeTimer = nil
        if hs.keycodes.currentSourceID() == TARGET_SOURCE_ID and not rightCmdIsDown then
            trace(string.format("松开 %.1f 秒后仍在豆包，兜底回微信输入法", RESTORE_IME_DELAY))
            backHome("松开后兜底恢复")
        end
    end)
end

local function onRightCmdDown()
    if rightCmdIsDown then
        return
    end

    rightCmdIsDown = true
    trace("右 Command 按下")

    -- 新一轮开始时，取消上一轮尚未执行的兜底恢复
    cancelRestoreImeTimer()

    switchToDoubao()

    cancelOptionTimer()
    optionPressTimer = hs.timer.doAfter(OPTION_PRESS_DELAY, function()
        optionPressTimer = nil

        if rightCmdIsDown then
            trace("按住超过 0.30 秒，提前双击左 Option")
            doubleTapLeftOption()
        end
    end)
end

local function onRightCmdUp()
    if not rightCmdIsDown then
        return
    end

    rightCmdIsDown = false
    trace("右 Command 松开")

    cancelOptionTimer()
    doubleTapLeftOption()

    -- 兜底：若语音没触发或劫持没发生，也要回到微信输入法
    scheduleFallbackRestore()
end

-- 只处理右 Command 的 flagsChanged，根据内部状态翻转判断按下/松开，
-- 不依赖 flags.cmd（避免偶发监听失效）
local function handleRightCmdFlagsChanged(event)
    local keycode = event:getKeyCode()
    if keycode ~= KEYCODE_RIGHT_CMD then
        return false
    end

    if rightCmdIsDown then
        onRightCmdUp()
    else
        onRightCmdDown()
    end

    return false
end

-- 回调异常不让 watcher「死掉」
local function safeEventHandler(event)
    local ok, result = xpcall(function()
        return handleRightCmdFlagsChanged(event)
    end, debug.traceback)

    if not ok then
        log.ef("eventtap 回调报错:\n%s", tostring(result))
        return false
    end

    return result
end

-- 全局持有，避免被 GC
_G.rightCmdWatcher = hs.eventtap.new({hs.eventtap.event.types.flagsChanged}, safeEventHandler)
_G.rightCmdWatcher:start()

-- 输入源变化监听
hs.keycodes.inputSourceChanged(onInputSourceChanged)

-- 调试通道：
--   open "hammerspoon://doubaoime?cmd=check|switch|home"
--   check=查看当前输入源  switch=切到豆包  home=强制回微信输入法
hs.urlevent.bind("doubaoime", function(_, paramsOrQuery)
    local cmd = nil
    if type(paramsOrQuery) == "table" then
        cmd = paramsOrQuery["cmd"]
    elseif type(paramsOrQuery) == "string" then
        cmd = paramsOrQuery:match("cmd=([%w_]+)")
    end

    trace("URL 调试命令: " .. tostring(cmd))

    if cmd == "check" then
        trace("currentSourceID = " .. tostring(hs.keycodes.currentSourceID()))
        trace("currentMethod    = " .. tostring(hs.keycodes.currentMethod()))
        trace("currentLayout    = " .. tostring(hs.keycodes.currentLayout()))
    elseif cmd == "switch" then
        switchToDoubao()
    elseif cmd == "home" or cmd == "restore" then
        backHome("URL 手动回切")
    else
        trace("未知调试命令: " .. tostring(cmd))
    end
end)

-- 启动时如果卡在豆包（比如上次语音劫持后重启），自动回微信输入法
if hs.keycodes.currentSourceID() == TARGET_SOURCE_ID then
    scheduleBackHome("启动时清理")
end

-- 开机自启，后台常驻
hs.autoLaunch(true)

-- 加载 ipc，让 brew 链接的 hs 命令行可用
pcall(function() require("hs.ipc") end)

alert.show("RightCmdIME v2 脚本已启动", 2)
trace("========== 脚本已启动(v2)，辅助功能权限: " .. tostring(hs.accessibilityState()) .. " ==========")
