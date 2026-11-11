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
    assert nvim.exec_lua("return vim.api.nvim_win_get_width(0)") <= 21
    nvim.input("<Esc>")
    wait("not require('acp.inline').is_active()")
    print("ok: closing releases ownership, restores draft and supports a narrow attached UI")
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
