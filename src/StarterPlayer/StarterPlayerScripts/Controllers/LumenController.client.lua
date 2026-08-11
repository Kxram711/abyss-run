--!strict
-- LumenController — client mirror of the shared Lumen pool (GDD §9).
-- Consumes LumenService's LumenChanged / DarknessChanged / CellCountChanged
-- events. NO GUI yet (the HUD bar + lumen<->world brightness mapping come from
-- the UI/UX delegation) — this controller logs state and hosts the debug
-- keybind [C] (consume a Lumen Cell; starter loadout grants 1).
--
-- The client NEVER mutates the pool: all changes go through server RPCs.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local Knit = require(ReplicatedStorage.Packages.Knit)

local LumenController = Knit.CreateController {
	Name = "LumenController",
}

local function Log(msg: string)
	print("[LumenController]", msg)
end

function LumenController:KnitStart()
	local LumenService = Knit.GetService("LumenService")

	-- Pool value: log on whole-number changes (HUD binding lands later).
	local lastLogged: number? = nil
	LumenService.LumenChanged:Connect(function(value: number)
		local whole = math.floor(value)
		if whole ~= lastLogged then
			lastLogged = whole
			Log(("Lumen pool: %d/100"):format(whole))
		end
	end)

	-- Darkness failure state (GDD §4.2): recoverable, not instant death.
	-- Vignette rendering is deferred; the event + log prove the state machine.
	LumenService.DarknessChanged:Connect(function(inDarkness: boolean)
		if inDarkness then
			Log("DARKNESS — the facility swallows the light. Recharge (cell/well) to recover.")
		else
			Log("LIGHT RECOVERED — the squad is out of Darkness.")
		end
	end)

	-- Per-player cell count (debug + future HUD).
	LumenService.CellCountChanged:Connect(function(count: number)
		Log(("Lumen Cells carried: %d"):format(count))
	end)

	-- Debug keybind [C]: consume a Lumen Cell if the player owns one.
	-- Starter loadout grants 1 cell so this is testable end-to-end.
	UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessed: boolean)
		if gameProcessed then
			return
		end
		if input.UserInputType == Enum.UserInputType.Keyboard and input.KeyCode == Enum.KeyCode.C then
			LumenService:ConsumeCell():andThen(function(result: string)
				if result == "success" then
					Log("Lumen Cell consumed: +25 Lumen to the pool.")
				else
					Log("No Lumen Cells left to consume.")
				end
			end):catch(function(err: any)
				warn("[LumenController] ConsumeCell failed:", err)
			end)
		end
	end)

	Log(("Started for %s"):format(Players.LocalPlayer.Name))
end

return LumenController
