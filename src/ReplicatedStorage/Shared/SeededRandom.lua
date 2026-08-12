--!strict
-- SeededRandom — deterministic mulberry32 PRNG for floor generation (GDD §4.3).
-- Same seed => same sequence, guaranteed, on every platform and engine
-- version. The floor generator path never touches math.random; this module is
-- the single source of randomness for layout, and the entity delegation can
-- reuse it for deterministic spawn placement.
--
-- Mulberry32 (per C. Wellons' "practical random numbers") is a tiny, well-
-- understood 32-bit PRNG — deliberately chosen over Roblox's Random class so
-- sequences cannot drift between engine builds (seed-share leaderboards, GDD
-- §4.3, depend on stable layouts).

local SeededRandom = {}
SeededRandom.__index = SeededRandom

export type SeededRandom = typeof(SeededRandom) & { _state: number }

-- FNV-1a: folds any string/number seed into a 32-bit integer.
function SeededRandom.hash(input: (string | number)): number
	local str = tostring(input)
	local h = 2166136261 -- FNV offset basis
	for i = 1, #str do
		h = bit32.bxor(h, string.byte(str, i))
		h = (h * 16777619) % 4294967296 -- FNV prime, mod 2^32
	end
	return h
end

function SeededRandom.new(seed: number): SeededRandom
	local self = setmetatable({}, SeededRandom)
	self._state = math.floor(seed) % 4294967296
	if self._state == 0 then
		self._state = 1 -- mulberry32 has no 0 state
	end
	return self
end

-- Next float in [0, 1).
function SeededRandom:Next(): number
	local s = (self._state + 1831565813) % 4294967296 -- 0x6D2B79F5
	local t = bit32.bxor(s, bit32.rshift(s, 15))
	t = bit32.bxor(t, bit32.band(bit32.lshift(t, 13), 4294967295))
	t = bit32.bxor(t, bit32.rshift(t, 11))
	self._state = s
	return t / 4294967296
end

-- Next integer in [min, max], inclusive.
function SeededRandom:NextInt(min: number, max: number): number
	return math.floor(self:Next() * (max - min + 1)) + min
end

-- Fisher–Yates shuffle, in place. Deterministic given the RNG sequence.
function SeededRandom:Shuffle<T>(list: { T }): { T }
	for i = #list, 2, -1 do
		local j = self:NextInt(1, i)
		list[i], list[j] = list[j], list[i]
	end
	return list
end

return SeededRandom
