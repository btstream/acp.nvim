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
  local field = {
    key = key,
    title = property.title or key,
    description = property.description,
    default = property.default,
    required = required,
  }
  if type(property) ~= "table" then
    return nil
  end
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

---@param schema table
---@return {fields: table[], message: string|nil}|nil
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
      if property and property.type == "object" then
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
    return tostring(a.title) < tostring(b.title)
  end)
  if #fields == 0 then
    return nil
  end
  return { fields = fields }
end

local function check_text(field, value)
  if field.min_length and #value < field.min_length then
    return string.format("%s must be at least %d characters", field.title, field.min_length)
  end
  if field.max_length and #value > field.max_length then
    return string.format("%s must be at most %d characters", field.title, field.max_length)
  end
  if field.pattern and not value:match(field.pattern) then
    return string.format("%s does not match the required pattern", field.title)
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
      local list = type(value) == "table" and value or {}
      if custom then
        list = vim.list_extend(vim.deepcopy(list), { custom })
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
      if not chosen and field.required then
        return false, field.title .. " is required"
      end
      if chosen then
        content[field.key] = chosen
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
      if (not text or text == "") and field.required then
        return false, field.title .. " is required"
      end
      if text and text ~= "" then
        local problem = check_text(field, text)
        if problem then
          return false, problem
        end
        content[field.key] = text
      end
    end
    if custom and content[field.key] == nil then
      content[field.key] = custom
    end
  end
  return true, content
end

return M
