-- Missile Tracker Arcanus for WoW 1.12

local frame = CreateFrame("Frame", "MissileTrackerArcanusFrame", UIParent)
local damageTotal = 0
local lastHitTime = 0
local lastArcaneMissilesHit = 0  -- Track last AM hit separately
local CAST_TIMEOUT = 2.05  -- Reset if no arcane spell hits for 2.05 seconds
local damageLog = {}  -- Store individual hits
local showBreakdown = false
local detailFrames = {}  -- Store icon/text frames for reuse
local MAX_DETAIL_ROWS = 15  -- Limit displayed rows
local topRecord = 0  -- Will be loaded from saved vars
local debugMode = false  -- Debug mode flag

-- Event handler for loading saved variables
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("CHAT_MSG_SPELL_SELF_DAMAGE")

-- Create the display window
local displayFrame = CreateFrame("Frame", "MTADisplay", UIParent)
displayFrame:SetWidth(220)
displayFrame:SetHeight(80)
displayFrame:SetPoint("CENTER", 0, 200)
displayFrame:SetBackdrop({
    bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
    edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
    tile = true, tileSize = 32, edgeSize = 32,
    insets = { left = 11, right = 12, top = 12, bottom = 11 }
})
displayFrame:SetMovable(true)
displayFrame:EnableMouse(true)
displayFrame:RegisterForDrag("LeftButton")
displayFrame:SetScript("OnDragStart", function() 
    if not displayFrame.isLocked then
        this:StartMoving() 
    end
end)
displayFrame:SetScript("OnDragStop", function() this:StopMovingOrSizing() end)
displayFrame.isLocked = false  -- Lock state

-- Title text
local titleText = displayFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
titleText:SetPoint("TOP", 0, -15)
titleText:SetText("Arcane Missiles")

-- Damage text
local damageText = displayFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
damageText:SetPoint("TOP", 0, -30)
damageText:SetText("0 damage")

-- Glow effect for new records (3 white layers increasing in size)
local glowLayers = {}
for layer = 1, 3 do
    -- Create 8 directional glows for each layer (4 cardinal + 4 diagonal)
    for i = 1, 8 do
        local glow = displayFrame:CreateFontString(nil, "BACKGROUND")
        glow:SetFont("Fonts\\FRIZQT__.TTF", 14)
        glow:SetPoint("TOP", 0, -30)
        glow:SetText("")
        table.insert(glowLayers, {layer = glow, size = layer})
    end
end

-- Animation state
local glowAlpha = 0
local glowDirection = 1
local shakeOffsetX = 0
local shakeOffsetY = 0
local shakeTime = 0

-- Spark effect state
local sparkTexts = {}
local activeSparks = {}
local MAX_SPARKS = 5

-- Create spark text pool
for i = 1, MAX_SPARKS do
    local spark = displayFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
    spark:SetPoint("TOP", 0, -30)
    spark:Hide()
    table.insert(sparkTexts, spark)
end

-- Record text
local recordText = displayFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
recordText:SetPoint("TOP", 0, -48)
recordText:SetTextColor(0.7, 0.7, 0.7)
recordText:SetText("")

-- Debug mode indicator
local debugText = displayFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
debugText:SetPoint("TOPRIGHT", -40, -15)
debugText:SetTextColor(1, 0, 0)
debugText:SetText("")

-- Details text (for breakdown)
local detailsContainer = CreateFrame("Frame", nil, displayFrame)
detailsContainer:SetPoint("TOP", 0, -65)
detailsContainer:SetWidth(180)
detailsContainer:SetHeight(200)

-- Function to get or create detail row
local function GetDetailFrame(index)
    if not detailFrames[index] then
        local row = CreateFrame("Frame", nil, detailsContainer)
        row:SetWidth(180)
        row:SetHeight(16)
        row:SetPoint("TOP", 0, -(index - 1) * 16)
        
        -- Icon
        local icon = row:CreateTexture(nil, "ARTWORK")
        icon:SetWidth(14)
        icon:SetHeight(14)
        icon:SetPoint("CENTER", -35, 0)
        row.icon = icon
        
        -- Damage text
        local text = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        text:SetPoint("CENTER", -18, 0)
        row.text = text
        
        detailFrames[index] = row
    end
    return detailFrames[index]
