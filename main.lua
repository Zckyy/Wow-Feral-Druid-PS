--Import our dependencies
local SPELLS = require("extra/spells")
local menu = require("extra/menu")
local izi = require("common/izi_sdk")
local enums = require("common/enums")

--Define our constants
local BUFFS = enums.buff_db

--Delay for rotation after dismounting
local DISMOUNT_DELAY_MS = 1000

--Pandemic threshold for DoTs (30% of base duration)
local RAKE_PANDEMIC_THRESHOLD_SEC = 15 * 0.30
local RIP_PANDEMIC_THRESHOLD_SEC = 24 * 0.30
local MOONFIRE_PANDEMIC_THRESHOLD_SEC = 22 * 0.30

--We define some local variables that we will update later
local game_time_ms = 0
local combo_points = 0
local energy = 0
local last_mounted_time_ms = 0
local energy_below_30_time_ms = 0
local last_feral_frenzy_cast_ms = 0
local last_frantic_frenzy_cast_ms = 0

--Energy costs / thresholds (Dragonflight / TWW tuning as of 2026-02)
local ENERGY_COST_SHRED = 40
local ENERGY_COST_RAKE = 35
local ENERGY_COST_RIP = 20
local ENERGY_COST_SWIPE = 35
local ENERGY_COST_PRIMAL_WRATH = 25
local ENERGY_COST_FERAL_OR_FRANTIC_FRENZY = 25
--Ferocious Bite costs 25, but we hold for 50 to allow the +25 energy consume for 100% damage.
local ENERGY_THRESHOLD_FEROCIOUS_BITE = 50
local ENERGY_COST_FEROCIOUS_BITE = 25

-- If we had to leave Cat Form to break a root and Auto Cat Form is disabled,
-- we'll re-enter Cat Form once the root is gone.
local recat_pending = false

--Cache frequently used spell IDs (avoids repeated method calls in hot paths)
local ID_MARK_OF_THE_WILD = SPELLS.MARK_OF_THE_WILD:id()
local ID_CAT_FORM = SPELLS.CAT_FORM:id()
local ID_TRAVEL_FORM = SPELLS.TRAVEL_FORM:id()
local ID_PROWL = SPELLS.PROWL:id()

--Returns the time in milliseconds since the last dismount
---@return number time_since_last_dismount_ms
local function time_since_last_dismount_ms()
    return game_time_ms - last_mounted_time_ms
end

---Checks if Chomp is available (energy < 30% or within 2 seconds of dropping below 30%)
---@return boolean is_chomp_available
local function is_chomp_available()
    if energy < 30 then
        return true
    end

    --Check if we're within 2 seconds of energy dropping below 30%
    local time_since_below_30_ms = game_time_ms - energy_below_30_time_ms
    return time_since_below_30_ms <= 2000
end

---Checks if we're waiting for combo points from Feral/Frantic Frenzy to be awarded
---These abilities award 5 combo points over ~1 second, so we need to wait
---@return boolean is_waiting_for_frenzy_combo_points
local function is_waiting_for_frenzy_combo_points()
    local time_since_feral_frenzy = game_time_ms - last_feral_frenzy_cast_ms
    local time_since_frantic_frenzy = game_time_ms - last_frantic_frenzy_cast_ms

    --Wait up to 1500ms for combo points to be awarded, but stop waiting once we reach max CPs
    if time_since_feral_frenzy <= 1500 and time_since_feral_frenzy > 0 and combo_points < 5 then
        return true
    end

    if time_since_frantic_frenzy <= 1500 and time_since_frantic_frenzy > 0 and combo_points < 5 then
        return true
    end

    return false
end

---Checks if Rake needs to be applied or refreshed (pandemic window)
---@param target game_object
---@return boolean needs_rake
local function needs_rake(target)
    if not target:has_debuff(BUFFS.RAKE) then
        return true
    end
    local remaining = target:debuff_remains(BUFFS.RAKE)
    return remaining <= RAKE_PANDEMIC_THRESHOLD_SEC
end

