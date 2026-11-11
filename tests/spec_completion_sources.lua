return function(t)
  local Config = require("acp.config")
  local core = require("acp.completion")
  local files = require("acp.completion.files")
  local mentions = require("acp.completion.mentions")
  local context = require("acp.context")
  local counter = 0

  local function fixture(fn, overrides)
    counter = counter + 1
    local root = "/tmp/opencode/acp-completion-" .. vim.uv.hrtime() .. "-" .. counter
    vim.fn.mkdir(root, "p")
    local config = Config.validate(Config.merge(Config.defaults, {
      completion = { files = { backend = "builtin", root = root } },
    }))
    if overrides then
      config = Config.validate(Config.merge(config, overrides))
    end
    local buf = vim.api.nvim_create_buf(false, true)
    local previous = vim.api.nvim_get_current_win()
    local win = vim.api.nvim_open_win(buf, true, { relative = "editor", row = 0, col = 0, width = 60, height = 6 })
    vim.bo[buf].filetype = "acp_input"
    local session =
      { cwd = root, commands = { { name = "compact", description = "Compact history" }, { name = "init" } } }
    require("acp.ui.complete").attach(buf, function()
      return session
    end, config)
    local function write(path, text)
      vim.fn.mkdir(vim.fs.dirname(root .. "/" .. path), "p")
      local fd = assert(io.open(root .. "/" .. path, "wb"))
      fd:write(text or "test\n")
      fd:close()
    end
    local function cursor(text, col)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { text .. " " })
      vim.api.nvim_win_set_cursor(win, { 1, col or #text })
    end
    local function request()
      local result, problem
      local pos = vim.api.nvim_win_get_cursor(win)
      core.request(buf, pos[1] - 1, pos[2], function(items, err)
        result, problem = items, err
      end)
      t.truthy(
        vim.wait(5000, function()
          return result ~= nil
        end, 1),
        "completion did not settle"
      )
      t.eq(nil, problem)
      return result
    end
    local ok, err = pcall(fn, {
      root = root,
      buf = buf,
      win = win,
      config = config,
      session = session,
      write = write,
      cursor = cursor,
      request = request,
      switch = function(value)
        session = value
      end,
    })
    core.detach(buf)
    files.refresh()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
    if vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_delete(buf, { force = true })
    end
    if vim.api.nvim_win_is_valid(previous) then
      vim.api.nvim_set_current_win(previous)
    end
    vim.fn.delete(root, "rf")
    if not ok then
      error(err, 0)
    end
  end

  t.describe("shared completion sources", function()
    t.it("round-trips quoted paths, unicode, spaces, quotes and newline characters", function()
      for _, path in ipairs({
        "Makefile",
        "中文/说明.md",
        "with spaces/file.txt",
        'a"quote.lua',
        "a\\backslash",
        "a\nnewline",
        "a@b.txt",
      }) do
        local token = mentions.tokens("read " .. mentions.encode(path) .. " please")[1]
        t.truthy(token, path)
        t.eq(path, token.path)
      end
      t.eq(0, #mentions.tokens('email@example.com @"\\u0000" @"unterminated'))
    end)

    t.it("recognises only command names and boundary-delimited mentions", function()
      t.eq(nil, core.context("email@example.com", 17))
      t.eq(nil, core.context("https://host/path", 17))
      t.eq(nil, core.context("/compact arguments", 18))
      t.eq("command", core.context("/com", 4).kind)
      local q = core.context('你好 @"dir with space/file.txt" suffix', #'你好 @"dir with spa')
      t.eq("dir with spa", q.query)
      t.eq(#"你好 ", q.first)
      t.eq(#'你好 @"dir with space/file.txt"', q.last)
    end)

    t.it("delivers fresh command descriptions without executing a command", function()
      fixture(function(f)
        f.cursor("/co")
        local items = f.request()
        t.eq(2, #items)
        t.eq("/compact", items[1].textEdit.newText)
        t.eq(0, items[1].textEdit.range.start.character)
        t.eq(3, items[1].textEdit.range["end"].character)
        t.eq("Compact history", items[1].documentation.value)
        f.session.commands = { { name = "new-command" } }
        t.eq("/new-command", f.request()[1].label)
      end)
    end)

    t.it("indexes the full project before any menu cap or fuzzy matching", function()
      fixture(function(f)
        for i = 1, 260 do
          f.write("many/file" .. i .. ".lua")
        end
        f.write("deep/nested/z-last-target.lua")
        f.cursor("@ztarget")
        local items = f.request()
        t.eq(261, #items)
        local labels = {}
        for _, item in ipairs(items) do
          labels[item.label] = true
        end
        t.truthy(labels["deep/nested/z-last-target.lua"])
        local native = core.native_items(items, { kind = "file", query = "zlasttarget" }, 1)
        t.eq(1, #native)
        t.eq("@deep/nested/z-last-target.lua", native[1].word)
      end)
    end)

    t.it("uses session-relative edits and expands extensionless/special paths into attachments", function()
      fixture(function(f)
        f.write("Makefile")
        f.write("docs/中文 file.txt")
        f.session.cwd = f.root .. "/docs"
        f.cursor("see @Ma leftover", #"see @Ma")
        local items = f.request()
        local make
        for _, item in ipairs(items) do
          if item.label == "../Makefile" then
            make = item
          end
        end
        t.truthy(make)
        t.eq("@../Makefile", make.textEdit.newText)
        local text = mentions.encode("../Makefile")
          .. " "
          .. mentions.encode("中文 file.txt")
          .. " @../docs/../Makefile"
        local attached = context.mentions(text, f.config, f.session.cwd)
        t.eq(2, #attached)
        t.eq("Makefile", attached[1].label)
        t.eq("中文 file.txt", attached[2].label)
      end)
    end)

    t.it("uses byte ranges around unicode and replaces the whole existing token", function()
      fixture(function(f)
        f.write("lua/测试.lua")
        f.cursor("你好 @lu/old.lua suffix", #"你好 @lu")
        local item = f.request()[1]
        t.eq(#"你好 ", item.textEdit.range.start.character)
        t.eq(#"你好 @lu/old.lua", item.textEdit.range["end"].character)
        vim.api.nvim_buf_set_text(
          f.buf,
          0,
          item.textEdit.range.start.character,
          0,
          item.textEdit.range["end"].character,
          { item.textEdit.newText }
        )
        t.eq("你好 @lua/测试.lua suffix ", vim.api.nvim_get_current_line())
      end)
    end)

    t.it("invalidates indexes on refresh and observes newly created files", function()
      fixture(function(f)
        f.write("first.txt")
        f.cursor("@")
        t.eq(1, #f.request())
        f.write("second.txt")
        t.eq(1, #f.request())
        core.refresh()
        t.eq(2, #f.request())
      end)
    end)

    t.it("evicts old project indexes at the configured cache budget", function()
      fixture(function(f)
        f.write("first.txt")
        f.write("second/other.txt")
        f.cursor("@")
        t.eq(2, #f.request())
        f.config.completion.files.root = f.root .. "/second"
        t.eq(1, #f.request())
        f.write("new.txt")
        f.config.completion.files.root = f.root
        t.eq(3, #f.request(), "an evicted project index was retained")
      end, { completion = { files = { max_projects = 1 } } })
    end)

    t.it("indexes file symlinks but never traverses directory symlinks", function()
      fixture(function(f)
        f.write("real.txt")
        t.truthy(vim.uv.fs_symlink(f.root .. "/real.txt", f.root .. "/file-link"))
        t.truthy(vim.uv.fs_symlink(f.root, f.root .. "/directory-loop"))
        f.cursor("@")
        local items, labels = f.request(), {}
        for _, item in ipairs(items) do
          labels[item.label] = true
        end
        t.eq(2, #items)
        t.truthy(labels["file-link"])
        t.falsy(labels["directory-loop"])
      end)
    end)

    t.it("keeps framework completion available when the native frontend is disabled", function()
      fixture(function(f)
        t.eq("", vim.bo[f.buf].completefunc)
        t.truthy(core.available(f.buf))
        f.session.commands = { { name = "review.all", description = "Review", input = { hint = "[scope]" } }, vim.NIL }
        f.cursor("/review.")
        local items = f.request()
        t.eq(1, #items)
        t.eq("/review.all", items[1].label)
        t.eq("[scope]", items[1].detail)
      end, { completion = { native = false } })
    end)

    t.it("preserves literal dollar signs and special names through indexing and submission", function()
      fixture(function(f)
        local names = { "$HOME.txt", 'a"quote.txt', "a\\backslash.txt", "a\nnewline.txt", "中文 file.txt" }
        for _, name in ipairs(names) do
          f.write(name)
        end
        f.cursor("@")
        local items, text = f.request(), {}
        t.eq(#names, #items)
        for _, item in ipairs(items) do
          t.falsy(item.label:find("%c"), "completion labels must fit a single menu line")
          text[#text + 1] = item.textEdit.newText
        end
        t.eq(#names, #context.mentions(table.concat(text, " "), f.config, f.root))
      end)
    end)

    t.it("does not publish a slow result after session changes or input edits", function()
      fixture(function(f)
        f.write("file.txt")
        for _, mutate in ipairs({
          function()
            f.switch({ cwd = f.root, commands = {} })
          end,
          function()
            f.cursor("@changed")
          end,
        }) do
          f.cursor("@")
          local result
          core.request(f.buf, 0, 1, function(items)
            result = items
          end)
          mutate()
          t.truthy(vim.wait(2000, function()
            return result ~= nil
          end, 1))
          t.eq(0, #result)
        end
      end)
    end)

    t.it("discards results when the composer becomes read-only or changes filetype", function()
      fixture(function(f)
        for _, option in ipairs({ "modifiable", "filetype" }) do
          f.cursor("/co")
          local result
          core.request(f.buf, 0, 3, function(items)
            result = items
          end)
          if option == "modifiable" then
            vim.bo[f.buf].modifiable = false
          else
            vim.bo[f.buf].filetype = "lua"
          end
          t.truthy(vim.wait(2000, function()
            return result ~= nil
          end, 1))
          t.eq(0, #result)
          vim.bo[f.buf].modifiable = true
          vim.bo[f.buf].filetype = "acp_input"
        end
      end)
    end)

    t.it("supports cancellation and buffer teardown without late results", function()
      fixture(function(f)
        f.cursor("@")
        local calls, count = 0, nil
        local cancel = core.request(f.buf, 0, 1, function(items)
          calls, count = calls + 1, #items
        end)
        cancel()
        core.detach(f.buf)
        vim.wait(20)
        t.eq(1, calls)
        t.eq(0, count)
      end)
    end)

    t.it("reports index overflow instead of silently truncating files", function()
      fixture(function(f)
        for i = 1, 40 do
          f.write("files/file" .. i .. ".txt")
        end
        local result, err
        files.list(f.root, f.config.completion.files, function(paths, problem)
          result, err = paths, problem
        end)
        t.truthy(vim.wait(2000, function()
          return err ~= nil
        end, 1))
        t.eq(nil, result)
        t.match("max_bytes", err)
      end, { completion = { files = { max_bytes = 1024 } } })
    end)

    for _, backend in ipairs({ "rg", "fd", "git" }) do
      if vim.fn.executable(backend) == 1 or (backend == "fd" and vim.fn.executable("fdfind") == 1) then
        t.it("discovers untracked project files and honours ignore/hidden options with " .. backend, function()
          fixture(function(f)
            t.eq(0, vim.system({ "git", "init", "-q", f.root }):wait().code)
            f.write(".gitignore", "ignored/\n")
            f.write("Makefile")
            f.write(".hidden.txt")
            f.write("deep/untracked file.txt")
            f.write("ignored/secret.txt")
            t.eq(0, vim.system({ "git", "-C", f.root, "add", "Makefile" }):wait().code)
            local function list()
              local result, err
              files.list(f.root, f.config.completion.files, function(paths, problem)
                result, err = paths, problem
              end)
              t.truthy(vim.wait(3000, function()
                return result ~= nil or err ~= nil
              end, 1))
              t.eq(nil, err)
              local set = {}
              for _, path in ipairs(result) do
                set[path] = true
                t.falsy(path:match("^%.git/"))
              end
              return set
            end
            local paths = list()
            t.truthy(paths.Makefile)
            t.truthy(paths["deep/untracked file.txt"])
            t.truthy(paths[".hidden.txt"])
            t.falsy(paths["ignored/secret.txt"])
            f.config.completion.files.hidden = false
            t.falsy(list()[".hidden.txt"])
            f.config.completion.files.ignored = true
            t.truthy(list()["ignored/secret.txt"])
          end, { completion = { files = { backend = backend } } })
        end)
      end
    end

    t.it("drains NUL-delimited process output completely before delivering exit", function()
      fixture(function(f)
        f.config.completion.files.command = {
          "python3",
          "-c",
          "import os,time;os.write(1,b'first');time.sleep(.01);os.write(1,b'.txt\\0'+b''.join(('nested/file%d.txt'%i).encode()+b'\\0' for i in range(700)))",
        }
        local result, err
        files.list(f.root, f.config.completion.files, function(paths, problem)
          result, err = paths, problem
        end)
        t.truthy(vim.wait(3000, function()
          return result ~= nil or err ~= nil
        end, 1))
        t.eq(nil, err)
        t.eq(701, #result)
        t.eq("first.txt", result[1])
        t.eq("nested/file699.txt", result[701])
      end)
    end)

    t.it("shares an in-flight scan and cancels subscribers independently", function()
      fixture(function(f)
        f.config.completion.files.command =
          { "python3", "-c", "import os,time;time.sleep(.02);os.write(1,b'file.txt\\0')" }
        local first, second = false, nil
        local cancel = files.list(f.root, f.config.completion.files, function()
          first = true
        end)
        files.list(f.root, f.config.completion.files, function(paths)
          second = paths
        end)
        cancel()
        t.truthy(vim.wait(3000, function()
          return second ~= nil
        end, 1))
        t.falsy(first)
        t.eq({ "file.txt" }, second)
      end)
    end)

    t.it("does not restart discovery on the cancel-to-next-query handoff", function()
      local system, calls = vim.system, 0
      local ok, problem = pcall(function()
        fixture(function(f)
          f.config.completion.files.command =
            { "python3", "-c", "import os,time;time.sleep(.02);os.write(1,b'file.txt\\0')" }
          vim.system = function(...)
            calls = calls + 1
            return system(...)
          end
          local cancel = files.list(f.root, f.config.completion.files, function() end)
          cancel()
          local result
          files.list(f.root, f.config.completion.files, function(paths)
            result = paths
          end)
          t.truthy(vim.wait(3000, function()
            return result ~= nil
          end, 1))
          t.eq(1, calls, "each keystroke restarted the project scan")
        end)
      end)
      vim.system = system
      if not ok then
        error(problem, 0)
      end
    end)

    t.it("rejects malformed command output and missing executables", function()
      fixture(function(f)
        for _, command in ipairs({
          { "python3", "-c", "print('not NUL delimited')" },
          { "acp-no-such-file-enumerator" },
        }) do
          f.config.completion.files.command = command
          local result, err
          files.list(f.root, f.config.completion.files, function(paths, problem)
            result, err = paths, problem
          end)
          t.truthy(vim.wait(3000, function()
            return err ~= nil
          end, 1))
          t.eq(nil, result)
        end
      end)
    end)

    t.it("validates completion budgets and custom discovery configuration", function()
      for _, override in ipairs({
        { max_items = 0 },
        { picker = "unknown" },
        { files = { backend = "shell" } },
        { files = { max_projects = 1.5 } },
        { files = { max_bytes = 0 } },
        { files = { command = "rg --files" } },
        { files = { command = {} } },
        { files = { root = true } },
        { native = "yes" },
      }) do
        t.falsy(pcall(function()
          Config.validate(Config.merge(Config.defaults, { completion = override }))
        end))
      end
    end)

    t.it("adapts identical candidates to both frameworks without requiring either plugin", function()
      fixture(function(f)
        f.cursor("/co")
        local blink = require("acp.completion.blink").new()
        t.truthy(blink:enabled())
        local a
        blink:get_completions({ bufnr = f.buf, cursor = { 1, 3 } }, function(value)
          a = value
        end)
        t.truthy(vim.wait(2000, function()
          return a ~= nil
        end, 1))
        local cmp = require("acp.completion.cmp").new()
        t.truthy(cmp:is_available())
        t.eq("utf-8", cmp:get_position_encoding_kind())
        local b
        cmp:complete({ context = { bufnr = f.buf, cursor = { row = 1, col = 4 } } }, function(value)
          b = value
        end)
        t.truthy(vim.wait(2000, function()
          return b ~= nil
        end, 1))
        t.eq(a.items, b.items)
        t.truthy(a.is_incomplete_forward)
        t.truthy(b.isIncomplete)
        vim.bo[f.buf].filetype = "lua"
        t.falsy(blink:enabled())
        t.falsy(cmp:is_available())
      end)
    end)

    t.it("inserts a picker selection without opening it or sending the prompt", function()
      fixture(function(f)
        f.write("dir/file with spaces.txt")
        f.cursor("read @old tail", #"read @old")
        local chosen = false
        require("acp.completion.picker").open(f.buf, f.win, {
          select = function(paths, accept)
            t.eq(1, #paths)
            chosen = true
            accept(paths[1])
          end,
        })
        t.truthy(vim.wait(2000, function()
          return chosen and vim.api.nvim_get_current_line():find("file with spaces", 1, true) ~= nil
        end, 1))
        t.eq('read @"dir/file with spaces.txt" tail ', vim.api.nvim_get_current_line())
        t.eq(f.buf, vim.api.nvim_get_current_buf())
        vim.cmd("stopinsert")
      end)
    end)

    t.it("allows a picker to take focus without cancelling its pending insertion", function()
      fixture(function(f)
        f.write("chosen.txt")
        f.cursor("read @old")
        local other
        require("acp.completion.picker").open(f.buf, f.win, {
          select = function(paths, accept)
            local buf = vim.api.nvim_create_buf(false, true)
            vim.bo[buf].bufhidden = "wipe"
            other = vim.api.nvim_open_win(buf, true, { relative = "editor", row = 1, col = 1, width = 30, height = 3 })
            accept(paths[1])
          end,
        })
        t.truthy(vim.wait(2000, function()
          return vim.api.nvim_buf_get_lines(f.buf, 0, 1, false)[1] == "read @chosen.txt "
        end, 1))
        t.eq(f.win, vim.api.nvim_get_current_win())
        t.eq(0, vim.tbl_count(core.binding(f.buf).requests))
        if other and vim.api.nvim_win_is_valid(other) then
          vim.api.nvim_win_close(other, true)
        end
        vim.cmd("stopinsert")
      end)
    end)

    t.it("passes safe labels to fzf-lua and inserts the original selected path", function()
      local old = package.loaded["fzf-lua"]
      local ok, problem = pcall(function()
        fixture(function(f)
          local name = 'dir/line\nbreak "quote".txt'
          f.write(name)
          f.cursor("@old")
          package.loaded["fzf-lua"] = {
            fzf_exec = function(labels, opts)
              t.eq({ mentions.encode(name):sub(2) }, labels)
              t.falsy(labels[1]:find("\n", 1, true))
              opts.actions.default({ labels[1] })
            end,
          }
          require("acp.completion.picker").open(f.buf, f.win, { backend = "fzf-lua" })
          t.truthy(vim.wait(2000, function()
            return vim.api.nvim_get_current_line() == mentions.encode(name) .. " "
          end, 1))
          t.eq(1, vim.api.nvim_buf_line_count(f.buf))
          t.eq(1, #context.mentions(vim.api.nvim_get_current_line(), f.config, f.root))
          vim.cmd("stopinsert")
        end)
      end)
      package.loaded["fzf-lua"] = old
      if not ok then
        error(problem, 0)
      end
    end)

    t.it("rejects a picker acceptance after the session was replaced", function()
      fixture(function(f)
        f.write("file.txt")
        f.cursor("read @old")
        local accept
        require("acp.completion.picker").open(f.buf, f.win, {
          select = function(_, callback)
            accept = callback
          end,
        })
        t.truthy(vim.wait(2000, function()
          return accept ~= nil
        end, 1))
        f.switch({ cwd = f.root })
        accept("file.txt")
        vim.wait(20)
        t.eq("read @old ", vim.api.nvim_get_current_line())
      end)
    end)
  end)
end
