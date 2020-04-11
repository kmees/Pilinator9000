Pilinator9000 = LibStub("AceAddon-3.0"):NewAddon("Pilinator9000",
                                                 "AceConsole-3.0",
                                                 "AceEvent-3.0", "AceComm-3.0",
                                                 "AceSerializer-3.0",
                                                 "AceTimer-3.0")

local Addon = Pilinator9000

local RAID_TYPES = {
  summon = 1,
  kill = 2,
  pvp = 3,
  ashenvale = 10,
  duskwood = 11,
  feralas = 12,
  hinterlands = 13
}

function Addon:OnInitialize()
  self.db = LibStub("AceDB-3.0"):New("Pilinator9000DB")
  self.db.global.addonUsers = self.db.global.addonUsers or {}
  self.hidden = false
  self.officer = false

  self:Reset()

  self:RegisterComm("pilinator", "CommHandler")
  self:RegisterComm("unitscan", "UnitscanHandler")
  self:RegisterEvent("PARTY_INVITE_REQUEST", "HandleGroupInvite")
  self:RegisterEvent("GROUP_ROSTER_UPDATE", "HandleRosterUpdate")

  self:WaitForGuildInfo(60)
end

function Addon:WaitForGuildInfo(retries)
  retries = retries or 0

  local gName, _, gRank = GetGuildInfo("player")
  self:Debug('WaitForGuildInfo: ' .. tostring(gName) .. ':' .. tostring(gRank))

  if gName ~= nil then
    self.officer = gRank <= 1
    self:InitializeUI()

    self:Broadcast({action = 'get_info', leader = UnitIsGroupLeader("player")})
  elseif retries > 0 then
    self:ScheduleTimer(function() Addon:WaitForGuildInfo(retries - 1) end, 1)
  end
end

-- ******************
-- * COMM HANDLERS *
-- ******************

do
  local forceShow = true
  function Addon:UnitscanHandler(prefix, msg, channel)
    if prefix ~= 'unitscan' then return end

    self:Show(3, forceShow)

    forceShow = false
  end
end

function Addon:CommHandler(prefix, serializedMsg, channel, sender)
  if prefix ~= 'pilinator' then return end

  self:Debug("CommHandler: " .. sender .. ', ' .. serializedMsg)

  local success, msg = self:Deserialize(serializedMsg)

  if not success then return end

  local player = UnitName('player')

  if msg.action == 'join' and msg.raidType == self.raidType and sender ~= player then
    if (IsInRaid() and self:PlayerIsLeader()) or self.creating then
      InviteUnit(sender)
    end
  end

  if msg.action == 'convert' then
    -- case 1: player is new leader or in group with new leader
    if player == msg.leader or self:UnitIsInRaid(msg.leader) then
      self.raidType = msg.raidType

      if UnitIsGroupLeader('player') then self:InitializeRaid() end
      -- case 2: player is in old raid
    elseif msg.raidType == self.raidType then
      self:JoinOrCreateRaid(msg.raidType, math.random(5) + 2)
    end
  end

  if msg.action == 'update' and msg.raidType ~= nil then
    self.raidSizes[msg.raidType] = msg.raidSize
  end

  if msg.action == 'left' then
    self.raidSizes[msg.raidType] = 0

    if (self.raidType == msg.raidType and self:PlayerIsLeader()) then
      self:Broadcast({
        action = 'update',
        raidType = self.raidType,
        raidSize = GetNumGroupMembers()
      })
    end
  end

  if msg.action == 'get_info' then
    if self:IsActive() and self:PlayerIsLeader(msg.leader) then
      self:Broadcast({
        action = 'info',
        inRaid = Addon:UnitIsInRaid(sender),
        raidType = self.raidType,
        raidSizes = self.raidSizes
      }, "WHISPER", sender)
    end
  end

  if msg.action == 'info' then
    self:SetAddonUser(sender)

    if msg.inRaid then self.raidType = msg.raidType end
    self.raidSizes = msg.raidSizes

    self:Show(10)
  end

  if msg.action == 'request_leader' and self.raidType == msg.raidType and
    UnitIsGroupLeader('player') then self:PromoteLeader(sender) end

  if msg.action == 'announce' and self:PlayerIsLeader() then
    if not self.lastAnnounce or GetTime() - self.lastAnnounce > 10 then
      self.lastAnnounce = GetTime()

      local chatMsg = self:GetRaidNameWithSize(self.raidType,
                                               GetNumGroupMembers()) ..
                        ': whisper ' .. UnitName("player") ..
                        ' \'pili\' for invite!'

      SendChatMessage(chatMsg, "GUILD")
    end
  end

  if msg.action == 'request_sync' then self:Broadcast({action = 'sync'}) end

  if msg.action == 'sync' then self:SetAddonUser(sender) end
end

