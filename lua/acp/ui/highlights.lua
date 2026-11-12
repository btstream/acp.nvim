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
  AcpInputImage = { fg = "#292929", bg = "#ffcc80", bold = true },

  -- Inline editing. The prompt is a modal-looking float; pending hunks take the
  -- warning colour and the current one the info colour.
  AcpInlinePrompt = { link = "NormalFloat" },
  AcpInlineBorder = { link = "FloatBorder" },
  AcpInlineTitle = { link = "FloatTitle" },
  AcpInlineBanner = { link = "Comment" },
  -- Shared diff roles. Card rows paint these as a background; the review links
  -- its hunk and bar groups to them, so one override reaches every diff surface.
  -- They follow the theme's own diff colours on purpose: the plugin does no
  -- colour maths at runtime.
  AcpDiffAdd = { link = "DiffAdd" },
  AcpDiffDelete = { link = "DiffDelete" },
  AcpDiffModify = { link = "DiffChange" },
  -- Side-by-side review. The columns are padded scratch buffers, not Vim
  -- diff windows, so these are the only surfaces a review paints.
  AcpReviewNormal = { link = "Normal" },
  -- Filler rows: a hatch in a fixed subdued grey, visible on themes whose
  -- `DiffDelete` sets no foreground.
  AcpReviewFiller = { fg = "#5c6370" },
  AcpReviewGutter = { link = "LineNr" },
  AcpReviewGutterCur = { link = "CursorLineNr" },
  AcpReviewFold = { link = "Folded" },
  AcpReviewFoldCol = { link = "FoldColumn" },
  AcpReviewEob = { link = "Normal" },
  AcpReviewSep = { link = "WinSeparator" },
  -- The cursor row, mirrored into every column by `cursorbind`. The background
  -- is copied from `CursorLine` without its underline (see `define_review`).
  AcpReviewCursorLine = { link = "CursorLine" },
  -- Pane headers: a badge saying which side this is, its label and, on the
  -- result column, the decision count.
  AcpReviewBadgeOriginal = { link = "Comment" },
  AcpReviewBadgeResult = { link = "DiagnosticInfo" },
  AcpReviewBadgeProposal = { link = "DiagnosticOk" },
  AcpReviewPath = { link = "Comment" },
  AcpReviewVersion = { link = "NonText" },
  -- Row surfaces. No foreground: syntax colours remain in charge of the text.
  -- The original column shows what goes away, the proposal what comes in, the
  -- result what is still undecided. Backgrounds are copied from the theme's
  -- diff groups in `define_review`.
  AcpReviewAdd = { link = "AcpDiffAdd" },
  AcpReviewDelete = { link = "AcpDiffDelete" },
  AcpReviewPending = { link = "AcpDiffModify" },
  -- Characters that changed inside a paired row.
  AcpReviewAddText = { link = "DiffText" },
  AcpReviewDeleteText = { link = "DiffText" },
  -- A side that lost the decision: the replaced original or the dropped
  -- proposal. A foreground, so it overrides syntax colours.
  AcpReviewDimmed = { link = "Comment" },
  -- The one-cell state bar beside every row of a hunk, in every column.
  AcpReviewStatePending = { link = "DiagnosticWarn" },
  AcpReviewStateCurrent = { link = "DiagnosticInfo" },
  AcpReviewStateAccepted = { link = "AcpInlineAccepted" },
  AcpReviewStateRejected = { link = "AcpInlineRejected" },
  -- Key hints after the hunk under the cursor.
  AcpReviewHint = { link = "Comment" },
  AcpInlineAccepted = { link = "DiagnosticOk" },
  AcpInlineRejected = { link = "ErrorMsg" },
  AcpAssistant = { link = "Normal" },
  -- The block header is split in two so the glyph and the label can be coloured
  -- independently: the icon marks who is speaking, the title names the turn.
  -- Both default to the speaker's own colour, which keeps the header reading as
  -- one unit until someone deliberately splits them.
  AcpUserIcon = { link = "AcpUser" },
  AcpUserTitle = { link = "AcpUserIcon" },
  AcpAssistantIcon = { link = "Keyword" },
  AcpAssistantTitle = { link = "Keyword" },
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
  -- Diffs inside a tool card. The line colour is the diff background itself, so
  -- a change reads like it does in a review window; the sign gets its own group
  -- because some themes only colour the background.
  AcpDiffAddSign = { link = "DiffAdd" },
  AcpDiffRemoveSign = { link = "DiffDelete" },
  AcpDiffHunk = { link = "@label" },
  AcpDiffMeta = { link = "Comment" },
  AcpDiffFile = { link = "Title" },
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

  -- Pickers the plugin draws itself (`ui.picker = "internal"` and the
  -- `:Acp sessions` window). The window chrome is mapped through `winhighlight`,
  -- so a float can be styled apart from other floating windows without
  -- touching the theme's `NormalFloat`/`FloatBorder` groups.
  AcpPickerNormal = { link = "NormalFloat" },
  AcpPickerBorder = { link = "FloatBorder" },
  AcpPickerTitle = { link = "FloatTitle" },
  -- The cursor row. Links to the generic selection group so a picker looks like
  -- every other selection by default, but can be styled on its own.
  AcpPickerSelection = { link = "AcpSelection" },
  -- The label of a row. Links to `Normal` rather than to a surface group: inside
  -- a picker float `winhighlight` already remaps `Normal` to `AcpPickerNormal`,
  -- while in a snacks list it stays the list's own background.
  AcpPickerItem = { link = "Normal" },
  -- Characters matched by the filter query.
  AcpPickerMatch = { link = "Search" },
  -- The active row's marker: the session arrow and the check on the current
  -- option.
  AcpPickerCurrent = { link = "StatusLine" },
  -- The active row's label. Emphasis only, with no background of its own, so a
  -- snacks row does not turn into a statusline strip.
  AcpPickerCurrentItem = { link = "AcpTitle" },
  -- Row descriptions and timestamps, drawn at the end of the line.
  AcpPickerDescription = { link = "Comment" },
  AcpPickerMeta = { link = "Comment" },
  -- "no match" / "no matching sessions".
  AcpPickerEmpty = { link = "Comment" },
  -- The rule above the footer of the session browser.
  AcpPickerSeparator = { link = "NonText" },
  -- The filter prompt and the text typed into it.
  AcpPickerPrompt = { link = "AcpToolbarAccent" },
  -- Footer hints and transient status ("deleting...", "deleted").
  AcpPickerFooter = { link = "Comment" },

  -- Generic selection groups. The pickers link to these by default; the
  -- transcript and panels use them directly.
  AcpSelection = { link = "Visual" },
  AcpPinned = { link = "StatusLine" },
}

