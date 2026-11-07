return function(t)
  local acp = require("acp")
  local controller = require("acp.controller")
  local picker = require("acp.ui.picker")

  local root = vim.fn.fnamemodify(vim.fn.getcwd(), ":p")

  local function setup()
    acp.setup({
      agent = "opencode",
      agents = { opencode = { command = "python3", args = { root .. "tests/mock_agent.py" } } },
      ui = { session_picker = "internal" },
      permissions = { prompt = "native" },
    })
    controller.open()
    local S = controller.state()
    vim.wait(8000, function()
      return S.session ~= nil
    end, 20)
    return S
  end

  ---Run a prompt to completion.
  local function run_turn(S, text)
    controller.submit(text, {})
    vim.wait(15000, function()
      return S.session and S.session.status == "idle"
    end, 20)
  end

  ---Record the picker requests instead of rendering them.
  local function capture_picker()
    local calls = {}
    local original = picker.select
    picker.select = function(opts)
      calls[#calls + 1] = opts
    end
    return calls, function()
      picker.select = original
    end
  end

  t.describe("session titles", function()
    t.it("starts without a title", function()
      local S = setup()
      t.eq(nil, S.session.title)
      controller.hide()
    end)

    t.it("picks up the auto-generated title after a turn", function()
      local S = setup()
      run_turn(S, "hello")
      vim.wait(4000, function()
        return S.session.title ~= nil
      end, 20)
      t.eq("Mock titled session", S.session.title)
      controller.hide()
    end)

    t.it("shows the title in the transcript winbar", function()
      local S = setup()
      run_turn(S, "hello")
      vim.wait(4000, function()
        return S.session.title ~= nil
      end, 20)
      local bar = controller.chat_bar(S.chat.win)
      t.match("Mock titled session", bar)
      controller.hide()
    end)

    t.it("keeps the title within the window width", function()
      local S = setup()
      run_turn(S, "hello")
      vim.wait(4000, function()
        return S.session.title ~= nil
      end, 20)
      for _, width in ipairs({ 20, 30, 45 }) do
        vim.api.nvim_win_set_width(S.chat.win, width)
        local win_width = vim.api.nvim_win_get_width(S.chat.win)
        local bar = vim.api.nvim_get_option_value("winbar", { win = S.chat.win })
        local res = vim.api.nvim_eval_statusline(bar, {
          winid = S.chat.win,
          maxwidth = win_width,
          use_winbar = true,
        })
        t.truthy(res.width <= win_width, string.format("chat winbar overflows at %d", win_width))
        t.match("Mock", res.str)
      end
      controller.hide()
    end)
  end)

  t.describe("session delete", function()
    ---Open the session browser and return its window, buffer and picker handle.
    local function open_browser(S)
      controller.pick_session()
      local found
      vim.wait(6000, function()
        for _, win in ipairs(vim.api.nvim_list_wins()) do
          local buf = vim.api.nvim_win_get_buf(win)
          if vim.bo[buf].filetype == "acp_sessions" then
            found = { win = win, buf = buf }
            return true
          end
        end
        return false
      end, 20)
      return found
    end

    local function browser_lines(browser)
      return vim.api.nvim_buf_get_lines(browser.buf, 0, -1, false)
    end

    local function find_row(browser, needle)
      for i, line in ipairs(browser_lines(browser)) do
        if line:find(needle, 1, true) then
          return i
        end
      end
      return nil
    end

    t.it("lists sessions without a delete entry", function()
      local S = setup()
      local browser = open_browser(S)
      t.truthy(browser, "session browser did not open")
      t.eq("acp_sessions", vim.bo[browser.buf].filetype)
      local lines = browser_lines(browser)
      local joined = table.concat(lines, "\n")
      t.match("sess_old", joined .. "sess_old")
      for _, line in ipairs(lines) do
        t.falsy(line:lower():find("delete session", 1, true), "delete must not be a list entry")
      end
      pcall(vim.api.nvim_win_close, browser.win, true)
      controller.hide()
    end)

    t.it("marks the active session with a cursor icon", function()
      local S = setup()
      local browser = open_browser(S)
      t.truthy(browser)
      -- The active session starts with the arrow marker.
      local icons = require("acp.ui.icons").get(true)
      local marked = false
      for _, line in ipairs(browser_lines(browser)) do
        if vim.startswith(line, icons.arrow_right .. " ") or vim.startswith(line, "> ") then
          marked = true
        end
      end
      t.truthy(marked, "no active-session marker")
      pcall(vim.api.nvim_win_close, browser.win, true)
      controller.hide()
    end)

    t.it("filters sessions by typing", function()
      local S = setup()
      local browser = open_browser(S)
      t.truthy(browser)
      for _, ch in ipairs({ "O", "l", "d" }) do
        vim.api.nvim_feedkeys(ch, "x", false)
      end
      local joined = table.concat(browser_lines(browser), "\n")
      t.match("Old conversation", joined)
      t.falsy(joined:find("sess_mock", 1, true), "the other session should be filtered out")
      pcall(vim.api.nvim_win_close, browser.win, true)
      controller.hide()
    end)

    t.it("deletes a non-active session with <C-d>", function()
      local S = setup()
      local browser = open_browser(S)
      t.truthy(browser)

      local row = find_row(browser, "Old conversation")
      t.truthy(row, "target session not listed")
      vim.api.nvim_win_set_cursor(browser.win, { row, 0 })

      -- Confirm via the vim.ui.select dialog.
      local asked = false
      local original = vim.ui.select
      vim.ui.select = function(_, opts, cb)
        asked = true
        t.match("Old conversation", opts.prompt)
        cb("Delete")
      end
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<C-d>", true, false, true), "x", false)
      vim.wait(6000, function()
        return S.sessions["sess_old"] == nil
      end, 20)
      vim.ui.select = original

      t.truthy(asked, "no confirmation was shown")
      t.eq(nil, S.sessions["sess_old"])
      t.truthy(S.session and S.session.id == "sess_mock", "active session must survive")

      -- And the row disappears from the dialog once the callback lands.
      vim.wait(4000, function()
        return find_row(browser, "Old conversation") == nil
      end, 20)
      t.eq(nil, find_row(browser, "Old conversation"))
      pcall(vim.api.nvim_win_close, browser.win, true)
      controller.hide()
    end)

    t.it("does not delete when the confirmation is declined", function()
      local S = setup()
      local browser = open_browser(S)
      t.truthy(browser)
      local row = find_row(browser, "Old conversation")
      vim.api.nvim_win_set_cursor(browser.win, { row, 0 })

      local original = vim.ui.select
      vim.ui.select = function(_, _, cb)
        cb("Cancel")
      end
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<C-d>", true, false, true), "x", false)
      vim.wait(800)
      vim.ui.select = original

      t.truthy(find_row(browser, "Old conversation"), "session was deleted despite declining")
      pcall(vim.api.nvim_win_close, browser.win, true)
      controller.hide()
    end)

    t.it("reports when the agent cannot delete", function()
      local S = setup()
      -- Pretend the agent has no delete capability.
      S.client.has_session_capability = function(_, name)
        return name ~= "delete"
      end
      local browser = open_browser(S)
      t.truthy(browser)
      vim.api.nvim_win_set_cursor(browser.win, { 1, 0 })

      local prompted = false
      local original = vim.ui.select
      vim.ui.select = function()
        prompted = true
      end
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<C-d>", true, false, true), "x", false)
      vim.wait(500)
      vim.ui.select = original

      t.falsy(prompted, "should not offer a confirmation it cannot honour")
      local joined = table.concat(browser_lines(browser), "\n")
      t.match("cannot delete", joined)
      pcall(vim.api.nvim_win_close, browser.win, true)
      controller.hide()
    end)
  end)
end
