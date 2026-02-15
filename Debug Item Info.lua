-- Debug Item Info: Show clip gain and other properties for selected items
local num_items = reaper.CountSelectedMediaItems(0)
if num_items == 0 then
  reaper.ShowConsoleMsg("[DEBUG] No items selected.\n")
  return
end

for i = 0, num_items - 1 do
  local item = reaper.GetSelectedMediaItem(0, i)
  local take = reaper.GetActiveTake(item)
  local track = reaper.GetMediaItem_Track(item)
  local track_idx = math.floor(reaper.GetMediaTrackInfo_Value(track, "IP_TRACKNUMBER"))

  local d_vol = reaper.GetMediaItemInfo_Value(item, "D_VOL")
  local d_vol_db = 20 * math.log(d_vol, 10)

  local take_vol = 0
  local take_vol_db = 0
  local take_name = ""
  if take then
    take_vol = reaper.GetMediaItemTakeInfo_Value(take, "D_VOL")
    take_vol_db = 20 * math.log(take_vol, 10)
    local _, name = reaper.GetSetMediaItemTakeInfo_String(take, "P_NAME", "", false)
    take_name = name
  end

  reaper.ShowConsoleMsg(string.format(
    "[DEBUG] Item %d (track %d): D_VOL=%.6f (%.2f dB)  take D_VOL=%.6f (%.2f dB)  name=%s\n",
    i + 1, track_idx, d_vol, d_vol_db, take_vol, take_vol_db, take_name))
end
