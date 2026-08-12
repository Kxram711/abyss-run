--!strict
-- RunHudController — run-state HUD surface (GDD §7.1 UI/UX).
-- Placeholder seam for the in-run HUD (Lumen bar, HP, artifact slots, cell
-- count), floor-screen drain-rate preview, and extract/push prompts.
-- UI screens themselves are owned by the UI/UX delegation; this controller
-- is where their data bindings will live.
--
-- THIS PASS (extraction loop delegation): no GUI — but the run lifecycle is
-- observable in the output console, which is what playtesting needs today:
--   * RunService run-state transitions (lobby -> in-run -> extracted/wiped)
--   * ArtifactService carry changes (pickup / capacity / extract clear)
--   * ExtractionService push-downs and extraction results (banked Filaments)
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Knit = require(ReplicatedStorage.Packages.Knit)
local RunHudController = Knit.CreateController {
	Name = "RunHudController",
}
local function Log(msg: string)
	print("[RunHud]", msg)
end
function RunHudController:KnitStart()
	local runService = Knit.GetService("RunService")
	local artifactService = Knit.GetService("ArtifactService")
	local extractionService = Knit.GetService("ExtractionService")

	runService.RunStateChanged:Connect(function(state: string, payload: any?)
		if state == "extracted" and payload ~= nil then
			Log(("RUN EXTRACTED — floor %d, %dF banked, squad alive: %s"):format(
				payload.FloorReached or 0, payload.BankedFilaments or 0, tostring(payload.SquadAlive)
			))
		elseif state == "wiped" and payload ~= nil then
			Log(("RUN WIPED (%s) — floor %d, carried loot lost"):format(
				tostring(payload.Reason), payload.FloorReached or 0
			))
		else
			Log("Run state -> " .. tostring(state))
		end
	end)

	artifactService.CarryChanged:Connect(function(snapshot: any)
		local count = #snapshot.Artifacts + (snapshot.SpecialSlot ~= nil and 1 or 0)
		Log(("Carry: %d/%d slots (%dF) — %s"):format(
			count, snapshot.RegularSlotsMax + 1, snapshot.TotalValue, tostring(count == 0 and "empty" or "held")
		))
	end)

	extractionService.FloorAdvanced:Connect(function(floor: number)
		Log("Pushed down -> floor " .. tostring(floor))
	end)

	extractionService.ExtractionCompleted:Connect(function(results: any)
		local items = {}
		for _, a in ipairs(results.Artifacts or {}) do
			table.insert(items, a.Name)
		end
		Log(("Extraction complete: %s — banked %dF"):format(
			#items > 0 and table.concat(items, ", ") or "no artifacts", results.BankedFilaments or 0
		))
	end)
end
return RunHudController
