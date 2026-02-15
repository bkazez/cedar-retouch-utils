-- Return from CEDAR Retouch
-- Re-imports the processed multichannel WAV from CEDAR Retouch,
-- replacing original items at their correct positions.
-- Fully undoable with Ctrl+Z (single undo step).

-- Constants
local EXTSTATE_SECTION = "CEDAR_Roundtrip"

---------------------------------------------------------------------------
-- JSON decoder (minimal, sufficient for metadata)
---------------------------------------------------------------------------

local function json_decode(str)
  local pos = 1

  local function skip_whitespace()
    while pos <= #str and str:sub(pos, pos):match("[ \t\n\r]") do
      pos = pos + 1
    end
  end

  local function peek()
    skip_whitespace()
    return str:sub(pos, pos)
  end

  local function consume(expected)
    skip_whitespace()
    if str:sub(pos, pos) ~= expected then
      error("JSON parse error: expected '" .. expected .. "' at position " .. pos)
    end
    pos = pos + 1
  end

  local parse_value -- forward declaration

  local function parse_string()
    consume('"')
    local result = {}
    while pos <= #str do
      local c = str:sub(pos, pos)
      pos = pos + 1
      if c == '"' then
        return table.concat(result)
      elseif c == '\\' then
        local esc = str:sub(pos, pos)
        pos = pos + 1
        if esc == '"' then result[#result + 1] = '"'
        elseif esc == '\\' then result[#result + 1] = '\\'
        elseif esc == 'n' then result[#result + 1] = '\n'
        elseif esc == 't' then result[#result + 1] = '\t'
        elseif esc == 'r' then result[#result + 1] = '\r'
        else result[#result + 1] = esc end
      else
        result[#result + 1] = c
      end
    end
    error("JSON parse error: unterminated string")
  end

  local function parse_number()
    skip_whitespace()
    local start = pos
    if str:sub(pos, pos) == '-' then pos = pos + 1 end
    while pos <= #str and str:sub(pos, pos):match("[0-9]") do pos = pos + 1 end
    if pos <= #str and str:sub(pos, pos) == '.' then
      pos = pos + 1
      while pos <= #str and str:sub(pos, pos):match("[0-9]") do pos = pos + 1 end
    end
    if pos <= #str and str:sub(pos, pos):match("[eE]") then
      pos = pos + 1
      if pos <= #str and str:sub(pos, pos):match("[%+%-]") then pos = pos + 1 end
      while pos <= #str and str:sub(pos, pos):match("[0-9]") do pos = pos + 1 end
    end
    return tonumber(str:sub(start, pos - 1))
  end

  local function parse_array()
    consume('[')
    local arr = {}
    if peek() == ']' then
      consume(']')
      return arr
    end
    while true do
      arr[#arr + 1] = parse_value()
      skip_whitespace()
      if peek() == ',' then
        consume(',')
      else
        break
      end
    end
    consume(']')
    return arr
  end

  local function parse_object()
    consume('{')
    local obj = {}
    if peek() == '}' then
      consume('}')
      return obj
    end
    while true do
      local key = parse_string()
      consume(':')
      obj[key] = parse_value()
      skip_whitespace()
      if peek() == ',' then
        consume(',')
      else
        break
      end
    end
    consume('}')
    return obj
  end

  parse_value = function()
    skip_whitespace()
    local c = peek()
    if c == '"' then return parse_string()
    elseif c == '{' then return parse_object()
    elseif c == '[' then return parse_array()
    elseif c == 't' then
      pos = pos + 4; return true
    elseif c == 'f' then
      pos = pos + 5; return false
    elseif c == 'n' then
      pos = pos + 4; return nil
    else
      return parse_number()
    end
  end

  return parse_value()
end

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

local function find_track_by_guid(guid)
  local num_tracks = reaper.CountTracks(0)
  for i = 0, num_tracks - 1 do
    local track = reaper.GetTrack(0, i)
    if reaper.GetTrackGUID(track) == guid then
      return track
    end
  end
  return nil
end

-- Find all items on a track that overlap a time range.
-- Used as fallback when GUID lookup fails (e.g. re-running Return without undo).
local function find_items_overlapping(track, range_start, range_end)
  local results = {}
  local num_items = reaper.CountTrackMediaItems(track)
  for i = 0, num_items - 1 do
    local item = reaper.GetTrackMediaItem(track, i)
    local pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
    local len = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
    if pos + len > range_start and pos < range_end then
      results[#results + 1] = item
    end
  end
  return results
end

---------------------------------------------------------------------------
-- Metadata loading
---------------------------------------------------------------------------

local function load_metadata()
  -- Try ExtState first
  local json_str = reaper.GetExtState(EXTSTATE_SECTION, "metadata")
  if json_str and json_str ~= "" then
    local ok, metadata = pcall(json_decode, json_str)
    if ok and metadata then
      return metadata, nil
    end
  end

  -- Fallback: prompt user for sidecar JSON file
  local retval, file_path = reaper.GetUserFileNameForRead("", "Select CEDAR roundtrip metadata JSON", "json")
  if not retval then
    return nil, "No metadata found. Run 'Send to CEDAR Retouch' first."
  end

  local f = io.open(file_path, "r")
  if not f then
    return nil, "Cannot read metadata file: " .. file_path
  end
  json_str = f:read("*a")
  f:close()

  local ok, metadata = pcall(json_decode, json_str)
  if not ok or not metadata then
    return nil, "Invalid metadata JSON file."
  end

  return metadata, nil
end

---------------------------------------------------------------------------
-- WAV validation
---------------------------------------------------------------------------

-- CEDAR Retouch saves files with multiple concatenated RIFF chunks:
-- chunk 1 = original audio, chunk 2+ = processed audio (undo history).
-- Standard tools only read chunk 1 (unprocessed). This function extracts
-- the last RIFF chunk (most recent processed audio) into a clean WAV file.
local function extract_processed_riff(wav_path)
  local f = io.open(wav_path, "rb")
  if not f then return nil end

  -- Walk all RIFF chunks to find the last one
  local last_offset = nil
  local last_size = nil
  local offset = 0
  local chunk_count = 0

  while true do
    f:seek("set", offset)
    local hdr = f:read(8)
    if not hdr or #hdr < 8 then break end
    local magic, riff_size = string.unpack("<c4I4", hdr)
    if magic ~= "RIFF" then break end

    last_offset = offset
    last_size = riff_size
    chunk_count = chunk_count + 1

    -- CEDAR does not pad to even boundaries between RIFF chunks
    offset = offset + 8 + riff_size
  end

  -- Need at least 2 chunks (original + processed)
  if chunk_count < 2 then
    f:close()
    return nil
  end

  -- Verify last chunk is WAVE
  f:seek("set", last_offset + 8)
  local wave_tag = f:read(4)
  if not wave_tag or wave_tag ~= "WAVE" then f:close(); return nil end

  -- Read the last RIFF chunk
  f:seek("set", last_offset)
  local chunk_data = f:read(8 + last_size)
  f:close()

  if not chunk_data or #chunk_data < 8 + last_size then return nil end

  reaper.ShowConsoleMsg("[CEDAR] Found " .. chunk_count .. " RIFF chunks, extracting chunk " .. chunk_count .. " (most recent).\n")

  -- Write to a clean file
  local clean_path = wav_path:gsub("%.wav$", "_processed.wav")
  local out = io.open(clean_path, "wb")
  if not out then return nil end
  out:write(chunk_data)
  out:close()

  return clean_path
end

local function validate_processed_wav(metadata)
  local wav_path = metadata.wav_path
  local f = io.open(wav_path, "rb")
  if not f then
    return nil, "Processed WAV not found at:\n" .. wav_path ..
      "\n\nMake sure you saved the file in CEDAR Retouch (overwrite the original)."
  end

  -- Check if CEDAR appended processed audio as a second RIFF chunk
  local header = f:read(12)
  if not header or #header < 12 then
    f:close()
    return nil, "WAV file is too small or corrupt: " .. wav_path
  end
  local riff = header:sub(1, 4)
  local wave = header:sub(9, 12)
  if riff ~= "RIFF" or wave ~= "WAVE" then
    f:close()
    return nil, "File is not a valid WAV: " .. wav_path
  end

  local _, riff_size = string.unpack("<c4I4", header)
  -- CEDAR does not pad to even boundaries between RIFF chunks
  local chunk2_offset = 8 + riff_size

  f:seek("set", chunk2_offset)
  local peek = f:read(4)
  f:close()

  if peek and peek == "RIFF" then
    -- Multi-RIFF file from CEDAR: extract the processed chunk
    reaper.ShowConsoleMsg("[CEDAR] Multi-RIFF file detected, extracting processed audio...\n")
    local clean_path = extract_processed_riff(wav_path)
    if clean_path then
      wav_path = clean_path
      reaper.ShowConsoleMsg("[CEDAR] Extracted to: " .. clean_path .. "\n")
    else
      return nil, "Failed to extract processed audio from CEDAR file."
    end
  end

  -- Read WAV header to verify channel count
  local f2 = io.open(wav_path, "rb")
  local final_header = f2:read(44)
  f2:close()

  if not final_header or #final_header < 44 then
    return nil, "WAV file is too small or corrupt: " .. wav_path
  end

  local num_channels = string.unpack("<I2", final_header, 23)
  if num_channels ~= metadata.num_channels then
    return nil, "Channel count mismatch. Expected " .. metadata.num_channels ..
      " but WAV has " .. num_channels .. " channels." ..
      "\n\nMake sure CEDAR saved all channels."
  end

  return wav_path, nil
end

---------------------------------------------------------------------------
-- Item creation helper
---------------------------------------------------------------------------

local CEDAR_SUFFIX = "_cedar_" .. os.date("%y%m%d_%H%M")

local function create_cedar_item(track, first_out_ch, playback_channels, position, length, range_start, wav_path, take_name, item_vol, take_vol)
  local new_item = reaper.AddMediaItemToTrack(track)
  reaper.SetMediaItemInfo_Value(new_item, "D_POSITION", position)
  reaper.SetMediaItemInfo_Value(new_item, "D_LENGTH", length)
  if item_vol then
    reaper.SetMediaItemInfo_Value(new_item, "D_VOL", item_vol)
  end

  local new_take = reaper.AddTakeToMediaItem(new_item)
  local source = reaper.PCM_Source_CreateFromFile(wav_path)
  reaper.SetMediaItemTake_Source(new_take, source)

  if playback_channels == 1 then
    -- Mono: extract single channel. I_CHANMODE 3+N extracts mono channel N (0-based).
    reaper.SetMediaItemTakeInfo_Value(new_take, "I_CHANMODE", 3 + first_out_ch)
  elseif playback_channels == 2 then
    -- Stereo pair: I_CHANMODE 67 + 2*pair_index.
    -- first_out_ch is 0-based channel index, divide by 2 to get pair index.
    -- 67=ch1+2, 69=ch3+4, 71=ch5+6, etc.
    reaper.SetMediaItemTakeInfo_Value(new_take, "I_CHANMODE", 67 + first_out_ch)
  end
  -- playback_channels > 2: left at I_CHANMODE 0 (normal), which reads from ch1.
  -- This only works correctly if first_out_ch == 0. Validated at export time.

  -- Start offset: item position relative to WAV start
  local offset_in_wav = position - range_start
  reaper.SetMediaItemTakeInfo_Value(new_take, "D_STARTOFFS", offset_in_wav)

  -- Restore take volume
  if take_vol then
    reaper.SetMediaItemTakeInfo_Value(new_take, "D_VOL", take_vol)
  end

  -- Preserve original take name with cedar suffix
  local cedar_name = (take_name or "CEDAR") .. CEDAR_SUFFIX
  reaper.GetSetMediaItemTakeInfo_String(new_take, "P_NAME", cedar_name, true)

  return new_item
end

---------------------------------------------------------------------------
-- Item replacement
---------------------------------------------------------------------------

local function replace_items(metadata, wav_path)
  local errors = {}
  local is_partial = metadata.time_sel_start ~= nil
  local sel_start = metadata.time_sel_start
  local sel_end = metadata.time_sel_end

  -- Determine replacement region
  local replace_region_start, replace_region_end
  if is_partial then
    replace_region_start = sel_start
    replace_region_end = sel_end
  else
    replace_region_start = metadata.range_start
    replace_region_end = metadata.range_end
  end

  -- First pass: validate tracks exist and build operations list
  local operations = {}
  local affected_tracks = {}  -- track GUID -> track pointer
  for _, item_meta in ipairs(metadata.items) do
    local track = find_track_by_guid(item_meta.track_guid)
    if not track then
      errors[#errors + 1] = "Track not found (GUID: " .. item_meta.track_guid ..
        ", was track #" .. item_meta.track_idx .. "). Was it deleted?"
      goto continue_item
    end

    affected_tracks[item_meta.track_guid] = track

    operations[#operations + 1] = {
      track = track,
      track_guid = item_meta.track_guid,
      first_out_ch = item_meta.first_out_ch,
      playback_channels = item_meta.playback_channels,
      item_position = item_meta.position,
      item_length = item_meta.length,
      item_guid = item_meta.item_guid,
      take_name = item_meta.take_name,
      item_vol = item_meta.item_vol,
      take_vol = item_meta.take_vol,
    }

    ::continue_item::
  end

  if #errors > 0 then
    return false, table.concat(errors, "\n")
  end

  -- Second pass: clear the replacement region on all affected tracks.
  -- This handles both GUID-matched items and any leftover items from previous
  -- Return runs, preventing stacked/overlapping items.
  -- Use operations list (not hash table) to iterate tracks in deterministic order.
  local tracks_processed = {}
  for _, op in ipairs(operations) do
    if tracks_processed[op.track_guid] then goto continue_track end
    tracks_processed[op.track_guid] = true
    local track = op.track
    local track_idx = math.floor(reaper.GetMediaTrackInfo_Value(track, "IP_TRACKNUMBER"))
    if is_partial then
      -- Partial mode: split at boundaries, delete the middle.
      -- Must iterate in reverse position order so splits don't affect unprocessed items.
      local overlapping = find_items_overlapping(track, replace_region_start, replace_region_end)
      reaper.ShowConsoleMsg("[CEDAR] Track " .. track_idx .. ": clearing " .. #overlapping .. " overlapping item(s)\n")
      table.sort(overlapping, function(a, b)
        return reaper.GetMediaItemInfo_Value(a, "D_POSITION") >
               reaper.GetMediaItemInfo_Value(b, "D_POSITION")
      end)
      for _, item in ipairs(overlapping) do
        local item_pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
        local item_end = item_pos + reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
        local replace_start = math.max(item_pos, sel_start)
        local replace_end = math.min(item_end, sel_end)
        if replace_start < replace_end then
          if replace_end < item_end then
            reaper.SplitMediaItem(item, replace_end)
          end
          local middle_item = item
          if replace_start > item_pos then
            middle_item = reaper.SplitMediaItem(item, replace_start)
          end
          reaper.DeleteTrackMediaItem(track, middle_item)
        end
      end
    else
      -- Full mode: delete all overlapping items. Iterate in reverse index order
      -- so deletion doesn't shift indices of items we haven't processed yet.
      local num_items = reaper.CountTrackMediaItems(track)
      reaper.ShowConsoleMsg("[CEDAR] Track " .. track_idx .. ": scanning " .. num_items .. " item(s) for deletion\n")
      for i = num_items - 1, 0, -1 do
        local item = reaper.GetTrackMediaItem(track, i)
        local pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
        local len = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
        if pos + len > replace_region_start and pos < replace_region_end then
          reaper.DeleteTrackMediaItem(track, item)
        end
      end
    end
    ::continue_track::
  end

  -- Third pass: create new CEDAR items
  for _, op in ipairs(operations) do
    local position, length
    if is_partial then
      position = math.max(op.item_position, sel_start)
      local item_end = math.min(op.item_position + op.item_length, sel_end)
      length = item_end - position
      if length <= 0 then goto continue_create end
    else
      position = op.item_position
      length = op.item_length
    end

    create_cedar_item(op.track, op.first_out_ch, op.playback_channels,
      position, length, metadata.range_start, wav_path, op.take_name, op.item_vol, op.take_vol)

    ::continue_create::
  end

  return true, nil
end

---------------------------------------------------------------------------
-- Main
---------------------------------------------------------------------------

local function main()
  -- Load metadata
  local metadata, err = load_metadata()
  if not metadata then
    reaper.ShowConsoleMsg("[CEDAR] ERROR: " .. err .. "\n")
    return
  end

  -- Validate processed WAV
  local wav_path, val_err = validate_processed_wav(metadata)
  if not wav_path then
    reaper.ShowConsoleMsg("[CEDAR] ERROR: " .. val_err .. "\n")
    return
  end

  local item_count = #metadata.items

  -- Begin undo block
  reaper.Undo_BeginBlock()
  reaper.PreventUIRefresh(1)

  -- Replace items
  local ok, replace_err = replace_items(metadata, wav_path)

  reaper.PreventUIRefresh(-1)
  reaper.UpdateArrange()
  reaper.UpdateTimeline()
  -- Force peak rebuild for new items
  reaper.Main_OnCommand(40047, 0)  -- Build any missing peak files

  if ok then
    reaper.Undo_EndBlock("Return from CEDAR Retouch", -1)
    reaper.ShowConsoleMsg("[CEDAR] Replaced " .. item_count .. " item(s). Ctrl+Z to undo.\n")
    reaper.ShowConsoleMsg("[CEDAR] To re-edit: make changes in CEDAR, save, run Return again.\n")
  else
    -- Undo the partial changes
    reaper.Undo_EndBlock("Return from CEDAR Retouch (failed)", -1)
    reaper.Main_OnCommand(40029, 0) -- Edit: Undo
    reaper.ShowConsoleMsg("[CEDAR] ERROR: " .. replace_err .. "\n")
    reaper.ShowConsoleMsg("[CEDAR] All changes have been undone.\n")
  end
end

main()