---Checks if Rip needs to be applied or refreshed (pandemic window)
---@param target game_object
---@return boolean needs_rip
local function needs_rip(target)
    if not target:has_debuff(BUFFS.RIP) then
        return true
    end
    local remaining = target:debuff_remains(BUFFS.RIP)
    return remaining <= RIP_PANDEMIC_THRESHOLD_SEC
end

---Checks if Moonfire needs to be applied or refreshed (pandemic window)
---@param target game_object
---@return boolean needs_moonfire
local function needs_moonfire(target)
    if not target:has_debuff(BUFFS.MOONFIRE) then
        return true
    end
    local remaining = target:debuff_remains(BUFFS.MOONFIRE)
    return remaining <= MOONFIRE_PANDEMIC_THRESHOLD_SEC
end

---Handles utility and precombat actions
---@param me game_object
---@param in_combat boolean
---@return boolean success
local function utility(me, in_combat)
    --Mark of the Wild
    if menu.AUTO_MARK_OF_THE_WILD_CHECK:get_state() and not me:has_buff(ID_MARK_OF_THE_WILD) then
        if SPELLS.MARK_OF_THE_WILD:cast_safe(me, "Mark of the Wild") then
            return true
        end
    end

    --Cat Form
    if menu.AUTO_CAT_FORM_CHECK:get_state() and not me:has_buff(ID_CAT_FORM) then
        if SPELLS.CAT_FORM:cast_safe(nil, "Cat Form") then
            return true
        end
    end

    --Prowl (only out of combat)
    if not in_combat and menu.AUTO_PROWL_CHECK:get_state() and me:has_buff(ID_CAT_FORM) and not me:has_buff(ID_PROWL) then
        if SPELLS.PROWL:cast_safe(nil, "Prowl") then
            return true
        end
    end

    return false
end

--Defensive spell options/filters (reused to avoid per-tick allocations)
---@type unit_cast_opts
local DEF_OPTS = { skip_gcd = true }

---@type defensive_filters
local BARKSKIN_FILTERS =
{
    health_percentage_threshold_raw = 0,
    health_percentage_threshold_incoming = 0,
}

---@type defensive_filters
local SURVIVAL_INSTINCTS_FILTERS =
{
    health_percentage_threshold_raw = 0,
    health_percentage_threshold_incoming = 0,
}

---Handles defensive spells
---@param me game_object
---@return boolean
local function defensives(me)
    BARKSKIN_FILTERS.health_percentage_threshold_raw = menu.BARKSKIN_MAX_HP:get()
    BARKSKIN_FILTERS.health_percentage_threshold_incoming = menu.BARKSKIN_FUTURE_HP:get()

    if SPELLS.BARKSKIN:cast_defensive(me, BARKSKIN_FILTERS, "Barkskin", DEF_OPTS) then
        return true
    end

    SURVIVAL_INSTINCTS_FILTERS.health_percentage_threshold_raw = menu.SURVIVAL_INSTINCTS_MAX_HP:get()
    SURVIVAL_INSTINCTS_FILTERS.health_percentage_threshold_incoming = menu.SURVIVAL_INSTINCTS_MAX_FUTURE_HP:get()

    if SPELLS.SURVIVAL_INSTINCTS:cast_defensive(me, SURVIVAL_INSTINCTS_FILTERS, "Survival Instincts", DEF_OPTS) then
        return true
    end

    return false
end

