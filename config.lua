Config = {}

-- Debug mode - shows target zones and console logs
Config.Debug = false

-- Inventory item names to require.
-- Depending on your server/items this might be:
-- "weapon_lasso", "lasso", "WEAPON_LASSO", etc.
Config.RequiredLassoItem = {'Sandard Lasso', 'Reinforced Lasso'}

-- One or more arenas / roping zones
Config.Arenas = {
    {
        name = "McFarlane Roping Pen",
        zone = {
            coords = vector3(-2422.24, -2333.75, 61.18), -- center of start interaction
            radius = 3.0,                            -- how close to interact
        },

        cow = {
            model = 'a_c_pronghorn_01',                   -- change if your server uses different cow model
            spawn = vector4(-2419.57, -2328.16, 61.37, 128.50), -- spawn point
            runTo = vector3(-2476.67, -2372.57, 61.18), -- finish point (cow tries to reach)
        },

        countdownSeconds = 3,  -- countdown before start

        hogtie = {
            headDistance = 1.5,   -- must be close to head to hogtie
            key = 0x760A9C6F,     -- INPUT_DETONATE (G)
            progressMs = 1800,
        },

        flee = {
            runSeconds = 7,
            despawnAfterSeconds = 6,
        },
    }
}

-- Cow behavior tuning
Config.CowBehavior = {
    runSpeed = 2.5,           -- 1.0 walk, 2.0 jog/run; animals vary
    refreshRunTaskMs = 2000,  -- re-issue run task to keep it moving
    zigZagChance = 0.50,      -- chance to add slight random offset each refresh
    zigZagRadius = 9.0,       -- how far cow deviates laterally
}

-- UI text
Config.Text = {
    targetLabel = "Start Pronghorn Roping",
    needLasso = "You need a lasso to do pronghorn roping.",
    busy = "Roping is already in progress.",
    countdown = "Get ready...",
    ropeIt = "Rope the pronghorn!",
    hogtiePrompt = "Press ~e~G~q~ to hogtie",
    hogtied = "Hogtied!",
    release = "Cut free... it's running!",
}
