--[[
    Subtitle to Text+ Professional Edition
    
    DaVinci Resolve用の字幕からText+への変換スクリプト。
    保守性と拡張性を重視したモジュラー構造。
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

-- マーカー名からトラックターゲットとテンプレート名を抽出する
function MarkerParser.parse(markerName)
    if markerName:sub(1, #Config.PREFIX) ~= Config.PREFIX then
        return nil
    end
    
    local body = markerName:sub(#Config.PREFIX + 1)
    local trackTarget, templateName = body:match("^(.-)%-(.*)$")
    
    if not trackTarget or not templateName then
        return nil -- 無効な形式
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
        Logger.debug("  [Delete] 既存クリップを " .. #toDelete .. " 件削除します。")
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
        -- 代替検索ロジック
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
    -- resolve オブジェクトは環境から自動提供されることを前提とする
    if not resolve then
        print("Error: resolve オブジェクトが見つかりません。DaVinci Resolve内で実行してください。")
        return
    end

    local project = resolve:GetProjectManager():GetCurrentProject()
    local timeline = project and project:GetCurrentTimeline()
    if not timeline then
        Logger.error("プロジェクトまたはタイムラインが開かれていません。")
        return
    end

    local mediaPool = project:GetMediaPool()
    local rootFolder = mediaPool:GetRootFolder()
    local markers = timeline:GetMarkers()
    
    Logger.info("Timeline: " .. timeline:GetName())
    
    if not markers or next(markers) == nil then
        Logger.info("タイムライン上にマーカーがありません。")
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
    
    Logger.info("完了しました。(" .. markerCount .. " 個のマーカーを処理)")
end

function App:processMarker(timeline, mediaPool, rootFolder, frame, marker, param)
    local vIdx = ResolveClient.findTrackIndexByName(timeline, "video", param.targetTrackName)
    local sIdx = ResolveClient.findTrackIndexByName(timeline, "subtitle", param.targetTrackName)
    
    if not vIdx or not sIdx then
        Logger.error("対象トラックが見つかりません: " .. param.targetTrackName)
        return
    end

    Logger.info("Marker: " .. marker.name .. " -> Track: " .. param.targetTrackName)

    -- 既存クリップを削除
    local timelineStart = timeline:GetStartFrame()
    local mStartAbs = frame + timelineStart
    local mEndAbs = mStartAbs + (marker.duration or 1)
    ResolveClient.deleteClipsInRange(timeline, "video", vIdx, mStartAbs, mEndAbs)

    -- 字幕取得
    local subs = SubtitleProcessor.getSubtitlesInRange(timeline, sIdx, frame, frame + (marker.duration or 1))
    if #subs == 0 then
        Logger.info("  [Skip] 指定範囲に字幕がありません。")
        return
    end

    -- テンプレート取得
    local templateClip = ResolveClient.findClipInMediaPool(rootFolder, param.templateName)
    if not templateClip then
        Logger.error("  テンプレートが見つかりません: " .. param.templateName)
        return
    end

    -- 字幕ごとにText+挿入
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
    Logger.info("  [Result] " .. success .. "/" .. #subs .. " 個の Text+ を配置・更新しました。")
end

function App:showGuidance()
    Logger.info("\n[Guidance] 有効なマーカーが見つかりませんでした。")
    Logger.info("以下の命名規則を確認してください：")
    Logger.info("1. トラック名: '" .. Config.PREFIX .. "TrackName' (例: " .. Config.PREFIX .. "Main)")
    Logger.info("2. マーカー名: '" .. Config.PREFIX .. "TrackName-TemplateName' (例: " .. Config.PREFIX .. "Main-StyleA)")
    Logger.info("   ※メディアプールに 'StyleA' という名前のText+が必要です。")
end

-- アプリケーション実行
App:run()
