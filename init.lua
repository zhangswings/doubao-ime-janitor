-- ============================================
-- 豆包语音「输入法管家」v4
-- 目标：语音用豆包（按住右 Command 说话，松手结束），打字永远用微信输入法
--
-- 关键事实（来自豆包输入法设置面板）：
--   · 豆包「长按模式」绑定右⌘：按住说话、松手结束并上屏
--   · 「免按模式」绑定右⌘：按一次开始说话，再按任意键结束
--   · 「全局唤起语音」已开启：跨输入法直接调起豆包语音
--   => 豆包自己就能处理右⌘语音，脚本不需要切输入法、也不需要模拟任何按键
--      （v1~v3 自己切 IME + 模拟 Option 反而与豆包原生手势打架）
--   => 唯一的坑：语音结束上屏时，豆包会把输入源劫持成自己，卡住不切回
--
-- 所以 v4 只做一件事：当好"输入法管家"——
--   1. 跟踪右 Command 按住状态：录音期间绝不切输入法
--   2. 语音结束（松手）且豆包完成上屏后，延迟 2 秒切回微信输入法
--   3. 任何时刻输入源"非预期地"变成豆包（FN/免按模式等），同样延迟切回
-- ============================================
local log = hs.logger.new("RightCmdIME", "debug")
local alert = hs.alert

-- 目标输入法：豆包（只用于语音，不该长期停留）
local TARGET_SOURCE_ID = "com.bytedance.inputmethod.doubaoime.pinyin"

-- 日常打字输入法：一切结束后回到这里
local HOME_SOURCE_ID = "com.tencent.inputmethod.wetype.pinyin"

-- 输入源变成豆包后，等多久切回微信输入法（秒）
-- 留 2 秒给"松手上屏 + 智能文字整理"，太短可能打断润色，太长打字会落在豆包上
local BACK_HOME_DELAY = 2.0

-- 松开右 Command 后，若一直没发生输入源变化，兜底切回的延迟（秒）
local AFTER_RELEASE_DELAY = 2.0

-- 物理按键 keycode
local KEYCODE_RIGHT_CMD = 54

-- 状态变量
local rightCmdIsDown = false
local backHomeTimer = nil

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

local function cancelBackHomeTimer()
    if backHomeTimer then
        backHomeTimer:stop()
        backHomeTimer = nil
    end
end

local function backHome(reason)
    if hs.keycodes.currentSourceID() == HOME_SOURCE_ID then
        return
    end
    local ok = hs.keycodes.currentSourceID(HOME_SOURCE_ID)
    trace(string.format("回到微信输入法(%s) => %s  原因: %s", HOME_SOURCE_ID, tostring(ok), reason or "-"))
    if ok == false then
        alert.show("切回微信输入法失败，请手动检查输入法设置", 3)
    end
end

local function scheduleBackHome(delay, reason)
    cancelBackHomeTimer()
    backHomeTimer = hs.timer.doAfter(delay, function()
        backHomeTimer = nil
        -- 录音期间（右 Command 仍按着）不打扰
        if hs.keycodes.currentSourceID() == TARGET_SOURCE_ID and not rightCmdIsDown then
            backHome(reason)
        end
    end)
end

-- 输入源监听：豆包成为当前输入法（语音劫持/外部触发），稍后送回微信输入法
local function onInputSourceChanged()
    if hs.keycodes.currentSourceID() == TARGET_SOURCE_ID then
        if not rightCmdIsDown then
            trace(string.format("输入源变为豆包，%.1f 秒后回微信输入法", BACK_HOME_DELAY))
            scheduleBackHome(BACK_HOME_DELAY, "劫持自动回切")
        else
            trace("输入源变为豆包（右 Command 录音中，暂不处理）")
        end
    else
        cancelBackHomeTimer()
    end
end

-- 只跟踪右 Command 的按住/松开，不再模拟任何按键、不再切输入法
local function handleRightCmdFlagsChanged(event)
    if event:getKeyCode() ~= KEYCODE_RIGHT_CMD then
        return false
    end

    if rightCmdIsDown then
        rightCmdIsDown = false
        trace("右 Command 松开（录音结束，豆包上屏中）")
        -- 兜底：若豆包上屏后没有触发输入源变化事件，也要回微信输入法
        scheduleBackHome(AFTER_RELEASE_DELAY, "松开后兜底回切")
    else
        rightCmdIsDown = true
        trace("右 Command 按下（豆包录音开始）")
        cancelBackHomeTimer()
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

hs.keycodes.inputSourceChanged(onInputSourceChanged)

-- 调试通道：open "hammerspoon://doubaoime?cmd=check|home|switch"
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
    elseif cmd == "home" or cmd == "restore" then
        backHome("URL 手动回切")
    elseif cmd == "switch" then
        local ok = hs.keycodes.currentSourceID(TARGET_SOURCE_ID)
        trace("手动切到豆包 => " .. tostring(ok))
    else
        trace("未知调试命令: " .. tostring(cmd))
    end
end)

-- 启动时如果卡在豆包，自动回微信输入法
if hs.keycodes.currentSourceID() == TARGET_SOURCE_ID then
    scheduleBackHome(1.0, "启动时清理")
end

-- 开机自启，后台常驻
hs.autoLaunch(true)

-- 加载 ipc，让 brew 链接的 hs 命令行可用
pcall(function() require("hs.ipc") end)

alert.show("RightCmdIME v4 输入法管家已启动", 2)
trace("========== 脚本已启动(v4 输入法管家)，辅助功能权限: " .. tostring(hs.accessibilityState()) .. " ==========")
