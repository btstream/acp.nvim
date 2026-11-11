"""Attached-UI thought collapse and mouse overscroll regression.

Run: python3 tests/integration_tail.py (optional dependency: pynvim).
"""

import logging
from pathlib import Path
import threading

import pynvim


logging.disable(logging.CRITICAL)
ROOT = str(Path(__file__).resolve().parent.parent)
nvim = pynvim.attach(
    "child", argv=["nvim", "--embed", "-u", "NONE", "-i", "NONE", "--noplugin"]
)
grid = {}


def phase(label, action, marker=None, align="bottom"):
    result = []
    marker_rows = []
    expired = threading.Event()

    def notification(method, args):
        if method == "redraw":
            for event in args:
                if event[0] == "grid_line":
                    for line in event[1:]:
                        _, row, col, cells = line[:4]
                        for cell in cells:
                            for _ in range(cell[2] if len(cell) > 2 else 1):
                                grid[(row, col)] = cell[0]
                                col += 1
                elif event[0] == "flush" and marker:
                    for row in range(30):
                        text = "".join(grid.get((row, col), " ") for col in range(100))
                        if marker in text:
                            marker_rows.append(row)
        elif method == "acp_tail_done":
            result.append(args[0])
            nvim.stop_loop()

    def timeout():
        expired.set()
        nvim.async_call(nvim.stop_loop)

    nvim.exec_lua(
        action
        + f"""
        vim.defer_fn(function()
          local c = tail_test
          local info = vim.fn.getwininfo(c.win)[1]
          local count = vim.api.nvim_buf_line_count(c.buf)
          local view = vim.api.nvim_win_call(c.win, vim.fn.winsaveview)
          vim.rpcnotify({nvim.channel_id}, 'acp_tail_done', {{
            count = count,
            bottom = info.winrow + info.winbar + info.height - 1,
            top = info.winrow + info.winbar,
            first_row = vim.fn.screenpos(c.win, 1, 1).row,
            eof_row = vim.fn.screenpos(c.win, count, 1).row,
            follow = c.follow,
            mode = vim.fn.mode(), focused_win = vim.api.nvim_get_current_win(), chat_win = c.win,
            width = info.width, textoff = info.textoff, screen_height = info.height,
            topline = view.topline, topfill = view.topfill, skipcol = view.skipcol,
            last = vim.api.nvim_buf_get_lines(c.buf, -2, -1, false)[1],
          }})
        end, 150)
        """
    )
    deadline = threading.Timer(8, timeout)
    deadline.start()
    try:
        nvim.run_loop(None, notification)
    finally:
        deadline.cancel()
    assert not expired.is_set() and result, f"{label}: editor did not respond"
    stats = result[0]
    if align == "top":
        assert stats["first_row"] == stats["top"] and stats["topline"] == 1, f"{label}: short text not at top: {stats}"
        assert stats["topfill"] == 0 and stats["skipcol"] == 0, f"{label}: artificial top space: {stats}"
    else:
        assert stats["eof_row"] == stats["bottom"], f"{label}: blank space below EOF: {stats}"
    assert stats["last"] == "", f"{label}: trailing buffer blank line was lost"
    if marker:
        assert all(row == stats["bottom"] - 2 for row in marker_rows), f"{label}: overscroll flashed in UI frames: {marker_rows}"
    print(f"ok {label}: {align}-aligned")
    return stats


def wheel(direction, count):
    return f"""
    local info = vim.fn.getwininfo(tail_test.win)[1]
    for _ = 1, {count} do
      vim.api.nvim_input_mouse('wheel', '{direction}', '', 0,
        info.winrow + info.winbar + 2, info.wincol + 2)
    end
    """


