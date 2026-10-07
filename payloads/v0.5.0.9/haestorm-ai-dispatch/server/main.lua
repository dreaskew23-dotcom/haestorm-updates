local QB = exports['qb-core']:GetCoreObject()
local units, lanes, seenCalls, dedupe, rate = {}, {}, {}, {}, {}
local mode, enabled = 'ai', Config.Enabled
local usage = { day = '', month = '', daily = 0, monthly = 0 }
local voiceSessions, notices, voiceGeneration = {}, {}, 1
local replyCursor = {}
local function understandingLog(stage, u, rawText, parsed, extra)
    if not Config.UnderstandingDebug then return end
    local payload = {
        stage = stage, unit = u and u.sign or nil, source = u and u.source or nil,
        raw = rawText, normalized = parsed and parsed.text or nil,
        intent = parsed and parsed.intent or nil, confidence = parsed and parsed.confidence or nil,
        status = u and units[u.source] and units[u.source].status or nil,
        callId = u and units[u.source] and units[u.source].callId or nil, extra = extra, time = os.time()
    }
    print(('[AI dispatch understanding] %s'):format(json.encode(payload)))
end
local function variant(key, fallback)
    local list = Config.ReplyVariants and Config.ReplyVariants[key]
    if type(list) ~= 'table' or #list == 0 then return fallback end
    replyCursor[key] = (replyCursor[key] or 0) % #list + 1
    return list[replyCursor[key]]
end
local function authorized(src, ace) return src == 0 or IsPlayerAceAllowed(src, ace) end
local function radioSign(u)
    local aliases = Config.RadioCallsignAliases or {}
    return tostring(aliases[u.sign] or u.sign)
end
local function identity(src, allowOffDuty)
    local p = QB.Functions.GetPlayer(src)
    if not p then return nil end
    local d = p.PlayerData
    if type(d) ~= 'table' or type(d.job) ~= 'table' then return nil end
    for name, a in pairs(Config.Agencies) do
        local sign = tostring(d.metadata and d.metadata.callsign or '')
        local csOk, cs = DispatchBridge.callsign(src)
        if csOk and type(cs) == 'table' and type(cs.callsign) == 'string' and cs.callsign ~= '' then sign = cs.callsign end
        if a.jobs[d.job.name] and sign ~= '' and sign:match(a.callsignPattern) and (d.job.onduty or allowOffDuty) then
            local channel = DispatchBridge.channel(src)
            if channel and a.channels[channel] then return { source = src, cid = d.citizenid, sign = sign, agency = name, channel = channel, player = p } end
        end
    end
end
local function lane(u)
    local k = u.agency .. ':' .. u.channel
    lanes[k] = lanes[k] or { queue = {}, emergency = {}, announcements = {}, agency = u.agency, channel = u.channel }
    return lanes[k]
end
local function saveEmergencyHolds()
    local holds = {}
    for key, l in pairs(lanes) do if next(l.emergency) then holds[key] = { agency = l.agency, channel = l.channel, emergency = l.emergency } end end
    SetResourceKvp('emergencyHolds', json.encode(holds))
end

local reply

-- v0.4.22: keep spoken ten-codes clipped and natural. Internal intent/config
-- values remain canonical (10-4, 10-9, etc.); only radio delivery changes.
local function radioSpeechText(text)
    text = tostring(text or '')
    return (text:gsub('10%-(%d+)', '10 %1'))
end

local function friendlyVehicleModel(model)
    model = tostring(model or '')
    if model == '' then return nil end
    local vehicles = QB.Shared and QB.Shared.Vehicles or nil
    local v = vehicles and (vehicles[model] or vehicles[model:lower()]) or nil
    if type(v) == 'table' then
        local brand = tostring(v.brand or ''):gsub('^%s+',''):gsub('%s+$','')
        local name = tostring(v.name or v.model or model):gsub('^%s+',''):gsub('%s+$','')
        if brand ~= '' and name ~= '' and not name:lower():find(brand:lower(), 1, true) then return brand .. ' ' .. name end
        if name ~= '' then return name end
    end
    return nil
end

local function cleanPlateReturn(result)
    if type(result) ~= 'table' or type(result.radioSummary) ~= 'string' then return nil end
    local summary = result.radioSummary
    local model = result.model or result.vehicleModel or result.vehicle or result.spawncode
    if not model then model = summary:match('[Rr]eturns to%s+([^,]+),') end
    local friendly = friendlyVehicleModel(model)
    if friendly and model and tostring(model) ~= '' then
        local escaped = tostring(model):gsub('([^%w])','%%%1')
        summary = summary:gsub(escaped, friendly, 1)
    end
    summary = summary:gsub('%s+', ' '):gsub('^%s+',''):gsub('%s+$','')
    return summary
end

-- v0.4.10: ps-dispatch is authoritative for call attachment/closure.
-- Use a server export for resource-to-resource sync. Local TriggerEvent calls do
-- not reliably preserve GetInvokingResource(), which could leave AI on a ghost call.
local function applyPsDispatchSync(payload)
    if type(payload) ~= 'table' or type(payload.citizenid) ~= 'string' then return false, 'invalid payload' end
    local action = tostring(payload.action or ''):upper()
    local callId = tonumber(payload.callId)

    for src, state in pairs(units) do
        local player = QB.Functions.GetPlayer(src)
        local cid = player and player.PlayerData and player.PlayerData.citizenid
        if cid == payload.citizenid then
            if action == 'ATTACH' then
                state.callId = callId or state.callId
                state.activity = os.time()
                state.welfare = nil
                if Config.UnderstandingDebug then
                    print(('[AI TEST SYNC] %s'):format(json.encode({action='ATTACH', unit=(player.PlayerData.metadata and player.PlayerData.metadata.callsign), callId=state.callId, time=os.time()})))
                end
                return true
            elseif (action == 'DETACH' or action == 'CALL_CLEARED') and (not callId or state.callId == callId) then
                local oldCall = state.callId
                state.callId = nil
                state.dispatchAttachGraceUntil = nil
                state.stop = nil
                state.awaitDisposition = nil
                state.pending = nil
                state.voicePending = nil
                state.waitingPlate = nil
                state.welfare = nil
                state.selecting = nil
                state.status = 'AVAILABLE'
                for _, l in pairs(lanes) do l.emergency[payload.citizenid] = nil end
                saveEmergencyHolds()
                CreateThread(function()
                    pcall(function() DispatchBridge.status(src, 'AVAILABLE') end)
                end)

                -- v0.4.12: a manual ps-dispatch detach/clear must be acknowledged over the radio,
                -- not only reflected silently in AI state. State is cleared first so the spoken
                -- acknowledgement cannot inherit the old call/emergency status.
                local syncUnit = identity(src, true)
                if syncUnit and reply then
                    local clearText = action == 'CALL_CLEARED'
                        and '10-4, that call is clear. Show you 10-8.'
                        or '10-4, you are clear. Show you 10-8.'
                    reply(syncUnit, clearText, false)
                end

                print(('[AI TEST SYNC] %s'):format(json.encode({action=action, unit=(player.PlayerData.metadata and player.PlayerData.metadata.callsign), callId=oldCall or callId, status='AVAILABLE', welfare='CANCELLED', spokenAck=syncUnit ~= nil, time=os.time()})))
                return true
            end
            return true
        end
    end
    return false, 'unit not tracked'
end

exports('PsDispatchSync', function(payload)
    if GetInvokingResource() ~= Config.DispatchResource then return false, 'unauthorized' end
    return applyPsDispatchSync(payload)
end)

reply = function(u, text, emergency)
    if not enabled or (mode == 'manual' and not (emergency and Config.EmergencyInManual)) then return end
    local spokenSign = radioSign(u)
    text = radioSpeechText(text)
    local msg = spokenSign .. ', ' .. text
    local ok = DispatchBridge.speak(u.channel, msg, u.agency, emergency)
    if Config.ResponseDebug ~= false then
        local state = units[u.source] or {}
        print(('[AI dispatch response] %s'):format(json.encode({
            unit = u.sign, radioCallsign = spokenSign, source = u.source, agency = u.agency, channel = u.channel,
            response = msg, speechQueued = ok == true, emergency = emergency == true,
            status = state.status, callId = state.callId, time = os.time()
        })))
    end
    -- Text delivery only to validated officers sharing this agency/channel.
    for src in pairs(QB.Functions.GetQBPlayers()) do
        local target = identity(src, src == u.source)
        if target and target.agency == u.agency and (Config.SharedLeoRadio == true or target.channel == u.channel) then
            TriggerClientEvent('haestorm-ai-dispatch:message', src, msg, ok)
        end
    end
end
local function broadcastSpeak(l, text, emergency, reason)
    if not enabled or (mode == 'manual' and not (emergency and Config.EmergencyInManual)) then return false end
    text = radioSpeechText(text)
    local started = GetGameTimer()
    local ok = DispatchBridge.speak(l.channel, text, l.agency, emergency)
    if Config.ResponseDebug ~= false then
        print(('[AI TEST SAYS] %s'):format(json.encode({
            target = 'ALL UNITS', agency = l.agency, channel = l.channel, response = text,
            emergency = emergency == true, speechQueued = ok == true, reason = reason,
            queueMs = GetGameTimer() - started, time = os.time()
        })))
    end
    return ok
end
local function audit(u, action, callId)
    if Config.Audit then print(('[AI dispatch] %s'):format(json.encode({ unit = u.sign, citizenid = u.cid, action = action, callId = callId, time = os.time() }))) end
end
local function suitable(u, call)
    if type(call.jobs) ~= 'table' then return false end
    for _, job in ipairs(call.jobs) do if job == u.player.PlayerData.job.name or job == u.player.PlayerData.job.type then return true end end
    return false