end

-- Toggle button
local toggleButton = CreateFrame("Button", nil, displayFrame)
toggleButton:SetWidth(16)
toggleButton:SetHeight(16)
toggleButton:SetPoint("TOPRIGHT", -15, -15)

-- Button icon (down arrow)
local buttonIcon = toggleButton:CreateTexture(nil, "OVERLAY")
buttonIcon:SetWidth(16)
buttonIcon:SetHeight(16)
buttonIcon:SetPoint("CENTER", 0, 0)
buttonIcon:SetTexture("Interface\\ChatFrame\\UI-ChatIcon-ScrollDown-Up")

toggleButton:SetScript("OnClick", function()
    showBreakdown = not showBreakdown
    if showBreakdown then
        buttonIcon:SetTexture("Interface\\ChatFrame\\UI-ChatIcon-ScrollUp-Up")
    else
        buttonIcon:SetTexture("Interface\\ChatFrame\\UI-ChatIcon-ScrollDown-Up")
    end
    UpdateDisplay()
end)

-- Lock button
local lockButton = CreateFrame("Button", nil, displayFrame)
lockButton:SetWidth(16)
lockButton:SetHeight(16)
lockButton:SetPoint("TOP", toggleButton, "BOTTOM", 0, -2)

-- Lock button icon
local lockIcon = lockButton:CreateTexture(nil, "OVERLAY")
lockIcon:SetWidth(16)
lockIcon:SetHeight(16)
lockIcon:SetPoint("CENTER", 0, 0)
lockIcon:SetTexture("Interface\\Icons\\Spell_Holy_SealOfValor")

lockButton:SetScript("OnClick", function()
    displayFrame.isLocked = not displayFrame.isLocked
    MissileTrackerArcanusDB.isLocked = displayFrame.isLocked  -- Save to disk
    if displayFrame.isLocked then
        lockIcon:SetTexture("Interface\\Icons\\Spell_Frost_FrostNova")
        displayFrame:EnableMouse(false)  -- Make click-through when locked
        DEFAULT_CHAT_FRAME:AddMessage("Missile Tracker Arcanus: Locked")
    else
        lockIcon:SetTexture("Interface\\Icons\\Spell_Holy_SealOfValor")
        displayFrame:EnableMouse(true)  -- Re-enable mouse when unlocked
        DEFAULT_CHAT_FRAME:AddMessage("Missile Tracker Arcanus: Unlocked")
    end
end)

-- Function to trigger shake effect
local function ShakeText()
    shakeTime = 0.15  -- Shake for 0.15 seconds
end

-- Function to get shake intensity based on damage
local function GetShakeIntensity()
    if topRecord > 0 and damageTotal > 0 then
        local progress = damageTotal / topRecord
        -- Scale from 4 to 10 as we approach/exceed record
        return 4 + (progress * 6)
    end
    return 4  -- Default shake intensity
end

-- Function to create spark effect
local function CreateSpark(damage, color)
    -- Find available spark
    local spark = nil
    for i, s in ipairs(sparkTexts) do
        if not s:IsShown() then
            spark = s
            break
        end
    end
    
    if spark then
        -- Random direction
        local angle = math.random() * 3.14159 * 2
        local distance = 40 + math.random() * 30
        
        local sparkData = {
            spark = spark,
            startTime = GetTime(),
            duration = 0.5,
            startX = 0,
            startY = -30,
            endX = math.cos(angle) * distance,
            endY = -30 + math.sin(angle) * distance,
            color = color,
            damage = damage
        }
        
        spark:SetText("+" .. damage)
        spark:SetFont("Fonts\\FRIZQT__.TTF", 16)
        spark:SetTextColor(color[1], color[2], color[3], 1)
        spark:Show()
        
        table.insert(activeSparks, sparkData)
    end
end

