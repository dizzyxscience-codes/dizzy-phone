local QBCore = exports['qb-core']:GetCoreObject()

local isOpen = false
local pendingAirdrop = nil
--- Incoming call payload waiting for NUI bootstrap (overlay lives inside #root which is hidden until phone opens).
local pendingIncomingCall = nil
--- True between incomingCall and accept / decline / end (used to decline if player closes phone while ringing).
local awaitingIncomingAnswer = false
--- Non-nil while a voice call is connected (closing the phone must not hang up).
local activeCallPeerPhone = nil
--- Outbound ring in progress (same: closing phone only hides UI).
local outgoingRinging = false
local outboundRingDial = ''
--- GTA cell-phone camera session (LB-style).
local inCellCameraCapture = false
local cellCamCaption = ''
local cellCamFront = false
local cellCamBusyShot = false
local cellCamHudGen = 0
local CELL_FRONT_CAM_NATIVE = 0x2491A93618B7D838
local CELL_CAM_HELP_TEXT_ENTRY = 'DIZZYPHONE_CAMHELP'
--- Speakerphone (pma-voice call volume boost) while in an active call only.
local phoneSpeakerOn = false
local savedCallVolumeBeforeSpeaker = nil
local phoneProp = 0
local lastPhoneAnimCtx = nil --- 'foot' | 'car'

local PHONE_ANIM_FOOT = { dict = 'cellphone@', clip = 'cellphone_text_read_base' }
local PHONE_ANIM_CAR = { dict = 'anim@cellphone@in_car@ps', clip = 'cellphone_text_in' }

--- Bumped to cancel any in-flight incoming ring loop (avoids overlap if a second call races).
local incomingCallRingGeneration = 0
--- Sound id for the current ring tone (must use StopSound — PlaySoundFrontend(-1, …) cannot be cut short).
local activeIncomingRingSoundId = nil

local function defaultCallVolume()
    return tonumber(GetConvar('voice_defaultCallVolume', '60')) or 60
end

local function resetPhoneSpeakerAfterCall()
    if phoneSpeakerOn or savedCallVolumeBeforeSpeaker then
        local restore = savedCallVolumeBeforeSpeaker or defaultCallVolume()
        pcall(function()
            if GetResourceState('pma-voice') == 'started' then
                exports['pma-voice']:setCallVolume(restore)
            end
        end)
    end
    phoneSpeakerOn = false
    savedCallVolumeBeforeSpeaker = nil
end

local function releaseIncomingRingSound(sid)
    if not sid then return end
    pcall(function()
        StopSound(sid)
        ReleaseSoundId(sid)
    end)
end

local function stopIncomingCallRing()
    incomingCallRingGeneration = incomingCallRingGeneration + 1
    local sid = activeIncomingRingSoundId
    activeIncomingRingSoundId = nil
    releaseIncomingRingSound(sid)
end

local function playNewTextSound()
    if not Config.EnablePhoneSounds then return end
    local ok = pcall(function()
        PlaySoundFrontend(-1, 'Text_Arrive', 'Phone_SoundSet_Default', true)
    end)
    if ok then return end
    pcall(function()
        PlaySoundFrontend(-1, 'Menu_Accept', 'HUD_FRONTEND_DEFAULT_SOUNDSET', true)
    end)
end

local function startIncomingCallRingLoop()
    if not Config.EnablePhoneSounds then return end
    incomingCallRingGeneration = incomingCallRingGeneration + 1
    local gen = incomingCallRingGeneration
    local interval = tonumber(Config.CallRingRepeatMs) or 2800
    CreateThread(function()
        while gen == incomingCallRingGeneration do
            if activeIncomingRingSoundId then
                local old = activeIncomingRingSoundId
                activeIncomingRingSoundId = nil
                releaseIncomingRingSound(old)
            end
            local sid = GetSoundId()
            activeIncomingRingSoundId = sid
            pcall(function()
                PlaySoundFrontend(sid, 'Remote_Ring', 'Phone_SoundSet_Michael', true)
            end)
            Wait(interval)
        end
        local tail = activeIncomingRingSoundId
        activeIncomingRingSoundId = nil
        releaseIncomingRingSound(tail)
    end)
end

local function getWorkingCameraResource()
    for _, name in ipairs(Config.GetCameraResourceCandidates()) do
        if GetResourceState(name) == 'started' then
            return name
        end
    end
    return nil
end

local function blockedByMeta()
    local data = QBCore.Functions.GetPlayerData()
    if not data or not data.metadata then return false end
    local m = data.metadata
    if Config.BlockIfDead and m.isdead then return true end
    if Config.BlockIfLastStand and m.inlaststand then return true end
    if Config.BlockIfCuffed and m.ishandcuffed then return true end
    return false
end

--- Parse JSON (or raw URL) returned by screenshot-basic upload callbacks.
local function parseScreenshotUploadResult(raw)
    if raw == nil then return nil end
    if type(raw) == 'table' then
        if type(raw.url) == 'string' then return raw.url end
        if type(raw.link) == 'string' then return raw.link end
        local att = raw.attachments
        if type(att) == 'table' and att[1] then
            local a = att[1]
            if type(a.url) == 'string' then return a.url end
            if type(a.proxy_url) == 'string' then return a.proxy_url end
        end
        return nil
    end
    if type(raw) ~= 'string' or raw == '' then return nil end
    if raw:match('^data:image/') then return raw end
    local ok, data = pcall(json.decode, raw)
    if ok and type(data) == 'table' then
        return parseScreenshotUploadResult(data)
    end
    return raw:match('^(https?://%S+)')
end

local function cellFrontCamActivate(active)
    Citizen.InvokeNative(CELL_FRONT_CAM_NATIVE, active and true or false)
end

--- screenshot-basic upload or data URL, then server save. Calls onFinished(ok).
local function runScreenshotAndSave(resName, caption, onFinished)
    local function done(ok)
        if onFinished then
            onFinished(ok and true or false)
        end
    end

    local function finalizeSave(imageUrl)
        if not imageUrl or imageUrl == '' then
            done(false)
            return
        end
        QBCore.Functions.TriggerCallback('dizzy-phone:server:savePhoto', function(res)
            done(res and res.ok)
        end, imageUrl, caption or '')
    end

    local urlcfg = Config.CameraUploadUrl
    if urlcfg and urlcfg ~= '' then
        local exportOk = pcall(function()
            exports[resName]:requestScreenshotUpload(
                urlcfg,
                Config.CameraUploadField or 'files[0]',
                function(innerData)
                    CreateThread(function()
                        local imageUrl = parseScreenshotUploadResult(innerData)
                        if not imageUrl then
                            done(false)
                            return
                        end
                        finalizeSave(imageUrl)
                    end)
                end
            )
        end)
        if not exportOk then
            done(false)
        end
    else
        local quality = tonumber(Config.CameraScreenshotQuality) or 0.82
        local exportOk = pcall(function()
            exports[resName]:requestScreenshot({
                encoding = 'jpg',
                quality = quality,
            }, function(dataUri)
                CreateThread(function()
                    finalizeSave(dataUri)
                end)
            end)
        end)
        if not exportOk then
            done(false)
        end
    end
end

---@param resumePhone boolean|nil when false, do not restore hand phone / NUI after closing cell cam (e.g. main phone closing).
local function endCellCameraSession(resumePhone)
    if resumePhone == nil then
        resumePhone = true
    end
    inCellCameraCapture = false
    cellCamBusyShot = false
    cellCamHudGen = cellCamHudGen + 1
    pcall(function()
        CellCamActivate(false, false)
    end)
    pcall(function()
        DestroyMobilePhone()
    end)
    cellFrontCamActivate(false)
    cellCamFront = false
    ClearPedSecondaryTask(PlayerPedId())
    SetNuiFocusKeepInput(false)
    DisplayRadar(true)
    ClearHelp(true)
    SendNUIMessage({ action = 'cameraCellMode', active = false })
    SendNUIMessage({ action = 'cameraStatus', busy = false, text = '' })
    if resumePhone and isOpen then
        SetNuiFocus(true, true)
        startPhoneAnim()
    end
end

local function maintainCellCameraSelfieAnim(ped)
    if Config.CellCamSelfieAnim == false then
        return
    end
    ped = ped or PlayerPedId()
    local inCar = IsPedInAnyVehicle(ped, false)
    local dict = 'cellphone@self'
    local anim = inCar and 'selfie' or 'selfie_in'
    if not loadPhoneAnimDict(dict) then
        return
    end
    if not IsEntityPlayingAnim(ped, dict, anim, 3) then
        TaskPlayAnim(ped, dict, anim, 8.0, -8.0, -1, 49, 0.0, false, false, false)
    end
end

local function startCellCameraHudLoop()
    cellCamHudGen = cellCamHudGen + 1
    local gen = cellCamHudGen
    if Config.CellCamShowTip ~= false then
        AddTextEntry(
            CELL_CAM_HELP_TEXT_ENTRY,
            'Camera — move mouse to aim, scroll wheel to zoom.~n~Use on-screen Capture, Flip, or Close.~n~Escape closes the camera.'
        )
    end
    CreateThread(function()
        while inCellCameraCapture and gen == cellCamHudGen do
            HideHudComponentThisFrame(7)
            HideHudComponentThisFrame(8)
            HideHudComponentThisFrame(9)
            HideHudComponentThisFrame(6)
            HideHudComponentThisFrame(19)
            HideHudAndRadarThisFrame()
            maintainCellCameraSelfieAnim(PlayerPedId())
            if Config.CellCamShowTip ~= false then
                BeginTextCommandDisplayHelp(CELL_CAM_HELP_TEXT_ENTRY)
                EndTextCommandDisplayHelp(0, false, true, 0)
            end
            Wait(0)
        end
    end)
end

local function takePhonePhotoClassic(caption)
    if not isOpen or blockedByMeta() then return end
    local resName = getWorkingCameraResource()
    if not resName then
        return
    end
    local wasOpen = isOpen
    stopPhoneAnim()
    SetNuiFocus(false, false)
    if isOpen then
        SendNUIMessage({ action = 'cameraStatus', busy = true, text = 'Capturing… hide phone UI' })
    end
    local preDelay = tonumber(Config.CameraCaptureDelayMs) or 720
    if preDelay < 200 then preDelay = 200 end
    if preDelay > 3000 then preDelay = 3000 end
    Wait(preDelay)

    local function restorePhoneNui()
        if isOpen then
            SendNUIMessage({ action = 'cameraStatus', busy = false, text = '' })
        end
        if wasOpen and isOpen then
            startPhoneAnim()
            SetNuiFocus(true, true)
        end
    end

    runScreenshotAndSave(resName, caption, function(ok)
        restorePhoneNui()
        if ok and isOpen then
            SendNUIMessage({ action = 'galleryRefresh' })
            SendNUIMessage({ action = 'photoSavedToGallery' })
        end
    end)
end

local function beginCellCameraCapture(caption)
    if not isOpen or blockedByMeta() then return end
    local resName = getWorkingCameraResource()
    if not resName then
        return
    end
    cellCamCaption = caption or ''
    stopPhoneAnim()
    DisplayRadar(false)
    SetNuiFocusKeepInput(true)
    SetNuiFocus(true, true)
    local created = pcall(function()
        CreateMobilePhone(tonumber(Config.CellCamPhoneType) or 2)
    end)
    if not created then
        DisplayRadar(true)
        SetNuiFocusKeepInput(false)
        takePhonePhotoClassic(caption)
        return
    end
    local startup = tonumber(Config.CellCamStartupDelayMs) or 450
    if startup < 120 then startup = 120 end
    if startup > 2000 then startup = 2000 end
    Wait(startup)
    pcall(function()
        CellCamActivate(true, true)
    end)
    inCellCameraCapture = true
    cellCamFront = false
    startCellCameraHudLoop()
    SendNUIMessage({
        action = 'cameraCellMode',
        active = true,
        allowFlip = Config.CellCamAllowFlip ~= false,
        showGrid = Config.CellCamShowGrid ~= false,
    })
end

function takePhonePhoto(caption)
    if not isOpen or blockedByMeta() then return end
    if Config.UseCellPhoneCamera then
        beginCellCameraCapture(caption)
    else
        takePhonePhotoClassic(caption)
    end
end

local function loadPhoneAnimDict(dict)
    if HasAnimDictLoaded(dict) then return true end
    RequestAnimDict(dict)
    local t = 0
    while not HasAnimDictLoaded(dict) and t < 100 do
        Wait(10)
        t = t + 1
    end
    return HasAnimDictLoaded(dict)
end

local function getPhoneAnimForPed(ped)
    if IsPedInAnyVehicle(ped, false) then
        return PHONE_ANIM_CAR.dict, PHONE_ANIM_CAR.clip
    end
    return PHONE_ANIM_FOOT.dict, PHONE_ANIM_FOOT.clip
end

--- Upper-body phone hold; on foot uses standard cellphone@ (in_car anim looks wrong walking).
local function playPhoneHoldAnim(ped)
    ped = ped or PlayerPedId()
    local dict, clip = getPhoneAnimForPed(ped)
    local ctx = IsPedInAnyVehicle(ped, false) and 'car' or 'foot'
    if lastPhoneAnimCtx ~= ctx then
        ClearPedSecondaryTask(ped)
        lastPhoneAnimCtx = ctx
    end
    if not loadPhoneAnimDict(dict) then return end
    if not IsEntityPlayingAnim(ped, dict, clip, 3) then
        TaskPlayAnim(ped, dict, clip, 8.0, -8.0, -1, 49, 0, false, false, false)
    end
end

local function startPhoneAnim()
    local ped = PlayerPedId()
    playPhoneHoldAnim(ped)
    Wait(100)
    if phoneProp == 0 then
        local primary = Config.PhoneProp or `prop_phone_proto`
        local fallback = Config.PhonePropFallback or `prop_npc_phone_02`
        local m = primary
        RequestModel(m)
        local t = 0
        while not HasModelLoaded(m) and t < 100 do
            Wait(10)
            t = t + 1
        end
        if not HasModelLoaded(m) then
            m = fallback
            RequestModel(m)
            t = 0
            while not HasModelLoaded(m) and t < 100 do
                Wait(10)
                t = t + 1
            end
        end
        if HasModelLoaded(m) then
            phoneProp = CreateObject(m, 0.0, 0.0, 0.0, true, true, false)
            local ox, oy, oz, rx, ry, rz = 0.0, 0.0, 0.0, 0.0, 0.0, 0.0
            if m == primary then
                -- Slightly forward for flatter “slab” models
                oz = 0.035
            end
            AttachEntityToEntity(phoneProp, ped, GetPedBoneIndex(ped, 28422), ox, oy, oz, rx, ry, rz, true, true, false, true, 1, true)
        end
    end
end

local function stopPhoneAnim()
    local ped = PlayerPedId()
    ClearPedSecondaryTask(ped)
    lastPhoneAnimCtx = nil
    if phoneProp ~= 0 then
        DeleteObject(phoneProp)
        phoneProp = 0
    end
end

local function declineIncomingIfRinging()
    if not awaitingIncomingAnswer then return end
    awaitingIncomingAnswer = false
    pendingIncomingCall = nil
    stopIncomingCallRing()
    TriggerServerEvent('dizzy-phone:server:callDecline')
end

local function failBootstrapAndClearIncoming()
    pendingIncomingCall = nil
    if awaitingIncomingAnswer then
        awaitingIncomingAnswer = false
        stopIncomingCallRing()
        TriggerServerEvent('dizzy-phone:server:callDecline')
    end
end

local function setOpen(state)
    if state == isOpen then return end
    if not state and inCellCameraCapture then
        endCellCameraSession(false)
    end
    if not state and awaitingIncomingAnswer then
        declineIncomingIfRinging()
    end
    isOpen = state
    SetNuiFocus(state, state)
    SetNuiFocusKeepInput(false)
    if state then
        startPhoneAnim()
        QBCore.Functions.TriggerCallback('dizzy-phone:server:bootstrap', function(payload)
            if not payload then
                isOpen = false
                SetNuiFocus(false, false)
                stopPhoneAnim()
                failBootstrapAndClearIncoming()
                return
            end
            if payload.error == 'no_phone' then
                isOpen = false
                SetNuiFocus(false, false)
                stopPhoneAnim()
                failBootstrapAndClearIncoming()
                return
            end
            if payload.error == 'no_number' then
                isOpen = false
                SetNuiFocus(false, false)
                stopPhoneAnim()
                failBootstrapAndClearIncoming()
                return
            end
            SendNUIMessage({ action = 'open', data = payload })
            if pendingAirdrop then
                SendNUIMessage({ action = 'airdropIncoming', data = pendingAirdrop })
            end
            if pendingIncomingCall then
                local d = pendingIncomingCall
                pendingIncomingCall = nil
                SendNUIMessage({ action = 'incomingCall', data = d })
            end
            if activeCallPeerPhone then
                SendNUIMessage({ action = 'callConnected', data = { withPhone = activeCallPeerPhone } })
                if phoneSpeakerOn then
                    SendNUIMessage({ action = 'callSpeaker', on = true })
                end
            elseif outgoingRinging then
                SendNUIMessage({ action = 'callResult', reason = 'ringing', dial = outboundRingDial })
            end
        end)
    else
        stopPhoneAnim()
        local preserveCallUi = (activeCallPeerPhone ~= nil) or outgoingRinging
        SendNUIMessage({ action = 'close', preserveCallUi = preserveCallUi })
    end
end

local function tryToggle()
    if isOpen then
        setOpen(false)
        return
    end
    if blockedByMeta() then
        return
    end
    setOpen(true)
end

RegisterCommand(Config.OpenCommand, function()
    tryToggle()
end, false)

RegisterKeyMapping(Config.OpenCommand, 'Open phone', 'keyboard', Config.DefaultKey)

RegisterNetEvent('dizzy-phone:client:openFromItem', function()
    tryToggle()
end)

RegisterNetEvent('dizzy-phone:client:airdropIncoming', function(data)
    if type(data) ~= 'table' then return end
    pendingAirdrop = data
    if isOpen then
        SendNUIMessage({ action = 'airdropIncoming', data = data })
    end
end)

RegisterNetEvent('QBCore:Client:OnMoneyChange', function(mtype)
    if not isOpen then return end
    local d = QBCore.Functions.GetPlayerData()
    if not d or not d.money then return end
    SendNUIMessage({
        action = 'money',
        cash = d.money.cash,
        bank = d.money.bank,
    })
end)

RegisterNetEvent('dizzy-phone:client:messagePush', function(row)
    SendNUIMessage({ action = 'messagePush', row = row })
    playNewTextSound()
end)

RegisterNetEvent('dizzy-phone:client:incomingCall', function(data)
    if type(data) ~= 'table' then return end
    awaitingIncomingAnswer = true
    startIncomingCallRingLoop()
    if isOpen then
        SendNUIMessage({ action = 'incomingCall', data = data })
    else
        if blockedByMeta() then
            awaitingIncomingAnswer = false
            pendingIncomingCall = nil
            stopIncomingCallRing()
            TriggerServerEvent('dizzy-phone:server:callDecline')
            return
        end
        pendingIncomingCall = data
        setOpen(true)
    end
end)

RegisterNetEvent('dizzy-phone:client:callResult', function(reason, dial)
    if reason == 'ringing' then
        outgoingRinging = true
        outboundRingDial = type(dial) == 'string' and dial or ''
    else
        outgoingRinging = false
        outboundRingDial = ''
    end
    SendNUIMessage({ action = 'callResult', reason = reason, dial = outboundRingDial })
end)

RegisterNetEvent('dizzy-phone:client:callConnected', function(data)
    stopIncomingCallRing()
    awaitingIncomingAnswer = false
    pendingIncomingCall = nil
    outgoingRinging = false
    outboundRingDial = ''
    activeCallPeerPhone = data and data.withPhone or nil
    SendNUIMessage({ action = 'callConnected', data = data })
end)

RegisterNetEvent('dizzy-phone:client:callEnded', function(reason)
    stopIncomingCallRing()
    awaitingIncomingAnswer = false
    pendingIncomingCall = nil
    activeCallPeerPhone = nil
    outgoingRinging = false
    outboundRingDial = ''
    resetPhoneSpeakerAfterCall()
    SendNUIMessage({ action = 'callEnded', reason = reason })
end)

RegisterNUICallback('close', function(_, cb)
    setOpen(false)
    cb('ok')
end)

RegisterNUICallback('ready', function(_, cb)
    cb('ok')
end)

RegisterNUICallback('getContacts', function(_, cb)
    QBCore.Functions.TriggerCallback('dizzy-phone:server:getContacts', function(rows)
        cb(rows or {})
    end)
end)

RegisterNUICallback('getMessages', function(_, cb)
    QBCore.Functions.TriggerCallback('dizzy-phone:server:getMessages', function(rows)
        cb(rows or {})
    end)
end)

RegisterNUICallback('getNotes', function(_, cb)
    QBCore.Functions.TriggerCallback('dizzy-phone:server:getNotes', function(rows)
        cb(rows or {})
    end)
end)

RegisterNUICallback('contactSave', function(data, cb)
    TriggerServerEvent('dizzy-phone:server:contactSave', data)
    cb('ok')
end)

RegisterNUICallback('contactDelete', function(data, cb)
    TriggerServerEvent('dizzy-phone:server:contactDelete', data.id)
    cb('ok')
end)

RegisterNUICallback('sendMessage', function(data, cb)
    TriggerServerEvent('dizzy-phone:server:sendMessage', data.to, data.body)
    cb('ok')
end)

RegisterNUICallback('markRead', function(data, cb)
    TriggerServerEvent('dizzy-phone:server:markRead', data.other)
    cb('ok')
end)

RegisterNUICallback('noteSave', function(data, cb)
    TriggerServerEvent('dizzy-phone:server:noteSave', data.id, data.title, data.body)
    cb('ok')
end)

RegisterNUICallback('noteDelete', function(data, cb)
    TriggerServerEvent('dizzy-phone:server:noteDelete', data.id)
    cb('ok')
end)

RegisterNUICallback('bankTransfer', function(data, cb)
    QBCore.Functions.TriggerCallback('dizzy-phone:server:bankTransfer', function(res)
        cb(res or { ok = false })
    end, data.phone, data.amount)
end)

RegisterNUICallback('setWaypoint', function(data, cb)
    local x = tonumber(data.x)
    local y = tonumber(data.y)
    if x and y then
        SetNewWaypoint(x + 0.0, y + 0.0)
    end
    cb('ok')
end)

RegisterNUICallback('getMyCoords', function(_, cb)
    local c = GetEntityCoords(PlayerPedId())
    cb({ x = c.x, y = c.y, z = c.z })
end)

RegisterNUICallback('callStart', function(data, cb)
    TriggerServerEvent('dizzy-phone:server:callStart', data.phone)
    cb('ok')
end)

RegisterNUICallback('callAccept', function(_, cb)
    stopIncomingCallRing()
    TriggerServerEvent('dizzy-phone:server:callAccept')
    cb('ok')
end)

RegisterNUICallback('callDecline', function(_, cb)
    stopIncomingCallRing()
    TriggerServerEvent('dizzy-phone:server:callDecline')
    cb('ok')
end)

RegisterNUICallback('callEnd', function(_, cb)
    TriggerServerEvent('dizzy-phone:server:callEnd')
    cb('ok')
end)

RegisterNUICallback('callHangup', function(_, cb)
    TriggerServerEvent('dizzy-phone:server:callHangup')
    cb('ok')
end)

RegisterNUICallback('callToggleSpeaker', function(_, cb)
    if not activeCallPeerPhone or GetResourceState('pma-voice') ~= 'started' then
        cb('ok')
        return
    end
    phoneSpeakerOn = not phoneSpeakerOn
    if phoneSpeakerOn then
        local prev = defaultCallVolume()
        local ok, cur = pcall(function()
            return exports['pma-voice']:getCallVolume()
        end)
        if ok and type(cur) == 'number' then
            prev = cur
        end
        savedCallVolumeBeforeSpeaker = prev
        local spVol = tonumber(Config.CallSpeakerVolume) or 100
        if spVol < 1 then spVol = 1 end
        if spVol > 100 then spVol = 100 end
        pcall(function()
            exports['pma-voice']:setCallVolume(spVol)
        end)
    else
        local restore = savedCallVolumeBeforeSpeaker or defaultCallVolume()
        pcall(function()
            exports['pma-voice']:setCallVolume(restore)
        end)
        savedCallVolumeBeforeSpeaker = nil
    end
    SendNUIMessage({ action = 'callSpeaker', on = phoneSpeakerOn })
    cb('ok')
end)

RegisterNUICallback('getAirDropNearby', function(_, cb)
    QBCore.Functions.TriggerCallback('dizzy-phone:server:getAirDropNearby', function(rows)
        cb(rows or {})
    end)
end)

RegisterNUICallback('airdropSend', function(data, cb)
    local tid = tonumber(data and data.targetServerId)
    if tid then TriggerServerEvent('dizzy-phone:server:airdropSend', tid) end
    cb('ok')
end)

RegisterNUICallback('airdropAccept', function(_, cb)
    pendingAirdrop = nil
    TriggerServerEvent('dizzy-phone:server:airdropAccept')
    cb('ok')
end)

RegisterNUICallback('airdropDecline', function(_, cb)
    pendingAirdrop = nil
    TriggerServerEvent('dizzy-phone:server:airdropDecline')
    cb('ok')
end)

RegisterNUICallback('installApp', function(data, cb)
    QBCore.Functions.TriggerCallback('dizzy-phone:server:installApp', function(res)
        cb(res or { ok = false })
    end, data and data.appId)
end)

RegisterNUICallback('uninstallApp', function(data, cb)
    QBCore.Functions.TriggerCallback('dizzy-phone:server:uninstallApp', function(res)
        cb(res or { ok = false })
    end, data and data.appId)
end)

RegisterNUICallback('getSocialPosts', function(data, cb)
    QBCore.Functions.TriggerCallback('dizzy-phone:server:getSocialPosts', function(rows)
        cb(rows or {})
    end, data and data.appId)
end)

RegisterNUICallback('createSocialPost', function(data, cb)
    TriggerServerEvent('dizzy-phone:server:createSocialPost', data and data.appId, data and data.body)
    cb('ok')
end)

RegisterNUICallback('takePhoto', function(data, cb)
    local cap = data and data.caption or ''
    CreateThread(function()
        takePhonePhoto(cap)
    end)
    cb('ok')
end)

RegisterNUICallback('cellCameraCancel', function(_, cb)
    if inCellCameraCapture then
        endCellCameraSession(true)
    end
    cb('ok')
end)

RegisterNUICallback('cellCameraFlip', function(_, cb)
    if inCellCameraCapture and Config.CellCamAllowFlip ~= false then
        cellCamFront = not cellCamFront
        cellFrontCamActivate(cellCamFront)
    end
    cb('ok')
end)

RegisterNUICallback('cellCameraShutter', function(_, cb)
    cb('ok')
    if not inCellCameraCapture or cellCamBusyShot then return end
    local resName = getWorkingCameraResource()
    if not resName then
        endCellCameraSession(true)
        return
    end
    cellCamBusyShot = true
    SendNUIMessage({ action = 'cameraStatus', busy = true, text = 'Saving…' })
    CreateThread(function()
        local d = tonumber(Config.CellCamShutterDelayMs) or 120
        if d < 0 then d = 0 end
        if d > 800 then d = 800 end
        Wait(d)
        runScreenshotAndSave(resName, cellCamCaption, function(ok)
            cellCamBusyShot = false
            endCellCameraSession(true)
            if ok and isOpen then
                SendNUIMessage({ action = 'galleryRefresh' })
                SendNUIMessage({ action = 'photoSavedToGallery' })
            end
        end)
    end)
end)

RegisterNUICallback('getPhotos', function(_, cb)
    QBCore.Functions.TriggerCallback('dizzy-phone:server:getPhotos', function(rows)
        cb(rows or {})
    end)
end)

RegisterNUICallback('savePhotoUrl', function(data, cb)
    local url = data and data.url
    local cap = data and data.caption or ''
    QBCore.Functions.TriggerCallback('dizzy-phone:server:savePhoto', function(res)
        res = res or { ok = false, err = 'fail' }
        cb(res)
    end, url, cap)
end)

RegisterNUICallback('deletePhoto', function(data, cb)
    TriggerServerEvent('dizzy-phone:server:deletePhoto', data and data.id)
    cb('ok')
end)

RegisterNUICallback('getServices', function(_, cb)
    QBCore.Functions.TriggerCallback('dizzy-phone:server:getServices', function(rows)
        cb(rows or {})
    end)
end)

RegisterNUICallback('getServiceStaff', function(data, cb)
    QBCore.Functions.TriggerCallback('dizzy-phone:server:getServiceStaff', function(rows)
        cb(rows or {})
    end, data and data.job)
end)

RegisterNUICallback('getGarageVehiclesPhone', function(_, cb)
    QBCore.Functions.TriggerCallback('dizzy-phone:server:getGarageVehiclesPhone', function(rows)
        cb(rows or {})
    end)
end)

RegisterNUICallback('deliverGarageVehicle', function(data, cb)
    QBCore.Functions.TriggerCallback('dizzy-phone:server:deliverGarageVehicle', function(res)
        cb(res or { ok = false, err = 'unknown' })
    end, data and data.plate)
end)

local phoneAnimRefresh = 0
CreateThread(function()
    while true do
        if isOpen then
            phoneAnimRefresh = phoneAnimRefresh + 1
            if phoneAnimRefresh >= 28 then
                phoneAnimRefresh = 0
                playPhoneHoldAnim(PlayerPedId())
            end
            DisableControlAction(0, 1, true)
            DisableControlAction(0, 2, true)
            DisableControlAction(0, 24, true)
            DisableControlAction(0, 25, true)
            DisablePlayerFiring(PlayerId(), true)
            Wait(0)
        else
            phoneAnimRefresh = 0
            Wait(500)
        end
    end
end)

exports('IsOpen', function()
    return isOpen
end)
