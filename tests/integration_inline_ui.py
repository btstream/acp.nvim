"""Attached UI: Visual mapping, ranged command, close/resize and current session."""
import logging
from pathlib import Path
import tempfile
import time

import pynvim

logging.disable(logging.CRITICAL)
ROOT = str(Path(__file__).resolve().parent.parent)
state = tempfile.TemporaryDirectory(prefix="acp-inline-ui-", dir="/tmp/opencode")
nvim = pynvim.attach("child", argv=["env", "XDG_STATE_HOME=" + state.name,
    "nvim", "--embed", "-u", "NONE", "-i", "NONE", "--noplugin"])


def wait(expr):
    deadline = time.time() + 12
    while time.time() < deadline:
        if nvim.exec_lua("return (" + expr + ") and true or false"):
            return
        time.sleep(0.02)
    raise AssertionError("timed out: " + expr)


try:
    nvim.ui_attach(100, 30, rgb=True, ext_linegrid=True)
    nvim.exec_lua("""
        local root = ...
        vim.opt.rtp:append(root)
        vim.g.mapleader = ' '
        vim.notify = function() end
        require('acp').setup({
          agents={opencode={command='python3',args={root..'/tests/mock_agent.py'}}},
          inline={review={mode='diff'}},
        })
        vim.cmd('runtime plugin/acp.lua')
        require('acp').open()
    """, ROOT)
    wait("require('acp.controller').state().session ~= nil")
    nvim.exec_lua("""
        vim.cmd('wincmd p')
        vim.cmd('new')
        source = vim.api.nvim_get_current_buf()
        source_win = vim.api.nvim_get_current_win()
        session = require('acp.controller').state().session
        require('acp.controller').state().client.new_session = function() error('new session forbidden') end
        vim.api.nvim_buf_set_lines(source,0,-1,false,{'before','INLINE_OLD','after'})
        vim.api.nvim_win_set_cursor(0,{2,0})
    """)
    nvim.input("V ai")
    wait("vim.bo.filetype == 'acp_inline' and vim.fn.mode() == 'i'")
    nvim.input("replace marker<CR>")
    wait("require('acp.inline.diff_session').active(source)")
    assert nvim.exec_lua("return vim.api.nvim_buf_get_lines(source,0,-1,false)") == ["before", "INLINE_OLD", "after"]
    nvim.input("ga")
    wait("not require('acp.inline.diff_session').active(source)")
    assert nvim.exec_lua("return vim.api.nvim_buf_get_lines(source,0,-1,false)") == ["before", "INLINE_NEW", "after"]
    print("ok: real Visual mapping captures selection, enters insert, and reviews without touching source")

    nvim.input("u")
    wait("vim.api.nvim_buf_get_lines(source,1,2,false)[1] == 'INLINE_OLD'")
    nvim.command("2,2Acp inline write")
    wait("vim.bo.filetype == 'acp_inline' and vim.fn.mode() == 'i'")
    nvim.input("replace marker<CR>")
    wait("vim.api.nvim_buf_get_lines(source,1,2,false)[1] == 'INLINE_NEW'")
    wait("not require('acp.inline').is_active()")
    assert nvim.exec_lua("return require('acp.controller').state().session == session")
    print("ok: ranged command and explicit write reuse the current session")

    nvim.exec_lua("vim.api.nvim_buf_call(source,function() vim.cmd('silent undo') end)")
    wait("vim.api.nvim_buf_get_lines(source,1,2,false)[1] == 'INLINE_OLD'")
    tabs_before = len(nvim.exec_lua("return vim.api.nvim_list_tabpages()"))
    nvim.command("2,2Acp inline diff")
    wait("vim.bo.filetype == 'acp_inline' and vim.fn.mode() == 'i'")
    nvim.input("replace marker<CR>")
    wait("require('acp.inline.diff_session').active(source)")
    wait("vim.bo.filetype == 'acp_inline_review'")
    review = nvim.exec_lua("""
        local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
        local text = table.concat(lines, "\\n")
        return {text = text, two_columns = text:find("│", 1, true) ~= nil,
          unchanged_left = text:find("before", 1, true) ~= nil,
          proposal_right = text:find("INLINE_NEW", 1, true) ~= nil,
          tabs = #vim.api.nvim_list_tabpages(),
          marks = #vim.api.nvim_buf_get_extmarks(0,
            vim.api.nvim_get_namespaces()["acp.inline.review"], 0, -1, {})}
    """)
    assert review["two_columns"], review
    assert review["unchanged_left"], review
    assert review["proposal_right"], review
    assert review["marks"] > 0, review
    assert review["tabs"] == tabs_before + 1, review
    print("ok: review opens in its own tab as a whole-file two-column buffer")

    # The cursor starts on the only changed row, so gr rejects that hunk.
    nvim.input("gr")
    wait("not require('acp.inline.diff_session').active(source)")
    wait("vim.bo.filetype ~= 'acp_inline_review'")
    assert len(nvim.exec_lua("return vim.api.nvim_list_tabpages()")) == tabs_before, "review tab was left open"
    assert nvim.exec_lua("return vim.api.nvim_buf_get_lines(source,0,-1,false)") == ["before", "INLINE_OLD", "after"]
    print("ok: rejecting the hunk leaves the source untouched and closes the review tab")

    nvim.exec_lua("""
        local config = require('acp.controller').state().config
        config.inline.window.review.target = 'float'
        vim.api.nvim_set_current_win(source_win)
        vim.api.nvim_win_set_cursor(0,{2,0})
        require('acp.inline').open({review='diff',mode='V',pos1={0,2,1,0},pos2={0,2,1,0}})
    """)
    wait("vim.bo.filetype == 'acp_inline' and vim.fn.mode() == 'i'")
    nvim.input("replace marker<CR>")
    wait("require('acp.inline.diff_session').active(source)")
    wait("vim.bo.filetype == 'acp_inline_review'")
    assert nvim.exec_lua("return vim.api.nvim_win_get_config(0).relative") == "editor"
    assert len(nvim.exec_lua("return vim.api.nvim_list_tabpages()")) == tabs_before, "float review opened a tab"
    nvim.input("gr")
    wait("not require('acp.inline.diff_session').active(source)")
    nvim.exec_lua("require('acp.controller').state().config.inline.window.review.target = 'buffer'")
    print("ok: review.target chooses between a tab buffer and a float")

    nvim.command("Acp inline")
    wait("vim.bo.filetype == 'acp_inline' and vim.fn.mode() == 'i'")
    nvim.input("draft")
    wait("require('acp.inline.ui').text() == 'draft'")
    nvim.exec_lua("vim.api.nvim_win_close(0,true)")
    wait("not require('acp.inline').is_active()")
    nvim.command("Acp inline")
    wait("vim.bo.filetype == 'acp_inline'")
    assert nvim.exec_lua("return require('acp.inline.ui').text()") == "draft"
    nvim.ui_try_resize(25, 10)
    nvim.exec_lua("require('acp.inline.ui').reposition()")
    assert nvim.exec_lua("return vim.api.nvim_win_get_width(0)") <= 23
    assert nvim.exec_lua("return vim.api.nvim_win_get_width(0) + 2 <= vim.o.columns")
    nvim.input("<Esc>")
    wait("not require('acp.inline').is_active()")
    print("ok: closing releases ownership, restores draft and supports a narrow attached UI")

    nvim.exec_lua("""
        local config = require('acp.controller').state().config
        config.inline.window.border = 'double'
        config.inline.window.title_pos = 'center'
        config.inline.window.highlights.title = 'MyInlineTitle'
        config.inline.window.prompt.width = 30
        config.inline.window.prompt.height = 2
        config.inline.window.prompt.follow_cursor = true
        vim.api.nvim_set_current_win(source_win)
        vim.api.nvim_win_set_cursor(0,{2,0})
        require('acp.inline').open({review='diff',mode='V',pos1={0,2,1,0},pos2={0,2,1,0}})
    """)
    wait("vim.bo.filetype == 'acp_inline' and vim.fn.mode() == 'i'")
    appearance = nvim.exec_lua("""
        local config = vim.api.nvim_win_get_config(0)
        local screen = vim.fn.screenpos(source_win, 2, 1)
        return {border = config.border, title_pos = config.title_pos,
          width = vim.api.nvim_win_get_width(0), row = config.row,
          cursor_row = screen.row - 1, winhl = vim.wo.winhighlight}
    """)
    assert len(appearance["border"]) == 8, appearance
    assert appearance["border"][0] == "╔", appearance
    assert appearance["title_pos"] == "center", appearance
    assert appearance["width"] <= 30, appearance
    assert "FloatTitle:MyInlineTitle" in appearance["winhl"], appearance
    assert appearance["row"] > appearance["cursor_row"], appearance
    print("ok: border, title position, width and highlight groups come from config")

    before = nvim.exec_lua("return vim.api.nvim_win_get_config(0).row")
    nvim.exec_lua("vim.api.nvim_set_current_win(source_win); vim.api.nvim_win_set_cursor(0,{1,0}); "
                  "vim.api.nvim_exec_autocmds('CursorMoved',{})")
    wait("vim.api.nvim_win_get_config(0).row ~= " + str(before))
    print("ok: the prompt follows the cursor instead of a fixed screen row")
    nvim.exec_lua("require('acp.inline').stop()")
    wait("not require('acp.inline').is_active()")

    nvim.exec_lua("""
        require('acp.controller').disconnect()
        local original = function() end
        vim.keymap.set('n','zx',original)
        require('acp').setup({keymaps={inline={normal='zx',visual=false}}})
        assert(vim.fn.maparg('zx','n',false,true).callback ~= original)
        require('acp').setup({keymaps={inline={normal=false,visual=false}}})
        assert(vim.fn.maparg('zx','n',false,true).callback == original, 'original mapping not restored')
        require('acp').setup({keymaps={inline={normal='zx',visual=false}}})
        local user = function() end
        vim.keymap.set('n','zx',user)
        require('acp').setup({keymaps={inline={normal=false,visual=false}}})
        assert(vim.fn.maparg('zx','n',false,true).callback == user, 'new user mapping overwritten')
    """)
    print("ok: reconfiguration restores old mappings without overwriting newer user mappings")
finally:
    try:
        nvim.command("qa!")
    except (EOFError, OSError):
        pass
    nvim.close()
    state.cleanup()