-- ******************
-- * EVENT HANDLERS *
-- ******************

function Addon:HandleGroupInvite()
  self:Debug('HandleGroupInvite')

  if (self.joining) then
    self.creating = false
    self.switching = false
    AcceptGroup()
  else
    self.invited = true
  end
end

function Addon:HandleRosterUpdate()
  self:Debug('HandleRosterUpdate')

  if not IsInGroup() then
    if (self.leader and self.raidType ~= nil) then
      self:Broadcast({action = 'left', raidType = self.raidType})
    end
    if not self.switching then
      self:Reset()
      self:Broadcast({action = 'get_info'})
    end

    self.leader = false
  end

  if self.invited and IsInRaid() then
    self.invited = false

    self:Broadcast({action = 'get_info'})
  end

  if (self.joining) then
    StaticPopup_Hide("PARTY_INVITE")
    self.joining = false
    self.creating = false
    self.switching = false
  end

  if (UnitIsGroupLeader('player')) then
    self.leader = true

    if (IsInGroup() and not IsInRaid() and self:IsActive()) then
      self:InitializeRaid()
    end
  else
    self.leader = false
  end

  if (self:PlayerIsLeader()) then
    local raidSize = GetNumGroupMembers()
    if (IsInGroup() and self.raidSizes[self.raidType] ~= raidSize) then
      self.raidSizes[self.raidType] = raidSize
      self:Broadcast({
        action = 'update',
        raidType = self.raidType,
        raidSize = raidSize
      })

      if (UnitIsGroupLeader("player")) then self:PromoteAssistantAll() end
    end
  end
end

-- ****************
-- * USER ACTIONS *
-- ****************

function Addon:JoinOrCreateRaid(raidType, delay)
  self:Debug("JoinOrCreateRaid: " .. raidType)

  if (raidType == nil) then return end

  if IsInGroup() then
    self.switching = self.raidType ~= nil
    LeaveParty()

    self:ScheduleTimer(function() self:JoinOrCreateRaid(raidType) end,
                       delay or 1)
  else
    self.joining = true
    self.creating = true
    self.raidType = raidType

    self:Broadcast({action = 'join', raidType = raidType})
  end
end

function Addon:ConfirmConvertRaid(raidType)
  StaticPopup_Show('PILINATOR_CONFIRM_CONVERT_' .. tostring(raidType))
end

function Addon:ConvertRaid(raidType)
  self:Debug("ConvertRaid: " .. raidType)

  if (raidType == nil) then return end

  if (UnitIsGroupLeader('player')) then
    self:Broadcast({action = 'update', raidType = self.raidType, raidSize = 0})

    self.joining = false
    self.creating = false
    self.raidType = raidType

    self:Broadcast({
      action = 'convert',
      raidType = raidType,
      leader = UnitName("player")
    })
  end
end

function Addon:CanRequestLeader()
  if self.creating or self.joining or not self.officer then return false end

  return not UnitIsGroupLeader('player') or not self:PlayerIsMasterLooter()
end

function Addon:RequestLeader()
  self:Broadcast({action = 'request_leader', raidType = self.raidType})
end

function Addon:AnnounceRaids()
  if self.officer then self:Broadcast({action = 'announce'}) end
end

function Addon:RequestSync()
  if self.officer then self:Broadcast({action = 'request_sync'}) end
end

-- *******
-- * UI *
-- *******

do
  local names = {'Summon', 'Kill', 'PvP'}

  local function padSize(size)
    if size == nil or size <= 0 then return '00' end
    if size < 10 then return '0' .. size end
    return '' .. size
  end

  function Addon:GetRaidTitle(index, size)
    local prefix = ''

    if (self.raidType == index) then prefix = '* ' end

    return prefix .. self:GetRaidNameWithSize(index, size)
  end

  function Addon:GetRaidNameWithSize(index, size)
    return '[' .. padSize(size) .. '/40] ' .. names[index] .. ' Raid'
  end

  function Addon:GetRaidName(index) return names[index] .. ' Raid' end

  function Addon:GetJoinRaidLabel(index) return 'Join ' .. names[index] end
end

