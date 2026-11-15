--------------------------
--  Shot Bench
--------------------------
-- Takes the screenshots for Forever Games' page (CurseForge and the like): every game set up the
-- way it is best seen (Session:Showcase, each game's `showcase`), in the window at the size it
-- starts out at, in the middle of the screen, with the rest of the client's interface out of the
-- way and the world behind it. Stand somewhere worth seeing first, the camera where you want it.
--
--   /shotbench all                 every game against people, one against the computer, the front
--                                  page, a turn coming in, and the window small
--   /shotbench <game id> [...]     only these (chess, 2048, freecell...), against people
--   /shotbench computer <id> [...] these against the computer
--   /shotbench home                the front page with games against people on it, none of yours
--   /shotbench social              your turn coming in, with links to games said in guild chat, and
--                                  the interface as it is. It clears the chat window first
--   /shotbench small [game id]     the small window in its corner, with the interface as it is
--   /shotbench new                 the new game wizard (it shows your own friends: only if you want)
--   /shotbench ui                  leave the interface as it is in the next run, or hide it again
--   /shotbench list                the game ids there are
--   /shotbench stop                give up
--
-- Any of them can follow each other in one go: /shotbench social small chess computer reversi
--
-- The game is the player's, called "Elowen" in it, against people with names of their own who
-- aren't there (nothing is sent to them) or against the computer, and is cleared away again after
-- its picture. Nothing of it is counted. Where the interface is shown, the frames with your
-- character's name in them aren't.
--
-- What is kept for each screenshot, in ShotBenchDB.shots (written out on /reload or logging
-- out): the game, the name the client gave the file (by the second it was taken in), where the
-- window was on the screen in pixels, and the same as one line for Tools/ShotBench/crop.py.

local _, ns = ...

local function say(text)
  print("|cff66ccffShot Bench|r: " .. text)
end

-- Seconds a game is given to be drawn, its pieces dealt and laid and its fades over, before its
-- picture, and to give up waiting for the client to say the screenshot is taken
local SETTLE, TIMEOUT = 3, 6
-- Seconds to get the mouse out of the way before the first
local COUNTDOWN = 5
-- The games pictured small at the end of `all`, with the client's interface as it is
local SMALL_GAMES = { "chess", "solitaire" }
-- Pictured against the computer in `all` as well, for it to be seen that it can be
local COMPUTER_GAMES = { "reversi" }
-- What is on the front page in its picture: games against people, some waiting on the player and
-- some on the others, and games for one
local HOME_GAMES = {
  { game = "words", setup = { people = true } },
  { game = "backgammon", setup = { people = true, waiting = true } },
  { game = "crazyeights", setup = { people = true } },
  { game = "connectfour", setup = { people = true, waiting = true } },
  { game = "realms", setup = { people = true, waiting = true } },
  { game = "yacht", setup = { people = true, waiting = true } },
  { game = "freecell" },
  { game = "sudoku" },
}
-- The turn that comes in, in the picture of what the player sees of the others, and what is said
-- in guild chat: games linked for whoever clicks first ({game id}). Said by a name, or by one of
-- the others in the game the turn is in, by number
local SOCIAL_GAME = "words"
local SOCIAL_CHAT = {
  { who = "Dravin", text = "anyone up for a game? {backgammon}" },
  { who = 1, text = "played my word, your go Elowen" },
  { who = 2, text = "{connectfour} first to click it plays me" },
}
-- The frames with the player's character's name in them, kept out of sight where the rest of the
-- interface is in the picture
local FACES = { "PlayerFrame", "TargetFrame", "FocusFrame", "PartyFrame", "PetFrame", "CompactRaidFrameContainer" }

-- Names over heads and speech bubbles aren't the interface's: hiding it leaves them
local NAMES = { "UnitNameOwn", "UnitNameNPC", "UnitNameNonCombatCreatureName", "UnitNameFriendlyPlayerName",
  "UnitNameFriendlyPetName", "UnitNameFriendlyGuardianName", "UnitNameFriendlyTotemName", "UnitNameFriendlyMinionName",
  "UnitNameFriendlySpecialNPCName", "UnitNameEnemyPlayerName", "UnitNameEnemyPetName", "UnitNameEnemyGuardianName",
  "UnitNameEnemyTotemName", "UnitNameEnemyMinionName", "UnitNameHostleNPC", "UnitNameInteractiveNPC",
  "UnitNamePlayerGuild", "nameplateShowAll", "nameplateShowEnemies", "nameplateShowFriends", "nameplateShowFriendlyNpcs",
  "nameplateShowSelf", "chatBubbles", "chatBubblesParty" }

local function cvar(name)
  local ok, value = pcall(C_CVar.GetCVar, name)
  return ok and value or nil
end

--- Sets a cvar, and says what it is now: the client keeps the old value for one it doesn't take
local function setCVar(name, value)
  pcall(C_CVar.SetCVar, name, tostring(value))
  return cvar(name)
end

local keepInterface = false
local run
local driver = CreateFrame("Frame")
driver:Hide()

--- The game ids there are, in the order the new game wizard lists them
local function gameIds()
  local ids = {}
  for _, game in ipairs(ForeverGamesAPI.Games.List()) do
    ids[#ids + 1] = game.id
  end
  return ids
end

--- Makes a frame see-through rather than hiding it, which the client won't let an addon do to
--- some of the interface, and which leaves nothing for it to tidy up. How it was is kept
local function fade(frame)
  if run.faded[frame] == nil then
    run.faded[frame] = frame:GetAlpha()
  end
  frame:SetAlpha(0)
end

local function unfade(frame)
  if run.faded[frame] ~= nil then
    frame:SetAlpha(run.faded[frame])
    run.faded[frame] = nil
  end
end

--- Everything of the client's interface out of sight but the window. What it was is taken the
--- first time: whatever comes up later (an effect of the game's own) is left as it is
local function hideInterface()
  if not run.interface then
    run.interface = {}
    for _, child in ipairs({ UIParent:GetChildren() }) do
      if child ~= ForeverGamesFrame and not (child.IsForbidden and child:IsForbidden()) then
        run.interface[#run.interface + 1] = child
      end
    end
  end
  for _, child in ipairs(run.interface) do
    fade(child)
  end
  for _, name in ipairs(NAMES) do
    local value = cvar(name)
    if value ~= nil and run.was.names[name] == nil then
      run.was.names[name] = value
      setCVar(name, 0)
    end
  end
end

--- Whether a frame or anything in it says the character's name, a few levels down: a unit frame
--- of another addon's, say, that the client's own names don't cover
local function named(frame, name, depth)
  -- A unit frame of the character's, whether or not its name can be read
  local mine = pcall(function()
    assert(frame.unit == "player" or (frame.GetAttribute and frame:GetAttribute("unit") == "player"))
  end)
  if mine then
    return true
  end
  for _, region in ipairs({ frame:GetRegions() }) do
    -- Text the client keeps from addons (a unit's name, in some clients) can't be looked into:
    -- that is no reason to give up on the rest
    local ok, found = pcall(function()
      return region.GetText ~= nil and region:IsVisible() and region:GetText():find(name, 1, true) ~= nil
    end)
    if ok and found then
      return true
    end
  end
  if depth > 0 then
    for _, child in ipairs({ frame:GetChildren() }) do
      if not (child.IsForbidden and child:IsForbidden()) and child:IsVisible() and named(child, name, depth - 1) then
        return true
      end
    end
  end
  return false
end

--- The interface as the player has it, but for the frames with their character's name in them
--- @param all boolean? Those too, as the run comes to an end
local function showInterface(all)
  local faded = {}
  for frame in pairs(run.faded) do
    faded[#faded + 1] = frame
  end
  for _, frame in ipairs(faded) do
    unfade(frame)
  end
  -- Names over heads stay off but at the end: the character's own is one of them
  if all then
    for name, value in pairs(run.was.names) do
      setCVar(name, value)
    end
    run.was.names = {}
  else
    for _, name in ipairs(NAMES) do
      local value = cvar(name)
      if value ~= nil and run.was.names[name] == nil then
        run.was.names[name] = value
        setCVar(name, 0)
      end
    end
  end
  if not all then
    for _, name in ipairs(FACES) do
      if _G[name] then
        fade(_G[name])
      end
    end
    -- And whatever else has it in, but the chat, which is cleared where it is in the picture
    local me = UnitName("player")
    for _, child in ipairs({ UIParent:GetChildren() }) do
      -- A protected frame can't even be asked what it is
      local ok, has = pcall(function()
        return me and child ~= ForeverGamesFrame and not (child.IsForbidden and child:IsForbidden())
          and child:GetObjectType() ~= "ScrollingMessageFrame" and child:IsVisible() and named(child, me, 4)
      end)
      if ok and has then
        fade(child)
      end
    end
  end
end

--- Where a frame is on the screen, in pixels from the top left: left, top, right, bottom
local function pixels(frame)
  local width, height = GetPhysicalScreenSize()
  local scale = frame:GetEffectiveScale()
  -- The client's units across the whole screen, in pixels
  local unit = height / (UIParent:GetHeight() * UIParent:GetEffectiveScale())
  local left, top = frame:GetLeft() * scale * unit, height - frame:GetTop() * scale * unit
  local right, bottom = frame:GetRight() * scale * unit, height - frame:GetBottom() * scale * unit
  return math.floor(left + 0.5), math.floor(top + 0.5), math.floor(right + 0.5), math.floor(bottom + 0.5), width, height
end

local function finish(why)
  if not run then
    return
  end
  driver:Hide()
  quietChat(false)
  showInterface(true)
  setCVar("screenshotFormat", run.was.format)
  setCVar("screenshotQuality", run.was.quality)
  pcall(ForeverGames.EndShowcase, ForeverGames)
  -- The window as the player had it
  local window = ForeverGames.db.profile.window
  window.width, window.height, window.small = run.was.width, run.was.height, run.was.small
  ForeverGames.db.profile.smallFade = run.was.smallFade
  if ForeverGamesFrame then
    ForeverGamesFrame:SetSize(window.width, window.height)
  end
  local taken, failed = 0, 0
  for _, shot in ipairs(run.taken) do
    if shot.failed or shot.timedOut then
      failed = failed + 1
    else
      taken = taken + 1
    end
  end
  run = nil
  if why then
    say(why)
  end
  say(("%d screenshots%s. /reload (or log out) to write them out, then tell Claude"):format(taken,
    failed > 0 and (" (|cffff4040%d failed|r)"):format(failed) or ""))
end

--- Keeps what there is to know about a screenshot, as fields and as one line
local function keep(shot)
  local fields = {}
  for _, key in ipairs({ "id", "kind", "game", "vs", "called", "done", "format", "left", "top", "right", "bottom", "width",
    "height", "log", "failed", "problem" }) do
    if shot[key] ~= nil then
      fields[#fields + 1] = key .. "=" .. tostring(shot[key] == true and 1 or shot[key])
    end
  end
  shot.line = table.concat(fields, "|")
  table.insert(ShotBenchDB.shots, shot)
end

--- A game's name, the way it is said in a link to it in chat (GUI/Links.lua)
local function linkTo(gameId, host)
  local game = ForeverGamesAPI.Games.Get(gameId)
  if not game then
    return gameId
  end
  return ("|cff71d5ff|Haddon:ForeverGames:%s:%s|h[Forever Games: %s]|h|r"):format(game.id, host, game.name)
end

--- Keeps the chat window to what is said for the picture: what anybody really says meanwhile (a
--- guildmate's name) and the bench's own lines are left out until it is taken
local function quietChat(on)
  local frame = DEFAULT_CHAT_FRAME
  if on and not run.chatAdd then
    run.chatAdd = frame.AddMessage
    frame.AddMessage = function(self, ...)
      if run and run.saying then
        return run.chatAdd(self, ...)
      end
    end
  elseif not on and run.chatAdd then
    frame.AddMessage = run.chatAdd
    run.chatAdd = nil
  end
end

--- Says something in guild chat as somebody else would have, in the chat window
local function guildSays(who, text)
  local frame = DEFAULT_CHAT_FRAME
  local info = ChatTypeInfo and ChatTypeInfo.GUILD or { r = 0.25, g = 1, b = 0.25 }
  local prefix = (CHAT_GUILD_GET or "[Guild] %s: "):format(("|Hplayer:%s|h[%s]|h"):format(who, who))
  text = text:gsub("{(%w+)}", function(gameId)
    return linkTo(gameId, who)
  end)
  run.saying = true
  frame:AddMessage(prefix .. text, info.r, info.g, info.b)
  run.saying = nil
end

--- The others in a game, by seat
local function othersIn(match)
  local others = {}
  for seat, name in ipairs(match.players) do
    if seat ~= match.me then
      others[#others + 1] = name
    end
  end
  return others
end

--- Sets up what the next screenshot is of. False if there is nothing to take of it
local function stage(item)
  -- Put away by EndShowcase, and opened again on what is to be seen. The chat as it was
  quietChat(false)
  ForeverGames:EndShowcase()
  if item.kind == "new" then
    ForeverGames:HandleSlashCommand("new")
    return true
  elseif item.kind == "home" then
    return ForeverGames:ShowcaseHome(HOME_GAMES) > 0
  elseif item.kind == "social" then
    local match, err = ForeverGames:ShowcaseToast(SOCIAL_GAME, { people = true })
    if not match then
      say(("|cffff4040%s couldn't be set up:|r %s"):format(SOCIAL_GAME, tostring(err)))
      return false
    end
    local others = othersIn(match)
    quietChat(true)
    DEFAULT_CHAT_FRAME:Clear()
    for _, line in ipairs(SOCIAL_CHAT) do
      guildSays(type(line.who) == "number" and (others[line.who] or "Corwyn") or line.who, line.text)
    end
    return true
  end
  local setup = item.vs ~= "computer" and { people = true } or nil
  local ok, match, err = pcall(ForeverGames.Showcase, ForeverGames, item.game, setup)
  if not ok or not match then
    say(("|cffff4040%s couldn't be set up:|r %s"):format(item.game, tostring(ok and err or match)))
    return false
  end
  item.log = #match.log
  if item.kind == "small" then
    -- The chat in the picture with nothing in it: the bench's own lines and other addons' aren't
    -- what the picture is of
    quietChat(true)
    DEFAULT_CHAT_FRAME:Clear()
    ForeverGames:HandleSlashCommand("small")
  end
  return true
end

driver:RegisterEvent("SCREENSHOT_SUCCEEDED")
driver:RegisterEvent("SCREENSHOT_FAILED")
driver:SetScript("OnEvent", function(_, event)
  if run and run.phase == "waiting" then
    local shot = run.taken[#run.taken]
    shot.done = date("%m%d%y_%H%M%S")
    shot.failed = event == "SCREENSHOT_FAILED" or nil
    keep(shot)
    run.phase, run.clock = "next", 0
  end
end)

driver:SetScript("OnUpdate", function(_, elapsed)
  if not run then
    driver:Hide()
    return
  end
  run.clock = run.clock + elapsed
  if InCombatLockdown() then
    finish("|cffff4040Given up: you are in combat|r")
    return
  end
  if run.phase == "countdown" then
    if run.clock >= COUNTDOWN then
      run.phase, run.clock = "next", 0
    end
  elseif run.phase == "next" then
    run.index = run.index + 1
    local item = run.queue[run.index]
    if not item then
      finish()
      return
    end
    local ok, staged = pcall(stage, item)
    if not ok then
      say(("|cffff4040%s went wrong:|r %s"):format(item.game or item.kind, tostring(staged)))
    end
    if ok and staged then
      -- Taken whatever happens to the interface: what went wrong is said, once
      local withInterface = item.kind == "small" or item.kind == "social" or keepInterface
      local shown, err = pcall(withInterface and showInterface or hideInterface)
      -- Kept with the screenshot too: in a picture with the chat in it, nothing more is said there
      item.problem = not shown and tostring(err):gsub("[|=]", " ") or nil
      if not shown and not run.complained then
        run.complained = true
        say("|cffff4040The interface couldn't all be put out of the way:|r " .. tostring(err))
      end
      run.phase, run.clock = "settle", 0
    end
  elseif run.phase == "settle" then
    -- A second of its own for each, as the client names screenshots by the second
    if run.clock >= SETTLE and time() ~= run.lastSecond then
      run.lastSecond = time()
      local item = run.queue[run.index]
      local frame = ForeverGamesFrame
      local shot = { id = #ShotBenchDB.shots + 1, kind = item.kind, game = item.game, vs = item.vs,
        called = date("%m%d%y_%H%M%S"), format = run.format, log = item.log, problem = item.problem }
      if item.kind ~= "small" and item.kind ~= "social" and frame and frame:IsShown() then
        shot.left, shot.top, shot.right, shot.bottom, shot.width, shot.height = pixels(frame)
      else
        shot.width, shot.height = GetPhysicalScreenSize()
      end
      run.taken[#run.taken + 1] = shot
      run.phase, run.clock = "waiting", 0
      Screenshot()
    end
  elseif run.phase == "waiting" then
    if run.clock >= TIMEOUT then
      local shot = run.taken[#run.taken]
      shot.timedOut = true
      keep(shot)
      run.phase, run.clock = "next", 0
    end
  end
end)

local function start(queue)
  if run then
    say("Already taking them: /shotbench stop gives up")
    return
  end
  if InCombatLockdown() then
    say("|cffff4040Not in combat|r")
    return
  end
  if type(Screenshot) ~= "function" or not (ForeverGames and ForeverGames.Showcase) then
    say("|cffff4040This client has no Screenshot for addons, or Forever Games has no showcases|r")
    return
  end
  if #queue == 0 then
    say("Nothing to take")
    return
  end
  local window = ForeverGames.db.profile.window
  run = { queue = queue, index = 0, taken = {}, clock = 0, phase = "countdown", faded = {},
    was = { format = cvar("screenshotFormat"), quality = cvar("screenshotQuality"), width = window.width,
      height = window.height, small = window.small, smallFade = ForeverGames.db.profile.smallFade, names = {} } }
  -- The small window as it is with the mouse over it, not faded the way it is while it is elsewhere
  ForeverGames.db.profile.smallFade = false
  -- Lossless where the client can, at its best otherwise
  run.format = setCVar("screenshotFormat", "png")
  if run.format ~= "png" then
    run.format = setCVar("screenshotFormat", "jpeg")
    setCVar("screenshotQuality", 10)
  end
  -- The window at the size it starts out at, in the middle of the screen
  local usual = ForeverGames.db.defaults.profile.window
  window.width, window.height = usual.width, usual.height
  if not ForeverGamesFrame then
    ForeverGames:HandleSlashCommand("")
  end
  ForeverGamesFrame:ClearAllPoints()
  ForeverGamesFrame:SetPoint("CENTER")
  ForeverGamesFrame:SetSize(window.width, window.height)
  say(("%d to take, %s apart. Move the mouse out of the way: starting in %d seconds"):format(#queue,
    SETTLE .. " seconds", COUNTDOWN))
  driver:Show()
end

SLASH_SHOTBENCH1 = "/shotbench"
SlashCmdList.SHOTBENCH = function(input)
  local words = {}
  for word in (input or ""):lower():gmatch("%S+") do
    words[#words + 1] = word
  end
  local command = words[1] or ""
  local known = {}
  for _, id in ipairs(gameIds()) do
    known[id] = true
  end
  if command == "all" then
    local queue = {}
    for _, id in ipairs(gameIds()) do
      queue[#queue + 1] = { kind = "game", game = id }
    end
    for _, id in ipairs(COMPUTER_GAMES) do
      if known[id] then
        queue[#queue + 1] = { kind = "game", game = id, vs = "computer" }
      end
    end
    queue[#queue + 1] = { kind = "home" }
    queue[#queue + 1] = { kind = "social" }
    for _, id in ipairs(SMALL_GAMES) do
      if known[id] then
        queue[#queue + 1] = { kind = "small", game = id }
      end
    end
    start(queue)
  elseif command == "ui" then
    keepInterface = not keepInterface
    say(keepInterface and "The interface is left as it is" or "The interface is hidden for them")
  elseif command == "list" then
    say(table.concat(gameIds(), ", "))
  elseif command == "stop" then
    finish("Given up")
  elseif command ~= "" then
    -- Any of the pictures there are, one after the other: games (against the computer after
    -- `computer`), the front page, the social one, the wizard, and a game small
    local queue, vs = {}, nil
    local index = 1
    while index <= #words do
      local word = words[index]
      if word == "computer" then
        vs = "computer"
      elseif word == "home" or word == "social" or word == "new" then
        queue[#queue + 1] = { kind = word }
      elseif word == "small" then
        local id = known[words[index + 1] or ""] and words[index + 1] or SMALL_GAMES[1]
        if id == words[index + 1] then
          index = index + 1
        end
        queue[#queue + 1] = { kind = "small", game = id }
      elseif known[word] then
        queue[#queue + 1] = { kind = "game", game = word, vs = vs }
      else
        return say("No game or picture " .. word .. ": /shotbench list")
      end
      index = index + 1
    end
    start(queue)
  else
    say("/shotbench all | <game id> ... | computer <game id> ... | home | social | small [game id] | new | ui | list | stop")
  end
end

local loader = CreateFrame("Frame")
loader:RegisterEvent("PLAYER_LOGIN")
loader:SetScript("OnEvent", function()
  ShotBenchDB = ShotBenchDB or {}
  ShotBenchDB.shots = ShotBenchDB.shots or {}
  say(("loaded, %d screenshots kept. Stand somewhere worth seeing, then /shotbench all"):format(#ShotBenchDB.shots))
end)
