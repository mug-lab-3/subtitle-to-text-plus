-- DaVinci Resolve Subtitle to Text+ Converter
-- @@@- で始まるビデオトラックに対し、同名の字幕トラックの内容をマーカー区間（@@@-XXX）に合わせてText+として挿入します。

-- ==========================================
-- Configuration
-- ==========================================

local PREFIX = "::"
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

-- タイムライン上の特定の範囲にあるクリップを削除する
local function deleteClipsInRange(timeline, trackType, trackIndex, startTimeAbs, endTimeAbs)
    local items = timeline:GetItemListInTrack(trackType, trackIndex)
    if not items then return end
    
    for _, item in ipairs(items) do
        local start = item:GetStart()
        local duration = item:GetDuration()
        local itemEnd = start + duration
        
        -- 重なり（Overlap）の判定
        if start < endTimeAbs and itemEnd > startTimeAbs then
            logDebug("  [Delete] 既存クリップを削除します: " .. item:GetName() .. " (Range: " .. start .. " - " .. itemEnd .. ")")
            timeline:DeleteClips({item})
        end
    end
end

-- ==========================================
-- Core Logic Functions
-- ==========================================

-- 特定のマーカーに対して、その範囲内の「各字幕ごと」にText+を挿入・設定する
local function processMarker(projectContext, markerData)
    local timeline = projectContext.timeline
    local mediaPool = projectContext.mediaPool
    local rootFolder = projectContext.rootFolder
    local timelineStart = timeline:GetStartFrame()
    
    -- 1. マーカー名の解析 (形式: ::Track-Template)
    local nameBody = markerData.name:sub(PREFIX_LEN + 1)
    local trackNameWithoutPrefix, templateName = nameBody:match("^(.-)%-(.*)$")
    
    if not trackNameWithoutPrefix or not templateName then
        logDebug("マーカー名の形式が不正です (期待: ::Track-Template): " .. markerData.name)
        return false
    end
    
    -- トラック名（プレフィックスあり）の生成
    local targetTrackName = PREFIX .. trackNameWithoutPrefix
    
    -- 2. 対象トラックの検索
    local vIdx = findTrackIndexByName(timeline, "video", targetTrackName)
    local sIdx = findTrackIndexByName(timeline, "subtitle", targetTrackName)
    
    if not vIdx or not sIdx then
        logDebug("対象トラックが見つかりません: " .. targetTrackName)
        return false
    end
    
    print("  Marker処理開始: " .. markerData.name .. " -> Track: " .. targetTrackName .. ", Template: " .. templateName)
    
    -- 3. 既存クリップの削除（上書き対応）
    -- マーカーの開始位置と終了位置（絶対座標）
    local mStartAbs = markerData.frame + timelineStart
    local mEndAbs = mStartAbs + (markerData.duration or 1)
    logDebug("既存クリップのクリーニング中... (Range: " .. mStartAbs .. " - " .. mEndAbs .. ")")
    deleteClipsInRange(timeline, "video", vIdx, mStartAbs, mEndAbs)

    -- 4. マーカー区間内の個別字幕アイテムを取得
    local subtitles = getSubtitlesInRange(timeline, sIdx, markerData.frame, markerData.frame + (markerData.duration or 1))
    
    if #subtitles == 0 then
        print("    [Skip] 指定範囲に字幕が見つかりませんでした。")
        return false
    end
    
    -- 5. ソースクリップ（Template）を事前に検索
    local sourceClip = findClipInMediaPool(rootFolder, templateName)
    if not sourceClip then
        print("    [Error] メディアプールにテンプレートが見つかりません: " .. templateName)
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
            ["trackIndex"] = vIdx,
            ["mediaType"] = 1
        }})
        
        local item = items and items[1]
        if item then
            -- 各クリップに個別のテキストを設定
            if updateTextPlusContent(item, sub.text) then
                successCount = successCount + 1
            end
        else
            logDebug("    [Error] クリップ挿入失敗: " .. (sub.text:sub(1,10) or "Unknown"))
        end
    end
    
    print("    [Result] " .. successCount .. "/" .. #subtitles .. " 個の Text+ を挿入・更新しました。")
    return successCount > 0
end

-- ==========================================
-- Main Entry Point
-- ==========================================

local function run()
    -- local resolve = Resolve()
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

    if not markers or next(markers) == nil then
        print("Info: タイムライン上にマーカーが一つもありません。")
        return
    end

    -- 全トラック名のリストアップ（重要：命名規則の確認用）
    logDebug("現在のトラック一覧:")
    for i = 1, videoTrackCount do
        logDebug("  Video " .. i .. ": [" .. timeline:GetTrackName("video", i) .. "]")
    end
    for i = 1, subtitleTrackCount do
        logDebug("  Subtitle " .. i .. ": [" .. timeline:GetTrackName("subtitle", i) .. "]")
    end

    -- マーカー主導での処理
    local markerProcessed = 0
    local sortedFrames = {}
    for frame, _ in pairs(markers) do
        table.insert(sortedFrames, frame)
    end
    table.sort(sortedFrames)

    logDebug("検出された全マーカーの確認:")
    for _, frame in ipairs(sortedFrames) do
        local marker = markers[frame]
        logDebug("  Frame " .. frame .. ": Name=[" .. marker.name .. "]")
        
        if marker.name:sub(1, PREFIX_LEN) == PREFIX then
            if processMarker(projectContext, {
                name = marker.name,
                frame = frame,
                duration = marker.duration
            }) then
                markerProcessed = markerProcessed + 1
            end
        end
    end
    
    if markerProcessed == 0 then
        print("\n[Guidance] 有効なマーカー(" .. PREFIX .. "で始まるもの)が処理されませんでした。")
        print("以下の点を確認してください：")
        print("1. マーカー名が '" .. PREFIX .. "トラック名-テンプレート名' になっていますか？ (例: " .. PREFIX .. "Main-StyleA)")
        print("2. 対象のビデオトラックと字幕トラックの両方に '" .. PREFIX .. "' が付いていますか？ (例: " .. PREFIX .. "Main)")
        print("3. メディアプールにテンプレートクリップ (例: StyleA) が存在しますか？")
    end
    
    print("\nFinish: 完了しました。(" .. markerProcessed .. " 個のマーカーを処理しました)")
end

run()
