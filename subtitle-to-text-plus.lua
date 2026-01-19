-- DaVinci Resolve Subtitle to Text+ Converter
-- @@@- で始まるビデオトラックに対し、同名の字幕トラックの内容をマーカー区間（@@@-XXX）に合わせてText+として挿入します。

-- ==========================================
-- Configuration
-- ==========================================

local PREFIX = "@@@-"
local PREFIX_LEN = #PREFIX
local DEBUG_MODE = false -- 詳細ログを表示するかどうか

-- ==========================================
-- Utility Functions
-- ==========================================

local function logDebug(msg)
    if DEBUG_MODE then
        print("  [DEBUG] " .. msg)
    end
end

-- メディアプールから名前でクリップを検索する（再帰的）
local function findClipInMediaPool(folder, name)
    local clips = folder:GetClipList()
    for _, clip in ipairs(clips) do
        if clip:GetName() == name then
            return clip
        end
    end
    
    local subFolders = folder:GetSubFolderList()
    for _, subFolder in ipairs(subFolders) do
        local found = findClipInMediaPool(subFolder, name)
        if found then return found end
    end
    
    return nil
end

-- 指定されたタイムラインで特定の名前のトラックのインデックスを探す
local function findTrackIndexByName(timeline, trackType, name)
    local count = timeline:GetTrackCount(trackType)
    for i = 1, count do
        local tName = timeline:GetTrackName(trackType, i)
        if tName == name then
            return i
        end
    end
    return nil
end

-- ==========================================
-- Timeline Item / Fusion Functions
-- ==========================================

-- 挿入されたText+アイテムのテキスト内容を更新する
local function updateTextPlusContent(timelineItem, text)
    local comp = timelineItem:GetFusionCompByIndex(1)
    if not comp then
        logDebug("Fusion Compが見つかりません。")
        return false
    end

    -- Python版を参考に FindTool も併用
    local tool = comp:FindTool("Template")
    if not tool then
        local tools = comp:GetToolList()
        for _, t in pairs(tools) do
            local attrs = t:GetAttrs()
            if attrs.TOOLS_Name == "Template" or attrs.TOOLB_Name == "TextPlus" then
                tool = t
                break
            end
        end
    end

    if tool then
        tool:SetInput("StyledText", text)
        logDebug("StyledTextを更新しました。")
        return true
    end

    logDebug("TextPlusツールが見つかりません。")
    return false
end

-- 字幕トラック内の指定範囲にある個別の字幕アイテム（名前とタイミング）をリストで取得する
local function getSubtitlesInRange(timeline, subtitleTrackIndex, startTimeRel, endTimeRel)
    local items = timeline:GetItemListInTrack("subtitle", subtitleTrackIndex)
    if not items or #items == 0 then
        logDebug("字幕トラックにアイテムがありません。")
        return {}
    end

    local timelineStart = timeline:GetStartFrame()
    local subtitleList = {}

    for i, item in ipairs(items) do
        local start = item:GetStart()
        local duration = item:GetDuration()
        local itemEnd = start + duration
        local text = item:GetName()
        
        -- クリップの判定（マーカー区間内にあるか）
        -- ※字幕クリップの座標は常に絶対座標のため、絶対座標で比較
        local mStartAbs = startTimeRel + timelineStart
        local mEndAbs = endTimeRel + timelineStart
        
        if start < mEndAbs and itemEnd > mStartAbs then
            table.insert(subtitleList, {
                text = text,
                start = start,
                duration = duration,
                itemEnd = itemEnd
            })
            logDebug("  [Found] 字幕: '" .. text:sub(1,10) .. "...' (Start: " .. start .. ")")
        end
    end
    
    return subtitleList
end

-- ==========================================
-- Core Logic Functions
-- ==========================================

