"""Attached UI: inspect actual grid RGB attributes, not highlight IDs or names."""
import logging
from pathlib import Path
import tempfile

import pynvim

logging.disable(logging.CRITICAL)
ROOT = str(Path(__file__).resolve().parent.parent)
state = tempfile.TemporaryDirectory(prefix="acp-inline-hl-", dir="/tmp/opencode")
nvim = pynvim.attach("child", argv=["env", "XDG_STATE_HOME=" + state.name,
    "nvim", "--embed", "-u", "NONE", "-i", "NONE", "--noplugin"])
attrs, cells = {}, {}


def notification(name, args):
    if name == "acp_probe_done":
        nvim.stop_loop()
    if name != "redraw":
        return
    for event in args:
        for item in event[1:]:
            if event[0] == "hl_attr_define":
                attrs[item[0]] = item[1]
            elif event[0] == "grid_line":
                grid, row, col, line = item[:4]
                hl = 0
                for cell in line:
                    if len(cell) > 1:
                        hl = cell[1]
                    for _ in range(cell[2] if len(cell) > 2 else 1):
                        cells[(grid, row, col)] = (cell[0], hl)
                        col += 1
            elif event[0] == "grid_clear":
                for key in list(cells):
                    if key[0] == item[0]:
                        del cells[key]
            elif event[0] == "grid_scroll":
                grid, top, bottom, left, right, rows, cols = item
                previous = dict(cells)
                for row in range(top, bottom):
                    for col in range(left, right):
                        source_row, source_col = row + rows, col + cols
                        cells[(grid, row, col)] = previous.get((grid, source_row, source_col), (" ", 0)) \
                            if top <= source_row < bottom and left <= source_col < right else (" ", 0)


def flush():
    nvim.exec_lua("vim.cmd('redraw!'); vim.rpcnotify(..., 'acp_probe_done')", nvim.channel_id)
    nvim.run_loop(None, notification)


def cell(row, col):
    text, hl = cells[(1, row - 1, col - 1)]
    return text, attrs[hl]


NORMAL, CURSOR = 0x202020, 0x2a2a2a
ADD, DELETE, PENDING = 0x123456, 0x654321, 0x345678
ADD_TEXT = 0x0000aa
FILLER_FG, FILLER_BG = 0x778899, 0x102030
DIMMED_FG = 0x555555
STATE_FG = {"Pending": 0xddaa33, "Current": 0x33aadd, "Accepted": 0x55dd77, "Rejected": 0xdd5577}
FILLER = "filler"

# Display rows (identical in every column):
#   3  '' -> 'CHANGED'          modify, whole-line rewrite (no char marks)
#   6  ... 'EXTRA ' inserted    modify, char marks on the proposal side
#   10 'line 10' removed        delete
#   16 'ADDED'                  add
# Each stage applies one more decision on top of the previous ones.
STAGES = [
    ("pending", None),
    ("delete accepted", (10, "ga")),
    ("add accepted", (16, "ga")),
    ("first modify rejected", (3, "gr")),
]


def expected(role, stage, row):
    """Row background per column and decision, as `align.decorations` paints it."""
    done = [name for name, _ in STAGES[1:STAGES.index(next(x for x in STAGES if x[0] == stage)) + 1]]
    accepted = {10: "delete accepted" in done, 16: "add accepted" in done}
    rejected = {3: "first modify rejected" in done}
    if role == "original":
        return {3: NORMAL if rejected[3] else DELETE, 6: DELETE,
                10: "dimmed" if accepted[10] else DELETE, 16: FILLER}[row]
    if role == "proposal":
        return {3: "dimmed" if rejected[3] else ADD, 6: ADD, 10: FILLER, 16: ADD}[row]
    return {3: NORMAL if rejected[3] else PENDING, 6: PENDING,
            10: FILLER if accepted[10] else PENDING, 16: ADD if accepted[16] else FILLER}[row]


def bar_state(stage, row):
    done = [name for name, _ in STAGES[1:STAGES.index(next(x for x in STAGES if x[0] == stage)) + 1]]
    return {10: "Accepted" if "delete accepted" in done else "Pending",
            16: "Accepted" if "add accepted" in done else "Pending",
            3: "Rejected" if "first modify rejected" in done else "Pending",
            6: "Pending"}[row]


