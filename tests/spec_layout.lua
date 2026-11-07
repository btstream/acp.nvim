return function(t)
  local edgy = require("acp.integrations.edgy")

  t.describe("layout", function()
    t.it("builds edgy views with the expected filetypes", function()
      local views = edgy.views({ width = 0.4, input_height = 6 })
      t.eq("acp_chat", views.chat.ft)
      t.eq("acp_input", views.input.ft)
      t.eq(0.4, views.chat.size.width)
      t.eq(6, views.input.size.height)
      t.falsy(views.chat.wo.winbar)
      t.falsy(views.input.wo.winbar)
    end)

    t.it("lets acp own the composer winbar by default", function()
      local views = edgy.views()
      t.eq(false, views.input.wo.winbar)
      t.eq(false, views.chat.wo.winbar)
    end)

    t.it("extends an edgy config without duplicating views", function()
      local opts = { right = { "Trouble" } }
      edgy.extend(opts)
      edgy.extend(opts)
      local count = 0
      for _, entry in ipairs(opts.right) do
        if type(entry) == "table" and (entry.ft == "acp_chat" or entry.ft == "acp_input") then
          count = count + 1
        end
      end
      t.eq(2, count)
    end)

    t.it("does not clobber an existing acp view", function()
      local opts = { right = { { ft = "acp_chat", title = "Mine" } } }
      edgy.extend(opts)
      local first = opts.right[1]
      t.eq("Mine", first.title)
    end)
  end)
end
