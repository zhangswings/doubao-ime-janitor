-- ============================================
-- Right Command -> 切到豆包输入法 -> 双击左 Option 唤起语音 -> 2 秒后切回原输入法
-- 基于 https://github.com/Paxxs/Doubao-ime-hammerspoon 适配本机：
--   日常打字 = 微信输入法，豆包输入法只用于语音识别
--   1. 输入法按「源 ID」切换（豆包 ID 取自本机实测），比原脚本按中文名切换更稳
--   2. 新增调试通道：hs 命令行 / open "hammerspoon://doubaoime?cmd=check|switch|restore"
--   3. 流程日志同步写入 /tmp/hs-doubao-debug.log，便于外部观察
-- ============================================
local log = hs.logger.new("RightCmdIME", "debug")
local alert = hs.alert

-- 目标输入法：豆包（语音用）
local TARGET_SOURCE_ID = "com.bytedance.inputmethod.doubaoime.pinyin"

-- 右侧 Command 按下后，多久再执行双击左 Option（秒）
local OPTION_PRESS_DELAY = 0.30

-- 两次 Option 点击之间的间隔（秒）
local OPTION_DOUBLE_TAP_INTERVAL = 0.18

-- 松开右 Command 后，延迟多久恢复原输入法（秒）
local RESTORE_IME_DELAY = 2.0

-- 物理按键 keycode
local KEYCODE_RIGHT_CMD = 54

-- 状态变量
local previousInputSource = nil
local rightCmdIsDown = false
local optionPressTimer = nil
local restoreImeTimer = nil

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

local function nowSource()
    local sourceID = hs.keycodes.currentSourceID()
    if sourceID ~= nil and sourceID ~= "" then
        return { kind = "sourceID", value = sourceID }
    end

    local layout = hs.keycodes.currentLayout()
    if layout ~= nil then
        return { kind = "layout", value = layout }
    end

    return nil
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

local function switchToTargetIME()
    local current = nowSource()
    previousInputSource = current

    if current == nil then
        trace("无法识别当前输入来源，跳过记录")
    end

    if current ~= nil and current.value == TARGET_SOURCE_ID then
        trace("当前已经是豆包输入法，无需切换")
        return
    end

    local ok = hs.keycodes.currentSourceID(TARGET_SOURCE_ID)
    trace(string.format("切换到豆包输入法(%s) => %s", TARGET_SOURCE_ID, tostring(ok)))

    if ok == false then
        alert.show("切换豆包输入法失败：请到 系统设置 → 键盘 → 输入法，添加并启用「豆包输入法」", 4)
    end
end

local function restorePreviousIME()
    if not previousInputSource then
        trace("没有记录到之前的输入来源，跳过恢复")
        return
    end

    local old = previousInputSource
    local ok = false

    if old.kind == "sourceID" then
        ok = hs.keycodes.currentSourceID(old.value)
        trace(string.format("恢复之前输入法(%s) => %s", tostring(old.value), tostring(ok)))
    elseif old.kind == "layout" then
        ok = hs.keycodes.setLayout(old.value)
        trace(string.format("恢复之前键盘布局(%s) => %s", tostring(old.value), tostring(ok)))
    else
        trace("未知的输入来源类型，无法恢复: " .. hs.inspect(old))
    end

    previousInputSource = nil
end

local function scheduleRestorePreviousIME()
    cancelRestoreImeTimer()

    restoreImeTimer = hs.timer.doAfter(RESTORE_IME_DELAY, function()
        restoreImeTimer = nil
        trace(string.format("延迟 %.2f 秒到，开始恢复之前输入法", RESTORE_IME_DELAY))
        restorePreviousIME()
    end)
end

local function onRightCmdDown()
    if rightCmdIsDown then
        return
    end

    rightCmdIsDown = true
    trace("右 Command 按下")

    -- 新一轮开始时，取消上一次尚未执行的恢复动作
    cancelRestoreImeTimer()

    switchToTargetIME()

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

    -- 延迟恢复原输入法
    scheduleRestorePreviousIME()
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

-- 调试通道：
--   终端: hs -c 'hs.keycodes.currentSourceID()'
--   或:  open "hammerspoon://doubaoime?cmd=check"  （check / switch / restore）
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
        switchToTargetIME()
    elseif cmd == "restore" then
        restorePreviousIME()
    else
        trace("未知调试命令: " .. tostring(cmd))
    end
end)

-- 开机自启，后台常驻
hs.autoLaunch(true)

-- 加载 ipc，让 brew 链接的 hs 命令行可用
pcall(function() require("hs.ipc") end)

alert.show("RightCmdIME 脚本已启动", 2)
trace("========== 脚本已启动，辅助功能权限: " .. tostring(hs.accessibilityState()) .. " ==========")
