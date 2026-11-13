return function(t)
  local controller = require("acp.controller")
  local config = require("acp.config")
  local state = require("acp.session.state")
  local picker = require("acp.ui.picker")

  local function with_ui_select(stub, fn)
    local original = vim.ui.select
    vim.ui.select = stub
    local ok, err = pcall(fn)
    vim.ui.select = original
    if not ok then
      error(err, 0)
    end
  end

  t.describe("permissions", function()
    t.it("resolves with an explicit reject option when dismissed", function()
      controller.setup({ ui = {}, permissions = { prompt = "native" } })
      local S = controller.state()
      local resolved
      S.interactions:open("permission", {
        sessionId = "s1",
        toolCall = { title = "Write file" },
        options = {
          { optionId = "a", name = "Allow", kind = "allow_once" },
          { optionId = "r", name = "Reject", kind = "reject_once" },
        },
      }, function(response)
        resolved = response
      end, 1, "perm1")
      controller.resolve_permission("perm1", nil, true)
      t.truthy(resolved)
      t.eq("r", resolved.outcome.optionId)
      t.eq("answered", S.interactions:get("perm1").state)
    end)

    t.it("resolves with the cancelled outcome when no reject exists", function()
      controller.setup({ ui = {}, permissions = { prompt = "native" } })
      local S = controller.state()
      local resolved
      S.interactions:open("permission", {
        sessionId = "s1",
        options = { { optionId = "a", name = "Allow", kind = "allow_once" } },
      }, function(response)
        resolved = response
      end, 1, "perm2")
      controller.resolve_permission("perm2", nil, true)
      t.truthy(resolved)
      t.eq("cancelled", resolved.outcome.outcome)
      t.eq("cancelled", S.interactions:get("perm2").state)
    end)

    t.it("reports waiting_permission in the status payload", function()
      controller.setup({ ui = {}, permissions = { prompt = "native" } })
      local S = controller.state()
      local session = state.new("s1", "/tmp")
      S.session = session
      S.interactions:open("permission", { sessionId = "s1", options = {} }, function() end, 1, "perm3")
      local st = controller.status()
      t.truthy(st.waiting_permission)
      S.interactions:cancel("perm3")
      t.falsy(controller.status().waiting_permission)
    end)

    t.it("expires the picker when the agent withdraws the request", function()
      controller.setup({ ui = {}, permissions = { prompt = "select" } })
      local S = controller.state()
      local picker = require("acp.ui.picker")
      local original = picker.select
      local choices = {}
      picker.select = function(opts)
        choices[#choices + 1] = opts
      end
      local ok, err = pcall(function()
        S.interactions:open(
          "permission",
          { sessionId = "s1", options = { { optionId = "a", name = "Allow", kind = "allow_once" } } },
          function() end,
          9,
          "perm9"
        )
        t.eq(1, #choices)
        S.interactions:on_remote_cancel(9)
        t.eq("expired", S.interactions:get("perm9").state)
        t.eq(0, #S.interactions:pending())
        t.falsy(controller.status().waiting_permission)
      end)
      picker.select = original
      if not ok then
        error(err, 0)
      end
    end)

    t.it("renders a compact statusline component", function()
      controller.setup({ ui = {}, permissions = { prompt = "native" } })
      local S = controller.state()
      S.connection = "ready"
      S.session = nil
      local ic = require("acp.ui.icons").get(true)
      t.eq(ic.assistant, controller.statusline())
      local session = state.new("s1", "/tmp")
      session.status = "running"
      S.session = session
      t.eq(ic.assistant .. " " .. ic.tool_run, controller.statusline())
    end)
  end)

  t.describe("picker", function()
    t.it("uses vim.ui.select by default", function()
      controller.setup({ ui = {} })
      local called = nil
      with_ui_select(function(items, opts, cb)
        called = { count = #items, prompt = opts.prompt, kind = opts.kind }
        cb(items[2])
      end, function()
        local chosen
        picker.select({
          title = "Pick",
          items = { { label = "one", value = 1 }, { label = "two", value = 2 } },
          on_choice = function(value)
            chosen = value
          end,
        })
        t.eq(2, chosen)
      end)
      t.truthy(called)
      t.eq(2, called.count)
      t.eq("Pick", called.prompt)
      t.eq("acp_select", called.kind)
    end)

    t.it("treats a nil choice as cancellation", function()
      controller.setup({ ui = {} })
      local cancelled = false
      with_ui_select(function(items, _, cb)
        cb(items[1])
        cb(nil) -- a second callback must be ignored
        cb(nil)
      end, function()
        picker.select({
          title = "Pick",
          items = { { label = "one", value = 1 } },
          on_choice = function() end,
          on_cancel = function()
            cancelled = true
          end,
        })
      end)
      t.falsy(cancelled, "the first choice should win")
    end)

    t.it("calls on_cancel when the prompt is dismissed", function()
      controller.setup({ ui = {} })
      local cancelled = false
      with_ui_select(function(_, _, cb)
        cb(nil)
      end, function()
        picker.select({
          title = "Pick",
          items = { { label = "one", value = 1 } },
          on_choice = function() end,
          on_cancel = function()
            cancelled = true
          end,
        })
      end)
      t.truthy(cancelled)
    end)

    t.it("formats items with their description", function()
      local formatted = picker._format_item({ label = "Claude Sonnet 5", description = "balanced" }, 40)
      t.match("Claude Sonnet 5", formatted)
      t.match("balanced", formatted)
    end)

    t.it("truncates long descriptions", function()
      local formatted = picker._format_item({
        label = "m",
        description = string.rep("x", 100),
      }, 20)
      t.truthy(vim.fn.strdisplaywidth(formatted) <= 40, "description was not truncated")
    end)

    t.it("still supports the built-in picker when opted in", function()
      controller.setup({ ui = { picker = "internal" } })
      local chosen
      local invoked = false
      with_ui_select(function()
        invoked = true
      end, function()
        picker.select({
          title = "Pick",
          items = { { label = "one", value = 1 }, { label = "two", value = 2 } },
          on_choice = function(value)
            chosen = value
          end,
        })
      end)
      t.falsy(invoked, "vim.ui.select must not be used in internal mode")
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "x", false)
      vim.wait(200, function()
        return chosen ~= nil
      end, 10)
      t.eq(1, chosen)
    end)
  end)
end
