-- Send to CEDAR Retouch
-- Exports selected items across tracks to a single multichannel WAV,
-- launches CEDAR Retouch, and copies the WAV path to clipboard.

-- Logging
local function log(msg)
  reaper.ShowConsoleMsg("[CEDAR] " .. msg .. "\n")
end

-- Constants
local BLOCK_SIZE = 65536
local BIT_DEPTH = 24
local BYTES_PER_SAMPLE = BIT_DEPTH / 8
local CEDAR_APP_PATH = "/Applications/CEDARRetouch.app"
local ROUNDTRIP_SUBDIR = "cedar_roundtrip"
local EXTSTATE_SECTION = "CEDAR_Roundtrip"

---------------------------------------------------------------------------
-- WAV writer (pure Lua, 24-bit PCM)
---------------------------------------------------------------------------

local function write_wav_header(f, num_channels, sample_rate, num_samples)
  local byte_rate = sample_rate * num_channels * BYTES_PER_SAMPLE
  local block_align = num_channels * BYTES_PER_SAMPLE
  local data_size = num_samples * num_channels * BYTES_PER_SAMPLE
  local chunk_size = 36 + data_size

  f:write("RIFF")
  f:write(string.pack("<I4", chunk_size))
  f:write("WAVE")

  -- fmt sub-chunk
  f:write("fmt ")
  f:write(string.pack("<I4", 16))           -- sub-chunk size
  f:write(string.pack("<I2", 1))            -- PCM format
  f:write(string.pack("<I2", num_channels))
  f:write(string.pack("<I4", sample_rate))
  f:write(string.pack("<I4", byte_rate))
  f:write(string.pack("<I2", block_align))
  f:write(string.pack("<I2", BIT_DEPTH))

  -- data sub-chunk header
  f:write("data")
  f:write(string.pack("<I4", data_size))
end

local function pack_samples_24bit(interleaved_floats, count)
  local parts = {}
  for i = 1, count do
    local s = interleaved_floats[i]
    -- clamp to [-1, 1]
    if s > 1.0 then s = 1.0 elseif s < -1.0 then s = -1.0 end
    local int_val = math.floor(s * 8388607 + 0.5) -- 2^23 - 1
    if int_val < 0 then int_val = int_val + 16777216 end -- 2^24
    parts[#parts + 1] = string.pack("<I2B",
      int_val & 0xFFFF,
      (int_val >> 16) & 0xFF)
  end
  return table.concat(parts)
end

---------------------------------------------------------------------------
-- JSON encoder (minimal, sufficient for metadata)
---------------------------------------------------------------------------

