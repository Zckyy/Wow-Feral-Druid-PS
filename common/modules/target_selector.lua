---@meta
---@diagnostic disable: undefined-global, missing-fields, lowercase-global

-- Target Selector adapter for IZI-based rotations.
--
-- Docs reference (Project Sylvanas TS):
-- https://docs.project-sylvanas.net/dev/libraries/modules/target-selector
--
-- IMPORTANT: Consumers must call methods with ':' (colon).

---@class ts_virtual_menu_element
---@field private _value any
---@field private _default any
local ts_virtual_menu_element = {}

ts_virtual_menu_element.__index = ts_virtual_menu_element

---@param default any
---@return ts_virtual_menu_element
function ts_virtual_menu_element.new(default)
    return setmetatable({ _value = default, _default = default }, ts_virtual_menu_element)
end

---@param value any
function ts_virtual_menu_element:set(value)
    self._value = value
end

---@return any
function ts_virtual_menu_element:get()
    return self._value
end

---@return boolean
function ts_virtual_menu_element:get_state()
    return not not self._value
end

---@return any
function ts_virtual_menu_element:get_default()
    return self._default
end

---@class target_selector
---@field public menu_elements table
local target_selector = {}

target_selector.menu_elements = {
    damage = {
        is_damage_enabled = ts_virtual_menu_element.new(true),
        weight_multiple_hits = ts_virtual_menu_element.new(false),
        slider_weight_multiple_hits = ts_virtual_menu_element.new(1),
        slider_weight_multiple_hits_radius = ts_virtual_menu_element.new(8),
    },
    heal = {
        is_heal_enabled = ts_virtual_menu_element.new(true),
        -- Placeholder knobs for compatibility; not used by this adapter today.
        weight_low_health = ts_virtual_menu_element.new(true),
    },
    settings = {
        max_range_damage = ts_virtual_menu_element.new(40),
        max_range_heal = ts_virtual_menu_element.new(40),
    },
}

---@param limit? integer
---@return integer
local function clamp_limit(limit)
    limit = tonumber(limit) or 3
    if limit < 1 then
        return 0
    end
    if limit > 3 then
        return 3
    end
    return math.floor(limit)
end

---@param u game_object|nil
---@return boolean
local function is_valid_enemy_unit(u)
    if not u then
        return false
    end

    if u.is_valid and (not u:is_valid()) then
        return false
    end

    if u.is_dead and u:is_dead() then
        return false
    end

    if u.is_visible and (not u:is_visible()) then
        return false
    end

    if u.is_valid_enemy and (not u:is_valid_enemy()) then
        return false
    end

    return true
end

---@param u game_object|nil
---@return boolean
local function is_valid_ally_unit(u)
    if not u then
        return false
    end

    if u.is_valid and (not u:is_valid()) then
        return false
    end

    if u.is_dead and u:is_dead() then
        return false
    end

    if u.is_visible and (not u:is_visible()) then
        return false
    end

    if u.is_valid_ally and (not u:is_valid_ally()) then
        return false
    end

    return true
end

---Retrieves the table containing the best damage targets possible.
---Delegates to IZI SDK's built-in TS when available.
---@param limit? integer Max 3 (defaults to 3)
---@return game_object[]
function target_selector:get_targets(limit)
    local n = clamp_limit(limit)
    if n == 0 then
        return {}
    end

    local ok, izi = pcall(require, "common/izi_sdk")
    if not ok or not izi then
        return {}
    end

    if not self.menu_elements.damage.is_damage_enabled:get_state() then
        return {}
    end

    if type(izi.get_ts_targets) == "function" then
        local targets = izi.get_ts_targets(n)
        return targets or {}
    end

    -- Fallback: call single-target TS accessor if get_ts_targets isn't available.
    local out = {}
    for i = 1, n do
        local u = (type(izi.ts) == "function") and izi.ts(i) or nil
        if is_valid_enemy_unit(u) then
            out[#out + 1] = u
        end
    end
    return out
end

---Retrieves the table containing the best healing targets possible.
---IZI SDK does not expose a dedicated "heal TS" in the public API stub,
---so this falls back to a simple "lowest HP% allies" selection.
---@param limit? integer Max 3 (defaults to 3)
---@return game_object[]
function target_selector:get_targets_heal(limit)
    local n = clamp_limit(limit)
    if n == 0 then
        return {}
    end

    local ok, izi = pcall(require, "common/izi_sdk")
    if not ok or not izi then
        return {}
    end

    if not self.menu_elements.heal.is_heal_enabled:get_state() then
        return {}
    end

    local max_range = tonumber(self.menu_elements.settings.max_range_heal:get()) or 40

    ---@type table<any, boolean>
    local seen = {}
    ---@type game_object[]
    local candidates = {}

    local function add(u)
        if not is_valid_ally_unit(u) then
            return
        end
        if seen[u] then
            return
        end
        seen[u] = true
        candidates[#candidates + 1] = u
    end

    if type(izi.me) == "function" then
        add(izi.me())
    end

    if type(izi.party) == "function" then
        local party = izi.party(max_range)
        if type(party) == "table" then
            for i = 1, #party do
                add(party[i])
            end
        end
    end

    if type(izi.friends) == "function" then
        local friends = izi.friends(max_range)
        if type(friends) == "table" then
            for i = 1, #friends do
                add(friends[i])
            end
        end
    end

    table.sort(candidates, function(a, b)
        local ahp = (a.get_health_percentage and a:get_health_percentage()) or 100
        local bhp = (b.get_health_percentage and b:get_health_percentage()) or 100
        if ahp == bhp then
            return false
        end
        return ahp < bhp
    end)

    if #candidates <= n then
        return candidates
    end

    local out = {}
    for i = 1, n do
        out[i] = candidates[i]
    end
    return out
end

return target_selector
