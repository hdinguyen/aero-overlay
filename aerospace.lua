-- AeroSpace Overlay for Hammerspoon
-- Shows a grid overlay of AeroSpace workspaces with applications in QWERTY layout
-- Hotkey: Alt + ESC to toggle overlay

hs.hotkey.setLogLevel("warning")

local M = {}

-- Configuration
local GRID_COLS = 10  -- QWERTY keyboard layout
local GRID_ROWS = 4   -- 4 rows of QWERTY layout
local CELL_MARGIN = 3

local overlay = nil
local isOverlayVisible = false
local temporaryHotkeys = {}
local fileWatcher = nil
local keyEventTap = nil
local mainHotkey = nil

-- QWERTY keyboard layout mapping for workspaces
-- Note: AeroSpace doesn't allow comma (,) in workspace names, so we skip it
local LAYOUT_ROWS = {
    {"1", "2", "3", "4", "5", "6", "7", "8", "9", "0"},
    {"q", "w", "e", "r", "t", "y", "u", "i", "o", "p"},
    {"a", "s", "d", "f", "g", "h", "j", "k", "l", ";"},
    {"z", "x", "c", "v", "b", "n", "m", "<", ">", "/"}  -- Replaced , with < and . with >
}

-- Mock data for static overlay demo
local mockWorkspaceData = {
    ["1"] = {
        {appName = "Chrome", windowTitle = "Gmail", windowId = "1001"},
        {appName = "Slack", windowTitle = "Team Chat", windowId = "1002"}
    },
    ["2"] = {
        {appName = "VSCode", windowTitle = "project.lua", windowId = "2001"},
        {appName = "Terminal", windowTitle = "zsh", windowId = "2002"}
    },
    ["q"] = {
        {appName = "Finder", windowTitle = "Documents", windowId = "3001"}
    },
    ["w"] = {
        {appName = "Safari", windowTitle = "GitHub", windowId = "4001"},
        {appName = "Notes", windowTitle = "Meeting Notes", windowId = "4002"},
        {appName = "Calculator", windowTitle = "", windowId = "4003"}
    },
    ["a"] = {
        {appName = "Spotify", windowTitle = "Playlist", windowId = "5001"}
    },
    ["s"] = {
        {appName = "Docker Desktop", windowTitle = "", windowId = "6001"},
        {appName = "Postman", windowTitle = "API Testing", windowId = "6002"}
    }
}

local workspaceData = {}
local currentWorkspace = nil  -- Will be fetched from AeroSpace
local cacheTimestamp = 0
local CACHE_DURATION = 10
local isUpdating = false

-- Function to get workspace key from grid position
local function getWorkspaceKey(col, row)
    if row <= #LAYOUT_ROWS and col <= #LAYOUT_ROWS[row] then
        return LAYOUT_ROWS[row][col]
    end
    return nil
end

local function trimWorkspace(workspace)
    return workspace and workspace:gsub("^%s*(.-)%s*$", "%1") or nil
end

local function executeAerospaceCommand(args)
    local command = "/opt/homebrew/bin/aerospace " .. table.concat(args, " ")
    local result, status = hs.execute(command)
    
    if not status or not result or result == "" then
        return {}
    end
    
    local success, jsonData = pcall(hs.json.decode, result)
    return success and jsonData or nil
end

-- Function to check if cache is valid
local function isCacheValid()
    local currentTime = os.time()
    return (currentTime - cacheTimestamp) < CACHE_DURATION
end

local function executeFormatCommand(args)
    local escapedArgs = {}
    for _, arg in ipairs(args) do
        if string.find(arg, "[%s%;%,%|%&%$%`%'%\"%\\%*%?%[%]%(%){}<>]") or string.find(arg, "%{") then
            local escaped = string.gsub(arg, "'", "'\"'\"'")
            table.insert(escapedArgs, "'" .. escaped .. "'")
        else
            table.insert(escapedArgs, arg)
        end
    end
    
    local command = "/opt/homebrew/bin/aerospace " .. table.concat(escapedArgs, " ")
    local result, status = hs.execute(command)
    
    return status and result or nil
