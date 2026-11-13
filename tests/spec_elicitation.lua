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

    t.it("edits a choice field that has no custom counterpart", function()
      local choices = {}
      with_picker(function(opts)
        choices[#choices + 1] = opts
      end, function()
        local content
        form.open({
          message = "m",
          requestedSchema = {
            type = "object",
            properties = {
              a = { type = "string", title = "A", enum = { "x", "y" } },
              b = { type = "string", title = "B" },
            },
          },
        }, {
          on_submit = function(value)
            content = value
          end,
          on_cancel = function() end,
          on_decline = function() end,
          notify = function() end,
        })
        local win
        for _, candidate in ipairs(vim.api.nvim_list_wins()) do
          if vim.b[vim.api.nvim_win_get_buf(candidate)].acp_form then
            win = candidate
          end
        end
        t.truthy(win, "form window not found")
        vim.api.nvim_set_current_win(win)
        vim.api.nvim_win_set_cursor(win, { 3, 0 }) -- message, blank, then A
        vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "x", false)
        vim.wait(50)
        t.truthy(choices[1], "the choice picker did not open")
        -- Regression: a choice without `_custom` used to index a nil key.
        local ok, err = pcall(choices[1].on_choice, "x")
        t.truthy(ok, tostring(err))
        vim.api.nvim_set_current_win(win)
        vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<C-s>", true, false, true), "x", false)
        vim.wait(50)
        t.eq("x", (content or {}).a)
        form.dismiss()
      end)
    end)

    t.it("settles the request when the form window is closed directly", function()
      local cancelled = false
      form.open({
        message = "m",
        requestedSchema = {
          type = "object",
          properties = { a = { type = "string", title = "A" }, b = { type = "string", title = "B" } },
        },
      }, {
        on_submit = function() end,
        on_cancel = function()
          cancelled = true
        end,
        on_decline = function() end,
        notify = function() end,
      })
      local win
      for _, candidate in ipairs(vim.api.nvim_list_wins()) do
        if vim.b[vim.api.nvim_win_get_buf(candidate)].acp_form then
          win = candidate
        end
      end
      t.truthy(win, "form window not found")
      vim.api.nvim_win_close(win, true)
      vim.wait(200, function()
        return cancelled
      end)
      t.truthy(cancelled, "closing the window left the request pending")
    end)

    t.it("ignores input callbacks that arrive after the form closed", function()
      local choices = {}
      with_picker(function(opts)
        choices[#choices + 1] = opts
      end, function()
        local submitted = false
        form.open({
          message = "m",
          requestedSchema = {
            type = "object",
            properties = { a = { type = "string", title = "A", enum = { "x" } }, b = { type = "string" } },
          },
        }, {
          on_submit = function()
            submitted = true
          end,
          on_cancel = function() end,
          on_decline = function() end,
          notify = function() end,
        })
        local win
        for _, candidate in ipairs(vim.api.nvim_list_wins()) do
          if vim.b[vim.api.nvim_win_get_buf(candidate)].acp_form then
            win = candidate
          end
        end
        t.truthy(win, "form window not found")
        vim.api.nvim_set_current_win(win)
        vim.api.nvim_win_set_cursor(win, { 3, 0 })
        vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "x", false)
        vim.wait(50)
        form.dismiss()
        local ok = pcall(choices[1].on_choice, "x")
        t.truthy(ok, "a late choice raised instead of being ignored")
        t.falsy(submitted)
      end)
    end)
  end)
end
