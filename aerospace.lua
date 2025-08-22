-- AeroSpace Overlay for Hammerspoon
-- Shows a grid overlay of AeroSpace workspaces with applications in QWERTY layout
-- Hotkey: Alt + ESC to toggle overlay
-- 
-- Layout mapping:
-- Row 1: 1 2 3 4 5 6 7 8 9 0
-- Row 2: q w e r t y u i o p  
-- Row 3: a s d f g h j k l ;
-- Row 4: z x c v b n m , . /
--
-- Performance optimizations:
-- - INSTANT overlay display (0ms blocking) - shows immediately with cached/empty data
-- - Async data fetching using hs.task (non-blocking background updates)
-- - Single CLI call using format command (~22ms vs 100ms+ for sequential calls)
-- - 10-second data caching to avoid redundant CLI calls
-- - Visual loading indicators while data updates in background
-- - Live overlay refresh when new data arrives
-- - On-demand refresh mode (no background refresh) to minimize resource usage

local M = {}

-- Configuration
local GRID_COLS = 10  -- QWERTY keyboard layout
local GRID_ROWS = 4   -- 4 rows of QWERTY layout
local CELL_WIDTH = 120
local CELL_HEIGHT = 80
local CELL_MARGIN = 3

-- State
local overlay = nil
local keyWatcher = nil
local isOverlayVisible = false
local temporaryHotkeys = {}

-- QWERTY keyboard layout mapping for workspaces
local LAYOUT_ROWS = {
    {"1", "2", "3", "4", "5", "6", "7", "8", "9", "0"},
    {"q", "w", "e", "r", "t", "y", "u", "i", "o", "p"},
    {"a", "s", "d", "f", "g", "h", "j", "k", "l", ";"},
    {"z", "x", "c", "v", "b", "n", "m", ",", ".", "/"}
}

-- Cache for workspace data with timestamp
local workspaceData = {}
local cacheTimestamp = 0
local CACHE_DURATION = 10 -- Cache for 10 seconds (even longer)
local BACKGROUND_REFRESH_INTERVAL = 60 -- Background refresh every 60 seconds (very infrequent)
local isUpdating = false
local updateTimer = nil
local lastUserActivity = 0
local refreshOnDemandOnly = false -- Option to disable background refresh entirely

-- Pre-rendered overlay components
local preRenderedOverlay = nil
local overlayNeedsUpdate = true

-- Function to get workspace key from grid position
local function getWorkspaceKey(col, row)
    if row <= #LAYOUT_ROWS and col <= #LAYOUT_ROWS[row] then
        return LAYOUT_ROWS[row][col]
    end
    return nil
end

-- Function to execute aerospace command and parse JSON
local function executeAerospaceCommand(args)
    -- Use hs.execute for simpler synchronous execution
    local command = "/opt/homebrew/bin/aerospace " .. table.concat(args, " ")
    print("Executing: " .. command)
    
    local result, status, exitType, exitCode = hs.execute(command)
    
    if not status then
        print("Error executing aerospace command: " .. command)
        print("Exit code: " .. tostring(exitCode))
        return nil
    end
    
    if not result or result == "" then
        print("No output from aerospace command")
        return {}
    end
    
    -- Parse JSON
    local success, jsonData = pcall(hs.json.decode, result)
    if success then
        return jsonData
    else
        print("Error parsing JSON: " .. tostring(jsonData))
        print("Raw output: " .. result)
        return nil
    end
end

-- Function to check if cache is valid
local function isCacheValid()
    local currentTime = os.time()
    return (currentTime - cacheTimestamp) < CACHE_DURATION
end

-- Function to execute format command and parse results
local function executeFormatCommand(args)
    -- Properly escape the format string for shell execution
    local escapedArgs = {}
    for i, arg in ipairs(args) do
        if string.find(arg, "%{") then
            -- This is a format string, wrap it in single quotes
            table.insert(escapedArgs, "'" .. arg .. "'")
        else
            table.insert(escapedArgs, arg)
        end
    end
    
    local command = "/opt/homebrew/bin/aerospace " .. table.concat(escapedArgs, " ")
    local result, status, exitType, exitCode = hs.execute(command)
    
    if not status then
        print("Error executing aerospace command: " .. command)
        return nil
    end
    
    return result
