local core = require("acp.completion")
local Source = {}
Source.__index = Source

function Source.new()
  return setmetatable({}, Source)
end
function Source:enabled()
  return core.available(vim.api.nvim_get_current_buf())
end
function Source:get_trigger_characters()
  return { "@", "/", '"' }
end
function Source:get_completions(ctx, callback)
  local row = ctx.pos and ctx.pos.row or ctx.cursor[1] - 1
  local col = ctx.pos and ctx.pos.col or ctx.cursor[2]
  return core.request(ctx.bufnr, row, col, function(items, err)
    if err then
      require("acp.log").warn("completion: %s", err)
    end
    callback({ items = items, is_incomplete_forward = true, is_incomplete_backward = true })
  end)
end

return Source