-- Function to update display
function UpdateDisplay()
    -- Update debug indicator
    if debugMode then
        debugText:SetText("DEBUG")
    else
        debugText:SetText("")
    end
    
    -- Show/hide background and title based on breakdown state
    if showBreakdown then
        displayFrame:SetBackdrop({
            bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
            edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
            tile = true, tileSize = 32, edgeSize = 32,
            insets = { left = 11, right = 12, top = 12, bottom = 11 }
        })
        titleText:Show()
        lockButton:Show()
    else
        displayFrame:SetBackdrop(nil)
        titleText:Hide()
        lockButton:Hide()
    end
    
    -- Calculate size and color based on progress to record
    local fontSize = 14
    local textColor = {1, 1, 1}  -- White by default
    local isNewRecord = false
    
    if topRecord > 0 and damageTotal > 0 then
        local progress = damageTotal / topRecord
        
        -- Scale font size from 14 to 24 as we approach record
        fontSize = 14 + (progress * 10)
        fontSize = math.min(fontSize, 24)  -- Cap at 24
        
        -- Arcane color transition: white -> cyan -> light blue -> purple
        if progress >= 1 then
            -- Past record - bright purple with glow
            textColor = {0.8, 0.4, 1}
            isNewRecord = true
        elseif progress >= 0.9 then
            -- 90-100% - light purple
            local t = (progress - 0.9) / 0.1
            textColor = {0.7 + (0.1 * t), 0.5 - (0.1 * t), 1}
        elseif progress >= 0.7 then
            -- 70-90% - light blue to light purple
            local t = (progress - 0.7) / 0.2
            textColor = {0.6 + (0.1 * t), 0.7 - (0.2 * t), 1}
        elseif progress >= 0.5 then
            -- 50-70% - cyan to light blue
            local t = (progress - 0.5) / 0.2
            textColor = {0.5 + (0.1 * t), 0.8 - (0.1 * t), 1}
        elseif progress >= 0.3 then
            -- 30-50% - white to cyan
            local t = (progress - 0.3) / 0.2
            textColor = {1 - (0.5 * t), 1 - (0.2 * t), 1}
        end
    end
    
    -- Store current color for spark creation
    displayFrame.currentColor = textColor
    
    -- Apply font size and color
    damageText:SetFont("Fonts\\FRIZQT__.TTF", fontSize)
    damageText:SetTextColor(textColor[1], textColor[2], textColor[3])
    damageText:SetText(damageTotal .. " damage")
    damageText:SetPoint("TOP", shakeOffsetX, -30 + shakeOffsetY)
    
    -- Apply glow effect for new records (3 white layers)
    if isNewRecord then
        local directions = {
            {x = 1, y = 0},    -- Right
            {x = -1, y = 0},   -- Left
            {x = 0, y = 1},    -- Down
            {x = 0, y = -1},   -- Up
            {x = 1, y = 1},    -- Bottom-Right
            {x = -1, y = 1},   -- Bottom-Left
            {x = 1, y = -1},   -- Top-Right
            {x = -1, y = -1}   -- Top-Left
        }
        
        local glowIndex = 1
        for layerSize = 1, 3 do
            for dirIndex = 1, 8 do
                local glowData = glowLayers[glowIndex]
                local glow = glowData.layer
                local dir = directions[dirIndex]
                
                -- Each layer increases offset and font size by 1
                local offset = layerSize
                local fontIncrease = layerSize
                
                glow:SetFont("Fonts\\FRIZQT__.TTF", fontSize + fontIncrease)
                glow:SetText(damageTotal .. " damage")
                glow:SetPoint("TOP", shakeOffsetX + (dir.x * offset), -30 + shakeOffsetY + (dir.y * offset))
                
                -- Outer layers slightly more transparent
                local alpha = glowAlpha * (0.6 - (layerSize * 0.1))
                glow:SetTextColor(1, 1, 1, alpha)
                glow:Show()
                
                glowIndex = glowIndex + 1
            end
        end
    else
        for i, glowData in ipairs(glowLayers) do
            glowData.layer:Hide()
        end
    end
    
    -- Always show record
    if topRecord > 0 then
        if damageTotal > topRecord then
            recordText:SetText("NEW RECORD!")
            recordText:SetTextColor(1, 1, 0)  -- Yellow
        else
            recordText:SetText("Record: " .. topRecord)
            recordText:SetTextColor(0.7, 0.7, 0.7)  -- Gray
        end
    else
        recordText:SetText("Record: 0")
        recordText:SetTextColor(0.7, 0.7, 0.7)  -- Gray
    end
    
    -- Hide all detail frames first
    for i, row in ipairs(detailFrames) do
        row:Hide()
    end
    
    if showBreakdown then
        -- Show breakdown with icons
        local numToShow = math.min(table.getn(damageLog), MAX_DETAIL_ROWS)
        
        for i = 1, numToShow do
            local entry = damageLog[i]
            local row = GetDetailFrame(i)
            
            -- Set icon based on source
            if entry.source == "AM" or entry.source == "AM Crit" then
                row.icon:SetTexture("Interface\\Icons\\Spell_Nature_StarFall")
            elseif entry.source == "Surge" or entry.source == "Surge Crit" then
                row.icon:SetTexture("Interface\\Icons\\INV_Enchant_EssenceMagicLarge")
            elseif entry.source == "Explosion" or entry.source == "Explosion Crit" then
                row.icon:SetTexture("Interface\\Icons\\Spell_Nature_WispSplode")
            elseif entry.source == "Rupture" or entry.source == "Rupture Crit" then
                row.icon:SetTexture("Interface\\Icons\\Spell_Shadow_ShadowWordPain")
            else
                row.icon:SetTexture("Interface\\Icons\\Spell_Nature_WispSplode")
            end
            
            -- Set text and color
            row.text:SetText(entry.damage)
            if entry.isCrit then
                row.text:SetTextColor(1, 1, 0)  -- Yellow for crits
            else
                row.text:SetTextColor(1, 1, 1)  -- White for normal hits
            end
            
            row:Show()
        end
        
        displayFrame:SetHeight(math.max(95, 85 + (numToShow * 16)))
    else
        -- Collapsed - hide details
        displayFrame:SetHeight(95)
    end
