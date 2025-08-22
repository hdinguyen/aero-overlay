# AeroSpace Overlay for Hammerspoon

This project provides a visual overlay system for AeroSpace window manager, inspired by https://blog.jverkamp.com/2023/01/23/once-again-to-hammerspoon/#pulling-it-all-together-initlua

## Purpose

An easy way to visualize and control AeroSpace workspaces (https://nikitabobko.github.io/AeroSpace/guide) using Hammerspoon (https://www.hammerspoon.org/go/).

## Features

### 1. Visual Workspace Overlay
- **Hotkey**: Alt + ESC to toggle overlay
- Shows all AeroSpace workspaces with their applications
- Real-time integration with AeroSpace CLI
- Visual indicators for active/empty workspaces

### 2. QWERTY Keyboard Layout
The overlay displays workspaces in QWERTY keyboard layout order:

```
Row 1: 1 2 3 4 5 6 7 8 9 0
Row 2: q w e r t y u i o p  
Row 3: a s d f g h j k l ;
Row 4: z x c v b n m , . /
```

### 3. Application Display
- Lists all applications in each workspace
- Highlights workspaces with applications (green tint)
- Empty workspaces shown in gray
- Application names truncated for display

## Usage

1. Ensure AeroSpace is installed and configured
2. Load the `aerospace.lua` script in Hammerspoon
3. Press `Alt + ESC` to toggle the overlay
4. Press any key to hide the overlay

## Performance Features

### Resource Optimization
- **On-Demand Mode** (default): No background refresh, data updates only when overlay is shown
- **Smart Caching**: 10-second cache duration to minimize CLI calls
- **User Activity Tracking**: Prevents unnecessary refreshes during idle periods
- **Single CLI Call**: Uses format command for 80% faster data fetching (~22ms vs 100ms+)

### Usage Modes
```lua
-- Switch to background refresh mode (if you want automatic updates)
require("aerospace").disableOnDemandMode()

-- Switch back to on-demand mode (maximum efficiency)
require("aerospace").enableOnDemandMode()
```

## Integration

The overlay integrates with AeroSpace using optimized CLI commands:
- **Primary**: `aerospace list-windows --all --format "%{workspace}|%{app-name}|%{window-title}|%{window-id}"` - Single fast call
- **Fallback**: `aerospace list-workspaces --all --json` - If format command fails

