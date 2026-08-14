--!strict
-- EconomyService — Filaments bank and permanent unlocks (GDD §4.6).
-- Owns the per-account Filaments bank, credited ONLY on extraction (§4.7:
-- wipe loses run loot, never the bank). This pass adds DataStore persistence:
--   * Profile = { Filaments, Upgrades } persisted per UserId (defaults on
--     first load; the Upgrades table is where the shop's owned gear lives).
--   * Load on join (async with retries/backoff; in-memory deltas made before
--     the load lands are MERGED on top of the loaded baseline, so an early
--     extraction can never lose a credit).
--   * Save on change with throttling (dirty flag + coalesced write) and a
--     final save on player leave; best-effort flush on server close.
--   * GetProfile(player) is the shop's read API (Filaments + owned upgrades).
--
-- Knit Comm surface (server -> client):
--   FilamentsChanged(player, newBalance)   fired on every bank credit AND when
--                                          the persisted profile lands (so the
--                                          HUD/shop refresh from 0 to the real
--                                          balance on join)
--   UpgradesChanged(player)                fired when owned upgrades change or
--                                          the persisted upgrades land (client
--                                          effect seams — e.g. Aperture Lens —
--                                          re-read via GetProfile)
--   RPC GetFilaments()                     current balance
--   RPC GetProfile()                       { Filaments, Upgrades } for the shop
--   RPC GetShopCatalog()                   the 5 slice gear upgrades (GDD §4.6)
--   RPC PurchaseUpgrade(id)                buy a gear upgrade (validates funds,
--                                          deducts, records owned, persists)

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local DataStoreService = game:GetService("DataStoreService")
local Knit = require(ReplicatedStorage.Packages.Knit)

-- GDD §4.6 slice gear catalog (exact names, effects, costs). Effects are
-- applied read-live by the owning service seams (they check HasUpgrade), so a
-- purchase takes effect immediately without a rebuild:
--   aperture_lens      -> FlashlightController beam angle +15% (client visual);
--                         EntityService stagger +0.5s
--   ration_pack        -> LumenService GetMaxCells +1 (3 -> 4)
--   long_cell_carrier  -> LumenService GetMaxCells +2 (3 -> 5)
--   quiet_treads       -> EntityService crouch-speed noise halved (6 -> 3 studs
--                         on the crouch branch; crouch detection lands with the
--                         movement pass)
--   sprint_regulator   -> LumenService GetSprintDrainPerSecond 0.4 -> 0.3 L/s
local UPGRADES = {
    aperture_lens = {
        Id = "aperture_lens",
        Name = "Aperture Lens",
        Cost = 400,
        Description = "Beam wider +15% · focus stagger +0.5s",
    },
    ration_pack = {
        Id = "ration_pack",
        Name = "Ration Pack",
        Cost = 600,
        Description = "+1 consumable slot",
    },
    long_cell_carrier = {
        Id = "long_cell_carrier",
        Name = "Long-Cell Carrier",
        Cost = 1200,
        Description = "Lumen Cell carry 3 → 5",
    },
    quiet_treads = {
        Id = "quiet_treads",
        Name = "Quiet Treads",
        Cost = 1200,
        Description = "Crouch noise 6 → 3 studs",
    },
    sprint_regulator = {
        Id = "sprint_regulator",
        Name = "Sprint Regulator",
        Cost = 1800,
        Description = "Sprint Lumen tax 0.4 → 0.3 L/s",
    },
}
local UPGRADE_ORDER = { "aperture_lens", "ration_pack", "long_cell_carrier", "quiet_treads", "sprint_regulator" }

local EconomyService = Knit.CreateService {
    Name = "EconomyService",
    Client = {
        FilamentsChanged = Knit.CreateSignal(), -- (player: Player, newBalance: number)
        UpgradesChanged = Knit.CreateSignal(), -- (player: Player) — re-read GetProfile
    },
}

-- ---------------------------------------------------------------------------
-- Tuning / persistence config
-- ---------------------------------------------------------------------------
local CONFIG = {
    -- "LightsOutProfiles_v1" — keep the name stable; bump the suffix only on a
    -- deliberate data migration (v1 = slice profile shape).
    StoreName = "LightsOutProfiles_v1",
    KeyPrefix = "Profile_",
    SaveThrottleSeconds = 5, -- coalesced write window after any mutation
    LoadAttempts = 5, -- GetAsync retries
    SaveAttempts = 5, -- SetAsync retries
    RetryBaseDelay = 1, -- 1s, 2s, 4s... exponential backoff
}

-- ---------------------------------------------------------------------------
-- Client-callable RPCs (Knit injects the calling Player as first arg)
-- ---------------------------------------------------------------------------

function EconomyService.Client:GetFilaments(player: Player)
    return EconomyService:GetFilaments(player)
end

function EconomyService.Client:GetProfile(player: Player)
    return EconomyService:GetProfile(player)
end

function EconomyService.Client:GetShopCatalog(player: Player)
    return EconomyService:GetShopCatalog()
end

--- Buy a gear upgrade (GDD §4.6). Server-authoritative: validates the id and
--- funds, deducts, records ownership, persists. Returns:
---   { Success = true, Balance, Upgrade }
---   { Success = false, Reason = "unknown_upgrade" | "already_owned" |
---     "insufficient_funds", Cost?, Balance? }
function EconomyService.Client:PurchaseUpgrade(player: Player, upgradeId: string)
    return EconomyService:PurchaseUpgradeForPlayer(player, upgradeId)
end

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------

function EconomyService:KnitStart()
    self.Profiles = {} -- [userId: number] -> Profile (see _NewProfile)
    self.DataStore = nil
    local ok, store = pcall(function()
        return DataStoreService:GetDataStore(CONFIG.StoreName)
    end)
    if ok then
        self.DataStore = store
        print("[EconomyService] DataStore ready — profiles persist across restarts.")
    else
        warn("[EconomyService] DataStore unavailable (" .. tostring(store) .. ") — running in-memory only for this session.")
    end

    -- Load every current player, then hook join/leave.
    for _, player in Players:GetPlayers() do
        self:OnPlayerAdded(player)
    end
    Players.PlayerAdded:Connect(function(player)
        self:OnPlayerAdded(player)
    end)
    Players.PlayerRemoving:Connect(function(player)
        self:OnPlayerRemoving(player)
    end)

    -- Best-effort flush on server close (game:BindToClose lets us wait briefly;
    -- throttled saves may also still be pending).
    game:BindToClose(function()
        for userId, profile in pairs(self.Profiles) do
            if profile.Dirty and self.DataStore ~= nil then
                local key = self:_Key(userId)
                local payload = self:_Serializable(profile)
                task.spawn(function()
                    self:_SetAsyncWithRetry(key, payload)
                end)
            end
        end
    end)
end

function EconomyService:OnPlayerAdded(player: Player)
    local profile = self:_Profile(player) -- in-memory defaults immediately usable
    profile.Loading = true
    self:_LoadProfile(player, profile)
end

function EconomyService:OnPlayerRemoving(player: Player)
    local profile = self.Profiles[player.UserId]
    if profile == nil then
        return
    end
    -- Cancel a pending throttled save (it may still win the race harmlessly —
    -- SetAsync is idempotent on the same payload — but avoid double writes).
    if profile.SaveThread ~= nil then
        task.cancel(profile.SaveThread)
        profile.SaveThread = nil
    end
    if profile.Dirty and self.DataStore ~= nil then
        local key = self:_Key(player.UserId)
        local payload = self:_Serializable(profile)
        task.spawn(function()
            self:_SetAsyncWithRetry(key, payload)
            profile.Dirty = false
        end)
    end
    self.Profiles[player.UserId] = nil
end

-- ---------------------------------------------------------------------------
-- DataStore load / save (retries + exponential backoff)
-- ---------------------------------------------------------------------------

function EconomyService:_LoadProfile(player: Player, profile: any)
    if self.DataStore == nil then
        profile.Loading = false
        return -- in-memory-only session (Studio without API access, etc.)
    end
    local key = self:_Key(player.UserId)
    local data = self:_GetAsyncWithRetry(key)
    profile.Loading = false
    if type(data) ~= "table" then
        -- First load: defaults stay (fresh profile). Nothing to merge.
        if profile.Dirty then
            self:_ScheduleSave(player, profile) -- persist the in-run deltas
        end
        return
    end

    local loadedFilaments = type(data.Filaments) == "number" and math.floor(data.Filaments) or 0
    local loadedUpgrades = type(data.Upgrades) == "table" and data.Upgrades or {}

    if profile.Dirty then
        -- The player modified the profile (early extraction/upgrade) before the
        -- load landed. In-memory values are DELTAS against the 0 baseline, so
        -- merge them on top of the loaded baseline (money adds; upgrades union).
        profile.Filaments = loadedFilaments + profile.Filaments
        for id in pairs(loadedUpgrades) do
            profile.Upgrades[id] = true
        end
    else
        profile.Filaments = loadedFilaments
        for id in pairs(loadedUpgrades) do
            profile.Upgrades[id] = true
        end
    end
    -- Push the persisted balance to the HUD/shop (they may have read 0).
    self.Client.FilamentsChanged:Fire(player, profile.Filaments)
    -- Persisted upgrades landed: client effect seams (Aperture Lens beam, etc.)
    -- re-read ownership via GetProfile.
    self.Client.UpgradesChanged:Fire(player)
    if profile.Dirty then
        self:_ScheduleSave(player, profile)
    end
end

function EconomyService:_GetAsyncWithRetry(key: string): any?
    if self.DataStore == nil then
        return nil
    end
    return self:_WithRetry(function()
        return self.DataStore:GetAsync(key)
    end, CONFIG.LoadAttempts)
end

function EconomyService:_SetAsyncWithRetry(key: string, value: any)
    if self.DataStore == nil then
        return
    end
    self:_WithRetry(function()
        self.DataStore:SetAsync(key, value)
        return true
    end, CONFIG.SaveAttempts)
end

--- Shared retry loop: exponential backoff (1s, 2s, 4s...), warns on final
--- failure but never raises (a failed save is retried next mutation/leave).
function EconomyService:_WithRetry(taskFn: () -> any?, attempts: number): any?
    local lastError: any = nil
    for attempt = 1, attempts do
        local ok, result = pcall(taskFn)
        if ok then
            return result
        end
        lastError = result
        task.wait(CONFIG.RetryBaseDelay * (2 ^ (attempt - 1)))
    end
    warn(("[EconomyService] DataStore op failed after %d attempts: %s"):format(attempts, tostring(lastError)))
    return nil
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
    profile.Dirty = true
    self:_ScheduleSave(player, profile)
    self.Client.FilamentsChanged:Fire(player, profile.Filaments)
    return profile.Filaments
end

function EconomyService:GetFilaments(player: Player): number
    return self:_Profile(player).Filaments
end

-- ---------------------------------------------------------------------------
-- Profile API (shop reads this; upgrade ownership is written by PurchaseUpgrade)
-- ---------------------------------------------------------------------------

--- Server-internal read API for other services: full profile snapshot.
function EconomyService:GetProfile(player: Player): any
    local profile = self:_Profile(player)
    local upgrades = {}
    for id in pairs(profile.Upgrades) do
        upgrades[id] = true
    end
    return {
        Filaments = profile.Filaments,
        Upgrades = upgrades,
        Loaded = not profile.Loading,
    }
end

--- Does the player own this upgrade id? (effect seams read this)
function EconomyService:HasUpgrade(player: Player, upgradeId: string): boolean
    return self:_Profile(player).Upgrades[upgradeId] == true
end

--- Server-internal: record upgrade ownership after a validated purchase.
function EconomyService:SetUpgradeOwned(player: Player, upgradeId: string)
    local profile = self:_Profile(player)
    profile.Upgrades[upgradeId] = true
    profile.Dirty = true
    self:_ScheduleSave(player, profile)
end

-- ---------------------------------------------------------------------------
-- Shop API (GDD §4.6 / §7.1 slice: 5 gear upgrades, Filaments only)
-- ---------------------------------------------------------------------------

--- Catalog for the shop UI: ordered, serializable, exact GDD costs.
function EconomyService:GetShopCatalog(): { any }
    local out: { any } = {}
    for _, id in ipairs(UPGRADE_ORDER) do
        local def = UPGRADES[id]
        table.insert(out, {
            Id = def.Id,
            Name = def.Name,
            Cost = def.Cost,
            Description = def.Description,
        })
    end
    return out
end

--- The purchase path the Client RPC calls. Effects are read-live by the owning
--- seams (HasUpgrade), so nothing else needs to run on purchase — the gear is
--- "applied" the moment ownership flips.
function EconomyService:PurchaseUpgradeForPlayer(player: Player, upgradeId: string): any
    local def = UPGRADES[upgradeId]
    if def == nil then
        return { Success = false, Reason = "unknown_upgrade" }
    end
    local profile = self:_Profile(player)
    if profile.Upgrades[upgradeId] then
        return { Success = false, Reason = "already_owned" }
    end
    if profile.Filaments < def.Cost then
        return {
            Success = false,
            Reason = "insufficient_funds",
            Cost = def.Cost,
            Balance = profile.Filaments,
        }
    end
    profile.Filaments -= def.Cost
    self:SetUpgradeOwned(player, upgradeId)
    self.Client.FilamentsChanged:Fire(player, profile.Filaments)
    self.Client.UpgradesChanged:Fire(player)
    print(("[EconomyService] %s bought %s (-%dF, balance %dF)."):format(player.Name, def.Name, def.Cost, profile.Filaments))
    return {
        Success = true,
        Balance = profile.Filaments,
        Upgrade = {
            Id = def.Id,
            Name = def.Name,
            Cost = def.Cost,
            Description = def.Description,
        },
    }
end

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

--- In-memory profile, created lazily with defaults (never blocks on load).
function EconomyService:_Profile(player: Player): any
    local profile = self.Profiles[player.UserId]
    if profile == nil then
        profile = {
            Filaments = 0,
            Upgrades = {}, -- [upgradeId: string] -> true
            Dirty = false, -- unsaved mutations
            Loading = false, -- async DataStore load in flight
            SavePending = false, -- throttled write scheduled
            SaveThread = nil :: thread?,
        }
        self.Profiles[player.UserId] = profile
    end
    return profile
end

function EconomyService:_Key(userId: number): string
    return CONFIG.KeyPrefix .. tostring(userId)
end

function EconomyService:_Serializable(profile: any): any
    local upgrades = {}
    for id in pairs(profile.Upgrades) do
        upgrades[id] = true
    end
    return {
        Filaments = profile.Filaments,
        Upgrades = upgrades,
    }
end

--- Coalesced save: at most one write per player per throttle window. The
--- payload is snapshotted at write time, so later mutations are picked up by
--- the next window (or the leave save).
function EconomyService:_ScheduleSave(player: Player, profile: any)
    if self.DataStore == nil then
        profile.Dirty = false
        return
    end
    if profile.SavePending then
        return
    end
    profile.SavePending = true
    profile.SaveThread = task.spawn(function()
        task.wait(CONFIG.SaveThrottleSeconds)
        profile.SaveThread = nil
        profile.SavePending = false
        if profile.Dirty then
            local ok, err = pcall(function()
                self:_SetAsyncWithRetry(self:_Key(player.UserId), self:_Serializable(profile))
            end)
            if ok then
                profile.Dirty = false
            end
        end
    end)
end

return EconomyService
