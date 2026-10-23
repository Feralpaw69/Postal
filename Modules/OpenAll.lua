local Postal = LibStub("AceAddon-3.0"):GetAddon("Postal")
local Postal_OpenAll = Postal:NewModule("OpenAll", "AceEvent-3.0")
local L = LibStub("AceLocale-3.0"):GetLocale("Postal")
Postal_OpenAll.description = L["A button that collects all attachments and coins from mail."]
Postal_OpenAll.description2 = L[ [[|cFFFFCC00*|r Simple filters are available for various mail types.
|cFFFFCC00*|r Shift-Click the Open All button to override the filters and take ALL mail.
|cFFFFCC00*|r OpenAll will never delete any mail (mail without text is auto-deleted by the game when all attached items and gold are taken).
|cFFFFCC00*|r OpenAll will skip CoD mails and mails from Blizzard.
|cFFFFCC00*|r Disable the Verbose option to stop the chat spam while opening mail.]] ]

------------------------------------------------------------------------
-- FAST OPEN ALL
-- The original code sent one request, then polled every 0.5s until the
-- server confirmed it before sending the next one. This version sends the
-- requests back to back (like spam-clicking) going from the last mail to
-- the first, so deleted mails never shift the ones still to do. When it
-- reaches the top it waits a moment and does a check pass: anything the
-- server dropped is picked up again.
------------------------------------------------------------------------
local STEP_DELAY   = 0.10  -- seconds between two take requests (lower = faster, 0.05 is the practical minimum)
local VERIFY_DELAY = 0.80  -- wait for the server to catch up before the check pass
local BAG_RECHECK  = 0.50  -- wait before re-counting bag space when the estimate runs out
local MAX_PASSES   = 6

local mailIndex, attachIndex
local origNumItems, origTotalItems
local pass, lastRemaining
local freeSlots, bagRechecked
local skipFlag
local invFull
local openAllOverride
local button
local Postal_OpenAllMenuButton

-- Frame that drives the loop
local updateFrame = CreateFrame("Frame")
updateFrame:Hide()
updateFrame.time = 0
updateFrame:SetScript("OnUpdate", function(self, elapsed)
	self.time = self.time - elapsed
	if self.time <= 0 then
		self:Hide()
		local f = self.func
		self.func = nil
		if f then f(Postal_OpenAll) end
	end
end)

local function Schedule(delay, func)
	updateFrame.time = delay
	updateFrame.func = func
	updateFrame:Show()
end

-- Frame to refresh the Inbox
-- I'm cheap so instead of trying to track 60 or so seconds since the
-- last CheckInbox(), I just call CheckInbox() every 10 seconds
local refreshFrame = CreateFrame("Frame", nil, MailFrame)
refreshFrame:Hide()
refreshFrame:SetScript("OnShow", function(self)
	self.time = 10
end)
refreshFrame:SetScript("OnUpdate", function(self, elapsed)
	self.time = self.time - elapsed
	if self.time <= 0 then
		self.time = 10
		Postal:Print(L["Refreshing mailbox..."])
		CheckInbox()
		local current, total = GetInboxNumItems()
		if current == 50 or current == total then
			-- If we're here, then mailbox contains a full fresh 50 or
			-- we're showing all the mail we have, so continue open all
			self:Hide()
			Postal_OpenAll:OpenAll(true)
		end
	end
end)

local function CountFreeBagSlots()
	local free = 0
	for bag = 0, NUM_BAG_SLOTS do
		local bagFree, bagFam = GetContainerNumFreeSlots(bag)
		if bagFam == 0 then
			free = free + bagFree
		end
	end
	return free
end

-- Returns msgMoney, msgItem, msgSubject if this mail should be opened, nil if it is filtered out
local function ShouldOpen(i)
	local sender, msgSubject, msgMoney, msgCOD, _, msgItem, _, _, msgText, _, isGM = select(3, GetInboxHeaderInfo(i))
	if not msgSubject and not sender then return end
	-- Skip mail if it contains a CoD or if its from a GM
	if (msgCOD and msgCOD > 0) or isGM then
		skipFlag = true
		return
	end
	local mailType = Postal:GetMailType(msgSubject)
	if mailType == "NonAHMail" then
		-- Skip player sent mail with attachments according to user options
		if not (openAllOverride or Postal.db.profile.OpenAll.Attachments) and msgItem then
			return
		end
	else
		-- AH mail, check if its from faction or neutral AH
		local factionEnglish, factionLocale = UnitFactionGroup("player")
		if not strfind(sender or "", factionLocale) then
			mailType = "Neutral"..mailType
		end
		if not (openAllOverride or Postal.db.profile.OpenAll[mailType]) then
			return
		end
	end
	return msgMoney or 0, msgItem, msgSubject