end
local function callsFor(u)
    local all = DispatchBridge.calls()
    if not all then return nil end
    local out = {}
    for _, c in pairs(all) do if suitable(u, c) and not c.closed and not c.resolved then out[#out + 1] = c end end
    return out
end
local function choose(u, r)
    local calls = callsFor(u)
    if not calls then return nil, 'dispatch connection unavailable.' end
    local matches = {}
    for _, c in ipairs(calls) do
        if r.callId and c.id == r.callId then return c end
        local description = ((c.message or '') .. ' ' .. (c.street or '')):lower()
        if not r.callId and r.selector and description:find(r.selector, 1, true) then matches[#matches + 1] = c end
    end
    if r.callId then return nil, 'that call is no longer available.' end
    if #matches == 1 then return matches[1] end
    if r.latest then
        local id = lane(u).latest
        for _, c in ipairs(calls) do if c.id == id then return c end end
        return nil, 'the last announced call is no longer available.'
    end
    if not r.selector and #calls == 1 then return calls[1] end
    return nil, #calls == 0 and 'no suitable active call.' or 'which call? Give the call number, type, or location.'
end
local function nextUnit(l)
    l.active = nil
    while #l.queue > 0 do
        local q = table.remove(l.queue, 1)
        local u = identity(q.source)
        if u and u.cid == q.cid and u.sign == q.sign and u.channel == l.channel and u.agency == l.agency and os.time() < q.expires then
            l.active = q.source
            units[q.source].untilTime = os.time() + Config.ConversationSeconds
            reply(u, variant('HAIL', 'go ahead.'))
            return
        end
    end
end
local function finish(u)
    local s = units[u.source]
    if s then s.voicePending = nil; s.pending = nil; s.selecting = nil; s.awaitDisposition = nil end
    nextUnit(lane(u))
end
local function state(u)
    local s = units[u.source]
    if s and (s.cid ~= u.cid or s.channel ~= u.channel or s.agency ~= u.agency or s.sign ~= u.sign) then
        local old = lanes[s.agency .. ':' .. s.channel]
        if old and old.active == u.source then nextUnit(old) end
        s = nil
    end
    if not s then s = { cid = u.cid, sign = u.sign, channel = u.channel, agency = u.agency, status = 'AVAILABLE', activity = os.time() }; units[u.source] = s end
    return s
end
local function setStatus(u, s, status)
    local ok, err = DispatchBridge.status(u.source, status)
    if not ok then reply(u, 'MDT status update failed. No status change confirmed.'); return false end
    s.status = status; s.activity = os.time(); s.welfare = nil
    -- v0.5.0: keep a structured AI/CAD unit board in ps-mdt. Failure here is
    -- non-fatal because the existing officer-status write remains authoritative.
    pcall(function()
        DispatchBridge.unitState(u.source, status, s.callId, {
            callsign = radioSign(u), agency = u.agency, updatedAt = os.time(), incidentMode = s.incidentMode,
        })
    end)
    audit(u, status, s.callId)
    return true
end
local function queryUnits(u, text)
    local t = tostring(text or ''):lower()
    local fire, ems, leo, availableLeo = 0, 0, 0, 0
    for src, player in pairs(QB.Functions.GetQBPlayers()) do
        local d = player.PlayerData or {}; local job = d.job or {}; local name = tostring(job.name or '')
        if job.onduty then
            if name == 'fire' then fire = fire + 1 end
            if name == 'ambulance' or name == 'ems' then ems = ems + 1 end
            local isLeo = name == 'police' or name == 'sheriff' or name == 'statepolice' or name == 'vpd' or name == 'bcso' or name == 'icso' or name == 'hsp' or name == 'hive'
            if isLeo then
                leo = leo + 1
                if tonumber(src) ~= tonumber(u.source) then
                    local us = units[src]
                    if not us or us.status == 'AVAILABLE' then availableLeo = availableLeo + 1 end
                end
            end
        end
    end
    if t:find('fire',1,true) then return fire > 0 and (fire .. ' fire unit' .. (fire == 1 and '' or 's') .. ' showing on duty.') or 'negative, no fire units showing on duty.' end
    if t:find('ems',1,true) or t:find('medic',1,true) or t:find('ambulance',1,true) then return ems > 0 and (ems .. ' EMS unit' .. (ems == 1 and '' or 's') .. ' showing on duty.') or 'negative, no EMS units showing on duty.' end
    if t:find('other unit',1,true) or t:find('available unit',1,true) or t:find('any units',1,true) or t:find('anybody',1,true) then
        return availableLeo > 0 and (availableLeo .. ' other unit' .. (availableLeo == 1 and '' or 's') .. ' available.') or 'negative, no other available units showing.'
    end
    return nil
end
local function emergencyParticipant(u, s, l)
    -- The unit that declared the emergency always has the air. Units already
    -- attached/responding to the same incident may also pass priority traffic.
    if l.emergency[u.cid] then return true end
    if not s then return false end
    if s.status == 'EMERGENCY' then return true end
    if s.callId then
        for cid, hold in pairs(l.emergency) do
            local owner = units[hold.source]
            if owner and owner.cid == cid and owner.callId and owner.callId == s.callId then
                return s.status == 'RESPONDING' or s.status == 'ON_SCENE'
            end
        end
    end
    return false
end
local function routineDuringEmergency(r)
    -- Records checks and ordinary availability/admin traffic wait until the air
    -- is released. Priority incident traffic is never blocked by this list.
    return r.intent == 'PLATE' or r.intent == 'PLATE_REQUEST' or r.intent == 'QUERY'
        or r.intent == 'AVAILABLE' or r.intent == 'BUSY' or r.intent == 'UNAVAILABLE'
        or r.intent == 'ON_DUTY' or r.intent == 'OFF_DUTY' or r.intent == 'TRAFFIC_STOP'
end
local function syncCallNote(u, s, text)
    if not s or not s.callId or type(text) ~= 'string' or text == '' then return end
    local ok, err = DispatchBridge.note(u.source, s.callId, text)
    if Config.UnderstandingDebug then
        print(('[AI TEST MDT] %s'):format(json.encode({stage='call_note', unit=u.sign, callId=s.callId, ok=ok == true, note=text, error=(not ok and tostring(err) or nil), time=os.time()})))
    end
end
local function cadEvent(u, s, eventType, payload)
    if not s or not s.callId then return false end
    payload = type(payload) == 'table' and payload or {}
    payload.callsign = payload.callsign or radioSign(u)
    payload.status = payload.status or s.status
    payload.incidentMode = payload.incidentMode or s.incidentMode
    local ok = DispatchBridge.cadEvent(u.source, s.callId, eventType, payload)
    return ok == true
end
local function syncTrafficStopCad(u, s, eventType, note)
    if not s or not s.callId then return end
    s.stop = s.stop or { opened=os.time() }
    local payload = {
        note = note,
        vehicle = s.stop.vehicleSummary,
        occupants = s.stop.occupied,
        noAdditional = s.stop.noAdditional == true,
        noPlate = s.stop.noPlate == true,
        plate = s.stop.plate,
        disposition = s.stop.disposition,
        location = s.stop.location and s.stop.location.street or nil,
        incidentMode = 'TRAFFIC_STOP',
    }
    DispatchBridge.action(u.source, 'incident_update', s.callId, {
        incidentMode='TRAFFIC_STOP', priority=3, information=note or 'Traffic stop update',
        street=payload.location, cad=payload,
    })
    cadEvent(u, s, eventType or 'TRAFFIC_STOP_UPDATE', payload)
end
local function isPursuitTraffic(text)
    local t = tostring(text or ''):lower()
    return t:find('pursuit',1,true) or t:find('taking off',1,true) or t:find('fleeing',1,true)
        or t:find('we are moving',1,true) or t:find("we're moving",1,true)
end
local function isFootPursuitTraffic(text)
    local t = tostring(text or ''):lower()
    return t:find('foot pursuit',1,true) or t:find('foot bail',1,true) or t:find('bailed',1,true)
        or t:find('bailing',1,true) or t:find('one running',1,true) or t:find('suspect running',1,true)
        or t:find("he's running",1,true) or t:find('hes running',1,true)
        or t:find("she's running",1,true) or t:find('shes running',1,true)
        or t:find("subject's running",1,true) or t:find('subjects running',1,true)
        or t:find('running northbound',1,true) or t:find('running southbound',1,true)
        or t:find('running eastbound',1,true) or t:find('running westbound',1,true)
        or t:find('took off on foot',1,true) or t:find('taking off on foot',1,true)
        or t:find('running from me',1,true)
end
local function incidentPayload(u, s, text, mode, priority)
    local ped = GetPlayerPed(u.source)
    local coords = GetEntityCoords(ped)
    return {
        information = tostring(text or ''):sub(1,220),
        incidentMode = mode,
        priority = priority,
        coords = {x=coords.x,y=coords.y,z=coords.z},
        street = s.stop and s.stop.location and s.stop.location.street or nil,
    }
end
local function updateIncidentMemory(s, text, mode)
    s.incident = s.incident or {}
    local m = s.incident
    local t = DispatcherIntent.normalize(tostring(text or ''))
    m.mode = mode or m.mode
    local dirs = { 'northbound','southbound','eastbound','westbound','northeast','northwest','southeast','southwest','north','south','east','west' }
    for _, d in ipairs(dirs) do if (' '..t..' '):find(' '..d..' ',1,true) then m.direction=d; break end end
    local postal = t:match('postal%s+(%d+)') or t:match('mile marker%s+(%d+)') or t:match('marker%s+(%d+)') or t:match('route%s+(%d+)')
    if postal then m.marker=postal end
    local speed = t:match('speed%s+(%d+)') or t:match('(%d+)%s*mph') or t:match('speeds?%s+about%s+(%d+)') or t:match('speeds?%s+(%d+)')
    if speed then m.speed=speed end
    if t:find('heavy traffic',1,true) then m.traffic='heavy traffic'
    elseif t:find('moderate traffic',1,true) then m.traffic='moderate traffic'
    elseif t:find('light traffic',1,true) then m.traffic='light traffic' end
    if t:find('lost visual',1,true) or t:find('lost eyes',1,true) or t:find('lost sight',1,true) then m.visual='lost visual'
    elseif t:find('visual',1,true) then m.visual='visual' end
    if t:find('crashed',1,true) or t:find('crash',1,true) or t:find('wrecked',1,true) then m.event='vehicle crashed' end
    if t:find('foot bail',1,true) or t:find('bailing',1,true) or t:find('bailed',1,true) or t:find('running',1,true) then m.event='foot bail' end
    m.last = tostring(text or ''):sub(1,140)
end
local function incidentSummary(s, text)
    local m = s.incident or {}
    local parts = {}
    if m.mode == 'TRAFFIC_STOP' then parts[#parts+1]='Traffic stop'
    elseif m.mode == 'SUBJECT_STOP' then parts[#parts+1]='Subject stop'
    elseif m.mode == 'VEHICLE_PURSUIT' then parts[#parts+1]='Vehicle pursuit'
    elseif m.mode == 'FOOT_PURSUIT' then parts[#parts+1]='Foot pursuit'
    elseif m.mode == 'SHOTS_FIRED' then parts[#parts+1]='Shots fired'
    elseif m.mode == 'OFFICER_DOWN' then parts[#parts+1]='Officer down'
    else parts[#parts+1]='Priority incident' end
    if m.direction then parts[#parts+1]=m.direction end
    if m.marker then parts[#parts+1]='marker '..m.marker end
    if m.speed then parts[#parts+1]=m.speed..' MPH' end
    if m.traffic then parts[#parts+1]=m.traffic end
    if m.event then parts[#parts+1]=m.event end
    if m.visual then parts[#parts+1]=m.visual end
    local summary = table.concat(parts, ' | ')
    local raw = tostring(text or ''):sub(1,120)
    if raw ~= '' and not summary:lower():find(raw:lower(),1,true) then summary = summary .. ' | Last: ' .. raw end
    return summary:sub(1,220)
end

local function updateLiveIncident(u, s, text, mode, priority)
    updateIncidentMemory(s, text, mode)
    local payload = incidentPayload(u, s, incidentSummary(s, text), mode, priority)
    if s.callId then
        local ok = DispatchBridge.action(u.source, 'incident_update', s.callId, payload)
        if ok then syncCallNote(u, s, tostring(text or ''):sub(1,220)) end
        return ok
    end
    local ok, result = DispatchBridge.action(u.source, 'incident_open', nil, payload)
    if ok and type(result)=='table' and tonumber(result.callId) then
        s.callId = tonumber(result.callId)
        seenCalls[s.callId] = true
        s.dispatchAttachGraceUntil = os.time() + 12
        syncCallNote(u, s, tostring(text or ''):sub(1,220))
        return true
    end
    return false
end
local function emergencyUpdateReply(u, text, modeChanged)
    local t = tostring(text or ''):lower()
    local hasDirection = t:find('north',1,true) or t:find('south',1,true) or t:find('east',1,true) or t:find('west',1,true)
    local officerDown = t:find('officer down',1,true) or t:find('unit down',1,true)
    local armed = t:find('has a gun',1,true) or t:find('with a gun',1,true) or t:find('armed subject',1,true)
        or t:find('subject armed',1,true) or t:find('weapon displayed',1,true) or t:find('brandished',1,true)

    if officerDown then
        reply(u, 'officer down. Emergency traffic only. All available units respond. Advise exact location and officer status.', true)
    elseif t:find('shots fired', 1, true) or t:find('shots being fired', 1, true) then
        reply(u, 'shots fired. Emergency traffic only. All available units start that way. Advise your status.', true)
    elseif isFootPursuitTraffic(t) then
        local direction = t:match('(northbound)') or t:match('(southbound)') or t:match('(eastbound)') or t:match('(westbound)')
            or t:match('(northeast)') or t:match('(northwest)') or t:match('(southeast)') or t:match('(southwest)')
        if direction then
            reply(u, 'copy, foot pursuit ' .. direction .. '. Units start that way. Keep updates coming.', true)
        elseif modeChanged then
            reply(u, 'copy, foot pursuit. Give direction of travel.', true)
        else
            reply(u, variant('COPY', 'copy.'), true)
        end
    elseif isPursuitTraffic(t) then
        if modeChanged and not hasDirection then reply(u, 'copy, pursuit. Give direction and vehicle description.', true)
        else reply(u, modeChanged and 'copy, pursuit.' or variant('COPY', 'copy.'), true) end
    elseif armed then
        reply(u, 'copy, armed subject. Use caution. Keep updates coming.', true)
    elseif t:find('crash',1,true) or t:find('wreck',1,true) then
        reply(u, 'copy, vehicle crashed. Advise injuries and if anyone is running.', true)
    elseif t:find('lost visual',1,true) or t:find('lost eyes',1,true) or t:find('lost sight',1,true) then
        reply(u, 'copy, lost visual. Last known direction?', true)
    elseif t:find('north',1,true) or t:find('south',1,true) or t:find('east',1,true) or t:find('west',1,true) or t:find('postal',1,true) or t:find('route',1,true) or t:find('marker',1,true) then
        reply(u, variant('COPY', 'copy.'), true)
    elseif t:find('one detained', 1, true) or t:find('in custody', 1, true) then
        reply(u, 'copy, one detained. Continue when ready.', true)
    elseif t:find('ems', 1, true) or t:find('medic', 1, true) or t:find('ambulance', 1, true) then
        reply(u, 'copy, medical requested.', true)
    else
        reply(u, variant('COPY', 'copy.'), true)
    end
end

-- v0.5.0.8 immersive incident helpers.
local function isArmedTraffic(text)
    local t = DispatcherIntent.normalize(tostring(text or ''))
    return t:find('has a gun',1,true) or t:find('with a gun',1,true)
        or t:find('armed subject',1,true) or t:find('subject armed',1,true)
        or t:find('weapon displayed',1,true) or t:find('brandished',1,true)
        or t:find('firearm',1,true)
end

local function isOfficerDownTraffic(text)
    local t = DispatcherIntent.normalize(tostring(text or ''))
    return t:find('officer down',1,true) or t:find('unit down',1,true)
end

local function subjectStopDetail(text)
    local t = DispatcherIntent.normalize(tostring(text or ''))
    local personWord = t:find('male',1,true) or t:find('female',1,true) or t:find('subject',1,true)
        or t:find('individual',1,true) or t:find('person',1,true) or t:find('suspect',1,true)
    local detailWord = t:find('wearing',1,true) or t:find('hoodie',1,true) or t:find('shirt',1,true)
        or t:find('pants',1,true) or t:find('jeans',1,true) or t:find('shorts',1,true)
        or t:find('jacket',1,true) or t:find('hat',1,true) or t:find('shoes',1,true)
        or t:find('tall',1,true) or t:find('short',1,true) or t:find('heavy',1,true)
    local vehicleWord = t:find('vehicle',1,true) or t:find('car ',1,true) or t:find('truck',1,true)
        or t:find('plate',1,true) or t:find('driver',1,true) or t:find('occupant',1,true)
    if personWord and detailWord and not vehicleWord then return true end
    if isArmedTraffic(t) then return true end
    return false
end

-- v0.5.0.8 realistic dispatcher hails:
-- Rotate concise radio responses and use the unit's current context when it is
-- already committed to a stop/call. This keeps the dispatcher natural without
-- becoming chatty or inventing details.
local function realisticHail(s)
    local key, list
    if s and s.stop then
        key = 'HAIL_TRAFFIC'
        list = { 'go ahead with your traffic.', 'go ahead, what do you have?', 'send your traffic.' }
    elseif s and (s.callId or s.status == 'RESPONDING' or s.status == 'ON_SCENE' or s.incidentMode) then
        key = 'HAIL_UPDATE'
        list = { 'go ahead with your update.', 'go ahead.', 'send it.' }
    else
        key = 'HAIL_GENERAL'
        list = { 'go ahead.', 'send it.', 'go for dispatch.', "I'm listening." }
    end
    replyCursor[key] = (replyCursor[key] or 0) % #list + 1
    return list[replyCursor[key]]
end

local function process(u, r)
    local s, l = state(u), lane(u)
    s.untilTime = os.time() + Config.ConversationSeconds
    -- Control traffic must execute before the emergency hold gate or the unit that
    -- created the emergency can never clear it.
    if r.intent == 'RESUME_AIR_AVAILABLE' then
        local hadEmergency = l.emergency[u.cid] ~= nil or s.status == 'EMERGENCY'
        local oldCallId = s.callId
        l.emergency[u.cid] = nil; saveEmergencyHolds(); s.pending=nil; s.voicePending=nil; s.waitingPlate=nil; s.welfare=nil
        if oldCallId then
            local ok = DispatchBridge.action(u.source, 'detach', oldCallId, { disposition = 'emergency traffic clear; unit back 10-8' })
            if ok then audit(u, 'DETACH', oldCallId); s.callId=nil; s.stop=nil; s.awaitDisposition=nil; s.incident=nil; s.incidentMode=nil; s.lastPursuitUpdate=nil end
        end
        setStatus(u, s, 'AVAILABLE')
        audit(u, 'END_EMERGENCY', oldCallId)
        audit(u, 'AVAILABLE', oldCallId)
        if not next(l.emergency) then
            if hadEmergency then reply(u, '10-4. Emergency traffic clear. Show you 10-8.', true)
            else reply(u, '10-4. The air is clear. Show you 10-8.', false) end
        else
            reply(u, '10-4. Your emergency traffic is clear. Show you 10-8. Hold the air for the remaining emergency traffic.', true)
        end
        finish(u); return
    end
    if r.intent == 'END_EMERGENCY' or r.intent == 'RESUME_AIR' then
        local hadEmergency = l.emergency[u.cid] ~= nil or s.status == 'EMERGENCY'
        l.emergency[u.cid] = nil; saveEmergencyHolds(); s.pending=nil; s.voicePending=nil; s.waitingPlate=nil; s.welfare=nil
        s.incidentMode=nil; s.incident=nil; s.lastPursuitUpdate=nil; s.lastPursuitPrompt=nil
        if s.status == 'EMERGENCY' then setStatus(u, s, s.callId and 'ON_SCENE' or 'AVAILABLE') end
        audit(u, 'END_EMERGENCY', s.callId)
        if not next(l.emergency) then
            if hadEmergency then reply(u, '10-4. Emergency traffic clear. All units, resume normal traffic.', true)
            else reply(u, '10-4. The air is already clear.', false) end
        else reply(u, '10-4. Your emergency traffic is clear. Hold the air for the remaining emergency traffic.', true) end
        finish(u); return
    end
    if r.intent == 'HOLD_AIR' then reply(u, '10-4. All units, hold routine traffic.', true); return end
    if r.intent == 'RADIO_CHECK' then reply(u, 'loud and clear.'); finish(u); return end
    if r.intent == 'CANCEL_BACKUP' then s.pending=nil; s.voicePending=nil; reply(u, '10-4. Disregard the additional unit.'); finish(u); return end
    if r.intent == 'CANCEL_LAST_TRAFFIC' then
        s.pending=nil; s.voicePending=nil; s.waitingPlate=nil; s.selecting=nil; s.awaitDisposition=nil
        reply(u, '10-4, disregard your last traffic.'); finish(u); return
    end
    if r.intent == 'CANCEL_CALL' then
        if s.callId then
            local callId = s.callId
            local ok = DispatchBridge.action(u.source, 'detach', callId, { disposition = 'disregard' })
            if ok then s.callId=nil; s.stop=nil; s.awaitDisposition=nil; setStatus(u, s, 'AVAILABLE'); audit(u, 'CANCEL_CALL', callId); reply(u, '10-4, call ' .. callId .. ' disregarded. You are back available.')
            else reply(u, 'unable to clear that call. Use the dispatch menu.') end
        else reply(u, '10-4. You are not attached to an active call.') end
        finish(u); return
    end
    if r.intent == 'CANCEL' then s.pending = nil; s.voicePending = nil; s.waitingPlate = nil; reply(u, '10-4, disregard.'); finish(u); return end
    if r.intent == 'CORRECTION' then s.pending = nil; s.selecting = true; reply(u, 'give the corrected call number or plate.'); return end
    if r.intent == 'CONFIRM' then
        local pending = s.pending; s.pending = nil
        if not pending or pending.expires < os.time() then reply(u, 'no current request to confirm.'); return end
        r = pending.request; r.confirmed = true
    end
    if r.intent == 'EMERGENCY' then
        -- v0.4.11: do not create another ps-dispatch incident when this unit
        -- already has an active emergency. Treat repeated panic/emergency
        -- traffic as an update to the existing incident.
        if l.emergency[u.cid] and s.callId then
            s.status = 'EMERGENCY'; s.activity = os.time(); s.welfare = nil
            syncCallNote(u, s, r.text or 'emergency update')
            reply(u, '10-4. Emergency traffic remains active on call ' .. tostring(s.callId) .. '.', true)
            return
        end
        l.emergency[u.cid] = { sign = u.sign, source = u.source }
        saveEmergencyHolds()
        -- Interrupt the routine conversation; preserve it at the head of the queue.
        if l.active and l.active ~= u.source and units[l.active] then
            local prior = units[l.active]
            table.insert(l.queue, 1, { source = l.active, cid = prior.cid, sign = prior.sign, channel = prior.channel, priority = 1, requested = os.time(), conversation = 'interrupted', expires = os.time() + Config.QueueSeconds })
        end
        l.active = u.source; s.status = 'EMERGENCY'; s.pending = nil
        local ped = GetPlayerPed(u.source)
        local coords = GetEntityCoords(ped)
        s.activity = os.time(); s.welfare = nil
        local ok, result = DispatchBridge.action(u.source, 'emergency', s.callId, { coords = { x = coords.x, y = coords.y, z = coords.z } })
        if ok then s.callId = result.callId or s.callId; audit(u, 'EMERGENCY', s.callId) end
        reply(u, ok and '10-4. All units hold the air, emergency traffic. Units in the area start that way.' or '10-4. All units hold the air, emergency traffic. Units in the area respond to this unit GPS.', true)
        for target in pairs(QB.Functions.GetQBPlayers()) do
            local other = identity(target)
            if other and other.agency == u.agency and (Config.SharedLeoRadio == true or other.channel == u.channel) then TriggerClientEvent('haestorm-ai-dispatch:emergencyLocation', target, coords) end
        end
        DispatchBridge.status(u.source, 'EMERGENCY')
        return
    end
    if r.intent == 'EMERGENCY_UPDATE' then
        local rt = tostring(r.text or ''):lower()
        if rt:find('send additional',1,true) or rt:find('send me additional',1,true) or rt:find('send me an officer',1,true) or rt:find('need another unit',1,true) or rt:find('start another unit',1,true) or rt:find('need units',1,true) then
            if s.callId then DispatchBridge.action(u.source, 'backup', s.callId, { reason='pursuit assistance' }) end
            reply(u, 'copy, starting another unit.', true)
            s.activity=os.time(); s.lastPursuitUpdate=os.time(); s.welfare=nil; s.welfareStage=nil
            finish(u); return
        end
        local now = os.time()
        local previousMode = s.incidentMode
        local mode = previousMode
        if isOfficerDownTraffic(r.text) then mode = 'OFFICER_DOWN'
        elseif isFootPursuitTraffic(r.text) then mode = 'FOOT_PURSUIT'
        elseif isPursuitTraffic(r.text) then mode = 'VEHICLE_PURSUIT'
        elseif tostring(r.text or ''):lower():find('shots fired',1,true) then mode = 'SHOTS_FIRED'
        elseif isArmedTraffic(r.text) then mode = 'PRIORITY_INCIDENT'
        elseif not mode then mode = 'PRIORITY_INCIDENT' end

        if not l.emergency[u.cid] then
            l.emergency[u.cid] = { sign = u.sign, source = u.source }
            saveEmergencyHolds()
            l.active = u.source
        end
        s.status = 'EMERGENCY'; s.pending = nil; s.activity = now; s.welfare = nil; s.welfareStage = nil
        s.incidentMode = mode
        if mode == 'VEHICLE_PURSUIT' or mode == 'FOOT_PURSUIT' then s.lastPursuitUpdate = now end

        -- Keep the officer on the SAME CAD incident whenever possible. A traffic
        -- stop that turns into a pursuit is upgraded instead of creating a new panic call.
        local updated = updateLiveIncident(u, s, r.text, mode, (mode == 'SHOTS_FIRED' or mode == 'OFFICER_DOWN') and 0 or 1)
        if not updated and not s.callId then
            -- Last-resort emergency lifecycle if ps-dispatch could not open/update a call.
            local ped = GetPlayerPed(u.source)
            local coords = GetEntityCoords(ped)
            local ok, result = DispatchBridge.action(u.source, 'emergency', nil, { coords = { x=coords.x,y=coords.y,z=coords.z } })
            if ok then s.callId = result.callId or s.callId; if s.callId then seenCalls[s.callId]=true end end
        end
        DispatchBridge.status(u.source, 'EMERGENCY')
        audit(u, 'EMERGENCY_UPDATE', s.callId)
        emergencyUpdateReply(u, r.text, previousMode ~= mode)
        return
    end
    if r.intent == 'SUBJECT_STOP' then
        s.activity = os.time(); s.welfare = nil; s.welfareStage = nil
        s.pending = nil; s.voicePending = nil; s.waitingPlate = nil
        s.stop = nil; s.priorityBackupStarted = nil
        s.incidentMode = 'SUBJECT_STOP'
        s.incident = s.incident or {}
        s.incident.subject = r.subject
        s.incident.locationText = r.location

        local note = 'Out with ' .. tostring(r.subject or 'an individual')
        if r.location and r.location ~= '' then note = note .. ' at ' .. tostring(r.location) end

        local opened = updateLiveIncident(u, s, note, 'SUBJECT_STOP', 3)
        if opened and s.callId then
            cadEvent(u, s, 'SUBJECT_STOP_OPEN', {
                subject = r.subject,
                location = r.location,
                note = note,
                incidentMode = 'SUBJECT_STOP'
            })
            pcall(function()
                DispatchBridge.unitState(u.source, 'ON_SCENE', s.callId, {
                    callsign = radioSign(u),
                    incidentMode = 'SUBJECT_STOP',
                    subject = r.subject,
                    location = r.location
                })
            end)
        else
            syncCallNote(u, s, note)
        end

        setStatus(u, s, 'ON_SCENE')
        audit(u, 'SUBJECT_STOP', s.callId)
        if r.location and r.location ~= '' then
            reply(u, '10-4. Show you out with ' .. tostring(r.subject or 'an individual') .. ' at ' .. tostring(r.location) .. '.')
        else
            reply(u, '10-4. Show you out with ' .. tostring(r.subject or 'an individual') .. '.')
        end
        finish(u); return
    end
    if r.intent == 'INCIDENT_UPDATE' then
        s.activity = os.time(); s.welfare = nil; s.welfareStage = nil
        local armed = isArmedTraffic(r.text)
        if armed then
            s.incidentMode = 'PRIORITY_INCIDENT'
            local updated = s.callId and updateLiveIncident(u, s, r.text, 'PRIORITY_INCIDENT', 1) or false
            if not updated then syncCallNote(u, s, r.text) end

            -- Start one additional unit on an armed-subject incident. First add
            -- backup to the current CAD incident. If that bridge path rejects the
            -- request, fall back to a standalone 10-32 assist and an all-units
            -- broadcast instead of silently dropping the request.
            if not s.priorityBackupStarted then
                local backupOk, backupResult = DispatchBridge.action(u.source, 'backup', s.callId, { reason='armed subject', status=s.status })
                if not backupOk then
                    backupOk, backupResult = DispatchBridge.action(u.source, 'backup', nil, { reason='armed subject', status=s.status })
                end
                if backupOk then
                    s.priorityBackupStarted = true
                    local assistCallId = type(backupResult) == 'table' and tonumber(backupResult.callId) or nil
                    if assistCallId then seenCalls[assistCallId] = true end
                    local announcement = radioSign(u) .. ' has an armed subject'
                    if s.incident and s.incident.locationText then announcement = announcement .. ' at ' .. tostring(s.incident.locationText) end
                    announcement = announcement .. '. Any available unit start that way and advise if responding.'
                    broadcastSpeak({ agency=u.agency, channel=Config.PrimaryDispatchFrequency }, announcement, true, 'armed_subject_backup')
                else
                    local announcement = radioSign(u) .. ' requesting an additional for an armed subject. Any available unit start that way and advise if responding.'
                    broadcastSpeak({ agency=u.agency, channel=Config.PrimaryDispatchFrequency }, announcement, true, 'armed_subject_backup_radio_fallback')
                end
                if Config.UnderstandingDebug then
                    print(('[AI TEST BACKUP] %s'):format(json.encode({unit=u.sign, reason='armed subject', ok=backupOk == true, currentCall=s.callId, result=backupResult, time=os.time()})))
                end
            end
            reply(u, s.priorityBackupStarted and 'copy, armed subject. Use caution. Additional unit started.' or 'copy, armed subject. Use caution. Additional requested over the air.', true)
        elseif s.incidentMode == 'SUBJECT_STOP' then
            if s.callId then updateLiveIncident(u, s, r.text, 'SUBJECT_STOP', 3) else syncCallNote(u, s, r.text) end
            reply(u, variant('COPY', 'copy the description.'))
        else
            if s.callId then updateLiveIncident(u, s, r.text, s.incidentMode or s.status, nil) else syncCallNote(u, s, r.text) end
            reply(u, variant('COPY', 'copy.'))
        end
        finish(u); return
    end
    if r.intent == 'NO_PLATE' then
        s.waitingPlate = nil; s.activity = os.time(); s.welfare = nil; s.welfareStage = nil
        s.stop = s.stop or { opened=os.time() }; s.stop.noPlate = true
        if s.callId then syncTrafficStopCad(u, s, 'NO_PLATE', 'No plate displayed') end
        reply(u, '10-4, no plate displayed.')
        return
    end
    if r.intent == 'ACK' then
        s.activity = os.time(); s.welfare = nil; s.welfareStage = nil
        -- Real dispatch does not answer every officer acknowledgement.
        finish(u); return
    end
    if r.intent == 'HAIL' then reply(u, realisticHail(s)); return end
    if r.text == 'status okay' or r.text == 'all okay' or r.text == 'code 4' then s.activity = os.time(); s.welfare = nil; reply(u, variant('COPY', 'copy.')); finish(u); return end
    if r.intent == 'QUERY' then
        local unitAnswer = queryUnits(u, r.text)
        if unitAnswer then reply(u, unitAnswer); finish(u); return end
        local calls = callsFor(u) or {}
        local items = {}
        for _, c in ipairs(calls) do for _, unit in ipairs(c.units or {}) do items[#items + 1] = tostring(unit.callsign or 'unknown') .. ' on call ' .. c.id end end
        reply(u, #items > 0 and table.concat(items, '; ') or 'no responding units listed.'); finish(u); return
    end
    if r.intent == 'PLATE_REQUEST' then
        s.waitingPlate = os.time() + Config.ConversationSeconds
        reply(u, 'go ahead with the plate.'); return
    end
    if r.intent == 'TRAFFIC_STOP_UPDATE' then
        s.stop = s.stop or { opened = os.time() }
        s.stop.lastUpdate = os.time()
        s.stop.vehicleSummary = r.summary or s.stop.vehicleSummary
        if r.noAdditional ~= nil then s.stop.noAdditional = r.noAdditional == true end
        if r.occupied then s.stop.occupied = r.occupied end
        s.activity = os.time(); s.welfare = nil
        -- On a stop, do not make the officer repeat an entire description just
        -- because one word was clipped. Once dispatch has useful vehicle context,
        -- acknowledge what was understood and move naturally to the plate.
        s.waitingPlate = os.time() + Config.ConversationSeconds
        syncTrafficStopCad(u, s, 'VEHICLE_OCCUPANTS', tostring(r.summary or 'vehicle received'))
        if r.partial then
            reply(u, 'copy. Plate when ready.')
        else
            reply(u, 'copy. Plate when ready.')
        end
        return
    end
    if r.intent == 'NEGATED' then reply(u, variant('NEGATED', '10-4, disregard.')); finish(u); return end
    if s.selecting and r.intent == 'UNKNOWN' then
        r = { intent = 'RESPONDING', callId = tonumber(r.text:match('(%d+)')), selector = r.text, confidence = 1 }
    end
    if r.intent == 'RESPONDING' then
        local c, err = choose(u, r)
        if not c then s.selecting = true; reply(u, err); return end
        if s.callId and s.callId ~= c.id and not r.confirmed then
            s.pending = { request = { intent = 'RESPONDING', callId = c.id }, expires = os.time() + Config.ConversationSeconds }
            reply(u, 'confirm switching to call ' .. c.id .. '.'); return
        end
        local ok = DispatchBridge.action(u.source, 'attach', c.id)
        if not ok then reply(u, 'attachment failed. Repeat or use the dispatch menu.'); return end
        s.callId = c.id; s.selecting = nil; audit(u, 'ATTACH', c.id)
        syncCallNote(u, s, u.sign .. ' responding')
        if setStatus(u, s, 'RESPONDING') then reply(u, 'copy, responding to call ' .. tostring(c.id) .. '.')
        else reply(u, 'attached to call ' .. c.id .. '; MDT status remains unconfirmed.') end
        finish(u); return
    end
    if r.intent == 'CLEAR' then
        local disposition = r.disposition or 'unit clear'
        if s.callId then
            local oldCall = s.callId
            if r.disposition then
                s.stop = s.stop or {}; s.stop.disposition = r.disposition
                syncCallNote(u, s, 'Disposition: ' .. tostring(r.disposition))
                cadEvent(u, s, 'DISPOSITION', { disposition=r.disposition, note='Disposition: '..tostring(r.disposition) })
            end
            cadEvent(u, s, 'CALL_CLEARED', { disposition=disposition, note='Unit clear: '..tostring(disposition) })
            local ok = DispatchBridge.action(u.source, 'clear', oldCall, { disposition = disposition })
            if not ok then reply(u, 'clearing failed. Still attached.'); return end
            audit(u, 'CLEAR', oldCall); s.callId = nil
        end
        s.stop = nil; s.awaitDisposition = nil; s.pending=nil; s.waitingPlate=nil; s.incidentMode=nil; s.incident=nil; s.lastPursuitUpdate=nil; s.priorityBackupStarted=nil; s.welfare=nil
        if setStatus(u, s, 'AVAILABLE') then
            -- Keep the radio acknowledgement clipped; the disposition is stored in CAD/MDT.
            reply(u, 'copy. Clear, 10-8.')
        end
        finish(u); return
    end
    if r.intent == 'PLATE' then
        s.waitingPlate = nil; s.pending = nil
        if Config.UnderstandingDebug then
            print(('[AI TEST PLATE] %s'):format(json.encode({stage='lookup_start', unit=u.sign, radioCallsign=radioSign(u), plate=r.plate, time=os.time()})))
        end
        -- Real dispatch cadence: acknowledge the plate first, then give the return.
        -- This makes an actual lookup delay sound intentional instead of like the
        -- dispatcher stopped responding.
        reply(u, 'copy ' .. r.plate .. '. Stand by.')
        s.stop = s.stop or { opened=os.time() }; s.stop.plate = r.plate
        if s.callId then syncTrafficStopCad(u, s, 'PLATE', 'Plate ' .. tostring(r.plate)) end
        local ok, result = DispatchBridge.lookup(u.source, 'plate', r.plate)
        if Config.UnderstandingDebug then
            print(('[AI TEST PLATE] %s'):format(json.encode({stage='lookup_result', unit=u.sign, plate=r.plate, ok=ok == true, hasRadioSummary=type(result)=='table' and type(result.radioSummary)=='string', error=(not ok and tostring(result) or nil), time=os.time()})))
        end
        if ok and type(result) == 'table' and type(result.radioSummary) == 'string' then
            local plateReturn = cleanPlateReturn(result) or result.radioSummary
            if s.callId then cadEvent(u, s, 'PLATE_RETURN', { plate=r.plate, vehicle=result.vehicleLabel or result.vehicle, owner=result.ownerName, note=plateReturn }) end
            reply(u, plateReturn:sub(1, 220)); audit(u, 'PLATE_CHECK')
        else reply(u, 'no return on ' .. r.plate .. '. Verify the plate when ready.') end
        finish(u); return
    end
    if r.intent == 'BACKUP' then
        s.activity = os.time(); s.welfare=nil; s.welfareStage=nil
        if s.incidentMode == 'VEHICLE_PURSUIT' or s.incidentMode == 'FOOT_PURSUIT' then s.lastPursuitUpdate = os.time() end
        -- v0.4.22: a 32 is an operational request, not just a spoken acknowledgement.
        -- If the unit is already on a CAD call, flag that call for backup. If the
        -- unit is on a standalone traffic stop, ps-dispatch creates a real 10-32
        -- assist call at the officer's server-owned GPS and attaches the requester.
        local ok, result = DispatchBridge.action(u.source, 'backup', s.callId, {
            street = s.stop and s.stop.location and s.stop.location.street or nil,
            status = s.status,
        })
        if not ok and s.callId then
            -- Some incident types cannot be mutated by the backup action. Fall
            -- back to a standalone assist call rather than forcing the officer
            -- to repeat the same request.
            ok, result = DispatchBridge.action(u.source, 'backup', nil, {
                street = s.stop and s.stop.location and s.stop.location.street or nil,
                status = s.status,
                reason = 'additional unit requested',
            })
        end
        if ok then
            local backupCallId = s.callId or (type(result) == 'table' and tonumber(result.callId) or nil)
            if backupCallId then
                s.callId = backupCallId
                seenCalls[backupCallId] = true -- we announce it ourselves below; avoid duplicate poll announcement
            end
            audit(u, 'BACKUP', backupCallId)
            reply(u, variant('BACKUP', '10-4, starting a 32.'))

            local where = s.stop and s.stop.location and tostring(s.stop.location.street or '') or ''
            local announcement = radioSign(u) .. ' requesting a 32'
            if where ~= '' then announcement = announcement .. ' at ' .. where end
            if backupCallId then announcement = announcement .. ', call ' .. tostring(backupCallId) end
            announcement = announcement .. '. Any available unit start that way, advise if responding.'
            broadcastSpeak({ agency = u.agency, channel = Config.PrimaryDispatchFrequency }, announcement, false, 'backup_request')
        else
            reply(u, '10-9. Unable to start the additional. Repeat the request.')
        end
        finish(u); return
    end
    if r.intent == 'ON_DUTY' or r.intent == 'OFF_DUTY' then
        if r.intent == 'OFF_DUTY' and s.callId then local oldCall=s.callId; if DispatchBridge.action(u.source,'detach',oldCall,{disposition='unit off duty'}) then s.callId=nil; s.stop=nil; s.incidentMode=nil; audit(u,'DETACH',oldCall) end end
        u.player.Functions.SetJobDuty(r.intent == 'ON_DUTY')
        if u.player.PlayerData.job.onduty ~= (r.intent == 'ON_DUTY') then reply(u, 'duty update failed.'); return end
        s.status = r.intent; s.activity = os.time(); audit(u, r.intent); reply(u, 'copy. ' .. r.intent:lower():gsub('_', ' ') .. '.'); finish(u); return
    end
    -- v0.4.15: returning 10-8 is a valid routine traffic-stop clearance when
    -- the stop is not attached to a separate CAD call. Do not trap the unit in
    -- TRAFFIC_STOP just because no canned disposition was spoken.
    if r.intent == 'AVAILABLE' and s.stop and not s.callId then
        s.stop = nil; s.awaitDisposition = nil; s.pending = nil; s.waitingPlate = nil; s.welfare = nil
        if setStatus(u, s, 'AVAILABLE') then reply(u, 'copy, clear, 10-8.') end
        finish(u); return
    end
    if Config.MdtStatuses[r.intent] then
        if r.intent == 'AVAILABLE' and s.callId then
            local oldCall = s.callId
            cadEvent(u, s, 'CALL_CLEARED', { disposition='unit back 10-8', note='Unit clear, 10-8' })
            local ok = DispatchBridge.action(u.source, 'clear', oldCall, { disposition = 'unit back 10-8' })
            if not ok then reply(u, 'unable to clear that call.'); return end
            audit(u, 'DETACH', oldCall); s.callId=nil; s.stop=nil; s.awaitDisposition=nil; s.pending=nil; s.waitingPlate=nil; s.incidentMode=nil; s.incident=nil; s.lastPursuitUpdate=nil; s.priorityBackupStarted=nil
        end
        if r.intent == 'ON_SCENE' and not s.callId then reply(u, 'which call are you on scene at?'); return end
        if setStatus(u, s, r.intent) then
            if r.intent == 'TRAFFIC_STOP' then
                s.stop = { opened = os.time(), noAdditional = r.noAdditional == true }; s.incidentMode = 'TRAFFIC_STOP'
                TriggerClientEvent('haestorm-ai-dispatch:locationRequest', u.source)
                -- v0.5.0: every traffic stop is a real CAD/MDT incident from the
                -- beginning, not only after backup or a pursuit starts.
                local stopNote = r.noAdditional and 'Traffic stop initiated; no additional unit requested' or 'Traffic stop initiated'
                local opened = updateLiveIncident(u, s, stopNote, 'TRAFFIC_STOP', 3)
                if opened and s.callId then
                    cadEvent(u, s, 'TRAFFIC_STOP_OPEN', { note=stopNote, noAdditional=r.noAdditional == true, incidentMode='TRAFFIC_STOP' })
                    pcall(function() DispatchBridge.unitState(u.source, 'TRAFFIC_STOP', s.callId, {callsign=radioSign(u),incidentMode='TRAFFIC_STOP',noAdditional=r.noAdditional == true}) end)
                end
                if r.noAdditional then reply(u, 'copy. No additional. Vehicle and occupants.')
                else reply(u, 'copy. Vehicle and occupants.') end
            else reply(u, variant(r.intent, Config.RadioStatusReplies[r.intent] or ('copy. Showing you ' .. r.intent:lower():gsub('_', ' ') .. '.'))); finish(u) end
        end
        return
    end
    understandingLog('unhandled_process', u, r.text, r, 'intent reached process without a handler')
    reply(u, variant('REPEAT', '10-9.'))
end
-- v0.4.24: natural welfare/status-check replies. A unit may answer for itself
-- ("I'm good", "my unit is good", "code 4") or, when clearly identified,
-- another officer may advise that a checked unit is good. Spoken traffic never
-- changes identity; it only clears an existing welfare timer for a known unit.
local welfareDigits = { ['0']='zero',['1']='one',['2']='two',['3']='three',['4']='four',['5']='five',['6']='six',['7']='seven',['8']='eight',['9']='nine' }
local welfarePolice = { A='adam',B='boy',C='charles',D='david',E='edward',F='frank',G='george',H='henry',I='ida',J='john',K='king',L='lincoln',M='mary',N='nora',O='ocean',P='paul',Q='queen',R='robert',S='sam',T='tom',U='union',V='victor',W='william',X='xray',Y='young',Z='zebra' }
local welfareNato = { A='alpha',B='bravo',C='charlie',D='delta',E='echo',F='foxtrot',G='golf',H='hotel',I='india',J='juliett',K='kilo',L='lima',M='mike',N='november',O='oscar',P='papa',Q='quebec',R='romeo',S='sierra',T='tango',U='uniform',V='victor',W='whiskey',X='xray',Y='yankee',Z='zulu' }
local function welfareCallsignAliases(sign)
    sign = tostring(sign or ''):upper()
    local aliases = { sign:lower(), sign:gsub('[^%w]',''):lower() }
    local lead, letter, tail = sign:match('^(%d)(%a)%-?0?(%d+)$')
    if lead and letter and tail then
        local d1, d2 = welfareDigits[lead], {}
        for c in tail:gmatch('.') do d2[#d2+1] = welfareDigits[c] or c end
        local tailWords = table.concat(d2, ' ')
        aliases[#aliases+1] = d1 .. ' ' .. welfarePolice[letter] .. ' ' .. tailWords
        aliases[#aliases+1] = d1 .. ' ' .. welfareNato[letter] .. ' ' .. tailWords
    end
    return aliases
end
local function welfarePositive(text)
    local t = DispatcherIntent.normalize(text)
    -- Negatives/requests for help must never be treated as a welfare clear.
    if t:find('not good',1,true) or t:find('not code 4',1,true) or t:find('need help',1,true)
        or t:find('need assistance',1,true) or t:find('send help',1,true) or t:find('send another',1,true)
        or t:find('start me a 32',1,true) or t:find('start me at 32',1,true) or t:find('step it up',1,true) then return false end
    local phrases = {
        "i'm good", 'i am good', 'my unit is good', "my unit's good", 'unit is good', "unit's good",
        "we're good", 'we are good', 'all good', 'everything is good', "everything's good",
        "i'm fine", 'i am fine', "we're fine", 'we are fine', 'everything is fine', "everything's fine",
        "i'm okay", 'i am okay', 'we are okay', "we're okay", 'no issues', 'still good',
        'code 4', 'code four', '10-4', 'no assistance needed', 'negative assistance',
        'no additional needed', 'no additional', 'secure at this time', 'good at this time'
    }
    for _, phrase in ipairs(phrases) do if t:find(phrase,1,true) then return true end end
    -- Whisper has repeatedly rendered "code four" as "in four" on this radio path.
    if t:find(' is in four',1,true) or t:find(' in four at this time',1,true) then return true end
    return false
end
local function resolveWelfareTarget(speaker, text)
    local t = DispatcherIntent.normalize(text):gsub('x%s*%-?%s*ray','xray')
    local candidates = {}
    for otherSrc, otherState in pairs(units) do
        if tonumber(otherSrc) ~= tonumber(speaker.source) and otherState.welfare ~= nil then
            local other = identity(otherSrc)
            if other and other.agency == speaker.agency and (Config.SharedLeoRadio == true or other.channel == speaker.channel) then
                candidates[#candidates+1] = { u=other, s=otherState }
            end
        end
    end
    -- Prefer an explicit full callsign, including APCO and NATO spoken forms.
    for _, item in ipairs(candidates) do
        for _, alias in ipairs(welfareCallsignAliases(item.u.sign)) do
            if alias ~= '' and t:find(alias,1,true) then return item.u, item.s end
        end
    end
    -- "2 is good" is accepted only when exactly one checked unit can safely match 2.
    local number = t:match('^%s*(%d+)%s+is%s+') or t:match('%s(%d+)%s+is%s+')
    if number then
        local matches = {}
        for _, item in ipairs(candidates) do
            local tail = tostring(item.u.sign):match('%-?0?(%d+)$')
            if tostring(tail or '') == tostring(number) then matches[#matches+1] = item end
        end
        if #matches == 1 then return matches[1].u, matches[1].s end
    end
    return nil, nil
end
local function handleWelfareTraffic(u, s, text, now)
    if not welfarePositive(text) then return false end
    local targetU, targetS = resolveWelfareTarget(u, text)
    if targetU and targetS then
        targetS.welfare = nil; targetS.welfareStage = nil; targetS.activity = now
        if Config.UnderstandingDebug then
            print(('[AI TEST WELFARE] %s'):format(json.encode({unit=targetU.sign, relayedBy=u.sign, action='THIRD_PARTY_CODE4', escalation='CANCELLED', time=now})))
        end
        reply(u, '10-4. Copy ' .. radioSign(targetU) .. ' code 4.')
        finish(u)
        return true
    end
    if s.welfare ~= nil then
        s.welfare = nil; s.welfareStage = nil; s.activity = now
        if Config.UnderstandingDebug then
            print(('[AI TEST WELFARE] %s'):format(json.encode({unit=u.sign, action='CODE4', escalation='CANCELLED', time=now})))
        end
        reply(u, '10-4.')
        finish(u)
        return true
    end
    return false
end


-- v0.5.0.4 STT/radio normalization:
-- Recover a small set of common Whisper mishears for 10-8 traffic.  Ambiguous
-- phrases are only rewritten when the tracked unit state makes a status update
-- plausible, so normal conversational uses of words such as "tonight" remain
-- untouched.
local function normalizeVoiceStatusMishears(src, text)
    local original = tostring(text or '')
    local normalized = original
    local tracked = units[src]
    local status = tracked and tostring(tracked.status or '') or ''
    local statusContext = status == 'AVAILABLE' or status == 'ON_DUTY' or status == 'RESPONDING'
        or status == 'ON_SCENE' or status == 'TRAFFIC_STOP'

    local compactOriginal = DispatcherIntent.normalize(original)
    -- Whisper occasionally hears a one-word radio hail of "Dispatch" as
    -- "Internet". Only correct the standalone word; never rewrite normal
    -- sentences that legitimately contain "internet".
    if compactOriginal == 'internet' then
        normalized = 'Dispatch.'
    end

    -- High-confidence phrasing can always be corrected.
    normalized = normalized:gsub('([Ss]how me)%s+[Tt]onight', '%1 10-8')
    normalized = normalized:gsub('([Mm]ark me)%s+[Tt]onight', '%1 10-8')
    normalized = normalized:gsub('([Pp]ut me)%s+[Tt]onight', '%1 10-8')
    normalized = normalized:gsub('([Ss]how me)%s+[Tt]en%s+[Aa]te', '%1 10-8')
    normalized = normalized:gsub('([Mm]ark me)%s+[Tt]en%s+[Aa]te', '%1 10-8')

    -- Police-radio person references: Whisper commonly renders "male" as "mail".
    -- Only correct it when the surrounding phrase clearly describes a person.
    normalized = normalized:gsub('([Oo]ut with one)%s+[Mm]ail', '%1 male')
    normalized = normalized:gsub('([Oo]ut with a)%s+[Mm]ail', '%1 male')
    normalized = normalized:gsub('([Oo]ut with)%s+[Ee]mail', '%1 a male')
    normalized = normalized:gsub('([Oo]ut with one)%s+[Ee]mail', '%1 male')
    normalized = normalized:gsub('^([Mm]ail)%s+is%s+wearing', 'Male is wearing')
    normalized = normalized:gsub('^([Mm]ail)%s+wearing', 'Male wearing')
    normalized = normalized:gsub('^[Mm][Aa][Ll]%s+is%s+wearing', 'Male is wearing')
    normalized = normalized:gsub('^[Mm][Aa][Ll]%s+wearing', 'Male wearing')

    if statusContext then
        local compact = DispatcherIntent.normalize(normalized)
        -- Whisper occasionally collapses "show me tonight" into these forms.
        if compact == 'sermon tonight' or compact == 'showing tonight'
            or compact == 'show me tonight' or compact == 'show me back tonight'
            or compact == 'send me back tonight' or compact == 'mark me tonight' then
            normalized = 'Show me 10-8.'
        elseif compact == 'sermon ten eight' or compact == 'showing ten eight' then
            normalized = 'Show me 10-8.'
        elseif compact == 'send me back' or compact == 'put me back'
            or compact == 'mark me back' or compact == 'show me back'
            or compact == 'back in service' or compact == 'put me back in service'
            or compact == 'send me back in service' then
            normalized = 'Show me 10-8.'
        end
    end

    if normalized ~= original and Config.ResponseDebug ~= false then
        print(('[AI response debug] %s'):format(json.encode({
            stage='transcript_normalized', original=original, normalized=normalized,
            unitStatus=status ~= '' and status or nil, time=os.time()
        })))
    end
    return normalized
end

-- v0.5.0.5 subject-stop normalization:
-- Officers commonly say "show/send/mark me out with ..." when making a
-- self-initiated pedestrian/subject contact.  Keep this local and deterministic
-- so ordinary "send me" traffic is not misclassified.
local function parseSubjectStopTraffic(text)
    local compact = DispatcherIntent.normalize(tostring(text or ''))
    local matched = compact:match('^show me out with%s+(.+)$')
        or compact:match('^send me out with%s+(.+)$')
        or compact:match('^mark me out with%s+(.+)$')
        or compact:match('^just show me out with%s+(.+)$')
        or compact:match('^just send me out with%s+(.+)$')
        or compact:match('^just mark me out with%s+(.+)$')
        or compact:match('^you can show me out with%s+(.+)$')
        or compact:match('^you can send me out with%s+(.+)$')
        or compact:match('^you can mark me out with%s+(.+)$')
        or compact:match('^i am out with%s+(.+)$')
        or compact:match("^i'm out with%s+(.+)$")

    if not matched or matched == '' then return nil end

    local location = matched:match('%s+at%s+(.+)$')
    local subject = matched
    if location then subject = matched:sub(1, #matched - (#location + 4)) end
    subject = subject:gsub('^%s+',''):gsub('%s+$','')
    if subject == '' then subject = 'an individual' end

    return {
        intent = 'SUBJECT_STOP',
        confidence = 1,
        text = compact,
        subject = subject,
        location = location,
    }
end

local function parseOperationalShorthand(text)
    local compact = DispatcherIntent.normalize(tostring(text or ''))

    -- Short radio-control wording Whisper commonly truncates.
    if compact == 'disreg' or compact == 'disreg it' or compact == 'disreg that' then
        return { intent='CANCEL', confidence=1, text=compact }
    end

    -- Natural 10-6/busy phrasing. Keep this narrow so numbers in unrelated
    -- traffic do not change a unit status.
    local busy = {
        ['10-6']=true, ['10 6']=true,
        ['show me 10-6']=true, ['show me 10 6']=true,
        ['mark me 10-6']=true, ['mark me 10 6']=true,
        ['put me 10-6']=true, ['put me 10 6']=true,
        ['send me 10-6']=true, ['send me 10 6']=true,
        ['you can show me 10-6']=true, ['you can show me 10 6']=true,
        ['you can mark me 10-6']=true, ['you can mark me 10 6']=true,
        ['you can put me 10-6']=true, ['you can put me 10 6']=true,
    }
    if busy[compact] then return { intent='BUSY', confidence=1, text=compact } end

    -- "No additional" is negative backup traffic, never a request to start a
    -- unit. If the same transmission starts a traffic stop, preserve the stop.
    local noAdditional = compact:find('no additional',1,true)
        or compact:find('negative additional',1,true)
        or compact:find('no extra unit',1,true)
        or compact:find('no extra units',1,true)
        or compact:find('negative on additional',1,true)
        or compact:find('no additional at this time',1,true)
    if noAdditional then
        local trafficStop = compact:find('traffic stop',1,true)
            or compact:find('10-11',1,true) or compact:find('10 11',1,true)
            or compact:find('vehicle stop',1,true) or compact:find('on a stop',1,true)
        if trafficStop then
            return { intent='TRAFFIC_STOP', confidence=1, text=compact, noAdditional=true }
        end
        return { intent='NEGATED', confidence=1, text=compact, noAdditional=true }
    end

    return nil
end

local function ingress(src, channel, text, confidence, requestId, overlap, trusted)
    if not enabled or type(text) ~= 'string' or #text > Config.MaxText or #text == 0 then return false end
    text = normalizeVoiceStatusMishears(src, text)
    local shorthand = parseOperationalShorthand(text)

    -- Subject-stop language is more specific than the generic traffic-stop parser.
    -- Parse it first so "one male/mail at postal 506" cannot become a vehicle stop.
    local subjectStop = parseSubjectStopTraffic(text)
    local r = shorthand or subjectStop or DispatcherIntent.parse(text)
    if r.intent == 'UNKNOWN' then
        local ackText = DispatcherIntent.normalize(text)
        local naturalAck = {
            ['copy']=true, ['copy that']=true, ['received']=true, ['roger']=true,
            ['roger that']=true, ['understood']=true, ['affirm']=true, ['affirmative']=true
        }
        if naturalAck[ackText] then
            r = { intent='ACK', confidence=1, text=ackText }
        end
    end
    if Config.UnderstandingDebug then
        local pu = identity(src, true)
        understandingLog('local', pu, text, r, 'local parser result')
    end
    local prior = units[src]
    if prior and prior.interpreting then
        if r.intent ~= 'EMERGENCY' then return false end
        prior.interpreting = nil
    end
    local pendingIntent = prior and prior.voicePending and prior.voicePending.request.intent
    local u = identity(src, r.intent == 'ON_DUTY' or (r.intent == 'CONFIRM' and pendingIntent == 'ON_DUTY'))
    if not u or tonumber(channel) ~= u.channel then return false end
    if mode == 'manual' and not ((r.intent == 'EMERGENCY' or (r.intent == 'CONFIRM' and pendingIntent == 'EMERGENCY')) and Config.EmergencyInManual) then return false end
    local now = os.time()
    if rate[src] and now - rate[src] < Config.RateSeconds then return false end
    rate[src] = now
    if type(requestId) ~= 'string' or #requestId > 100 then return false end
    local key = u.cid .. ':' .. requestId
    if dedupe[key] then return false end
    dedupe[key] = now
    local day, month = os.date('!%Y-%m-%d'), os.date('!%Y-%m')
    if usage.day ~= day then usage.day = day; usage.daily = 0 end
    if usage.month ~= month then usage.month = month; usage.monthly = 0 end
    if r.intent ~= 'EMERGENCY' and (usage.daily >= Config.DailyTransmissions or usage.monthly >= Config.MonthlyTransmissions) then reply(u, 'dispatcher usage limit reached. Use normal dispatch controls.'); return false end
    usage.daily = usage.daily + 1; usage.monthly = usage.monthly + 1
    SetResourceKvp('usage', json.encode(usage))
    local l, s = lane(u), state(u)
    -- If dispatch just asked for a plate, the next transmission may be only the
    -- characters/phonetics. Convert it before semantic AI so this path stays fast.
    if s.waitingPlate then
        if s.waitingPlate < now then s.waitingPlate = nil
        elseif r.intent == 'UNKNOWN' then
            local plate = DispatcherIntent.plate(text)
            if plate then
                r = { intent = 'PLATE', plate = plate, text = r.text, confidence = 1 }
                understandingLog('plate_context', u, text, r, 'plate recovered from follow-up transmission')
            end
        end
    end
    if overlap then reply(u, 'units calling, you doubled. 10-9 one at a time.'); return false end
    if not trusted then return false end

    -- Any authenticated keyed transmission proves the unit is active. Update the
    -- welfare clock immediately so a timer cannot fire while the officer is in the
    -- middle of giving pursuit/priority traffic.
    s.activity = now

    -- Natural code-4/status replies are handled before semantic AI and before
    -- generic welfare cancellation so another unit can safely clear the checked unit.
    if handleWelfareTraffic(u, s, text, now) then return true end

    -- v0.4.15: any authenticated transmission after a welfare/status check is a
    -- response from the unit. Cancel escalation first; if the words are unclear,
    -- dispatch can still ask 10-9 instead of falsely sending a supervisor check.
    if s.welfare then
        s.welfare = nil
        s.welfareStage = nil
        s.activity = now
        if Config.UnderstandingDebug then
            print(('[AI TEST WELFARE] %s'):format(json.encode({unit=u.sign, action='RESPONSE_RECEIVED', escalation='CANCELLED', time=now})))
        end
    end

    -- Subject-stop context wins over generic vehicle-stop interpretation when the
    -- officer is clearly giving a person description.
    if s.incidentMode == 'SUBJECT_STOP' and subjectStopDetail(text)
        and (r.intent == 'UNKNOWN' or r.intent == 'TRAFFIC_STOP' or r.intent == 'TRAFFIC_STOP_UPDATE' or r.intent == 'NEGATED') then
        r = { intent='INCIDENT_UPDATE', confidence=1, text=DispatcherIntent.normalize(text) }
        understandingLog('subject_stop_context', u, text, r, 'subject description recovered from active subject stop')
    end

    -- Escalate unmistakable action traffic without waiting for semantic fallback.
    local normalizedAction = DispatcherIntent.normalize(tostring(text or ''))
    local urgentAction = isOfficerDownTraffic(normalizedAction)
        or normalizedAction:find('shots fired',1,true)
        or normalizedAction:find('shots being fired',1,true)
        or isFootPursuitTraffic(normalizedAction)
        or isPursuitTraffic(normalizedAction)
    if urgentAction and r.intent ~= 'END_EMERGENCY' and r.intent ~= 'RESUME_AIR'
        and r.intent ~= 'RESUME_AIR_AVAILABLE' and r.intent ~= 'CLEAR' then
        r = { intent='EMERGENCY_UPDATE', confidence=1, text=text }
        understandingLog('priority_escalation', u, text, r, 'action phrase escalated from live radio context')
    elseif isArmedTraffic(normalizedAction) and r.intent == 'UNKNOWN' then
        r = { intent='INCIDENT_UPDATE', confidence=1, text=text }
        understandingLog('priority_context', u, text, r, 'armed-subject traffic promoted to priority incident update')
    end

    -- Context-first traffic-stop parsing. Generic UNKNOWN/NEGATED results do not
    -- get to discard useful vehicle/occupant information while the unit is on a stop.
    if s.stop and (r.intent == 'UNKNOWN' or r.intent == 'NEGATED') then
        local stopUpdate = DispatcherIntent.trafficStopUpdate(text)
        if stopUpdate then
            r = { intent='TRAFFIC_STOP_UPDATE', confidence=1, text=r.text, summary=stopUpdate.summary, partial=stopUpdate.partial, noAdditional=stopUpdate.noAdditional, occupied=stopUpdate.occupied }
            understandingLog('traffic_stop_context', u, text, r, 'vehicle/occupant details recovered from active stop context')
        end
    end

    -- State-first incident engine. Once a unit is actively in a pursuit/priority
    -- incident, interpret the next short transmission in that context BEFORE
    -- generic semantic fallback. Backup/clear/control intents retain priority.
    if s.incidentMode and (s.incidentMode == 'VEHICLE_PURSUIT' or s.incidentMode == 'FOOT_PURSUIT' or s.incidentMode == 'PRIORITY_INCIDENT' or s.incidentMode == 'SHOTS_FIRED') then
        local tt = DispatcherIntent.normalize(tostring(text or ''))
        local contextual = r.intent == 'UNKNOWN'
        if contextual then
            local ignore = tt == '' or tt == 'thank you' or tt == 'thanks' or tt == 'copy' or tt == '10-4' or tt == '10 4'
            if not ignore and #tt <= 180 then
                r = {intent='EMERGENCY_UPDATE', text=text, confidence=1}
                understandingLog('incident_context', u, text, r, 'state-first active incident update')
            end
        end
    end

    local emergencyActive = next(l.emergency) ~= nil
    local priorityUnit = emergencyActive and emergencyParticipant(u, s, l)
    -- The unit controlling an emergency may clear/end its own incident naturally.
    if priorityUnit and s.status == 'EMERGENCY' and (r.intent == 'AVAILABLE' or r.intent == 'CLEAR') then
        r = { intent='RESUME_AIR_AVAILABLE', text=r.text, confidence=1, disposition=r.disposition }
        understandingLog('incident_clear_context', u, text, r, 'priority unit ended emergency and returned available')
    end

    local isEmergency = r.intent == 'EMERGENCY' or r.intent == 'EMERGENCY_UPDATE' or r.intent == 'END_EMERGENCY' or r.intent == 'RESUME_AIR' or r.intent == 'RESUME_AIR_AVAILABLE' or r.intent == 'HOLD_AIR' or r.intent == 'CANCEL' or r.intent == 'CANCEL_LAST_TRAFFIC' or r.intent == 'CANCEL_CALL' or r.intent == 'CANCEL_BACKUP' or r.intent == 'BACKUP' or r.intent == 'ON_SCENE' or r.intent == 'RESPONDING' or (r.intent == 'CONFIRM' and s.voicePending and s.voicePending.request.intent == 'EMERGENCY')
    if emergencyActive and routineDuringEmergency(r) and not priorityUnit then reply(u, 'stand by. Emergency traffic only.', true); return false end
    if emergencyActive and not priorityUnit and not isEmergency then reply(u, 'stand by unless emergency.', true); return false end
    if l.active and l.active ~= src and not isEmergency and not priorityUnit then
        for _, q in ipairs(l.queue) do if q.source == src then reply(u, 'standby. 10-9 when called.'); return false end end
        if #l.queue >= Config.MaxQueue then reply(u, 'queue full. Call again shortly.'); return false end
        l.queue[#l.queue + 1] = { source = src, cid = u.cid, sign = u.sign, channel = u.channel, priority = 0, requested = now, conversation = 'waiting', expires = now + Config.QueueSeconds }
        reply(u, 'standby.'); return true
    end
    -- Reserve this unit's dialogue even while an unscored request is awaiting
    -- readback. Other routine callers must wait instead of opening another one.
    if not isEmergency and not priorityUnit then l.active = src; s.untilTime = now + Config.ConversationSeconds end
    if r.intent == 'UNKNOWN' and Config.SemanticUnderstanding and notices[src] and not overlap
        and not s.selecting and not s.awaitDisposition and not s.voicePending
        and r.text ~= 'status okay' and r.text ~= 'all okay' and r.text ~= 'code 4'
        and (confidence == nil or (type(confidence) == 'number' and confidence >= Config.Confidence and confidence <= 1)) then
        local contextCalls = {}
        for _, c in ipairs(callsFor(u) or {}) do
            contextCalls[#contextCalls + 1] = { id = c.id, description = tostring(c.message or ''):sub(1, 150), street = tostring(c.street or ''):sub(1, 80) }
            if #contextCalls >= 20 then break end
        end
        local generation, cid, sign = voiceGeneration, u.cid, u.sign
        s.interpreting = requestId
        local semanticStarted = GetGameTimer()
        local ok, response = pcall(function() return exports[Config.VoiceBridgeResource]:InterpretRadio({id = u.cid .. ':' .. requestId, text = text, context = {status = s.status, currentCall = s.callId, latestCall = l.latest, onTrafficStop = s.stop ~= nil, trafficStop = s.stop, awaitingDisposition = s.awaitDisposition == true, calls = contextCalls, tenCodes = Config.Phrases, radioLingo = Config.RadioLingo, recentIntent = s.lastIntent, waitingForPlate = s.waitingPlate ~= nil, emergencyActive = next(l.emergency) ~= nil, emergencyParticipant = emergencyParticipant(u, s, l), incidentMode = s.incidentMode, channel = u.channel, agency = u.agency, awaiting = s.waitingPlate and 'PLATE' or (s.awaitDisposition and 'DISPOSITION' or (s.selecting and 'CALL_SELECTION' or nil))}}) end)
        if Config.UnderstandingDebug then print(('[AI dispatch latency] semantic=%dms unit=%s'):format(GetGameTimer() - semanticStarted, tostring(u.sign))) end
        local current = identity(src)
        if s.interpreting ~= requestId then return false end
        s.interpreting = nil
        if not enabled or mode ~= 'ai' or voiceGeneration ~= generation or not current or current.cid ~= cid or current.sign ~= sign or current.channel ~= u.channel or (not priorityUnit and l.active ~= src) then return false end
        local candidate = ok and type(response) == 'table' and response.ok and response.result
        local allowed = {EMERGENCY_UPDATE=true,RADIO_CHECK=true,HAIL=true,RESPONDING=true,ON_SCENE=true,AVAILABLE=true,BUSY=true,UNAVAILABLE=true,TRAFFIC_STOP=true,TRANSPORTING=true,BACKUP=true,CLEAR=true,EMERGENCY=true,QUERY=true,NEGATED=true,CANCEL=true,CANCEL_LAST_TRAFFIC=true,CANCEL_CALL=true,CANCEL_BACKUP=true,END_EMERGENCY=true,HOLD_AIR=true,RESUME_AIR=true,RESUME_AIR_AVAILABLE=true,PLATE=true,PLATE_REQUEST=true,TRAFFIC_STOP_UPDATE=true,NO_PLATE=true,INCIDENT_UPDATE=true,SUBJECT_STOP=true,ACK=true}
        if type(candidate) ~= 'table' or not allowed[candidate.intent] or type(candidate.confidence) ~= 'number' or candidate.confidence < Config.SemanticConfidence or candidate.confidence > 1 then
            understandingLog('semantic_rejected', u, text, r, { ok = ok, responseOk = type(response) == 'table' and response.ok or false, candidate = candidate })
            reply(u, variant('REPEAT', '10-9.')); return false
        end
        if candidate.callId then
            local valid = false
            for _, c in ipairs(callsFor(current) or {}) do if c.id == candidate.callId then valid = true; break end end
            if not valid then reply(u, 'that call is no longer available.'); return false end
        end
        if candidate.disposition then
            local valid = false
            for _, d in ipairs(Config.Dispositions) do if d == candidate.disposition then valid = true; break end end
            if not valid then return false end
        end
        understandingLog('semantic_accepted', u, text, r, { intent = candidate.intent, confidence = candidate.confidence, callId = candidate.callId, disposition = candidate.disposition })
        r = {intent = candidate.intent, callId = candidate.callId, disposition = candidate.disposition, plate = candidate.plate, text = r.text, confidence = candidate.confidence}
        -- Semantic confidence never substitutes for acoustic confidence; even
        -- typed AI interpretations require an explicit operator readback.
        confidence = nil
    end
    if confidence == nil and Config.UnscoredVoice == 'natural' then
        -- Scribe does not provide acoustic confidence. For normal radio traffic,
        -- use the validated local/semantic intent immediately so dispatch behaves
        -- like a dispatcher instead of forcing a robotic readback every time.
        -- The process() layer still performs contextual validation (active call,
        -- disposition requirements, call selection, etc.). Sensitive plate checks
        -- retain their own explicit confirmation inside process().
        if r.intent == 'CONFIRM' and s.voicePending then
            local pending = s.voicePending; s.voicePending = nil
            if pending.expires < now then reply(u, 'confirmation expired. 10-9.'); return false end
            r = pending.request
        elseif r.intent == 'UNKNOWN' then
            if s.selecting then
                local selection = { callId = tonumber(r.text:match('(%d+)')), selector = r.text }
                local call, err = choose(u, selection)
                if not call then reply(u, err); return false end
                r = { intent = 'RESPONDING', callId = call.id }
            elseif s.awaitDisposition then
                for _, d in ipairs(Config.Dispositions) do if r.text == d then r = { intent = 'CLEAR', disposition = d }; break end end
            elseif r.text == 'status okay' or r.text == 'all okay' or r.text == 'code 4' then
                process(u, r); return true
            else
                understandingLog('unknown_after_context', u, text, r, 'no contextual match')
                reply(u, variant('REPEAT', '10-9.')); return false
            end
        end
    elseif confidence == nil and Config.UnscoredVoice == 'confirm' then
        -- Missing acoustic confidence is never replaced with a numeric constant.
        -- Exact-match classifier evidence plus an explicit operator readback is
        -- a separate policy. Low numeric confidence is still always rejected.
        if r.intent == 'CONFIRM' and s.voicePending then
            local pending = s.voicePending; s.voicePending = nil
            if pending.expires < now then reply(u, 'confirmation expired. 10-9.'); return false end
            r = pending.request
        elseif r.intent == 'HAIL' or r.intent == 'QUERY' or r.intent == 'NEGATED' or r.intent == 'CANCEL' or r.intent == 'CANCEL_LAST_TRAFFIC' or r.intent == 'CANCEL_CALL' or r.intent == 'CANCEL_BACKUP' or r.intent == 'END_EMERGENCY' or r.intent == 'HOLD_AIR' or r.intent == 'RESUME_AIR' or r.intent == 'RESUME_AIR_AVAILABLE' or r.intent == 'CORRECTION' then
            -- Read-only dialogue and cancelling a pending request are safe.
        elseif r.intent == 'UNKNOWN' then
            -- Preserve existing contextual clarification/disposition dialogue;
            -- stage the actual resulting mutating request for readback first.
            if s.selecting then
                local selection = { callId = tonumber(r.text:match('(%d+)')), selector = r.text }
                local call, err = choose(u, selection)
                if not call then reply(u, err); return false end
                r = { intent = 'RESPONDING', callId = call.id }
            elseif s.awaitDisposition then
                for _, d in ipairs(Config.Dispositions) do if r.text == d then r = { intent = 'CLEAR', disposition = d }; break end end
            elseif r.text == 'status okay' or r.text == 'all okay' or r.text == 'code 4' then
                process(u, r); return true
            else reply(u, '10-9.'); return false end
            if r.intent == 'UNKNOWN' then reply(u, '10-9.'); return false end
            s.voicePending = { request = r, expires = now + Config.ConversationSeconds }
            reply(u, 'confirm ' .. r.intent:lower():gsub('_', ' ') .. (r.callId and (' on call ' .. r.callId) or '') .. (r.disposition and (' with ' .. r.disposition) or '') .. '. Say confirm.'); return true
        elseif r.intent == 'CONFIRM' then
            -- Confirming a previously read-back plate/call correction.
            if not s.pending then reply(u, 'no current request to confirm.'); return false end
        else
            if r.intent == 'RESPONDING' then
                local call, err = choose(u, r)
                if not call then s.selecting = true; reply(u, err); return false end
                r.callId = call.id
            end
            s.voicePending = { request = r, expires = now + Config.ConversationSeconds }
            reply(u, 'confirm ' .. r.intent:lower():gsub('_', ' ') .. (r.callId and (' on call ' .. r.callId) or '') .. (r.plate and (' plate ' .. r.plate) or '') .. (r.disposition and (' with ' .. r.disposition) or '') .. '. Say confirm.', r.intent == 'EMERGENCY'); return true
        end
    elseif type(confidence) ~= 'number' or confidence < Config.Confidence or confidence > 1 then reply(u, '10-9.'); return false
    elseif r.intent == 'CONFIRM' and s.voicePending then
        local pending = s.voicePending; s.voicePending = nil
        if pending.expires < now then reply(u, 'confirmation expired. 10-9.'); return false end
        r = pending.request
    end
    s.lastIntent = r.intent ~= 'CONFIRM' and r.intent or s.lastIntent
    if r.intent == 'EMERGENCY' then process(u, r); return true end
    if l.active and l.active ~= src and not priorityUnit then
        for _, q in ipairs(l.queue) do if q.source == src then reply(u, 'standby. 10-9 when called.'); return false end end
        if #l.queue >= Config.MaxQueue then reply(u, 'queue full. Call again shortly.'); return false end
        l.queue[#l.queue + 1] = { source = src, cid = u.cid, sign = u.sign, channel = u.channel, priority = 0, requested = now, conversation = 'waiting', expires = now + Config.QueueSeconds }
        reply(u, 'standby.'); return true
    end
    l.active = src; s.untilTime = now + Config.ConversationSeconds
    process(u, r); return true
end
-- Only the trusted server radio/STT resource can submit a transcript or confidence.
exports('SubmitRadioTranscript', function(src, channel, text, confidence, id, overlap, session)
    if GetInvokingResource() ~= Config.VoiceBridgeResource then return false end
    if session then
        local current = voiceSessions[src]
        local u = identity(src, true)
        if not current or not u or current.token ~= session or current.signature ~= (u.cid .. ':' .. u.sign .. ':' .. u.agency .. ':' .. u.channel .. ':' .. tostring(u.player.PlayerData.job.onduty)) then return false end
    elseif confidence == nil then return false end
    return ingress(src, channel, text, confidence, id, overlap, true)
end)


-- v0.5.0.2 direct worker event handoff fallback.
-- The external worker owns STT/audio capture and exposes a short-lived /events
-- queue. Some older radio-bridge builds can remain connected for speech output
-- while failing to drain transcript events after a resource/update restart.
-- Polling the worker here gives the authoritative dispatch core a direct path
-- for transcript/notice/delivery events without changing tRadio or local STT/TTS.
local directWorkerPollBusy = false
local directWorkerSeen = {}
local directWorkerLastCleanup = 0

local function directWorkerAuthHeaders()
    local token = GetConvar('ai_dispatch_bridge_token', '')
    if token == '' then return nil end
    return {
        ['Authorization'] = 'Bearer ' .. token,
        ['Content-Type'] = 'application/json'
    }
end

local function cleanupDirectWorkerSeen(now)
    if now - directWorkerLastCleanup < 30 then return end
    directWorkerLastCleanup = now
    for id, seenAt in pairs(directWorkerSeen) do
        if now - seenAt > 60 then directWorkerSeen[id] = nil end
    end
end

local function validateDirectWorkerSession(src, channel, session)
    src = tonumber(src)
    channel = tonumber(channel)
    if not src or not channel or type(session) ~= 'string' or session == '' then
        return nil, 'invalid_event_identity'
    end
    local current = voiceSessions[src]
    local u = identity(src, true)
    if not current or not u then return nil, 'unit_not_eligible' end
    local signature = u.cid .. ':' .. u.sign .. ':' .. u.agency .. ':' .. u.channel .. ':' .. tostring(u.player.PlayerData.job.onduty)
    if current.signature ~= signature then return nil, 'session_signature_changed' end
    if current.token ~= session then return nil, 'session_token_mismatch' end
    if tonumber(u.channel) ~= channel then return nil, 'channel_mismatch' end
    return u
end

local function handleDirectWorkerEvent(event)
    if type(event) ~= 'table' then return false, 'invalid_event' end
    local eventId = tostring(event.id or '')
    if eventId == '' then return false, 'missing_event_id' end
    if directWorkerSeen[eventId] then return true, 'duplicate_local' end
    directWorkerSeen[eventId] = os.time()

    if event.kind == 'transcript' then
        local src = tonumber(event.source)
        local channel = tonumber(event.channel)
        local u, sessionErr = validateDirectWorkerSession(src, channel, event.session)
        if not u then
            print(('[AI worker event] transcript rejected id=%s src=%s channel=%s reason=%s'):format(eventId, tostring(src), tostring(channel), tostring(sessionErr)))
            return false, sessionErr
        end
        local text = tostring(event.text or '')
        if text == '' or #text > Config.MaxText then
            print(('[AI worker event] transcript rejected id=%s src=%s reason=invalid_text'):format(eventId, tostring(src)))
            return false, 'invalid_text'
        end
        local accepted = ingress(src, channel, text, event.confidence, eventId, event.overlap == true, true)
        print(('[AI worker event] transcript id=%s src=%s unit=%s channel=%s accepted=%s text=%s'):format(
            eventId, tostring(src), tostring(u.sign), tostring(channel), tostring(accepted == true), json.encode(text:sub(1, 180))))
        return accepted == true, accepted == true and 'accepted' or 'ingress_rejected'
    elseif event.kind == 'notice' then
        local src = tonumber(event.source)
        local channel = tonumber(event.channel)
        local _, sessionErr = validateDirectWorkerSession(src, channel, event.session)
        if sessionErr then return false, sessionErr end
        TriggerClientEvent('haestorm-ai-dispatch:message', src, tostring(event.message or ''):sub(1, 240), false)
        return true, 'notice_delivered'
    elseif event.kind == 'delivery_failed' then
        local channel = tonumber(event.channel)
        if channel then
            for src in pairs(QB.Functions.GetQBPlayers()) do
                local u = identity(src)
                if u and (Config.SharedLeoRadio == true or tonumber(u.channel) == channel) then
                    TriggerClientEvent('haestorm-ai-dispatch:message', src, 'Dispatcher voice playback failed. Confirmed actions remain recorded; use text controls.', false)
                end
            end
        end
        print(('[AI worker event] delivery_failed channel=%s reason=%s'):format(tostring(channel), tostring(event.reason or 'unknown')))
        return true, 'delivery_failure_noted'
    end

    return false, 'unsupported_event_kind'
end

local function ackDirectWorkerEvents(ids, headers)
    if type(ids) ~= 'table' or #ids == 0 then return end
    PerformHttpRequest('http://127.0.0.1:8789/ack', function(statusCode)
        if statusCode ~= 200 then
            print(('[AI worker event] ACK failed http=%s count=%s'):format(tostring(statusCode), tostring(#ids)))
        end
    end, 'POST', json.encode({ ids = ids }), headers)
end

CreateThread(function()
    Wait(1500)
    while true do
        Wait(250)
        cleanupDirectWorkerSeen(os.time())
        if not directWorkerPollBusy and Config.ExternalSpeech and enabled then
            local headers = directWorkerAuthHeaders()
            if headers then
                directWorkerPollBusy = true
                PerformHttpRequest('http://127.0.0.1:8789/events', function(statusCode, body)
                    directWorkerPollBusy = false
                    if statusCode ~= 200 then return end
                    local ok, payload = pcall(json.decode, body or '')
                    if not ok or type(payload) ~= 'table' or type(payload.events) ~= 'table' or #payload.events == 0 then return end
                    local ackIds = {}
                    for _, event in ipairs(payload.events) do
                        if type(event) == 'table' and event.id then
                            -- Always ACK after a deterministic validation/handling attempt.
                            -- Invalid/stale events must not poison the 30-second worker queue.
                            pcall(handleDirectWorkerEvent, event)
                            ackIds[#ackIds + 1] = tostring(event.id)
                            if #ackIds >= 8 then break end
                        end
                    end
                    ackDirectWorkerEvents(ackIds, headers)
                end, 'GET', '', headers)
            end
        end
    end
end)
local function buildVoicePolicy()
    local speechEnabled = GetConvarInt('ai_dispatch_speech_enabled', 0) == 1
    local policy = { enabled = enabled and speechEnabled and Config.ExternalSpeech and (mode == 'ai' or Config.EmergencyInManual), routine = mode == 'ai', externalNotice = Config.ExternalSpeech, generation = voiceGeneration, units = {}, channels = {} }
    local channels = {}
    for _, agency in pairs(Config.Agencies) do for channel in pairs(agency.channels) do
        if not channels[channel] then policy.channels[#policy.channels + 1] = { frequency = channel, encoding = Config.RadioModes[channel] or 'opus' }; channels[channel] = true end
    end end
    if policy.enabled then for src in pairs(QB.Functions.GetQBPlayers()) do
        local u = identity(src, true)
        if u and notices[src] then
            local signature = u.cid .. ':' .. u.sign .. ':' .. u.agency .. ':' .. u.channel .. ':' .. tostring(u.player.PlayerData.job.onduty)
            if not voiceSessions[src] or voiceSessions[src].signature ~= signature then voiceSessions[src] = { signature = signature, token = ('%s:%s:%s'):format(GetGameTimer(), src, math.random(10000000, 99999999)) } end
            policy.units[#policy.units + 1] = { source = tonumber(src), channel = u.channel, session = voiceSessions[src].token }
        end
    end end
    return policy
end

exports('GetVoicePolicy', function()
    if GetInvokingResource() ~= Config.VoiceBridgeResource then return { enabled = false, units = {}, channels = {} } end
    return buildVoicePolicy()
end)

-- v0.5.0.2 policy heartbeat: the worker intentionally expires a voice policy
-- after five seconds. Push the authoritative server policy every two seconds so
-- eligible on-duty radio units remain synchronized even if a bridge event is
-- missed or a resource restart interrupts the old refresh loop.
CreateThread(function()
    local lastSummary = nil
    while true do
        Wait(2000)
        local token = GetConvar('ai_dispatch_bridge_token', '')
        if token ~= '' then
            local policy = buildVoicePolicy()
            local body = json.encode(policy)
            PerformHttpRequest('http://127.0.0.1:8789/policy', function(statusCode)
                local summary = ('enabled=%s units=%s generation=%s http=%s'):format(tostring(policy.enabled), tostring(#policy.units), tostring(policy.generation), tostring(statusCode))
                if statusCode ~= 200 then
                    if summary ~= lastSummary then print('[AI policy sync] FAILED ' .. summary) end
                elseif summary ~= lastSummary then
                    print('[AI policy sync] ' .. summary)
                end
                lastSummary = summary
            end, 'POST', body, { ['Authorization'] = 'Bearer ' .. token, ['Content-Type'] = 'application/json' })
        end
    end
end)
exports('VoiceBridgeNotice', function(src, channel, session, text)
    if GetInvokingResource() ~= Config.VoiceBridgeResource or type(text) ~= 'string' then return false end
    local u = identity(src, true); local current = voiceSessions[src]
    if not u or u.channel ~= tonumber(channel) or not current or current.token ~= session then return false end
    TriggerClientEvent('haestorm-ai-dispatch:message', src, text:sub(1, 240), false); return true
end)
exports('VoiceDeliveryFailed', function(channel)
    if GetInvokingResource() ~= Config.VoiceBridgeResource then return end
    for src in pairs(QB.Functions.GetQBPlayers()) do local u = identity(src); if u and (Config.SharedLeoRadio == true or u.channel == tonumber(channel)) then TriggerClientEvent('haestorm-ai-dispatch:message', src, 'Dispatcher voice playback failed. Confirmed actions remain recorded; use text controls.', false) end end
end)
RegisterNetEvent('haestorm-ai-dispatch:noticeSeen', function()
    local src = source
    notices[src] = true

    -- Startup privacy/debug information is staff-facing only. Normal players
    -- are acknowledged silently so they remain eligible for voice dispatch.
    if Config.ExternalSpeech and authorized(src, Config.AdminAce) then
        TriggerClientEvent('haestorm-ai-dispatch:developerNotice', src, Config.ExternalSpeechNotice)
    end
end)
local function cancelSpeech()
    voiceGeneration = voiceGeneration + 1
    pcall(function() exports[Config.VoiceBridgeResource]:CancelSpeech() end)
end
local function diagnostic(src)
    local p = QB.Functions.GetPlayer(src)
    if not p or not p.PlayerData or not p.PlayerData.job then return 'Officer job data is not loaded. Rejoin or wait for character loading.' end
    local d, agency = p.PlayerData, nil
    for _, a in pairs(Config.Agencies) do if a.jobs[d.job.name] then agency = a; break end end
    if not agency then return 'Your current job is not authorized for dispatch.' end
    local sign = tostring(d.metadata and d.metadata.callsign or '')
    if sign == '' or not sign:match(agency.callsignPattern) then return 'Set a valid callsign in your officer profile.' end
    local channel, radioError = DispatchBridge.channel(src)
    if not channel or not agency.channels[channel] then return radioError or 'Radio membership was not verified. Select an authorized transmit channel.' end
    if not d.job.onduty then return 'You are off duty. Go on duty before using voice dispatch.' end
    if not enabled then return 'AI dispatch is disabled. An administrator must enable it.' end
    if mode ~= 'ai' then return 'A human dispatcher has control. Authorized staff must resume AI mode.' end
    if GetConvarInt('ai_dispatch_speech_enabled', 0) ~= 1 then return 'Typed dispatch is ready; speech is disabled. An administrator must enable speech.' end
    if not notices[src] then return 'Typed dispatch is ready; the radio privacy notice has not been acknowledged. Reconnect to reload the dispatcher client.' end
    return ('Officer ready: job %s, callsign %s, channel %s.'):format(d.job.name, sign, channel)
end
local function diagnosticReply(src, text)
    TriggerClientEvent('haestorm-ai-dispatch:message', src, text, false)
end
RegisterCommand('dispatchstatus', function(src)
    if src > 0 then
        local text = diagnostic(src)
        print(('[AI dispatch] status source=%s: %s'):format(src, text))
        diagnosticReply(src, text)
    end
end)
RegisterCommand('dispatchhelp', function(src)
    if src > 0 then diagnosticReply(src, 'Dispatch: /dispatchstatus checks readiness; /dispatchvoice Dispatch opens radio traffic. Say responding, on scene, available, backup, or clear. Dispositions are optional. Voice changes require confirm. /dispatchpanic activates an emergency; use only for an actual in-game emergency.') end
end)
RegisterCommand('dispatchvoice', function(src, args)
    if src <= 0 then return end
    local u = identity(src, true)
    if not u or not enabled then diagnosticReply(src, diagnostic(src)); return end
    if mode ~= 'ai' and not Config.EmergencyInManual then diagnosticReply(src, diagnostic(src)); return end
    ingress(src, u.channel, table.concat(args, ' '), 1, ('typed:%s:%s'):format(src, GetGameTimer()), false, true)
end)
RegisterCommand('dispatchtest', function(src, args)
    if src > 0 and authorized(src, Config.AdminAce) then
        local u = identity(src, true)
        if u then ingress(src, u.channel, table.concat(args, ' '), 1, 'test:' .. GetGameTimer(), false, true) end
    end
end)
RegisterCommand('dispatchpanic', function(src)
    local u = src > 0 and identity(src)
    if u then ingress(src, u.channel, 'emergency', 1, 'panic:' .. GetGameTimer(), false, true) end
end)
RegisterCommand('dispatchmode', function(src, args)
    if not authorized(src, Config.TakeoverAce) then return end
    if args[1] == 'manual' or args[1] == 'ai' then
        mode = args[1]
        cancelSpeech()
        for _, l in pairs(lanes) do l.active = nil; l.queue = {} end
        for _, s in pairs(units) do s.pending = nil; s.voicePending = nil; s.selecting = nil end
        print('[AI dispatch] mode=' .. mode .. ' actor=' .. src)
    end
end)
RegisterCommand('dispatchdisable', function(src) if authorized(src, Config.AdminAce) then enabled = false; cancelSpeech(); print('[AI dispatch] disabled actor=' .. src) end end)
RegisterCommand('dispatchenable', function(src) if authorized(src, Config.AdminAce) then enabled = true; cancelSpeech(); print('[AI dispatch] enabled actor=' .. src) end end)
RegisterCommand('dispatchspeech', function(src, args)
    if not authorized(src, Config.AdminAce) then
        if src > 0 then diagnosticReply(src, 'You do not have the ai_dispatch.admin ACE permission. Run this command from the server console or grant the ACE to your admin group.') end
        print('[AI dispatch] dispatchspeech denied actor=' .. tostring(src) .. ' missing ACE=' .. tostring(Config.AdminAce))
        return
    end
    local action = tostring(args[1] or ''):lower()
    if action ~= 'enable' and action ~= 'disable' then
        if src > 0 then diagnosticReply(src, 'Usage: /dispatchspeech enable or /dispatchspeech disable') else print('[AI dispatch] Usage: dispatchspeech enable|disable') end
        return
    end
    SetConvar('ai_dispatch_speech_enabled', action == 'enable' and '1' or '0')
    cancelSpeech()
    local msg = 'Speech recognition ' .. (action == 'enable' and 'ENABLED' or 'DISABLED') .. '. Run /dispatchspeechhealth next.'
    print('[AI dispatch] speech=' .. action .. ' actor=' .. src)
    if src > 0 then diagnosticReply(src, msg) end
end)
RegisterCommand('dispatchradiodebug', function(src, args)
    if not authorized(src, Config.AdminAce) then
        if src > 0 then diagnosticReply(src, 'You do not have the ai_dispatch.admin ACE permission.') end
        return
    end
    local target = tonumber(args[1]) or (src > 0 and src or 1)
    local info = DispatchBridge.radioDebug(target)
    local encoded = json.encode(info)
    print(('[AI radio debug] %s'):format(encoded))
    if src > 0 then
        local resolved = info and info.resolved or nil
        diagnosticReply(src, resolved and ('Radio source '..target..' resolved to channel '..resolved..'.') or ('Radio source '..target..' did not resolve. Check txAdmin for [AI radio debug].'))
    end
end, false)

RegisterCommand('dispatcheligibilitydebug', function(src, args)
    if not authorized(src, Config.AdminAce) then
        if src > 0 then diagnosticReply(src, 'You do not have the ai_dispatch.admin ACE permission.') end
        return
    end

    local target = tonumber(args[1]) or (src > 0 and src or 1)
    local p = QB.Functions.GetPlayer(target)
    local report = {
        source = target,
        playerLoaded = p ~= nil,
        enabled = enabled == true,
        mode = mode,
        speechConvar = GetConvarInt('ai_dispatch_speech_enabled', 0),
        externalSpeech = Config.ExternalSpeech == true,
        noticeSeen = notices[target] == true,
        job = nil,
        onduty = nil,
        callsign = nil,
        callsignValid = false,
        agency = nil,
        jobAuthorized = false,
        channel = nil,
        channelError = nil,
        channelAuthorized = false,
        identityOffDutyAllowed = false,
        identityStrict = false,
        voicePolicyEligible = false,
        failedGates = {},
    }

    if p and p.PlayerData then
        local d = p.PlayerData
        if type(d.job) == 'table' then
            report.job = d.job.name
            report.onduty = d.job.onduty == true
        end
        report.callsign = tostring(d.metadata and d.metadata.callsign or '')

        for name, agency in pairs(Config.Agencies or {}) do
            if type(d.job) == 'table' and agency.jobs and agency.jobs[d.job.name] then
                report.agency = name
                report.jobAuthorized = true
                report.callsignValid = report.callsign ~= '' and report.callsign:match(agency.callsignPattern) ~= nil
                local channel, channelError = DispatchBridge.channel(target)
                report.channel = channel
                report.channelError = channelError
                report.channelAuthorized = channel ~= nil and agency.channels and agency.channels[channel] == true
                break
            end
        end
    end

    report.identityOffDutyAllowed = identity(target, true) ~= nil
    report.identityStrict = identity(target, false) ~= nil
    report.voicePolicyEligible = report.identityOffDutyAllowed and report.noticeSeen and report.enabled and report.speechConvar == 1 and report.externalSpeech and (report.mode == 'ai' or Config.EmergencyInManual == true)

    if not report.playerLoaded then report.failedGates[#report.failedGates + 1] = 'player_not_loaded' end
    if not report.jobAuthorized then report.failedGates[#report.failedGates + 1] = 'job_not_authorized' end
    if not report.callsignValid then report.failedGates[#report.failedGates + 1] = 'callsign_invalid_or_blank' end
    if not report.channelAuthorized then report.failedGates[#report.failedGates + 1] = 'radio_channel_not_authorized' end
    if not report.identityOffDutyAllowed then report.failedGates[#report.failedGates + 1] = 'identity_failed_even_with_offduty_allowed' end
    if not report.onduty then report.failedGates[#report.failedGates + 1] = 'off_duty_for_strict_dispatch' end
    if not report.noticeSeen then report.failedGates[#report.failedGates + 1] = 'speech_notice_not_seen' end
    if not report.enabled then report.failedGates[#report.failedGates + 1] = 'dispatch_disabled' end
    if report.mode ~= 'ai' and Config.EmergencyInManual ~= true then report.failedGates[#report.failedGates + 1] = 'manual_mode' end
    if report.speechConvar ~= 1 then report.failedGates[#report.failedGates + 1] = 'speech_disabled' end
    if not report.externalSpeech then report.failedGates[#report.failedGates + 1] = 'external_speech_disabled' end

    print(('[AI eligibility debug] %s'):format(json.encode(report)))
    if src > 0 then
        local summary = #report.failedGates == 0 and 'all gates passed' or table.concat(report.failedGates, ', ')
        diagnosticReply(src, ('Eligibility source %s: %s. See txAdmin for full [AI eligibility debug].'):format(target, summary))
    end
end)

RegisterCommand('dispatchpttdebug', function(src)
    if not authorized(src, Config.AdminAce) then
        if src > 0 then diagnosticReply(src, 'You do not have the ai_dispatch.admin ACE permission.') end
        return
    end

    local token = GetConvar('ai_dispatch_bridge_token', '')
    if token == '' then
        print('[AI PTT debug] worker token missing')
        return
    end

    PerformHttpRequest('http://127.0.0.1:8789/health', function(statusCode, body)
        if statusCode ~= 200 then
            print(('[AI PTT debug] worker health HTTP %s'):format(tostring(statusCode)))
            if src > 0 then diagnosticReply(src, 'PTT debug could not reach the AI worker.') end
            return
        end
        local ok, data = pcall(json.decode, body or '')
        if not ok or type(data) ~= 'table' then
            print('[AI PTT debug] invalid worker health response')
            return
        end
        local ptt = data.pttDebug or {}
        local report = {
            workerBuild = data.workerBuild,
            radioConnected = data.radioConnected,
            voiceEnabled = data.voiceEnabled,
            eligibleUnits = data.eligibleUnits,
            lastSttError = data.lastSttError,
            lastSttStage = data.lastSttStage,
            lastSttAt = data.lastSttAt,
            lastSttAudio = data.lastSttAudio,
            ptt = ptt,
        }
        print(('[AI PTT debug] %s'):format(json.encode(report)))
        if src > 0 then
            diagnosticReply(src, ('PTT debug: starts=%s ends=%s voicePackets=%s authorized=%s. See txAdmin for full trace.'):format(
                tostring(ptt.pttStarts or 0), tostring(ptt.pttEnds or 0), tostring(ptt.voicePackets or 0), tostring(ptt.authorizedVoicePackets or 0)
            ))
        end
    end, 'GET', '', { ['Authorization'] = 'Bearer ' .. token })
end, false)


RegisterCommand('dispatchresponsedebug', function(src)
    if not authorized(src, Config.AdminAce) then
        if src > 0 then diagnosticReply(src, 'You do not have the ai_dispatch.admin ACE permission.') end
        return
    end

    local token = GetConvar('ai_dispatch_bridge_token', '')
    if token == '' then
        print('[AI response debug] worker token missing')
        return
    end

    PerformHttpRequest('http://127.0.0.1:8789/health', function(statusCode, body)
        if statusCode ~= 200 then
            print(('[AI response debug] worker health HTTP %s'):format(tostring(statusCode)))
            if src > 0 then diagnosticReply(src, 'Response debug could not reach the AI worker.') end
            return
        end
        local ok, data = pcall(json.decode, body or '')
        if not ok or type(data) ~= 'table' then
            print('[AI response debug] invalid worker health response')
            return
        end
        local report = {
            workerBuild = data.workerBuild,
            ready = data.ready,
            radioConnected = data.radioConnected,
            voiceEnabled = data.voiceEnabled,
            eligibleUnits = data.eligibleUnits,
            ttsProvider = data.ttsProvider,
            lastDeliveryError = data.lastDeliveryError,
            lastDeliveryStage = data.lastDeliveryStage,
            lastDeliverySuccessAt = data.lastDeliverySuccessAt,
            lastDeliveryFailureAt = data.lastDeliveryFailureAt,
            response = data.responseDebug or {},
            lastTranscript = data.pttDebug and data.pttDebug.lastTranscript or nil,
        }
        print(('[AI response debug] %s'):format(json.encode(report)))
        if src > 0 then
            local r = report.response or {}
            diagnosticReply(src, ('Response debug: queued=%s delivered=%s failed=%s. See txAdmin for full [AI response debug].'):format(
                tostring(r.queued or 0), tostring(r.delivered or 0), tostring(r.failed or 0)
            ))
        end
    end, 'GET', '', { ['Authorization'] = 'Bearer ' .. token })
end, false)

RegisterCommand('dispatchspeechhealth', function(src)
    if not authorized(src, Config.AdminAce) then
        if src > 0 then diagnosticReply(src, 'You do not have the ai_dispatch.admin ACE permission.') end
        print('[AI dispatch] dispatchspeechhealth denied actor=' .. tostring(src) .. ' missing ACE=' .. tostring(Config.AdminAce))
        return
    end

    local token = GetConvar('ai_dispatch_bridge_token', '')
    if token == '' then
        local msg = 'Speech health FAILED: ai_dispatch_bridge_token is not set.'
        print('[AI dispatch] ' .. msg)
        if src > 0 then diagnosticReply(src, msg) end
        return
    end

    PerformHttpRequest('http://127.0.0.1:8789/health', function(statusCode, body)
        if statusCode ~= 200 then
            local msg = 'Speech health FAILED: worker HTTP ' .. tostring(statusCode) .. '. Make sure ai-dispatch-worker is running.'
            print('[AI dispatch] ' .. msg)
            if src > 0 then diagnosticReply(src, msg) end
            return
        end

        local ok, data = pcall(json.decode, body or '')
        if not ok or type(data) ~= 'table' or data.ok ~= true then
            local msg = 'Speech health FAILED: worker returned an invalid response.'
            print('[AI dispatch] ' .. msg)
            if src > 0 then diagnosticReply(src, msg) end
            return
        end

        local msg = ('Speech health OK | build=%s | ready=%s | reason=%s | TTS=%s | STT=%s | radio=%s | voice=%s | eligibleUnits=%s'):format(
            tostring(data.workerBuild or 'unknown'),
            tostring(data.ready),
            tostring(data.reason or 'unknown'),
            tostring(data.ttsProvider or 'unknown'),
            tostring(data.sttProvider or 'unknown'),
            tostring(data.radioConnected),
            tostring(data.voiceEnabled),
            tostring(data.eligibleUnits or 0)
        )
        print('[AI dispatch] ' .. msg)
        if src > 0 then diagnosticReply(src, msg) end
    end, 'GET', '', { ['Authorization'] = 'Bearer ' .. token })
end, false)

RegisterCommand('dispatchcancelpanic', function(src, args)
    if not authorized(src, Config.TakeoverAce) then return end
    -- Callsign + agency remain usable after disconnect or resource restart.
    local sign, agency = args[1], args[2]
    if not sign or not Config.Agencies[agency] then return end
    for _, l in pairs(lanes) do if l.agency == agency then
        for cid, hold in pairs(l.emergency) do if hold.sign == sign then
            l.emergency[cid] = nil
            local s = units[hold.source]
            if s and s.cid == cid then s.status = 'UNAVAILABLE'; s.activity = os.time() end
            if not next(l.emergency) then nextUnit(l) end
            print('[AI dispatch] emergency hold cancelled actor=' .. src .. ' unit=' .. sign)
        end end
    end end
    saveEmergencyHolds()
end)
RegisterNetEvent('haestorm-ai-dispatch:location', function(data)
    local src = source; local u = identity(src); local s = units[src]
    if not u or not s or not s.stop or type(data) ~= 'table' then return end
    if s.stop.location then return end
    -- Client street labels are descriptive only; GPS is always server-owned.
    local c = GetEntityCoords(GetPlayerPed(src))
    s.stop.location = { coords = { x = c.x, y = c.y, z = c.z }, street = tostring(data.street or ''):sub(1, 80), heading = GetEntityHeading(GetPlayerPed(src)) }
    if s.callId then syncTrafficStopCad(u, s, 'LOCATION', s.stop.location.street ~= '' and ('Location: '..s.stop.location.street) or 'GPS location updated') end
end)
AddEventHandler('playerDropped', function()
    local src = source
    for _, l in pairs(lanes) do
        for i = #l.queue, 1, -1 do if l.queue[i].source == src then table.remove(l.queue, i) end end
        if l.active == src then nextUnit(l) end
        -- Emergency hold deliberately persists until authorized cancellation.
    end
    units[src] = nil; rate[src] = nil; notices[src] = nil; voiceSessions[src] = nil
end)
local stored = GetResourceKvpString('usage')
if stored then local ok, value = pcall(json.decode, stored); if ok and type(value) == 'table' then usage = value end end
-- A resource restart is a fresh AI-dispatch session. Do not restore temporary
-- emergency/hold/conversation state from the previous runtime.
DeleteResourceKvp('emergencyHolds')
print('[AI TEST RESET] temporary AI state cleared; waiting to baseline existing dispatch calls')
local callsBaselined = false
CreateThread(function()
    while true do
        Wait(Config.PollSeconds * 1000)
        local now = os.time()
        for k, timestamp in pairs(dedupe) do if now - timestamp > 300 then dedupe[k] = nil end end
        for _, l in pairs(lanes) do
            local s = l.active and units[l.active]
            if not next(l.emergency) and l.active and (not s or (s.untilTime or 0) < now) then
                if s then s.pending = nil; s.voicePending = nil; s.selecting = nil end
                nextUnit(l)
            end
            for i = #l.queue, 1, -1 do if l.queue[i].expires < now then table.remove(l.queue, i) end end
        end
        for src, s in pairs(units) do
            local u = identity(src)
            local limit = Config.Welfare[s.status]
            if u and s.incidentMode and (s.incidentMode == 'VEHICLE_PURSUIT' or s.incidentMode == 'FOOT_PURSUIT') then
                local last = s.lastPursuitUpdate or s.activity or now
                if now - last >= Config.PursuitUpdateSeconds and (not s.lastPursuitPrompt or now - s.lastPursuitPrompt >= Config.PursuitPromptCooldown) then
                    s.lastPursuitPrompt = now
                    reply(u, 'update location.', true)
                end
            end
            local activePursuit = s.incidentMode == 'VEHICLE_PURSUIT' or s.incidentMode == 'FOOT_PURSUIT'
            if u and limit and not activePursuit and now - s.activity >= limit then
                if not s.welfare then
                    s.welfare = now; s.welfareStage = 1
                    local msg = s.status == 'TRAFFIC_STOP' and 'status?' or (s.status == 'EMERGENCY' and 'you code 4?' or 'status?')
                    reply(u, msg, s.status == 'EMERGENCY')
                elseif s.welfare > 0 and s.welfareStage == 1 and now - s.welfare > Config.WelfareResponseSeconds then
                    s.welfare = now; s.welfareStage = 2
                    reply(u, 'second call, advise status.', true)
                elseif s.welfare > 0 and s.welfareStage == 2 and now - s.welfare > Config.WelfareEscalationSeconds then
                    reply(u, 'no response. Available unit or supervisor, check this unit.', true); s.welfare = -1; s.welfareStage = 3
                end
            end
        end
        local all = DispatchBridge.calls()
        if all then
            local live = {}
            -- First successful poll after resource start establishes a baseline.
            -- Existing ps-dispatch calls are NOT new AI announcements.
            if not callsBaselined then
                local baselineCount = 0
                for _, c in pairs(all) do live[c.id] = true; baselineCount = baselineCount + 1 end
                seenCalls = live
                callsBaselined = true
                print(('[AI TEST RESET] baseline complete; existingCalls=%s; dispatcher ready for NEW traffic'):format(tostring(baselineCount)))
            else
            for _, c in pairs(all) do
                live[c.id] = true
                if not seenCalls[c.id] then
                    for agency, cfg in pairs(Config.Agencies) do
                        local jobMatch = false
                        for _, j in ipairs(c.jobs or {}) do if cfg.jobs[j] or (agency == 'police' and j == 'leo') or (agency == 'ems' and j == 'ems') then jobMatch = true end end
                        if jobMatch then
                            -- v0.4.16.2: in shared-LEO mode, all-unit call announcements transmit once
                            -- on the primary dispatch frequency. Officers on department primaries hear
                            -- that traffic through tRadio scan instead of receiving duplicate TTS on
                            -- every subscribed frequency.
                            if agency == 'police' and Config.SharedLeoRadio == true then
                                local channel = tonumber(Config.PrimaryDispatchFrequency) or 100
                                if cfg.channels[channel] then
                                    local l = lane({ agency = agency, channel = channel })
                                    l.announcements[#l.announcements + 1] = c.id
                                end
                            else
                                for channel in pairs(cfg.channels) do
                                    local l = lane({ agency = agency, channel = channel })
                                    l.announcements[#l.announcements + 1] = c.id
                                end
                            end
                        end
                    end
                end
            end
            end -- callsBaselined
            seenCalls = live
            for _, l in pairs(lanes) do
                for i = #l.announcements, 1, -1 do if not live[l.announcements[i]] then table.remove(l.announcements, i) end end
                if enabled and mode == 'ai' and not next(l.emergency) and not l.active and l.announcements[1] then
                    for _, c in pairs(all) do if c.id == l.announcements[1] then
                        local announcement = ('All available units, call %s, priority %s, %s at %s. Advise if responding.'):format(c.id, c.priority or 'unknown', c.message or 'incident', c.street or 'unknown location')
                        local ok = broadcastSpeak(l, announcement, false, 'new_dispatch_call')
                        if ok then l.latest = c.id; table.remove(l.announcements, 1) end
                        break
                    end end
                end
            end
        end
    end
end)



-- v0.4.28: live pursuit GPS. Attached pursuit units update CAD silently;
-- the primary unit moves the active pursuit blip while secondary/support GPS
-- remains available to the pursuit board. Voice traffic is not required.
CreateThread(function()
    while true do
        Wait(1500)
        for src, st in pairs(units) do
            if st and st.callId and (st.incidentMode == 'VEHICLE_PURSUIT' or st.incidentMode == 'FOOT_PURSUIT') then
                local u = identity(src)
                if u then
                    pcall(function()
                        DispatchBridge.action(src, 'incident_gps', st.callId, { incidentMode = st.incidentMode })
                    end)
                end
            end
        end
    end
end)

-- v0.4.9: authoritative ps-dispatch reconciliation failsafe.
-- Event sync remains instant; this loop repairs missed UI/event paths.
local function reconcileDispatchState(src, state)
    if not state or not state.callId then return end
    -- Newly-created emergency calls can take a moment to finish their ps-dispatch
    -- attachment path. Never interpret that propagation window as a real clear.
    if state.dispatchAttachGraceUntil and os.time() < state.dispatchAttachGraceUntil then return end
    local player = QB.Functions.GetPlayer(src)
    if not player then return end

    local ok, snapshot = DispatchBridge.dispatchState(src)
    if not ok or type(snapshot) ~= 'table' then
        if Config.UnderstandingDebug then
            print(('[AI TEST RECONCILE] %s'):format(json.encode({
                source=src, expectedCall=state.callId, result='QUERY_FAILED',
                error=tostring(snapshot), time=os.time()
            })))
        end
        return
    end

    local authoritativeCall = tonumber(snapshot.attachedCallId)
    if authoritativeCall == tonumber(state.callId) then return end

    local oldCall = state.callId
    local cid = player.PlayerData.citizenid
    state.callId = authoritativeCall
    state.dispatchAttachGraceUntil = nil
    state.stop = nil
    state.awaitDisposition = nil
    state.pending = nil
    state.voicePending = nil
    state.waitingPlate = nil
    state.welfare = nil
    state.selecting = nil

    for _, l in pairs(lanes) do l.emergency[cid] = nil end
    saveEmergencyHolds()

    if authoritativeCall then
        if state.status == 'EMERGENCY' then state.status = 'RESPONDING' end
    else
        state.status = 'AVAILABLE'
        CreateThread(function()
            pcall(function() DispatchBridge.status(src, 'AVAILABLE') end)
        end)
    end

    print(('[AI TEST RECONCILE] %s'):format(json.encode({
        source=src,
        unit=(player.PlayerData.metadata and player.PlayerData.metadata.callsign),
        previousCall=oldCall,
        authoritativeCall=authoritativeCall,
        result=authoritativeCall and 'CALL_CHANGED' or 'CLEARED_FROM_PS_DISPATCH',
        status=state.status,
        welfare='CANCELLED',
        emergency=false,
        time=os.time()
    })))
end

CreateThread(function()
    while true do
        Wait(3000)
        for src, state in pairs(units) do
            if state and state.callId then
                reconcileDispatchState(src, state)
            end
        end
    end
end)