end


local function fetchWorkspaceDataFast(callback)
    hs.task.new("/opt/homebrew/bin/aerospace", function(exitCode, stdOut, stdErr)
        if exitCode ~= 0 or not stdOut or stdOut == "" then
            if callback then callback({}) end
            return
        end
        
        local data = {}
        
        -- Parse each line to extract app info and workspace
        for line in stdOut:gmatch("[^\r\n]+") do
            if line and line ~= "" then
                local parts = {}
                for part in line:gmatch("[^|]+") do
                    table.insert(parts, part)
                end
                
                if #parts >= 4 then
                    local appName = parts[1]
                    local windowTitle = parts[2] or ""
                    local windowId = parts[3] or ""
                    local workspaceName = parts[4]
                    
                    -- Initialize workspace array if it doesn't exist
                    if not data[workspaceName] then
                        data[workspaceName] = {}
                    end
                    
                    -- Add app to workspace
                    table.insert(data[workspaceName], {
                        appName = appName,
                        windowTitle = windowTitle,
                        windowId = windowId
                    })
                end
            end
        end
        
        if callback then callback(data) end
        
    end, {"list-windows", "--all", "--format", "%{app-name}|%{window-title}|%{window-id}|%{workspace}"}):start()
end

-- Function to fetch workspace data with caching (NEVER blocks)
local function fetchWorkspaceData()
    -- For static demo, return mock data directly
    return mockWorkspaceData
end




local function forceRefreshWorkspaceData()
    cacheTimestamp = 0
end

local function forceRefreshCurrentWorkspace()
    currentWorkspace = nil
    hs.task.new("/opt/homebrew/bin/aerospace", function(exitCode, stdOut, stdErr)
        if exitCode == 0 and stdOut and stdOut ~= "" then
            local workspace = stdOut:match("([^\r\n]+)")
            if workspace then
                currentWorkspace = trimWorkspace(workspace)
            end
        end
    end, {"list-workspaces", "--focused", "--format", "%{workspace}"}):start()
end

local function forceRefreshAll()
    forceRefreshCurrentWorkspace()
    forceRefreshWorkspaceData()
end

local eventListenerEnabled = false
local eventServer = nil
local eventListenerPort = 18901

local function handleWorkspaceChange(newWorkspace)
    currentWorkspace = newWorkspace
end

local function startEventListener()
    if eventListenerEnabled then
        return
    end
    
    -- Create simple HTTP server to receive workspace change notifications
    eventServer = hs.httpserver.new(false, false)
    eventServer:setInterface("127.0.0.1")
    eventServer:setPort(eventListenerPort)
    
    eventServer:setCallback(function(method, path, headers, body)
        if method == "POST" and path == "/workspace-change" then
            -- Parse workspace from request body
            local workspace = body and body:match("([^\r\n]+)")
            if workspace then
                workspace = trimWorkspace(workspace)  -- Trim whitespace
                handleWorkspaceChange(workspace)
            end
            return "OK", 200, {}
        end
        return "Not Found", 404, {}
    end)
    
    if eventServer:start() then
        eventListenerEnabled = true
    else
        eventServer = nil
    end
end

local function stopEventListener()
    if not eventListenerEnabled then
        return
    end
    
    if eventServer then
        eventServer:stop()
        eventServer = nil
    end
    
    eventListenerEnabled = false
end

-- Function to toggle event listener
local function toggleEventListener()
    if eventListenerEnabled then
        stopEventListener()
    else
        startEventListener()
    end
end

