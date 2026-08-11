--!strict
-- FlashlightController — the player's beam (GDD §4.1/§4.2).
-- Client-side: creates a SpotLight on the character's Head (primitives only),
-- toggles with [F], flickers while the pool is low, and dies in Darkness.
--
-- Server-authoritative economy: the beam's Lumen tax (+0.3 L/s, v1 target) is
-- applied by LumenService via the SetFlashlight RPC — this controller only
-- renders light; it never spends Lumen itself.
--
-- Design notes:
--   * Beam defaults ON at spawn — the squad's light is the game's identity.
--   * In Darkness all beams force off (server event); they stay off after
--     recovery until the player presses [F] again (light is a choice).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local Knit = require(ReplicatedStorage.Packages.Knit)

local DEFAULT_FLICKER_THRESHOLD = 10 -- overridden by LumenService Config

local FlashlightController = Knit.CreateController {
	Name = "FlashlightController",
	LumenService = nil :: any,
	Beam = nil :: SpotLight?,
	On = false,
	InDarkness = false,
	CurrentLumen = 100.0,
	FlickerThreshold = DEFAULT_FLICKER_THRESHOLD,
}

local function Log(msg: string)
	print("[FlashlightController]", msg)
end

function FlashlightController:KnitStart()
	self.LumenService = Knit.GetService("LumenService")

	-- Server-pushed tuning (single source of truth for v1 targets).
	self.LumenService.Config:Observe(function(config: any)
		if type(config) == "table" and type(config.FlickerThreshold) == "number" then
			self.FlickerThreshold = config.FlickerThreshold
		end
	end)

	-- Current pool value drives the flicker behavior.
	self.LumenService.Lumen:Observe(function(value: number)
		self.CurrentLumen = value
	end)

	-- Darkness: beams die (GDD §4.2). Stay off until the player re-toggles.
	self.LumenService.DarknessChanged:Connect(function(inDarkness: boolean)
		self.InDarkness = inDarkness
		if inDarkness then
			self:ApplyBeamVisual(false)
		end
	end)

	-- Server force-sync (e.g. beams killed on Darkness). LOCAL APPLY ONLY —
	-- never echo back to the server from here (that would loop).
	self.LumenService.FlashlightChanged:Connect(function(on: boolean)
		if not on and self.On then
			self.On = false
			self:ApplyBeamVisual(false)
		end
	end)

	-- Character rig: attach the beam to the Head (fallback: HumanoidRootPart).
	local player = Players.LocalPlayer
	local character = player.Character or player.CharacterAdded:Wait()
	self:SetupCharacter(character)
	player.CharacterAdded:Connect(function(newCharacter: Model)
		self:SetupCharacter(newCharacter)
	end)

	-- [F] toggles the beam.
	UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessed: boolean)
		if gameProcessed then
			return
		end
		if input.UserInputType == Enum.UserInputType.Keyboard and input.KeyCode == Enum.KeyCode.F then
			self:ToggleBeam()
		end
	end)

	-- Flicker heartbeat (client-side visual only).
	task.spawn(function()
		self:FlickerLoop()
	end)

	Log("Started")
end

function FlashlightController:SetupCharacter(character: Model)
	-- Respawn / re-rig: drop any previous beam.
	if self.Beam then
		self.Beam:Destroy()
		self.Beam = nil
	end
	self.On = false

	local part: BasePart? = character:WaitForChild("Head", 5) :: BasePart?
	if not part then
		part = character:WaitForChild("HumanoidRootPart", 5)
	end
	if not part then
		warn("[FlashlightController] No Head/HumanoidRootPart on character — beam disabled")
		return
	end

	local beam = Instance.new("SpotLight")
	beam.Name = "PlayerFlashlight"
	beam.Brightness = 2.5
	beam.Range = 70
	beam.Angle = 65
	beam.Color = Color3.fromRGB(255, 244, 214) -- warm beam; skins come later
	beam.Enabled = false
	beam.Parent = part
	self.Beam = beam

	-- Default ON at spawn: the squad starts its run with the beams lit.
	self:SetBeamOn(true, "spawn")
end

function FlashlightController:SetBeamOn(on: boolean, reason: string)
	self.On = on
	self:ApplyBeamVisual(on)

	-- Sync the economy with the server (authoritative drain + Darkness gate).
	self.LumenService:SetFlashlight(on):andThen(function(accepted: boolean)
		if accepted then
			Log(("Beam %s (%s)"):format(on and "ON" or "OFF", reason))
		else
			-- Server rejected (only possible reason: Darkness). Revert locally.
			self.On = false
			self:ApplyBeamVisual(false)
			Log("Beam rejected by server — the squad is in Darkness.")
		end
	end):catch(function(err: any)
		warn("[FlashlightController] SetFlashlight failed:", err)
	end)
end

function FlashlightController:ToggleBeam()
	if self.InDarkness then
		Log("Cannot toggle beam during Darkness.")
		return
	end
	self:SetBeamOn(not self.On, "toggle")
end

-- Visual state of the beam. `on` is the player's intent; Darkness overrides.
function FlashlightController:ApplyBeamVisual(on: boolean)
	if not self.Beam then
		return
	end
	self.Beam.Enabled = on and not self.InDarkness
end

-- Flicker below the pool threshold (v1 target): random stutter while the
-- squad's light is dying. Restores solid light above the threshold.
function FlashlightController:FlickerLoop()
	while true do
		task.wait(0.1)
		local beam = self.Beam
		if not beam then
			continue
		end
		if self.On and not self.InDarkness and self.CurrentLumen <= self.FlickerThreshold then
			beam.Enabled = math.random() > 0.4
		else
			beam.Enabled = self.On and not self.InDarkness
		end
	end
end

return FlashlightController
