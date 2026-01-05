local RSGCore = exports['rsg-core']:GetCoreObject()

local activeRun = false
local activeCow = nil
local activeArenaIndex = nil
local uncutZoneId = nil
local hogtied = false  -- Track hogtie state across functions

-- -------------------------------------------------------
-- Helpers (natives vary on RedM builds; keep wrappers safe)
-- -------------------------------------------------------
local function notify(msg, msgType)
    lib.notify({
        title = 'Pronghorn Roping',
        description = msg,
        type = msgType or 'inform'
    })
end

local function LoadModel(model)
    local hash = joaat(model)
    RequestModel(hash)
    local timeout = GetGameTimer() + 10000
    while not HasModelLoaded(hash) do
        Wait(50)
        if GetGameTimer() > timeout then return nil end
    end
    return hash
end

local function SpawnAnimal(model, coords, heading)
    print("[ROPE] Attempting to spawn: " .. model)
    
    local hash = joaat(model)
    
    -- Request and wait for model
    RequestModel(hash)
    local timeout = GetGameTimer() + 10000
    while not HasModelLoaded(hash) do
        Wait(100)
        if GetGameTimer() > timeout then
            print("[ROPE] Model load timeout: " .. model)
            return nil
        end
    end
    
    print("[ROPE] Model loaded, spawning ped...")
    
    -- Spawn with networked parameters for multiplayer visibility
    local ped = CreatePed(hash, coords.x, coords.y, coords.z, heading or 0.0, true, true, false, false)
    
    if not ped or ped == 0 then
        print("[ROPE] Failed to create ped")
        return nil
    end
    
    print("[ROPE] Ped created successfully: " .. tostring(ped))
    
    -- Post-creation setup - aggressive visibility (like working rodeo script)
    Wait(100)
    SetEntityAsMissionEntity(ped, true, true)
    NetworkRegisterEntityAsNetworked(ped)
    SetEntityVisible(ped, true)
    SetEntityAlpha(ped, 255, false)
    SetEntityCollision(ped, true, true)
    FreezeEntityPosition(ped, false)
    SetEntityInvincible(ped, true)
    SetBlockingOfNonTemporaryEvents(ped, true)
    
    -- Force visibility with rendering natives
    Citizen.InvokeNative(0xEA02E132F5C68722, ped) -- SetEntityVisible native
    Citizen.InvokeNative(0x283978A15512B2FE, ped, true) -- SetEntityAlwaysPrerender
    
    print("[ROPE] Applied visibility and mission entity setup")
    
    -- Debug checks
    print('[ROPE] visible?', IsEntityVisible(ped))
    print('[ROPE] alpha?', GetEntityAlpha(ped))
    print('[ROPE] model hash?', GetEntityModel(ped))
    
    return ped
end

local function safeDeleteEntity(ent)
    if ent and DoesEntityExist(ent) then
        SetEntityAsMissionEntity(ent, true, true)
        DeleteEntity(ent)
    end
end

local function normalize(vec)
    local len = #vec
    if len == 0 then return vec3(0, 0, 0) end
    return vec / len
end

-- Try to detect if cow is lassoed (native name/hashes can vary)
local function isEntityLassoed(entity)
    if not entity or not DoesEntityExist(entity) then return false end

    -- Attempt a few known patterns; if none work, fall back to "hogtie only when close + cow stopped"
    local ok, result

    -- Pattern A: Citizen.InvokeNative with guessed hash (may fail harmlessly)
    ok, result = pcall(function()
        -- Some builds expose _IS_PED_LASSOED / IS_PED_LASSOED; if this hash is wrong it just errors inside pcall
        return Citizen.InvokeNative(0x9682F850056C9ADE, entity) -- common RDR2 hash used by some scripts
    end)
    if ok and type(result) == 'boolean' then return result end

    -- Pattern B: another commonly used hash by community scripts (varies)
    ok, result = pcall(function()
        return Citizen.InvokeNative(0xE3B6097CC25AA69E, entity)
    end)
    if ok and type(result) == 'boolean' then return result end

    return false
end

local function taskCowRunTo(arena)
    if not activeCow or not DoesEntityExist(activeCow) then return end

    local target = arena.cow.runTo
    local runSpeed = Config.CowBehavior.runSpeed
    local zigChance = Config.CowBehavior.zigZagChance
    local zigRadius = Config.CowBehavior.zigZagRadius

    local tx, ty, tz = target.x, target.y, target.z

    if math.random() < zigChance then
        tx = tx + (math.random() * 2.0 - 1.0) * zigRadius
        ty = ty + (math.random() * 2.0 - 1.0) * zigRadius
    end

    -- Keep it moving; animals respond differently, so we re-issue periodically
    TaskGoStraightToCoord(activeCow, tx, ty, tz, runSpeed, -1, 0.0, 0.0)
