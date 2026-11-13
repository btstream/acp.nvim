return function(t)
  local controller = require("acp.controller")
  local config = require("acp.config")
  local state = require("acp.session.state")
  local picker = require("acp.ui.picker")
  local permissions = require("acp.app.permissions")

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
      S.view.interactions:open("permission", {
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
      t.eq("answered", S.view.interactions:get("perm1").state)
    end)

    t.it("resolves with the cancelled outcome when no reject exists", function()
      controller.setup({ ui = {}, permissions = { prompt = "native" } })
      local S = controller.state()
      local resolved
      S.view.interactions:open("permission", {
        sessionId = "s1",
        options = { { optionId = "a", name = "Allow", kind = "allow_once" } },
      }, function(response)
        resolved = response
      end, 1, "perm2")
      controller.resolve_permission("perm2", nil, true)
      t.truthy(resolved)
      t.eq("cancelled", resolved.outcome.outcome)
      t.eq("cancelled", S.view.interactions:get("perm2").state)
    end)

    t.it("reports waiting_permission in the status payload", function()
      controller.setup({ ui = {}, permissions = { prompt = "native" } })
      local S = controller.state()
      local session = state.new("s1", "/tmp")
      S.sess.current = session
      S.view.interactions:open("permission", { sessionId = "s1", options = {} }, function() end, 1, "perm3")
      local st = controller.status()
      t.truthy(st.waiting_permission)
      S.view.interactions:cancel("perm3")
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
        S.view.interactions:open(
          "permission",
          { sessionId = "s1", options = { { optionId = "a", name = "Allow", kind = "allow_once" } } },
          function() end,
          9,
          "perm9"
        )
        t.eq(1, #choices)
        S.view.interactions:on_remote_cancel(9)
        t.eq("expired", S.view.interactions:get("perm9").state)
        t.eq(0, #S.view.interactions:pending())
        t.falsy(controller.status().waiting_permission)
      end)
      picker.select = original
      if not ok then
        error(err, 0)
      end
    end)

    t.it("does not treat a single-option approval as a question", function()
      local parsed = permissions.new({
        config = function()
          return { permissions = { prompt = "select", auto_allow = { "allow_once" } } }
        end,
        valid = function()
          return true
        end,
        answer = function() end,
        dismiss = function() end,
        notify = function() end,
      })
      local interaction = {
        type = "permission",
        request = {
          toolCall = { kind = "execute", title = "npm test" },
          options = { { optionId = "a", kind = "allow_once" } },
        },
      }
      t.falsy(parsed:is_question(interaction))
      t.truthy(parsed:auto(interaction), "auto_allow no longer applies to a plain approval")
    end)

    t.it("recognises pi select and switch_mode as questions", function()
      local p = permissions.new({
        config = function()
          return { permissions = { prompt = "select", auto_allow = { "allow_once" } } }
        end,
        valid = function()
          return true
        end,
        answer = function() end,
        dismiss = function() end,
        notify = function() end,
      })
      for _, tool in ipairs({
        { kind = "other", rawInput = { method = "select" } },
        { kind = "other", rawInput = { method = "confirm" } },
        { kind = "switch_mode", title = "Approve Plan" },
      }) do
        local interaction = {
          type = "permission",
          request = {
            toolCall = tool,
            options = {
              { optionId = "a", kind = "allow_once" },
              { optionId = "b", kind = "allow_once" },
            },
          },
        }
        t.truthy(p:is_question(interaction), vim.inspect(tool))
        t.falsy(p:auto(interaction))
      end
    end)

    t.it("uses the meta permission title for Claude questions", function()
      controller.setup({ ui = { picker = "vim" }, permissions = { prompt = "select" } })
      local S = controller.state()
      local picker = require("acp.ui.picker")
      local original, seen = picker.select, nil
      picker.select = function(opts)
        seen = opts
      end
      local ok, err = pcall(function()
        S.view.interactions:open("permission", {
          sessionId = "s1",
          _meta = { permission = { title = "Ready to code?" } },
          toolCall = {
            kind = "switch_mode",
            title = "Approve Plan",
            _meta = { permission = { title = "Ready to code?" } },
          },
          options = {
            { optionId = "a", name = "Yes", kind = "allow_once" },
            { optionId = "r", name = "No", kind = "reject_once" },
          },
        }, function() end, 1, "perm-meta")
        t.truthy(seen)
        t.match("Ready to code%?", seen.title)
      end)
      picker.select = original
      if not ok then
        error(err, 0)
      end
    end)

    t.it("renders a compact statusline component", function()
      controller.setup({ ui = {}, permissions = { prompt = "native" } })
      local S = controller.state()
      S.conn.phase = "ready"
      S.sess.current = nil
      local ic = require("acp.ui.icons").get(true)
      t.eq(ic.assistant, controller.statusline())
      local session = state.new("s1", "/tmp")
      session.status = "running"
      S.sess.current = session
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
