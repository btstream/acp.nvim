-- Integration test: a real image attachment reaches the agent as an ACP image block.
--
-- ACP_IMAGE_CAPABILITY=1 nvim --headless -i NONE -u tests/minimal_init.lua -l tests/integration_image.lua
--
-- The mock agent only advertises promptCapabilities.image when that variable is
-- set, so this also proves the client refuses the attachment otherwise.
local root = vim.fn.fnamemodify(vim.fn.getcwd(), ":p")

local function wait(cond, timeout, label)
  if not vim.wait(timeout or 8000, cond, 20) then
    error("timed out: " .. (label or "condition"), 2)
  end
end

local acp = require("acp")
local controller = require("acp.controller")
local context = require("acp.context")
local image = require("acp.context.image")

local tmp = "/tmp/opencode/acp-image-integration-" .. tostring(vim.uv.hrtime())
vim.fn.mkdir(tmp, "p")
image.dir = function()
  return tmp .. "/images"
end
require("acp.storage.drafts").path = function()
  return tmp .. "/drafts.json"
end
local png = "\137PNG\r\n\26\n" .. string.rep("\0\1\2\3", 400)
local shot = tmp .. "/shot.png"
do
  local fh = assert(io.open(shot, "wb"))
  fh:write(png)
  fh:close()
end

acp.setup({
  agent = "opencode",
  agents = { opencode = { command = "python3", args = { root .. "tests/mock_agent.py" } } },
  ui = {},
  layout = { input_height = 6 },
})
acp.open()

