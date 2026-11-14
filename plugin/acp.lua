-- User commands.
local function api()
  local ok, mod = pcall(require, "acp")
  if not ok then
    return nil
  end
  return mod
end

local SUBCOMMANDS = {
  "open",
  "hide",
  "toggle",
  "new",
  "stop",
  "reconnect",
  "login",
  "logout",
  "agent",
  "agents",
  "install",
  "update",
  "uninstall",
  "config",
  "disconnect",
  "permission",
  "sessions",
  "delete",
  "model",
  "mode",
  "file",
  "files",
  "image",
  "inline",
  "inline-stop",
  "inline-reset",
  "diagnostics",
}

---Complete subcommands, and agent ids for the commands that take one.
local function complete(arglead, cmdline)
  local words = vim.split(vim.trim(cmdline), "%s+")
  local typing_first = #words == 1 or (#words == 2 and not cmdline:match("%s$"))
  local candidates
  if typing_first then
    candidates = SUBCOMMANDS
  else
    local sub = words[2]
    if sub == "install" or sub == "update" or sub == "uninstall" then
      local ok, registry = pcall(require, "acp.manager.registry")
      candidates = {}
      if ok then
        for _, id in ipairs(registry.ids()) do
          if registry.package_of(id) then
            candidates[#candidates + 1] = id
          end
        end
      end
    elseif sub == "agent" then
      local ok, config = pcall(require, "acp.config")
      local current = ok and (config.current or config.defaults) or {}
      candidates = vim.tbl_keys(current.agents or {})
      table.sort(candidates)
    else
      return {}
    end
  end
  return vim.tbl_filter(function(item)
    return vim.startswith(item, arglead)
  end, candidates)
end

local function define(name, fn, desc, range, completer)
  pcall(
    vim.api.nvim_create_user_command,
    name,
    fn,
    { desc = "acp.nvim: " .. desc, nargs = "*", range = range, complete = completer }
  )
end

local function setup()
  define(
    "Acp",
    function(args)
      local acp = api()
      if not acp then
        return
      end
      local sub = args.args ~= "" and args.args or "toggle"
      local rest = ""
      local head, tail = sub:match("^(%S+)%s+(.+)$")
      if head then
        sub, rest = head, tail
      end
      if sub == "open" then
        acp.open()
      elseif sub == "hide" or sub == "close" then
        acp.hide()
      elseif sub == "toggle" then
        acp.toggle()
      elseif sub == "new" then
        acp.new_session()
      elseif sub == "stop" or sub == "cancel" then
        acp.cancel()
      elseif sub == "sessions" then
        acp.pick_session()
      elseif sub == "delete" then
        acp.delete_session()
      elseif sub == "reconnect" then
        acp.reconnect()
      elseif sub == "login" then
        acp.login()
      elseif sub == "logout" then
        acp.logout()
      elseif sub == "agent" then
        acp.pick_agent(rest ~= "" and rest or nil)
      elseif sub == "agents" then
        acp.manage_agents()
      elseif sub == "install" or sub == "update" then
        -- Like :MasonInstall, the window opens so the install is visible.
        local id, version = rest:match("^(%S+)%s*(%S*)$")
        if not id then
          if sub == "update" then
            acp.update_agent(nil)
          end
          acp.manage_agents()
          return
        end
        local fn = sub == "install" and acp.install_agent or acp.update_agent
        if fn(id, version ~= "" and { version = version } or nil) then
          acp.manage_agents()
        end
      elseif sub == "uninstall" then
        if rest == "" then
          acp.manage_agents()
          return
        end
        acp.uninstall_agent(rest)
      elseif sub == "config" then
        acp.pick_config()
      elseif sub == "disconnect" then
        acp.disconnect()
      elseif sub == "permission" then
        acp.show_permission()
      elseif sub == "model" then
        acp.pick_model()
      elseif sub == "mode" then
        acp.pick_mode()
      elseif sub == "file" then
        acp.add_file()
      elseif sub == "files" then
        acp.pick_file()
      elseif sub == "image" then
        if rest ~= "" then
          acp.add_image(vim.fn.expand(rest))
        else
          acp.paste_image()
        end
      elseif sub == "inline" then
        local opts = {}
        if rest ~= "" then
          opts.review = rest
        end
        if args.range > 0 then
          opts.mode = "V"
          opts.pos1 = { 0, args.line1, 1, 0 }
          opts.pos2 = { 0, args.line2, 1, 0 }
        end
        acp.inline(opts)
      elseif sub == "inline-stop" then
        acp.inline_stop()
      elseif sub == "inline-reset" then
        acp.inline_reset()
      elseif sub == "diagnostics" then
        acp.add_diagnostics()
      else
        vim.notify("acp.nvim: unknown subcommand " .. sub, vim.log.levels.WARN)
      end
    end,
    "open|hide|toggle|new|stop|reconnect|login|logout|agent|agents|install|update|uninstall|config|disconnect|permission|sessions|delete|model|mode|file|files|image|inline|inline-stop|inline-reset|diagnostics",
    true,
    complete
  )

  define("AcpCompletionRefresh", function()
    local m = api()
    if m then
      m.refresh_completion()
    end
  end, "refresh project file completion indexes")

  define("AcpLog", function()
    local m = api()
    if m then
      m.show_log()
    end
  end, "open the log file")

  define("AcpDebug", function()
    local m = api()
    if m then
      m.debug_state()
    end
  end, "print controller state")
end

setup()

return {}