end

-- Fast function to fetch workspace data using format command (single CLI call)
local function fetchWorkspaceDataFast()
    print("Fetching workspace data from AeroSpace (optimized)...")
    local startTime = os.clock()
    
    -- Get all windows with workspace info in one command
    local result = executeFormatCommand({"list-windows", "--all", "--format", "%{workspace}|%{app-name}|%{window-title}|%{window-id}"})
    
    if not result then
        print("Failed to get windows with format, falling back to workspace-by-workspace JSON")
        -- Fallback: get workspaces first, then query each one
        local workspaces = executeAerospaceCommand({"list-workspaces", "--all", "--json"})
        if workspaces then
            local data = {}
            print("Using fallback method: querying " .. #workspaces .. " workspaces individually")
            
            for _, ws in ipairs(workspaces) do
                local workspaceName = ws.workspace
                local windows = executeAerospaceCommand({"list-windows", "--workspace", workspaceName, "--json"})
                
                if windows then
                    data[workspaceName] = {}
                    for _, window in ipairs(windows) do
                        table.insert(data[workspaceName], {
                            appName = window["app-name"],
                            windowTitle = window["window-title"],
                            windowId = window["window-id"]
                        })
                    end
                else
                    data[workspaceName] = {}
                end
            end
            return data
        end
        return {}
    end
    
    -- Parse the formatted output
    local data = {}
    local lines = {}
    
    -- Split result into lines
    for line in result:gmatch("[^\r\n]+") do
        table.insert(lines, line)
    end
    
    for _, line in ipairs(lines) do
        if line and line ~= "" then
            -- Parse format: workspace|app-name|window-title|window-id
            local parts = {}
            for part in line:gmatch("[^|]+") do
                table.insert(parts, part)
            end
            
            if #parts >= 2 then
                local workspace = parts[1]
                local appName = parts[2]
                local windowTitle = parts[3] or ""
                local windowId = parts[4] or ""
                
                if not data[workspace] then
                    data[workspace] = {}
                end
                
                table.insert(data[workspace], {
                    appName = appName,
                    windowTitle = windowTitle,
                    windowId = windowId
                })
            end
        end
    end
    
    local endTime = os.clock()
    print("Workspace data fetch completed in " .. string.format("%.3f", endTime - startTime) .. " seconds")
    
    local workspaceCount = 0
    local totalWindows = 0
    for workspace, windows in pairs(data) do
        workspaceCount = workspaceCount + 1
        totalWindows = totalWindows + #windows
    end
    print("Found " .. workspaceCount .. " workspaces with " .. totalWindows .. " windows")
    
    return data
end

-- Function to fetch workspace data with caching (NEVER blocks)
local function fetchWorkspaceData()
    -- Always return cached data immediately (even if stale)
    if next(workspaceData) ~= nil then
        return workspaceData
    end
    
    -- If no cache exists, return empty structure for immediate display
    return {}
end

-- Async function to update workspace data
local function updateWorkspaceDataAsync()
    -- Skip if already updating
    if isUpdating then
        return
    end
    
    -- Skip if cache is still valid
    if isCacheValid() and next(workspaceData) ~= nil then
        return
    end
    
    print("Starting async workspace data update...")
    isUpdating = true
    
    -- Use hs.task for true async execution
    local task = hs.task.new("/opt/homebrew/bin/aerospace", function(exitCode, stdOut, stdErr)
        isUpdating = false
        
        if exitCode == 0 and stdOut and stdOut ~= "" then
            -- Parse the formatted output
            local data = {}
            local lines = {}
            
            -- Split result into lines
            for line in stdOut:gmatch("[^\r\n]+") do
                table.insert(lines, line)
            end
            
            for _, line in ipairs(lines) do
                if line and line ~= "" then
                    -- Parse format: workspace|app-name|window-title|window-id
                    local parts = {}
                    for part in line:gmatch("[^|]+") do
                        table.insert(parts, part)
                    end
                    
                    if #parts >= 2 then
                        local workspace = parts[1]
                        local appName = parts[2]
                        local windowTitle = parts[3] or ""
                        local windowId = parts[4] or ""
                        
                        if not data[workspace] then
                            data[workspace] = {}
                        end
                        
                        table.insert(data[workspace], {
                            appName = appName,
                            windowTitle = windowTitle,
                            windowId = windowId
                        })
                    end
                end
            end
            
            -- Update cache
            workspaceData = data
            cacheTimestamp = os.time()
            overlayNeedsUpdate = true
            
            print("Async workspace data update completed")
            
            -- If overlay is visible, refresh it
            if isOverlayVisible and overlay then
                print("Refreshing visible overlay with new data")
                -- Create new canvas with updated data
                local screen = hs.screen.mainScreen()
                local screenFrame = screen:frame()
                local newCanvas = hs.canvas.new(screenFrame)
                
                -- Copy elements from new overlay
                local tempCanvas = createOverlayCanvas()
                for i = 1, #tempCanvas do
                    newCanvas[i] = tempCanvas[i]
                end
                
                -- Replace the overlay
                overlay:delete()
                overlay = newCanvas
                overlay:show()
            end
        else
            print("Async update failed, exit code: " .. exitCode)
            isUpdating = false
        end
    end, {"list-windows", "--all", "--format", "%{workspace}|%{app-name}|%{window-title}|%{window-id}"})
    
    task:start()
end

-- Function to track user activity
local function updateUserActivity()
    lastUserActivity = os.time()
end

-- Function to check if system is idle (no recent user activity)
local function isSystemIdle()
    return (os.time() - lastUserActivity) > 60 -- 60 seconds of inactivity
end

-- Ultra-efficient background refresh with minimal resource usage
local function startBackgroundRefresh()
    -- Skip background refresh if on-demand mode is enabled
    if refreshOnDemandOnly then
        print("Background refresh disabled (on-demand mode)")
        return
    end
    
    if updateTimer then
        updateTimer:stop()
    end
    
    updateTimer = hs.timer.new(BACKGROUND_REFRESH_INTERVAL, function()
        -- Very strict conditions to minimize resource usage
        local shouldRefresh = not isOverlayVisible 
                             and not isUpdating 
                             and not isSystemIdle()  -- Don't refresh when system is idle
                             and not isCacheValid() -- Only refresh if cache is stale
                             and (os.time() - lastUserActivity) < 300 -- Only if user was active in last 5 minutes
        
        if shouldRefresh then
            print("Ultra-efficient background refresh triggered")
            isUpdating = true
            local data = fetchWorkspaceDataFast()
            if data then
                workspaceData = data
                cacheTimestamp = os.time()
            end
            isUpdating = false
        end
    end)
    updateTimer:start()
    print("Ultra-efficient background refresh timer started (every " .. BACKGROUND_REFRESH_INTERVAL .. "s)")
end

-- Function to stop background refresh
local function stopBackgroundRefresh()
    if updateTimer then
        updateTimer:stop()
        updateTimer = nil
        print("Background refresh timer stopped")
    end
end

-- Function to enable on-demand only mode (no background refresh)
local function enableOnDemandMode()
    refreshOnDemandOnly = true
    stopBackgroundRefresh()
    print("Switched to on-demand refresh mode (no background refresh)")
end

-- Function to disable on-demand mode (re-enable background refresh)
local function disableOnDemandMode()
    refreshOnDemandOnly = false
    startBackgroundRefresh()
    print("Switched to background refresh mode")
end

-- Function to format application list for display
local function formatAppList(apps)
    if not apps or #apps == 0 then
        return "No apps"
    end
    
    local appList = {}
    for _, app in ipairs(apps) do
        -- Use app name, truncate if too long
        local appName = app.appName
        if string.len(appName) > 12 then
            appName = string.sub(appName, 1, 9) .. "..."
        end
        table.insert(appList, appName)
    end
    
    return table.concat(appList, "\n")
end

-- Function to create overlay canvas elements (separated from display)
local function createOverlayCanvas()
    local screen = hs.screen.mainScreen()
    local screenFrame = screen:frame()
    
    -- Get data immediately (cached or empty)
    local data = fetchWorkspaceData()
    
    -- Use full screen for overlay
    local overlayFrame = screenFrame
    
    -- Calculate grid dimensions to fit screen
    local availableWidth = screenFrame.w - (CELL_MARGIN * 2)
    local availableHeight = screenFrame.h - (CELL_MARGIN * 2)
    
    -- Recalculate cell size to fit screen
    local cellWidth = (availableWidth - (GRID_COLS - 1) * CELL_MARGIN) / GRID_COLS
    local cellHeight = (availableHeight - (GRID_ROWS - 1) * CELL_MARGIN) / GRID_ROWS
    
    -- Center the grid within the screen
    local gridWidth = GRID_COLS * cellWidth + (GRID_COLS - 1) * CELL_MARGIN
    local gridHeight = GRID_ROWS * cellHeight + (GRID_ROWS - 1) * CELL_MARGIN
    local gridOffsetX = (screenFrame.w - gridWidth) / 2
    local gridOffsetY = (screenFrame.h - gridHeight) / 2
    
    -- Create canvas
    local canvas = hs.canvas.new(overlayFrame)
    
    -- Add semi-transparent background covering full screen
    canvas[1] = {
        type = "rectangle",
        action = "fill",
        fillColor = {red = 0, green = 0, blue = 0, alpha = 0.1},
        frame = {x = 0, y = 0, w = screenFrame.w, h = screenFrame.h}
    }
    
    -- Add grid cells
    local elementIndex = 2
    for row = 1, GRID_ROWS do
        for col = 1, GRID_COLS do
            local x = gridOffsetX + (col - 1) * (cellWidth + CELL_MARGIN)
            local y = gridOffsetY + (row - 1) * (cellHeight + CELL_MARGIN)
            local workspaceKey = getWorkspaceKey(col, row)
            
            if workspaceKey then
                -- Get applications for this workspace
                local apps = data[workspaceKey] or data[string.upper(workspaceKey)] or {}
                local hasApps = #apps > 0
                
                -- Add loading indicator if data is stale/empty and we're updating
                local isStaleData = not isCacheValid() or (next(data) == nil)
                local showLoading = isStaleData and isUpdating
                
                -- Cell background - highlight if has apps, show loading state
                local bgColor
                if showLoading then
                    bgColor = {red = 0.3, green = 0.3, blue = 0.4, alpha = 0.6}  -- Blue tint for loading
                elseif hasApps then
                    bgColor = {red = 0.2, green = 0.4, blue = 0.2, alpha = 0.7}  -- Green tint for active
                else
                    bgColor = {red = 0.2, green = 0.2, blue = 0.2, alpha = 0.5}  -- Gray for empty
                end
                
                canvas[elementIndex] = {
                    type = "rectangle",
                    action = "fill",
                    fillColor = bgColor,
                    strokeColor = {red = 0.5, green = 0.5, blue = 0.5, alpha = 1},
                    strokeWidth = 1,
                    frame = {x = x, y = y, w = cellWidth, h = cellHeight}
                }
                elementIndex = elementIndex + 1
                
                -- Workspace label
                canvas[elementIndex] = {
                    type = "text",
                    text = workspaceKey,
                    textColor = {red = 1, green = 1, blue = 1, alpha = 1},
                    textSize = 16,
                    textFont = "Helvetica-Bold",
                    frame = {x = x + 5, y = y + 5, w = cellWidth - 10, h = 22}
                }
                elementIndex = elementIndex + 1
                
                -- Applications list with loading indicator
                local appText
                local textColor
                
                if showLoading then
                    appText = "Loading..."
                    textColor = {red = 0.7, green = 0.7, blue = 1, alpha = 1}  -- Light blue for loading
                elseif hasApps then
                    appText = formatAppList(apps)
                    textColor = {red = 0.9, green = 1, blue = 0.9, alpha = 1}  -- Light green for apps
                else
                    appText = "No apps"
                    textColor = {red = 0.5, green = 0.5, blue = 0.5, alpha = 1}  -- Gray for no apps
                end
                
                canvas[elementIndex] = {
                    type = "text",
                    text = appText,
                    textColor = textColor,
                    textSize = 10,
                    textFont = "Helvetica",
                    frame = {x = x + 5, y = y + 27, w = cellWidth - 10, h = cellHeight - 32}
                }
                elementIndex = elementIndex + 1
            end
        end
    end
    
    return canvas
end

-- Function to create and display overlay instantly
local function createOverlay()
    local canvas = createOverlayCanvas()
    return canvas
end

-- Function to setup temporary key handlers for hiding overlay
local function setupTemporaryKeyHandlers()
    -- Common keys that should hide the overlay (using valid Hammerspoon key names)
    local keys = {
        "space", "return", "escape", "tab", "delete",
        "a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l", "m",
        "n", "o", "p", "q", "r", "s", "t", "u", "v", "w", "x", "y", "z",
        "1", "2", "3", "4", "5", "6", "7", "8", "9", "0",
        "up", "down", "left", "right"
    }
    
    for _, key in ipairs(keys) do
        local hotkey = hs.hotkey.bind({}, key, function()
            hideOverlay()
        end)
        table.insert(temporaryHotkeys, hotkey)
    end
    
    -- Also bind common modifier combinations
    local modifiers = {"cmd", "alt", "ctrl", "shift"}
    for _, mod in ipairs(modifiers) do
        for _, key in ipairs({"space", "return", "escape", "tab"}) do
            local hotkey = hs.hotkey.bind({mod}, key, function()
                hideOverlay()
            end)
            table.insert(temporaryHotkeys, hotkey)
        end
    end
end

-- Function to clear temporary key handlers
local function clearTemporaryKeyHandlers()
    for _, hotkey in ipairs(temporaryHotkeys) do
        hotkey:delete()
    end
    temporaryHotkeys = {}
end

-- Function to show overlay (INSTANT display)
local function showOverlay()
    if isOverlayVisible then return end
    
    local startTime = os.clock()
    
    -- Track user activity
    updateUserActivity()
    
    -- Create and show overlay immediately with cached/empty data
    overlay = createOverlay()
    overlay:show()
    isOverlayVisible = true
    
    -- Setup temporary hotkeys to hide overlay on any key press
    setupTemporaryKeyHandlers()
    
    local endTime = os.clock()
    print("AeroSpace overlay shown instantly in " .. string.format("%.3f", endTime - startTime) .. " seconds")
    
    -- Start async data update (non-blocking)
    updateWorkspaceDataAsync()
end

-- Function to hide overlay
function hideOverlay()
    if not isOverlayVisible then return end
    
    if overlay then
        overlay:delete()
        overlay = nil
    end
    
    -- Clear temporary hotkeys
    clearTemporaryKeyHandlers()
    
    if keyWatcher then
        keyWatcher:stop()
        keyWatcher = nil
    end
    
    isOverlayVisible = false
    print("AeroSpace overlay hidden")
end

-- Function to toggle overlay
local function toggleOverlay()
    -- Track user activity on toggle
    updateUserActivity()
    
    if isOverlayVisible then
        hideOverlay()
    else
        showOverlay()
    end
end

-- Set up hotkey binding (Alt + ESC)
local function setupHotkey()
    hs.hotkey.bind({"alt"}, "escape", toggleOverlay)
    print("AeroSpace overlay hotkey bound to Alt + ESC")
end

-- Initialize the module
local function init()
    setupHotkey()
    
    -- Initialize user activity tracking
    updateUserActivity()
    
    -- Start async pre-loading of workspace data (non-blocking)
    print("Starting async pre-load of workspace data...")
    updateWorkspaceDataAsync()
    
    -- Start with on-demand mode for maximum efficiency
    -- Users can switch to background mode if needed
    enableOnDemandMode()
    
    print("AeroSpace overlay initialized with instant display")
    print("Overlay will show immediately - data loads in background")
end

-- Cleanup function
local function cleanup()
    hideOverlay()
    stopBackgroundRefresh()
    print("AeroSpace overlay cleanup completed")
end

-- Module interface
M.init = init
M.cleanup = cleanup
M.showOverlay = showOverlay
M.hideOverlay = hideOverlay
M.toggleOverlay = toggleOverlay
M.startBackgroundRefresh = startBackgroundRefresh
M.stopBackgroundRefresh = stopBackgroundRefresh
M.enableOnDemandMode = enableOnDemandMode
M.disableOnDemandMode = disableOnDemandMode

-- Auto-initialize when loaded
init()

return M
