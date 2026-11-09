-- Semantic highlight groups.
--
-- Everything here is static: each group links to one of Neovim's own groups, so
-- the panel looks like any other buffer and follows the colorscheme without this
-- module inspecting colours at runtime.
--
-- Content groups (`AcpBold`, `AcpH1`, ...) link to the treesitter `@markup.*`
-- captures on purpose. A bold word, a heading or a quote therefore renders the
-- same in the transcript as it does in an ordinary Markdown buffer, including
-- under themes that only define the generic captures.
--
-- Two ways to customise, both of which win over these defaults:
--
--   * `ui.highlights` in `setup()` — a table of group -> definition
--   * `vim.api.nvim_set_hl(0, "AcpUser", { fg = "#ff0000" })` at any time
--
-- The defaults are applied with `default = true` (`:hi-default`), which never
-- replaces a group that already exists.
local M = {}

M.groups = {
  AcpNormal = { link = "Normal" },
  AcpMuted = { link = "Comment" },
  AcpBorder = { link = "FloatBorder" },
  AcpTitle = { link = "Title" },

  -- Toolbar. The panel maps `WinBar` to `AcpToolbar`, so a region that only
  -- sets a foreground still paints the bar's background: the bar reads as one
  -- strip, and only the glyph colour changes between states.
  AcpToolbar = { link = "StatusLine" },
  -- Only a foreground: the background is inherited from `AcpToolbar` via the
  -- `%$...$` markup, so there is nothing to set here.
  AcpToolbarAccent = { fg = "fg" },
  -- Modes are badges, told apart by their background.
  AcpToolbarModePlan = { fg = "#212121", bg = "#ffcb6b" },
  AcpToolbarModeBuild = { fg = "#212121", bg = "#c792ea" },
  -- Statuses are plain glyphs. Idle is just the bar's own text colour: no
  -- emphasis means no special colour, and it is readable by construction.
  -- (`Comment` would be tempting but is tuned for prose on `Normal`.) The other
  -- states take their theme diagnostic colour.
  AcpToolbarIdle = { link = "StatusLine" },
  AcpToolbarRunning = { link = "DiagnosticInfo" },
  AcpToolbarWaiting = { link = "DiagnosticWarn" },
  AcpToolbarCancelling = { link = "DiagnosticError" },

  AcpUser = { link = "Function" },
  AcpUserChip = { link = "Visual" },
  AcpAssistant = { link = "Normal" },
  -- The block header is split in two so the glyph and the label can be coloured
  -- independently: the icon marks who is speaking, the title names the turn.
  -- Both default to the speaker's own colour, which keeps the header reading as
  -- one unit until someone deliberately splits them.
  AcpUserIcon = { link = "AcpUser" },
  AcpUserTitle = { link = "AcpUserIcon" },
  AcpAssistantIcon = { link = "AcpAssistant" },
  AcpAssistantTitle = { link = "AcpAssistantIcon" },
  -- Thoughts are quiet reasoning text; there is no standard capture for them.
  AcpThought = { link = "@markup.raw" },
  -- Tool headers label a call, they are not the content, so they stay quiet.
  AcpToolTitle = { link = "Comment" },
  AcpToolTag = { link = "Comment" },

  -- There is deliberately no `AcpToolBody` group: card body text must inherit
  -- whatever is behind it so the card's own background shows through.
  --
  -- Both surfaces come from theme groups rather than a colour blended at
  -- runtime. `CursorLine` is the raised one, `NormalFloat` the sunken one, so a
  -- code block inside a card still reads as a separate region.
  AcpCardBg = { link = "CursorLine" },
  AcpCodeBlockBg = { link = "NormalFloat" },
  -- Same captures a Markdown buffer uses for a fenced block's info string and
  -- for table borders, so both look identical to a `.md` file.
  AcpCodeLang = { link = "@label" },

  AcpTableHead = { link = "@markup.heading" },
  -- The frame is chrome, not content: one quiet grey group for every border
  -- character. `@punctuation.special` would be the Markdown-parity choice, but
  -- themes colour it as an accent (orange under gruvbox), which turns a table
  -- into a neon grid.
  AcpTableBorder = { link = "NonText" },

  AcpToolRunning = { link = "DiagnosticWarn" },
  AcpToolSuccess = { link = "DiagnosticOk" },
  AcpToolError = { link = "DiagnosticError" },
  AcpToolCancelled = { link = "Comment" },

  -- Content shares the treesitter captures used by a Markdown buffer, except
  -- inline code: `@markup.raw` is a warm accent there, which reads as emphasis
  -- in prose. `String` keeps inline code distinguishable from running text
  -- without shouting.
  AcpMdCode = { link = "String" },
  AcpBold = { link = "@markup.strong" },
  AcpItalic = { link = "@markup.italic" },
  AcpStrike = { link = "@markup.strikethrough" },
  AcpMdLink = { link = "@markup.link" },
  -- One per level, so a theme that distinguishes headings keeps doing so. When
  -- it defines only `@markup.heading`, the numbered captures fall back to it —
  -- the same chain a Markdown buffer follows.
  AcpH1 = { link = "@markup.heading.1" },
  AcpH2 = { link = "@markup.heading.2" },
  AcpH3 = { link = "@markup.heading.3" },
  AcpH4 = { link = "@markup.heading.4" },
  AcpQuote = { link = "@markup.quote" },
  AcpLink = { link = "@markup.link" },

  AcpPlan = { link = "DiagnosticInfo" },
  AcpPlanDone = { link = "DiagnosticOk" },
  AcpPlanPending = { link = "Comment" },
  AcpNotice = { link = "DiagnosticInfo" },
  AcpNoticeWarn = { link = "DiagnosticWarn" },
  AcpNoticeError = { link = "DiagnosticError" },
  AcpPermission = { link = "DiagnosticWarn" },
  AcpChild = { link = "Comment" },
  AcpSeparator = { link = "NonText" },
  AcpStreaming = { link = "DiagnosticInfo" },
  AcpSelection = { link = "Visual" },
  AcpPinned = { link = "StatusLine" },
}

