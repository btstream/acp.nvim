-- Every binding the plugin installs must be configurable, so these tests walk
-- the same action table the mapping module uses instead of a hand-written list.
return function(t)
  local config = require("acp.config")
  local keymaps = require("acp.ui.keymaps")
  local windows = require("acp.ui.windows")

  ---A resolved configuration, exercising the merge + validate path a user takes.
  ---@param over table|nil
  ---@return table
  local function cfg(over)
    return config.validate(config.merge(config.defaults, over or {}))
  end

  ---Canonical form of a key, so `<C-s>` and the `<C-S>` from `nvim_buf_get_keymap`
  ---compare equal.
  ---@param lhs string
  ---@return string
  local function key_of(lhs)
    local ok, code = pcall(vim.keycode, lhs)
    if not ok then
      return lhs
    end
    local ok_trans, translated = pcall(vim.fn.keytrans, code)
    return (ok_trans and translated) or lhs
  end

  ---Descriptions installed in `buf`, keyed by `<mode> <lhs>`.
  ---@param buf integer
  ---@return table<string, string>
  local function installed(buf)
    local found = {}
    for _, mode in ipairs({ "n", "i" }) do
      for _, map in ipairs(vim.api.nvim_buf_get_keymap(buf, mode)) do
        if map.desc and map.desc:match("^acp:") then
          found[mode .. " " .. key_of(map.lhs)] = map.desc
        end
      end
    end
    return found
  end

  ---A scratch buffer with a view's mappings attached.
  ---@param view string
  ---@param keymaps_config table
  ---@return integer buf
  local function attach(view, keymaps_config)
    local buf = vim.api.nvim_create_buf(false, true)
    local handlers = {}
    for _, spec in ipairs(keymaps.view_actions(view)) do
      handlers[spec.handler] = function() end
    end
    handlers.get_session = function()
      return nil
    end
    keymaps.attach(view, buf, keymaps_config, handlers)
    return buf
  end

  t.describe("keymap configuration", function()
    t.it("binds every declared action by default", function()
      local resolved = cfg()
      for _, view in ipairs({ "input", "chat" }) do
        local buf = attach(view, resolved.keymaps[view])
        local found = installed(buf)
        for _, spec in ipairs(keymaps.view_actions(view)) do
          local pairs_ = keymaps.expand(resolved.keymaps[view][spec.action], spec.modes)
          if view == "input" and spec.action == "pick_file" then
            t.eq(false, resolved.keymaps[view][spec.action], "the optional file picker must not claim a key by default")
          else
            t.truthy(#pairs_ > 0, view .. "." .. spec.action .. " has no default binding")
          end
          for _, pair in ipairs(pairs_) do
            local desc = found[pair.mode .. " " .. key_of(pair.lhs)]
            t.eq("acp: " .. spec.desc, desc, view .. "." .. spec.action .. " is not bound to " .. pair.lhs)
          end
        end
      end
    end)

    t.it("gives the composer and the transcript separate defaults", function()
      local km = cfg().keymaps
      t.eq("<C-]>", km.input.add_selection)
      t.eq("S", km.chat.add_selection)
      t.eq({ n = "M", i = "<M-m>" }, km.input.pick_model)
      t.eq("M", km.chat.pick_model)
    end)

    t.it("accepts a single key, a list and a per-mode map", function()
      local resolved = cfg({
        keymaps = {
          chat = { help = "H", focus_input = { "i", "<C-s>", "a" }, pick_model = { n = "T" } },
        },
      })
      local found = installed(attach("chat", resolved.keymaps.chat))
      t.eq("acp: help", found["n H"])
      t.eq("acp: focus composer", found["n i"])
      t.eq("acp: focus composer", found["n " .. key_of("<C-s>")])
      t.eq("acp: focus composer", found["n a"])
      t.eq("acp: pick model", found["n T"])
      t.eq(nil, found["n M"], "the old default must be gone")
    end)

    t.it("filters per-mode keys down to the modes a view declares", function()
      -- The transcript has no insert-mode mappings, so the `i` entry is dropped
      -- instead of creating one the transcript cannot use.
      local resolved = cfg({ keymaps = { chat = { pick_model = { n = "T", i = "<M-t>" } } } })
      local found = installed(attach("chat", resolved.keymaps.chat))
      t.eq("acp: pick model", found["n T"])
      t.eq(nil, found["i <M-t>"])

      -- The composer does declare insert mode for the same action.
      local input = cfg({ keymaps = { input = { pick_model = { n = "T", i = "<M-t>" } } } })
      local input_found = installed(attach("input", input.keymaps.input))
      t.eq("acp: pick model", input_found["i <M-t>"])
    end)

    t.it("leaves an action unbound when configured as false", function()
      local resolved = cfg({ keymaps = { chat = { help = false, scroll_top = "" } } })
      local found = installed(attach("chat", resolved.keymaps.chat))
      t.eq(nil, found["n g?"], "a disabled binding must not be installed")
      t.eq(nil, found["n gg"], "an empty key must not be installed")
      -- Neighbouring actions are untouched.
      t.eq("acp: hide panel", found["n q"])
    end)

    t.it("rejects a flat key and names the view it belongs to", function()
      -- Actions are grouped by view; a bare key would otherwise silently do
      -- nothing, so the error says where it should live.
      t.raises(function()
        cfg({ keymaps = { close_panel = "Q" } })
      end, "keymaps%.close_panel must be nested under a view")
      t.raises(function()
        cfg({ keymaps = { send = "<C-CR>" } })
      end, "keymaps%.send must be nested under a view")
    end)

    t.it("rejects an unknown view", function()
      t.raises(function()
        cfg({ keymaps = { composr = { send = "<C-s>" } } })
      end, "unknown keymaps entry")
    end)

    t.it("rejects an unknown action", function()
      t.raises(function()
        cfg({ keymaps = { chat = { send = "<C-s>" } } })
      end, "unknown keymaps.chat action")
    end)

    t.it("rejects an unknown mode", function()
      t.raises(function()
        cfg({ keymaps = { chat = { help = { q = "H" } } } })
      end, "unknown mode")
    end)

    t.it("rejects a value that is not a key", function()
      t.raises(function()
        cfg({ keymaps = { chat = { help = 42 } } })
      end, "must be a string")
      t.raises(function()
        cfg({ keymaps = { chat = { help = { n = 42 } } } })
      end, "must be a string")
    end)

    t.it("rejects two actions on the same key", function()
      t.raises(function()
        cfg({ keymaps = { chat = { help = "S", add_selection = "S" } } })
      end, "both use S")
    end)

    t.it("detects a clash between keys that are aliases", function()
      -- `<C-i>` is `<Tab>` in a terminal, so mapping both would silently shadow
      -- one of them.
      t.raises(function()
        cfg({ keymaps = { chat = { toggle_block = "<Tab>", help = "<C-i>" } } })
      end, "are the same key")
    end)

    t.it("allows the same key in different modes and views", function()
      -- `q` hides the panel in both views, and the composer's `send` lives in
      -- two modes: neither is a conflict.
      local resolved = cfg()
      t.eq("q", resolved.keymaps.input.close_panel)
      t.eq("q", resolved.keymaps.chat.close_panel)
      t.eq("<C-s>", resolved.keymaps.input.send)
    end)

    t.it("builds the help sheet from the live configuration", function()
      local resolved = cfg({ keymaps = { chat = { help = "H", scroll_top = false } } })
      local text = table.concat(windows.help_lines(resolved.keymaps), "\n")
      t.match("H%s+help", text)
      t.match("q%s+hide panel", text)
      t.falsy(text:find("g?", 1, true), "a rebound key is still shown")
      -- "toggle" contains "gg", so match the key column instead of a substring.
      t.falsy(text:find("%sgg%s", 1), "a disabled binding is still shown")
      -- The composer section reflects its own keys.
      t.match("C%-%]>%s+add selection", text)
    end)

    t.it("lists the composer and the transcript in the help sheet", function()
      local text = table.concat(windows.help_lines(cfg().keymaps), "\n")
      t.match("Composer", text)
      t.match("Transcript", text)
      t.match("<C%-s>%s+send", text)
      t.match("i / <C%-s>%s+focus composer", text)
    end)
  end)
end