-- 特定のマーカーに対して、その範囲内の「各字幕ごと」にText+を挿入・設定する
local function processMarker(projectContext, markerData)
    local timeline = projectContext.timeline
    local mediaPool = projectContext.mediaPool
    local rootFolder = projectContext.rootFolder
    
    local clipName = markerData.name:sub(PREFIX_LEN + 1)
    print("  Marker処理開始: " .. markerData.name .. " -> Template: " .. clipName)
    
    -- マーカー区間内の個別字幕アイテムを取得
    local subtitles = getSubtitlesInRange(timeline, markerData.subtitleTrackIndex, markerData.frame, markerData.frame + (markerData.duration or 1))
    
    if #subtitles == 0 then
        print("    [Skip] 指定範囲に字幕が見つかりませんでした。")
        return false
    end
    
    -- ソースクリップ（Template）を事前に検索
    local sourceClip = findClipInMediaPool(rootFolder, clipName)
    if not sourceClip then
        print("    [Error] メディアプールにテンプレートが見つかりません: " .. clipName)
        return false
    end
    
    print("    字幕を " .. #subtitles .. " 個発見しました。個別挿入を開始します...")
    
    local successCount = 0
    for _, sub in ipairs(subtitles) do
        -- 各字幕クリップに合わせたText+を挿入
        local items = mediaPool:AppendToTimeline({{
            ["mediaPoolItem"] = sourceClip,
            ["startFrame"] = 0,
            ["endFrame"] = sub.duration,
            ["recordFrame"] = sub.start, -- 字幕自体の開始フレーム（絶対座標）を使用
            ["trackIndex"] = markerData.videoTrackIndex,
            ["mediaType"] = 1
        }})
        
        local item = items and items[1]
        if item then
            -- 各クリップに個別のテキストを設定
            if updateTextPlusContent(item, sub.text) then
                successCount = successCount + 1
            end
        else
            logDebug("    [Error] クリップ挿入失敗: " .. sub.text:sub(1,10))
        end
    end
    
    print("    [Result] " .. successCount .. "/" .. #subtitles .. " 個の Text+ を挿入・更新しました。")
    return successCount > 0
end

-- ==========================================
-- Main Entry Point
-- ==========================================

local function run()
    local resolve = Resolve()
    local projectManager = resolve:GetProjectManager()
    local project = projectManager:GetCurrentProject()
    
    if not project then
        print("Error: プロジェクトが開かれていません。")
        return
    end

    local timeline = project:GetCurrentTimeline()
    if not timeline then
        print("Error: タイムラインが開かれていません。")
        return
    end

    local mediaPool = project:GetMediaPool()
    local rootFolder = mediaPool:GetRootFolder()
    
    print("Timeline: " .. timeline:GetName())
    
    local projectContext = {
        project = project,
        timeline = timeline,
        mediaPool = mediaPool,
        rootFolder = rootFolder
    }
    
    local videoTrackCount = timeline:GetTrackCount("video")
    local subtitleTrackCount = timeline:GetTrackCount("subtitle")
    local markers = timeline:GetMarkers()
    
    logDebug("ビデオトラック数: " .. videoTrackCount .. ", 字幕トラック数: " .. subtitleTrackCount)

    if not markers then
        print("Info: タイムライン上にマーカーが一つもありません。")
        return
    end

    -- 全トラック名のリストアップ（デバッグ用）
    logDebug("全トラックの確認:")
    for i = 1, videoTrackCount do
        logDebug("  Video " .. i .. ": " .. timeline:GetTrackName("video", i))
    end
    for i = 1, subtitleTrackCount do
        logDebug("  Subtitle " .. i .. ": " .. timeline:GetTrackName("subtitle", i))
    end

    -- ビデオトラックの走査
    local trackProcessed = 0
    for vIdx = 1, videoTrackCount do
        local vName = timeline:GetTrackName("video", vIdx)
        
        if vName:sub(1, PREFIX_LEN) == PREFIX then
            trackProcessed = trackProcessed + 1
            print("\nTrack Processing: " .. vName .. " (Index: " .. vIdx .. ")")
            
            -- 対応する字幕トラックを探す
            local sIdx = findTrackIndexByName(timeline, "subtitle", vName)
            
            if not sIdx then
                print("  Warning: 同じ名前の字幕トラック '" .. vName .. "' が見つかりません。")
            else
                logDebug("一致する字幕トラックを発見: Index " .. sIdx)
                
                -- 各マーカーを処理
                local markerFoundOnTrack = 0
                for frame, marker in pairs(markers) do
                    if marker.name:sub(1, PREFIX_LEN) == PREFIX then
                        markerFoundOnTrack = markerFoundOnTrack + 1
                        processMarker(projectContext, {
                            name = marker.name,
                            frame = frame,
                            duration = marker.duration,
                            videoTrackIndex = vIdx,
                            subtitleTrackIndex = sIdx
                        })
                    end
                end
                
                if markerFoundOnTrack == 0 then
                    logDebug("このトラックの対象となるマーカー(開始が" .. PREFIX .. ")がありません。")
                end
            end
        end
    end
    
    if trackProcessed == 0 then
        print("\n対象トラックが見つかりませんでした。命名規則(" .. PREFIX .. ")を確認してください。")
    end
    
    print("\nFinish: 完了しました。")
end

run()