end

-- Function to reset damage counter
local function ResetDamage()
    -- Update record if we beat it
    if damageTotal > topRecord then
        topRecord = damageTotal
        MissileTrackerArcanusDB.topRecord = topRecord  -- Save to disk
    end
    
    damageTotal = 0
    damageLog = {}
    UpdateDisplay()
end

-- Event handler
frame:SetScript("OnEvent", function()
    if event == "ADDON_LOADED" and arg1 == "MissileTrackerArcanus" then
        -- Initialize saved variables
        if not MissileTrackerArcanusDB then
            MissileTrackerArcanusDB = {
                topRecord = 0,
                isLocked = false
            }
        end
        -- Load the saved record
        topRecord = MissileTrackerArcanusDB.topRecord
        
        -- Load and apply lock state
        displayFrame.isLocked = MissileTrackerArcanusDB.isLocked or false
        if displayFrame.isLocked then
            lockIcon:SetTexture("Interface\\Icons\\Spell_Frost_FrostNova")
            displayFrame:EnableMouse(false)
        else
            lockIcon:SetTexture("Interface\\Icons\\Spell_Holy_SealOfValor")
            displayFrame:EnableMouse(true)
        end
        
        UpdateDisplay()
        DEFAULT_CHAT_FRAME:AddMessage("Missile Tracker Arcanus loaded! Record: " .. topRecord)
        
    elseif event == "CHAT_MSG_SPELL_SELF_DAMAGE" then
        local currentTime = GetTime()
        local isArcaneSpell = false
        local spellSource = nil
        
        -- Check for Arcane Missiles
        if string.find(arg1, "Your Arcane Missiles hits") or string.find(arg1, "Your Arcane Missiles crits") then
            isArcaneSpell = true
            spellSource = "AM"
            if string.find(arg1, "crits") then
                spellSource = "AM Crit"
            end
        end
        
        -- Check for Arcane Instability
        if string.find(arg1, "Your Arcane Instability hits") or string.find(arg1, "Your Arcane Instability crits") then
            isArcaneSpell = true
            spellSource = "Instability"
            if string.find(arg1, "crits") then
                spellSource = "Instability Crit"
            end
        end
        
        -- Check for Arcane Surge
        if string.find(arg1, "Your Arcane Surge hits") or string.find(arg1, "Your Arcane Surge crits") then
            isArcaneSpell = true
            spellSource = "Surge"
            if string.find(arg1, "crits") then
                spellSource = "Surge Crit"
            end
        end
        
        -- Check for Arcane Explosion
        if string.find(arg1, "Your Arcane Explosion hits") or string.find(arg1, "Your Arcane Explosion crits") then
            isArcaneSpell = true
            spellSource = "Explosion"
            if string.find(arg1, "crits") then
                spellSource = "Explosion Crit"
            end
        end
        
        -- Check for Arcane Rupture
        if string.find(arg1, "Your Arcane Rupture hits") or string.find(arg1, "Your Arcane Rupture crits") then
            isArcaneSpell = true
            spellSource = "Rupture"
            if string.find(arg1, "crits") then
                spellSource = "Rupture Crit"
            end
        end
        
        if isArcaneSpell then
            -- Skip timeout checks in debug mode
            if not debugMode then
                -- All arcane spells use the same timeout
                if lastArcaneMissilesHit and lastArcaneMissilesHit > 0 and currentTime - lastArcaneMissilesHit > CAST_TIMEOUT then
                    ResetDamage()
                end
                
                -- All spells except pure procs (Instability/Surge) update the timer
                if spellSource ~= "Instability" and spellSource ~= "Instability Crit" and
                   spellSource ~= "Surge" and spellSource ~= "Surge Crit" then
                    lastArcaneMissilesHit = currentTime
                end
            end
            
            lastHitTime = currentTime
            
            local _, _, damage = string.find(arg1, "for (%d+)")
            if damage then
                local damageNum = tonumber(damage)
                damageTotal = damageTotal + damageNum
                
                -- Determine if it's a crit
                local isCrit = string.find(arg1, "crits") ~= nil
                
                -- Add to log
                table.insert(damageLog, {source = spellSource, damage = damageNum, isCrit = isCrit})
                
                -- Trigger shake effect
                ShakeText()
                
                UpdateDisplay()
                
                -- Create spark effect with current color
                CreateSpark(damageNum, displayFrame.currentColor or {1, 1, 1})
            end
        end
    end
end)

