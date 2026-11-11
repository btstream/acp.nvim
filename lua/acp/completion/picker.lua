-- Explicit file selection complements the inline completion menu. Tools only
-- select a path; accepting inserts a mention, never opens a file or sends text.
local core = require("acp.completion")
local files = require("acp.completion.files")
local mentions = require("acp.completion.mentions")
local M = {}
local pending = {}

local function select_paths(paths, backend, accept)
  if backend == "vim" then
    vim.ui.select(paths, {
      prompt = "Insert @file",
      kind = "acp_file",
      format_item = function(path)
        return mentions.encode(path):sub(2)
      end,
    }, accept)
  elseif backend == "fzf-lua" then
    local values, labels = {}, {}
    for _, path in ipairs(paths) do
      local label = mentions.encode(path):sub(2)
      labels[#labels + 1], values[label] = label, path
    end
    require("fzf-lua").fzf_exec(labels, {
      prompt = "@file> ",
      actions = {
        ["default"] = function(selected)
          accept(selected and values[selected[1]])
        end,
      },
      fzf_opts = { ["--no-multi"] = true },
    })
  elseif backend == "snacks" then
    local items = {}
    for _, path in ipairs(paths) do
      items[#items + 1] = { text = mentions.encode(path):sub(2), path = path }
    end
    require("snacks").picker({
      title = "Insert @file",
      items = items,
      layout = { preset = "select" },
      format = function(item)
        return { { item.text } }
      end,
      confirm = function(picker, item)
        picker:close()
        accept(item and item.path)
      end,
    })
  elseif backend == "telescope" then
    local actions, state = require("telescope.actions"), require("telescope.actions.state")
    require("telescope.pickers")
      .new({}, {
        prompt_title = "Insert @file",
        finder = require("telescope.finders").new_table({
          results = paths,
          entry_maker = function(path)
            return { value = path, display = mentions.encode(path):sub(2), ordinal = path }
          end,
        }),
        sorter = require("telescope.config").values.generic_sorter({}),
        attach_mappings = function(prompt)
          actions.select_default:replace(function()
            local entry = state.get_selected_entry()
            actions.close(prompt)
            accept(entry and entry.value)
          end)
          return true
        end,
      })
      :find()
  else
    error("unknown file picker: " .. tostring(backend))
  end
end

function M.open(buf, win, opts)
  opts = opts or {}
  local binding = core.binding(buf)
  if not binding or not vim.api.nvim_win_is_valid(win) or vim.api.nvim_win_get_buf(win) ~= buf then
    return
  end
  if pending[buf] then
    pending[buf]()
  end
  local session, tick = binding.getter(), vim.api.nvim_buf_get_changedtick(buf)
  local cwd = core.cwd(binding, session)
  local cursor = vim.api.nvim_win_get_cursor(win)
  local row, col = cursor[1] - 1, cursor[2]
  local line = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or ""
  local query = core.context(line, col)
  if not query or query.kind ~= "file" then
    query = { first = col, last = col }
  end
  local cancelled, unsubscribe, cancel = false, nil, nil
  cancel = function()
    cancelled = true
    if unsubscribe then
      unsubscribe()
    end
    if pending[buf] == cancel then
      pending[buf] = nil
    end
    binding.requests[cancel] = nil
  end
  pending[buf], binding.requests[cancel] = cancel, "picker"
  local function fresh()
    local current = binding.getter()
    return not cancelled
      and core.binding(buf) == binding
      and core.available(buf)
      and vim.api.nvim_buf_is_valid(buf)
      and vim.api.nvim_win_is_valid(win)
      and vim.api.nvim_win_get_buf(win) == buf
      and vim.api.nvim_win_get_cursor(win)[1] == cursor[1]
      and vim.api.nvim_win_get_cursor(win)[2] == cursor[2]
      and vim.api.nvim_buf_get_changedtick(buf) == tick
      and current == session
      and core.cwd(binding, current) == cwd
  end
  local function accept(path)
    vim.schedule(function()
      if type(path) ~= "string" or path == "" or not fresh() then
        cancel()
        return
      end
      local before, after = line:sub(query.first, query.first), line:sub(query.last + 1, query.last + 1)
      local prefix = query.first > 0 and not before:match("[%s%(%[{]") and " " or ""
      local suffix = after == "" or not after:match("%s")
      local inserted = prefix .. mentions.encode(path) .. (suffix and " " or "")
      vim.api.nvim_buf_set_text(buf, row, query.first, row, query.last, { inserted })
      vim.api.nvim_set_current_win(win)
      vim.api.nvim_win_set_cursor(win, { row + 1, query.first + #inserted })
      vim.cmd("startinsert")
      cancel()
    end)
  end
  unsubscribe = files.list(cwd, binding.config.completion.files, function(paths, err, root)
    if not fresh() then
      cancel()
      return
    end
    if err then
      cancel()
      vim.notify("acp.nvim: " .. err, vim.log.levels.WARN)
      return
    end
    -- Once discovery is done the picker owns its own paths, not a reference to
    -- the cache entry (which may subsequently be evicted by another project).
    if unsubscribe then
      unsubscribe()
      unsubscribe = nil
    end
    local relative, index = {}, 1
    local function build()
      if not fresh() then
        cancel()
        return
      end
      for _ = 1, 256 do
        local path = paths[index]
        if not path then
          local ok, problem = pcall(function()
            if opts.select then
              opts.select(relative, accept)
            else
              select_paths(relative, opts.backend or binding.config.completion.picker, accept)
            end
          end)
          if not ok then
            cancel()
            vim.notify("acp.nvim: file picker failed: " .. tostring(problem), vim.log.levels.WARN)
          end
          return
        end
        relative[#relative + 1] = root == cwd and path or files.relative(root .. "/" .. path, cwd)
        index = index + 1
      end
      vim.schedule(build)
    end
    build()
  end)
  return cancel
end

return M
