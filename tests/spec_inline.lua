return function(t)
  local Config = require("acp.config")
  local review = require("acp.inline.review")

  local function cfg(over)
    return Config.validate(Config.merge(Config.defaults, over or {}))
  end

  t.describe("inline review policy", function()
    t.it("defaults to diff and honours exact filetypes before wildcards", function()
      local c = cfg({ inline = { review = { mode = "diff", by_filetype = { markdown = "write", ["*"] = "diff" } } } })
      t.eq("diff", (review.resolve("lua", c)))
      t.eq("write", (review.resolve("markdown", c)))
      t.eq("diff", (review.resolve("markdownx", c)))
      t.eq("diff", (review.resolve("", c)))
    end)

    t.it("falls back through compound filetype components", function()
      local c = cfg({ inline = { review = { by_filetype = { markdown = "write" } } } })
      t.eq("write", (review.resolve("markdown.pandoc", c)))
      t.eq("diff", (review.resolve("pandoc", c)))
    end)

    t.it("accepts the table form for forward-compatible per-filetype options", function()
      local c = cfg({ inline = { review = { by_filetype = { text = { mode = "write" } } } } })
      t.eq("write", (review.resolve("text", c)))
    end)

    t.it("lets always-accept win and can be reset", function()
      local c = cfg({ inline = { review = { by_filetype = { lua = "diff", ["*"] = "diff" } } } })
      review.always_accept(9101)
      t.eq("write", (review.resolve("lua", c, 9101)))
      review.reset(9101)
      t.eq("diff", (review.resolve("lua", c, 9101)))
    end)

    t.it("reports the source of the decision", function()
      local c = cfg({ inline = { review = { by_filetype = { markdown = "write" } } } })
      local mode, source = review.resolve("markdown.pandoc", c)
      t.eq("write", mode)
      t.eq("markdown", source)
      mode, source = review.resolve("lua", c)
      t.eq("diff", mode)
      t.eq("default", source)
    end)

    t.it("validates modes, keys and the override count", function()
      local bad = {
        { review = { mode = "ask" } },
        { review = { by_filetype = { "" } } },
        { review = { by_filetype = { [" "] = "diff" } } },
        { review = { by_filetype = { lua = "review" } } },
        { review = { by_filetype = { lua = {} } } },
        { review = { by_filetype = { "lua" } } },
        { scope = "buffer" },
        { copy_dir = "tmp" },
        { context_bytes = 10 },
        { expand_selection = "yes" },
      }
      for _, over in ipairs(bad) do
        t.falsy(
          pcall(function()
            Config.validate(Config.merge(Config.defaults, { inline = over }))
          end),
          vim.inspect(over)
        )
      end
      local many = {}
      for i = 1, 257 do
        many["ft" .. i] = "diff"
      end
      t.falsy(pcall(function()
        Config.validate(Config.merge(Config.defaults, { inline = { review = { by_filetype = many } } }))
      end))
    end)

    t.it("validates the inline keymaps", function()
      t.falsy(pcall(function()
        Config.validate(Config.merge(Config.defaults, { keymaps = { inline = { typo = "x" } } }))
      end))
      t.falsy(pcall(function()
        Config.validate(Config.merge(Config.defaults, { keymaps = { inline = { normal = 1 } } }))
      end))
      t.truthy(pcall(function()
        Config.validate(
          Config.merge(Config.defaults, { keymaps = { inline = { normal = false, visual = "<leader>x" } } })
        )
      end))
    end)
  end)
end
