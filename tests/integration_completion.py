"""Real completion frontends in an attached UI (optional dependency: pynvim).

python3 tests/integration_completion.py blink /path/to/blink.cmp [/path/to/blink.lib]
python3 tests/integration_completion.py cmp /path/to/nvim-cmp
python3 tests/integration_completion.py native
"""

import logging
from pathlib import Path
import sys
import tempfile
import threading

import pynvim


logging.disable(logging.CRITICAL)
ROOT = str(Path(__file__).resolve().parent.parent)
ENGINE = sys.argv[1]
assert ENGINE in ("blink", "cmp", "native")
# Every extra argument is a runtimepath entry: blink.cmp v2 also needs blink.lib.
DEPS = [str(Path(arg).resolve()) for arg in sys.argv[2:]]
nvim = pynvim.attach("child", argv=["nvim", "--embed", "-u", "NONE", "-i", "NONE", "--noplugin"])


def wait_for(label, expression):
    result = []
    expired = threading.Event()

    def notification(method, args):
        if method == "acp_completion_test":
            result.append(args[0])
            nvim.stop_loop()

    def timeout():
        expired.set()
        nvim.async_call(nvim.stop_loop)

    nvim.exec_lua(
        """
        local expression, channel = ...
        local predicate = assert(loadstring('return function() ' .. expression .. ' end'))()
        local attempts = 0
        local function probe()
          attempts = attempts + 1
          local ok, value = pcall(predicate)
          if not ok or value or attempts > 150 then
            vim.rpcnotify(channel, 'acp_completion_test', {
              ok = ok, value = value or false,
              messages = vim.fn.execute('messages'), line = vim.api.nvim_get_current_line(),
            })
          else vim.defer_fn(probe, 20) end
        end
        vim.defer_fn(probe, 20)
        """,
        expression,
        nvim.channel_id,
    )
    deadline = threading.Timer(8, timeout)
    deadline.start()
    try:
        nvim.run_loop(None, notification)
    finally:
        deadline.cancel()
    assert not expired.is_set() and result, f"{label}: editor did not respond"
    assert result[0]["ok"] and result[0]["value"], f"{label}: {result[0]}"
    print(f"ok {ENGINE}: {label}")


def reset(text, col=None):
    nvim.exec_lua(
        r"""
        local text, col = ...
        if test_engine == 'blink' then require('blink.cmp').hide()
        elseif test_engine == 'cmp' then require('cmp').abort()
        else vim.api.nvim_feedkeys(vim.keycode('<C-e>'), 'n', false) end
        vim.api.nvim_buf_set_lines(test_buf, 0, -1, false, { '' })
        vim.api.nvim_win_set_cursor(0, { 1, 0 })
        vim.cmd('startinsert')
        _G.test_typing_done = false
        local chars, index = vim.fn.split(text, '\\zs'), 1
        local function type_next()
          if index <= #chars then
            vim.api.nvim_input(chars[index])
            index = index + 1
            vim.defer_fn(type_next, 8)
          else
            if type(col) == 'number' then
              vim.api.nvim_win_set_cursor(0, { 1, col })
              if test_engine == 'blink' then require('blink.cmp').show()
              elseif test_engine == 'cmp' then require('cmp').complete() end
            end
            if test_engine == 'native' then vim.api.nvim_input('<C-x><C-u>') end
            _G.test_typing_done = true
          end
        end
        vim.defer_fn(type_next, 8)
        """,
        text,
        col,
    )


def complete(text, label, expected, col=None):
    reset(text, col)
    wait_for(
        f"candidate {label}",
        f"if not test_typing_done then return false end; for _, item in ipairs(test_items()) do if item.label == {label!r} then return true end end",
    )
    nvim.exec_lua(
        """
        local target = ...
        local index
        for i, item in ipairs(test_items()) do if item.label == target then index = i; break end end
        assert(index, 'selected candidate disappeared')
        if test_engine == 'blink' then require('blink.cmp').accept({ index = index })
        elseif test_engine == 'cmp' then
          local cmp = require('cmp')
          for _ = 1, index do cmp.select_next_item({ behavior = cmp.SelectBehavior.Select }) end
          cmp.confirm({ select = false })
        else
          local keys = string.rep(vim.keycode('<C-n>'), index) .. vim.keycode('<C-y>')
          vim.api.nvim_feedkeys(keys, 'n', false)
        end
        """,
        label,
    )
    wait_for("accepted edit", f"return vim.api.nvim_get_current_line() == {expected!r}")
    assert len(nvim.current.buffer[:]) == 1, "accepting a candidate submitted or inserted a newline"