-- Slash command to toggle display
local function SlashCommandHandler(msg)
    if msg == "reset" then
        topRecord = 0
        MissileTrackerArcanusDB.topRecord = 0  -- Save to disk
        damageTotal = 0
        damageLog = {}
        UpdateDisplay()
        DEFAULT_CHAT_FRAME:AddMessage("Missile Tracker Arcanus: Record reset!")
    elseif msg == "debug" then
        debugMode = not debugMode
        if debugMode then
            DEFAULT_CHAT_FRAME:AddMessage("Missile Tracker Arcanus: Debug mode ENABLED (no timeout)")
        else
            DEFAULT_CHAT_FRAME:AddMessage("Missile Tracker Arcanus: Debug mode DISABLED")
            -- Reset damage when exiting debug mode
            ResetDamage()
        end
        UpdateDisplay()
    elseif displayFrame:IsShown() then
        displayFrame:Hide()
        DEFAULT_CHAT_FRAME:AddMessage("Missile Tracker Arcanus hidden")
    else
        displayFrame:Show()
        DEFAULT_CHAT_FRAME:AddMessage("Missile Tracker Arcanus shown")
    end
end

SLASH_AMTRACKER1 = "/amtrack"
SLASH_AMTRACKER2 = "/amt"
SLASH_AMTRACKER3 = "/mta"
SlashCmdList["AMTRACKER"] = SlashCommandHandler

-- Show display on load
displayFrame:Show()

