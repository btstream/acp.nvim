-- Icon set. Nerd Font glyphs by default, with an ASCII fallback.
--
-- Nerd Font is assumed unless `ui.icons = false`. Every glyph below lives in
-- the Nerd Fonts Nerd Fonts-patched range, so no extra plugin is required.
local M = {}

---Nerd Font glyphs (default).
---@return table<string, string>
function M.nerd()
  return {
    tool = "󰒓", -- cog
    tool_ok = "󰄬", -- check
    tool_fail = "󰅖", -- close
    tool_run = "󰝱", -- loading
    tool_pending = "󰝦", -- circle-outline
    user = "󰀄", -- account
    assistant = "󰚩", -- robot
    thought = "󰧤", -- brain
    plan = "󰉹", -- format-list
    notice = "󰋼", -- information
    compaction = "󰏘", -- compress
    child = "󱍔", -- subdirectory
    more = "󰇘", -- dots-horizontal
    chevron_down = "󰅀", -- chevron-down
    chevron_right = "󰅂", -- chevron-right
    arrow_down = "󰁅", -- arrow-down
    trash = "󰩹", -- trash
    session = "󰈔", -- message-text
    model = "󰍣", -- chip
    mode = "󰣢", -- tune
    file = "󰈔", -- file
    error = "󰅙", -- alert-circle
    warning = "󰀪", -- alert
    check_circle = "󰗠", -- check-circle
    spinner = "󰝱", -- loading
    ellipsis = "󰇘", -- dots-horizontal
    cursor = "󰜠", -- cursor-default
    close = "󰅖", -- close
    plus = "󰐕", -- plus
    history = "󰋚", -- history
    arrow_right = "󰁔", -- arrow-right
  }
end

---Plain ASCII fallback for terminals without a patched font.
---@return table<string, string>
function M.ascii()
  return {
    tool = "*",
    tool_ok = "v",
    tool_fail = "x",
    tool_run = "o",
    tool_pending = ".",
    user = ">",
    assistant = "#",
    thought = "+",
    plan = "*",
    notice = "!",
    compaction = "=",
    child = ">",
    more = "...",
    chevron_down = "v",
    chevron_right = ">",
    arrow_down = "v",
    trash = "x",
    session = "=",
    model = "M",
    mode = "T",
    file = "f",
    error = "E",
    warning = "W",
    check_circle = "v",
    spinner = "*",
    ellipsis = "...",
    cursor = ">",
    close = "x",
    plus = "+",
    history = "H",
    arrow_right = ">",
  }
end

---Resolve the active icon set.
---@param use_icons boolean|nil
---@return table<string, string>
function M.get(use_icons)
  if use_icons == false then
    return M.ascii()
  end
  return M.nerd()
end

return M
