# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a Hammerspoon-based overlay system for AeroSpace window manager. The project creates an interactive overlay that helps users visualize which applications belong to which workspace in AeroSpace.

## Key Components

- **aerospace.lua**: Main Hammerspoon script (currently empty - needs implementation)
- **README.md**: Project documentation and requirements

## Project Goals

1. **Workspace Overlay**: Toggle overlay showing application-to-workspace mapping
   - Hotkey: Alt + ESC
   - Grid layout: 10 columns (1,2,3,4,5,6,7,8,9,0) × 4 rows (a,b,c,d)
   - Purpose: Visual aid for AeroSpace workspace navigation

2. **Integration Points**:
   - AeroSpace window manager (https://nikitabobko.github.io/AeroSpace/guide)
   - Hammerspoon automation (https://www.hammerspoon.org/go/)

## Development Context

- **Language**: Lua (Hammerspoon scripting)
- **Target Platform**: macOS
- **Dependencies**: 
  - AeroSpace window manager
  - Hammerspoon application

## Architecture Notes

This is a single-script project focused on creating a visual overlay system. The main implementation should be contained in `aerospace.lua` following Hammerspoon's module structure and event handling patterns.

## Reference Implementation

The project draws inspiration from: https://blog.jverkamp.com/2023/01/23/once-again-to-hammerspoon/#pulling-it-all-together-initlua