try:
    nvim.ui_attach(150, 40, rgb=True, ext_linegrid=True)
    nvim.exec_lua("""
        vim.opt.rtp:append(...)
        vim.o.termguicolors = true
        vim.api.nvim_set_hl(0, 'Normal', {bg='#202020', fg='#eeeeee'})
        vim.api.nvim_set_hl(0, 'DiffChange', {bg='#ff0000', underline=true})
        vim.api.nvim_set_hl(0, 'DiffText', {bg='#990000', undercurl=true})
        -- Theme cursor line with an underline: it must not be mirrored across
        -- the columns.
        vim.api.nvim_set_hl(0, 'CursorLine', {bg='#2a2a2a', underline=true})
        require('acp.ui.highlights').setup({
          AcpReviewAdd={bg='#123456'}, AcpReviewDelete={bg='#654321'},
          AcpReviewPending={bg='#345678'}, AcpReviewAddText={bg='#0000aa'},
          AcpReviewDeleteText={bg='#aa0000'},
          AcpReviewFiller={fg='#778899', bg='#102030'},
          AcpReviewDimmed={fg='#555555'},
          AcpReviewStatePending={fg='#ddaa33'}, AcpReviewStateCurrent={fg='#33aadd'},
          AcpInlineAccepted={fg='#55dd77'}, AcpInlineRejected={fg='#dd5577'},
          AcpReviewGutterCur={fg='#eeeeee'}, AcpReviewGutter={fg='#777777'},
        })
        old = {}
        for i=1,22 do old[i]='line '..i end
        old[3] = ''
        old[6] = 'prefix line 6 suffix'
        edited=vim.deepcopy(old)
        edited[3]='CHANGED'; edited[6]='prefix line 6 EXTRA suffix'
        table.remove(edited,10); table.insert(edited,15,'ADDED')
        source=vim.api.nvim_create_buf(false,true)
        vim.api.nvim_buf_set_lines(source,0,-1,false,old)
        vim.api.nvim_set_current_buf(source)
        local C=require('acp.config')
        config=C.merge(C.defaults,{inline={window={review={fold=false,min_split_width=20,hints=false}}}})
    """, ROOT)
    for mode in ("2-column", "3-column"):
        nvim.exec_lua("""
            config.inline.window.review.layout = ...
            assert(require('acp.inline.diff_session').open({bufnr=source, lines=edited, config=config}))
            result_win=vim.api.nvim_get_current_win()
        """, mode)
        for stage, action in STAGES:
            if action:
                row, key = action
                nvim.exec_lua("vim.api.nvim_set_current_win(result_win); vim.api.nvim_win_set_cursor(0, {..., 0})", row)
                nvim.exec_lua("vim.fn.maparg(..., 'n', false, true).callback()", key)
                # Park the cursor on context so the cursor line does not cover
                # the rows under test.
                nvim.exec_lua("vim.api.nvim_win_set_cursor(result_win, {1, 0})")
            for theme_event in (False, True):
                if theme_event:
                    nvim.exec_lua("vim.api.nvim_exec_autocmds('ColorScheme', {})")
                flush()
                panes = nvim.exec_lua("""
                    local out={}
                    for _,w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
                      local bar=vim.wo[w].winbar
                      local p={role=bar:find('BadgeOriginal',1,true) and 'original'
                        or (bar:find('BadgeProposal',1,true) and 'proposal' or 'result'), pos={},
                        diff=vim.wo[w].diff}
                      for _,r in ipairs({1,2,3,4,6,10,11,16,17}) do
                        p.pos[tostring(r)]=vim.fn.screenpos(w,r,1)
                      end
                      p.width=require('acp.inline.review.layout').gutter(vim.api.nvim_win_get_buf(w)).width
                      out[#out+1]=p
                    end
                    return out
                """)
                for pane in panes:
                    role = pane["role"]
                    assert not pane["diff"], (mode, role, "pane is in Vim diff mode")
                    rows = [pane["pos"][str(r)]["row"] for r in (1, 2, 3, 4, 6, 10, 11, 16, 17)]
                    # Padding keeps every display row on its own screen row.
                    assert rows == sorted(rows) and len(set(rows)) == len(rows), (mode, role, rows)
                    for row in (2, 4, 11, 17):
                        pos = pane["pos"][str(row)]
                        for col in range(pos["col"], pos["col"] + 20):
                            _, rgb = cell(pos["row"], col)
                            assert rgb.get("background", NORMAL) == NORMAL, (mode, stage, role, row, col, rgb)
                    # The cursor line: theme background, no underline, in every column.
                    pos = pane["pos"]["1"]
                    for col in range(pos["col"], pos["col"] + 20):
                        _, rgb = cell(pos["row"], col)
                        assert rgb.get("background") == CURSOR, (mode, stage, role, "cursorline", rgb)
                        assert not rgb.get("underline"), (mode, stage, role, "cursorline underline", rgb)
                    for row in (3, 6, 10, 16):
                        want = expected(role, stage, row)
                        pos = pane["pos"][str(row)]
                        for col in range(pos["col"], pos["col"] + 28):
                            text, rgb = cell(pos["row"], col)
                            assert not rgb.get("underline") and not rgb.get("undercurl"), (mode, stage, role, row, rgb)
                            if want == FILLER:
                                assert text == "╱", (mode, stage, role, row, col, text)
                                assert (rgb.get("foreground"), rgb.get("background")) == (FILLER_FG, FILLER_BG), rgb
                            elif want == "dimmed":
                                assert rgb.get("background", NORMAL) == NORMAL, (mode, stage, role, row, rgb)
                                assert rgb.get("foreground") == DIMMED_FG, (mode, stage, role, row, rgb)
                            else:
                                bg = want
                                # 'EXTRA ' is the only changed run inside a paired row.
                                offset = col - pos["col"]
                                if row == 6 and want == ADD and 14 <= offset < 20:
                                    bg = ADD_TEXT
                                assert rgb.get("background", NORMAL) == bg, \
                                    (mode, stage, role, row, col, rgb, hex(bg) if isinstance(bg, int) else bg)
                        # State bar: first cell of the gutter, coloured by decision.
                        bar_col = pos["col"] - pane["width"] - 2
                        glyph, rgb = cell(pos["row"], bar_col)
                        st = bar_state(stage, row)
                        assert rgb.get("foreground") == STATE_FG[st], (mode, stage, role, row, glyph, rgb, st)
                        assert glyph == {"Accepted": "✓", "Rejected": "✗"}.get(st, "▎"), (mode, stage, role, row, glyph)
                        # Filler rows have no line number.
                        number = "".join(cell(pos["row"], c)[0] for c in range(bar_col + 1, pos["col"])).strip()
                        assert (number == "") == (want == FILLER), (mode, stage, role, row, repr(number))
        nvim.exec_lua("require('acp.inline.diff_session').close_all()")
        print("ok: " + mode + " aligns columns with filler, paints each side by decision, marks changed characters and state bars")
finally:
    try:
        nvim.command("qa!")
    except (EOFError, OSError):
        pass
    nvim.close()
    state.cleanup()
