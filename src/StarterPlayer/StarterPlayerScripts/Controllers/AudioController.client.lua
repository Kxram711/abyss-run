--!strict
-- AudioController — client audio rig for LIGHTS OUT (GDD §9: "audio is half
-- the game"). All sounds are created at runtime from a config table of Roblox
-- library AssetIds (FREE library sounds only — no paid assets).
--
-- ⚠️ ASSET-ID PLACEHOLDERS — READ ME
--   The IDs below are well-known free Roblox library sounds picked as sensible
--   stand-ins. They could NOT be verified from this environment (Roblox asset
--   APIs are auth-gated), and some may have been removed/renamed over the
--   years. VERIFY EACH ONE IN STUDIO (insert the ID into a Sound and listen)
--   or swap in original audio before launch. The controller fails soft: a
--   missing/blocked asset only logs — it never errors the game.
--
-- Rig (GDD §9):
--   * AmbientDrone   low looping facility hum — volume RISES and pitch FALLS
--                    as the Lumen pool drops (the hum "sickens" with the light)
--   * Heartbeat      looping — fades in below 30 Lumen, quickens below 15
--                    (the universal "light is dying" cue, GDD §9)
--   * WardenBuzz     one-shot on WardenGaze (local player only) — the
--                    light-bulb-fail buzz of your own beam dying
--   * ArtifactChime  one-shot on ArtifactPickedUp (non-positional this pass:
--                    the carry entry carries no world position)
--   * DarknessSting  one-shot on DarknessChanged(true) — the light surges out
--   * InvestigateCue one-shot on EntityStateChanged INVESTIGATE/CHASE on the
--                    local player's floor, positioned at the entity model
--                    (EntityStateChanged now carries Floor + Position)
--
-- Non-positioned sounds live under the local player's PlayerGui (client-only —
-- zero replication churn). Positioned one-shots parent to a world part (the
-- entity model) so they pan/attenuate naturally and die with the model.
-- The loops are volume/pitch-mapped in a 0.25s tick — no per-frame work, and
-- the mix is tuned to sit under friend VOIP (full ducking is a later pass).

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Knit = require(ReplicatedStorage.Packages.Knit)

local AUDIO_CONFIG: { [string]: any } = {
	-- Master gain for every sound (0..1). GDD §9's VOIP duck (mix sits under
	-- friend banter) is a later pass — flagged to the lead.
	MasterVolume = 0.8,
	AmbientDrone = {
		AssetId = 136097950, -- PLACEHOLDER: "Spooky" dark ambience loop (verify in Studio)
		Volume = 0.12, -- at full Lumen (the facility always hums)
		MaxVolume = 0.5, -- at Lumen 0 — louder in darkness (GDD §9)
		PitchAtFull = 1.0,
		PitchAtZero = 0.85, -- pitches DOWN as Lumen falls (GDD §9)
	},
	Heartbeat = {
		AssetId = 131537112, -- PLACEHOLDER: low heartbeat loop (verify in Studio)
		Volume = 0.35,
		FadeInBelow = 30, -- GDD §9: a quiet heartbeat begins under 30 Lumen.
		-- NOTE: the brief said "below the flicker threshold" (10); the GDD —
		-- which is the authority here — specifies 30 with a quicken under 15.
		SpeedUpBelow = 15, -- GDD §9: quickening under 15
		SpeedAtFadeIn = 1.0,
		SpeedAtZero = 1.7,
	},
	WardenBuzz = {
		AssetId = 10209641, -- PLACEHOLDER: electric buzz / lightbulb fail (verify in Studio)
		Volume = 0.5,
		MaxDuration = 2,
	},
	ArtifactChime = {
		AssetId = 169380552, -- PLACEHOLDER: pickup chime (verify in Studio)
		Volume = 0.45,
		MaxDuration = 2,
	},
	DarknessSting = {
		AssetId = 10555569, -- PLACEHOLDER: low boom — classic free "Explosion"; swap for a sub-bass swell (verify in Studio)
		Volume = 0.55,
		MaxDuration = 3,
	},
	InvestigateCue = {
		AssetId = 178128338, -- PLACEHOLDER: whisper / dark cue (verify in Studio)
		Volume = 0.6,
		MaxDuration = 2.5,
	},
}

