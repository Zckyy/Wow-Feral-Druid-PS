---@meta menu
local m = core.menu
local key_helper = require("common/utility/key_helper")
local control_panel_utility = require("common/utility/control_panel_helper")

--Constants
local PLUGIN_PREFIX = "blaze_feral_druid"
local TTD_MIN = 1
local TTD_MAX = 120
local TTD_DEFAULT = 16
local TTD_DEFAULT_AOE = 20

---Creates an ID with prefix for our rotation so we don't need to type it every time
---@param key string
local function id(key)
    return string.format("%s_%s", PLUGIN_PREFIX, key)
end

---@class feral_druid_menu
local menu =
{
    --Global
    MAIN_TREE = m.tree_node(),
    GLOBAL_CHECK = m.checkbox(true, id("global_toggle")),

    --Keybinds
    KEYBIND_TREE = m.tree_node(),
    ROTATION_KEYBIND = m.keybind(7, false, id("rotation_toggle")),
    BERSERK_KEYBIND = m.keybind(7, false, id("berserk_keybind")),
    CONVOKE_KEYBIND = m.keybind(7, false, id("convoke_keybind")),
    FERAL_FRENZY_KEYBIND = m.keybind(7, false, id("feral_frenzy_keybind")),

    --Cooldowns
    COOLDOWNS_TREE = m.tree_node(),

    --Berserk
    BERSERK_TREE = m.tree_node(),
    BERSERK_CHECK = m.checkbox(true, id("berserk_toggle")),
    BERSERK_MIN_TTD = m.slider_float(TTD_MIN, TTD_MAX, TTD_DEFAULT, id("berserk_min_ttd")),
    BERSERK_MIN_TTD_AOE = m.slider_float(TTD_MIN, TTD_MAX, TTD_DEFAULT_AOE, id("berserk_min_ttd_aoe")),

    --Convoke the Spirits
    CONVOKE_TREE = m.tree_node(),
    CONVOKE_CHECK = m.checkbox(true, id("convoke_toggle")),
    CONVOKE_MIN_TTD = m.slider_float(TTD_MIN, TTD_MAX, TTD_DEFAULT, id("convoke_min_ttd")),
    CONVOKE_MIN_TTD_AOE = m.slider_float(TTD_MIN, TTD_MAX, TTD_DEFAULT_AOE, id("convoke_min_ttd_aoe")),

    --Feral/Frantic Frenzy
    FERAL_FRENZY_TREE = m.tree_node(),
    FERAL_FRENZY_CHECK = m.checkbox(true, id("feral_frenzy_toggle")),
    FERAL_FRENZY_MIN_TTD = m.slider_float(TTD_MIN, TTD_MAX, TTD_DEFAULT, id("feral_frenzy_min_ttd")),
    FERAL_FRENZY_MIN_TTD_AOE = m.slider_float(TTD_MIN, TTD_MAX, TTD_DEFAULT_AOE, id("feral_frenzy_min_ttd_aoe")),

    --Defensives
    DEFENSIVES_TREE = m.tree_node(),

    --Barkskin
    BARKSKIN_TREE = m.tree_node(),
    BARKSKIN_CHECK = m.checkbox(true, id("barkskin_toggle")),
    BARKSKIN_MAX_HP = m.slider_int(1, 100, 80, id("barkskin_max_hp")),
    BARKSKIN_FUTURE_HP = m.slider_int(1, 100, 70, id("barkskin_max_future_hp")),

    --Survival Instincts
    SURVIVAL_INSTINCTS_TREE = m.tree_node(),
    SURVIVAL_INSTINCTS_CHECK = m.checkbox(true, id("survival_instincts_toggle")),
    SURVIVAL_INSTINCTS_MAX_HP = m.slider_int(1, 100, 50, id("survival_instincts_max_hp")),
    SURVIVAL_INSTINCTS_MAX_FUTURE_HP = m.slider_int(1, 100, 40, id("survival_instincts_max_future_hp")),

    --Utility
    UTILITY_TREE = m.tree_node(),
    AUTO_MARK_OF_THE_WILD_CHECK = m.checkbox(true, id("auto_mark_wild")),
    AUTO_CAT_FORM_CHECK = m.checkbox(true, id("auto_cat_form")),
    AUTO_PROWL_CHECK = m.checkbox(true, id("auto_prowl")),

    --Visuals
    VISUALS_TREE = m.tree_node(),
    DRAW_TS_LINE_CHECK = m.checkbox(true, id("draw_target_line")),
}

