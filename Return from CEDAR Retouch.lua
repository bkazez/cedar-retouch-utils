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

local function find_item_by_guid(guid)
  local num_items = reaper.CountMediaItems(0)
  for i = 0, num_items - 1 do
    local item = reaper.GetMediaItem(0, i)
    local _, item_guid = reaper.GetSetMediaItemInfo_String(item, "GUID", "", false)
    if item_guid == guid then
      return item
    end
  end
  return nil
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

local function validate_processed_wav(metadata)
  local wav_path = metadata.wav_path
  local f = io.open(wav_path, "rb")
  if not f then
    return nil, "Processed WAV not found at:\n" .. wav_path ..
      "\n\nMake sure you saved the file in CEDAR Retouch (overwrite the original)."
  end

  -- Read WAV header to verify channel count
  local header = f:read(44)
  f:close()

  if not header or #header < 44 then
    return nil, "WAV file is too small or corrupt: " .. wav_path
  end

  local riff = header:sub(1, 4)
  local wave = header:sub(9, 12)
  if riff ~= "RIFF" or wave ~= "WAVE" then
    return nil, "File is not a valid WAV: " .. wav_path
  end

  local num_channels = string.unpack("<I2", header, 23)
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

local function create_cedar_item(track, first_out_ch, playback_channels, position, length, range_start, wav_path)
  local new_item = reaper.AddMediaItemToTrack(track)
  reaper.SetMediaItemInfo_Value(new_item, "D_POSITION", position)
  reaper.SetMediaItemInfo_Value(new_item, "D_LENGTH", length)

  local new_take = reaper.AddTakeToMediaItem(new_item)
  local source = reaper.PCM_Source_CreateFromFile(wav_path)
  reaper.SetMediaItemTake_Source(new_take, source)

  if playback_channels == 1 then
    -- Mono: extract single channel. I_CHANMODE 3+N extracts mono channel N (0-based).
    reaper.SetMediaItemTakeInfo_Value(new_take, "I_CHANMODE", 3 + first_out_ch)
  elseif playback_channels == 2 then
    -- Stereo pair: I_CHANMODE 67 + 2*offset selects stereo starting at that channel.
    -- 67=ch1+2, 69=ch3+4, 71=ch5+6, etc.
    reaper.SetMediaItemTakeInfo_Value(new_take, "I_CHANMODE", 67 + 2 * first_out_ch)
  end
  -- playback_channels > 2: left at I_CHANMODE 0 (normal), which reads from ch1.
  -- This only works correctly if first_out_ch == 0. Validated at export time.

  -- Start offset: item position relative to WAV start
  local offset_in_wav = position - range_start
  reaper.SetMediaItemTakeInfo_Value(new_take, "D_STARTOFFS", offset_in_wav)

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

  -- First pass: validate all items/tracks exist
  local operations = {}
  for _, item_meta in ipairs(metadata.items) do
    local track = find_track_by_guid(item_meta.track_guid)
    if not track then
      errors[#errors + 1] = "Track not found (GUID: " .. item_meta.track_guid ..
        ", was track #" .. item_meta.track_idx .. "). Was it deleted?"
      goto continue_item
    end

    local item = find_item_by_guid(item_meta.item_guid)
    if not item then
      errors[#errors + 1] = "Item not found (GUID: " .. item_meta.item_guid ..
        " on track #" .. item_meta.track_idx .. "). Was it deleted?"
      goto continue_item
    end

    operations[#operations + 1] = {
      item = item,
      track = track,
      first_out_ch = item_meta.first_out_ch,
      playback_channels = item_meta.playback_channels,
      item_position = item_meta.position,
      item_length = item_meta.length,
    }

    ::continue_item::
  end

  if #errors > 0 then
    return false, table.concat(errors, "\n")
  end

  -- Second pass: split (if partial) and replace
  if is_partial then
    -- Time-selection mode: split items at boundaries, replace only the middle
    for _, op in ipairs(operations) do
      local item = op.item
      local item_pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
      local item_end = item_pos + reaper.GetMediaItemInfo_Value(item, "D_LENGTH")

      -- Clamp replacement to where item and time selection overlap
      local replace_start = math.max(item_pos, sel_start)
      local replace_end = math.min(item_end, sel_end)
      if replace_start >= replace_end then goto continue_op end

      -- Split at selection end first (so the item reference stays valid for start split)
      local right_item = nil
      if replace_end < item_end then
        right_item = reaper.SplitMediaItem(item, replace_end)
      end

      -- Split at selection start (item becomes left portion, middle_item is the slice)
      local middle_item = item
      if replace_start > item_pos then
        middle_item = reaper.SplitMediaItem(item, replace_start)
      end

      -- Delete the middle slice
      local middle_track = reaper.GetMediaItem_Track(middle_item)
      reaper.DeleteTrackMediaItem(middle_track, middle_item)

      -- Insert CEDAR-processed item in its place
      create_cedar_item(op.track, op.first_out_ch, op.playback_channels,
        replace_start, replace_end - replace_start, metadata.range_start, wav_path)

      ::continue_op::
    end
  else
    -- Full-item mode: delete originals, create replacements
    for _, op in ipairs(operations) do
      local track = reaper.GetMediaItem_Track(op.item)
      reaper.DeleteTrackMediaItem(track, op.item)
    end

    for _, op in ipairs(operations) do
      create_cedar_item(op.track, op.first_out_ch, op.playback_channels,
        op.item_position, op.item_length, metadata.range_start, wav_path)
    end
  end

  return true, nil
end

---------------------------------------------------------------------------
-- Cleanup
---------------------------------------------------------------------------

local function cleanup_extstate()
  reaper.DeleteExtState(EXTSTATE_SECTION, "metadata", false)
end

---------------------------------------------------------------------------
-- Main
---------------------------------------------------------------------------

local function main()
  -- Load metadata
  local metadata, err = load_metadata()
  if not metadata then
    reaper.ShowMessageBox(err, "Return from CEDAR Retouch", 0)
    return
  end

  -- Validate processed WAV
  local wav_path, val_err = validate_processed_wav(metadata)
  if not wav_path then
    reaper.ShowMessageBox(val_err, "Return from CEDAR Retouch", 0)
    return
  end

  -- Confirm with user
  local item_count = #metadata.items
  local msg = "Ready to replace " .. item_count .. " item(s) with processed audio from:\n" ..
    wav_path .. "\n\nThis is undoable with Ctrl+Z.\n\nProceed?"
  local result = reaper.ShowMessageBox(msg, "Return from CEDAR Retouch", 1)
  if result ~= 1 then return end

  -- Begin undo block
  reaper.Undo_BeginBlock()
  reaper.PreventUIRefresh(1)

  -- Replace items
  local ok, replace_err = replace_items(metadata, wav_path)

  reaper.PreventUIRefresh(-1)
  reaper.UpdateTimeline()

  if ok then
    reaper.Undo_EndBlock("Return from CEDAR Retouch", -1)
    cleanup_extstate()
    reaper.ShowMessageBox(
      "Replaced " .. item_count .. " item(s) with CEDAR-processed audio.\n" ..
      "Use Ctrl+Z to undo.",
      "Return from CEDAR Retouch", 0)
  else
    -- Undo the partial changes
    reaper.Undo_EndBlock("Return from CEDAR Retouch (failed)", -1)
    reaper.Main_OnCommand(40029, 0) -- Edit: Undo
    reaper.ShowMessageBox(
      "Errors occurred during import:\n\n" .. replace_err ..
      "\n\nAll changes have been undone.",
      "Return from CEDAR Retouch", 0)
  end
end

main()