try:
    nvim.ui_attach(100, 30, rgb=True, ext_linegrid=True)
    nvim.exec_lua(
        r"""
        vim.opt.runtimepath:append(...)
        vim.opt.mouse = 'a'
        local cfg = require('acp.config').defaults
        local chat = require('acp.ui.chat').new({ config = cfg })
        chat.win = vim.api.nvim_get_current_win()
        vim.api.nvim_win_set_buf(chat.win, chat.buf)
        vim.wo[chat.win].winbar = 'Transcript'
        vim.wo[chat.win].scrolloff = 2
        vim.wo[chat.win].linebreak = true
        vim.wo[chat.win].breakindent = true
        vim.wo[chat.win].statuscolumn = ' '
        _G.tail_test = chat
        _G.tail_state = require('acp.session.state').new('tail-ui', '/tmp')
        tail_state:track_changes()
        for i = 1, 40 do
          tail_state:append({ id = 'h' .. i, kind = 'agent', text = 'history ' .. i })
        end
        tail_state:append_text('thought', string.rep('reasoning ', 700), 't')
        chat:set_session(tail_state)
        """,
        ROOT,
    )
    phase("wrapped streaming thought", "")
    collapsed = phase("automatic collapse", "tail_state:finish_thought(); tail_test:render()\n")
    title = "".join(grid.get((collapsed["bottom"] - 2, col), " ") for col in range(100))
    assert "Thought" in title, f"collapsed title was not above the trailing blank: {title!r}"
    phase(
        "reply appended after collapse",
        "tail_state:append_text('agent', 'next reply', 'a'); tail_test:render()\n",
    )
    baseline = phase("mouse wheel down at EOF", wheel("down", 15), "next reply")
    again = phase("repeated mouse wheel down at EOF", wheel("down", 15), "next reply")
    for key in ("topline", "topfill", "skipcol"):
        assert baseline[key] == again[key], f"continued scrolling after EOF changed {key}"
    nvim.exec_lua(wheel("up", 5))
    nvim.exec_lua("vim.wait(40)")
    assert not nvim.exec_lua("return tail_test.follow"), "scrolling up did not leave follow mode"
    phase("mouse returns from history to EOF", wheel("down", 40))
    phase(
        "short collapsed thought",
        r"""
        _G.tail_state = require('acp.session.state').new('short-ui', '/tmp')
        tail_state:track_changes()
        tail_state:append_text('thought', string.rep('reasoning\n', 40), 't')
        tail_test:set_session(tail_state)
        tail_state:finish_thought()
        tail_test:render()
        """,
        align="top",
    )
    short = phase("mouse wheel down on short transcript", wheel("down", 15), align="top")
    assert short["count"] == 2, "display padding leaked into buffer lines"
    phase(
        "short reply keeps following",
        "tail_test:scroll_to_bottom(); tail_state:append_text('agent', 'short reply', 'a'); tail_test:render()\n",
        align="top",
    )
    phase(
        "coalesced collapse and oversized wrapped reply",
        r"""
        _G.tail_state = require('acp.session.state').new('coalesced-ui', '/tmp')
        tail_state:track_changes()
        tail_state:append_text('thought', string.rep('reasoning\n', 40), 't')
        tail_test:set_session(tail_state)
        tail_state:append_text('agent', string.rep('wrapped reply ', 300), 'a')
        tail_test:render()
        """,
    )
    typing = phase(
        "non-current transcript while typing",
        "vim.cmd('vsplit'); vim.api.nvim_win_set_buf(0, vim.api.nvim_create_buf(false, true)); vim.cmd('startinsert')\n",
    )
    assert typing["mode"].startswith("i") and typing["focused_win"] != typing["chat_win"]
    continued = phase(
        "tail update preserves input focus and insert mode",
        "tail_state:append_text('thought', string.rep('more thinking ', 100), 't2'); tail_state:finish_thought(); tail_test:render()\n",
    )
    assert continued["mode"].startswith("i"), "tail anchoring left input insert mode"
    assert continued["focused_win"] == typing["focused_win"], "tail anchoring stole input focus"
    print("all attached-UI transcript tail checks passed")
finally:
    try:
        nvim.command("qa!")
    except (EOFError, OSError):
        pass
    nvim.close()
