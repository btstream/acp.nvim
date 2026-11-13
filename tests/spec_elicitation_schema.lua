return function(t)
  local schema = require("acp.app.elicitation_schema")

  local function field_by_key(parsed, key)
    for _, item in ipairs(parsed.fields) do
      if item.key == key then
        return item
      end
    end
  end

  t.describe("elicitation schema", function()
    t.it("parses string enums as a single choice", function()
      local parsed = schema.parse({
        type = "object",
        properties = { colour = { type = "string", title = "Colour", enum = { "red", "blue" } } },
        required = { "colour" },
      })
      t.truthy(parsed)
      local field = field_by_key(parsed, "colour")
      t.eq("choice", field.kind)
      t.truthy(field.required)
      t.eq({ "red", "blue" }, { field.options[1].value, field.options[2].value })
    end)

    t.it("parses oneOf titles and descriptions", function()
      local parsed = schema.parse({
        type = "object",
        properties = {
          pick = {
            type = "string",
            oneOf = {
              { const = "a", title = "Alpha", description = "first" },
              { const = "b", title = "Beta" },
            },
          },
        },
      })
      t.truthy(parsed)
      local field = field_by_key(parsed, "pick")
      t.eq("Alpha", field.options[1].label)
      t.eq("first", field.options[1].description)
    end)

    t.it("merges an Other text field into its choice", function()
      local parsed = schema.parse({
        type = "object",
        properties = {
          answer = { type = "string", enum = { "yes", "no" } },
          answer_custom = { type = "string", title = "Something else" },
        },
      })
      t.truthy(parsed)
      t.eq(1, #parsed.fields)
      t.eq("answer_custom", parsed.fields[1].custom_key)
      t.eq("Something else", parsed.fields[1].custom_title)
    end)

    t.it("parses arrays as multi-select with bounds", function()
      local parsed = schema.parse({
        type = "object",
        properties = {
          tags = { type = "array", items = { enum = { "a", "b", "c" } }, minItems = 1, maxItems = 2 },
        },
      })
      t.truthy(parsed)
      local field = field_by_key(parsed, "tags")
      t.eq("multi", field.kind)
      t.eq(1, field.min_items)
      t.eq(2, field.max_items)
    end)

    t.it("parses scalar field types", function()
      local parsed = schema.parse({
        type = "object",
        properties = {
          flag = { type = "boolean" },
          count = { type = "integer", minimum = 1, maximum = 3 },
          name = { type = "string", minLength = 2 },
        },
      })
      t.truthy(parsed)
      t.eq("boolean", field_by_key(parsed, "flag").kind)
      t.eq("integer", field_by_key(parsed, "count").kind)
      t.eq("text", field_by_key(parsed, "name").kind)
    end)

    t.it("declines nested objects and empty schemas", function()
      t.falsy(schema.parse({ type = "object", properties = { nested = { type = "object" } } }))
      t.falsy(schema.parse({ type = "object", properties = {} }))
      t.falsy(schema.parse({}))
    end)

    t.it("validates required, length, pattern, number and format", function()
      local parsed = schema.parse({
        type = "object",
        properties = {
          mail = { type = "string", format = "email" },
          age = { type = "integer", minimum = 18 },
          code = { type = "string", pattern = "^%u+$" },
          name = { type = "string", minLength = 3 },
        },
        required = { "name" },
      })
      local ok, err = schema.validate(parsed.fields, {})
      t.falsy(ok)
      t.match("required", err)
      ok, err = schema.validate(parsed.fields, { name = "ab" })
      t.falsy(ok)
      t.match("at least 3", err)
      ok, err = schema.validate(parsed.fields, { name = "abc", mail = "nope" })
      t.falsy(ok)
      t.match("email", err)
      ok, err = schema.validate(parsed.fields, { name = "abc", code = "abc" })
      t.falsy(ok)
      t.match("pattern", err)
      ok, err = schema.validate(parsed.fields, { name = "abc", age = "17" })
      t.falsy(ok)
      t.match("at least 18", err)
    end)

    t.it("converts numbers and merges the custom answer", function()
      local parsed = schema.parse({
        type = "object",
        properties = {
          count = { type = "integer" },
          choice = { type = "string", enum = { "a" } },
          choice_custom = { type = "string" },
        },
      })
      local ok, content = schema.validate(parsed.fields, {
        count = "3",
        choice_custom = "mine",
      })
      t.truthy(ok, content)
      t.eq(3, content.count)
      t.eq("mine", content.choice)
    end)

    t.it("checks multi-select bounds", function()
      local parsed = schema.parse({
        type = "object",
        properties = { tags = { type = "array", items = { enum = { "a", "b", "c" } }, minItems = 2 } },
      })
      local ok, err = schema.validate(parsed.fields, { tags = { "a" } })
      t.falsy(ok)
      t.match("at least 2", err)
    end)
  end)
end