---Handles single target rotation based on Druid of The Claw APL
---@param me game_object
---@param target game_object
---@param use_berserk boolean
---@param use_convoke boolean
---@param use_frenzy boolean
---@param has_lunar_inspiration boolean
---@param has_frantic_frenzy boolean
---@return boolean success
local function single_target(me, target, use_berserk, use_convoke, use_frenzy, has_lunar_inspiration, has_frantic_frenzy)
    local ttd = target:time_to_die()
    local target_distance = me:distance_to(target)
    local has_clearcasting_feral = me:has_buff(BUFFS.CLEARCASTING_FERAL)

    --Check Tiger's Fury status for cooldown syncing
    local has_tigers_fury = me:has_buff(BUFFS.TIGERS_FURY)
    local tigers_fury_ready = SPELLS.TIGERS_FURY:cooldown_up()

    --Check for cooldown usage validity
    local berserk_valid = menu.validate_berserk(ttd)
    local convoke_valid = menu.validate_convoke(ttd)
    local feral_frenzy_valid = menu.validate_feral_frenzy(ttd)

    --Rake if prowl buff is up
    if me:has_buff(ID_PROWL) then
        if energy >= ENERGY_COST_RAKE and SPELLS.RAKE:cast_safe(target, "Rake (Prowl)") then
            return true
        end
    end

    --Cooldowns: use on cooldown (no manual syncing/holding).
    --Tiger's Fury is used immediately when available (cannot be refreshed while buff is active).
    if target_distance <= 8 and tigers_fury_ready and (not has_tigers_fury) then
        if SPELLS.TIGERS_FURY:cast_safe(nil, "Tiger's Fury") then
            return true
        end
    end

    --Berserk - use immediately when ready (only if keybind is enabled)
    if use_berserk and berserk_valid and SPELLS.BERSERK:cooldown_up() and me:has_buff(BUFFS.TIGERS_FURY) and SPELLS.BERSERK:cast_safe(nil, "Berserk") then
        return true
    end

    --Convoke the Spirits - use immediately when ready (only if keybind is enabled)
    if use_convoke and convoke_valid and SPELLS.CONVOKE_THE_SPIRITS:cooldown_up() and me:has_buff(BUFFS.TIGERS_FURY) and target_distance <= 8 then
        --Convoke awards combo points rapidly; avoid entering Convoke while capped.
        if combo_points == 5 then
            if me:has_buff(BUFFS.APEX_PREDATORS_CRAVING) and SPELLS.FEROCIOUS_BITE:cast_safe(target, "Ferocious Bite (Pre-Convoke/Apex)") then
                return true
            end

            if needs_rip(target) and energy >= ENERGY_COST_RIP and SPELLS.RIP:cast_safe(target, "Rip (Pre-Convoke)") then
                return true
            end

            if energy >= ENERGY_COST_FEROCIOUS_BITE and SPELLS.FEROCIOUS_BITE:cast_safe(target, "Ferocious Bite (Pre-Convoke)") then
                return true
            end
        end

        if SPELLS.CONVOKE_THE_SPIRITS:cast_safe(nil, "Convoke") then
            return true
        end
    end

    --Chomp if energy < 30% or within 2 seconds of dropping below 30%
    if is_chomp_available() then
        if SPELLS.CHOMP:cast_safe(target, "Chomp") then
            return true
        end
    end

    --Rip if needs refreshing (pandemic) and combo_points>=5
    if needs_rip(target) and combo_points >= 5 then
        if energy >= ENERGY_COST_RIP and SPELLS.RIP:cast_safe(target, "Rip") then
            return true
        end
    end

    --Ferocious Bite if combo_points>=5
    if combo_points >= 5 and energy >= ENERGY_THRESHOLD_FEROCIOUS_BITE then
        if SPELLS.FEROCIOUS_BITE:cast_safe(target, "Ferocious Bite (5 CP)") then
            return true
        end
    end

    --Ferocious Bite if apex_predators_craving buff is up
    if me:has_buff(BUFFS.APEX_PREDATORS_CRAVING) then
        if SPELLS.FEROCIOUS_BITE:cast_safe(target, "Ferocious Bite (Apex)") then
            return true
        end
    end

    --Feral Frenzy if combo_points<=1 and Tiger's Fury buff is up (only if Frantic Frenzy not learned and keybind enabled)
    if use_frenzy and energy >= ENERGY_COST_FERAL_OR_FRANTIC_FRENZY and not has_frantic_frenzy and feral_frenzy_valid and combo_points <= 1 and has_tigers_fury then
        if SPELLS.FERAL_FRENZY:cast_safe(target, "Feral Frenzy (TF)") then
            last_feral_frenzy_cast_ms = game_time_ms
            return true
        end
    end

    --Feral Frenzy if combo_points<=1 and Tiger's Fury not ready (only if Frantic Frenzy not learned and keybind enabled)
    if use_frenzy and energy >= ENERGY_COST_FERAL_OR_FRANTIC_FRENZY and feral_frenzy_valid and not has_frantic_frenzy and combo_points <= 1 and not tigers_fury_ready then
        if SPELLS.FERAL_FRENZY:cast_safe(target, "Feral Frenzy") then
            last_feral_frenzy_cast_ms = game_time_ms
            return true
        end
    end

    --Frantic Frenzy if combo_points<=1 and distance<=8 and Tiger's Fury buff is up
    if use_frenzy and energy >= ENERGY_COST_FERAL_OR_FRANTIC_FRENZY and has_frantic_frenzy and combo_points <= 1 and target_distance <= 8 and has_tigers_fury and SPELLS.FRANTIC_FRENZY:cooldown_up() then
        if SPELLS.FRANTIC_FRENZY:cast_safe(target, "Frantic Frenzy (TF)") then
            last_frantic_frenzy_cast_ms = game_time_ms
            return true
        end
    end

    --Frantic Frenzy if combo_points<=1 and distance<=8 and Tiger's Fury not ready
    if use_frenzy and energy >= ENERGY_COST_FERAL_OR_FRANTIC_FRENZY and has_frantic_frenzy and combo_points <= 1 and target_distance <= 8 and not tigers_fury_ready and SPELLS.FRANTIC_FRENZY:cooldown_up() then
        if SPELLS.FRANTIC_FRENZY:cast_safe(target, "Frantic Frenzy") then
            last_frantic_frenzy_cast_ms = game_time_ms
            return true
        end
    end

    --Wait for combo points from Feral/Frantic Frenzy before continuing
    if is_waiting_for_frenzy_combo_points() then
        return false
    end

    --Rake if needs refreshing (pandemic)
    if needs_rake(target) and combo_points < 5 then
        if energy >= ENERGY_COST_RAKE and SPELLS.RAKE:cast_safe(target, "Rake") then
            return true
        end
    end

    --Moonfire if talent lunar_inspiration and needs refreshing (pandemic)
    if has_lunar_inspiration and needs_moonfire(target) then
        if SPELLS.MOONFIRE:cast_safe(target, "Moonfire") then
            return true
        end
    end

    --Shred (main builder)
    if combo_points < 5 and (has_clearcasting_feral or energy >= ENERGY_COST_SHRED) and SPELLS.SHRED:cast_safe(target, "Shred") then
        return true
    end

    --Moonfire if talent lunar_inspiration and distance>15
    if has_lunar_inspiration and target_distance > 15 then
        if SPELLS.MOONFIRE:cast_safe(target, "Moonfire (Range)") then
            return true
        end
    end

    return false