---@alias menu_validator_fn fun(value: number): boolean

---Creates a new validator function validating a checkbox and relevant slider value
---@param checkbox checkbox
---@param slider slider_int|slider_float
---@param type? "min"|"max"|"equal"
---@return menu_validator_fn
function menu.new_validator_fn(checkbox, slider, type)
    type = type or "min"

    return function(value)
        if not checkbox:get_state() then
            return false
        end
        
        local slider_value = slider:get()
        
        if type == "min" then
            return value >= slider_value
        elseif type == "max" then
            return value <= slider_value
        else
            return value == slider_value
        end
    end
end

--Returns true if the plugin is enabled
---@return boolean enabled
function menu:is_enabled()
    return self.GLOBAL_CHECK:get_state()
end

--Returns true if the plugin and rotation are enabled
---@return boolean enabled
function menu:is_rotation_enabled()
    return self.GLOBAL_CHECK:get_state() and self.ROTATION_KEYBIND:get_toggle_state()
end

--Alias our menu to M so its shorter when rendering and registering our validator functions
---@class feral_druid_menu
local M = menu

core.register_on_render_menu_callback(function()
    M.MAIN_TREE:render("Blaze Feral Druid", function()
        M.GLOBAL_CHECK:render("Plugin Enabled", "Global toggle for the plugin")

        if not M.GLOBAL_CHECK:get_state() then
            return
        end

        M.KEYBIND_TREE:render("Keybinds", function()
            M.ROTATION_KEYBIND:render("Rotation Enabled", "Toggles rotation on / off")
            M.BERSERK_KEYBIND:render("Berserk/Incarnation", "Keybind to cast Berserk or Incarnation")
            M.CONVOKE_KEYBIND:render("Convoke the Spirits", "Keybind to cast Convoke the Spirits")
            M.FERAL_FRENZY_KEYBIND:render("Feral/Frantic Frenzy", "Keybind to cast Feral/Frantic Frenzy")
        end)

        M.COOLDOWNS_TREE:render("Cooldowns", function()
            M.BERSERK_TREE:render("Berserk", function()
                M.BERSERK_CHECK:render("Enabled", "Toggles Berserk usage on / off")

                if M.BERSERK_CHECK:get_state() then
                    M.BERSERK_MIN_TTD:render("Min TTD",
                        "Minimum Time To Die (in seconds) to use Berserk")

                    M.BERSERK_MIN_TTD_AOE:render("Min TTD (AoE)",
                        "Minimum AoE TTD (in seconds) to use Berserk")
                end
            end)

            M.CONVOKE_TREE:render("Convoke the Spirits", function()
                M.CONVOKE_CHECK:render("Enabled", "Toggles Convoke the Spirits usage on / off")

                if M.CONVOKE_CHECK:get_state() then
                    M.CONVOKE_MIN_TTD:render("Min TTD", "Minimum Time To Die (in seconds) to use Convoke the Spirits")
                    M.CONVOKE_MIN_TTD_AOE:render("Min TTD (AoE)", "Minimum AoE TTD (in seconds) to use Convoke the Spirits")
                end
            end)

            M.FERAL_FRENZY_TREE:render("Feral/Frantic Frenzy", function()
                M.FERAL_FRENZY_CHECK:render("Enabled", "Toggles Feral/Frantic Frenzy usage on / off")

                if M.FERAL_FRENZY_CHECK:get_state() then
                    M.FERAL_FRENZY_MIN_TTD:render("Min TTD", "Minimum Time To Die (in seconds) to use Feral/Frantic Frenzy")

                    M.FERAL_FRENZY_MIN_TTD_AOE:render("Min TTD (AoE)",
                        "Minimum AoE TTD (in seconds) to use Feral/Frantic Frenzy")
                end
            end)
        end)

        M.DEFENSIVES_TREE:render("Defensives", function()
            M.BARKSKIN_TREE:render("Barkskin", function()
                M.BARKSKIN_CHECK:render("Enabled", "Toggles Barkskin usage on / off")
                M.BARKSKIN_MAX_HP:render("Max HP", "Maximum HP to use Barkskin")
                M.BARKSKIN_FUTURE_HP:render("Max Future HP", "Maximum Future HP to use Barkskin")
            end)

            M.SURVIVAL_INSTINCTS_TREE:render("Survival Instincts", function()
                M.SURVIVAL_INSTINCTS_CHECK:render("Enabled", "Toggles Survival Instincts usage on / off")
                M.SURVIVAL_INSTINCTS_MAX_HP:render("Max HP", "Maximum HP to use Survival Instincts")
                M.SURVIVAL_INSTINCTS_MAX_FUTURE_HP:render("Max Future HP", "Maximum Future HP to use Survival Instincts")
            end)
        end)

        M.UTILITY_TREE:render("Utility", function()
            M.AUTO_MARK_OF_THE_WILD_CHECK:render("Auto Mark of the Wild", "Automatically cast Mark of the Wild")
            M.AUTO_CAT_FORM_CHECK:render("Auto Cat Form", "Automatically enter Cat Form")
            M.AUTO_PROWL_CHECK:render("Auto Prowl (OOC)", "Automatically use Prowl out of combat")
        end)

        M.VISUALS_TREE:render("Visuals", function()
            M.DRAW_TS_LINE_CHECK:render("Draw Target Line", "Draw a line from you to the target")
        end)
    end)
end)

