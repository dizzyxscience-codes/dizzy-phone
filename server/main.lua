local QBCore = exports['qb-core']:GetCoreObject()

local function phoneStr(n)
    return tostring(n or ''):gsub('%s+', '')
end

local function getCharPhone(Player)
    if not Player or not Player.PlayerData or not Player.PlayerData.charinfo then return nil end
    return phoneStr(Player.PlayerData.charinfo.phone)
end

local function getPlayerByPhoneStr(num)
    num = phoneStr(num)
    for _, src in pairs(QBCore.Functions.GetPlayers()) do
        local P = QBCore.Functions.GetPlayer(tonumber(src))
        if P and getCharPhone(P) == num then
            return P
        end
    end
    return nil
end

local function hasPhoneItem(src)
    if not Config.RequirePhoneItem then return true end
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player or not Player.PlayerData.items then return false end
    -- Scan inventory directly: qb-inventory GetItemByName can miss items when slots use
    -- string keys (e.g. items["5"]) because it indexes items[tonumber(slot)].
    local allowed = {}
    for i = 1, #Config.PhoneItems do
        local n = tostring(Config.PhoneItems[i] or ''):lower()
        if n ~= '' then allowed[n] = true end
    end
    for _, invItem in pairs(Player.PlayerData.items) do
        if invItem and invItem.name then
            local amt = tonumber(invItem.amount) or 0
            if amt > 0 and allowed[invItem.name:lower()] then
                return true
            end
        end
    end
    return false
end

local lastMsgTick = {}
local function checkCooldown(src)
    local now = GetGameTimer()
    local last = lastMsgTick[src] or 0
    if now - last < Config.MessageCooldownMs then return false end
    lastMsgTick[src] = now
    return true
end

local function sanitizeBody(text)
    if type(text) ~= 'string' then return '' end
    text = text:gsub('%c', ' '):gsub('^%s+', ''):gsub('%s+$', '')
    if #text > Config.MaxMessageLength then
        text = text:sub(1, Config.MaxMessageLength)
    end
    return text
end

---@class PendingCall
---@field fromSrc number
---@field toSrc number
---@field fromPhone string
---@field toPhone string
---@field started number
local PendingByTarget = {} ---@type table<number, PendingCall>
local PendingByCaller = {} ---@type table<number, PendingCall>
local ActiveCallChannel = {} ---@type table<number, number> -- src -> channel

local function clearPending(p)
    if not p then return end
    PendingByTarget[p.toSrc] = nil
    PendingByCaller[p.fromSrc] = nil
end

local function endVoiceFor(src)
    if not Config.EnableVoiceCalls then return end
    if GetResourceState('pma-voice') ~= 'started' then return end
    pcall(function()
        exports['pma-voice']:setPlayerCall(src, 0)
    end)
    ActiveCallChannel[src] = nil
end

local function genCallChannel()
    local ch
    repeat
        ch = math.random(100000, 999999999)
    until ch ~= 0
    return ch
end

--- AirDrop pending contact card: keyed by receiver server id
local PendingAirDrop = {} ---@type table<number, { fromSrc: number, exp: number }>

