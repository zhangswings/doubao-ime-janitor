-- ====================================================================
-- doubao-ime-janitor · 豆包语音「输入法管家」
-- 语音识别用豆包输入法，打字永远回到你指定的主力输入法。
--
-- 工作方式：
--   豆包输入法自带「全局唤起语音」（右⌘长按 / FN / 免按均可触发），
--   语音输入全流程由豆包自己完成。本脚本不模拟任何按键、不切换输入法，
--   只负责三件事：
--     · 有麦克风在录音（任何 App）→ 绝不碰输入法
--     · 录音结束后输入源仍停留在豆包 → 延迟回切到主力输入法
--     · 非录音状态下豆包滞留（劫持残留等）→ 同样回切
--
-- 个性化：复制 janitor-config.example.lua 为 ~/.hammerspoon/janitor-config.lua
--   并按需修改（输入法源 ID、回切延迟、轮询间隔、界面开关等），
--   无需改动本文件。
--
-- v6 变更：菜单栏创建全防护（失败原因写日志，不再中断配置加载）；
--   个性化设置外置为 janitor-config.lua。
-- ====================================================================
local log = hs.logger.new("ImeJanitor", "info")
local alert = hs.alert

-- ============ 默认配置 ============
local config = {
    -- 语音用的输入法源 ID（豆包输入法）
    targetSourceID = "com.bytedance.inputmethod.doubaoime.pinyin",
    -- 打字主力输入法源 ID（录音结束后回到这里）
    homeSourceID = "com.tencent.inputmethod.wetype.pinyin",

    -- 录音结束后等多久回主力输入法（秒）
    -- 实际延迟 = clamp(backHomeDelayMin, backHomeDelayFactor × 录音秒数, backHomeDelayMax)
    -- factor 给长语音的「智能文字整理」润色留时间；太短会打断提交，导致预编辑文字悬空
    backHomeDelayMin = 1.2,
    backHomeDelayFactor = 0.3,
    backHomeDelayMax = 6.0,

    -- 麦克风占用轮询间隔（秒）：越小，录音结束检测越跟手
    pollInterval = 0.25,

    -- 调试日志路径
    debugLogPath = "/tmp/hs-doubao-debug.log",

    -- 豆包输入法设置应用路径（菜单栏快捷入口）
    doubaoSettingsApp = "/Library/Input Methods/DoubaoIme.app/Contents/Applications/DoubaoImeSettings.app",

    -- 界面与行为开关
    menuBarEnabled = true,   -- 菜单栏图标与快捷菜单
    alertOnStart = true,     -- 启动时屏幕提示
    launchAtLogin = true,    -- 开机自启
}

-- ============ 加载用户覆盖配置 ~/.hammerspoon/janitor-config.lua ============
local userConfigPath = hs.configdir .. "/janitor-config.lua"
local userConfigLoaded = false
local userConfigError = nil
local uf = io.open(userConfigPath, "r")
if uf then
    uf:close()
    local ok, overrides = pcall(dofile, userConfigPath)
    if ok and type(overrides) == "table" then
        for k, v in pairs(overrides) do
            config[k] = v
        end
        userConfigLoaded = true
    elseif not ok then
        userConfigError = tostring(overrides)
    end
end

-- ============ 调试日志：同时进 Hammerspoon 控制台和文件 ============
local function trace(msg)
    log.df("%s", msg)
    local f = io.open(config.debugLogPath, "a")
    if f then
        f:write(os.date("%Y-%m-%d %H:%M:%S") .. "  " .. msg .. "\n")
        f:close()
    end
end

if userConfigLoaded then
    trace("已加载用户配置: " .. userConfigPath)
elseif userConfigError then
    trace("用户配置加载失败（使用默认值）: " .. userConfigError)
end

-- ============ 状态变量 ============
local isRecording = false
local recordingStartedAt = nil
local backHomeTimer = nil

local function cancelBackHomeTimer()
    if backHomeTimer then
        backHomeTimer:stop()
        backHomeTimer = nil
    end
end

local function backHome(reason)
    if hs.keycodes.currentSourceID() == config.homeSourceID then
        return
    end
    local ok = hs.keycodes.currentSourceID(config.homeSourceID)
    trace(string.format("回到主力输入法(%s) => %s  原因: %s", config.homeSourceID, tostring(ok), reason or "-"))
    if ok == false then
        alert.show("切回主力输入法失败，请检查 janitor-config.lua 里的 homeSourceID 是否正确", 3)
    end