function Addon:InitializeUI()
  self:Debug("InitializeUI")

  self.ui = {window = nil, raids = {}}

  do
    local AceGUI = LibStub("AceGUI-3.0")

    -- Create a container window
    local width = 250
    local height = 135
    if self.officer then
      width = width + 130
      height = height + 32
    end
    local window = AceGUI:Create("Window")
    window:SetCallback("OnClose", function(widget)
      self.hidden = true
      window:Hide()
      -- AceGUI:Release(widget)
      -- Addon.frame = nil
    end)
    window:SetTitle("Pilinator 9000")
    window:EnableResize(false)
    window:SetWidth(width)
    window:SetHeight(height)
    window:SetLayout("Flow")
    window.frame:SetClampedToScreen(true)

    if (self.db.global.window ~= nil) then
      window:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT",
                      self.db.global.window.X, self.db.global.window.Y)
      if not self.db.global.debug then window:Hide() end
    end

    self.ui.window = window

    for i = 1, 3 do
      local index = i
      self.ui.raids[index] = {}

      local g = AceGUI:Create('SimpleGroup')
      g:SetWidth(width)
      g:SetLayout('Flow')
      window:AddChild(g)

      local paddingL = AceGUI:Create('Label')
      paddingL:SetText(' ')
      paddingL:SetWidth(5)
      g:AddChild(paddingL)

      if self.officer then
        local leaderBtn = AceGUI:Create("Button")
        leaderBtn.frame:SetNormalTexture(
          "Interface\\GroupFrame\\UI-Group-LeaderIcon")
        -- leaderBtn:SetText('L')
        leaderBtn:SetWidth(24)
        leaderBtn:SetCallback("OnClick",
                              function() Addon:RequestLeader(index) end)
        g:AddChild(leaderBtn)

        local space = AceGUI:Create('Label')
        space:SetText(' ')
        space:SetWidth(5)
        g:AddChild(space)

        self.ui.raids[index].leaderBtn = leaderBtn
      end

      local title = AceGUI:Create('Label')
      title:SetText(self:GetRaidTitle(i, 0))
      title:SetWidth(130)
      g:AddChild(title)
      local joinBtn = AceGUI:Create("Button")
      joinBtn:SetText(self:GetJoinRaidLabel(i))
      joinBtn:SetWidth(90)
      joinBtn:SetCallback("OnClick",
                          function() Addon:JoinOrCreateRaid(index) end)
      g:AddChild(joinBtn)

      self.ui.raids[index].title = title
      self.ui.raids[index].joinBtn = joinBtn

      if self.officer then
        local space = AceGUI:Create('Label')
        space:SetText(' ')
        space:SetWidth(25)
        g:AddChild(space)

        local convertBtn = AceGUI:Create("Button")
        convertBtn:SetText('Convert')
        convertBtn:SetWidth(70)
        convertBtn:SetDisabled(true)
        convertBtn:SetCallback("OnClick",
                               function() Addon:ConfirmConvertRaid(index) end)
        g:AddChild(convertBtn)

        self.ui.raids[index].convertBtn = convertBtn

        StaticPopupDialogs['PILINATOR_CONFIRM_CONVERT_' .. tostring(index)] =
          {
            text = "Do you want to convert current group/raid to " ..
              self:GetRaidName(index) .. "?",
            button1 = "Yes",
            button2 = "No",
            OnAccept = function() self:ConvertRaid(index) end,
            timeout = 0,
            whileDead = true,
            hideOnEscape = true,
            preferredIndex = 3 -- avoid some UI taint, see http://www.wowace.com/announcements/how-to-avoid-some-ui-taint/
          }
      end
    end

    if self.officer then
      local g = AceGUI:Create('SimpleGroup')
      g:SetWidth(width)
      g:SetLayout('Flow')
      window:AddChild(g)

      local paddingL = AceGUI:Create('Label')
      paddingL:SetText(' ')
      paddingL:SetWidth(5)
      g:AddChild(paddingL)

      local announceBtn = AceGUI:Create("Button")
      announceBtn:SetText('Announce Raids')
      announceBtn:SetWidth(125)
      announceBtn:SetDisabled(true)
      announceBtn:SetCallback("OnClick", function() Addon:AnnounceRaids() end)
      g:AddChild(announceBtn)

      self.ui.announceBtn = announceBtn
    end
  end

  self.updateUiTimerId = self:ScheduleRepeatingTimer("UpdateUI", 1)
  self.saveUiTimerId = self:ScheduleRepeatingTimer("SaveUI", 30)
end

function Addon:SaveUI()
  local window = self.ui.window

  if (window ~= nil) then
    self.db.global.window = {
      X = window.frame:GetLeft(),
      Y = window.frame:GetTop()
    }
  end
end

function Addon:UpdateUI()
  local disableAnnounce = true

  for i = 1, 3 do
    self.ui.raids[i].title:SetText(self:GetRaidTitle(i, self.raidSizes[i]))
    disableAnnounce = disableAnnounce and
                        (self.raidSizes[i] == nil or self.raidSizes[i] == 0)

    if (self.raidType == i) then
      self.ui.raids[i].joinBtn:SetDisabled(true)

      if self.officer then
        self.ui.raids[i].convertBtn:SetDisabled(true)
        self.ui.raids[i].leaderBtn:SetDisabled(not self:CanRequestLeader())
      end
    else
      self.ui.raids[i].joinBtn:SetDisabled(false)
      if self.officer then
        self.ui.raids[i].convertBtn:SetDisabled(
          not IsInGroup() or not UnitIsGroupLeader('player'))
        self.ui.raids[i].leaderBtn:SetDisabled(true)
      end
    end
  end

  if self.officer then self.ui.announceBtn:SetDisabled(disableAnnounce) end
