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
    local function harness(overrides)
      local pending, resolved, changes = {}, {}, 0
      local p = permissions.new({
        pending = function()
          return pending
        end,
        config = config(overrides or { permissions = { prompt = "select", auto_allow = {} } }),
        client = function()
          return {
            resolve_permission = function(_, key, option)
              resolved[#resolved + 1] = { key = key, option = option }
            end,
          }
        end,
        on_changed = function()
          changes = changes + 1
        end,
        valid = function(entry, key)
          return entry ~= nil and pending[key] == entry
        end,
        notify = function() end,
      })
      return p, pending, resolved, function()
        return changes
      end
    end

    t.it("registers a request and reports it as waiting", function()
      local p, pending = harness()
      p:request({ key = "k", session_id = "s", options = { { optionId = "a", kind = "allow_once" } } })
      t.truthy(pending.k)
      t.truthy(p:waiting({ id = "s" }))
      t.falsy(p:waiting({ id = "other" }))
      t.falsy(p:waiting(nil))
    end)

    t.it("auto-approves only configured option kinds", function()
      local p, pending = harness({ permissions = { prompt = "native", auto_allow = { "allow_always" } } })
      local entry, option = p:request({
        key = "k",
        session_id = "s",
        options = {
          { optionId = "once", kind = "allow_once" },
          { optionId = "always", kind = "allow_always" },
        },
      })
      t.truthy(entry)
      t.eq("always", option)
      t.truthy(pending.k, "the entry stays pending until resolve runs")
      t.falsy(p:should_prompt())
    end)

    t.it("prefers an explicit reject option when dismissed", function()
      local p, _, resolved = harness()
      p:request({
        key = "k",
        session_id = "s",
        options = {
          { optionId = "a", kind = "allow_once" },
          { optionId = "r", kind = "reject_once" },
        },
      })
      p:resolve("k", nil, true)
      t.eq("r", resolved[1].option)
    end)

    t.it("sends a cancelled outcome when no reject option exists", function()
      local p, _, resolved = harness()
      p:request({ key = "k", session_id = "s", options = { { optionId = "a", kind = "allow_once" } } })
      p:resolve("k", nil, true)
      t.eq(nil, resolved[1].option)
    end)

    t.it("ignores a repeated resolution", function()
      local p, _, resolved = harness()
      p:request({ key = "k", session_id = "s", options = { { optionId = "a", kind = "allow_once" } } })
      p:resolve("k", "a")
      p:resolve("k", "a")
      t.eq(1, #resolved)
    end)

    t.it("drops the request when the client reports it resolved", function()
      local p, pending = harness()
      p:request({ key = "k", session_id = "s", options = {} })
      p:resolved("k")
      t.falsy(pending.k)
    end)

    t.it("clears every pending request on reset", function()
      local p, pending = harness()
      p:request({ key = "a", session_id = "s", options = {} })
      p:request({ key = "b", session_id = "s", options = {} })
      p:reset()
      t.eq(0, vim.tbl_count(pending))
    end)
  end)
end
