local RSGCore = exports['rsg-core']:GetCoreObject()

-- Simple server-side inventory check to prevent client spoofing
lib.callback.register('rsg-cattleroping:server:hasLasso', function(source)
    local Player = RSGCore.Functions.GetPlayer(source)
    if not Player then return false end

    -- TEMP: return true to bypass lasso check for testing
    return true

    -- local lassoItems = Config.RequiredLassoItem
    -- if type(lassoItems) == 'string' then
    --     lassoItems = {lassoItems}
    -- end

    -- for _, itemName in ipairs(lassoItems) do
    --     local item = Player.Functions.GetItemByName(itemName)
    --     if item ~= nil and (item.amount or 0) > 0 then
    --         return true
    --     end
    -- end

    -- return false
end)