core.register_on_render_control_panel_callback(function()
    local rotation_toggle_key = M.ROTATION_KEYBIND:get_key_code()
    local rotation_toggle =
    {
        name = string.format("[Blaze] Enabled (%s)", key_helper:get_key_name(rotation_toggle_key)),
        keybind = M.ROTATION_KEYBIND
    }

    local control_panel_elements = {}

    if M:is_enabled() then
        control_panel_utility:insert_toggle_(control_panel_elements, rotation_toggle.name, rotation_toggle.keybind, false)
        
        -- Cooldown Keybinds
        local berserk_key = M.BERSERK_KEYBIND:get_key_code()
        control_panel_utility:insert_toggle_(control_panel_elements, 
            string.format("[Blaze] Berserk/Incarn (%s)", key_helper:get_key_name(berserk_key)), 
            M.BERSERK_KEYBIND, false)
        
        local convoke_key = M.CONVOKE_KEYBIND:get_key_code()
        control_panel_utility:insert_toggle_(control_panel_elements, 
            string.format("[Blaze] Convoke (%s)", key_helper:get_key_name(convoke_key)), 
            M.CONVOKE_KEYBIND, false)
        
        local feral_frenzy_key = M.FERAL_FRENZY_KEYBIND:get_key_code()
        control_panel_utility:insert_toggle_(control_panel_elements, 
            string.format("[Blaze] Feral/Frantic Frenzy (%s)", key_helper:get_key_name(feral_frenzy_key)), 
            M.FERAL_FRENZY_KEYBIND, false)
    end

    return control_panel_elements
end)

--Cooldown Validators
M.validate_berserk = M.new_validator_fn(M.BERSERK_CHECK, M.BERSERK_MIN_TTD)
M.validate_berserk_aoe = M.new_validator_fn(M.BERSERK_CHECK, M.BERSERK_MIN_TTD_AOE)
M.validate_convoke = M.new_validator_fn(M.CONVOKE_CHECK, M.CONVOKE_MIN_TTD)
M.validate_convoke_aoe = M.new_validator_fn(M.CONVOKE_CHECK, M.CONVOKE_MIN_TTD_AOE)
M.validate_feral_frenzy = M.new_validator_fn(M.FERAL_FRENZY_CHECK, M.FERAL_FRENZY_MIN_TTD)
M.validate_feral_frenzy_aoe = M.new_validator_fn(M.FERAL_FRENZY_CHECK, M.FERAL_FRENZY_MIN_TTD_AOE)

return menu