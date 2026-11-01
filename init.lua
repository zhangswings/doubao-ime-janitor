-- ============================================
-- 豆包语音「输入法管家」v5
-- 目标：语音用豆包（右⌘长按 / FN / 免按均可），打字永远用微信输入法
--
-- v5 关键改动：录音检测从「右 Command 事件」改为「麦克风占用」
--   实测发现：豆包全局唤起语音时，右 Command 的按键事件脚本收不到
--   （被豆包自身监听拦截），或用户用 FN 触发——导致"录音中不切换"保护
--   失效，录音 2 秒后被微信输入法抢占。
--   改为轮询麦克风占用状态：有任何麦克风在录音就绝不切输入法；
--   录音结束后延迟切换（给上屏 + 智能文字整理留时间）。
--   对所有触发方式（右⌘长按 / FN / 免按模式）天然有效。
--
-- v5.2：回切延迟按录音时长自适应——
--   长语音的「智能文字整理」润色要数秒，固定短延迟会打断提交，
--   导致预编辑文字（下划线）悬空不消失。延迟 = clamp(1.2, 0.3×录音秒数, 6)。
-- ============================================
local log = hs.logger.new("RightCmdIME", "debug")
local alert = hs.alert

-- 目标输入法：豆包（只用于语音，不该长期停留）
local TARGET_SOURCE_ID = "com.bytedance.inputmethod.doubaoime.pinyin"

-- 日常打字输入法：一切结束后回到这里
local HOME_SOURCE_ID = "com.tencent.inputmethod.wetype.pinyin"

-- 录音结束后等多久回微信输入法（秒）
-- 短语音基准 1.2s；长语音按 0.3 × 录音秒数给"智能文字整理"留缓冲，封顶 6s
local BACK_HOME_DELAY_MIN = 1.2
local BACK_HOME_DELAY_FACTOR = 0.3
local BACK_HOME_DELAY_MAX = 6.0

-- 轮询间隔（秒）：越小，录音结束检测越跟手
local POLL_INTERVAL = 0.25

-- 状态变量
local isRecording = false
local recordingStartedAt = nil
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
        alert.show("切回微信输入法失败，请检查系统输入法设置", 3)
    end
end

local function scheduleBackHome(delay, reason)
    if backHomeTimer then
        return
    end
    backHomeTimer = hs.timer.doAfter(delay, function()
        backHomeTimer = nil
        if not isRecording and hs.keycodes.currentSourceID() == TARGET_SOURCE_ID then
            backHome(reason)
        end
    end)
end

-- 是否有任意输入设备（麦克风）正在被占用
local function anyMicInUse()
    local devices = hs.audiodevice.allInputDevices()
    for _, dev in ipairs(devices) do
        if dev:inUse() then
            return true
        end
    end
    return false
end

local function pollTick()
    local recording = anyMicInUse()

    if recording ~= isRecording then
        isRecording = recording
        if recording then
            recordingStartedAt = hs.timer.secondsSinceEpoch()
            trace("录音开始（麦克风占用）——豆包会话保护中")
            cancelBackHomeTimer()
        else
            local duration = recordingStartedAt and (hs.timer.secondsSinceEpoch() - recordingStartedAt) or 0
            local delay = math.min(BACK_HOME_DELAY_MAX, math.max(BACK_HOME_DELAY_MIN, BACK_HOME_DELAY_FACTOR * duration))
            trace(string.format("录音结束（时长 %.1f 秒），%.1f 秒后回微信输入法", duration, delay))
            if hs.keycodes.currentSourceID() == TARGET_SOURCE_ID then
                scheduleBackHome(delay, "录音结束回切")
            end
        end
    end

    -- 兜底：非录音状态下豆包滞留（漏掉的事件/残留状态），安排回切
    if not isRecording and not backHomeTimer
        and hs.keycodes.currentSourceID() == TARGET_SOURCE_ID then
        scheduleBackHome(BACK_HOME_DELAY_MIN, "豆包滞留回切")
    end
end

-- 输入源变化：仅记录日志（回切逻辑由轮询统一驱动，避免漏事件）
hs.keycodes.inputSourceChanged(function()
    trace("输入源变化 -> " .. tostring(hs.keycodes.currentSourceID()))
end)

-- 主循环轮询
pollTick()
_G.imeJanitorTimer = hs.timer.doEvery(POLL_INTERVAL, pollTick)

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
        trace("recording        = " .. tostring(isRecording))
    elseif cmd == "home" or cmd == "restore" then
        backHome("URL 手动回切")
    elseif cmd == "switch" then
        local ok = hs.keycodes.currentSourceID(TARGET_SOURCE_ID)
        trace("手动切到豆包 => " .. tostring(ok))
    else
        trace("未知调试命令: " .. tostring(cmd))
    end
end)

-- 开机自启，后台常驻
hs.autoLaunch(true)

-- 加载 ipc，让 brew 链接的 hs 命令行可用
pcall(function() require("hs.ipc") end)

alert.show("RightCmdIME v5 输入法管家已启动", 2)
trace("========== 脚本已启动(v5 麦克风检测)，辅助功能权限: " .. tostring(hs.accessibilityState()) .. " ==========")
