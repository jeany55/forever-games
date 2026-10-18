--------------------------
--  Pinball Bench: report
--------------------------
-- Reads what the bench kept in the game's saved variables after a /reload, and prints it: the
-- last sweep, against the frame with nothing moving, and the games played since.
--
--   lua Tools/PinballBench/report.lua [PinballBench.lua] [games n]
--
-- Without a file it looks for the account's own under the game's folder, the same one install.sh
-- installs into (WOW_ADDONS's folder's WTF, or the classic beta's).

local path = arg[1] ~= "games" and arg[1] or nil
local showGames = 10
for index = 1, #arg do
  if arg[index] == "games" then
    showGames = tonumber(arg[index + 1]) or showGames
  end
end
if not path then
  local addons = os.getenv("WOW_ADDONS") or "/mnt/c/Program Files (x86)/World of Warcraft/_classic_beta_/Interface/AddOns"
  local wtf = addons:gsub("Interface/AddOns/?$", "WTF/Account")
  local found = io.popen('ls -t "' .. wtf .. '"/*/SavedVariables/PinballBench.lua 2>/dev/null')
  path = found and found:read("*l")
  if found then
    found:close()
  end
end
assert(path, "No PinballBench.lua in the saved variables: play or sweep, then /reload")
local chunk = assert(loadfile(path))
local saved = {}
setfenv(chunk, saved)
chunk()
local db = saved.PinballBenchDB or {}
print("From " .. path)

local function environment(e)
  if not e then
    return "?"
  end
  return ("client %s, screen %s, UI scale %.2f, vsync %s, maxFPS %s (on %s), view %s"):format(e.client, e.screen, e.uiScale or 0,
    e.vsync, e.maxFPS, e.useMaxFPS, e.view or "?")
end

local sweep = db.sweeps and db.sweeps[#db.sweeps]
if sweep then
  print(("\nSweep of %s%s\n  %s"):format(sweep.when, sweep.done and "" or " (stopped before the end)", environment(sweep.environment)))
  local base = sweep.results[1] and sweep.results[1].name == "baseline" and sweep.results[1].frameMs or 0
  print(("  %-26s %8s %8s %8s %8s %8s %6s"):format("", "frame", "+frame", "95%", "physics", "drawing", "ticks"))
  for _, r in ipairs(sweep.results) do
    print(("  %-26s %6.1f ms %+6.1f ms %6.1f ms %6.2f ms %6.2f ms %6.1f"):format(r.name, r.frameMs, r.frameMs - base, r.frame95Ms,
      r.physicsMs, r.drawMs, r.ticks))
  end
else
  print("\nNo sweep yet: /pinbench sweep")
end

local games = db.games or {}
if #games > 0 then
  print(("\nThe last %d of %d games played"):format(math.min(showGames, #games), #games))
  for index = math.max(1, #games - showGames + 1), #games do
    local g = games[index]
    print(("  %s  %4ds  score %8d, ball %d%s%s  %3.0f fps, 95%% %.1f ms, slowest %.0f ms, physics %.2f ms (most %.1f), drawing %.2f ms, %s")
      :format(g.when, g.seconds, g.score, g.ball, g.over and ", over" or "",
        g.replay and (g.replayedSame and ", replay exact" or g.replayedSame == false and ", REPLAY DIFFERED" or ", replay") or "",
        g.fps, g.frame95Ms, g.frameMostMs, g.physicsMs, g.physicsMostMs, g.drawMs, g.environment and g.environment.view or "?"))
  end
end

-- The settings changed from what they would be, as the last game or sweep had them
local DEFAULTS = {}
do
  local ns = {}
  local ok = pcall(function()
    assert(loadfile("Engine/Physics.lua"))("PinballBench", ns)
    assert(loadfile("Tools/PinballBench/Build.lua"))("PinballBench", ns)
  end)
  DEFAULTS = ok and ns.DEFAULTS or {}
end
local changed = {}
for key, value in pairs(db.tune or {}) do
  changed[#changed + 1] = ("%s = %s%s"):format(key, tostring(value), DEFAULTS[key] and (" (default %s)"):format(DEFAULTS[key]) or "")
end
table.sort(changed)
print("\nSettings changed with /pinbench set: " .. (#changed > 0 and table.concat(changed, ", ") or "none"))
