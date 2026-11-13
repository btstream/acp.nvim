return function(t)
  local Interactions = require("acp.app.interactions")

  local function harness(policies)
    local answered, shown, dismissed = {}, {}, {}
    local interactions
    interactions = Interactions.new({
      policies = policies,
      presenters = {
        permission = {
          present = function(interaction)
            shown[#shown + 1] = interaction.id
            return true
          end,
          dismiss = function(interaction)
            dismissed[#dismissed + 1] = interaction.id
          end,
        },
        elicitation = {
          present = function(interaction)
            shown[#shown + 1] = interaction.id
            return true
          end,
          dismiss = function(interaction)
            dismissed[#dismissed + 1] = interaction.id
          end,
        },
      },
    })
    local function open(kind, request, rpc_id)
      return interactions:open(kind or "permission", request or { sessionId = "s" }, function(response)
        answered[#answered + 1] = response
      end, rpc_id)
    end
    return interactions, open, answered, shown, dismissed
  end

  t.describe("interactions", function()
    t.it("answers a request exactly once", function()
      local interactions, open, answered = harness()
      local interaction = open()
      t.truthy(interactions:answer(interaction.id, { outcome = { outcome = "selected", optionId = "a" } }))
      t.falsy(interactions:answer(interaction.id, { outcome = { outcome = "cancelled" } }))
      t.eq(1, #answered)
      t.eq("a", answered[1].outcome.optionId)
      t.eq(0, #interactions:pending())
    end)

    t.it("cancels a permission with the cancelled outcome", function()
      local interactions, open, answered = harness()
      local interaction = open()
      interactions:cancel_session("s")
      t.eq({ outcome = { outcome = "cancelled" } }, answered[1])
      t.eq("cancelled", interactions:get(interaction.id).state)
    end)

    t.it("cancels an elicitation with the cancel action", function()
      local interactions, open, answered = harness()
      open("elicitation", { sessionId = "s" })
      interactions:cancel_session("s")
      t.eq({ action = "cancel" }, answered[1])
    end)

    t.it("ignores requests from other sessions when cancelling one", function()
      local interactions, open, answered = harness()
      open("permission", { sessionId = "a" })
      local other = open("permission", { sessionId = "b" })
      interactions:cancel_session("a")
      t.eq(1, #answered)
      t.eq("pending", interactions:get(other.id).state)
    end)

    t.it("expires a withdrawn request without replying again", function()
      local interactions, open, answered, _, dismissed = harness()
      local interaction = open("permission", { sessionId = "s" }, 7)
      t.truthy(interactions:on_remote_cancel(7))
      t.eq(0, #answered)
      t.eq("expired", interactions:get(interaction.id).state)
      t.eq({ interaction.id }, dismissed)
    end)

    t.it("shows one request at a time and the next after an answer", function()
      local interactions, open, _, shown = harness()
      local first = open()
      local second = open()
      t.eq({ first.id }, shown)
      interactions:answer(first.id, { outcome = { outcome = "cancelled" } })
      vim.wait(50, function()
        return #shown == 2
      end)
      t.eq({ first.id, second.id }, shown)
    end)

    t.it("lets a policy answer without showing the picker", function()
      local interactions, open, answered, shown = harness({
        function(interaction)
          if interaction.type == "permission" then
            return { outcome = { outcome = "selected", optionId = "auto" } }
          end
        end,
      })
      open()
      t.eq(0, #shown)
      t.eq("auto", answered[1].outcome.optionId)
    end)

    t.it("cancels everything on teardown", function()
      local interactions, open, answered = harness()
      open()
      open()
      interactions:cancel_all("bye")
      t.eq(2, #answered)
      t.eq(0, #interactions:pending())
    end)

    t.it("retires settled requests instead of growing without bound", function()
      local interactions, open = harness()
      for _ = 1, 200 do
        local interaction = open()
        interactions:answer(interaction.id, { outcome = { outcome = "cancelled" } })
      end
      t.truthy(#interactions.order <= 0)
      t.truthy(#interactions.recent <= 32)
      vim.wait(50)
    end)

    t.it("declines an elicitation that has no presenter", function()
      local interactions = Interactions.new({ presenters = {} })
      local answered
      interactions:open("elicitation", { sessionId = "s" }, function(response)
        answered = response
      end)
      t.eq({ action = "decline" }, answered)
      t.eq(0, #interactions:pending())
    end)

    t.it("settles a request when the presenter throws", function()
      local interactions = Interactions.new({
        presenters = {
          permission = {
            present = function()
              error("boom")
            end,
          },
        },
        notify = function() end,
      })
      local answered
      interactions:open("permission", { sessionId = "s" }, function(response)
        answered = response
      end)
      t.eq({ outcome = { outcome = "cancelled" } }, answered)
      t.eq(0, #interactions:pending())
    end)

    t.it("can still read a just-settled request", function()
      local interactions, open = harness()
      local interaction = open()
      interactions:answer(interaction.id, { outcome = { outcome = "cancelled" } })
      t.eq("answered", interactions:get(interaction.id).state)
      t.eq(false, interactions:waiting(interaction.session_id))
    end)

    t.it("does not expire on a missing request id", function()
      local interactions, open = harness()
      local interaction = open("permission", { sessionId = "s" }, nil)
      t.falsy(interactions:on_remote_cancel(nil))
      t.eq("pending", interactions:get(interaction.id).state)
    end)
  end)
end
