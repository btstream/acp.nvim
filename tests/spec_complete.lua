return function(t)
  local complete = require("acp.ui.complete")
  local context = require("acp.context")
  local config = require("acp.config")
  local state = require("acp.session.state")

  t.describe("completion", function()
    t.it("completes slash commands", function()
      local session = state.new("s", "/tmp")
      session.commands = {
        { name = "compact", description = "Compact the session" },
        { name = "init", description = "Create AGENTS.md" },
      }
      vim.api.nvim_buf_set_lines(0, 0, -1, false, { "/com" })
      vim.api.nvim_win_set_cursor(0, { 1, 4 })
      local items = complete.complete(0, "com", session)
      t.eq(1, #items)
      t.eq("compact", items[1].word)
    end)

    t.it("finds the start column for an @mention", function()
      vim.api.nvim_buf_set_lines(0, 0, -1, false, { "look at @lua/" })
      vim.api.nvim_win_set_cursor(0, { 1, 12 })
      t.eq(8, complete.complete(1, "", nil))
    end)

    t.it("finds the start column for a slash command", function()
      vim.api.nvim_buf_set_lines(0, 0, -1, false, { "/comp" })
      vim.api.nvim_win_set_cursor(0, { 1, 5 })
      t.eq(1, complete.complete(1, "", nil))
    end)

    t.it("declines completion in the middle of prose", function()
      vim.api.nvim_buf_set_lines(0, 0, -1, false, { "just some words" })
      vim.api.nvim_win_set_cursor(0, { 1, 15 })
      t.eq(-3, complete.complete(1, "", nil))
    end)
  end)

  t.describe("context", function()
    local cfg = config.validate(config.merge(config.defaults, {}))

    t.it("encodes file URIs", function()
      t.eq("file:///tmp/a%20b.lua", context.to_uri("/tmp/a b.lua"))
    end)

    t.it("attaches an existing file", function()
      local path = "/tmp/acp_ctx_test.lua"
      local fh = io.open(path, "wb")
      fh:write("local x = 1\n")
      fh:close()
      local att = context.file(path, cfg)
      t.truthy(att)
      t.eq("file", att.kind)
      t.eq("acp_ctx_test.lua", att.label)
      -- The block is built at send time, not at attach time.
      t.eq(nil, att.block)
      local blocks = context.to_prompt("", { att }, cfg)
      t.eq("resource_link", blocks[1].type)
    end)

    t.it("rejects a missing file with a message", function()
      local att, err = context.file("/tmp/definitely-missing-acp.lua", cfg)
      t.falsy(att)
      t.match("not a readable file", err)
    end)

    t.it("expands @mentions into attachments", function()
      local path = "/tmp/acp_ctx_test.lua"
      local attachments = context.mentions("please read @/tmp/acp_ctx_test.lua", cfg, "/tmp")
      t.eq(1, #attachments)
      t.eq("file", attachments[1].kind)
    end)

    t.it("ignores @mentions that are not files", function()
      local attachments = context.mentions("mention @someone in chat", cfg, "/tmp")
      t.eq(0, #attachments)
    end)

    t.it("builds prompt blocks with text first", function()
      local blocks = context.to_prompt("hello", {
        { block = { type = "resource_link", uri = "file:///tmp/a", name = "a" } },
      })
      t.eq(2, #blocks)
      t.eq("text", blocks[1].type)
      t.eq("resource_link", blocks[2].type)
    end)

    t.it("omits an empty text block", function()
      local blocks = context.to_prompt("", {})
      t.eq(0, #blocks)
    end)

    local function supports(value)
      return function(name)
        if name == "embeddedContext" or name == "image" then
          return value
        end
        return false
      end
    end

    t.it("sends an unsaved buffer as a link plus text without embeddedContext", function()
      local path = "/tmp/acp_ctx_unsaved.lua"
      vim.fn.writefile({ "on disk" }, path)
      local bufnr = vim.fn.bufadd(path)
      vim.fn.bufload(bufnr)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "line one", "line two" })
      local att = assert(context.file(path, cfg))
      t.eq(true, att.unsaved)
      -- Nothing is decided at attach time.
      t.eq(nil, att.block)

      local blocks = context.to_prompt("look", { att }, cfg, { supports = supports(false) })
      t.eq("text", blocks[1].type)
      t.eq("resource_link", blocks[2].type)
      t.eq("text", blocks[3].type)
      t.eq("line one\nline two", blocks[3].text, "the buffer contents must reach the agent")

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
      vim.fn.delete(path)
    end)

    t.it("embeds an unsaved buffer when the agent advertises embeddedContext", function()
      local path = "/tmp/acp_ctx_unsaved2.lua"
      vim.fn.writefile({ "on disk" }, path)
      local bufnr = vim.fn.bufadd(path)
      vim.fn.bufload(bufnr)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "buffer only" })
      local att = assert(context.file(path, cfg))

      local blocks = context.to_prompt("look", { att }, cfg, { supports = supports(true) })
      t.eq("resource", blocks[2].type)
      t.eq("buffer only", blocks[2].resource.text)

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
      vim.fn.delete(path)
    end)

    t.it("sends a selection as a link plus text without embeddedContext", function()
      local path = "/tmp/acp_ctx_selection.lua"
      vim.fn.writefile({ "alpha", "beta", "gamma" }, path)
      local bufnr = vim.fn.bufadd(path)
      vim.fn.bufload(bufnr)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "alpha", "beta", "gamma" })
      vim.fn.setpos("'<", { 0, 2, 1, 0 })
      vim.fn.setpos("'>", { 0, 2, 4, 0 })
      local att = assert(context.selection(cfg, { bufnr = bufnr }))

      local blocks = context.to_prompt("see", { att }, cfg, { supports = supports(false) })
      t.eq("resource_link", blocks[2].type)
      t.eq("beta", blocks[3].text, "the selected text must reach the agent")

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
      vim.fn.delete(path)
    end)

    t.it("embeds a selection when the agent advertises embeddedContext", function()
      local path = "/tmp/acp_ctx_selection2.lua"
      vim.fn.writefile({ "alpha" }, path)
      local bufnr = vim.fn.bufadd(path)
      vim.fn.bufload(bufnr)
      vim.fn.setpos("'<", { 0, 1, 1, 0 })
      vim.fn.setpos("'>", { 0, 1, 5, 0 })
      local att = assert(context.selection(cfg, { bufnr = bufnr }))

      local blocks = context.to_prompt("see", { att }, cfg, { supports = supports(true) })
      t.eq("resource", blocks[2].type)
      t.eq("alpha", blocks[2].resource.text)

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
      vim.fn.delete(path)
    end)

    t.it("keeps a draft-restored attachment instead of dropping it", function()
      -- `storage/drafts` strips `block` from saved attachments; the prompt must
      -- still carry them.
      local att = { kind = "file", label = "x.lua", uri = "file:///tmp/x.lua", path = "/tmp/x.lua" }
      local blocks = context.to_prompt("msg", { att }, cfg)
      t.eq(2, #blocks)
      t.eq("resource_link", blocks[2].type)
      t.eq("file:///tmp/x.lua", blocks[2].uri)
    end)
  end)
end
