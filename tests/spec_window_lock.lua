return function(t)
  local acp = require("acp")
  local controller = require("acp.controller")
  local layout = require("acp.layout")

  local root = vim.fn.fnamemodify(vim.fn.getcwd(), ":p")

  local function setup(over)
    acp.setup(vim.tbl_deep_extend("force", {
      agent = "opencode",
      agents = { opencode = { command = "python3", args = { root .. "tests/mock_agent.py" } } },
      ui = {},
      permissions = { prompt = "native" },
      layout = { input_height = 5 },
    }, over or {}))
    controller.open()
    return controller.state()
  end

  t.describe("window lock", function()
    t.it("locks both panel windows", function()
      local S = setup()
      t.truthy(vim.api.nvim_get_option_value("winfixbuf", { win = S.view.chat.win }), "chat window not locked")
      t.truthy(vim.api.nvim_get_option_value("winfixbuf", { win = S.view.input.win }), "composer not locked")
      controller.hide()
    end)

    t.it("blocks :edit from replacing the transcript", function()
      local S = setup()
      vim.api.nvim_set_current_win(S.view.chat.win)
      local before = vim.api.nvim_win_get_buf(S.view.chat.win)
      local ok = pcall(vim.cmd, "edit /tmp/acp_lock_probe.txt")
      t.falsy(ok, ":edit should have been rejected")
      t.eq(before, vim.api.nvim_win_get_buf(S.view.chat.win), "transcript buffer was replaced")
      controller.hide()
    end)

    t.it("blocks :edit from replacing the composer", function()
      local S = setup()
      vim.api.nvim_set_current_win(S.view.input.win)
      local before = vim.api.nvim_win_get_buf(S.view.input.win)
      local ok = pcall(vim.cmd, "edit /tmp/acp_lock_probe.txt")
      t.falsy(ok, ":edit should have been rejected")
      t.eq(before, vim.api.nvim_win_get_buf(S.view.input.win), "composer buffer was replaced")
      controller.hide()
    end)

    t.it("blocks :bnext style buffer switching", function()
      local S = setup()
      vim.api.nvim_set_current_win(S.view.chat.win)
      local other = vim.api.nvim_create_buf(true, false)
      local ok = pcall(vim.api.nvim_win_set_buf, S.view.chat.win, other)
      t.falsy(ok, "nvim_win_set_buf should have been rejected")
      t.eq("acp_chat", vim.bo[vim.api.nvim_win_get_buf(S.view.chat.win)].filetype)
      controller.hide()
    end)

    t.it("still allows closing the window", function()
      local S = setup()
      local win = S.view.chat.win
      local ok = pcall(vim.api.nvim_win_close, win, true)
      t.truthy(ok, "a locked window must still be closable")
      controller.hide()
    end)

    t.it("turns a split of an ACP window into a usable window", function()
      local S = setup()
      vim.api.nvim_set_current_win(S.view.chat.win)
      vim.cmd("split")
      local new = vim.api.nvim_get_current_win()
      t.truthy(new ~= S.view.chat.win, "expected a new window")
      -- The new window must not become a locked duplicate of the transcript.
      t.falsy(vim.api.nvim_get_option_value("winfixbuf", { win = new }), "derived window is locked")
      t.falsy(layout.is_panel_buffer(vim.api.nvim_win_get_buf(new)), "derived window still shows the transcript")
      local ok = pcall(vim.cmd, "edit /tmp/acp_lock_probe.txt")
      t.truthy(ok, "derived window rejected :edit")
      pcall(vim.api.nvim_win_close, new, true)
      controller.hide()
    end)

    t.it("keeps the panel window locked after splitting", function()
      local S = setup()
      local original = S.view.chat.win
      vim.api.nvim_set_current_win(original)
      vim.cmd("split")
      t.truthy(vim.api.nvim_get_option_value("winfixbuf", { win = original }), "panel window lost its lock")
      t.eq("acp_chat", vim.bo[vim.api.nvim_win_get_buf(original)].filetype)
      pcall(vim.api.nvim_win_close, vim.api.nvim_get_current_win(), true)
      controller.hide()
    end)

    t.it("lets acp.nvim set its own buffer while locked", function()
      local S = setup()
      t.falsy(layout.set_window_buffer(S.view.chat.win, S.view.chat.buf) == false, "internal buffer set failed")
      -- The lock is restored afterwards.
      t.truthy(vim.api.nvim_get_option_value("winfixbuf", { win = S.view.chat.win }))
      controller.hide()
    end)

    t.it("can be disabled by configuration", function()
      local S = setup({ layout = { lock_buffer = false } })
      t.falsy(vim.api.nvim_get_option_value("winfixbuf", { win = S.view.chat.win }), "lock should be disabled")
      controller.hide()
    end)
  end)
end