-- Animation frame
local animFrame = CreateFrame("Frame")
local lastUpdate = GetTime()
animFrame:SetScript("OnUpdate", function()
    local now = GetTime()
    local elapsed = now - lastUpdate
    lastUpdate = now
    
    -- Handle shake animation
    if shakeTime > 0 then
        shakeTime = shakeTime - elapsed
        -- Random shake offset in both X and Y with scaling intensity
        local intensity = GetShakeIntensity()
        shakeOffsetX = (math.random() - 0.5) * intensity
        shakeOffsetY = (math.random() - 0.5) * intensity
        damageText:SetPoint("TOP", shakeOffsetX, -30 + shakeOffsetY)
        
        -- Update glow positions if active
        local directions = {
            {x = 1, y = 0},    -- Right
            {x = -1, y = 0},   -- Left
            {x = 0, y = 1},    -- Down
            {x = 0, y = -1},   -- Up
            {x = 1, y = 1},    -- Bottom-Right
            {x = -1, y = 1},   -- Bottom-Left
            {x = 1, y = -1},   -- Top-Right
            {x = -1, y = -1}   -- Top-Left
        }
        
        local glowIndex = 1
        for layerSize = 1, 3 do
            for dirIndex = 1, 8 do
                local glowData = glowLayers[glowIndex]
                if glowData.layer:IsShown() then
                    local dir = directions[dirIndex]
                    local offset = layerSize
                    glowData.layer:SetPoint("TOP", shakeOffsetX + (dir.x * offset), -30 + shakeOffsetY + (dir.y * offset))
                end
                glowIndex = glowIndex + 1
            end
        end
    else
        shakeOffsetX = 0
        shakeOffsetY = 0
        damageText:SetPoint("TOP", 0, -30)
    end
    
    -- Handle glow animation for new records
    if damageTotal > topRecord and damageTotal > 0 then
        glowAlpha = glowAlpha + (glowDirection * elapsed * 3)
        if glowAlpha >= 1 then
            glowAlpha = 1
            glowDirection = -1
        elseif glowAlpha <= 0.3 then
            glowAlpha = 0.3
            glowDirection = 1
        end
        
        -- Update all glow layers
        local directions = {
            {x = 1, y = 0},    -- Right
            {x = -1, y = 0},   -- Left
            {x = 0, y = 1},    -- Down
            {x = 0, y = -1},   -- Up
            {x = 1, y = 1},    -- Bottom-Right
            {x = -1, y = 1},   -- Bottom-Left
            {x = 1, y = -1},   -- Top-Right
            {x = -1, y = -1}   -- Top-Left
        }
        
        local glowIndex = 1
        for layerSize = 1, 3 do
            for dirIndex = 1, 8 do
                local glowData = glowLayers[glowIndex]
                local dir = directions[dirIndex]
                local offset = layerSize
                
                glowData.layer:SetPoint("TOP", shakeOffsetX + (dir.x * offset), -30 + shakeOffsetY + (dir.y * offset))
                
                -- Outer layers slightly more transparent
                local alpha = glowAlpha * (0.6 - (layerSize * 0.1))
                glowData.layer:SetTextColor(1, 1, 1, alpha)
                
                glowIndex = glowIndex + 1
            end
        end
    end
    
    -- Handle spark animations
    local i = 1
    while i <= table.getn(activeSparks) do
        local sparkData = activeSparks[i]
        local progress = (now - sparkData.startTime) / sparkData.duration
        
        if progress >= 1 then
            -- Spark finished, hide it
            sparkData.spark:Hide()
            table.remove(activeSparks, i)
        else
            -- Update spark position and appearance
            local x = sparkData.startX + (sparkData.endX - sparkData.startX) * progress
            local y = sparkData.startY + (sparkData.endY - sparkData.startY) * progress
            sparkData.spark:SetPoint("TOP", x, y)
            
            -- Grow from size 16 to 22 as it fades
            local size = 16 + (progress * 6)
            sparkData.spark:SetFont("Fonts\\FRIZQT__.TTF", size)
            
            -- Fade color to white and reduce alpha
            local fadeToWhite = progress * 0.7
            local r = sparkData.color[1] + (1 - sparkData.color[1]) * fadeToWhite
            local g = sparkData.color[2] + (1 - sparkData.color[2]) * fadeToWhite
            local b = sparkData.color[3] + (1 - sparkData.color[3]) * fadeToWhite
            local a = 1 - progress
            
            sparkData.spark:SetTextColor(r, g, b, a)
            
            i = i + 1
        end
    end
end)