end

local function scheduleBackHome(delay, reason)
    if backHomeTimer then
        return
    end
    backHomeTimer = hs.timer.doAfter(delay, function()
        backHomeTimer = nil
        if not isRecording and hs.keycodes.currentSourceID() == config.targetSourceID then
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
            local delay = math.min(config.backHomeDelayMax, math.max(config.backHomeDelayMin, config.backHomeDelayFactor * duration))
            trace(string.format("录音结束（时长 %.1f 秒），%.1f 秒后回主力输入法", duration, delay))
            if hs.keycodes.currentSourceID() == config.targetSourceID then
                scheduleBackHome(delay, "录音结束回切")
            end
        end
    end

    -- 兜底：非录音状态下豆包滞留（漏掉的事件/残留状态），安排回切
    if not isRecording and not backHomeTimer
        and hs.keycodes.currentSourceID() == config.targetSourceID then
        scheduleBackHome(config.backHomeDelayMin, "豆包滞留回切")
    end
end

-- 输入源变化：仅记录日志（回切逻辑由轮询统一驱动，避免漏事件）
hs.keycodes.inputSourceChanged(function()
    trace("输入源变化 -> " .. tostring(hs.keycodes.currentSourceID()))
end)

-- 主循环轮询
pollTick()
_G.imeJanitorTimer = hs.timer.doEvery(config.pollInterval, pollTick)

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
        local ok = hs.keycodes.currentSourceID(config.targetSourceID)
        trace("手动切到豆包 => " .. tostring(ok))
    else
        trace("未知调试命令: " .. tostring(cmd))
    end
end)

-- ============ 菜单栏图标与快捷菜单（每一步都有防护，失败不中断配置） ============
local function setupMenuBar()
    if not config.menuBarEnabled then
        return
    end

    local okBar, bar = pcall(hs.menubar.new)
    if not okBar or not bar then
        trace("菜单栏创建失败: " .. tostring(bar))
        return
    end

    local iconSet = false
    local okImg, icon = pcall(function() return hs.image.imageFromName("mic.fill") end)
    if okImg and icon ~= nil then
        local okSet, setErr = pcall(function() iconSet = bar:setIcon(icon, true) end)
        if not okSet then
            trace("菜单栏 setIcon 失败: " .. tostring(setErr))
        end
    elseif not okImg then
        trace("读取 SF Symbol 图标失败: " .. tostring(icon))
    end

    if not iconSet then
        local okTitle, titleErr = pcall(function() bar:setTitle("🎙") end)
        if not okTitle then
            trace("菜单栏 setTitle 失败: " .. tostring(titleErr))
        end
    end

    local okMenu, menuErr = pcall(function()
        bar:setMenu(function()
            return {
                { title = "强制回主力输入法", fn = function() backHome("菜单手动回切") end },
                { title = "打开豆包输入法设置", fn = function()
                    hs.execute('open "' .. config.doubaoSettingsApp .. '"')
                end },
                { title = "-" },
                { title = "重载脚本", fn = function() hs.reload() end },
            }
        end)
    end)
    if not okMenu then
        trace("菜单栏 setMenu 失败: " .. tostring(menuErr))
    end

    trace("菜单栏已创建：" .. (iconSet and "SF Symbol(mic.fill)" or "emoji 兜底"))
end
setupMenuBar()

-- 启动时如果卡在豆包，自动回主力输入法
if hs.keycodes.currentSourceID() == config.targetSourceID then
    scheduleBackHome(1.0, "启动时清理")
end

if config.launchAtLogin then
    hs.autoLaunch(true)
end

-- 加载 ipc，让 brew 链接的 hs 命令行可用
pcall(function() require("hs.ipc") end)

if config.alertOnStart then
    alert.show("输入法管家已启动（豆包语音 · 说完自动回切）", 2)
end

trace("========== 脚本已启动(v6) 辅助功能: " .. tostring(hs.accessibilityState())
    .. " 用户配置: " .. (userConfigLoaded and "已加载" or (userConfigError and "加载失败" or "默认值"))
    .. " ==========")
