-- Translate an elicitation JSON schema into a flat field list and validate it.
--
-- Only the shape agents actually send is supported: a root object of scalar or
-- enum fields. Nested objects (and anything else unknown) make the caller reply
-- `decline` rather than render a broken form.
local M = {}

local function enum_options(values)
  local out = {}
  for _, value in ipairs(values or {}) do
    if type(value) == "string" then
      out[#out + 1] = { value = value, label = value }
    elseif type(value) == "table" and type(value.const) == "string" then
      out[#out + 1] = { value = value.const, label = value.title or value.const, description = value.description }
    end
  end
  return out
end

local function one_of(entries)
  local out = {}
  for _, entry in ipairs(entries or {}) do
    if type(entry) == "table" and type(entry.const) == "string" then
      out[#out + 1] = { value = entry.const, label = entry.title or entry.const, description = entry.description }
    end
  end
  return out
end

local function parse_field(key, property, required)
  if type(property) ~= "table" then
    return nil
  end
  local field = {
    key = key,
    title = property.title or key,
    description = property.description,
    default = property.default,
    required = required,
  }
  local kind = property.type
  if property.enum then
    field.kind, field.options = "choice", enum_options(property.enum)
  elseif property.oneOf and kind == "string" then
    field.kind, field.options = "choice", one_of(property.oneOf)
  elseif kind == "array" then
    local items = property.items or {}
    if items.enum then
      field.kind, field.options = "multi", enum_options(items.enum)
    elseif items.anyOf then
      field.kind, field.options = "multi", one_of(items.anyOf)
    else
      return nil
    end
    field.min_items = property.minItems
    field.max_items = property.maxItems
  elseif kind == "boolean" then
    field.kind = "boolean"
  elseif kind == "number" or kind == "integer" then
    field.kind = kind
    field.minimum, field.maximum = property.minimum, property.maximum
  elseif kind == "string" then
    field.kind = "text"
    field.min_length, field.max_length = property.minLength, property.maxLength
    field.pattern, field.format = property.pattern, property.format
  else
    return nil
  end
  if field.kind == "choice" and #field.options == 0 then
    return nil
  end
  if field.kind == "multi" and #field.options == 0 then
    return nil
  end
  return field
end

---Order fields by key, numerically where the key ends in digits.
---
---Claude numbers its questions `question_0`, `question_1`, … and that numbering
---is the display order; lexicographic sorting would put `question_10` first.
---@param a string
---@param b string
---@return boolean
local function key_before(a, b)
  local a_head, a_num = a:match("^(.-)(%d+)$")
  local b_head, b_num = b:match("^(.-)(%d+)$")
  if a_head and b_head and a_head == b_head then
    return tonumber(a_num) < tonumber(b_num)
  end
  return a < b
end

---@param schema table
---@return {fields: table[]}|nil
function M.parse(schema)
  if type(schema) ~= "table" or schema.type ~= "object" or type(schema.properties) ~= "table" then
    return nil
  end
  local required = {}
  for _, key in ipairs(schema.required or {}) do
    required[key] = true
  end
  local fields = {}
  local by_key = {}
  for key, property in pairs(schema.properties) do
    if type(key) == "string" and not key:match("_custom$") then
      if type(property) == "table" and property.type == "object" then
        return nil
      end
      local field = parse_field(key, property, required[key])
      if not field then
        return nil
      end
      fields[#fields + 1] = field
      by_key[key] = field
    end
  end
  for key, property in pairs(schema.properties) do
    local base = type(key) == "string" and key:match("^(.*)_custom$") or nil
    local field = base and by_key[base]
    if field and (field.kind == "choice" or field.kind == "multi") then
      field.custom_key = key
      field.custom_title = (type(property) == "table" and property.title) or "Other"
    end
  end
  table.sort(fields, function(a, b)
    return key_before(a.key, b.key)
  end)
  if #fields == 0 then
    return nil
  end
  return { fields = fields }
end

---JSON Schema patterns are ECMA-262 regexes, not Lua patterns. Translating
---between the two is out of scope, so validate only the subset where both
---dialects agree. `%`, `{}` and `\` mean different things (or raise), and a
---silent wrong answer is worse than no check.
---@param field table
---@param value string
---@return string|nil problem
local function check_pattern(field, value)
  local pattern = field.pattern
  if pattern:find("[%%{}%\\]") then
    require("acp.log").debug("skipping non-portable elicitation pattern for %s: %s", field.key, pattern)
    return nil
  end
  local ok, matched = pcall(string.match, value, pattern)
  if not ok then
    require("acp.log").debug("unsupported elicitation pattern for %s: %s", field.key, pattern)
    return nil
  end
  if not matched then
    return string.format("%s does not match the required pattern", field.title)
  end
  return nil
end

---@param field table
---@param value string
---@return string|nil problem
local function check_text(field, value)
  local length = vim.fn.strchars(value)
  if field.min_length and length < field.min_length then
    return string.format("%s must be at least %d characters", field.title, field.min_length)
  end
  if field.max_length and length > field.max_length then
    return string.format("%s must be at most %d characters", field.title, field.max_length)
  end
  if field.pattern then
    local problem = check_pattern(field, value)
    if problem then
      return problem
    end
  end
  local format = field.format
  if format == "email" and not value:match("^[^@%s]+@[^@%s]+%.[^@%s]+$") then
    return string.format("%s must be an email address", field.title)
  elseif format == "uri" and not value:match("^%a[%w+.-]*://") then
    return string.format("%s must be a URI", field.title)
  elseif format == "date" and not value:match("^%d%d%d%d%-%d%d%-%d%d$") then
    return string.format("%s must be a date (YYYY-MM-DD)", field.title)
  end
  return nil
end

---Validate raw form values.
---@param fields table[]
---@param values table<string, any>
---@return boolean ok, table content|string error
function M.validate(fields, values)
  local content = {}
  for _, field in ipairs(fields) do
    local value = values[field.key]
    local custom = field.custom_key and values[field.custom_key] or nil
    if custom == "" then
      custom = nil
    end
    if field.kind == "multi" then
      local list = type(value) == "table" and vim.deepcopy(value) or {}
      if custom then
        list[#list + 1] = custom
      end
      if #list == 0 and field.required then
        return false, field.title .. " is required"
      end
      if field.min_items and #list > 0 and #list < field.min_items then
        return false, string.format("%s needs at least %d selections", field.title, field.min_items)
      end
      if field.max_items and #list > field.max_items then
        return false, string.format("%s allows at most %d selections", field.title, field.max_items)
      end
      if #list > 0 then
        content[field.key] = list
      end
    elseif field.kind == "choice" then
      local chosen = value
      if chosen == "" then
        chosen = nil
      end
      -- `<key>_custom` doubles as "Other" and as a note on the chosen option.
      -- With no option picked the custom text is the answer; otherwise both
      -- travel so the agent can keep the note.
      local answer = chosen or custom
      if not answer and field.required then
        return false, field.title .. " is required"
      end
      if chosen and #field.options > 0 then
        local known = false
        for _, option in ipairs(field.options) do
          if option.value == chosen then
            known = true
            break
          end
        end
        if not known then
          return false, string.format("%s must be one of the offered options", field.title)
        end
      end
      if answer then
        content[field.key] = answer
      end
      if chosen and custom then
        content[field.custom_key] = custom
      end
    elseif field.kind == "boolean" then
      if value ~= nil then
        content[field.key] = value and true or false
      elseif field.required then
        return false, field.title .. " is required"
      end
    elseif field.kind == "number" or field.kind == "integer" then
      if value == nil or value == "" then
        if field.required then
          return false, field.title .. " is required"
        end
      else
        local number = tonumber(value)
        if not number then
          return false, field.title .. " must be a number"
        end
        if field.kind == "integer" and number % 1 ~= 0 then
          return false, field.title .. " must be an integer"
        end
        if field.minimum and number < field.minimum then
          return false, string.format("%s must be at least %s", field.title, field.minimum)
        end
        if field.maximum and number > field.maximum then
          return false, string.format("%s must be at most %s", field.title, field.maximum)
        end
        content[field.key] = number
      end
    else
      local text = type(value) == "string" and value or nil
      if (not text or text == "") and not custom and field.required then
        return false, field.title .. " is required"
      end
      if text and text ~= "" then
        local problem = check_text(field, text)
        if problem then
          return false, problem
        end
        content[field.key] = text
      elseif custom then
        content[field.key] = custom
      end
    end
  end
  return true, content
end

return M