---Groups supplied through `ui.highlights`. Applied after the defaults and
---replacing them, because naming a group there is an explicit choice.
---@type table<string, table>
local overrides = {}

local augroup = nil

---Define a group unless something already defined it.
---
---Built-in groups use `default` so a user value set with `nvim_set_hl` before
---`setup` survives.
---@param name string
---@param spec table
---@return boolean
local function set_hl(name, spec)
  -- `default` belongs *in* the spec: `nvim_set_hl` takes three parameters, and
  -- a fourth is silently ignored when the call is wrapped in `pcall`.
  return pcall(vim.api.nvim_set_hl, 0, name, vim.tbl_extend("force", spec, { default = true }))
end

---@param name string
---@param spec table
local function force_hl(name, spec)
  pcall(vim.api.nvim_set_hl, 0, name, spec)
end

---Names overridden by the last `setup`. They are redefined from scratch on the
---next apply so removing an override falls back to the built-in spec instead of
---keeping a stale colour.
local forced = {}

---Give the review row groups the theme's diff background.
---
---Only the background is copied, so the theme's diff foreground or underline
---never replaces syntax colours. That is a read, never a blend: the colour is
---still the theme's, and `ColorScheme` repeats the copy. A theme without a
---diff background falls back to a link.
local function define_review()
  for _, kind in ipairs({
    { "AcpReviewAdd", "DiffAdd" },
    { "AcpReviewDelete", "DiffDelete" },
    { "AcpReviewPending", "DiffChange" },
    { "AcpReviewAddText", "DiffText" },
    { "AcpReviewDeleteText", "DiffText" },
    { "AcpReviewCursorLine", "CursorLine" },
  }) do
    local group, source = kind[1], kind[2]
    local ok, def = pcall(vim.api.nvim_get_hl, 0, { name = source, link = false })
    if ok and type(def) == "table" and def.bg then
      force_hl(group, { bg = def.bg })
    else
      force_hl(group, { link = source })
    end
  end
end

---Define every group. Safe to call again after a colorscheme change.
---
---Every group is a literal spec or a link; nothing is computed from the current
---theme. That keeps overrides predictable: setting one role group reaches every
---surface linked to it, and a review always resolves to the same definitions.
local function apply()
  for _, name in ipairs(forced) do
    force_hl(name, {})
  end
  for name, spec in pairs(M.groups) do
    set_hl(name, spec)
  end
  define_review()
  -- The previous overrides were cleared above, which makes `default` skip them;
  -- put their built-in spec back before applying the current overrides.
  for _, name in ipairs(forced) do
    if M.groups[name] then
      force_hl(name, M.groups[name])
    end
  end
  for name, spec in pairs(overrides) do
    force_hl(name, spec)
  end
  forced = vim.tbl_keys(overrides)
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

---------------------------------------------------------------------------
-- Picker groups
---------------------------------------------------------------------------

---Group names used by the plugin's own pickers.
---
---Kept here so the picker modules and their tests share one source of truth
---instead of repeating string literals.
M.picker = {
  normal = "AcpPickerNormal",
  border = "AcpPickerBorder",
  title = "AcpPickerTitle",
  selection = "AcpPickerSelection",
  item = "AcpPickerItem",
  match = "AcpPickerMatch",
  current = "AcpPickerCurrent",
  current_item = "AcpPickerCurrentItem",
  description = "AcpPickerDescription",
  meta = "AcpPickerMeta",
  empty = "AcpPickerEmpty",
  separator = "AcpPickerSeparator",
  prompt = "AcpPickerPrompt",
  footer = "AcpPickerFooter",
}

---`winhighlight` string that maps a picker float's chrome onto the
---`AcpPicker*` groups.
---
---`style = "minimal"` installs its own `Normal:NormalFloat,FloatBorder:...`
---mapping, so this must be assigned *after* the window is created.
---@return string
function M.picker_winhl()
  return table.concat({
    "Normal:" .. M.picker.normal,
    "NormalNC:" .. M.picker.normal,
    "FloatBorder:" .. M.picker.border,
    "FloatTitle:" .. M.picker.title,
  }, ",")
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
