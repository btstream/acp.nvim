-- One byte-oriented grammar for completion edits and submitted file mentions.
-- Quoted paths use JSON string escaping, so even quotes/newlines round-trip.
local M = {}

local function boundary(text, at)
  return at == 1 or text:sub(at - 1, at - 1):match("[%s%(%[{]") ~= nil
end

local function plain(c)
  return c ~= "" and c:byte() >= 32 and c:byte() ~= 127 and not c:match('[%s"\\@,;:%(%){%}%[%]<>]')
end

function M.encode(path)
  for i = 1, #path do
    if not plain(path:sub(i, i)) then
      return "@" .. vim.json.encode(path)
    end
  end
  return "@" .. path
end

function M.display(path)
  return path:find("%c") and vim.json.encode(path) or path
end

function M.tokens(text, incomplete)
  local out, i = {}, 1
  while i <= #text do
    if text:sub(i, i) ~= "@" or not boundary(text, i) then
      i = i + 1
    else
      local first, quoted, closed = i, text:sub(i + 1, i + 1) == '"', false
      local stop = i + 1
      local path
      if quoted then
        stop = stop + 1
        while stop <= #text do
          local c = text:sub(stop, stop)
          if c == "\\" then
            stop = stop + 2
          elseif c == '"' then
            closed, stop = true, stop + 1
            break
          else
            stop = stop + 1
          end
        end
        stop = math.min(stop, #text + 1)
        if closed then
          local ok, value = pcall(vim.json.decode, text:sub(first + 1, stop - 1))
          if ok and type(value) == "string" and not value:find("\0", 1, true) then
            path = value
          end
        end
      else
        while stop <= #text and plain(text:sub(stop, stop)) do
          stop = stop + 1
        end
        path, closed = text:sub(first + 1, stop - 1), true
      end
      if (closed and path and path ~= "") or incomplete then
        out[#out + 1] = { first = first - 1, last = stop - 1, path = path, quoted = quoted, closed = closed }
      end
      i = math.max(first + 1, stop)
    end
  end
  return out
end

function M.context(line, col)
  for _, token in ipairs(M.tokens(line, true)) do
    if col > token.first and col <= token.last then
      local raw = line:sub(token.first + 2, col)
      local query = raw
      if token.quoted then
        if raw:sub(-1) ~= '"' or not token.closed or col < token.last then
          raw = raw .. '"'
        end
        local ok, value = pcall(vim.json.decode, raw)
        query = ok and type(value) == "string" and value or line:sub(token.first + 3, col)
      end
      return { kind = "file", first = token.first, last = token.last, query = query }
    end
  end
end

return M
