"""Attached UI: Visual mapping, ranged command, side-by-side review and the card fallback."""
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
    deadline = time.time() + 15
    while time.time() < deadline:
        if nvim.exec_lua("return (" + expr + ") and true or false"):
            return
        time.sleep(0.02)
    raise AssertionError("timed out: " + expr)


def tabs():
    return len(nvim.exec_lua("return vim.api.nvim_list_tabpages()"))


try:
    nvim.ui_attach(140, 40, rgb=True, ext_linegrid=True)
    nvim.exec_lua("""
        local root = ...
        vim.opt.rtp:append(root)
        vim.g.mapleader = ' '
        vim.notify = function(m, l)
          if l and l >= 3 then _G.last_notice = tostring(m) end
        end
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
        vim.bo[source].filetype = 'lua'
        vim.api.nvim_win_set_cursor(0,{2,0})
    """)

    # --- Visual mapping -> insert prompt -> side-by-side review ------------
    nvim.input("V ai")
    wait("vim.bo.filetype == 'acp_inline' and vim.fn.mode() == 'i'")
    nvim.input("replace marker<CR>")
    wait("require('acp.inline.diff_session').active(source)")
    assert nvim.exec_lua("return vim.api.nvim_buf_get_lines(source,0,-1,false)") == ["before", "INLINE_OLD", "after"]

    layout = nvim.exec_lua("""
        local wins = vim.api.nvim_tabpage_list_wins(0)
        local info = {count = #wins, diff = 0, types = {}, winbars = {}}
        for _, win in ipairs(wins) do
          if vim.wo[win].diff then info.diff = info.diff + 1 end
          info.types[#info.types + 1] = vim.bo[vim.api.nvim_win_get_buf(win)].filetype
          info.winbars[#info.winbars + 1] = vim.wo[win].winbar
        end
        return info
    """)
    assert layout["count"] == 3, layout
    # Not Vim's diff mode: columns are aligned by padding instead.
    assert layout["diff"] == 0, layout
    assert all(t == "lua" for t in layout["types"]), layout
    # The decision count is shown once, on the result column.
    assert sum("pending" in (w or "") for w in layout["winbars"]) == 1, layout
    assert any("AcpReviewBadgeOriginal" in (w or "") for w in layout["winbars"]), layout
    assert any("AcpReviewBadgeResult" in (w or "") for w in layout["winbars"]), layout
    assert any("AcpReviewBadgeProposal" in (w or "") for w in layout["winbars"]), layout
    print("ok: each pane has its own badge, the result column the decision counter")
    diffopt = nvim.exec_lua("return {vim.o.diffopt, vim.api.nvim_get_option_info2('diffopt', {}).default}")
    assert diffopt[0] == diffopt[1], diffopt
    print("ok: review leaves diffopt alone")
    print("ok: review opens three aligned windows with the file's own filetype")

    result_buf = nvim.exec_lua("return vim.api.nvim_get_current_buf()")
    assert nvim.exec_lua("return vim.api.nvim_buf_get_lines(%d,0,-1,false)" % result_buf) == \
        ["before", "INLINE_OLD", "after"]
    # `]c` moves to the only changed block; `ga` accepts it and, as it was the
    # last pending hunk, settles the review.
    nvim.input("]c")
    assert nvim.exec_lua("return vim.api.nvim_win_get_cursor(0)[1]") == 2
    wait("(require('acp.inline.review.layout').gutter(0).bars[2] or {}).group == 'AcpReviewStateCurrent'")
    print("ok: cursor navigation updates the current-hunk state bar")
    nvim.input("ga")
    wait("not require('acp.inline.diff_session').active(source)")
    wait("vim.api.nvim_buf_get_lines(source,1,2,false)[1] == 'INLINE_NEW'")
    print("ok: native hunk navigation selects the changed block and accepts it")
    print("ok: the accepted hunks are applied once the review finishes")

    nvim.exec_lua("vim.api.nvim_buf_call(source,function() vim.cmd('silent undo') end)")
    wait("vim.api.nvim_buf_get_lines(source,1,2,false)[1] == 'INLINE_OLD'")

    # --- rejecting everything leaves the source untouched ------------------
    nvim.command("2,2Acp inline diff")
    wait("vim.bo.filetype == 'acp_inline' and vim.fn.mode() == 'i'")
    nvim.input("replace marker<CR>")
    wait("require('acp.inline.diff_session').active(source)")
    nvim.input("]c")
    nvim.input("gr")
    wait("not require('acp.inline.diff_session').active(source)")
    assert nvim.exec_lua("return vim.api.nvim_buf_get_lines(source,0,-1,false)") == \
        ["before", "INLINE_OLD", "after"]
    print("ok: rejecting the only hunk leaves the source untouched")

    # --- card fallback on a narrow screen ----------------------------------
    nvim.exec_lua("""
        local config = require('acp.controller').state().config
        config.inline.window.review.min_split_width = 10000
        vim.api.nvim_set_current_win(source_win)
        vim.api.nvim_win_set_cursor(0,{2,0})
        require('acp.inline').open({review='diff',mode='V',pos1={0,2,1,0},pos2={0,2,1,0}})
    """)
    wait("vim.bo.filetype == 'acp_inline' and vim.fn.mode() == 'i'")
    nvim.input("replace marker<CR>")
    wait("require('acp.inline.diff_session').active(source)")
    wait("vim.bo.filetype == 'acp_inline_review'")
    card = nvim.exec_lua("""
        local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
        local text = table.concat(lines, "\\n")
        return {header = text:find("@@ Hunk 1/1", 1, true) ~= nil,
          proposal = text:find("INLINE_NEW", 1, true) ~= nil,
          context = text:find("before", 1, true) ~= nil and text:find("after", 1, true) ~= nil}
    """)
    assert card["header"], card
    assert card["proposal"], card
    assert card["context"], card
    nvim.input("g3")
    wait("not require('acp.inline.diff_session').active(source)")
    print("ok: a narrow screen falls back to the card renderer")

    nvim.exec_lua("""
        require('acp.controller').state().config.inline.window.review.min_split_width = 90
        vim.api.nvim_set_current_win(source_win)
        vim.api.nvim_win_set_cursor(0,{2,0})
    """)

    # --- prompt window appearance -------------------------------------------
    nvim.exec_lua("""
        local config = require('acp.controller').state().config
        config.inline.window.border = 'double'
        config.inline.window.title_pos = 'center'
        config.inline.window.highlights.title = 'MyInlineTitle'
        config.inline.window.prompt.width = 30
        config.inline.window.prompt.height = 2
        config.inline.window.prompt.follow_cursor = true
        require('acp.inline').open({review='write',mode='V',pos1={0,2,1,0},pos2={0,2,1,0}})
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

    # EOF insertion has no result-side line until accepted; the result column
    # shows filler on its display row. It must still be reachable and
    # decidable without falling back to accept/reject-all.
    for mode in ("2-column", "3-column"):
        for action in ("ga", "gr"):
            nvim.exec_lua("""
                local mode = ...
                vim.api.nvim_set_current_win(source_win)
                vim.api.nvim_buf_set_lines(source, 0, -1, false, {'before','after'})
                local config = require('acp.controller').state().config
                config.inline.window.review.layout = mode
                assert(require('acp.inline.diff_session').open({
                  bufnr=source, lines={'before','after','APPENDED'}, config=config,
                }))
            """, mode)
            nvim.input("]c")
            wait("vim.api.nvim_win_get_cursor(0)[1] == 3")
            nvim.input(action)
            wait("not require('acp.inline.diff_session').active(source)")
            expected = ["before", "after"] + (["APPENDED"] if action == "ga" else [])
            assert nvim.exec_lua("return vim.api.nvim_buf_get_lines(source,0,-1,false)") == expected
    print("ok: both layouts navigate and decide EOF insertions individually")

    # `winfixbuf` must reject every way of swapping the buffer of a review
    # pane, most importantly the result column.
    nvim.exec_lua("""
        vim.api.nvim_set_current_win(source_win)
        vim.api.nvim_buf_set_lines(source, 0, -1, false, {'alpha','beta','gamma'})
        local config = require('acp.controller').state().config
        assert(require('acp.inline.diff_session').open({
          bufnr=source, lines={'alpha','BETA','gamma'}, config=config,
        }))
    """)
    wait("require('acp.inline.diff_session').active(source)")
    for win in nvim.exec_lua("return vim.api.nvim_tabpage_list_wins(0)"):
        before = nvim.exec_lua("return vim.api.nvim_win_get_buf(...)", win)
        for command in ("edit /tmp/opencode/should-not-open.lua", "enew", "bnext"):
            result = nvim.exec_lua("""
                local win, cmd = ...
                local ok, err = pcall(function()
                  vim.api.nvim_win_call(win, function() vim.cmd(cmd) end)
                end)
                return { ok = ok, err = tostring(err) }
            """, win, command)
            ok, err = result["ok"], result["err"]
            assert not ok, (command, win, err)
            assert "E1513" in str(err), (command, err)
            assert nvim.exec_lua("return vim.api.nvim_win_get_buf(...)", win) == before
            assert nvim.exec_lua("return vim.api.nvim_buf_is_valid(...)", before)
            assert nvim.exec_lua("return vim.api.nvim_get_option_value('winfixbuf', {win=...})", win)
    # A review must not linger half-alive either, and closing the tab is still
    # allowed even though every pane is pinned.
    nvim.exec_lua("vim.cmd('tabclose')")
    wait("not require('acp.inline.diff_session').active(source)")
    print("ok: review panes are pinned to their buffers and reject edits without blocking close")

    # Popups opened while a review runs must not inherit its window options and
    # join the diff.
    nvim.exec_lua("""
        vim.api.nvim_set_current_win(source_win)
        vim.api.nvim_buf_set_lines(source, 0, -1, false, {'alpha','beta','gamma'})
        local config = require('acp.controller').state().config
        assert(require('acp.inline.diff_session').open({
          bufnr=source, lines={'alpha','BETA','gamma'}, config=config,
        }))
    """)
    wait("require('acp.inline.diff_session').active(source)")
    leaked = nvim.exec_lua("""
        local win = vim.api.nvim_open_win(vim.api.nvim_create_buf(false, true), false, {
          relative='editor', row=1, col=1, width=20, height=3, style='minimal',
        })
        local out = {
          diff = vim.api.nvim_get_option_value('diff', {win=win}),
          winhl = vim.api.nvim_get_option_value('winhighlight', {win=win}),
        }
        vim.api.nvim_win_close(win, true)
        return out
    """)
    assert leaked["diff"] is False, leaked
    assert "AcpReview" not in leaked["winhl"], leaked
    nvim.exec_lua("vim.cmd('tabclose')")
    wait("not require('acp.inline.diff_session').active(source)")
    print("ok: a float opened during review does not inherit diff or review window highlights")

    nvim.exec_lua("""
        vim.api.nvim_set_current_win(source_win)
        vim.api.nvim_win_set_cursor(0,{2,0})
    """)
    nvim.exec_lua("""
        local old = {}
        for i = 1, 24 do old[i] = 'old line ' .. i end
        local edited = vim.deepcopy(old)
        edited[3], edited[10], edited[20] = 'changed 3', 'changed 10', 'changed 20'
        table.insert(edited, 4, 'inserted')
        vim.api.nvim_buf_set_lines(source, 0, -1, false, old)
        local config = require('acp.controller').state().config
        config.inline.window.review.layout = '3-column'
        assert(require('acp.inline.diff_session').open({bufnr=source, lines=edited, config=config}))
        review_result_win = vim.api.nvim_get_current_win()
    """)
    for key, row in (("]c", 3), ("ga", 3), ("]c", 11), ("]h", 21), ("[h", 11)):
        nvim.input(key)
        wait("vim.api.nvim_win_get_cursor(0)[1] == " + str(row))
    nvim.exec_lua("""
        local panes = vim.api.nvim_tabpage_list_wins(0)
        table.sort(panes, function(a, b)
          return vim.api.nvim_win_get_position(a)[2] < vim.api.nvim_win_get_position(b)[2]
        end)
        vim.api.nvim_set_current_win(panes[1])
        vim.api.nvim_win_set_cursor(0, {1, 0})
    """)
    side_win = nvim.exec_lua("return vim.api.nvim_get_current_win()")
    nvim.input("]c")
    wait("vim.api.nvim_get_current_win() == %d and vim.api.nvim_win_get_cursor(0)[1] == 3" % side_win)
    print("ok: hunk order survives accepted insertions and side-pane navigation stays in its column")
    filler = nvim.exec_lua("""
        local ns = vim.api.nvim_get_namespaces()['acp.inline.review']
        local out = {}
        for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
          for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(vim.api.nvim_win_get_buf(win), ns, 0, -1, {details=true})) do
            if mark[4].line_hl_group then
              local group = mark[4].line_hl_group
              out[#out + 1] = {name=group, fg=vim.api.nvim_get_hl(0, {name=group, link=false}).fg}
            end
          end
        end
        return out
    """)
    assert filler, "the insertion must leave filler in the original column"
    for pane in filler:
        assert pane["name"] == "AcpReviewFiller", pane
        assert pane["fg"] == 0x5C6370, pane
    print("ok: filler rows use the fixed subdued grey, not the normal white foreground")
    nvim.exec_lua("require('acp.inline.diff_session').close_all()")
finally:
    try:
        nvim.command("qa!")
    except (EOFError, OSError):
        pass
    nvim.close()
    state.cleanup()
