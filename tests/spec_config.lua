return function(t)
  local config = require("acp.config")

  t.describe("config", function()
    t.it("merges nested defaults", function()
      local merged = config.merge(config.defaults, { layout = { width = 0.5 } })
      t.eq(0.5, merged.layout.width)
      t.eq(0.38, config.defaults.layout.width)
      t.eq(8, merged.layout.input_height)
    end)

    t.it("replaces lists instead of merging them", function()
      local merged = config.merge(config.defaults, { agents = { opencode = { command = "x", args = { "y" } } } })
      t.eq({ "y" }, merged.agents.opencode.args)
    end)

    t.it("rejects an unknown agent", function()
      local merged = config.merge(config.defaults, { agent = "nope" })
      t.raises(function()
        config.validate(merged)
      end, "agent must be one of")
    end)

    t.it("rejects an empty agent command", function()
      local merged = config.merge(config.defaults, { agents = { opencode = { command = "" } } })
      t.raises(function()
        config.validate(merged)
      end, "non%-empty string")
    end)

    t.it("clamps panel width", function()
      local cfg = config.validate(config.merge(config.defaults, {}))
      t.eq(42, config.panel_width(cfg, 100))
      t.eq(76, config.panel_width(cfg, 200))
      t.eq(24, config.panel_width(cfg, 40))
    end)

    t.it("supports absolute widths", function()
      local cfg = config.validate(config.merge(config.defaults, { layout = { width = 60 } }))
      t.eq(60, config.panel_width(cfg, 200))
    end)

    t.it("accepts zero or at least 1024 for receive limits", function()
      for _, value in ipairs({ 0, 1024, 1024 * 1024 }) do
        local cfg = config.validate(
          config.merge(
            config.defaults,
            { transport = { max_pending_bytes = value, spill_bytes = value, text_chunk_bytes = value } }
          )
        )
        t.eq(value, cfg.transport.max_pending_bytes)
        t.eq(value, cfg.transport.spill_bytes)
        t.eq(value, cfg.transport.text_chunk_bytes)
      end
      t.eq(64 * 1024 * 1024, config.defaults.transport.spill_bytes)
      t.eq(64 * 1024, config.defaults.transport.text_chunk_bytes)
    end)
    t.it("rejects receive limits between 1 and 1023", function()
      for _, key in ipairs({ "max_pending_bytes", "spill_bytes", "text_chunk_bytes" }) do
        local merged = config.merge(config.defaults, { transport = { [key] = 500 } })
        t.raises(function()
          config.validate(merged)
        end, key)
      end
    end)
  end)
end
