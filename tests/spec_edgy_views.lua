return function(t)
  local edgy_views = require("acp.integrations.edgy")

  local root = vim.fn.fnamemodify(vim.fn.getcwd(), ":p")
  local has_edgy = (function()
    for _, dir in ipairs(vim.api.nvim_list_runtime_paths()) do
      if vim.fn.isdirectory(dir .. "/lua/edgy") == 1 then
        return true
      end
    end
    return false
  end)()

  t.describe("edgy view registration", function()
    t.it("builds array entries, not named keys", function()
      local opts = { right = {} }
      edgy_views.extend(opts)
      -- The array part must hold both views; a named key would be ignored by
      -- edgy, which only iterates `ipairs(views)`.
      t.eq(2, #opts.right)
      local fts = {}
      for _, view in ipairs(opts.right) do
        fts[view.ft] = true
      end
      t.truthy(fts.acp_chat, "acp_chat missing")
      t.truthy(fts.acp_input, "acp_input missing")
    end)

    if not has_edgy then
      t.it("has_view reports false without edgy", function()
        t.falsy(edgy_views.has_view("acp_chat"))
      end)
      t.it("check_registered does not raise without edgy", function()
        edgy_views._checked = nil
        local ok = pcall(edgy_views.check_registered)
        t.truthy(ok)
      end)
      return
    end

    local function with_edgy_config(right, fn)
      package.loaded["edgy.config"] = nil
      local config = require("edgy.config")
      config.setup({ right = right, animate = { enabled = false } })
      edgy_views._checked = nil
      local ok, err = pcall(fn, config)
      package.loaded["edgy.config"] = nil
      edgy_views._checked = nil
      if not ok then
        error(err, 0)
      end
    end

    t.it("detects both views when configured correctly", function()
      with_edgy_config({
        { ft = "acp_chat", title = "Agent" },
        { ft = "acp_input", title = "Message", size = { height = 0.2 } },
      }, function()
        t.truthy(edgy_views.has_view("acp_chat"), "acp_chat not detected")
        t.truthy(edgy_views.has_view("acp_input"), "acp_input not detected")
      end)
    end)

    t.it("detects a view registered by filetype string", function()
      with_edgy_config({ "acp_chat", { ft = "acp_input" } }, function()
        t.truthy(edgy_views.has_view("acp_chat"), "string entry not detected")
        t.truthy(edgy_views.has_view("acp_input"))
      end)
    end)

    t.it("detects the missing view in a named-key config", function()
      -- This is the mistake that leaves the composer outside the edgebar:
      -- `input = {...}` is a named key, so edgy's array part holds only one
      -- view and never builds that position.
      with_edgy_config({
        { ft = "acp_chat", title = "Agent" },
        input = { ft = "acp_input", title = "Message" },
      }, function()
        t.truthy(edgy_views.has_view("acp_chat"), "acp_chat should be found")
        t.falsy(edgy_views.has_view("acp_input"), "acp_input must be reported missing")
      end)
    end)

    t.it("reports nothing when both views are registered", function()
      with_edgy_config({
        { ft = "acp_chat" },
        { ft = "acp_input" },
      }, function()
        local warned = false
        local original = vim.notify
        vim.notify = function(msg, level)
          if level == vim.log.levels.WARN and tostring(msg):find("acp.nvim", 1, true) then
            warned = true
          end
        end
        edgy_views.check_registered()
        vim.wait(200)
        vim.notify = original
        t.falsy(warned, "warned although both views are registered")
      end)
    end)

    t.it("warns when a view is missing", function()
      with_edgy_config({
        { ft = "acp_chat" },
        input = { ft = "acp_input" },
      }, function()
        local messages = {}
        local original = vim.notify
        vim.notify = function(msg, level)
          if level == vim.log.levels.WARN then
            messages[#messages + 1] = tostring(msg)
          end
        end
        edgy_views.check_registered()
        vim.wait(300)
        vim.notify = original
        t.truthy(#messages > 0, "no warning was shown")
        t.match("acp_input", messages[1])
        t.match("array", messages[1])
      end)
    end)

    t.it("warns only once", function()
      with_edgy_config({
        { ft = "acp_chat" },
        input = { ft = "acp_input" },
      }, function()
        local count = 0
        local original = vim.notify
        vim.notify = function(_, level)
          if level == vim.log.levels.WARN then
            count = count + 1
          end
        end
        edgy_views.check_registered()
        edgy_views.check_registered()
        edgy_views.check_registered()
        vim.wait(300)
        vim.notify = original
        t.eq(1, count, "the warning must not repeat")
      end)
    end)
  end)
end
