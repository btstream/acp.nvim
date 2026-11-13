return function(t)
  local form = require("acp.ui.form")
  local picker = require("acp.ui.picker")

  local function with_picker(stub, fn)
    local original = picker.select
    picker.select = stub
    local ok, err = pcall(fn)
    picker.select = original
    if not ok then
      error(err, 0)
    end
  end

  t.describe("elicitation form", function()
    t.it("turns a single choice into one picker", function()
      with_picker(function(opts)
        t.eq("Which database?", opts.title)
        t.eq(2, #opts.items)
        opts.on_choice(opts.items[2].value)
      end, function()
        local content
        local opened = form.open({
          message = "Which database?",
          requestedSchema = {
            type = "object",
            properties = { db = { type = "string", enum = { "Postgres", "Redis" } } },
            required = { "db" },
          },
        }, {
          on_submit = function(value)
            content = value
          end,
          on_cancel = function() end,
          on_decline = function() end,
          notify = function() end,
        })
        t.truthy(opened)
        t.eq({ db = "Redis" }, content)
      end)
    end)

    t.it("reports a cancellation from the picker", function()
      with_picker(function(opts)
        opts.on_cancel()
      end, function()
        local cancelled = false
        form.open({
          message = "Pick",
          requestedSchema = {
            type = "object",
            properties = { db = { type = "string", enum = { "a" } } },
          },
        }, {
          on_submit = function() end,
          on_cancel = function()
            cancelled = true
          end,
          on_decline = function() end,
          notify = function() end,
        })
        t.truthy(cancelled)
      end)
    end)

    t.it("declines an unsupported schema", function()
      local declined = false
      local opened = form.open(
        { requestedSchema = { type = "object", properties = { nested = { type = "object" } } } },
        {
          on_submit = function() end,
          on_cancel = function() end,
          on_decline = function()
            declined = true
          end,
          notify = function() end,
        }
      )
      t.falsy(opened)
      t.truthy(declined)
    end)
  end)
end