end

local function getCowHeadCoords(cow)
    -- head bone is often "SKEL_Head" but animals vary; fallback to entity coords
    local headBone = GetEntityBoneIndexByName(cow, "SKEL_Head")
    if headBone and headBone ~= -1 then
        return GetWorldPositionOfEntityBone(cow, headBone)
    end
    local c = GetEntityCoords(cow)
    return vector3(c.x, c.y, c.z + 0.5)
end

local function hogtieCow(cow)
    -- We’ll “simulate” hogtie in a robust way:
    -- 1) stop cow
    -- 2) play a progress circle
    -- 3) freeze cow and ragdoll briefly to show it’s subdued
    ClearPedTasksImmediately(cow)
    SetEntityVelocity(cow, 0.0, 0.0, 0.0)

    -- Keep pronghorn in ragdoll during hogtie
    CreateThread(function()
        local startTime = GetGameTimer()
        while activeCow and DoesEntityExist(activeCow) and (GetGameTimer() - startTime) < (Config.Arenas[activeArenaIndex].hogtie.progressMs + 500) do
            SetPedToRagdoll(activeCow, 60000, 60000, 0, true, true, false)
            Wait(100)
        end
    end)

    local ok = lib.progressCircle({
        duration = Config.Arenas[activeArenaIndex].hogtie.progressMs,
        label = "Hogtying...",
        position = 'bottom',
        useWhileDead = false,
        canCancel = true,
        disable = { move = true, car = true, combat = true }
    })

    if not ok then
        return false
    end

    -- "hogtied" state: freeze and collapse for RP
    SetPedToRagdoll(cow, 60000, 60000, 0, true, true, false)
    Wait(700)
    FreezeEntityPosition(cow, true)
    return true
end

local function releaseAndFleeCow(arena)
    if not activeCow or not DoesEntityExist(activeCow) then return end

    -- Remove uncut zone
    if uncutZoneId then
        exports.ox_target:removeZone(uncutZoneId)
        uncutZoneId = nil
    end

    -- Stop keeping it ragdolled - set flag so refresh thread exits
    hogtied = false
    
    -- Wait a frame for the ragdoll thread to notice and stop
    Wait(50)

    -- Clear ragdoll and unfreeze
    ClearPedTasks(activeCow)
    FreezeEntityPosition(activeCow, false)

    -- Give it a small push away from player to start motion
    local playerPed = PlayerPedId()
    local playerPos = GetEntityCoords(playerPed)
    local cowPos = GetEntityCoords(activeCow)
    local away = normalize(cowPos - playerPos)
    ApplyForceToEntity(activeCow, 1, away.x * 2.0, away.y * 2.0, 0.5, 0, 0, 0, 0, true, true, true, false, true)

    Wait(100)

    -- Flee behavior: run away from player
    TaskSmartFleePed(activeCow, playerPed, 200.0, arena.flee.runSeconds * 1000, false, false)

    -- Despawn later
    CreateThread(function()
        Wait(arena.flee.despawnAfterSeconds * 1000)
        safeDeleteEntity(activeCow)
        activeCow = nil
        activeRun = false
        activeArenaIndex = nil
    end)
end

