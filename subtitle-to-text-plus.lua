--[[
    Subtitle to Text+ Professional Edition
    
    DaVinci Resolve script to convert subtitles to Text+ clips.
    Focuses on maintainability and modular structure.
]]

-- ==========================================
-- 1. Configuration object
-- ==========================================
local Config = {
    PREFIX = "::",
    DEBUG = false,
}

-- ==========================================
-- 2. Logger Module
-- ==========================================
local Logger = {}
function Logger.debug(msg)
    if Config.DEBUG then print("  [DEBUG] " .. msg) end
end
function Logger.info(msg) print("  [INFO] " .. msg) end
function Logger.error(msg) print("  [ERROR] " .. msg) end

-- ==========================================
-- 3. MarkerParser Module
-- ==========================================
local MarkerParser = {}

-- Extract track target and template name from marker name
function MarkerParser.parse(markerName)
    if markerName:sub(1, #Config.PREFIX) ~= Config.PREFIX then
        return nil
    end
    
    local body = markerName:sub(#Config.PREFIX + 1)
    local trackTarget, templateName = body:match("^(.-)%-(.*)$")
    
    if not trackTarget or not templateName then
        return nil -- Invalid format
    end
    
    return {
        targetTrackName = Config.PREFIX .. trackTarget,
        templateName = templateName
    }
end

-- ==========================================
-- 4. ResolveClient Module (Low-level API wrappers)
-- ==========================================
local ResolveClient = {}

function ResolveClient.findClipInMediaPool(folder, name)
    local clips = folder:GetClipList()
    for _, clip in ipairs(clips) do
        if clip:GetName() == name then return clip end
    end
    
    local subFolders = folder:GetSubFolderList()
    for _, subFolder in ipairs(subFolders) do
        local found = ResolveClient.findClipInMediaPool(subFolder, name)
        if found then return found end
    end
    return nil
end

function ResolveClient.findTrackIndexByName(timeline, trackType, name)
    local count = timeline:GetTrackCount(trackType)
    for i = 1, count do
        if timeline:GetTrackName(trackType, i) == name then return i end
    end
    return nil
end

function ResolveClient.deleteClipsInRange(timeline, trackType, trackIndex, startAbs, endAbs)
    local items = timeline:GetItemListInTrack(trackType, trackIndex)
    if not items then return end
    
    local toDelete = {}
    for _, item in ipairs(items) do
        local iStart = item:GetStart()
        local iEnd = iStart + item:GetDuration()
        if iStart < endAbs and iEnd > startAbs then
            table.insert(toDelete, item)
        end
    end
    
    if #toDelete > 0 then
        Logger.debug("  [Delete] Removing " .. #toDelete .. " existing clips.")
        timeline:DeleteClips(toDelete)
    end
end

-- ==========================================
-- 5. SubtitleProcessor Module (Core Business Logic)
-- ==========================================
local SubtitleProcessor = {}

function SubtitleProcessor.updateTextPlus(timelineItem, text)
    local comp = timelineItem:GetFusionCompByIndex(1)
    if not comp then return false end
    
    local tool = comp:FindTool("Template")
    if not tool then
        -- Fallback search logic
        for _, t in pairs(comp:GetToolList()) do
            local attrs = t:GetAttrs()
            if attrs.TOOLS_Name == "Template" or attrs.TOOLB_Name == "TextPlus" then
                tool = t
                break
            end
        end
    end
    
    if tool then
        tool:SetInput("StyledText", text)
        return true
    end
    return false
end

function SubtitleProcessor.getSubtitlesInRange(timeline, sIdx, startRel, endRel)
    local items = timeline:GetItemListInTrack("subtitle", sIdx)
    if not items then return {} end
    
    local timelineStart = timeline:GetStartFrame()
    local startAbs = startRel + timelineStart
    local endAbs = endRel + timelineStart
    
    local found = {}
    for _, item in ipairs(items) do
        local iStart = item:GetStart()
        local iEnd = iStart + item:GetDuration()
        
        if iStart < endAbs and iEnd > startAbs then
            table.insert(found, {
                text = item:GetName(),
                start = iStart,
                duration = item:GetDuration()
            })
        end
    end
    return found
end

-- ==========================================
-- 6. Application Controller
-- ==========================================
local App = {}

function App:run()
    -- 'resolve' object is expected to be pre-defined in the environment
    if not resolve then
        print("Error: 'resolve' object not found. Please run this script within DaVinci Resolve.")
        return
    end

    local project = resolve:GetProjectManager():GetCurrentProject()
    local timeline = project and project:GetCurrentTimeline()
    if not timeline then
        Logger.error("Project or Timeline is not open.")
        return
    end

    local mediaPool = project:GetMediaPool()
    local rootFolder = mediaPool:GetRootFolder()
    local markers = timeline:GetMarkers()
    
    Logger.info("Timeline: " .. timeline:GetName())
    
    if not markers or next(markers) == nil then
        Logger.info("No markers found on the timeline.")
        return
    end

    local sortedFrames = {}
    for f, _ in pairs(markers) do table.insert(sortedFrames, f) end
    table.sort(sortedFrames)

    local markerCount = 0
    for _, frame in ipairs(sortedFrames) do
        local marker = markers[frame]
        local param = MarkerParser.parse(marker.name)
        
        if param then
            markerCount = markerCount + 1
            self:processMarker(timeline, mediaPool, rootFolder, frame, marker, param)
        end
    end

    if markerCount == 0 then
        self:showGuidance()
    end
    
    Logger.info("Finished. (" .. markerCount .. " markers processed)")
end

function App:processMarker(timeline, mediaPool, rootFolder, frame, marker, param)
    local vIdx = ResolveClient.findTrackIndexByName(timeline, "video", param.targetTrackName)
    local sIdx = ResolveClient.findTrackIndexByName(timeline, "subtitle", param.targetTrackName)
    
    if not vIdx or not sIdx then
        Logger.error("Target tracks not found: " .. param.targetTrackName)
        return
    end

    Logger.info("Processing Marker: " .. marker.name .. " -> Track: " .. param.targetTrackName)

    -- Remove existing clips
    local timelineStart = timeline:GetStartFrame()
    local mStartAbs = frame + timelineStart
    local mEndAbs = mStartAbs + (marker.duration or 1)
    ResolveClient.deleteClipsInRange(timeline, "video", vIdx, mStartAbs, mEndAbs)

    -- Get subtitles
    local subs = SubtitleProcessor.getSubtitlesInRange(timeline, sIdx, frame, frame + (marker.duration or 1))
    if #subs == 0 then
        Logger.info("  [Skip] No subtitles found in the specified range.")
        return
    end

    -- Get template
    local templateClip = ResolveClient.findClipInMediaPool(rootFolder, param.templateName)
    if not templateClip then
        Logger.error("  Template not found: " .. param.templateName)
        return
    end

    -- Insert Text+ for each subtitle
    local success = 0
    for _, sub in ipairs(subs) do
        local items = mediaPool:AppendToTimeline({{
            ["mediaPoolItem"] = templateClip,
            ["startFrame"] = 0,
            ["endFrame"] = sub.duration,
            ["recordFrame"] = sub.start,
            ["trackIndex"] = vIdx,
            ["mediaType"] = 1
        }})
        
        if items and items[1] then
            if SubtitleProcessor.updateTextPlus(items[1], sub.text) then
                success = success + 1
            end
        end
    end
    Logger.info("  [Result] Successfully placed/updated " .. success .. "/" .. #subs .. " Text+ clips.")
end

function App:showGuidance()
    Logger.info("\n[Guidance] No valid markers found.")
    Logger.info("Please check the naming convention:")
    Logger.info("1. Track Name: '" .. Config.PREFIX .. "TrackName' (e.g., " .. Config.PREFIX .. "Main)")
    Logger.info("2. Marker Name: '" .. Config.PREFIX .. "TrackName-TemplateName' (e.g., " .. Config.PREFIX .. "Main-StyleA)")
    Logger.info("   * Ensure 'StyleA' Text+ exists in the Media Pool.")
end

-- Execution
App:run()