local function json_encode_value(val)
  local t = type(val)
  if t == "string" then
    return '"' .. val:gsub('\\', '\\\\'):gsub('"', '\\"'):gsub('\n', '\\n') .. '"'
  elseif t == "number" then
    return tostring(val)
  elseif t == "boolean" then
    return val and "true" or "false"
  elseif t == "nil" then
    return "null"
  elseif t == "table" then
    -- detect array vs object
    if #val > 0 or next(val) == nil then
      local items = {}
      for i = 1, #val do
        items[i] = json_encode_value(val[i])
      end
      return "[" .. table.concat(items, ",") .. "]"
    else
      local items = {}
      for k, v in pairs(val) do
        items[#items + 1] = json_encode_value(tostring(k)) .. ":" .. json_encode_value(v)
      end
      return "{" .. table.concat(items, ",") .. "}"
    end
  end
  return "null"
end

local function json_encode(tbl)
  return json_encode_value(tbl)
end

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

local function get_track_guid(track)
  return reaper.GetTrackGUID(track)
end

local function get_item_guid(item)
  local _, guid = reaper.GetSetMediaItemInfo_String(item, "GUID", "", false)
  return guid
end

local function get_output_dir()
  local _, project_path = reaper.EnumProjects(-1, "")
  if project_path and project_path ~= "" then
    local dir = project_path:match("(.+)[/\\]")
    if dir then
      return dir .. "/" .. ROUNDTRIP_SUBDIR
    end
  end
  -- Fallback to temp directory
  local tmpdir = os.getenv("TMPDIR") or "/tmp"
  -- Ensure trailing separator
  if tmpdir:sub(-1) ~= "/" then tmpdir = tmpdir .. "/" end
  return tmpdir .. ROUNDTRIP_SUBDIR
end

local function ensure_directory(path)
  reaper.RecursiveCreateDirectory(path, 0)
end

local function generate_filename()
  return "cedar_roundtrip_" .. os.date("%Y%m%d_%H%M%S") .. ".wav"
end

---------------------------------------------------------------------------
-- WAV header reader (fallback when REAPER API returns 0)
---------------------------------------------------------------------------

local function read_wav_header(path)
  local f = io.open(path, "rb")
  if not f then return 0, 0 end
  local header = f:read(44)
  f:close()
  if not header or #header < 44 then return 0, 0 end
  local riff = header:sub(1, 4)
  local wave = header:sub(9, 12)
  if riff ~= "RIFF" or wave ~= "WAVE" then return 0, 0 end
  local num_channels = string.unpack("<I2", header, 23)
  local sample_rate = string.unpack("<I4", header, 25)
  return sample_rate, num_channels
end

local function read_wav_sample_rate(path)
  local sr, _ = read_wav_header(path)
  return sr
end

local function read_wav_num_channels(path)
  local _, ch = read_wav_header(path)
  return ch
end

---------------------------------------------------------------------------
-- Validation
---------------------------------------------------------------------------

-- Determine how many channels to export for a take and which source channels to read.
-- Returns: playback_channels (int), source_channels_to_read (list of 1-based indices),
--          is_downmix (bool)
local function get_take_channel_info(take, num_src_channels)
  local chanmode = math.floor(reaper.GetMediaItemTakeInfo_Value(take, "I_CHANMODE"))

  if chanmode == 0 then
    -- Normal: all source channels
    local channels = {}
    for c = 1, num_src_channels do channels[c] = c end
    return num_src_channels, channels
  elseif chanmode == 1 then
    -- Reverse stereo: swap L/R
    if num_src_channels >= 2 then
      return 2, {2, 1}
    end
    return 1, {1}
  elseif chanmode == 2 then
    -- Mono downmix: sum all source channels
    local channels = {}
    for c = 1, num_src_channels do channels[c] = c end
    return 1, channels, true
  elseif chanmode >= 67 then
    -- Stereo pair at channel offset: 67=ch1+2, 69=ch3+4, etc.
    local offset = chanmode - 67  -- 0-based offset into source channels
    local ch1 = offset + 1       -- 1-based
    local ch2 = offset + 2
    if ch2 > num_src_channels then ch2 = num_src_channels end
    if ch1 > num_src_channels then ch1 = num_src_channels end
    return 2, {ch1, ch2}
  else
    -- Mono channel extraction: chanmode 3=ch1, 4=ch2, 5=ch3, etc.
    local src_ch = chanmode - 2  -- 1-based source channel
    if src_ch > num_src_channels then src_ch = 1 end
    return 1, {src_ch}
  end
end

local function select_items_in_time_selection()
  local ts_start, ts_end = reaper.GetSet_LoopTimeRange(false, false, 0, 0, false)
  if ts_start == ts_end then
    return false, "No items selected and no time selection."
  end
  local count = 0
  local num_tracks = reaper.CountTracks(0)
  for t = 0, num_tracks - 1 do
    local track = reaper.GetTrack(0, t)
    local num_items = reaper.CountTrackMediaItems(track)
    for i = 0, num_items - 1 do
      local item = reaper.GetTrackMediaItem(track, i)
      local pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
      local len = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
      if pos + len > ts_start and pos < ts_end then
        reaper.SetMediaItemSelected(item, true)
        count = count + 1
      end
    end
  end
  if count == 0 then
    return false, "No items overlap the time selection."
  end
  return true, nil
end

local function validate_selection()
  local num_items = reaper.CountSelectedMediaItems(0)
  if num_items == 0 then
    local ok, err = select_items_in_time_selection()
    if not ok then return nil, err end
    num_items = reaper.CountSelectedMediaItems(0)
  end

  local sample_rate = nil
  local items = {}

  for i = 0, num_items - 1 do
    local item = reaper.GetSelectedMediaItem(0, i)
    local take = reaper.GetActiveTake(item)
    if not take then
      return nil, "Item " .. (i + 1) .. " has no active take."
    end
    if reaper.TakeIsMIDI(take) then
      return nil, "Item " .. (i + 1) .. " is MIDI. Only audio items are supported."
    end

    local source = reaper.GetMediaItemTake_Source(take)

    -- Walk to root source (section sources return sr=0)
    local root = source
    while true do
      local parent = reaper.GetMediaSourceParent(root)
      if not parent then break end
      root = parent
    end

    -- GetMediaSourceSampleRate can return 0 for sources not yet peaked.
    -- Fall back to reading the WAV header directly.
    local sr = reaper.GetMediaSourceSampleRate(root)
    if sr == 0 then sr = reaper.GetMediaSourceSampleRate(source) end
    if sr == 0 then
      local src_file = reaper.GetMediaSourceFileName(source, "")
      sr = read_wav_sample_rate(src_file)
    end
    if sr == 0 then
      return nil, "Item " .. (i + 1) .. " has unknown sample rate."
    end

    if sample_rate == nil then
      sample_rate = sr
    elseif sr ~= sample_rate then
      return nil, "Mixed sample rates detected (" .. sample_rate .. " vs " .. sr ..
        "). All items must share the same sample rate."
    end

    -- Get channel count (try direct source, root, then WAV header)
    local num_src_channels = reaper.GetMediaSourceNumChannels(source)
    if num_src_channels == 0 then
      num_src_channels = reaper.GetMediaSourceNumChannels(root)
    end
    if num_src_channels == 0 then
      local src_file = reaper.GetMediaSourceFileName(source, "")
      num_src_channels = read_wav_num_channels(src_file)
    end
    local playback_channels, src_read_channels, is_downmix = get_take_channel_info(take, num_src_channels)

    local track = reaper.GetMediaItem_Track(item)
    local track_idx = math.floor(reaper.GetMediaTrackInfo_Value(track, "IP_TRACKNUMBER"))
    local position = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
    local length = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
    local start_offset = reaper.GetMediaItemTakeInfo_Value(take, "D_STARTOFFS")
    local playrate = reaper.GetMediaItemTakeInfo_Value(take, "D_PLAYRATE")
    local chanmode = math.floor(reaper.GetMediaItemTakeInfo_Value(take, "I_CHANMODE"))
    local _, take_name = reaper.GetSetMediaItemTakeInfo_String(take, "P_NAME", "", false)
    local item_vol = reaper.GetMediaItemInfo_Value(item, "D_VOL")
    local take_vol = reaper.GetMediaItemTakeInfo_Value(take, "D_VOL")

    items[#items + 1] = {
      item = item,
      take = take,
      source = source,
      track = track,
      track_idx = track_idx,
      track_guid = get_track_guid(track),
      item_guid = get_item_guid(item),
      position = position,
      length = length,
      start_offset = start_offset,
      playrate = playrate,
      take_name = take_name,
      item_vol = item_vol,
      take_vol = take_vol,
      num_src_channels = num_src_channels,
      playback_channels = playback_channels,
      src_read_channels = src_read_channels,
      is_downmix = is_downmix or false,
      chanmode = chanmode,
    }
  end

  return {
    items = items,
    sample_rate = sample_rate,
  }, nil
end

---------------------------------------------------------------------------
-- Gather track/channel mapping and time range
---------------------------------------------------------------------------

local function build_channel_map(items)
  -- Assign output channels per unique track, sorted by track index.
  -- Each track gets as many output channels as its playback channel count.
  local track_set = {}
  local track_list = {}

  for _, info in ipairs(items) do
    if not track_set[info.track_guid] then
      track_set[info.track_guid] = true
      track_list[#track_list + 1] = {
        track_guid = info.track_guid,
        track_idx = info.track_idx,
        playback_channels = info.playback_channels,
      }
    end
  end

  table.sort(track_list, function(a, b) return a.track_idx < b.track_idx end)

  -- guid_to_channel maps track GUID to first output channel index (0-based)
  local guid_to_channel = {}
  local total_channels = 0
  for _, entry in ipairs(track_list) do
    guid_to_channel[entry.track_guid] = total_channels
    total_channels = total_channels + entry.playback_channels
  end

  return guid_to_channel, total_channels
end

local function compute_time_range(items)
  local range_start = math.huge
  local range_end = -math.huge

  for _, info in ipairs(items) do
    local item_start = info.position
    local item_end = info.position + info.length
    if item_start < range_start then range_start = item_start end
    if item_end > range_end then range_end = item_end end
  end

  return range_start, range_end
end

local function get_time_selection()
  local ts_start, ts_end = reaper.GetSet_LoopTimeRange(false, false, 0, 0, false)
  if ts_start ~= ts_end then
    return ts_start, ts_end
  end
  return nil, nil
end

---------------------------------------------------------------------------
-- Audio reading and WAV export
---------------------------------------------------------------------------

local function export_multichannel_wav(data, guid_to_channel, num_channels, range_start, range_end, wav_path)
  local sample_rate = data.sample_rate
  local total_duration = range_end - range_start
  local total_samples = math.ceil(total_duration * sample_rate)

  local f = io.open(wav_path, "wb")
  if not f then
    return false, "Cannot create WAV file: " .. wav_path
  end

  write_wav_header(f, num_channels, sample_rate, total_samples)

  -- Build item entries with accessors, grouped for processing
  local item_entries = {}
  for _, info in ipairs(data.items) do
    local first_out_ch = guid_to_channel[info.track_guid]
    local accessor = reaper.CreateTakeAudioAccessor(info.take)
    -- Force source load by requesting hash
    reaper.GetAudioAccessorHash(accessor, "")
    item_entries[#item_entries + 1] = {
      accessor = accessor,
      position = info.position,
      length = info.length,
      start_offset = info.start_offset,
      playrate = info.playrate,
      num_src_channels = info.num_src_channels,
      playback_channels = info.playback_channels,
      src_read_channels = info.src_read_channels,
      is_downmix = info.is_downmix,
      first_out_ch = first_out_ch,
    }
  end

  -- Process in blocks
  local samples_written = 0

  while samples_written < total_samples do
    local block_len = math.min(BLOCK_SIZE, total_samples - samples_written)
    local block_start_time = range_start + (samples_written / sample_rate)
    local block_end_time = block_start_time + (block_len / sample_rate)

    -- Initialize interleaved output (silence)
    local interleaved = {}
    for i = 1, block_len * num_channels do
      interleaved[i] = 0.0
    end

    for _, entry in ipairs(item_entries) do
      local item_start = entry.position
      local item_end = entry.position + entry.length

      -- Skip if no overlap with this block
      if block_start_time >= item_end or block_end_time <= item_start then
        goto continue_item
      end

      -- Read from the accessor. For CreateTakeAudioAccessor, starttime_sec
      -- is relative to the start of the take (the accessor handles D_STARTOFFS internally).
      local read_start = (block_start_time - item_start) * (entry.playrate or 1.0)
      local n_src = entry.num_src_channels
      local buf = reaper.new_array(block_len * n_src)
      buf.clear()
      local got = reaper.GetAudioAccessorSamples(
        entry.accessor, sample_rate, n_src, read_start, block_len, buf)
      local raw = buf.table()

      if not entry.logged_first_block then
        entry.logged_first_block = true
        local peak = 0
        for si = 1, #raw do
          if math.abs(raw[si]) > peak then peak = math.abs(raw[si]) end
        end
        log(string.format("  ch=%d got=%d read_start=%.4f peak=%.6f n_src=%d",
          entry.first_out_ch, got, read_start, peak, n_src))
        if got == 0 then
          -- Close file, destroy accessors, report error
          f:close()
          for _, e in ipairs(item_entries) do
            reaper.DestroyAudioAccessor(e.accessor)
          end
          return false, "GetAudioAccessorSamples returned 0 for output channel " ..
            entry.first_out_ch .. ". Source may not be loaded."
        end
      end

      -- Map source channels to output channels based on take channel mode
      if entry.is_downmix then
        -- Sum all source channels into one output channel
        local out_ch = entry.first_out_ch
        for s = 1, block_len do
          local project_time = block_start_time + ((s - 1) / sample_rate)
          if project_time >= item_start and project_time < item_end then
            local sum = 0
            for c = 1, n_src do
              sum = sum + raw[(s - 1) * n_src + c]
            end
            local idx = (s - 1) * num_channels + out_ch + 1
            interleaved[idx] = interleaved[idx] + sum / n_src
          end
        end
      else
        -- Map each source read channel to its output channel
        for out_idx, src_ch in ipairs(entry.src_read_channels) do
          local out_ch = entry.first_out_ch + (out_idx - 1)
          for s = 1, block_len do
            local project_time = block_start_time + ((s - 1) / sample_rate)
            if project_time >= item_start and project_time < item_end then
              local sample_val = raw[(s - 1) * n_src + src_ch]
              local idx = (s - 1) * num_channels + out_ch + 1
              interleaved[idx] = interleaved[idx] + sample_val
            end
          end
        end
      end

      ::continue_item::
    end

    -- Write block as 24-bit PCM
    f:write(pack_samples_24bit(interleaved, block_len * num_channels))
    samples_written = samples_written + block_len
  end

  -- Destroy accessors
  for _, entry in ipairs(item_entries) do
    reaper.DestroyAudioAccessor(entry.accessor)
  end

  f:close()
  return true, nil
end

---------------------------------------------------------------------------
-- Metadata
---------------------------------------------------------------------------

local function build_metadata(data, guid_to_channel, num_channels, range_start, range_end, wav_path, time_sel)
  local items_meta = {}
  for _, info in ipairs(data.items) do
    items_meta[#items_meta + 1] = {
      track_guid = info.track_guid,
      item_guid = info.item_guid,
      track_idx = info.track_idx,
      first_out_ch = guid_to_channel[info.track_guid],
      playback_channels = info.playback_channels,
      chanmode = info.chanmode,
      position = info.position,
      length = info.length,
      start_offset = info.start_offset,
      take_name = info.take_name,
      item_vol = info.item_vol,
      take_vol = info.take_vol,
    }
  end

  local meta = {
    wav_path = wav_path,
    sample_rate = data.sample_rate,
    num_channels = num_channels,
    range_start = range_start,
    range_end = range_end,
    items = items_meta,
    timestamp = os.date("%Y-%m-%d %H:%M:%S"),
  }

  -- If a time selection was used, record it so Return knows to split items
  if time_sel then
    meta.time_sel_start = time_sel.start_time
    meta.time_sel_end = time_sel.end_time
  end

  return meta
end

local function save_metadata(metadata, output_dir)
  local json_str = json_encode(metadata)

  -- Save to ExtState
  reaper.SetExtState(EXTSTATE_SECTION, "metadata", json_str, false)

  -- Save sidecar JSON
  local json_path = output_dir .. "/cedar_roundtrip_metadata.json"
  local f = io.open(json_path, "w")
  if f then
    f:write(json_str)
    f:close()
  end

  return json_path
end

---------------------------------------------------------------------------
-- CEDAR launch
---------------------------------------------------------------------------

local function launch_cedar(wav_path)
  -- Check if CEDAR exists
  local f_check = io.open(CEDAR_APP_PATH .. "/Contents/Info.plist", "r")
  if not f_check then
    return false, "CEDAR Retouch not found at " .. CEDAR_APP_PATH ..
      ". Install it or update CEDAR_APP_PATH in this script."
  end
  f_check:close()

  -- Copy WAV path to clipboard as fallback
  local pipe = io.popen("pbcopy", "w")
  if pipe then
    pipe:write(wav_path)
    pipe:close()
  end

  -- Launch CEDAR, then open the file after a delay (CEDAR needs time to start).
  -- Written to a temp script because os.execute("... &") is unreliable in REAPER Lua.
  local escaped_app = CEDAR_APP_PATH:gsub("'", "'\\''")
  local escaped_path = wav_path:gsub("'", "'\\''")

  local tmpdir = os.getenv("TMPDIR") or "/tmp"
  if tmpdir:sub(-1) ~= "/" then tmpdir = tmpdir .. "/" end
  local sh_path = tmpdir .. "cedar_launch.sh"
  local sh = io.open(sh_path, "w")
  if sh then
    sh:write("#!/bin/sh\n")
    sh:write("open -a '" .. escaped_app .. "'\n")
    sh:write("sleep 3\n")
    sh:write("open -a '" .. escaped_app .. "' '" .. escaped_path .. "'\n")
    sh:close()
    os.execute("chmod +x '" .. sh_path .. "' && '" .. sh_path .. "' &")
  end

  return true, nil
end

---------------------------------------------------------------------------
-- Main
---------------------------------------------------------------------------

local function main()
  -- Validate selection
  local data, err = validate_selection()
  if not data then
    log("ERROR: " .. err)
    return
  end

  -- Build channel map and time range
  local guid_to_channel, num_channels = build_channel_map(data.items)
  local range_start, range_end = compute_time_range(data.items)

  -- Log item details for diagnostics
  for idx, info in ipairs(data.items) do
    local src_file = reaper.GetMediaSourceFileName(info.source, "")
    log(string.format("Item %d: track=%d chanmode=%d src_ch=%d play_ch=%d read={%s} out_ch=%d src=%s",
      idx, info.track_idx, info.chanmode, info.num_src_channels, info.playback_channels,
      table.concat(info.src_read_channels, ","), guid_to_channel[info.track_guid],
      src_file:match("[^/]+$") or src_file))
  end

  -- Use time selection if one exists, otherwise use the selected items' range
  local ts_start, ts_end = get_time_selection()
  if ts_start then
    range_start = math.max(range_start, ts_start)
    range_end = math.min(range_end, ts_end)
    if range_start >= range_end then
      log("ERROR: Time selection does not overlap any selected items.")
      return
    end
  else
    -- No time selection: use the items' range as the time selection
    ts_start = range_start
    ts_end = range_end
  end

  -- Prepare output path
  local output_dir = get_output_dir()
  ensure_directory(output_dir)
  local wav_path = output_dir .. "/" .. generate_filename()

  -- Export multichannel WAV
  local ok, export_err = export_multichannel_wav(
    data, guid_to_channel, num_channels, range_start, range_end, wav_path)
  if not ok then
    log("ERROR: " .. export_err)
    return
  end

  -- Save metadata
  local time_sel = nil
  if ts_start then
    time_sel = { start_time = ts_start, end_time = ts_end }
  end
  local metadata = build_metadata(
    data, guid_to_channel, num_channels, range_start, range_end, wav_path, time_sel)
  save_metadata(metadata, output_dir)

  -- Launch CEDAR and copy path
  local launched, launch_err = launch_cedar(wav_path)
  if not launched then
    log("ERROR: " .. launch_err .. " -- WAV exported to: " .. wav_path)
    return
  end

  local total_duration = range_end - range_start
  log("Exported " .. num_channels .. " ch, " ..
    string.format("%.1f", total_duration) .. "s -> " .. wav_path)
  log("Opening in CEDAR Retouch. Path also on clipboard.")
  log("When done, save (overwrite) and run 'Return from CEDAR Retouch'.")
end

main()
