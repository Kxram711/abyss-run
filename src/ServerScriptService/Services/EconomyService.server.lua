--!strict
-- EconomyService — Filaments bank and permanent unlocks (GDD §4.6).
-- Owns the per-account Filaments bank, credited ONLY on extraction (§4.7:
-- wipe loses run loot, never the bank). This pass is the minimal banking API
-- the extraction loop needs — the full profile (gear/floor-gate/cosmetic
-- unlock catalog, DataStore persistence, §4.6/§7.1) is a later delegation.
--
-- Knit Comm surface (server -> client; NO GUI this pass):
--   FilamentsChanged(player, newBalance)   fired on every bank credit
--   RPC GetFilaments()                     current balance (lobby/shop later)

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Knit = require(ReplicatedStorage.Packages.Knit)

local EconomyService = Knit.CreateService {
    Name = "EconomyService",
    Client = {
        FilamentsChanged = Knit.CreateSignal(), -- (player: Player, newBalance: number)
    },
}

-- ---------------------------------------------------------------------------
-- Client-callable RPCs (Knit injects the calling Player as first arg)
-- ---------------------------------------------------------------------------

function EconomyService.Client:GetFilaments(player: Player)
    return EconomyService:GetFilaments(player)
end

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------

function EconomyService:KnitStart()
    -- In-memory slice bank, keyed by UserId (survives re-joins on the same
    -- server). DataStore persistence is a later delegation (§7.4 Lead Dev
    -- save/load; flagged to the lead).
    self.Profiles = {} -- [userId: number] -> { Filaments: number }
end

-- ---------------------------------------------------------------------------
-- Banking API (server-internal; only the extraction flow calls this)
-- ---------------------------------------------------------------------------

--- Credits Filaments to a player's bank. Returns the new balance. Credits are
--- final — wipe consequences never touch the bank (GDD §4.7 fairness contract).
function EconomyService:BankFilaments(player: Player, amount: number): number
    if amount <= 0 then
        return self:GetFilaments(player)
    end
    local profile = self:_Profile(player)
    profile.Filaments += amount
    self.Client.FilamentsChanged:Fire(player, profile.Filaments)
    return profile.Filaments
end

function EconomyService:GetFilaments(player: Player): number
    return self:_Profile(player).Filaments
end

function EconomyService:_Profile(player: Player): any
    local profile = self.Profiles[player.UserId]
    if profile == nil then
        profile = { Filaments = 0 }
        self.Profiles[player.UserId] = profile
    end
    return profile
end

return EconomyService
