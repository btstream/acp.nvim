-- Session browser built on snacks.nvim's picker.
--
-- snacks gives us fuzzy matching (fzf syntax), a live preview pane and the
-- user's existing picker theme for free, so this module only supplies the
-- data, the row layout and the two ACP-specific actions.
--
-- snacks is optional: `open()` returns false when it is unavailable and the
-- caller falls back to the built-in window.
local Icons = require("acp.ui.icons")
local highlights = require("acp.ui.highlights")

-- Only the rows are ours to colour: snacks owns the window chrome, so the
-- `AcpPickerNormal`/`Border`/`Title` groups of the built-in pickers do not
-- apply here and the user's snacks theme keeps working.
local HL = highlights.picker

local M = {}

---@class AcpSnacksSessionOpts
---@field sessions table[] entries from session/list
---@field current_id string|nil
---@field can_delete boolean
---@field use_icons boolean|nil
---@field on_open fun(session_id: string)
---@field on_delete fun(session_id: string, done: fun(ok: boolean))

---Load snacks, returning nil when it is not installed or not configured.
---@return table|nil
local function load_snacks()
  local ok, snacks = pcall(require, "snacks")
  if not ok or type(snacks) ~= "table" then
    return nil
  end
  -- The picker module must be available too; a `snacks.nvim` install with
  -- `picker = { enabled = false }` should not be treated as usable.
  local picker_ok, picker = pcall(require, "snacks.picker")
  if not picker_ok or type(picker) ~= "table" then
    return nil
  end
  return snacks
end

---Whether the snacks backend can be used right now.
---@return boolean
function M.available()
  return load_snacks() ~= nil
end

---Format an ISO timestamp as "YYYY-MM-DD HH:MM".
---@param value any
---@return string
local function short_time(value)
  if type(value) ~= "string" or value == "" then
    return ""
  end
  local date, time = value:match("^(%d%d%d%d%-%d%d%-%d%d)T(%d%d:%d%d)")
  if date and time then
    return date .. " " .. time
  end
  return value:sub(1, 16)
end

---A session's display label: its title, or the id when no title exists yet.
---@param session table
---@return string
local function label_of(session)
  if type(session.title) == "string" and session.title ~= "" then
    return session.title
  end
  return session.sessionId
end

---Preview text shown to the right of the list.
---@param session table
---@return string
local function render_preview(session)
  local lines = {
    "# " .. label_of(session),
    "",
    "- **ID**: `" .. tostring(session.sessionId) .. "`",
  }
  if type(session.cwd) == "string" and session.cwd ~= "" then
    lines[#lines + 1] = "- **Directory**: `" .. session.cwd .. "`"
  end
  local updated = short_time(session.updatedAt)
  if updated ~= "" then
    lines[#lines + 1] = "- **Updated**: " .. updated
  end
  local created = short_time(session.createdAt)
  if created ~= "" then
    lines[#lines + 1] = "- **Created**: " .. created
  end
  return table.concat(lines, "\n")
end

---Open the snacks session browser.
---@param opts AcpSnacksSessionOpts
---@return boolean opened false when snacks is unavailable
function M.open(opts)
  local Snacks = load_snacks()
  if not Snacks then
    return false
  end

  local icons = Icons.get(opts.use_icons)
  -- Local, mutable snapshot: the finder rebuilds from it on every refresh.
  local sessions = vim.deepcopy(opts.sessions or {})

  local picker
  picker = Snacks.picker({
    title = " Sessions ",
    layout = { preset = "select" },
    preview = "preview",
    show_empty = true,
    format = function(item)
      local session = item.session
      local current = session.sessionId == opts.current_id
      local marker = current and (icons.arrow_right .. " ") or "  "
      local text = label_of(session)
      local when_text = short_time(session.updatedAt or session.createdAt)

      local ret = {
        { marker, current and HL.current or HL.description },
        { text, current and HL.current_item or HL.item },
      }
      if when_text ~= "" then
        ret[#ret + 1] = {
          when_text,
          HL.meta,
          virt_text = true,
          virt_text_pos = "right_align",
        }
      end
      return ret
    end,
    finder = function()
      local items = {}
      for _, session in ipairs(sessions) do
        items[#items + 1] = {
          text = label_of(session) .. " " .. tostring(session.sessionId),
          session = session,
          preview = {
            text = render_preview(session),
            ft = "markdown",
            loc = false,
          },
        }
      end
      return items
    end,
    actions = {
      ---Switch to the selected session.
      acp_open = function(p, item)
        if not item then
          return
        end
        p:close()
        vim.schedule(function()
          opts.on_open(item.session.sessionId)
        end)
      end,

      ---Delete the selected session, keeping the picker open.
      acp_delete = function(p, item)
        if not item then
          return
        end
        if not opts.can_delete then
          vim.notify("acp.nvim: this agent cannot delete sessions", vim.log.levels.WARN)
          return
        end
        local target_id = item.session.sessionId
        local target_label = label_of(item.session)

        vim.ui.select({ "Delete", "Cancel" }, {
          prompt = string.format('Delete "%s"?', target_label),
          kind = "acp_confirm_delete",
        }, function(choice)
          vim.schedule(function()
            if choice ~= "Delete" or p.closed then
              return
            end
            opts.on_delete(target_id, function(ok)
              if not ok or p.closed then
                return
              end
              local kept = {}
              for _, session in ipairs(sessions) do
                if session.sessionId ~= target_id then
                  kept[#kept + 1] = session
                end
              end
              sessions = kept
              p:refresh()
            end)
          end)
        end)
      end,
    },
    confirm = "acp_open",
    win = {
      input = {
        keys = {
          ["<C-d>"] = { "acp_delete", mode = { "n", "i" }, desc = "Delete session" },
        },
      },
      list = {
        keys = {
          ["<C-d>"] = { "acp_delete", desc = "Delete session" },
        },
      },
    },
  })

  return picker ~= nil
end

return M
