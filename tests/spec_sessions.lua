return function(t)
  local acp = require("acp")
  local controller = require("acp.controller")
  local picker = require("acp.ui.picker")

  local root = vim.fn.fnamemodify(vim.fn.getcwd(), ":p")

  local function setup()
    acp.setup({
      agent = "opencode",
      agents = { opencode = { command = "python3", args = { root .. "tests/mock_agent.py" } } },
      ui = { language = "en" },
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
    t.it("lists plus a delete entry", function()
      local S = setup()
      local calls, restore = capture_picker()
      controller.pick_session()
      vim.wait(5000, function()
        return #calls > 0
      end, 20)
      restore()
      local opts = calls[1]
      t.truthy(opts, "picker was not shown")
      local has_delete = false
      for _, item in ipairs(opts.items) do
        if item.value and item.value.kind == "delete_menu" then
          has_delete = true
        end
      end
      t.truthy(has_delete, "no delete entry in the session list")
      controller.hide()
    end)

    t.it("marks the active session", function()
      local S = setup()
      local calls, restore = capture_picker()
      controller.pick_session()
      vim.wait(5000, function()
        return #calls > 0
      end, 20)
      restore()
      local marked = false
      for _, item in ipairs(calls[1].items) do
        if item.value and item.value.session_id == S.session.id and (item.description or ""):match("current") then
          marked = true
        end
      end
      t.truthy(marked, "active session was not marked")
      controller.hide()
    end)

    t.it("deletes a non-active session", function()
      local S = setup()
      local calls, restore = capture_picker()
      controller.delete_session_flow()
      vim.wait(5000, function()
        return #calls > 0
      end, 20)
      t.truthy(calls[1], "delete flow did not ask for a session")
      -- Choose the non-active session.
      local target
      for _, item in ipairs(calls[1].items) do
        if item.value == "sess_old" then
          target = item.value
        end
      end
      t.truthy(target, "sess_old not listed")
      calls[1].on_choice(target)
      -- Confirmation dialog.
      t.truthy(calls[2], "no confirmation dialog")
      t.match("sess_old", calls[2].title)
      calls[2].on_choice(true)
      restore()

      vim.wait(6000, function()
        local ok, result = pcall(function()
          return S.sessions["sess_old"] == nil
        end)
        return ok and result
      end, 20)
      t.eq(nil, S.sessions["sess_old"])
      -- The active session must survive.
      t.truthy(S.session and S.session.id == "sess_mock")
      controller.hide()
    end)

    t.it("starts a fresh session when the active one is deleted", function()
      local S = setup()
      local calls, restore = capture_picker()
      controller.delete_session_flow()
      vim.wait(5000, function()
        return #calls > 0
      end, 20)
      local active_id = S.session.id
      calls[1].on_choice(active_id)
      t.truthy(calls[2], "no confirmation dialog")
      t.match("active", calls[2].title)
      calls[2].on_choice(true)
      restore()

      -- A replacement session is created.
      vim.wait(8000, function()
        return S.session ~= nil
      end, 20)
      t.truthy(S.session, "no session after deleting the active one")
      controller.hide()
    end)

    t.it("does nothing when the confirmation is declined", function()
      local S = setup()
      local calls, restore = capture_picker()
      controller.delete_session_flow()
      vim.wait(5000, function()
        return #calls > 0
      end, 20)
      calls[1].on_choice("sess_old")
      calls[2].on_choice(false)
      restore()
      vim.wait(300)
      -- The session is still there as far as acp.nvim is concerned.
      local still_listed = false
      local calls2, restore2 = capture_picker()
      controller.pick_session()
      vim.wait(4000, function()
        return #calls2 > 0
      end, 20)
      restore2()
      for _, item in ipairs(calls2[1].items) do
        if item.value and item.value.session_id == "sess_old" then
          still_listed = true
        end
      end
      t.truthy(still_listed, "session was deleted without confirmation")
      controller.hide()
    end)
  end)
end