end

---Handles AoE rotation based on Druid of The Claw APL
---@param me game_object
---@param target game_object
---@param enemies_melee game_object[]
---@param use_berserk boolean
---@param use_convoke boolean
---@param use_frenzy boolean
---@param has_lunar_inspiration boolean
---@param has_frantic_frenzy boolean
---@return boolean
local function aoe(me, target, enemies_melee, use_berserk, use_convoke, use_frenzy, has_lunar_inspiration,
                   has_frantic_frenzy, has_primal_wrath)
    local ttd = izi.get_time_to_die_global()
    local target_distance = me:distance_to(target)
    local active_enemies = #enemies_melee
    local has_clearcasting_feral = me:has_buff(BUFFS.CLEARCASTING_FERAL)

    --Range-gate AoE builders: if we still need to apply/refresh Rake, do not
    --use Swipe (8y) to start combat while we're outside Rake range (~5y).
    --This ensures we open with Rake for the stun/bonus damage.
    if needs_rake(target) and target_distance > 5 then
        return false
    end

    --Check for cooldown usage validity
    local berserk_valid = menu.validate_berserk_aoe(ttd)
    local convoke_valid = menu.validate_convoke_aoe(ttd)
    local feral_frenzy_valid = menu.validate_feral_frenzy_aoe(ttd)

    --Check Tiger's Fury status for cooldown syncing
    local has_tigers_fury = me:has_buff(BUFFS.TIGERS_FURY)
    local tigers_fury_ready = SPELLS.TIGERS_FURY:cooldown_up()

    --Rake if prowl buff is up (HIGHEST PRIORITY - opener with stun and bonus damage)
    if me:has_buff(ID_PROWL) then
        if energy >= ENERGY_COST_RAKE and SPELLS.RAKE:cast_safe(target, "Rake (Prowl)") then
            return true
        end
    end

    --Cooldowns: use on cooldown (no manual syncing/holding).
    --Tiger's Fury is used immediately when available (cannot be refreshed while buff is active).
    if target_distance <= 8 and tigers_fury_ready and (not has_tigers_fury) then
        if SPELLS.TIGERS_FURY:cast_safe(nil, "Tiger's Fury") then
            return true
        end
    end

    --Berserk - use immediately when ready (only if keybind is enabled)
    if use_berserk and berserk_valid and SPELLS.BERSERK:cast_safe(nil, "Berserk") then
        return true
    end

    --Convoke the Spirits - use immediately when ready (only if keybind is enabled)
    if use_convoke and convoke_valid and target_distance <= 8 then
        --Convoke awards combo points rapidly; avoid entering Convoke while capped.
        if combo_points == 5 then
            if me:has_buff(BUFFS.APEX_PREDATORS_CRAVING) and SPELLS.FEROCIOUS_BITE:cast_safe(target, "Ferocious Bite (Pre-Convoke/Apex)") then
                return true
            end

            --Prefer Primal Wrath over Rip in AoE.
            if has_primal_wrath and needs_rip(target) and target_distance <= 10 and energy >= ENERGY_COST_PRIMAL_WRATH and SPELLS.PRIMAL_WRATH:cast_safe(target, "Primal Wrath (Pre-Convoke)") then
                return true
            end

            if (not has_primal_wrath) and needs_rip(target) and energy >= ENERGY_COST_RIP and SPELLS.RIP:cast_safe(target, "Rip (Pre-Convoke)") then
                return true
            end

            if energy >= ENERGY_COST_FEROCIOUS_BITE and SPELLS.FEROCIOUS_BITE:cast_safe(target, "Ferocious Bite (Pre-Convoke)") then
                return true
            end
        end

        if SPELLS.CONVOKE_THE_SPIRITS:cast_safe(nil, "Convoke") then
            return true
        end
    end

    --Chomp if energy < 30% or within 2 seconds of dropping below 30%
    if is_chomp_available() then
        if SPELLS.CHOMP:cast_safe(target, "Chomp") then
            return true
        end
    end

    --Primal Wrath if learned and needs refreshing (pandemic) and combo_points>=5 and distance<=10
    --Prefer Primal Wrath over Rip in AoE since it applies Rip to all nearby enemies
    if has_primal_wrath and needs_rip(target) and combo_points >= 5 and target_distance <= 10 then
        if energy >= ENERGY_COST_PRIMAL_WRATH and SPELLS.PRIMAL_WRATH:cast_safe(target, "Primal Wrath (AoE)") then
            return true
        end
    end

    --Rip per-target in AoE ONLY if Primal Wrath is not learned
    if (not has_primal_wrath) and needs_rip(target) and combo_points >= 5 then
        if energy >= ENERGY_COST_RIP and SPELLS.RIP:cast_safe(target, "Rip") then
            return true
        end
    end

    --Ferocious Bite if combo_points>=5
    if combo_points >= 5 and energy >= ENERGY_THRESHOLD_FEROCIOUS_BITE then
        if SPELLS.FEROCIOUS_BITE:cast_safe(target, "Ferocious Bite (5 CP)") then
            return true
        end
    end

    --Ferocious Bite if apex_predators_craving buff is up
    if me:has_buff(BUFFS.APEX_PREDATORS_CRAVING) then
        if SPELLS.FEROCIOUS_BITE:cast_safe(target, "Ferocious Bite (Apex)") then
            return true
        end
    end

    --Feral Frenzy if combo_points<=1 and Tiger's Fury buff is up (only if Frantic Frenzy not learned and keybind enabled)
    if use_frenzy and energy >= ENERGY_COST_FERAL_OR_FRANTIC_FRENZY and not has_frantic_frenzy and feral_frenzy_valid and combo_points <= 1 and has_tigers_fury then
        if SPELLS.FERAL_FRENZY:cast_safe(target, "Feral Frenzy (TF)") then
            last_feral_frenzy_cast_ms = game_time_ms
            return true
        end
    end

    --Feral Frenzy if combo_points<=1 and Tiger's Fury not ready (only if Frantic Frenzy not learned and keybind enabled)
    if use_frenzy and energy >= ENERGY_COST_FERAL_OR_FRANTIC_FRENZY and feral_frenzy_valid and not has_frantic_frenzy and combo_points <= 1 and not tigers_fury_ready then
        if SPELLS.FERAL_FRENZY:cast_safe(target, "Feral Frenzy") then
            last_feral_frenzy_cast_ms = game_time_ms
            return true
        end
    end

    --Frantic Frenzy if combo_points<=1 and distance<=8 and Tiger's Fury buff is up
    if use_frenzy and energy >= ENERGY_COST_FERAL_OR_FRANTIC_FRENZY and combo_points <= 1 and target_distance <= 8 and has_tigers_fury and SPELLS.FRANTIC_FRENZY:cooldown_up() then
        if SPELLS.FRANTIC_FRENZY:cast_safe(target, "Frantic Frenzy (TF)") then
            last_frantic_frenzy_cast_ms = game_time_ms
            return true
        end
    end

    --Frantic Frenzy if combo_points<=1 and distance<=8 and Tiger's Fury not ready
    if use_frenzy and energy >= ENERGY_COST_FERAL_OR_FRANTIC_FRENZY and combo_points <= 1 and target_distance <= 8 and not tigers_fury_ready and SPELLS.FRANTIC_FRENZY:cooldown_up() then
        if SPELLS.FRANTIC_FRENZY:cast_safe(target, "Frantic Frenzy") then
            last_frantic_frenzy_cast_ms = game_time_ms
            return true
        end
    end

    --Wait for combo points from Feral/Frantic Frenzy before continuing
    if is_waiting_for_frenzy_combo_points() then
        return false
    end

    --Rake if needs refreshing (pandemic)
    if needs_rake(target) then
        if energy >= ENERGY_COST_RAKE and SPELLS.RAKE:cast_safe(target, "Rake") then
            return true
        end
    end

    --Moonfire if talent lunar_inspiration and needs refreshing (pandemic)
    if has_lunar_inspiration and needs_moonfire(target) then
        if SPELLS.MOONFIRE:cast_safe(target, "Moonfire") then
            return true
        end
    end

    --Swipe if distance<=8 and active_enemies>3 (main builder in aoe)
    if target_distance <= 8 and active_enemies >= 2 and combo_points < 5 then
        if (has_clearcasting_feral or energy >= ENERGY_COST_SWIPE) and SPELLS.SWIPE:cast_safe(target, "Swipe (AoE)") then
            return true
        end
    end

    --Moonfire if talent lunar_inspiration and distance>15
    if has_lunar_inspiration and target_distance > 15 then
        if SPELLS.MOONFIRE:cast_safe(target, "Moonfire (Range)") then
            return true
        end
    end

    return false
