-- Elicitation presentation: a form for schema requests, a confirm for URLs.
local form = require("acp.ui.form")

local Elicitation = {}
Elicitation.__index = Elicitation

---@param opts {answer: fun(interaction: table, response: table), notify: fun(message: string, level: integer|nil)}
function Elicitation.new(opts)
  return setmetatable({ answer = opts.answer, notify = opts.notify }, Elicitation)
end

---@param interaction table
---@return boolean shown
function Elicitation:present(interaction)
  local request = interaction.request or {}
  local url = request.url or (request._meta and request._meta.url)
  if request.mode == "url" or url then
    self.notify((request.message or "Open this URL to continue?") .. (url and ("\n" .. url) or ""), vim.log.levels.INFO)
    local items = { { label = "Open in browser", value = "open" } }
    require("acp.ui.picker").select({
      title = "Agent needs a browser",
      items = items,
      on_choice = function()
        if url and vim.ui.open then
          vim.ui.open(url)
        end
        self.answer(interaction, { action = "accept" })
      end,
      on_cancel = function()
        self.answer(interaction, { action = "cancel" })
      end,
    })
    return true
  end
  return form.open(request, {
    on_submit = function(content)
      self.answer(interaction, { action = "accept", content = content })
    end,
    on_cancel = function()
      self.answer(interaction, { action = "cancel" })
    end,
    on_decline = function()
      self.answer(interaction, { action = "decline" })
    end,
    notify = self.notify,
  })
end

function Elicitation:dismiss()
  form.dismiss()
end

return Elicitation