try:
    with tempfile.TemporaryDirectory(prefix="completion-ui-", dir="/tmp/opencode") as temp:
        project = Path(temp)
        (project / "many").mkdir()
        for i in range(260):
            (project / "many" / f"file{i}.lua").write_text("test\n")
        for name in ("deep/nested/z-last-target.lua", "docs/中文 file.txt", "lua/测试.lua", "Makefile"):
            path = project / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("test\n")
        nvim.ui_attach(100, 30, rgb=True, ext_linegrid=True)
        nvim.exec_lua(
            """
            local root, deps, engine, project = ...
            vim.opt.runtimepath:append(root)
            for _, dep in ipairs(deps) do vim.opt.runtimepath:append(dep) end
            _G.test_engine = engine
            if engine == 'blink' then
              require('blink.cmp').setup({
                fuzzy = { implementation = 'lua' },
                keymap = { preset = 'none', ['<CR>'] = { 'accept', 'fallback' } },
                completion = { list = { selection = { preselect = false, auto_insert = false } } },
                sources = { per_filetype = { acp_input = { 'acp' } }, providers = { acp = { name = 'ACP', module = 'acp.completion.blink' } } },
              })
              _G.test_items = function() return require('blink.cmp').get_items() end
            elseif engine == 'cmp' then
              vim.cmd('runtime plugin/cmp.lua')
              local cmp = require('cmp')
              require('acp.completion.cmp').setup()
              cmp.setup({
                snippet = { expand = function() error('unexpected snippet') end },
                preselect = cmp.PreselectMode.None,
                sources = { { name = 'acp', keyword_length = 0 } },
                matching = { disallow_symbol_nonprefix_matching = false },
                mapping = { ['<CR>'] = cmp.mapping.confirm({ select = false }) },
              })
              _G.test_items = function()
                local items = {}
                for _, entry in ipairs(cmp.get_entries()) do items[#items + 1] = entry:get_completion_item() end
                return items
              end
            else
              _G.test_items = function()
                local items = {}
                for _, item in ipairs(vim.fn.complete_info({ 'items' }).items) do items[#items + 1] = { label = item.abbr } end
                return items
              end
            end
            local config = require('acp.config')
            _G.test_cfg = config.validate(config.merge(config.defaults, { completion = { files = { root = project } } }))
            _G.test_session = { cwd = project, commands = { {name = 'compact', description = 'Compact history'}, {name = 'init'} } }
            local input = require('acp.ui.input').new({ config = test_cfg })
            _G.test_buf = input.buf
            _G.test_sent = 0
            require('acp.ui.keymaps').attach_input(test_buf, { config = test_cfg, keymaps = test_cfg.keymaps.input,
              get_session = function() return test_session end, on_send = function() test_sent = test_sent + 1 end })
            vim.api.nvim_win_set_buf(0, test_buf)
            vim.cmd('startinsert')
            """,
            ROOT,
            DEPS,
            ENGINE,
            str(project),
        )
        wait_for("input mode", "return vim.fn.mode():sub(1,1) == 'i'")
        complete("/com", "/compact", "/compact")
        complete("@zlasttarget", "deep/nested/z-last-target.lua", "@deep/nested/z-last-target.lua")
        complete("read @中文", "docs/中文 file.txt", 'read @"docs/中文 file.txt"')
        complete("你好 @lu/old.lua tail", "lua/测试.lua", "你好 @lua/测试.lua tail", len("你好 @lu".encode()))
        complete("@Make", "Makefile", "@Makefile")
        attached = nvim.exec_lua("return #require('acp.context').mentions(vim.api.nvim_get_current_line(), test_cfg, test_session.cwd)")
        assert attached == 1, "accepted extensionless file did not become an attachment"
        if ENGINE != "native":
            reset("/com")
            wait_for("command menu for Enter confirmation", "return test_typing_done and #test_items() == 1")
            nvim.exec_lua("if test_engine == 'blink' then require('blink.cmp').select_next() else require('cmp').select_next_item({behavior = require('cmp').SelectBehavior.Select}) end")
            wait_for("selected command", "if test_engine == 'blink' then return require('blink.cmp').get_selected_item() ~= nil else return require('cmp').get_selected_entry() ~= nil end")
            nvim.input("<CR>")
            wait_for("Enter confirms without sending", "return vim.api.nvim_get_current_line() == '/compact' and test_sent == 0")
            assert len(nvim.current.buffer[:]) == 1
        nvim.input("<C-s>")
        wait_for("ACP send key remains available", "return test_sent == 1")
        print(f"all {ENGINE} attached-UI completion checks passed")
finally:
    try:
        nvim.command("qa!")
    except (EOFError, OSError):
        pass
    nvim.close()
