local core = require("acp.completion")
local Source = {}
Source.__index = Source

function Source.new()
  return setmetatable({}, Source)
end
function Source:is_available()
  return core.available(vim.api.nvim_get_current_buf())
end
function Source:get_debug_name()
  return "acp"
end
function Source:get_position_encoding_kind()
  return "utf-8"
end
function Source:get_trigger_characters()
  return { "@", "/", '"' }
end
function Source:get_keyword_pattern()
  return [=[[^[:space:]]\+]=]
end
function Source:complete(params, callback)
  if self.cancel then
    self.cancel()
  end
  local token, done = {}, false
  self.token = token
  local cancel = core.request(
    params.context.bufnr,
    params.context.cursor.row - 1,
    params.context.cursor.col - 1,
    function(items, err)
      done = true
      if self.token == token then
        self.cancel = nil
      end
      if err then
        require("acp.log").warn("completion: %s", err)
      end
      callback({ items = items, isIncomplete = true })
    end
  )
  if not done then
    self.cancel = cancel
  end
end

local id
function Source.setup()
  if not id then
    id = require("cmp").register_source("acp", Source.new())
  end
  return id
end

return Source
