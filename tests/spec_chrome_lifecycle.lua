return function(t)
  local controller = require("acp.controller")
  local async = require("acp.async")
  local drafts = require("acp.storage.drafts")

  local function fixture(fn)
    drafts.flush()
    local original_path, original_notify = drafts.path, vim.notify
    drafts.path = function()
      return "/tmp/opencode/acp-chrome-" .. vim.uv.os_getpid() .. ".json"
    end
    drafts.clear()
    vim.notify = function() end
    controller.setup({
      cwd = "/tmp/opencode",
      layout = { focus_input_on_open = false },
      ui = { toolbar = { animation_interval = 10 } },
    })
    local s = controller.state()
    local client = {
      is_ready = function()
        return true
      end,
      shutdown = function() end,
      has_session_capability = function()
        return false
      end,
      load_session = function()
        return true, {}
      end,
      prompt = function()
        return async.await(function() end)
      end,
    }
    s.client, s.connection = client, "ready"
    controller.load_session("chrome-test")
    local ok, err = pcall(fn, s, client)
    controller.setup({}, { discard_queued = true })
    drafts.clear()
    drafts.path, vim.notify = original_path, original_notify
    if not ok then
      error(err, 0)
    end
  end

  local function advances(chrome)
    local frame = chrome.frame
    return vim.wait(300, function()
      return chrome.frame ~= frame
    end, 2)
  end

  t.describe("chrome lifecycle", function()
    t.it("resumes animation when reopening a running session", function()
      fixture(function(s)
        controller.open()
        controller.send_now("run", {})
        t.truthy(s.chrome.timer)
        t.truthy(advances(s.chrome))
        controller.hide()
        t.eq(nil, s.chrome.timer)
        t.eq("running", s.session.status)
        controller.open()
        t.truthy(s.chrome.timer, "reopening must restart the timer")
        t.truthy(advances(s.chrome), "the restored timer must advance frames")
      end)
    end)

    t.it("does not start a timer for a hidden background turn", function()
      fixture(function(s)
        controller.send_now("run hidden", {})
        t.eq(nil, s.chrome.timer)
        controller.open()
        t.truthy(s.chrome.timer)
        t.truthy(advances(s.chrome))
      end)
    end)

    t.it("stops animation for a closed composer and resumes after repair", function()
      fixture(function(s)
        controller.open()
        controller.send_now("run", {})
        vim.api.nvim_win_close(s.input.win, true)
        t.truthy(vim.wait(300, function()
          return s.chrome.timer == nil
        end, 2))
        controller.open()
        t.truthy(s.input:is_visible())
        t.truthy(s.chrome.timer)
        t.truthy(advances(s.chrome))
      end)
    end)

    t.it("leaves an idle session without an animation timer", function()
      fixture(function(s)
        controller.open()
        t.eq(nil, s.chrome.timer)
        controller.hide()
        controller.open()
        t.eq(nil, s.chrome.timer)
      end)
    end)

    t.it("keeps one timer across repeated opens", function()
      fixture(function(s)
        controller.open()
        controller.send_now("run", {})
        local timer = s.chrome.timer
        for _ = 1, 20 do
          controller.open()
        end
        t.eq(timer, s.chrome.timer)
        t.truthy(timer:is_active())
        t.falsy(timer:is_closing())
      end)
    end)

    t.it("repairs a stopped animation when the editor regains focus", function()
      fixture(function(s)
        controller.open()
        controller.send_now("run", {})
        local old = s.chrome.timer
        old:stop()
        vim.api.nvim_exec_autocmds("FocusGained", { modeline = false })
        t.truthy(vim.wait(300, function()
          return s.chrome.timer ~= old
        end, 2))
        t.truthy(old:is_closing())
        t.truthy(advances(s.chrome))
      end)
    end)

    t.it("pauses for an inactive tab and resumes on returning", function()
      fixture(function(s)
        controller.open()
        controller.send_now("run", {})
        local original_tab = vim.api.nvim_get_current_tabpage()
        vim.cmd("tabnew")
        local other = vim.api.nvim_get_current_tabpage()
        local ok, err = pcall(function()
          t.truthy(vim.wait(300, function()
            return s.chrome.timer == nil
          end, 2))
          vim.api.nvim_set_current_tabpage(original_tab)
          t.truthy(vim.wait(300, function()
            return s.chrome.timer ~= nil
          end, 2))
          t.truthy(advances(s.chrome))
        end)
        if vim.api.nvim_tabpage_is_valid(other) then
          vim.api.nvim_set_current_tabpage(other)
          vim.cmd("tabclose")
        end
        if not ok then
          error(err, 0)
        end
      end)
    end)

    t.it("does not repaint or restart a destroyed chrome instance", function()
      fixture(function(s)
        controller.open()
        controller.send_now("run", {})
        local old = s.chrome
        local applied, original_apply = 0, old.apply
        old.apply = function(self)
          applied = applied + 1
          return original_apply(self)
        end
        old:refresh()
        controller.setup({ cwd = "/tmp/opencode" })
        vim.wait(30)
        t.eq(0, applied, "queued refresh from the old instance must be discarded")
        t.eq(nil, old.timer)
        old:sync_animation(true)
        t.eq(nil, old.timer)
      end)
    end)

    t.it("does not reinstall keymaps or completion when windows reopen", function()
      fixture(function(s)
        local complete = require("acp.ui.complete")
        local calls, attaches, original, original_attach = 0, 0, vim.keymap.set, complete.attach
        vim.keymap.set = function(mode, lhs, rhs, opts)
          if
            opts
            and (opts.buffer == s.input.buf or opts.buffer == s.chat.buf)
            and opts.desc
            and opts.desc:match("^acp:")
          then
            calls = calls + 1
          end
          return original(mode, lhs, rhs, opts)
        end
        complete.attach = function(...)
          attaches = attaches + 1
          return original_attach(...)
        end
        local ok, err = pcall(function()
          controller.open()
          for _ = 1, 20 do
            controller.open()
          end
          controller.hide()
          controller.open()
          vim.api.nvim_win_close(s.input.win, true)
          controller.open()
        end)
        vim.keymap.set = original
        complete.attach = original_attach
        if not ok then
          error(err)
        end
        t.eq(0, calls, "buffer mappings should already be installed by setup")
        t.eq(0, attaches, "completion should not be reattached on window operations")
        t.truthy(s.input:is_visible())
        t.truthy(vim.bo[s.input.buf].completefunc ~= "")
      end)
    end)

    t.it("installs the selection attachment mapping as Ctrl-]", function()
      fixture(function(s)
        local mapping = vim.api.nvim_buf_call(s.input.buf, function()
          return vim.fn.maparg("<C-]>", "n", false, true)
        end)
        t.eq("acp: add selection", mapping.desc)
        t.eq(1, mapping.buffer)
        t.eq("function", type(mapping.callback))
      end)
    end)
  end)

  t.describe("catalog lifecycle", function()
    t.it("releases a cancelled refresh lock without losing cached metadata", function()
      fixture(function(s, client)
        local requests, replies = 0, {}
        client.has_session_capability = function()
          return true
        end
        client.list_sessions = function()
          requests = requests + 1
          return async.await(function(done)
            replies[#replies + 1] = done
          end)
        end
        s.catalog:cache_title(s.session.id, "cached")
        s.catalog:refresh_title(s.session)
        s.catalog:refresh_title(s.session)
        t.truthy(s.catalog.refreshing)
        t.truthy(s.catalog.pending)
        controller.disconnect()
        t.eq(false, s.catalog.refreshing)
        t.eq(false, s.catalog.pending)
        t.eq(nil, s.catalog.pending_session)
        t.eq("cached", s.catalog:title(s.session.id))

        s.client, s.connection = client, "ready"
        s.catalog:refresh_title(s.session)
        t.eq(2, requests, "a new connection must be able to refresh again")
        replies[1](true, { sessions = {} })
        vim.wait(20)
        t.truthy(s.catalog.refreshing, "late cleanup must not unlock the new request")
        replies[2](true, { sessions = {} })
        t.truthy(vim.wait(300, function()
          return not s.catalog.refreshing
        end, 2))
      end)
    end)

    t.it("clears metadata when setup creates a new runtime", function()
      fixture(function(s)
        s.titles.old, s.session_cwds.old = "old title", "/tmp/opencode/old-project"
        local old_titles, old_cwds = s.titles, s.session_cwds
        controller.setup({ cwd = "/tmp/opencode/new-project" })
        t.eq(nil, s.catalog:title("old"))
        t.eq(nil, s.catalog:cwd("old"))
        t.falsy(s.titles == old_titles)
        t.falsy(s.session_cwds == old_cwds)
      end)
    end)
  end)
end