end

-- How much is still left to take (used to decide if another pass is worth it)
local function CountRemaining()
	local n = 0
	for i = 1, GetInboxNumItems() do
		local money, items = ShouldOpen(i)
		if money then
			if money > 0 then n = n + 1 end
			if items and not invFull then n = n + items end
		end
	end
	return n
end

function Postal_OpenAll:OnEnable()
	if not button then
		button = CreateFrame("Button", "PostalOpenAllButton", InboxFrame, "UIPanelButtonTemplate")
		button:SetWidth(120)
		button:SetHeight(25)
		if GetLocale() == "frFR" then
			button:SetPoint("CENTER", InboxFrame, "TOP", -32, -410)
		else
			button:SetPoint("CENTER", InboxFrame, "TOP", -22, -410)
		end
		button:SetText(L["Open All"])
		button:SetScript("OnClick", function() Postal_OpenAll:OpenAll() end)
		button:SetFrameLevel(button:GetFrameLevel() + 1)
	end
	if not Postal_OpenAllMenuButton then
		-- Create the Menu Button
		Postal_OpenAllMenuButton = CreateFrame("Button", "Postal_OpenAllMenuButton", InboxFrame);
		Postal_OpenAllMenuButton:SetWidth(30);
		Postal_OpenAllMenuButton:SetHeight(30);
		Postal_OpenAllMenuButton:SetPoint("LEFT", button, "RIGHT", -2, 0);
		Postal_OpenAllMenuButton:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIcon-ScrollDown-Up");
		Postal_OpenAllMenuButton:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Round");
		Postal_OpenAllMenuButton:SetDisabledTexture("Interface\\ChatFrame\\UI-ChatIcon-ScrollDown-Disabled");
		Postal_OpenAllMenuButton:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIcon-ScrollDown-Down");
		Postal_OpenAllMenuButton:SetScript("OnClick", function(self, button, down)
			if Postal_DropDownMenu.initialize ~= Postal_OpenAll.ModuleMenu then
				CloseDropDownMenus()
				Postal_DropDownMenu.initialize = Postal_OpenAll.ModuleMenu
			end
			ToggleDropDownMenu(1, nil, Postal_DropDownMenu, self:GetName(), 0, 0)
		end)
		Postal_OpenAllMenuButton:SetFrameLevel(Postal_OpenAllMenuButton:GetFrameLevel() + 1)
	end

	self:RegisterEvent("MAIL_SHOW")
	-- For enabling after a disable
	button:Show()
	Postal_OpenAllMenuButton:SetScript("OnHide", Postal_DropDownMenu.HideMenu)
	Postal_OpenAllMenuButton:Show()
end

function Postal_OpenAll:OnDisable()
	self:Reset()
	button:Hide()
	Postal_OpenAllMenuButton:SetScript("OnHide", nil)
	Postal_OpenAllMenuButton:Hide()
end

function Postal_OpenAll:MAIL_SHOW()
	self:RegisterEvent("MAIL_CLOSED", "Reset")
	self:RegisterEvent("PLAYER_LEAVING_WORLD", "Reset")
end

function Postal_OpenAll:OpenAll(isRecursive)
	refreshFrame:Hide()
	updateFrame:Hide()
	origNumItems, origTotalItems = GetInboxNumItems()
	invFull = nil
	skipFlag = false
	pass = 1
	lastRemaining = nil
	if not isRecursive then openAllOverride = IsShiftKeyDown() end
	if origNumItems == 0 then
		return
	end

	Postal:DisableInbox(1)
	button:SetText(L["In Progress"])
	self:RegisterEvent("UI_ERROR_MESSAGE")
	self:StartPass()
end

function Postal_OpenAll:StartPass()
	mailIndex = GetInboxNumItems()
	attachIndex = nil
	freeSlots = CountFreeBagSlots()
	bagRechecked = false
	self:ProcessNext()
end

-- Called after waiting for the bags to update
function Postal_OpenAll:RecheckBags()
	freeSlots = CountFreeBagSlots()
	bagRechecked = true
	self:ProcessNext()
end

