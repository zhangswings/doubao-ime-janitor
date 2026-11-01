-- ============================================
-- Right Command -> 切到豆包输入法 -> 按住左 Option 说话 -> 松开上屏 -> 回到微信输入法
-- 基于 https://github.com/Paxxs/Doubao-ime-hammerspoon 适配本机
--   日常打字 = 微信输入法(HOME)，豆包输入法只用于语音(TARGET)
--
-- v3：语音手势从"双击 Option"改为"按住 Option"（push-to-talk）
--   原因：双击模式下豆包把语音文字放在预编辑态(带下划线)，脚本切走输入法时
--   未确认文字会被系统丢弃导致丢字；而"按住说话、松开上屏"是豆包原生交互，
--   松开瞬间文字即提交，之后切回微信输入法就安全了。
--
--   右 Command 按下 = 切豆包 + 按下左 Option（开始录音）
--   右 Command 松开 = 松开左 Option（豆包上屏）→ 1.5 秒后回微信输入法
-- ============================================
local log = hs.logger.new("RightCmdIME", "debug")
local alert = hs.alert

-- 语音手势："hold"=按住说话(push-to-talk，推荐) / "doubletap"=双击触发
local VOICE_GESTURE = "hold"

-- 目标输入法：豆包（语音用）
local TARGET_SOURCE_ID = "com.bytedance.inputmethod.doubaoime.pinyin"

-- 日常打字输入法：语音结束后回到这里
local HOME_SOURCE_ID = "com.tencent.inputmethod.wetype.pinyin"

-- 右 Command 按下后，等多久再按下左 Option（秒）：给输入法切换留时间
local OPTION_PRESS_DELAY = 0.30

-- 松开右 Command 后，延迟多久回微信输入法（秒）：给豆包上屏留时间
local RESTORE_IME_DELAY = 1.5

-- 被切到豆包（非脚本主动）后，等多久自动回微信输入法（秒）
local BACK_HOME_DELAY = 1.0

-- 自己主动切到豆包后的保护期（秒），期内不算"被劫持"
local HIJACK_GRACE = 1.5

-- 物理按键 keycode
local KEYCODE_RIGHT_CMD = 54

-- 状态变量
local rightCmdIsDown = false
local optionIsDown = false
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
-- 说明是外部触发（FN 语音等），稍后自动回微信输入法
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

-- 兜底：语音流程没走完或劫持没发生，也要回到微信输入法
local function scheduleFallbackRestore(delay, reason)
    cancelRestoreImeTimer()
    restoreImeTimer = hs.timer.doAfter(delay, function()
        restoreImeTimer = nil
        if hs.keycodes.currentSourceID() == TARGET_SOURCE_ID and not rightCmdIsDown then
            trace(string.format("%.1f 秒后仍在豆包，兜底回微信输入法", delay))
            backHome(reason)
        end
    end)
end

local function postOption(down)
    hs.eventtap.event.newKeyEvent(hs.keycodes.map.alt, down):post()
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

    if VOICE_GESTURE == "hold" then
        cancelOptionTimer()
        optionPressTimer = hs.timer.doAfter(OPTION_PRESS_DELAY, function()
            optionPressTimer = nil
            if rightCmdIsDown and not optionIsDown then
                optionIsDown = true
                trace("模拟按住左 Option（开始语音）")
                postOption(true)
            end
        end)
    end
end

local function onRightCmdUp()
    if not rightCmdIsDown then
        return
    end

    rightCmdIsDown = false
    trace("右 Command 松开")

    if VOICE_GESTURE == "hold" then
        cancelOptionTimer()
        if optionIsDown then
            optionIsDown = false
            trace("模拟松开左 Option（豆包上屏）")
            postOption(false)
            -- 松开即上屏，给 1.5 秒提交时间后回微信输入法
            scheduleFallbackRestore(RESTORE_IME_DELAY, "语音结束自动回切")
        else
            -- 轻点（不足 0.30 秒），没有进入语音，直接安排回微信输入法
            trace("轻点右 Command（未进入语音），安排回微信输入法")
            scheduleFallbackRestore(0.5, "轻点后回切")
        end
    else
        -- doubletap 模式：保持原插件行为（松开时模拟双击）
        trace("模拟双击左 Option")
        postOption(true)
        postOption(false)
        hs.timer.doAfter(0.18, function()
            postOption(true)
            postOption(false)
        end)
        scheduleFallbackRestore(3.0, "双击模式兜底回切")
    end
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

-- 调试通道：open "hammerspoon://doubaoime?cmd=check|switch|home"
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

-- 防御：万一脚本重载时 Option 还处于"按住"状态，先补一个松开，避免系统修饰键卡死
postOption(false)

-- 启动时如果卡在豆包（比如上次语音后重启），自动回微信输入法
if hs.keycodes.currentSourceID() == TARGET_SOURCE_ID then
    scheduleBackHome("启动时清理")
end

-- 开机自启，后台常驻
hs.autoLaunch(true)

-- 加载 ipc，让 brew 链接的 hs 命令行可用
pcall(function() require("hs.ipc") end)

alert.show("RightCmdIME v3 脚本已启动（按住说话模式）", 2)
trace("========== 脚本已启动(v3, 手势=" .. VOICE_GESTURE .. ")，辅助功能权限: " .. tostring(hs.accessibilityState()) .. " ==========")
