return function(t)
  local schema = require("acp.elicitation_schema")

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

    t.it("declines nested objects, non-table properties and empty schemas", function()
      t.falsy(schema.parse({ type = "object", properties = { nested = { type = "object" } } }))
      t.falsy(schema.parse({ type = "object", properties = { broken = true } }))
      t.falsy(schema.parse({ type = "object", properties = { broken = "text" } }))
      t.falsy(schema.parse({ type = "object", properties = {} }))
      t.falsy(schema.parse({}))
    end)

    t.it("keeps agent order instead of sorting by title", function()
      local parsed = schema.parse({
        type = "object",
        properties = {
          question_2 = { type = "string", enum = { "a" } },
          question_10 = { type = "string", enum = { "b" } },
          question_1 = { type = "string", enum = { "c" } },
        },
      })
      local keys = {}
      for _, field in ipairs(parsed.fields) do
        keys[#keys + 1] = field.key
      end
      t.eq({ "question_1", "question_2", "question_10" }, keys)
    end)

    t.it("counts characters, not bytes, for length limits", function()
      local parsed = schema.parse({ type = "object", properties = { name = { type = "string", minLength = 3 } } })
      local ok, err = schema.validate(parsed.fields, { name = "中文" })
      t.falsy(ok)
      t.match("at least 3", err)
      t.truthy(schema.validate(parsed.fields, { name = "中文字" }))
    end)

    t.it("tolerates patterns Lua cannot parse", function()
      -- `[a-z]{2,4}` is valid ECMA-262 but never matches as a Lua pattern; a
      -- trailing `%` raises. Neither may abort submission.
      local parsed = schema.parse({ type = "object", properties = { n = { type = "string", pattern = "^%" } } })
      t.truthy(schema.validate(parsed.fields, { n = "anything" }))
      local braces = schema.parse({ type = "object", properties = { n = { type = "string", pattern = "[a-z]{2,4}" } } })
      t.truthy(schema.validate(braces.fields, { n = "abc" }))
    end)

    t.it("validates required, length, pattern, number and format", function()
      local parsed = schema.parse({
        type = "object",
        properties = {
          mail = { type = "string", format = "email" },
          age = { type = "integer", minimum = 18 },
          code = { type = "string", pattern = "^[A-Z]+$" },
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

    t.it("accepts Other as the answer for a required choice", function()
      local parsed = schema.parse({
        type = "object",
        properties = {
          database = { type = "string", oneOf = { { const = "postgres" } } },
          database_custom = { type = "string" },
        },
        required = { "database" },
      })
      local ok, content = schema.validate(parsed.fields, { database_custom = "mysql" })
      t.truthy(ok, tostring(content))
      t.eq("mysql", content.database)
    end)

    t.it("sends the chosen option and its note together", function()
      local parsed = schema.parse({
        type = "object",
        properties = {
          database = { type = "string", oneOf = { { const = "postgres" } } },
          database_custom = { type = "string" },
        },
      })
      local ok, content = schema.validate(parsed.fields, { database = "postgres", database_custom = "add sqlite" })
      t.truthy(ok, tostring(content))
      t.eq("postgres", content.database)
      t.eq("add sqlite", content.database_custom)
    end)

    t.it("rejects a choice that is not one of the options", function()
      local parsed = schema.parse({ type = "object", properties = { db = { type = "string", enum = { "pg" } } } })
      local ok, err = schema.validate(parsed.fields, { db = "mysql" })
      t.falsy(ok)
      t.match("offered options", err)
    end)

    t.it("keeps a custom answer for a free-text field", function()
      local parsed = schema.parse({
        type = "object",
        properties = { note = { type = "string" }, note_custom = { type = "string" } },
        required = { "note" },
      })
      t.truthy(parsed)
      local ok, content = schema.validate(parsed.fields, { note = "typed" })
      t.truthy(ok, tostring(content))
      t.eq("typed", content.note)
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