function Postal_OpenAll:ProcessNext()
	while mailIndex > 0 do
		local msgMoney, msgItem, msgSubject = ShouldOpen(mailIndex)
		if not msgMoney then
			-- filtered / CoD / GM / gone
			mailIndex = mailIndex - 1
			attachIndex = nil
		else
			if not attachIndex then
				-- first time we touch this mail in this pass
				attachIndex = ATTACHMENTS_MAX_RECEIVE
				if pass == 1 and Postal.db.profile.OpenAll.SpamChat and (not invFull or msgMoney > 0) and (msgMoney > 0 or msgItem) then
					local moneyString = msgMoney > 0 and " ["..Postal:GetMoneyString(msgMoney).."]" or ""
					Postal:Print(format("%s %d: %s%s", L["Processing Message"], mailIndex, msgSubject or "", moneyString))
				end
			end

			-- Items first (backwards, so slots never shift)
			if msgItem and not invFull then
				while attachIndex > 0 and not GetInboxItemLink(mailIndex, attachIndex) do
					attachIndex = attachIndex - 1
				end
				if attachIndex > 0 then
					local keep = Postal.db.profile.OpenAll.KeepFreeSpace
					if keep > 0 and freeSlots <= keep then
						if not bagRechecked then
							-- our estimate ran out; let the bags catch up and count for real
							return Schedule(BAG_RECHECK, self.RecheckBags)
						end
						invFull = true
						Postal:Print(format(L["Not taking more items as there are now only %d regular bagslots free."], freeSlots))
					else
						TakeInboxItem(mailIndex, attachIndex)
						freeSlots = freeSlots - 1
						bagRechecked = false
						attachIndex = attachIndex - 1
						return Schedule(STEP_DELAY, self.ProcessNext)
					end
				end
			end

			-- Then the money, then move on to the next mail
			local idx = mailIndex
			mailIndex = mailIndex - 1
			attachIndex = nil
			if msgMoney > 0 then
				TakeInboxMoney(idx)
				return Schedule(STEP_DELAY, self.ProcessNext)
			end
		end
	end

	-- Reached the top of the inbox: let the server catch up, then check pass
	Schedule(VERIFY_DELAY, self.FinishPass)
end

function Postal_OpenAll:FinishPass()
	local remaining = CountRemaining()
	if remaining > 0 and pass < MAX_PASSES and (not lastRemaining or remaining < lastRemaining) then
		-- Something was dropped by the server (or still in flight), go again
		lastRemaining = remaining
		pass = pass + 1
		return self:StartPass()
	end

	-- If the numbers are different from previously
	local numItems, totalItems = GetInboxNumItems()
	if origNumItems ~= numItems or origTotalItems ~= totalItems then
		-- We only want to refresh if there's more items to show
		if (totalItems > numItems and numItems < 50) or (origTotalItems > origNumItems) then
			Postal:Print(L["Not all messages are shown, refreshing mailbox soon to continue Open All..."])
			refreshFrame:Show()
			return
		end
	end

	if IsAddOnLoaded("MrPlow") then
		if MrPlow.DoStuff then
			MrPlow:DoStuff("stack")
		elseif MrPlow.ParseInventory then -- Backwards compat
			MrPlow:ParseInventory()
		end
	end
	if skipFlag then Postal:Print(L["Some Messages May Have Been Skipped."]) end
	self:Reset()
end

function Postal_OpenAll:Reset(event)
	refreshFrame:Hide()
	updateFrame:Hide()
	updateFrame.func = nil
	self:UnregisterEvent("UI_ERROR_MESSAGE")
	button:SetText(L["Open All"])
	Postal:DisableInbox()
	InboxFrame_Update()
	if event == "MAIL_CLOSED" or event == "PLAYER_LEAVING_WORLD" then
		self:UnregisterEvent("MAIL_CLOSED")
		self:UnregisterEvent("PLAYER_LEAVING_WORLD")
	end
end

function Postal_OpenAll:UI_ERROR_MESSAGE(event, error_message)
	if error_message == ERR_INV_FULL then
		invFull = true
	end
	-- ERR_ITEM_MAX_COUNT (unique items): the item just stays in the mail;
	-- the check pass sees no progress on it and stops.
end

function Postal_OpenAll.SetKeepFreeSpace(dropdownbutton, arg1)
	Postal.db.profile.OpenAll.KeepFreeSpace = arg1
end

