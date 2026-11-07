-- User commands.
local function api()
  local ok, mod = pcall(require, "acp")
  if not ok then
    return nil
  end
  return mod
end

local function define(name, fn, desc)
  pcall(vim.api.nvim_create_user_command, name, fn, { desc = "acp.nvim: " .. desc, nargs = "*" })
end

local function setup()
  define("Acp", function(args)
    local acp = api()
    if not acp then
      return
    end
    local sub = args.args ~= "" and args.args or "toggle"
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
      require("acp.controller").delete_session_flow()
    elseif sub == "reconnect" then
      require("acp.controller").reconnect()
    elseif sub == "disconnect" then
      require("acp.controller").disconnect()
    elseif sub == "permission" then
      require("acp.controller").show_pending_permission()
    elseif sub == "model" then
      acp.pick_model()
    elseif sub == "mode" then
      acp.pick_mode()
    elseif sub == "file" then
      acp.add_file()
    elseif sub == "diagnostics" then
      acp.add_diagnostics()
    else
      vim.notify("acp.nvim: unknown subcommand " .. sub, vim.log.levels.WARN)
    end
  end, "open|hide|toggle|new|stop|reconnect|disconnect|permission|sessions|delete|model|mode|file|diagnostics")

  define("AcpLog", function()
    local m = api()
    if m then
      require("acp.controller").show_log()
    end
  end, "open the log file")

  define("AcpDebug", function()
    local m = api()
    if m then
      require("acp.controller").debug_state()
    end
  end, "print controller state")
end

setup()

return {}
