"""Attached-UI check: attaching an image must not disturb the composer.

python3 tests/integration_image_cursor.py

Headless suites cannot observe insert mode or the real screen cursor, so this
drives a real UI. It builds the composer directly instead of starting an agent,
which keeps the check focused on the editor behaviour being verified.
"""

import logging
from pathlib import Path
import time
import sys
import tempfile

import pynvim


logging.disable(logging.CRITICAL)
ROOT = str(Path(__file__).resolve().parent.parent)
USE_EDGY = "edgy" in sys.argv[1:]
state = tempfile.TemporaryDirectory(prefix="acp-image-ui-", dir="/tmp/opencode")
nvim = pynvim.attach("child", argv=["env", "XDG_STATE_HOME=" + state.name, "nvim", "--embed", "-u", "NONE", "-i", "NONE", "--noplugin"])


def wait_for(label, expression, timeout=10):
    deadline = time.time() + timeout
    while time.time() < deadline:
        if nvim.exec_lua("return (" + expression + ") and true or false"):
            return
        time.sleep(0.02)
    raise AssertionError(f"{label}: timed out waiting for {expression}")


def snapshot():
    return nvim.exec_lua(
        """
        return {
          cursor = vim.api.nvim_win_get_cursor(0),
          mode = vim.fn.mode(),
          line = vim.api.nvim_get_current_line(),
          lines = vim.api.nvim_buf_get_lines(test_input.buf, 0, -1, false),
          attachments = #test_input.attachments,
          image_marks = vim.api.nvim_buf_get_extmarks(test_input.buf,
            vim.api.nvim_get_namespaces()['acp.input.images'], 0, -1, {details = true}),
        }
        """
    )


def attach_image(path_lua="test_shot"):
    nvim.exec_lua(
        """
        local context = require('acp.context')
        local att, err = context.image(_G[({ ... })[1]], test_cfg)
        assert(att, err)
        test_input:add_attachment(att)
        """,
        path_lua,
    )


