local izi = require("common/izi_sdk")
local enums = require("common/enums")
local spell = izi.spell

local BUFFS = enums.buff_db

---@class feral_druid_spells
local SPELLS =
{
    --Damage Builders
    SHRED = spell(5221),
    RAKE = spell(1822),
    SWIPE = spell(213764),
    MOONFIRE = spell(8921),

    --Damage Finishers
    RIP = spell(1079),
    FEROCIOUS_BITE = spell(22568),
    PRIMAL_WRATH = spell(285381),

    --Cooldowns
    TIGERS_FURY = spell(5217),
    BERSERK = spell(106951),
    INCARNATION_AVATAR_OF_ASHAMANE = spell(102543),
    CONVOKE_THE_SPIRITS = spell(391528),
    FERAL_FRENZY = spell(274837),
    FRANTIC_FRENZY = spell(1243807),

    --Druid of the Claw
    CHOMP = spell(1244258),

    --Defensives
    BARKSKIN = spell(22812),
    SURVIVAL_INSTINCTS = spell(61336),

    --Utility
    MARK_OF_THE_WILD = spell(1126),
    PROWL = spell(5215),

    --Passives (these are just used to check for talents)
    LUNAR_INSPIRATION = spell(155580),
    RAVAGE = spell(441583),

    -- Druid Forms
    CAT_FORM = spell(768),
    BEAR_FORM = spell(5487),
    TRAVEL_FORM = spell(783),
}

--Track debuffs for DoT management
SPELLS.RAKE:track_debuff(BUFFS.RAKE)
SPELLS.RIP:track_debuff(BUFFS.RIP)
SPELLS.MOONFIRE:track_debuff(BUFFS.MOONFIRE)

return SPELLS
