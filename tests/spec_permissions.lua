return function(t)
  local controller = require("acp.controller")
  local config = require("acp.config")
  local state = require("acp.session.state")
  local picker = require("acp.ui.picker")

  t.describe("permissions", function()
    t.it("resolves with an explicit reject option when dismissed", function()
      controller.setup({ ui = { language = "en" }, permissions = { prompt = "native" } })
      local S = controller.state()
      local resolved
      S.client = {
        resolve_permission = function(_, key, option)
          resolved = { key = key, option = option }
        end,
      }
      S.pending_permissions.perm1 = {
        session_id = "s1",
        tool_call = { title = "Write file" },
        options = {
          { optionId = "a", name = "Allow", kind = "allow_once" },
          { optionId = "r", name = "Reject", kind = "reject_once" },
        },
      }
      controller.resolve_permission("perm1", nil, true)
      t.truthy(resolved)
      t.eq("r", resolved.option)
      t.falsy(S.pending_permissions.perm1)
      S.client = nil
    end)

    t.it("resolves with the cancelled outcome when no reject exists", function()
      controller.setup({ ui = { language = "en" }, permissions = { prompt = "native" } })
      local S = controller.state()
      local resolved
      S.client = {
        resolve_permission = function(_, key, option)
          resolved = { key = key, option = option }
        end,
      }
      S.pending_permissions.perm2 = {
        session_id = "s1",
        options = { { optionId = "a", name = "Allow", kind = "allow_once" } },
      }
      controller.resolve_permission("perm2", nil, true)
      t.truthy(resolved)
      t.eq(nil, resolved.option)
      S.client = nil
    end)

    t.it("reports waiting_permission in the status payload", function()
      controller.setup({ ui = { language = "en" }, permissions = { prompt = "native" } })
      local S = controller.state()
      local session = state.new("s1", "/tmp")
      S.session = session
      S.pending_permissions.perm3 = { session_id = "s1", options = {} }
      local st = controller.status()
      t.truthy(st.waiting_permission)
      S.pending_permissions = {}
      t.falsy(controller.status().waiting_permission)
    end)

    t.it("renders a compact statusline component", function()
      controller.setup({ ui = { language = "en" }, permissions = { prompt = "native" } })
      local S = controller.state()
      S.connection = "ready"
      S.session = nil
      t.eq("◆", controller.statusline())
      local session = state.new("s1", "/tmp")
      session.status = "running"
      S.session = session
      t.eq("◆ ◌", controller.statusline())
    end)
  end)

  t.describe("picker", function()
    t.it("invokes on_cancel when dismissed", function()
      local cancelled = false
      picker.select({
        title = "test",
        items = { { label = "one", value = 1 } },
        on_choice = function() end,
        on_cancel = function()
          cancelled = true
        end,
      })
      local win = vim.api.nvim_get_current_win()
      -- Focus moves away, which must count as a cancellation.
      vim.api.nvim_win_close(win, true)
      vim.wait(100, function()
        return cancelled
      end, 10)
      t.truthy(cancelled)
    end)

    t.it("invokes on_choice on selection", function()
      local chosen
      picker.select({
        title = "test",
        items = { { label = "one", value = 1 }, { label = "two", value = 2 } },
        on_choice = function(value)
          chosen = value
        end,
      })
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "x", false)
      vim.wait(100, function()
        return chosen ~= nil
      end, 10)
      t.eq(1, chosen)
    end)
  end)
end
