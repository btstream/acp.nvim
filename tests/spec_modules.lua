return function(t)
  local state = require("acp.session.state")
  local presenter = require("acp.ui.presenter")
  local text = require("acp.ui.text")
  local permissions = require("acp.app.permissions")

  local function config(overrides)
    return function()
      return overrides
    end
  end

  t.describe("presenter", function()
    t.it("reports toolbar labels from config options", function()
      local s = state.new("s", "/tmp")
      s.config_options = {
        {
          id = "model",
          category = "model",
          currentValue = "provider/model-x",
          options = { { value = "provider/model-x", name = "provider/Model X" } },
        },
      }
      local model, mode = presenter.toolbar_labels(s)
      t.eq("Model X", model)
      t.eq(nil, mode)
    end)

    t.it("reuses the memoised labels until the option changes", function()
      local s = state.new("s", "/tmp")
      s.config_options = {
        { id = "model", category = "model", currentValue = "a", options = { { value = "a", name = "A" } } },
      }
      presenter.toolbar_labels(s)
      local cached = s._toolbar_labels
      presenter.toolbar_labels(s)
      t.truthy(cached == s._toolbar_labels, "labels should be memoised")
    end)
  end)

  t.describe("text layout", function()
    t.it("renders fenced code with a language row", function()
      local lines = text.render_text("```lua\nlocal a = 1\n```", "AcpAssistant", 80)
      t.eq("lua", lines[1].text)
      t.match("local a = 1", lines[2].text)
    end)

    t.it("keeps streaming renders identical to a fresh render", function()
      local full = "one\n" .. "two\n" .. "three"
      local cache = {}
      for i = 1, #full do
        text.render_text(full:sub(1, i), "AcpAssistant", 80, cache)
      end
      local streamed = text.render_text(full, "AcpAssistant", 80, cache)
      local fresh = text.render_text(full, "AcpAssistant", 80)
      t.eq(#fresh, #streamed)
      for i = 1, #fresh do
        t.eq(fresh[i].text, streamed[i].text)
      end
    end)

    t.it("indents lines and shifts highlight segments", function()
      local out = text.indent_lines({ { text = "x", segments = { { s = 0, e = 1, group = "G" } } } }, "  ")
      t.eq("  x", out[1].text)
      t.eq(2, out[1].segments[1].s)
      t.eq(3, out[1].segments[1].e)
    end)

    t.it("measures truncation by display width", function()
      t.eq("中文", text.truncate_width("中文", 4))
      t.eq("ab", text.truncate_width("abcd", 2))
      t.eq("", text.truncate_width("abc", 0))
    end)
  end)

  t.describe("permissions policy", function()
    local Interactions = require("acp.app.interactions")

    local function harness(overrides)
      local answered, shown = {}, 0
      local cfg = config(overrides or { permissions = { prompt = "select", auto_allow = {} } })
      local interactions
      local p = permissions.new({
        config = cfg,
        valid = function(interaction)
          return interaction.state == "pending"
        end,
        answer = function(interaction, option_id)
          interactions:answer(interaction.id, { outcome = { outcome = "selected", optionId = option_id } })
        end,
        dismiss = function(interaction)
          interactions:cancel(interaction.id)
        end,
        notify = function() end,
      })
      interactions = Interactions.new({
        policies = {
          function(interaction)
            return p:auto(interaction)
          end,
        },
        present = function()
          shown = shown + 1
          return true
        end,
        dismiss = function() end,
      })
      local function open(request)
        return interactions:open("permission", request, function(response)
          answered[#answered + 1] = response
        end)
      end
      local function resolve(id, option, dismissed)
        local interaction = interactions:get(id)
        if dismissed and not option then
          for _, candidate in ipairs(interaction.request.options or {}) do
            if candidate.kind and candidate.kind:match("^reject") then
              option = candidate.optionId
              break
            end
          end
        end
        if option then
          interactions:answer(id, { outcome = { outcome = "selected", optionId = option } })
        else
          interactions:cancel(id)
        end
      end
      return p, interactions, answered, open, resolve, function()
        return shown
      end
    end

    t.it("registers a request and reports it as waiting", function()
      local _, interactions, _, open = harness()
      open({ sessionId = "s", options = { { optionId = "a", kind = "allow_once" } } })
      t.eq(1, #interactions:pending())
      t.truthy(interactions:waiting("s"))
      t.falsy(interactions:waiting("other"))
      t.falsy(interactions:waiting(nil))
    end)

    t.it("auto-approves only configured option kinds", function()
      local _, interactions, answered, open, _, shown = harness({
        permissions = { prompt = "native", auto_allow = { "allow_always" } },
      })
      open({
        sessionId = "s",
        options = {
          { optionId = "once", kind = "allow_once" },
          { optionId = "always", kind = "allow_always" },
        },
      })
      t.eq("always", answered[1].outcome.optionId)
      t.eq(0, #interactions:pending())
      t.eq(0, shown(), "an auto-approved request needs no picker")
    end)

    t.it("does not auto-answer a question wrapped in a permission", function()
      local _, interactions, answered, open = harness({ permissions = { auto_allow = { "allow_once" } } })
      open({
        sessionId = "s",
        toolCall = { kind = "switch_mode" },
        options = { { optionId = "a", kind = "allow_once" } },
      })
      t.eq(1, #interactions:pending())
      t.eq(0, #answered)
    end)

    t.it("prefers an explicit reject option when dismissed", function()
      local _, _, answered, open, resolve = harness()
      open({
        sessionId = "s",
        options = {
          { optionId = "a", kind = "allow_once" },
          { optionId = "r", kind = "reject_once" },
        },
      })
      resolve("perm:1", nil, true)
      t.eq("r", answered[1].outcome.optionId)
    end)

    t.it("sends a cancelled outcome when no reject option exists", function()
      local _, _, answered, open, resolve = harness()
      open({ sessionId = "s", options = { { optionId = "a", kind = "allow_once" } } })
      resolve("perm:1", nil, true)
      t.eq("cancelled", answered[1].outcome.outcome)
    end)

    t.it("ignores a repeated resolution", function()
      local _, _, answered, open, resolve = harness()
      open({ sessionId = "s", options = { { optionId = "a", kind = "allow_once" } } })
      resolve("perm:1", "a")
      resolve("perm:1", "a")
      t.eq(1, #answered)
    end)

    t.it("drops the request when it is resolved elsewhere", function()
      local _, interactions, answered, open = harness()
      open({ sessionId = "s", options = {} })
      interactions:resolved("perm:1")
      t.eq(0, #interactions:pending())
      t.eq(0, #answered)
    end)

    t.it("clears every pending request on reset", function()
      local _, interactions, _, open = harness()
      open({ sessionId = "s", options = {} })
      open({ sessionId = "s", options = {} })
      interactions:cancel_all("reset")
      t.eq(0, #interactions:pending())
    end)
  end)
end