function Postal_OpenAll.ModuleMenu(self, level)
	if not level then return end
	local info = self.info
	wipe(info)
	info.isNotRadio = 1
	local db = Postal.db.profile.OpenAll
	
	if level == 1 + self.levelAdjust then
		info.hasArrow = 1
		info.keepShownOnClick = 1
		info.func = self.UncheckHack
		info.notCheckable = 1

		info.text = FACTION.." "..L["AH-related mail"]
		info.value = "AHMail"
		UIDropDownMenu_AddButton(info, level)

		info.text = FACTION_STANDING_LABEL4.." "..L["AH-related mail"]
		info.value = "NeutralAHMail"
		UIDropDownMenu_AddButton(info, level)

		info.text = L["Non-AH related mail"]
		info.value = "NonAHMail"
		UIDropDownMenu_AddButton(info, level)

		info.text = L["Other options"]
		info.value = "OtherOptions"
		UIDropDownMenu_AddButton(info, level)

	elseif level == 2 + self.levelAdjust then

		info.keepShownOnClick = 1
		info.func = Postal.SaveOption
		info.arg1 = "OpenAll"

		if UIDROPDOWNMENU_MENU_VALUE == "AHMail" then
			info.text = L["Open all Auction cancelled mail"]
			info.arg2 = "AHCancelled"
			info.checked = db.AHCancelled
			UIDropDownMenu_AddButton(info, level)

			info.text = L["Open all Auction expired mail"]
			info.arg2 = "AHExpired"
			info.checked = db.AHExpired
			UIDropDownMenu_AddButton(info, level)

			info.text = L["Open all Outbid on mail"]
			info.arg2 = "AHOutbid"
			info.checked = db.AHOutbid
			UIDropDownMenu_AddButton(info, level)

			info.text = L["Open all Auction successful mail"]
			info.arg2 = "AHSuccess"
			info.checked = db.AHSuccess
			UIDropDownMenu_AddButton(info, level)

			info.text = L["Open all Auction won mail"]
			info.arg2 = "AHWon"
			info.checked = db.AHWon
			UIDropDownMenu_AddButton(info, level)

		elseif UIDROPDOWNMENU_MENU_VALUE == "NeutralAHMail" then
			info.text = L["Open all Auction cancelled mail"]
			info.arg2 = "NeutralAHCancelled"
			info.checked = db.NeutralAHCancelled
			UIDropDownMenu_AddButton(info, level)

			info.text = L["Open all Auction expired mail"]
			info.arg2 = "NeutralAHExpired"
			info.checked = db.NeutralAHExpired
			UIDropDownMenu_AddButton(info, level)

			info.text = L["Open all Outbid on mail"]
			info.arg2 = "NeutralAHOutbid"
			info.checked = db.NeutralAHOutbid
			UIDropDownMenu_AddButton(info, level)

			info.text = L["Open all Auction successful mail"]
			info.arg2 = "NeutralAHSuccess"
			info.checked = db.NeutralAHSuccess
			UIDropDownMenu_AddButton(info, level)

			info.text = L["Open all Auction won mail"]
			info.arg2 = "NeutralAHWon"
			info.checked = db.NeutralAHWon
			UIDropDownMenu_AddButton(info, level)

		elseif UIDROPDOWNMENU_MENU_VALUE == "NonAHMail" then
			info.text = L["Open all mail with attachments"]
			info.arg2 = "Attachments"
			info.checked = db.Attachments
			UIDropDownMenu_AddButton(info, level)

		elseif UIDROPDOWNMENU_MENU_VALUE == "OtherOptions" then
			info.text = L["Keep free space"]
			info.hasArrow = 1
			info.value = "KeepFreeSpace"
			info.func = self.UncheckHack
			UIDropDownMenu_AddButton(info, level)
			local listFrame = _G["DropDownList"..level]
			self.UncheckHack(_G[listFrame:GetName().."Button"..listFrame.numButtons])

			info.text = L["Verbose mode"]
			info.hasArrow = nil
			info.value = nil
			info.func = Postal.SaveOption
			info.arg2 = "SpamChat"
			info.checked = db.SpamChat
			UIDropDownMenu_AddButton(info, level)
		end

	elseif level == 3 + self.levelAdjust then
		if UIDROPDOWNMENU_MENU_VALUE == "KeepFreeSpace" then
			local keepFree = db.KeepFreeSpace
			info.func = Postal_OpenAll.SetKeepFreeSpace
			info.isNotRadio = nil
			for _, v in ipairs(Postal.keepFreeOptions) do
				info.text = v
				info.checked = v == keepFree
				info.arg1 = v
				UIDropDownMenu_AddButton(info, level)
			end
		end
	end
end