end

-- ***********
-- * UTILITY *
-- ***********

function Addon:Debug(payload)
  if self.db.global.debug then self:Print(payload) end
end

function Addon:InitializeRaid()
  if not IsInRaid() then ConvertToRaid() end
  SetLootMethod("master", UnitName('player'))
end

function Addon:PromoteAssistantAll()
  if (UnitIsGroupLeader('player')) then
    for i = 1, GetNumGroupMembers() do
      local name, rank = GetRaidRosterInfo(i)
      if (rank == 0) then PromoteToAssistant(name) end
    end
  end
end

function Addon:PromoteLeader(name)
  self:Debug('PromoteLeader: ' .. name)

  if (UnitIsGroupLeader('player')) then
    SetLootMethod("master", name)
    PromoteToLeader(name)
  end
end

function Addon:UnitIsInRaid(unitName)
  if IsInRaid() then
    for i = 1, GetNumGroupMembers() do
      local name = GetRaidRosterInfo(i)
      if (name == unitName) then return true end
    end

    return false
  else
    return false
  end
end

function Addon:PlayerIsLeader(leaderIsOffline)
  leaderIsOffline = leaderIsOffline or false

  if not self:IsActive() then return false end

  if IsInRaid() and UnitIsGroupLeader('player') then
    return true
  elseif IsInRaid() then
    local leaderSubstitute = nil
    for i = 1, GetNumGroupMembers() do
      local name, rank, _, _, _, _, _, online = GetRaidRosterInfo(i)

      leaderIsOffline = leaderIsOffline or (rank == 2 and not online)

      if leaderSubstitute == nil and online and rank == 1 and
        self:IsAddonUser(name) then
        -- self:Debug("Leader substitute: " .. name)
        leaderSubstitute = name
      end
    end

    return leaderIsOffline and leaderSubstitute == UnitName("player")
  else
    return false
  end
end
function Addon:PlayerIsMasterLooter()
  local loot, index = GetLootMethod()

  return loot == 'master' and index == 0
end

function Addon:Show(retries, force)
  retries = retries or 0
  force = force or false

  if self.hidden and not force then return end

  if self.ui ~= nil and self.ui.window ~= nil then
    self.hidden = false
    self.ui.window:Show()
  elseif retries > 0 then
    self:ScheduleTimer(function() Addon:Show(retries - 1) end, 1)
  end
end

function Addon:Reset()
  self:Debug("Reset")

  self.creating = false
  self.joining = false
  self.switching = false
  self.invited = false
  self.leader = false
  self.raidType = nil
  self.raidSizes = {}
end

function Addon:IsAddonUser(name)
  return self.db.global.addonUsers[name] or name == UnitName("player")
end
function Addon:SetAddonUser(name) self.db.global.addonUsers[name] = true end
function Addon:Broadcast(payload, channel, target)
  return self:SendCommMessage("pilinator", self:Serialize(payload),
                              channel or "GUILD", target)
end

function Addon:IsActive() return self.raidType ~= nil end

function Addon:Dump()
  self:Debug('debug: ' .. tostring(self.db.global.debug))
  self:Debug('leader: ' .. tostring(self.leader))
  self:Debug('creating: ' .. tostring(self.creating))
  self:Debug('joining: ' .. tostring(self.joining))
  self:Debug('switching: ' .. tostring(self.switching))
  self:Debug('officer: ' .. tostring(self.officer))
  self:Debug('raidType: ' .. tostring(self.raidType))
  self:Debug('raidSizes: ' .. tostring(self.raidSizes[1]) .. ', ' ..
               tostring(self.raidSizes[2]) .. ', ' ..
               tostring(self.raidSizes[3]))
end

-- ******************
-- * SLASH HANDLERS *
-- ******************

Addon:RegisterChatCommand("pili", "HandleSlashCmd")

function Addon:HandleSlashCmd(input)
  local action, args = strsplit(" ", input, 2)
  if (action == "reset") then
    self:Reset()
  elseif (action == "join") then
    local raidId = RAID_TYPES[args]

    if (raidId ~= nil) then self:JoinOrCreateRaid(raidId) end
  elseif (action == "convert") then
    local raidId = RAID_TYPES[args]

    if (raidId ~= nil) then self:ConvertRaid(raidId) end
  elseif (action == "dump") then
    self:Dump()
  elseif (action == "debug") then
    self.db.global.debug = not self.db.global.debug
    self:Print('Debug set to: ' .. tostring(self.db.global.debug))
  elseif (action == 'show') then
    self:Show(3, true)
  elseif (action == 'sync') then
    self:RequestSync()
  end
end