local function fetchInstalledApps(citizenid)
    local rows = MySQL.query.await(
        'SELECT app_id FROM dizzy_phone_installed_apps WHERE citizenid = ?',
        { citizenid }
    ) or {}
    local list = {}
    for i = 1, #rows do
        list[#list + 1] = rows[i].app_id
    end
    return list
end

local function isValidAppId(appId)
    if type(appId) ~= 'string' or appId == '' then return false end
    appId = appId:lower()
    for _, a in ipairs(Config.AppCatalog or {}) do
        if type(a.id) == 'string' and a.id:lower() == appId then return true end
    end
    return false
end

local function playerHasAppFromSource(source, appId)
    local Player = QBCore.Functions.GetPlayer(source)
    if not Player then return false end
    appId = tostring(appId or ''):lower()
    local rows = MySQL.query.await(
        'SELECT 1 FROM dizzy_phone_installed_apps WHERE citizenid = ? AND app_id = ? LIMIT 1',
        { Player.PlayerData.citizenid, appId }
    )
    return rows and #rows > 0
end

local function sanitizeSocialBody(text)
    if type(text) ~= 'string' then return '' end
    text = text:gsub('%c', ' '):gsub('^%s+', ''):gsub('%s+$', '')
    local maxLen = Config.MaxSocialPostLength or 280
    if #text > maxLen then text = text:sub(1, maxLen) end
    return text
end

local function sanitizeImageUrl(u)
    if type(u) ~= 'string' then return nil end
    u = u:gsub('%s+', '')
    local low = u:lower()
    if low:find('javascript:', 1, true) or low:find('vbscript:', 1, true) then return nil end
    if u:match('^https?://') then
        if #u > 2048 then u = u:sub(1, 2048) end
        return u
    end
    if u:match('^data:image/(jpeg|jpg|png|webp);base64,') then
        local maxLen = tonumber(Config.CameraMaxDataUrlLength) or 524288
        if #u > maxLen then return nil end
        return u
    end
    return nil
end

local function sanitizePhotoCaption(c)
    c = tostring(c or ''):gsub('%c', ' '):gsub('^%s+', ''):gsub('%s+$', '')
    local maxLen = Config.MaxPhotoCaptionLength or 200
    if #c > maxLen then c = c:sub(1, maxLen) end
    return c
end

local function serviceEntryLabel(entry)
    if type(entry) ~= 'table' then return '' end
    local custom = entry.label and tostring(entry.label):gsub('^%s+', ''):gsub('%s+$', '') or ''
    if custom ~= '' then return custom end
    local j = entry.job and QBCore.Shared.Jobs[entry.job]
    if j and j.label then return j.label end
    return tostring(entry.job or '')
end

local function findServiceDirectoryEntry(jobName)
    jobName = tostring(jobName or ''):lower()
    if jobName == '' then return nil end
    for _, entry in ipairs(Config.ServiceDirectory or {}) do
        if entry.job and entry.job:lower() == jobName then
            return entry
        end
    end
    return nil
end

local function getQbGarageByName(garageKey)
    garageKey = tostring(garageKey or '')
    if garageKey == '' then return nil end
    local resName = Config.PhoneGarageResource or 'qb-garages'
    if GetResourceState(resName) ~= 'started' then return nil end
    local ok, list = pcall(function()
        return exports[resName]:getAllGarages()
    end)
    if not ok or type(list) ~= 'table' then return nil end
    for i = 1, #list do
        local g = list[i]
        if g and g.name == garageKey then
            return g
        end
    end
    return nil
end

-- Bootstrap
QBCore.Functions.CreateCallback('dizzy-phone:server:bootstrap', function(source, cb)
    local Player = QBCore.Functions.GetPlayer(source)
    if not Player then return cb(nil) end
    if not hasPhoneItem(source) then return cb({ error = 'no_phone' }) end
    local my = getCharPhone(Player)
    if not my or my == '' then return cb({ error = 'no_number' }) end
    local char = Player.PlayerData.charinfo or {}
    local job = Player.PlayerData.job or {}
    cb({
        myPhone = my,
        name = (char.firstname or '') .. ' ' .. (char.lastname or ''),
        jobLabel = job.label or '',
        jobGrade = (job.grade and job.grade.name) or '',
        cash = Player.PlayerData.money and Player.PlayerData.money.cash or 0,
        bank = Player.PlayerData.money and Player.PlayerData.money.bank or 0,
        enableTransfer = Config.EnableBankTransfer,
        enableCalls = Config.EnableVoiceCalls and GetResourceState('pma-voice') == 'started',
        appCatalog = Config.AppCatalog or {},
        installedApps = fetchInstalledApps(Player.PlayerData.citizenid),
        camera = (function()
            local camRes = Config.CameraResource or 'screenshot-basic'
            local camOk = false
            for _, name in ipairs(Config.GetCameraResourceCandidates()) do
                if GetResourceState(name) == 'started' then
                    camRes = name
                    camOk = true
                    break
                end
            end
            return {
                uploadConfigured = type(Config.CameraUploadUrl) == 'string' and Config.CameraUploadUrl ~= '',
                resource = camRes,
                available = camOk,
                maxPhotos = Config.MaxGalleryPhotos or 200,
                useCellCamera = Config.UseCellPhoneCamera == true,
                cellCamShowGrid = Config.CellCamShowGrid ~= false,
                cellCamShowTip = Config.CellCamShowTip ~= false,
            }
        end)(),
        phoneGarage = Config.EnablePhoneGarage and GetResourceState(Config.PhoneGarageResource or 'qb-garages') == 'started',
        phoneGarageValetFee = tonumber(Config.PhoneGarageValetFee) or 0,
    })
end)

QBCore.Functions.CreateCallback('dizzy-phone:server:getContacts', function(source, cb)
    local Player = QBCore.Functions.GetPlayer(source)
    if not Player or not hasPhoneItem(source) then return cb({}) end
    local cid = Player.PlayerData.citizenid
    local rows = MySQL.query.await(
        'SELECT id, contact_name, phone_number, favorite FROM dizzy_phone_contacts WHERE owner_citizenid = ? ORDER BY favorite DESC, contact_name ASC',
        { cid }
    ) or {}
    cb(rows)
end)

QBCore.Functions.CreateCallback('dizzy-phone:server:getMessages', function(source, cb)
    local Player = QBCore.Functions.GetPlayer(source)
    if not Player or not hasPhoneItem(source) then return cb({}) end
    local my = getCharPhone(Player)
    if not my then return cb({}) end
    local rows = MySQL.query.await(
        [[SELECT id, from_phone, to_phone, body, is_read, created_at
          FROM dizzy_phone_messages
          WHERE from_phone = ? OR to_phone = ?
          ORDER BY created_at DESC LIMIT 250]],
        { my, my }
    ) or {}
    cb(rows)
end)

QBCore.Functions.CreateCallback('dizzy-phone:server:getNotes', function(source, cb)
    local Player = QBCore.Functions.GetPlayer(source)
    if not Player or not hasPhoneItem(source) then return cb({}) end
    local rows = MySQL.query.await(
        'SELECT id, title, body, updated_at FROM dizzy_phone_notes WHERE citizenid = ? ORDER BY updated_at DESC',
        { Player.PlayerData.citizenid }
    ) or {}
    cb(rows)
end)

QBCore.Functions.CreateCallback('dizzy-phone:server:getPhotos', function(source, cb)
    local Player = QBCore.Functions.GetPlayer(source)
    if not Player or not hasPhoneItem(source) then return cb({}) end
    local cap = Config.MaxGalleryPhotos or 200
    local rows = MySQL.query.await(
        'SELECT id, image_url, caption, created_at FROM dizzy_phone_photos WHERE citizenid = ? ORDER BY created_at DESC LIMIT ?',
        { Player.PlayerData.citizenid, cap }
    ) or {}
    cb(rows)
end)

local function savePhonePhotoForPlayer(src, imageUrl, caption)
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player or not hasPhoneItem(src) then return false, 'phone' end
    local url = sanitizeImageUrl(imageUrl)
    if not url then return false, 'invalid' end
    caption = sanitizePhotoCaption(caption)
    local cid = Player.PlayerData.citizenid
    local maxP = Config.MaxGalleryPhotos or 200
    local n = MySQL.scalar.await('SELECT COUNT(*) FROM dizzy_phone_photos WHERE citizenid = ?', { cid }) or 0
    if n >= maxP then
        local row = MySQL.single.await('SELECT id FROM dizzy_phone_photos WHERE citizenid = ? ORDER BY created_at ASC LIMIT 1', { cid })
        if row and row.id then
            MySQL.query.await('DELETE FROM dizzy_phone_photos WHERE id = ?', { row.id })
        end
    end
    MySQL.insert.await(
        'INSERT INTO dizzy_phone_photos (citizenid, image_url, caption) VALUES (?, ?, ?)',
        { cid, url, caption }
    )
    return true
end

RegisterNetEvent('dizzy-phone:server:savePhoto', function(imageUrl, caption)
    savePhonePhotoForPlayer(source, imageUrl, caption)
end)

QBCore.Functions.CreateCallback('dizzy-phone:server:savePhoto', function(source, cb, imageUrl, caption)
    local ok, err = savePhonePhotoForPlayer(source, imageUrl, caption)
    if ok then
        cb({ ok = true })
    else
        cb({ ok = false, err = err or 'fail' })
    end
end)

RegisterNetEvent('dizzy-phone:server:deletePhoto', function(photoId)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player or not hasPhoneItem(src) then return end
    photoId = tonumber(photoId)
    if not photoId then return end
    MySQL.query.await('DELETE FROM dizzy_phone_photos WHERE id = ? AND citizenid = ?', { photoId, Player.PlayerData.citizenid })
end)

QBCore.Functions.CreateCallback('dizzy-phone:server:getServices', function(source, cb)
    if not hasPhoneItem(source) then return cb({}) end
    local out = {}
    for _, entry in ipairs(Config.ServiceDirectory or {}) do
        local jobKey = entry.job
        if jobKey and QBCore.Shared.Jobs[jobKey] then
            local _, onDuty = QBCore.Functions.GetPlayersOnDuty(jobKey)
            onDuty = tonumber(onDuty) or 0
            out[#out + 1] = {
                job = jobKey,
                label = serviceEntryLabel(entry),
                open = onDuty > 0,
                onDuty = onDuty,
            }
        end
    end
    cb(out)
end)

QBCore.Functions.CreateCallback('dizzy-phone:server:getServiceStaff', function(source, cb, jobKey)
    if not hasPhoneItem(source) then return cb({}) end
    jobKey = tostring(jobKey or '')
    if jobKey == '' then return cb({}) end
    local entry = findServiceDirectoryEntry(jobKey)
    if not entry or not QBCore.Shared.Jobs[entry.job] then return cb({}) end
    local realJob = entry.job
    local staffSrcs = select(1, QBCore.Functions.GetPlayersOnDuty(realJob))
    if type(staffSrcs) ~= 'table' then staffSrcs = {} end
    local out = {}
    for i = 1, #staffSrcs do
        local staffSource = staffSrcs[i]
        local P = QBCore.Functions.GetPlayer(staffSource)
        if P then
            local char = P.PlayerData.charinfo or {}
            local name = ((char.firstname or '') .. ' ' .. (char.lastname or '')):gsub('^%s+', ''):gsub('%s+$', '')
            if name == '' then name = 'Employee' end
            local ph = getCharPhone(P)
            if ph and ph ~= '' then
                local grade = P.PlayerData.job and P.PlayerData.job.grade and P.PlayerData.job.grade.name
                out[#out + 1] = {
                    name = name,
                    phone = ph,
                    grade = grade or '',
                }
            end
        end
    end
    cb(out)
end)

QBCore.Functions.CreateCallback('dizzy-phone:server:getGarageVehiclesPhone', function(source, cb)
    if not Config.EnablePhoneGarage then return cb({}) end
    if GetResourceState(Config.PhoneGarageResource or 'qb-garages') ~= 'started' then return cb({}) end
    local Player = QBCore.Functions.GetPlayer(source)
    if not Player or not hasPhoneItem(source) then return cb({}) end
    local cid = Player.PlayerData.citizenid
    local rows = MySQL.rawExecute.await(
        'SELECT plate, vehicle, garage, fuel, engine, body FROM player_vehicles WHERE citizenid = ? AND state = 1 AND COALESCE(depotprice, 0) <= 0',
        { cid }
    ) or {}
    local out = {}
    for i = 1, #rows do
        local row = rows[i]
        local vData = QBCore.Shared.Vehicles[row.vehicle]
        local vname
        if vData and vData.brand then
            vname = vData.brand .. ' ' .. vData.name
        else
            vname = (vData and vData.name) or row.vehicle
        end
        local gCfg = getQbGarageByName(row.garage)
        local garLabel = gCfg and gCfg.label or (row.garage or 'Garage')
        out[#out + 1] = {
            plate = row.plate,
            vehicle = row.vehicle,
            label = vname,
            garageLabel = garLabel,
            fuel = row.fuel,
            engine = row.engine,
            body = row.body,
        }
    end
    cb(out)
end)

QBCore.Functions.CreateCallback('dizzy-phone:server:deliverGarageVehicle', function(source, cb, plate)
    if not Config.EnablePhoneGarage then return cb({ ok = false, err = 'disabled' }) end
    local resName = Config.PhoneGarageResource or 'qb-garages'
    if GetResourceState(resName) ~= 'started' then return cb({ ok = false, err = 'garage' }) end
    local Player = QBCore.Functions.GetPlayer(source)
    if not Player or not hasPhoneItem(source) then return cb({ ok = false, err = 'phone' }) end
    plate = QBCore.Shared.Trim(tostring(plate or ''))
    if plate == '' then return cb({ ok = false, err = 'plate' }) end
    local row = MySQL.single.await(
        'SELECT * FROM player_vehicles WHERE TRIM(plate) = ? AND citizenid = ? LIMIT 1',
        { plate, Player.PlayerData.citizenid }
    )
    if not row then return cb({ ok = false, err = 'notfound' }) end
    if tonumber(row.state) ~= 1 then return cb({ ok = false, err = 'notgaraged' }) end
    local dp = tonumber(row.depotprice) or 0
    if dp > 0 then return cb({ ok = false, err = 'depot' }) end
    local fee = tonumber(Config.PhoneGarageValetFee) or 0
    if fee > 0 then
        local cash = Player.PlayerData.money and Player.PlayerData.money.cash or 0
        if cash < fee then return cb({ ok = false, err = 'funds' }) end
        Player.Functions.RemoveMoney('cash', fee, 'dizzy-phone-garage-valet')
    end
    local garCfg = getQbGarageByName(row.garage)
    if not garCfg then
        garCfg = getQbGarageByName(Config.PhoneGarageFallback or 'motelgarage')
    end
    if not garCfg then return cb({ ok = false, err = 'config' }) end
    local data = {
        vehicle = row.vehicle,
        plate = row.plate,
        garage = garCfg,
        index = garCfg.name,
        type = garCfg.type,
        depotPrice = 0,
        stats = {
            fuel = tonumber(row.fuel) or 100,
            engine = tonumber(row.engine) or 1000,
            body = tonumber(row.body) or 1000,
        },
    }
    TriggerClientEvent('qb-garages:client:takeOutGarage', source, data)
    cb({ ok = true })
end)

RegisterNetEvent('dizzy-phone:server:contactSave', function(data)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player or not hasPhoneItem(src) then return end
    if type(data) ~= 'table' then return end
    local name = tostring(data.contact_name or ''):sub(1, 64):gsub('%c', ' ')
    local num = phoneStr(data.phone_number)
    if name == '' or num == '' then return end
    local fav = data.favorite and 1 or 0
    local cid = Player.PlayerData.citizenid
    MySQL.insert.await(
        'INSERT INTO dizzy_phone_contacts (owner_citizenid, contact_name, phone_number, favorite) VALUES (?, ?, ?, ?) ON DUPLICATE KEY UPDATE contact_name = VALUES(contact_name), favorite = VALUES(favorite)',
        { cid, name, num, fav }
    )
end)

RegisterNetEvent('dizzy-phone:server:contactDelete', function(id)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player or not hasPhoneItem(src) then return end
    id = tonumber(id)
    if not id then return end
    MySQL.query.await('DELETE FROM dizzy_phone_contacts WHERE id = ? AND owner_citizenid = ?', { id, Player.PlayerData.citizenid })
end)

RegisterNetEvent('dizzy-phone:server:sendMessage', function(toPhone, body)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player or not hasPhoneItem(src) then return end
    if not checkCooldown(src) then return end
    local from = getCharPhone(Player)
    toPhone = phoneStr(toPhone)
    body = sanitizeBody(body)
    if from == '' or toPhone == '' or body == '' then return end
    if from == toPhone then return end
    local id = MySQL.insert.await(
        'INSERT INTO dizzy_phone_messages (from_phone, to_phone, body, is_read) VALUES (?, ?, ?, 0)',
        { from, toPhone, body }
    )
    local Target = getPlayerByPhoneStr(toPhone)
    if Target then
        TriggerClientEvent('dizzy-phone:client:messagePush', Target.PlayerData.source, {
            id = id,
            from_phone = from,
            to_phone = toPhone,
            body = body,
            is_read = 0,
            created_at = os.date('!%Y-%m-%d %H:%M:%S'),
        })
    end
end)

RegisterNetEvent('dizzy-phone:server:markRead', function(otherPhone)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player or not hasPhoneItem(src) then return end
    local my = getCharPhone(Player)
    otherPhone = phoneStr(otherPhone)
    if my == '' or otherPhone == '' then return end
    MySQL.query.await(
        'UPDATE dizzy_phone_messages SET is_read = 1 WHERE to_phone = ? AND from_phone = ? AND is_read = 0',
        { my, otherPhone }
    )
end)

RegisterNetEvent('dizzy-phone:server:noteSave', function(noteId, title, body)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player or not hasPhoneItem(src) then return end
    title = tostring(title or 'Note'):sub(1, 100):gsub('%c', ' ')
    body = tostring(body or ''):sub(1, 8000)
    local cid = Player.PlayerData.citizenid
    noteId = tonumber(noteId)
    if noteId and noteId > 0 then
        MySQL.query.await('UPDATE dizzy_phone_notes SET title = ?, body = ? WHERE id = ? AND citizenid = ?', { title, body, noteId, cid })
    else
        MySQL.insert.await('INSERT INTO dizzy_phone_notes (citizenid, title, body) VALUES (?, ?, ?)', { cid, title, body })
    end
end)

RegisterNetEvent('dizzy-phone:server:noteDelete', function(noteId)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player or not hasPhoneItem(src) then return end
    noteId = tonumber(noteId)
    if not noteId then return end
    MySQL.query.await('DELETE FROM dizzy_phone_notes WHERE id = ? AND citizenid = ?', { noteId, Player.PlayerData.citizenid })
end)

QBCore.Functions.CreateCallback('dizzy-phone:server:bankTransfer', function(source, cb, targetPhone, amount)
    if not Config.EnableBankTransfer then return cb({ ok = false, err = 'disabled' }) end
    local Player = QBCore.Functions.GetPlayer(source)
    if not Player or not hasPhoneItem(source) then return cb({ ok = false, err = 'no_phone' }) end
    amount = math.floor(tonumber(amount) or 0)
    if amount < Config.TransferMin or amount > Config.TransferMax then
        return cb({ ok = false, err = 'amount' })
    end
    targetPhone = phoneStr(targetPhone)
    local Target = getPlayerByPhoneStr(targetPhone)
    if not Target then return cb({ ok = false, err = 'offline' }) end
    if Target.PlayerData.source == source then return cb({ ok = false, err = 'self' }) end
    local bank = Player.PlayerData.money.bank or 0
    local fee = math.floor(amount * (Config.TransferFeePercent / 100))
    local total = amount + fee
    if bank < total then return cb({ ok = false, err = 'funds' }) end
    Player.Functions.RemoveMoney('bank', total, 'dizzy-phone-transfer')
    Target.Functions.AddMoney('bank', amount, 'dizzy-phone-transfer-in')
    cb({
        ok = true,
        bank = Player.PlayerData.money.bank,
        cash = Player.PlayerData.money.cash,
    })
end)

-- Voice calls
local function tryStartVoiceCall(callerSrc, targetSrc)
    if not Config.EnableVoiceCalls or GetResourceState('pma-voice') ~= 'started' then return nil end
    local channel = genCallChannel()
    local ok1, ok2 = pcall(function()
        exports['pma-voice']:setPlayerCall(callerSrc, channel)
    end), pcall(function()
        exports['pma-voice']:setPlayerCall(targetSrc, channel)
    end)
    if ok1 and ok2 then
        ActiveCallChannel[callerSrc] = channel
        ActiveCallChannel[targetSrc] = channel
        return channel
    end
    return nil
end

RegisterNetEvent('dizzy-phone:server:callStart', function(targetPhone)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player or not hasPhoneItem(src) then return end
    if PendingByCaller[src] or ActiveCallChannel[src] then return end
    targetPhone = phoneStr(targetPhone)
    local from = getCharPhone(Player)
    if from == '' or targetPhone == '' or from == targetPhone then return end
    local Target = getPlayerByPhoneStr(targetPhone)
    if not Target then
        TriggerClientEvent('dizzy-phone:client:callResult', src, 'unavailable')
        return
    end
    local tSrc = Target.PlayerData.source
    if PendingByTarget[tSrc] then
        TriggerClientEvent('dizzy-phone:client:callResult', src, 'busy')
        return
    end
    local char = Player.PlayerData.charinfo or {}
    local display = ((char.firstname or '') .. ' ' .. (char.lastname or '')):gsub('^%s+', ''):gsub('%s+$', '')
    if display == '' then display = from end
    local p = {
        fromSrc = src,
        toSrc = tSrc,
        fromPhone = from,
        toPhone = targetPhone,
        started = GetGameTimer(),
    }
    PendingByTarget[tSrc] = p
    PendingByCaller[src] = p
    TriggerClientEvent('dizzy-phone:client:incomingCall', tSrc, {
        fromPhone = from,
        fromName = display,
    })
    TriggerClientEvent('dizzy-phone:client:callResult', src, 'ringing', targetPhone)
    CreateThread(function()
        Wait(Config.CallRingTimeoutMs)
        local cur = PendingByCaller[src]
        if cur and cur.toSrc == tSrc then
            clearPending(cur)
            TriggerClientEvent('dizzy-phone:client:callEnded', src, 'timeout')
            TriggerClientEvent('dizzy-phone:client:callEnded', tSrc, 'timeout')
        end
    end)
end)

RegisterNetEvent('dizzy-phone:server:callAccept', function()
    local src = source
    local p = PendingByTarget[src]
    if not p then return end
    clearPending(p)
    local ch = tryStartVoiceCall(p.fromSrc, p.toSrc)
    if not ch then
        TriggerClientEvent('dizzy-phone:client:callEnded', p.fromSrc, 'voice')
        TriggerClientEvent('dizzy-phone:client:callEnded', p.toSrc, 'voice')
        return
    end
    TriggerClientEvent('dizzy-phone:client:callConnected', p.fromSrc, { withPhone = p.toPhone })
    TriggerClientEvent('dizzy-phone:client:callConnected', p.toSrc, { withPhone = p.fromPhone })
end)

RegisterNetEvent('dizzy-phone:server:callDecline', function()
    local src = source
    local p = PendingByTarget[src]
    if p then
        clearPending(p)
        TriggerClientEvent('dizzy-phone:client:callEnded', p.fromSrc, 'declined')
        TriggerClientEvent('dizzy-phone:client:callEnded', p.toSrc, 'declined')
        return
    end
    p = PendingByCaller[src]
    if p then
        clearPending(p)
        TriggerClientEvent('dizzy-phone:client:callEnded', p.fromSrc, 'cancelled')
        TriggerClientEvent('dizzy-phone:client:callEnded', p.toSrc, 'cancelled')
    end
end)

RegisterNetEvent('dizzy-phone:server:callEnd', function()
    local src = source
    local ch = ActiveCallChannel[src]
    local other
    if ch then
        for a, c in pairs(ActiveCallChannel) do
            if a ~= src and c == ch then
                other = a
                break
            end
        end
    end
    endVoiceFor(src)
    if other then
        endVoiceFor(other)
        TriggerClientEvent('dizzy-phone:client:callEnded', other, 'ended')
    end
    TriggerClientEvent('dizzy-phone:client:callEnded', src, 'ended')
end)

--- End active call or cancel outgoing / incoming ring
RegisterNetEvent('dizzy-phone:server:callHangup', function()
    local src = source
    local ch = ActiveCallChannel[src]
    if ch and ch ~= 0 then
        local other
        for a, c in pairs(ActiveCallChannel) do
            if a ~= src and c == ch then
                other = a
                break
            end
        end
        endVoiceFor(src)
        if other then
            endVoiceFor(other)
            TriggerClientEvent('dizzy-phone:client:callEnded', other, 'ended')
        end
        TriggerClientEvent('dizzy-phone:client:callEnded', src, 'ended')
        return
    end
    local p = PendingByCaller[src] or PendingByTarget[src]
    if p then
        local a, b = p.fromSrc, p.toSrc
        clearPending(p)
        TriggerClientEvent('dizzy-phone:client:callEnded', a, 'cancelled')
        TriggerClientEvent('dizzy-phone:client:callEnded', b, 'cancelled')
    end
end)

QBCore.Functions.CreateCallback('dizzy-phone:server:getAirDropNearby', function(source, cb)
    if not hasPhoneItem(source) then return cb({}) end
    local myPed = GetPlayerPed(source)
    if not myPed or myPed == 0 then return cb({}) end
    local myCoords = GetEntityCoords(myPed)
    local range = (Config.AirDropRange or 12.0) + 0.01
    local out = {}
    for _, id in ipairs(QBCore.Functions.GetPlayers()) do
        local tid = tonumber(id)
        if tid and tid ~= source then
            local tped = GetPlayerPed(tid)
            if tped and tped ~= 0 then
                local c = GetEntityCoords(tped)
                local dist = #(myCoords - c)
                if dist <= range then
                    local P = QBCore.Functions.GetPlayer(tid)
                    if P then
                        local ch = P.PlayerData.charinfo or {}
                        local name = ((ch.firstname or '') .. ' ' .. (ch.lastname or '')):gsub('^%s+', ''):gsub('%s+$', '')
                        if name == '' then name = 'Citizen' end
                        out[#out + 1] = {
                            serverId = tid,
                            name = name,
                            dist = math.floor(dist * 10 + 0.5) / 10,
                        }
                    end
                end
            end
        end
    end
    table.sort(out, function(a, b) return a.dist < b.dist end)
    cb(out)
end)

RegisterNetEvent('dizzy-phone:server:airdropSend', function(targetSrc)
    local src = source
    targetSrc = tonumber(targetSrc)
    if not targetSrc or targetSrc == src then return end
    local Sender = QBCore.Functions.GetPlayer(src)
    local Target = QBCore.Functions.GetPlayer(targetSrc)
    if not Sender or not Target or not hasPhoneItem(src) then return end
    local myPed = GetPlayerPed(src)
    local tPed = GetPlayerPed(targetSrc)
    if not myPed or myPed == 0 or not tPed or tPed == 0 then return end
    local maxDist = (Config.AirDropRange or 12.0) + 1.25
    if #(GetEntityCoords(myPed) - GetEntityCoords(tPed)) > maxDist then
        return
    end
    local fromPhone = getCharPhone(Sender)
    if fromPhone == '' then return end
    local char = Sender.PlayerData.charinfo or {}
    local fromName = ((char.firstname or '') .. ' ' .. (char.lastname or '')):gsub('^%s+', ''):gsub('%s+$', '')
    if fromName == '' then fromName = 'Unknown' end
    PendingAirDrop[targetSrc] = {
        fromSrc = src,
        exp = GetGameTimer() + (Config.AirDropPendingMs or 90000),
    }
    TriggerClientEvent('dizzy-phone:client:airdropIncoming', targetSrc, {
        fromName = fromName,
        fromPhone = fromPhone,
    })
end)

RegisterNetEvent('dizzy-phone:server:airdropDecline', function()
    PendingAirDrop[source] = nil
end)

RegisterNetEvent('dizzy-phone:server:airdropAccept', function()
    local src = source
    local pend = PendingAirDrop[src]
    if not pend then return end
    if GetGameTimer() > pend.exp then
        PendingAirDrop[src] = nil
        return
    end
    local Sender = QBCore.Functions.GetPlayer(pend.fromSrc)
    local Receiver = QBCore.Functions.GetPlayer(src)
    PendingAirDrop[src] = nil
    if not Receiver or not Sender or not hasPhoneItem(src) then return end
    local char = Sender.PlayerData.charinfo or {}
    local cname = tostring(((char.firstname or '') .. ' ' .. (char.lastname or '')):gsub('^%s+', ''):gsub('%s+$', ''))
    if cname == '' then cname = 'AirDrop' end
    cname = cname:sub(1, 64):gsub('%c', ' ')
    local num = phoneStr(getCharPhone(Sender))
    if num == '' then return end
    local cid = Receiver.PlayerData.citizenid
    MySQL.insert.await(
        'INSERT INTO dizzy_phone_contacts (owner_citizenid, contact_name, phone_number, favorite) VALUES (?, ?, ?, ?) ON DUPLICATE KEY UPDATE contact_name = VALUES(contact_name)',
        { cid, cname, num, 0 }
    )
end)

QBCore.Functions.CreateCallback('dizzy-phone:server:installApp', function(source, cb, appId)
    local Player = QBCore.Functions.GetPlayer(source)
    if not Player or not hasPhoneItem(source) then return cb({ ok = false }) end
    appId = tostring(appId or ''):lower()
    if not isValidAppId(appId) then return cb({ ok = false }) end
    local cid = Player.PlayerData.citizenid
    MySQL.insert.await(
        'INSERT INTO dizzy_phone_installed_apps (citizenid, app_id) VALUES (?, ?) ON DUPLICATE KEY UPDATE app_id = VALUES(app_id)',
        { cid, appId }
    )
    cb({ ok = true, installedApps = fetchInstalledApps(cid) })
end)

QBCore.Functions.CreateCallback('dizzy-phone:server:uninstallApp', function(source, cb, appId)
    local Player = QBCore.Functions.GetPlayer(source)
    if not Player or not hasPhoneItem(source) then return cb({ ok = false }) end
    appId = tostring(appId or ''):lower()
    if not isValidAppId(appId) then return cb({ ok = false }) end
    local cid = Player.PlayerData.citizenid
    MySQL.query.await('DELETE FROM dizzy_phone_installed_apps WHERE citizenid = ? AND app_id = ?', { cid, appId })
    cb({ ok = true, installedApps = fetchInstalledApps(cid) })
end)

QBCore.Functions.CreateCallback('dizzy-phone:server:getSocialPosts', function(source, cb, appId)
    appId = tostring(appId or ''):lower()
    if not isValidAppId(appId) then return cb({}) end
    if not hasPhoneItem(source) or not playerHasAppFromSource(source, appId) then return cb({}) end
    local rows = MySQL.query.await(
        [[SELECT id, app_id, author_phone, author_name, body, created_at
          FROM dizzy_phone_social_posts WHERE app_id = ? ORDER BY created_at DESC LIMIT 120]],
        { appId }
    ) or {}
    cb(rows)
end)

RegisterNetEvent('dizzy-phone:server:createSocialPost', function(appId, body)
    local src = source
    appId = tostring(appId or ''):lower()
    if not isValidAppId(appId) then return end
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player or not hasPhoneItem(src) or not playerHasAppFromSource(src, appId) then return end
    body = sanitizeSocialBody(body)
    if body == '' then return end
    local phone = getCharPhone(Player)
    if phone == '' then return end
    local char = Player.PlayerData.charinfo or {}
    local display = ((char.firstname or '') .. ' ' .. (char.lastname or '')):gsub('^%s+', ''):gsub('%s+$', '')
    MySQL.insert.await(
        'INSERT INTO dizzy_phone_social_posts (app_id, citizenid, author_phone, author_name, body) VALUES (?, ?, ?, ?, ?)',
        { appId, Player.PlayerData.citizenid, phone, display, body }
    )
end)

CreateThread(function()
    for i = 1, #Config.PhoneItems do
        local itemName = Config.PhoneItems[i]
        QBCore.Functions.CreateUseableItem(itemName, function(source)
            TriggerClientEvent('dizzy-phone:client:openFromItem', source)
        end)
    end
end)

AddEventHandler('playerDropped', function()
    local src = source
    lastMsgTick[src] = nil
    for tgt, pend in pairs(PendingAirDrop) do
        if tgt == src or (pend and pend.fromSrc == src) then
            PendingAirDrop[tgt] = nil
        end
    end
    local p = PendingByCaller[src] or PendingByTarget[src]
    if p then
        local other = (src == p.fromSrc) and p.toSrc or p.fromSrc
        clearPending(p)
        TriggerClientEvent('dizzy-phone:client:callEnded', other, 'dropped')
    end
    local other2
    local ch = ActiveCallChannel[src]
    if ch then
        for a, c in pairs(ActiveCallChannel) do
            if a ~= src and c == ch then other2 = a break end
        end
    end
    endVoiceFor(src)
    if other2 then
        endVoiceFor(other2)
        TriggerClientEvent('dizzy-phone:client:callEnded', other2, 'dropped')
    end
end)