local AudioController = Knit.CreateController {
	Name = "AudioController",
	CurrentLumen = 100.0,
	CurrentFloor = 1,
	Player = nil :: Player?,
	RootFolder = nil :: Folder?,
	Sounds = {} :: { [string]: Sound },
}

local function Log(msg: string)
	print("[AudioController]", msg)
end

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------

function AudioController:KnitStart()
	local player = Players.LocalPlayer
	self.Player = player

	-- Client-only home for non-positioned sounds (PlayerGui never replicates).
	local playerGui = player:WaitForChild("PlayerGui")
	local folder = Instance.new("Folder")
	folder.Name = "AtmosphereAudio"
	folder.Parent = playerGui
	self.RootFolder = folder

	local lumenService = Knit.GetService("LumenService")
	local entityService = Knit.GetService("EntityService")
	local artifactService = Knit.GetService("ArtifactService")
	local runService = Knit.GetService("RunService")
	local extractionService = Knit.GetService("ExtractionService")

	-- Looping bed: facility drone + Lumen heartbeat (start silent; the
	-- Lumen-mapped tick fades them in as the light dies).
	self.Sounds.AmbientDrone = self:_NewLoopSound(AUDIO_CONFIG.AmbientDrone)
	self.Sounds.Heartbeat = self:_NewLoopSound(AUDIO_CONFIG.Heartbeat)

	-- Pool → drone/heartbeat mapping.
	lumenService.Lumen:Observe(function(value: number)
		self.CurrentLumen = value
	end)
	lumenService.LumenChanged:Connect(function(value: number)
		self.CurrentLumen = value
	end)

	-- Darkness sting: the light surges out (GDD §4.2).
	lumenService.DarknessChanged:Connect(function(inDarkness: boolean)
		if inDarkness then
			self:PlayOneShot("DarknessSting", self:_CharacterRoot())
		end
	end)

	-- Artifact pickup chime (GDD §4.4 satisfaction beat).
	artifactService.ArtifactPickedUp:Connect(function(_entry: any)
		self:PlayOneShot("ArtifactChime")
	end)

	-- Warden gaze: YOUR beam buzzes out (the HUD overlay + beam stutter are
	-- the visual half; this is the audio half).
	entityService.WardenGaze:Connect(function(gazedPlayer: Player, _flickerSeconds: number)
		if gazedPlayer == self.Player then
			self:PlayOneShot("WardenBuzz", self:_CharacterRoot())
		end
	end)

	-- Entity investigate/chase cue, gated to the local player's floor and
	-- positioned at the entity model so it pans as the threat moves.
	entityService.EntityStateChanged:Connect(function(entityId: number, kind: string, state: string, payload: any?)
		if state ~= "INVESTIGATE" and state ~= "CHASE" then
			return
		end
		local p = payload or {}
		if p.Floor ~= nil and p.Floor ~= self.CurrentFloor then
			return -- not the local player's floor
		end
		self:PlayOneShot("InvestigateCue", self:_EntityModel(entityId, kind))
	end)

	-- Current floor (for the same-floor gate above).
	runService.RunInfo:Observe(function(info: any)
		if type(info) == "table" and type(info.Floor) == "number" then
			self.CurrentFloor = info.Floor
		end
	end)
	extractionService.FloorAdvanced:Connect(function(floor: number)
		self.CurrentFloor = floor
	end)

	task.spawn(function()
		self:_LumenAudioLoop()
	end)

	Log(("Started for %s"):format(player.Name))
end