-- Function to show event listener setup instructions
local function showEventSetupInstructions()
    hs.alert.show("Check Hammerspoon console for setup instructions", 3)
    print("📖 AeroSpace Event Listener Setup Instructions:")
    print("")
    print("1. Add this line to your ~/.config/aerospace/aerospace.toml:")
    print("   exec-on-workspace-change = ['curl', '-X', 'POST', '-d', '$AEROSPACE_FOCUSED_WORKSPACE', 'http://127.0.0.1:" .. eventListenerPort .. "/workspace-change']")
    print("")
    print("2. Reload AeroSpace config:")
    print("   aerospace reload-config")
    print("")
    print("3. Enable the event listener:")
    print("   aerospace.toggleEventListener()")
    print("")
    print("Benefits:")
    print("- Instant overlay updates when switching workspaces")
    print("- Real-time current workspace highlighting")
    print("- No polling or background refresh needed")
    print("- Minimal resource usage")
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
local function createOverlayCanvas(callback)
    local screen = hs.screen.mainScreen()
    local screenFrame = screen:frame()
    
    -- Get real workspace data asynchronously
    fetchWorkspaceDataFast(function(data)
        
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
        
        -- Make overlay completely non-interactive and transparent to system
        canvas:canvasMouseEvents(false)        -- No mouse events at all
        canvas:clickActivating(false)          -- Don't activate on clicks
        canvas:wantsLayer(true)               -- Use Core Animation layer for better performance
        canvas:level(hs.canvas.windowLevels.overlay)  -- Show above other windows but not interfere
        canvas:behavior(hs.canvas.windowBehaviors.canJoinAllSpaces)  -- Available on all spaces
    
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
                    -- Get applications for this workspace (only exists if workspace has apps)
                    local apps = data[workspaceKey] or data[string.upper(workspaceKey)]
                    local hasApps = apps and #apps > 0
                    
                    -- Check if this is the current workspace
                    local isCurrentWorkspace = currentWorkspace and (workspaceKey == currentWorkspace or workspaceKey == string.lower(currentWorkspace))
                    
                    -- Only show loading if we have absolutely no data AND we're updating
                    -- Don't show loading for stale cache - show cached data instead
                    local hasNoData = (next(data) == nil)
                    local showLoading = hasNoData and isUpdating
                    
                    -- Cell background - highlight current workspace with different color
                    local bgColor
                    if showLoading then
                        bgColor = {red = 0.3, green = 0.3, blue = 0.4, alpha = 0.6}  -- Blue tint for loading
                    elseif isCurrentWorkspace then
                        -- Current workspace gets a light red/pink background
                        if hasApps then
                            bgColor = {red = 0.5, green = 0.2, blue = 0.2, alpha = 0.7}  -- Red tint for current with apps
                        else
                            bgColor = {red = 0.4, green = 0.2, blue = 0.2, alpha = 0.6}  -- Red tint for current empty
                        end
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
        
        if callback then callback(canvas) end
    end)
end


-- Function to setup event tap for capturing any key press
local function setupEventTap()
    -- Temporarily disable main hotkey to prevent conflicts
    if mainHotkey then
        mainHotkey:disable()
    end
    
    -- Create event tap to capture key down events
    keyEventTap = hs.eventtap.new({hs.eventtap.event.types.keyDown}, function(event)
        -- Add error handling to prevent crashes
        local success, result = pcall(function()
            -- Hide overlay immediately - no delay needed
            if isOverlayVisible then
                hideOverlay()
            end
            
            return false
        end)
        
        if not success then
            return false
        end
        
        return result
    end)
    
    if keyEventTap then
        keyEventTap:start()
    end
end

-- Function to clear event tap
local function clearEventTap()
    -- Stop and clear event tap
    if keyEventTap then
        local success, err = pcall(function()
            keyEventTap:stop()
        end)
        keyEventTap = nil
    end
    
    -- Re-enable main hotkey
    if mainHotkey then
        local success, err = pcall(function()
            mainHotkey:enable()
        end)
    end
end