---Groups supplied through `ui.highlights`. Applied after the defaults and
---replacing them, because naming a group there is an explicit choice.
---@type table<string, table>
local overrides = {}

local augroup = nil

---Define a group unless something already defined it.
---@param name string
---@param spec table
---@return boolean
local function set_hl(name, spec)
  -- `default` belongs *in* the spec: `nvim_set_hl` takes three parameters, and
  -- a fourth is silently ignored when the call is wrapped in `pcall`.
  return pcall(vim.api.nvim_set_hl, 0, name, vim.tbl_extend("force", spec, { default = true }))
end

---Define every group. Safe to call again after a colorscheme change.
local function apply()
  for name, spec in pairs(M.groups) do
    set_hl(name, spec)
  end
  -- Configured groups are forced, so calling `setup` again with new values takes
  -- effect instead of being skipped as "already defined".
  for name, spec in pairs(overrides) do
    pcall(vim.api.nvim_set_hl, 0, name, spec)
  end
end

M.apply = apply

---Apply highlights.
---
---A colorscheme load clears every user group, so the definitions are re-applied
---on ColorScheme. Without this the whole panel loses its colours when the user
---switches theme after setup.
---@param config table<string, table>|nil group name -> `nvim_set_hl` definition
function M.setup(config)
  overrides = type(config) == "table" and config or {}
  apply()

  if augroup then
    pcall(vim.api.nvim_del_augroup_by_id, augroup)
  end
  augroup = vim.api.nvim_create_augroup("AcpHighlights", { clear = true })
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = augroup,
    callback = function()
      apply()
    end,
  })
end

---Resolve a status to a highlight group.
---@param status string|nil
---@return string
function M.tool_status(status)
  if status == "completed" then
    return "AcpToolSuccess"
  elseif status == "failed" then
    return "AcpToolError"
  elseif status == "in_progress" or status == "pending" then
    return "AcpToolRunning"
  elseif status == "cancelled" then
    return "AcpToolCancelled"
  end
  return "AcpMuted"
end

return M