try:
    nvim.ui_attach(100, 30, rgb=True, ext_linegrid=True)

    nvim.exec_lua(
        """
        local root, use_edgy = ...
        vim.notify = function() end -- Notifications must not open a hit-enter prompt.
        vim.opt.runtimepath:append(root)
        local Config = require('acp.config')
        if use_edgy then
          local edgy = vim.fn.expand('~/.local/share/nvim/lazy/edgy.nvim')
          assert(vim.fn.isdirectory(edgy) == 1, 'edgy.nvim is required for this test')
          vim.opt.runtimepath:append(edgy)
          vim.opt.laststatus = 3
          vim.opt.splitkeep = 'screen'
          local opts = { animate = { enabled = false }, options = { right = { size = 55 } } }
          require('acp.integrations.edgy').extend(opts)
          require('edgy').setup(opts)
          require('acp').setup({
            agents = { opencode = { command = 'python3', args = { root .. '/tests/mock_agent.py' } } },
            layout = { backend = 'external', input_height = 6 },
          })
          require('acp').open()
          local st = require('acp.controller').state()
          assert(vim.wait(10000, function() return st.session ~= nil end, 20), 'no session')
          _G.test_cfg, _G.test_input = st.config, st.input
          test_input:clear()
          vim.api.nvim_set_current_win(test_input.win)
        else
          _G.test_cfg = Config.validate(Config.defaults)
          _G.test_input = require('acp.ui.input').new({ config = test_cfg })
        end

        local dir = vim.fn.tempname()
        vim.fn.mkdir(dir, 'p')
        _G.test_shot = dir .. '/shot.png'
        local fh = assert(io.open(test_shot, 'wb'))
        fh:write('\\137PNG\\r\\n\\026\\nDATA')
        fh:close()
        _G.test_clip = dir .. '/clip.png'
        local cf = assert(io.open(test_clip, 'wb'))
        cf:write('\\137PNG\\r\\n\\026\\nCLIP')
        cf:close()

        vim.api.nvim_win_set_buf(0, test_input.buf)
        test_input.win = vim.api.nvim_get_current_win()
        vim.api.nvim_buf_set_lines(test_input.buf, 0, -1, false, { 'hello brave world', 'second line' })
        vim.api.nvim_win_set_cursor(0, { 1, 5 })
        vim.cmd('startinsert')
        """,
        ROOT,
        USE_EDGY,
    )
    wait_for("insert mode", "vim.fn.mode() == 'i'")

    before = snapshot()
    print("before:", before)

    attach_image()
    after = snapshot()
    print("after attach:", after)
    assert after["cursor"] == [1, 14], f"cursor must follow the pasted image token: {after['cursor']}"
    assert after["lines"] == ["hello[Image 1] brave world", "second line"], after
    assert after["mode"] == "i", f"left insert mode: {after['mode']}"
    assert after["attachments"] == 1, "the image was not attached"
    marks = after["image_marks"]
    assert len(marks) == 1 and marks[0][1:3] == [0, 5], f"image is not at the paste cursor: {marks}"
    assert marks[0][3]["end_col"] == 14, "image is not an editable range"
    screen = nvim.exec_lua(
        """
        vim.cmd('redraw!')
        local p = vim.fn.screenpos(test_input.win, 1, 1)
        local chars = {}
        for col = p.col, p.col + 79 do
          chars[#chars + 1] = vim.fn.screenstring(p.row, col)
        end
        return table.concat(chars)
        """
    )
    assert "hello[Image 1] brave world" in screen, f"image is not drawn between the cursor's text: {screen!r}"
    assert marks[0][3]["hl_group"] == "AcpInputImage", marks
    print("ok: real screen draws the image chip at the input cursor, not the winbar")
    print("ok: pasting inserts an editable highlighted token and keeps insert mode")

    # Typing must continue exactly at the cursor, not at the end of the line.
    nvim.input("X")
    wait_for("typed character", "vim.api.nvim_get_current_line():find('X', 1, true) ~= nil")
    typed = nvim.exec_lua("return vim.api.nvim_get_current_line()")
    print("typed:", repr(typed))
    assert typed == "hello[Image 1]X brave world", f"typing went to the wrong place: {typed!r}"
    prompt_text = nvim.exec_lua("return test_input:text()")
    assert prompt_text == "helloX brave world\nsecond line", (prompt_text, snapshot())

    # Both sides of the token are real positions. Backspace/Delete erase the
    # whole attachment, and undo/redo restore/remove both text and metadata.
    nvim.input("<Left>")
    wait_for("move before X", "vim.api.nvim_win_get_cursor(0)[2] == 14")
    nvim.input("<BS>")
    wait_for("backspace removes image", "test_input:text() == 'helloX brave world\\nsecond line' and #test_input.attachments == 0")
    assert snapshot()["line"] == "helloX brave world", snapshot()
    nvim.input("<Esc>u")
    wait_for("undo restores image", "test_input:text() == 'helloX brave world\\nsecond line' and #test_input.attachments == 1")
    nvim.input("<C-r>")
    wait_for("redo removes image", "test_input:text() == 'helloX brave world\\nsecond line' and #test_input.attachments == 0")
    nvim.input("u")
    wait_for("undo restores again", "test_input:text() == 'helloX brave world\\nsecond line' and #test_input.attachments == 1")
    nvim.exec_lua("vim.api.nvim_win_set_cursor(0, {1, 5}); vim.cmd('startinsert')")
    wait_for("insert before image", "vim.fn.mode() == 'i'")
    nvim.input("<Del>")
    wait_for("delete removes image", "test_input:text() == 'helloX brave world\\nsecond line' and #test_input.attachments == 0")
    assert snapshot()["line"] == "helloX brave world", snapshot()
    nvim.exec_lua("vim.api.nvim_win_set_cursor(0, {1, 5})")
    attach_image()
    print("ok: image tokens support cursor movement, Backspace, Delete and undo/redo")

    if USE_EDGY:
        nvim.exec_lua(
            """
            assert(require('acp.controller').paste_image({ command = { 'cat', test_clip } }))
            """
        )
        wait_for("real clipboard callback", "#test_input.attachments == 2")
        actual = snapshot()
        assert any(mark[1:3] == [0, 14] for mark in actual["image_marks"]), actual
        assert actual["mode"] == "i", actual
        assert nvim.exec_lua("return test_input:text()") == "helloX brave world\nsecond line", actual
        bar = nvim.exec_lua("return require('acp.controller').composer_bar(test_input.win)")
        assert "shot.png" not in bar and "clip.png" not in bar, bar
        print("ok: real controller clipboard callback under edgy anchors the image inside input")
        nvim.exec_lua(
            """
            local reader = require('acp.context.clipboard')
            local saved = reader.read
            reader.read = function(_, done) _G.pending_image = done end
            assert(require('acp.controller').paste_image())
            reader.read = saved
            """
        )
        nvim.input("<Esc>")
        wait_for("user exits insert mode", "vim.fn.mode() == 'n'")
        nvim.exec_lua("pending_image('\\137PNG\\r\\n\\026\\nlate', 'image/png', nil)")
        assert snapshot()["mode"] == "n", "late clipboard result forced the user back into insert mode"
        nvim.command("startinsert")
        wait_for("resume insert mode", "vim.fn.mode() == 'i'")
        print("ok: a delayed clipboard result respects the user's explicit exit from insert mode")

    # The mapping must run our handler instead of literal-insert mode.
    nvim.exec_lua(
        """
        local c = test_cfg
        local buf = test_input.buf
        vim.bo[buf].filetype = 'acp_input'
        _G.paste_calls = 0
        require('acp.ui.keymaps').attach_input(buf, {
          config = c,
          keymaps = c.keymaps.input,
          get_session = function() return { cwd = '/tmp/opencode', commands = {} } end,
          on_send = function() end,
          on_cancel = function() end,
          on_hide = function() end,
          on_add_selection = function() end,
          on_pick_model = function() end,
          on_pick_mode = function() end,
          on_pick_session = function() end,
          on_pick_file = function() end,
          on_paste_image = function() paste_calls = paste_calls + 1 end,
          on_paste_image_path = function() return false end,
        })
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'after ctrl-v' })
        vim.api.nvim_win_set_cursor(0, { 1, 0 })
        """,
    )
    before2 = snapshot()
    nvim.input("<C-v>")
    wait_for("handler ran", "_G.paste_calls == 1")
    after2 = snapshot()
    assert after2["cursor"] == before2["cursor"], "the <C-v> mapping moved the cursor"
    assert after2["lines"] == before2["lines"], "the <C-v> mapping inserted a literal character"
    assert after2["mode"] == "i", f"the <C-v> mapping left insert mode: {after2['mode']}"
    print("ok: <C-v> runs the image handler without literal insert or cursor movement")

    print("all attached-UI cursor checks passed")
finally:
    try:
        nvim.command("qa!")
    except (EOFError, OSError):
        pass
    try:
        nvim.close()
    except Exception:
        pass
    state.cleanup()