end

core.register_on_update_callback(function()
    --Check if the rotation is enabled
    if not menu:is_enabled() then
        return
    end

    --Get the local player
    local me = izi.me()

    --Check if the local player exists and is valid
    if not (me and me.is_valid and me:is_valid()) then
        return
    end

    --Update our commonly used values
    game_time_ms = izi.now_game_time_ms()
    combo_points = me:get_power(enums.power_type.COMBOPOINTS)
    energy = me:get_power(enums.power_type.ENERGY)

    --Track when energy falls below 30% for Chomp availability
    if energy < 30 then
        energy_below_30_time_ms = game_time_ms
    end

    --Update the local player's last mounted/travel-form time.
    -- Travel Form (including flight) must behave like mounting: no rotation/utility actions.
    if me:is_mounted() or me:is_flying() or me:has_buff(ID_TRAVEL_FORM) then
        last_mounted_time_ms = game_time_ms
        return
    end

    --Delay actions after dismounting
    local time_dismounted_ms = time_since_last_dismount_ms()

    if time_dismounted_ms < DISMOUNT_DELAY_MS then
        return
    end

    --Check if we're in combat
    local in_combat = me:is_in_combat()

    -- Root handling:
    -- If we're rooted while in Cat Form, we want to leave Cat Form to break the root.
    -- If Auto Cat Form is disabled, queue re-entering Cat Form once root is cleared.
    local is_rooted = me:is_rooted()

    if recat_pending then
        if menu.AUTO_CAT_FORM_CHECK:get_state() then
            recat_pending = false
        elseif (not is_rooted) then
            if me:has_buff(ID_CAT_FORM) then
                recat_pending = false
            elseif SPELLS.CAT_FORM:cast_safe(nil, "Cat Form (Post-Root)") then
                recat_pending = false
                return
            end
        end
    end

    if is_rooted and me:has_buff(ID_CAT_FORM) then
        local left_cat = false

        -- Attempt to leave Cat Form by toggling it off.
        if SPELLS.CAT_FORM:cast_safe(nil, "Cancel Cat Form (Root)") then
            left_cat = true
            -- Fallback: force a shapeshift to guarantee we leave Cat Form.
        elseif SPELLS.BEAR_FORM:cast_safe(nil, "Bear Form (Root Break)") then
            left_cat = true
        end

        if left_cat then
            if not menu.AUTO_CAT_FORM_CHECK:get_state() then
                recat_pending = true
            end
            return
        end
    end

    --Execute our utility/precombat
    if utility(me, in_combat) then
        return
    end

    --If the rotation is paused let's return early
    if not menu:is_rotation_enabled() then
        return
    end

    --Get enemies within melee range
    local enemies_melee = me:get_enemies_in_melee_range(8)

    --Check if we are in an AoE scenario
    local is_aoe = #enemies_melee > 1

    --Execute our defensives
    if defensives(me) then
        return
    end

    --Get target selector targets
    local targets = izi.get_ts_targets()

    --Compute toggles/talents once per update (used across multiple target iterations)
    local use_berserk = menu.BERSERK_KEYBIND:get_toggle_state()
    local use_convoke = menu.CONVOKE_KEYBIND:get_toggle_state()
    local use_frenzy = menu.FERAL_FRENZY_KEYBIND:get_toggle_state()
    local has_lunar_inspiration = SPELLS.LUNAR_INSPIRATION:is_learned()
    local has_frantic_frenzy = SPELLS.FRANTIC_FRENZY:is_learned()
    local has_primal_wrath = SPELLS.PRIMAL_WRATH:is_learned()

    --Iterate over targets and run rotation logic
    for i = 1, #targets do
        local target = targets[i]

        --Check if the target is valid otherwise skip it
        if not (target and target.is_valid and target:is_valid()) then
            goto continue
        end

        --If the target is immune to any damage, skip it
        if target:is_damage_immune(target.DMG.ANY) then
            goto continue
        end

        --If the target is in a CC that breaks from damage, skip it
        if target:is_cc_weak() then
            goto continue
        end

        --Damage rotation
        if is_aoe then
            --If we are in aoe lets call our AoE handler
            if aoe(me, target, enemies_melee, use_berserk, use_convoke, use_frenzy, has_lunar_inspiration, has_frantic_frenzy, has_primal_wrath) then
                return
            end
        else
            --If we are single target lets call our single target handler
            if single_target(me, target, use_berserk, use_convoke, use_frenzy, has_lunar_inspiration, has_frantic_frenzy) then
                return
            end
        end

        ::continue::
    end
end)