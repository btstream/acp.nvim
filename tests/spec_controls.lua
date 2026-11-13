return function(t)
  local agents = require("acp.agents")
  local controls = require("acp.session.controls")
  local state = require("acp.session.state")

  local function session_with(result, profile_name)
    local s = state.new("s", "/tmp")
    s.profile = agents.get({ profile = profile_name or "generic" })
    s:configure(result)
    return s
  end

  t.describe("agent profiles", function()
    t.it("resolves the profile from the agent name, then generic", function()
      t.eq("opencode", agents.get({}, "opencode").name)
      t.eq("claude", agents.get({}, "claude").name)
      t.eq("pi", agents.get({}, "pi").name)
      t.eq("generic", agents.get({}, "unknown-agent").name)
      t.eq("generic", agents.get(nil, nil).name)
    end)

    t.it("lets an explicit profile win over the name", function()
      t.eq("pi", agents.get({ profile = "pi" }, "opencode").name)
      -- An unknown explicit profile falls back to the name.
      t.eq("claude", agents.get({ profile = "nope" }, "claude").name)
    end)

    t.it("recognises plan and unsafe modes", function()
      local claude = agents.get({}, "claude")
      t.truthy(claude.plan_mode("plan"))
      t.truthy(claude.plan_mode("Plan"))
      t.falsy(claude.plan_mode("default"))
      for _, mode in ipairs({ "acceptEdits", "bypassPermissions", "auto" }) do
        t.truthy(claude.unsafe_edit_mode(mode), mode)
      end
      t.falsy(claude.unsafe_edit_mode("default"))
    end)

    t.it("reads Claude tool names from _meta", function()
      local claude = agents.get({}, "claude")
      t.eq("MultiEdit", claude.tool_name({ _meta = { claudeCode = { toolName = "MultiEdit" } } }))
      t.eq(nil, claude.tool_name({ name = "Bash" }))
      t.eq(nil, claude.tool_name(nil))
    end)

    t.it("treats ExitPlanMode and pi UI requests as questions", function()
      local claude = agents.get({}, "claude")
      t.truthy(claude.is_question({ toolCall = { kind = "switch_mode" } }))
      t.falsy(claude.is_question({ toolCall = { kind = "edit" } }))
      local pi = agents.get({}, "pi")
      t.truthy(pi.is_question({ toolCall = { rawInput = { method = "select" } } }))
      t.truthy(pi.is_question({ toolCall = { rawInput = { method = "confirm" } } }))
      t.falsy(pi.is_question({ toolCall = { rawInput = { method = "other" } } }))
      -- The generic profile infers nothing.
      t.falsy(agents.get({}, "unknown").is_question)
    end)

    t.it("only OpenCode reads its own _meta", function()
      local opencode = agents.get({}, "opencode")
      local retry = opencode.update_meta({ _meta = { ["opencode/retry"] = 2 } }, {})
      t.eq(2, retry.retry)
      t.eq(nil, agents.get({}, "claude").update_meta({ _meta = { ["opencode/retry"] = 2 } }, {}))
    end)
  end)

  t.describe("session controls", function()
    t.it("uses configOptions and ignores duplicated modes", function()
      -- pi sends the same thinking levels as both `modes` and a config option.
      local s = session_with({
        modes = {
          currentModeId = "high",
          availableModes = { { id = "low", name = "Thinking: low" }, { id = "high", name = "Thinking: high" } },
        },
        configOptions = {
          { id = "model", category = "model", type = "select", currentValue = "m1", options = { { value = "m1" } } },
          {
            id = "thinking",
            category = "thought_level",
            type = "select",
            currentValue = "high",
            options = { { value = "low", name = "Thinking: low" }, { value = "high", name = "Thinking: high" } },
          },
        },
      }, "pi")
      t.truthy(s.controls.model)
      t.truthy(s.controls.thinking)
      t.eq("high", s.controls.thinking.current)
      -- pi's modes are a duplicate of thought_level, so no work mode.
      t.eq(nil, s.controls.mode)
    end)

    t.it("builds a work mode and a thinking level from modes alone", function()
      local s = session_with({
        modes = {
          currentModeId = "medium",
          availableModes = {
            { id = "low", name = "Low" },
            { id = "medium", name = "Medium" },
          },
        },
      }, "pi")
      t.truthy(s.controls.thinking)
      t.eq("medium", s.controls.thinking.current)
      t.eq("modes", s.controls.thinking.source)
      t.eq(nil, s.controls.mode)
    end)

    t.it("reads Claude mode semantics from option metadata", function()
      local s = session_with({
        modes = {
          currentModeId = "plan",
          availableModes = {
            { id = "default", name = "Manual", _meta = { kind = "standard" } },
            { id = "plan", name = "Plan", _meta = { kind = "plan" } },
            { id = "bypassPermissions", name = "Bypass", _meta = { kind = "full_access" } },
          },
        },
        configOptions = {
          {
            id = "mode",
            category = "mode",
            type = "select",
            currentValue = "plan",
            options = {
              { value = "default", name = "Manual", _meta = { kind = "standard" } },
              { value = "plan", name = "Plan", _meta = { kind = "plan" } },
              { value = "bypassPermissions", name = "Bypass", _meta = { kind = "full_access" } },
            },
          },
        },
      }, "claude")
      t.truthy(s.controls.mode.plan)
      t.falsy(s.controls.mode.unsafe)
      -- Switching the current value updates the derived flags.
      s.config_options[1].currentValue = "bypassPermissions"
      s:refresh_controls()
      t.falsy(s.controls.mode.plan)
      t.truthy(s.controls.mode.unsafe)
    end)

    t.it("puts unknown categories into extras", function()
      local s = session_with({
        configOptions = {
          { id = "fast", category = "other", type = "boolean", currentValue = false },
          { id = "model", category = "model", type = "select", currentValue = "m" },
        },
      })
      t.truthy(s.controls.model)
      t.eq(1, #s.controls.extras)
      t.eq("boolean", s.controls.extras[1].kind)
      t.eq("off", controls.label(s.controls.extras[1]))
    end)

    t.it("reads the nested current mode from modes", function()
      local s = session_with({
        modes = { currentModeId = "default", availableModes = { { id = "default", name = "Default" } } },
      }, "claude")
      t.eq("default", s.current_mode)
      t.eq("default", s.controls.mode.current)
    end)

    t.it("updates controls on current_mode_update", function()
      local reducer = require("acp.session.reducer")
      local s = session_with({
        configOptions = {
          {
            id = "mode",
            category = "mode",
            type = "select",
            currentValue = "default",
            options = { { value = "default", name = "Manual" }, { value = "plan", name = "Plan" } },
          },
        },
      }, "claude")
      reducer.apply(s, { sessionUpdate = "current_mode_update", currentModeId = "plan" })
      t.eq("plan", s.current_mode)
      t.eq("plan", s.controls.mode.current)
      t.truthy(s.controls.mode.plan)
    end)

    t.it("labels control values without a config option", function()
      local s = session_with({
        modes = { currentModeId = "plan", availableModes = { { id = "plan", name = "Plan" } } },
      })
      t.eq("Plan", controls.label(s.controls.mode))
    end)
  end)
end