local failures = {}
local function check(name, fn)
  local ok, err = pcall(fn)
  if not ok then
    failures[#failures + 1] = name .. ": " .. tostring(err)
    io.write("FAIL " .. name .. "\n")
  else
    io.write("ok   " .. name .. "\n")
  end
end

local st = controller.state()
wait(function()
  return st.session ~= nil
end, 8000, "session creation")

local capable = st.client and st.client:supports_prompt("image")

check("client exposes the agent's image capability", function()
  assert(type(capable) == "boolean", "supports_prompt did not return a boolean")
  assert(capable == (os.getenv("ACP_IMAGE_CAPABILITY") == "1"), "capability did not follow the mock agent")
end)

check("attaching an image file adds one image chip and no base64", function()
  -- A restored draft can already hold attachments from an earlier run.
  st.input:clear_attachments()
  assert(acp.add_image(shot), "add_image refused a valid PNG")
  local atts = st.input.attachments
  assert(#atts == 1, "expected one attachment, got " .. #atts)
  assert(atts[1].kind == "image", "wrong attachment kind: " .. tostring(atts[1].kind))
  assert(atts[1].path == shot, "attachment path was not recorded")
  assert(atts[1].block == nil, "attachment must not pre-encode its bytes")
  assert(atts[1].bytes == #png, "byte count mismatch")
end)

check("the composer chip is rendered", function()
  local win = st.input.win
  assert(vim.api.nvim_win_is_valid(win), "composer window missing")
  local ok, err = st.input:apply_winbar()
  assert(ok, tostring(err))
  local marks = vim.api.nvim_buf_get_extmarks(
    st.input.buf,
    vim.api.nvim_get_namespaces()["acp.input.images"],
    0,
    -1,
    { details = true }
  )
  assert(#marks == 1 and marks[1][4].hl_group == "AcpInputImage", "image token must be highlighted in the input buffer")
  assert(not controller.composer_bar(win):find("shot.png", 1, true), "image leaked into the winbar")
end)

check("attaching inserts a token at the cursor without changing prompt text", function()
  -- The editable token belongs in the buffer at the paste position, but must
  -- be stripped from the text passed to the agent.
  -- (Insert mode itself cannot be observed headlessly: `vim.fn.mode()` reports
  -- "n" without an attached UI. `tests/integration_image_cursor.py` covers it.)
  local win = st.input.win
  assert(vim.api.nvim_win_is_valid(win), "composer window missing")
  vim.api.nvim_set_current_win(win)
  vim.api.nvim_buf_set_lines(st.input.buf, 0, -1, false, { "hello brave world", "second line" })
  vim.api.nvim_win_set_cursor(win, { 1, 5 })
  local cursor = vim.api.nvim_win_get_cursor(win)
  local lines = vim.api.nvim_buf_get_lines(st.input.buf, 0, -1, false)

  st.input:clear_attachments()
  assert(acp.add_image(shot), "add_image refused a valid PNG")

  assert(vim.api.nvim_win_get_cursor(win)[2] >= cursor[2], "cursor must stay next to the inserted token")
  assert(st.input:text() == table.concat(lines, "\n"), "attachment token leaked into prompt text")
  assert(#st.input.attachments == 1, "the image was not attached")
end)

check("clipboard paste preserves prompt text and does not steal focus", function()
  local win = st.input.win
  vim.api.nvim_set_current_win(win)
  vim.api.nvim_win_set_cursor(win, { 2, 3 })
  local cursor = vim.api.nvim_win_get_cursor(win)
  local before = #st.input.attachments

  -- A fake reader avoids depending on the machine's clipboard contents.
  controller.paste_image({
    command = { "sh", "-c", "printf '\\211PNG\\r\\n\\032\\nCLIP'" },
  })
  wait(function()
    return #st.input.attachments == before + 1
  end, 8000, "clipboard attachment")

  assert(vim.api.nvim_win_get_cursor(win)[1] == cursor[1], "clipboard paste changed the cursor row")
  assert(st.input:text() == "hello brave world\nsecond line", "clipboard token leaked into prompt text")
  assert(vim.api.nvim_get_current_win() == win, "clipboard paste moved focus")
end)

check("clipboard paste does not drag focus back from another window", function()
  local input_win = st.input.win
  vim.cmd("split")
  local other = vim.api.nvim_get_current_win()
  local before = #st.input.attachments
  controller.paste_image({
    command = { "sh", "-c", "printf '\\211PNG\\r\\n\\032\\nCLIP2'" },
  })
  wait(function()
    return #st.input.attachments == before + 1
  end, 8000, "clipboard attachment")
  assert(vim.api.nvim_get_current_win() == other, "clipboard paste stole focus from another window")
  vim.api.nvim_set_current_win(input_win)
end)

check("a cleared draft rejects an old clipboard result", function()
  local reader = require("acp.context.clipboard")
  local saved, done = reader.read
  reader.read = function(_, callback)
    done = callback
  end
  local ok, err = pcall(controller.paste_image)
  reader.read = saved
  assert(ok, err)
  st.input:clear()
  done(png, "image/png", nil)
  assert(#st.input.attachments == 0, "old image was attached to a new draft")
end)

if capable then
  check("sending delivers a decodable image block", function()
    -- `path_mode = "link"` is the default, so an inline attachment is made the
    -- way the clipboard path does it: bytes embedded for one message only.
    local att = context.image_bytes(png, "image/png", controller.state().config)
    assert(att and att.inline == true, "clipboard attachment was not embedded")
    local sent = controller.send_now("look here", { att }, st.session)
    assert(sent, "prompt was not accepted")
    wait(function()
      local text = {}
      for _, line in ipairs(vim.api.nvim_buf_get_lines(st.chat.buf, 0, -1, false)) do
        text[#text + 1] = line
      end
      return table.concat(text, "\n"):find("IMAGE:image/png:", 1, true) ~= nil
    end, 8000, "image block echo")
    local joined = table.concat(vim.api.nvim_buf_get_lines(st.chat.buf, 0, -1, false), "\n")
    local encoded = joined:match("IMAGE:image/png:(%d+)")
    assert(encoded, "agent did not echo an image block")
    assert(tonumber(encoded) == #vim.base64.encode(png), "base64 payload length mismatch")
  end)

  check("an inline mention also produces an image block", function()
    local cfg = controller.state().config
    cfg.context.images.path_mode = "inline"
    local atts = context.mentions("see @" .. shot, cfg, st.session.cwd)
    assert(#atts == 1, "mention did not expand")
    assert(atts[1].kind == "image", "mention did not become an image attachment")
    local blocks = context.to_prompt("", atts, cfg)
    assert(blocks[1].type == "image", "mention did not encode an image block")
    cfg.context.images.path_mode = "link"
  end)
else
  check("sending refuses an embedded image when the agent did not advertise it", function()
    -- A clipboard attachment is always embedded, so it must be refused.
    local att = context.image_bytes(png, "image/png", controller.state().config)
    assert(att and att.inline == true, "clipboard attachment was not embedded")
    local before = #vim.api.nvim_buf_get_lines(st.chat.buf, 0, -1, false)
    local sent = controller.send_now("look here", { att }, st.session)
    assert(not sent, "prompt with an embedded image was accepted by a non-capable agent")
    assert(#vim.api.nvim_buf_get_lines(st.chat.buf, 0, -1, false) == before, "a failed send changed the transcript")
  end)

  check("a link-mode image is still allowed", function()
    local cfg = controller.state().config
    cfg.context.images.path_mode = "link"
    st.input:clear_attachments()
    local att = context.image(shot, cfg)
    assert(att and att.inline == false, "link-mode attachment was not created")
    st.input:add_attachment(att)
    assert(controller.send_now("link it", st.input.attachments, st.session), "resource_link send was refused")
    wait(function()
      return st.session and st.session.status == "running"
    end, 8000, "turn start")
    controller.cancel()
    wait(function()
      return st.session and st.session.status == "idle"
    end, 8000, "turn cancel")
  end)
end

check("the image cache is private and content-addressed", function()
  -- The file added above came from the workspace, not the clipboard, so store
  -- the same bytes through the clipboard path to exercise the cache.
  local cached = context.image_bytes(png, "image/png", controller.state().config)
  assert(cached and cached.path, "clipboard bytes were not cached")
  local dir = image.dir()
  local names = vim.fn.readdir(dir)
  local found = false
  for _, name in ipairs(names) do
    if name:find(vim.fn.sha256(png), 1, true) then
      found = true
      local stat = vim.uv.fs_stat(dir .. "/" .. name)
      assert(stat and stat.size == #png, "cached image has the wrong size")
      local mode = stat.mode % 8
      assert(mode == 0 or mode == 4 or mode == 6, "cached image is group/world writable")
    end
  end
  assert(found, "clipboard image was not stored in the cache")
end)

if capable then
  check("the real agent receives images interleaved at their input positions", function()
    wait(function()
      return st.session.status == "idle"
    end, 8000, "previous turn")
    st.input:clear()
    st.input:restore("ORDER_PROBE前\n中后")
    local first = assert(context.image_bytes(png .. "ONE", "image/png", st.config))
    local second = assert(context.image_bytes(png .. "TWO", "image/png", st.config))
    st.input:add_attachment(first, { 1, #"中" })
    st.input:add_attachment(second, { 0, #"ORDER_PROBE" })
    local raw = table.concat(vim.api.nvim_buf_get_lines(st.input.buf, 0, -1, false), "\n")
    local text = st.input:text()
    assert(context.display_text(text, st.input.attachments) == raw, "transcript order differs from input")
    assert(controller.send_now(text, st.input.attachments, st.session), "ordered prompt refused")
    local received
    wait(function()
      for _, block in ipairs(st.session.blocks) do
        if block.kind == "agent" then
          local encoded = (block.text or ""):match("ORDER:(%b[])")
          if encoded then
            received = vim.json.decode(encoded)
            return true
          end
        end
      end
      return false
    end, 8000, "agent order echo")
    assert(
      vim.deep_equal({
        "text:ORDER_PROBE",
        "image:" .. vim.base64.encode(png .. "TWO"),
        "text:前\n中",
        "image:" .. vim.base64.encode(png .. "ONE"),
        "text:后",
      }, received),
      "agent received reordered prompt blocks"
    )
    local local_user
    for _, block in ipairs(st.session.blocks) do
      if block.kind == "user" and block.text == text then
        local_user = block
      end
    end
    assert(local_user, "local transcript message missing")
    assert(
      context.display_text(local_user.text, local_user.attachments) == raw,
      "local transcript lost image positions"
    )
  end)
end

vim.fn.delete(tmp, "rf")
controller.disconnect()

if #failures > 0 then
  error("integration image failures:\n  " .. table.concat(failures, "\n  "), 0)
end
io.write("all image integration checks passed\n")
vim.cmd("qa!")