-- Function to show overlay (INSTANT display)
local function showOverlay()
    if isOverlayVisible then 
        return 
    end
    
    -- Force refresh all data first
    forceRefreshAll()
    
    -- Get real current workspace from AeroSpace, then show overlay
    hs.task.new("/opt/homebrew/bin/aerospace", function(exitCode, stdOut, stdErr)
        if exitCode == 0 and stdOut and stdOut ~= "" then
            local workspace = stdOut:match("([^\r\n]+)")
            if workspace then
                currentWorkspace = trimWorkspace(workspace)
            end
        end
        
        -- Create and show overlay after workspace update completes
        createOverlayCanvas(function(canvas)
            overlay = canvas
            overlay:show()
            isOverlayVisible = true
            
            -- Setup event tap to hide overlay on any key press
            setupEventTap()
        end)
    end, {"list-workspaces", "--focused", "--format", "%{workspace}"}):start()
end

-- Function to hide overlay
function hideOverlay()
    if not isOverlayVisible then 
        return 
    end
    
    if overlay then
        local success, err = pcall(function()
            overlay:delete()
        end)
        overlay = nil
    end
    
    -- Clear event tap
    local success, err = pcall(function()
        clearEventTap()
    end)
    
    isOverlayVisible = false
end

-- Function to toggle overlay
local function toggleOverlay()
    if isOverlayVisible then
        hideOverlay()
    else
        showOverlay()
    end
end

-- Set up hotkey binding with proper cleanup
local function setupHotkey()
    -- Clean up existing hotkey first
    if mainHotkey then
        mainHotkey:delete()
        mainHotkey = nil
    end
    
    -- Try Alt + ESC first
    mainHotkey = hs.hotkey.new({"alt"}, "escape", toggleOverlay)
    local success = mainHotkey:enable()
    
    if not success then
        mainHotkey:delete()
        
        -- Fallback to Alt + F12
        mainHotkey = hs.hotkey.new({"alt"}, "f12", toggleOverlay)
        local fallbackSuccess = mainHotkey:enable()
        
        if not fallbackSuccess then
            mainHotkey:delete()
            mainHotkey = nil
        end
    end
end

-- Function to setup file watcher for workspace changes
local function setupFileWatcher()
    -- Watch the workspace file for changes
    fileWatcher = hs.pathwatcher.new("/tmp/aerospace-current-workspace", function(files)
        -- Read the new workspace
        local file = io.open("/tmp/aerospace-current-workspace", "r")
        if file then
            local newWorkspace = file:read("*line")
            file:close()
            if newWorkspace and newWorkspace ~= "" then
                newWorkspace = trimWorkspace(newWorkspace)  -- Trim whitespace
                currentWorkspace = newWorkspace
            end
        end
    end)
    
    fileWatcher:start()
end

-- Initialize the module
local function init()
    -- Preload extensions to avoid lazy loading delays during event handling
    local _ = hs.keycodes.map  -- Force load keycodes extension
    local _ = hs.eventtap.event.types.keyDown  -- Force load eventtap extension
    
    setupHotkey()
    setupFileWatcher()
    
end

-- Cleanup function
local function cleanup()
    hideOverlay()
    stopEventListener()
    
    -- Clean up event tap
    if keyEventTap then
        keyEventTap:stop()
        keyEventTap = nil
    end
    
    -- Clean up main hotkey
    if mainHotkey then
        mainHotkey:delete()
        mainHotkey = nil
    end
    
    -- Stop file watcher
    if fileWatcher then
        fileWatcher:stop()
        fileWatcher = nil
    end
    
end

-- Module interface
M.init = init
M.cleanup = cleanup
M.showOverlay = showOverlay
M.hideOverlay = hideOverlay
M.toggleOverlay = toggleOverlay

-- Manual refresh controls
M.forceRefreshWorkspaceData = forceRefreshWorkspaceData
M.forceRefreshCurrentWorkspace = forceRefreshCurrentWorkspace
M.forceRefreshAll = forceRefreshAll


-- Event listener controls
M.startEventListener = startEventListener
M.stopEventListener = stopEventListener
M.toggleEventListener = toggleEventListener
M.showEventSetupInstructions = showEventSetupInstructions

-- Auto-initialize when loaded
init()

return M