local function startRoping(arenaIndex)
    if activeRun then
        notify(Config.Text.busy, 'error')
        return
    end

    local hasLasso = lib.callback.await('rsg-cattleroping:server:hasLasso', false)
    if not hasLasso then
        notify(Config.Text.needLasso, 'error')
        return
    end

    activeRun = true
    activeArenaIndex = arenaIndex
    local arena = Config.Arenas[arenaIndex]

    -- Countdown
    notify(Config.Text.countdown, 'inform')
    for i = arena.countdownSeconds, 1, -1 do
        lib.showTextUI(("Starting in %d"):format(i), { position = "top-center" })
        Wait(1000)
    end
    lib.hideTextUI()

    -- Spawn cow
    local c = arena.cow.spawn
    -- Spawn at normal ground level
    local cow = SpawnAnimal(arena.cow.model, vector3(c.x, c.y, c.z), c.w)
    
    if not cow then
        notify("Failed to spawn cow.", 'error')
        activeRun = false
        activeArenaIndex = nil
        return
    end

    activeCow = cow
    
    Wait(500)
    
    -- Aggressive visibility forcing
    for i = 1, 10 do
        SetEntityVisible(cow, true, false)
        SetEntityAlpha(cow, 255, false)
        Wait(50)
    end
    
    -- Force continuous rendering
    CreateThread(function()
        while activeCow and DoesEntityExist(activeCow) and activeRun do
            SetEntityVisible(activeCow, true, false)
            SetEntityAlpha(activeCow, 255, false)
            Wait(100)
        end
    end)
    
    -- Minimal setup
    SetPedFleeAttributes(cow, 0, false)
    SetBlockingOfNonTemporaryEvents(cow, true)
    SetPedKeepTask(cow, true)

    -- Make it feel "aggressive": always running, re-tasked, less likely to stop
    SetPedConfigFlag(cow, 146, true)  -- prevent some idle behaviors (flag varies)
    SetPedConfigFlag(cow, 208, true)

    notify(Config.Text.ropeIt, 'inform')

    -- Run-to-finish loop until lassoed or reaches near finish
    CreateThread(function()
        local lastTask = 0
        while activeRun and activeCow and DoesEntityExist(activeCow) do
            Wait(0)

            if isEntityLassoed(activeCow) then
                -- Cow is lassoed; stop running task spam
                ClearPedTasks(activeCow)
                break
            end

            local now = GetGameTimer()
            if now - lastTask >= Config.CowBehavior.refreshRunTaskMs then
                lastTask = now
                taskCowRunTo(arena)
            end

            local cowPos = GetEntityCoords(activeCow)
            local distToFinish = #(cowPos - arena.cow.runTo)
            if distToFinish < 3.0 then
                -- Reached finish without being roped; just keep moving a bit and allow roping
                taskCowRunTo(arena)
            end
        end
    end)

    -- Hogtie interaction loop:
    -- Player must be close to cow head, cow must be lassoed (or at least not sprinting)
    CreateThread(function()
        local isLaidDown = false
        while activeRun and activeCow and DoesEntityExist(activeCow) do
            Wait(0)

            if hogtied then break end

            local playerPed = PlayerPedId()
            local playerPos = GetEntityCoords(playerPed)
            local headPos = getCowHeadCoords(activeCow)
            local dist = #(playerPos - headPos)

            local lassoed = isEntityLassoed(activeCow)
            local cowSpeed = GetEntitySpeed(activeCow)

            -- When lassoed, make cow lay down
            if lassoed and not isLaidDown then
                ClearPedTasksImmediately(activeCow)
                SetEntityVelocity(activeCow, 0.0, 0.0, 0.0)
                SetPedToRagdoll(activeCow, 90000, 90000, 0, true, true, false)
                isLaidDown = true   
            end

            -- If native lasso detection fails on your build, we allow hogtie if cow is basically stopped
            local canHogtie = lassoed or cowSpeed < 0.6

            if canHogtie and dist <= arena.hogtie.headDistance then
                lib.showTextUI("[G] Hogtie", { position = "bottom-right" })

                if IsControlJustPressed(0, arena.hogtie.key) then
                    lib.hideTextUI()

                    local ok = hogtieCow(activeCow)
                    if ok then
                        hogtied = true
                        notify(Config.Text.hogtied, 'success')

                        -- Freeze the pronghorn so it can't run off
                        FreezeEntityPosition(activeCow, true)

                        -- Keep pronghorn ragdolled and laying down until cut
                        CreateThread(function()
                            while activeCow and DoesEntityExist(activeCow) and hogtied do
                                SetPedToRagdoll(activeCow, 90000, 90000, 0, true, true, false)
                                Wait(500)  -- Refresh less frequently to reduce stuttering
                            end
                        end)

                        -- Create uncut zone at pronghorn's current location
                        local pronghornCoords = GetEntityCoords(activeCow)
                        uncutZoneId = exports.ox_target:addSphereZone({
                            coords = pronghornCoords,
                            radius = 2.0,
                            debug = false,
                            options = {
                                {
                                    name = 'rsg-cattleroping:uncut',
                                    label = 'Uncut Rope',
                                    icon = 'fa-solid fa-knife',
                                    distance = 2.0,
                                    onSelect = function()
                                        lib.hideTextUI()
                                        notify(Config.Text.release, 'inform')
                                        releaseAndFleeCow(arena)
                                    end
                                }
                            }
                        })

                        break
                    end
                end
            else
                lib.hideTextUI()
            end
        end
        lib.hideTextUI()
    end)
end

-- -------------------------------------------------------
-- ox_target setup
-- -------------------------------------------------------
CreateThread(function()
    Wait(1000)

    for i, arena in ipairs(Config.Arenas) do
        exports.ox_target:addSphereZone({
            coords = arena.zone.coords,
            radius = arena.zone.radius,
            debug = false,
            options = {
                {
                    name = ('rsg-cattleroping:start:%d'):format(i),
                    label = Config.Text.targetLabel,
                    icon = 'fa-solid fa-hat-cowboy',
                    distance = arena.zone.radius,
                    onSelect = function()
                        startRoping(i)
                    end
                }
            }
        })
    end
end)

-- Cleanup if resource stops
AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    lib.hideTextUI()
    safeDeleteEntity(activeCow)
end)