-- ---------------------------------------------------------------------------
-- Lumen-mapped loops (GDD §9: drone sickens, heartbeat quickens)
-- ---------------------------------------------------------------------------

--- 0.25s tick: maps the pool onto the looping bed. No allocations — reads the
--- cached Sound objects and writes scalars.
function AudioController:_LumenAudioLoop()
	while true do
		task.wait(0.25)
		local lumen = self.CurrentLumen
		local t = 1 - math.clamp(lumen, 0, 100) / 100 -- 0 = full light, 1 = Darkness

		local drone = self.Sounds.AmbientDrone
		if drone then
			local d = AUDIO_CONFIG.AmbientDrone
			drone.Volume = d.Volume + (d.MaxVolume - d.Volume) * t
			drone.PlaybackSpeed = d.PitchAtFull + (d.PitchAtZero - d.PitchAtFull) * t
		end

		local heart = self.Sounds.Heartbeat
		if heart then
			local h = AUDIO_CONFIG.Heartbeat
			if lumen < h.FadeInBelow then
				local fade = 1 - math.clamp(lumen, 0, h.FadeInBelow) / h.FadeInBelow
				heart.Volume = h.Volume * fade
				heart.PlaybackSpeed = h.SpeedAtFadeIn
				if lumen < h.SpeedUpBelow then
					local q = 1 - math.clamp(lumen, 0, h.SpeedUpBelow) / h.SpeedUpBelow
					heart.PlaybackSpeed = h.SpeedAtFadeIn + (h.SpeedAtZero - h.SpeedAtFadeIn) * q
				end
			else
				heart.Volume = 0
			end
		end
	end
end

-- ---------------------------------------------------------------------------
-- One-shots
-- ---------------------------------------------------------------------------

--- Creates, plays, and self-cleans a one-shot. `parent` positions the sound
--- in 3D (world part) — pass nil for a non-positional cue. Missing/blocked
--- assets fail soft (pcall'd Play; the Sound just stays silent and is cleaned
--- up by the MaxDuration cap, which also guards long placeholder assets).
function AudioController:PlayOneShot(name: string, parent: Instance?)
	local cfg = AUDIO_CONFIG[name]
	if cfg == nil then
		return
	end
	local sound = Instance.new("Sound")
	sound.SoundId = "rbxassetid://" .. tostring(cfg.AssetId)
	sound.Volume = cfg.Volume * AUDIO_CONFIG.MasterVolume
	sound.Parent = parent or self.RootFolder
	pcall(function()
		sound:Play()
	end)
	task.delay(cfg.MaxDuration or 3, function()
		if sound.Parent ~= nil then
			sound:Destroy()
		end
	end)
end

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

function AudioController:_NewLoopSound(cfg: any): Sound
	local sound = Instance.new("Sound")
	sound.SoundId = "rbxassetid://" .. tostring(cfg.AssetId)
	sound.Looped = true
	sound.Volume = 0 -- loops start silent; the Lumen tick fades them in
	sound.PlaybackSpeed = 1
	sound.Parent = self.RootFolder
	pcall(function()
		sound:Play()
	end)
	return sound
end

function AudioController:_CharacterRoot(): Instance?
	local player = self.Player
	if player == nil then
		return nil
	end
	local character = player.Character
	if character == nil then
		return nil
	end
	return character:FindFirstChild("HumanoidRootPart")
end

--- The entity's model (kind_<id>, live under the current floor folder) so the
--- cue follows the moving threat. Falls back to nil (non-positional) when the
--- model can't be found (e.g. floor rebuild mid-event).
function AudioController:_EntityModel(entityId: number, kind: string): Instance?
	local floors = Workspace:FindFirstChild("Floors")
	if floors == nil then
		return nil
	end
	local folder = floors:FindFirstChildOfClass("Folder")
	if folder == nil then
		return nil
	end
	return folder:FindFirstChild(kind .. "_" .. tostring(entityId))
end

return AudioController
