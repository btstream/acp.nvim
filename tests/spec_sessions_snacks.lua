return function(t)
  local acp = require("acp")
  local controller = require("acp.controller")
  local session_snacks = require("acp.ui.session_snacks")

  local root = vim.fn.fnamemodify(vim.fn.getcwd(), ":p")

  ---Locate snacks.nvim on the runtimepath, if present.
  local function find_snacks()
    for _, dir in ipairs(vim.api.nvim_list_runtime_paths()) do
      if vim.fn.isdirectory(dir .. "/lua/snacks") == 1 then
        return true
      end
    end
    return false
  end

  local has_snacks = find_snacks()

  local function setup(over)
    acp.setup(vim.tbl_deep_extend("force", {
      agent = "opencode",
      agents = { opencode = { command = "python3", args = { root .. "tests/mock_agent.py" } } },
      ui = {},
      permissions = { prompt = "native" },
    }, over or {}))
    controller.open()
    local S = controller.state()
    vim.wait(8000, function()
      return S.sess.current ~= nil
    end, 20)
    return S
  end

  ---The most recently opened snacks picker.
  local function current_snacks_picker()
    local ok, snacks_picker = pcall(require, "snacks.picker")
    if not ok then
      return nil
    end
    local pickers = snacks_picker.get()
    return pickers[#pickers]
  end

  ---Open the session browser and wait for whichever backend appears.
  local function open_browser(S)
    controller.pick_session()
    vim.wait(4000, function()
      if current_snacks_picker() then
        return true
      end
      for _, win in ipairs(vim.api.nvim_list_wins()) do
        if vim.bo[vim.api.nvim_win_get_buf(win)].filetype == "acp_sessions" then
          return true
        end
      end
      return false
    end, 20)
    return current_snacks_picker()
  end

  t.describe("session snacks backend", function()
    t.it("reports availability honestly", function()
      t.eq(has_snacks, session_snacks.available())
    end)

    if not has_snacks then
      t.it("falls back to the built-in window when snacks is missing", function()
        local S = setup()
        local picker = open_browser(S)
        t.falsy(picker, "snacks picker used although snacks is unavailable")
        local found = false
        for _, win in ipairs(vim.api.nvim_list_wins()) do
          if vim.bo[vim.api.nvim_win_get_buf(win)].filetype == "acp_sessions" then
            found = true
            pcall(vim.api.nvim_win_close, win, true)
          end
        end
        t.truthy(found, "no fallback window was shown")
        controller.hide()
      end)
      return
    end

    t.it("uses snacks for the session browser by default", function()
      local S = setup()
      local picker = open_browser(S)
      t.truthy(picker, "snacks picker was not used")
      t.eq(" Sessions ", picker.opts.title)
      picker:close()
      controller.hide()
    end)

    t.it("lists every session", function()
      local S = setup()
      local picker = open_browser(S)
      t.truthy(picker)
      local ids = {}
      for _, item in ipairs(picker:items()) do
        ids[item.session.sessionId] = true
      end
      t.truthy(ids["sess_mock"], "active session missing")
      t.truthy(ids["sess_old"], "stored session missing")
      picker:close()
      controller.hide()
    end)

    t.it("marks the active session in the row", function()
      local S = setup()
      local picker = open_browser(S)
      t.truthy(picker)
      local icons = require("acp.ui.icons").get(true)
      local found
      for _, item in ipairs(picker:items()) do
        if item.session.sessionId == S.sess.current.id then
          found = item
        end
      end
      t.truthy(found, "active session item missing")
      -- The formatter depends on current_id, so drive it directly.
      local row = picker.opts.format(found, picker)
      t.eq(icons.arrow_right .. " ", row[1][1])
      t.eq("AcpPickerCurrent", row[1][2])
      picker:close()
      controller.hide()
    end)

    t.it("leaves non-active rows unmarked", function()
      local S = setup()
      local picker = open_browser(S)
      t.truthy(picker)
      local other
      for _, item in ipairs(picker:items()) do
        if item.session.sessionId ~= S.sess.current.id then
          other = item
        end
      end
      t.truthy(other)
      local row = picker.opts.format(other, picker)
      t.eq("  ", row[1][1])
      picker:close()
      controller.hide()
    end)

    t.it("provides a preview with the session id", function()
      local S = setup()
      local picker = open_browser(S)
      t.truthy(picker)
      local item = picker:items()[1]
      t.truthy(item.preview, "no preview attached")
      t.match(item.session.sessionId, item.preview.text)
      t.eq("markdown", item.preview.ft)
      t.eq(false, item.preview.loc)
      picker:close()
      controller.hide()
    end)

    t.it("binds <C-d> for deletion", function()
      local S = setup()
      local picker = open_browser(S)
      t.truthy(picker)
      -- snacks normalizes key notation, so accept either casing.
      local function has_ctrl_d(keys)
        return (keys["<C-d>"] or keys["<C-D>"]) ~= nil
      end
      t.truthy(has_ctrl_d(picker.opts.win.input.keys), "no <C-d> in the input window")
      t.truthy(has_ctrl_d(picker.opts.win.list.keys), "no <C-d> in the list window")
      picker:close()
      controller.hide()
    end)

    t.it("deletes a session and refreshes the list", function()
      local S = setup()
      local picker = open_browser(S)
      t.truthy(picker)

      -- Select the row to delete.
      local target_idx
      for i, item in ipairs(picker:items()) do
        if item.session.sessionId == "sess_old" then
          target_idx = i
        end
      end
      t.truthy(target_idx, "sess_old not listed")
      picker.list:set_target(target_idx, nil, { force = true })
      picker:refresh()
      vim.wait(500)

      local original = vim.ui.select
      local prompt
      vim.ui.select = function(_, opts, cb)
        prompt = opts.prompt
        cb("Delete")
      end
      picker:action("acp_delete", picker:current())
      vim.wait(6000, function()
        return S.sess.all["sess_old"] == nil
      end, 20)
      vim.ui.select = original

      t.match("Old conversation", prompt)
      t.eq(nil, S.sess.all["sess_old"])
      t.truthy(S.sess.current and S.sess.current.id == "sess_mock", "active session was affected")

      -- The picker stays open and drops the row.
      vim.wait(3000, function()
        return #picker:items() == 1
      end, 20)
      t.eq(1, #picker:items())
      t.falsy(picker.closed, "picker closed after deleting")
      picker:close()
      controller.hide()
    end)

    t.it("does not delete when the confirmation is declined", function()
      local S = setup()
      local picker = open_browser(S)
      t.truthy(picker)
      local original = vim.ui.select
      vim.ui.select = function(_, _, cb)
        cb("Cancel")
      end
      picker:action("acp_delete", picker:items()[1])
      vim.wait(1000)
      vim.ui.select = original
      t.eq(2, #picker:items(), "list changed although deletion was declined")
      picker:close()
      controller.hide()
    end)

    t.it("refuses to delete when the agent cannot", function()
      local S = setup()
      S.conn.client.has_session_capability = function(_, name)
        return name ~= "delete"
      end
      local picker = open_browser(S)
      t.truthy(picker)
      local prompted = false
      local original = vim.ui.select
      vim.ui.select = function()
        prompted = true
      end
      picker:action("acp_delete", picker:items()[1])
      vim.wait(500)
      vim.ui.select = original
      t.falsy(prompted, "offered a confirmation it cannot honour")
      picker:close()
      controller.hide()
    end)

    t.it("honours ui.session_picker = internal", function()
      local S = setup({ ui = { session_picker = "internal" } })
      local picker = open_browser(S)
      t.falsy(picker, "snacks was used although internal was requested")
      local found = false
      for _, win in ipairs(vim.api.nvim_list_wins()) do
        if vim.bo[vim.api.nvim_win_get_buf(win)].filetype == "acp_sessions" then
          found = true
          pcall(vim.api.nvim_win_close, win, true)
        end
      end
      t.truthy(found, "fallback window was not shown")
      controller.hide()
    end)

    t.it("opens the selected session on confirm", function()
      local S = setup()
      local picker = open_browser(S)
      t.truthy(picker)
      local target_idx
      for i, item in ipairs(picker:items()) do
        if item.session.sessionId == "sess_old" then
          target_idx = i
        end
      end
      t.truthy(target_idx)
      picker.list:set_target(target_idx, nil, { force = true })
      picker:refresh()
      vim.wait(500)
      picker:action("acp_open", picker:current())
      vim.wait(8000, function()
        return S.sess.current and S.sess.current.id == "sess_old"
      end, 20)
      t.eq("sess_old", S.sess.current.id)
      -- Loading replays history asynchronously; the title is applied after.
      vim.wait(6000, function()
        return S.sess.current.title ~= nil
      end, 20)
      t.eq("Old conversation", S.sess.current.title)
      controller.hide()
    end)
  end)
end
