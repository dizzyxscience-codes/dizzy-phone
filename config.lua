Config = {}

-- Command + default keybind (players can rebind in GTA settings)
Config.OpenCommand = 'phone'
Config.DefaultKey = 'M'

-- Require a phone item from Config.PhoneItems to open (set false to allow everyone)
Config.RequirePhoneItem = true
Config.PhoneItems = { 'phone', 'iphone', 'samsungphone' }

-- Block opening when dead / cuffed / last stand (uses QBCore metadata)
Config.BlockIfDead = true
Config.BlockIfCuffed = true
Config.BlockIfLastStand = true

-- SMS
Config.MaxMessageLength = 500
Config.MessageCooldownMs = 800

-- Bank transfer from Wallet app (set false to hide transfer UI)
Config.EnableBankTransfer = true
Config.TransferMin = 10
Config.TransferMax = 50000
Config.TransferFeePercent = 0 -- e.g. 2 = 2% fee to server account (not implemented as sink; kept for future)

-- Voice calls (requires pma-voice with voice_enableCalls 1)
Config.EnableVoiceCalls = true
Config.CallRingTimeoutMs = 45000
-- In-call speaker: pma-voice call receive volume while speaker is on (1–100)
Config.CallSpeakerVolume = 100

-- Incoming SMS / call UI sounds (GTA frontend soundsets)
Config.EnablePhoneSounds = true
-- Time between repeated incoming-call rings (ms)
Config.CallRingRepeatMs = 2800

-- GTA object shown in hand (prop_phone_proto = flatter slab, more Android-like than prop_npc_phone_02)
Config.PhoneProp = `prop_phone_proto`
Config.PhonePropFallback = `prop_npc_phone_02`

-- AirDrop (share your number with nearby players; server validates distance)
Config.AirDropRange = 12.0
Config.AirDropPendingMs = 90000

-- Downloadable apps (social). IDs must match sql / server checks.
Config.AppCatalog = {
    { id = 'chirp', name = 'Chirp', description = 'Short posts, city trends, and hashtags.', icon = '🐦', category = 'Social' },
    { id = 'pixl', name = 'Pixl', description = 'Caption drops and photo-story vibes.', icon = '📸', category = 'Social' },
    { id = 'cityfeed', name = 'CityFeed', description = 'Local buzz, jobs, and neighborhood takes.', icon = '🏙️', category = 'Social' },
}

Config.MaxSocialPostLength = 280

-- Camera: captures the game view and saves to Gallery (dizzy_phone_photos).
-- Requires screenshot-basic (or another resource with the same exports) — start it before dizzy-phone in server.cfg.
-- Discord webhook: use multipart field "files[0]" (default). FiveManage / other APIs: set field + URL per their docs.
--
-- UseCellPhoneCamera: GTA phone camera (CreateMobilePhone / CellCamActivate) — same idea as LB Phone / gcphone.
-- Set false to use “classic” mode: hide NUI briefly and screenshot the raw screen.
Config.UseCellPhoneCamera = true
Config.CellCamPhoneType = 2 -- CreateMobilePhone style (0–4; 2 = common smartphone)
Config.CellCamStartupDelayMs = 450
Config.CellCamShutterDelayMs = 120
Config.CellCamAllowFlip = true -- front / rear via CellFrontCamActivate
-- LB Phone–style presentation (see lb-phone Config.Camera + animations: cellphone@self, grid, tips)
Config.CellCamSelfieAnim = true -- hold selfie pose while the in-game phone camera is active
Config.CellCamShowTip = true -- GTA help text (top-left) with controls while in camera
Config.CellCamShowGrid = true -- rule-of-thirds grid overlay on the NUI HUD
Config.CameraResource = 'screenshot-basic'
--- Tried in order after CameraResource if the primary is not started (same export API as screenshot-basic).
Config.CameraResourceFallbacks = {}
Config.CameraUploadUrl = '' -- e.g. Discord webhook or https://api.fivemanage.com/api/image?apiKey=...
Config.CameraUploadField = 'files[0]'
-- If CameraUploadUrl is empty, camera uses data URLs stored in the DB (image_url should be MEDIUMTEXT — see sql/).
Config.CameraScreenshotQuality = 0.82
Config.CameraMaxDataUrlLength = 524288 -- max chars for data:image/...;base64,... (~512 KB)
-- Ms to wait after hiding NUI before screenshot (larger = cleaner frame on slow PCs).
Config.CameraCaptureDelayMs = 720
Config.MaxGalleryPhotos = 200
Config.MaxPhotoCaptionLength = 200

---@return string[]
function Config.GetCameraResourceCandidates()
    local try = {}
    local primary = Config.CameraResource or 'screenshot-basic'
    try[#try + 1] = primary
    if type(Config.CameraResourceFallbacks) == 'table' then
        for i = 1, #Config.CameraResourceFallbacks do
            local n = Config.CameraResourceFallbacks[i]
            if type(n) == 'string' and n ~= '' and n ~= primary then
                try[#try + 1] = n
            end
        end
    end
    return try
end

-- Services app: businesses listed in the phone. "Open" = at least one employee clocked on (QBCore job duty).
-- job must match QBCore.Shared.Jobs (e.g. police, ambulance). label is optional (defaults to shared job label).
Config.ServiceDirectory = {
    { job = 'police', label = 'Police' },
    { job = 'ambulance', label = 'EMS' },
    { job = 'mechanic', label = 'Mechanic' },
    { job = 'taxi', label = 'Taxi' },
}

-- My Garage (qb-garages): list garaged vehicles and request delivery at the garage spawn (same as walking to the lot).
Config.EnablePhoneGarage = true
Config.PhoneGarageResource = 'qb-garages'
Config.PhoneGarageValetFee = 0 -- cash charged when requesting vehicle; 0 = free
-- Used when a vehicle's stored garage key is missing from qb-garages (e.g. house parking).
Config.PhoneGarageFallback = 'motelgarage'
