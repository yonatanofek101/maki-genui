-- Live widget registry: widget id -> RegistryEntry (see schema.lua types).
-- Entries are what `ui_update`/`ui_close` act on and what `restore` consults
-- when a live widget's tool fell out of the host's warm window. No timers;
-- cleanup happens on put (eviction), close, and SessionEnd/SessionReset.

local Registry = { MAX_LIVE = 16 }

local entries = {} -- id -> entry
local order = {} -- ids, insertion order
local counter = 0

local function now()
  if os and os.time then
    return os.time()
  end
  return 0
end

local function index_of(id)
  for i, x in ipairs(order) do
    if x == id then
      return i
    end
  end
  return nil
end

local function drop(id)
  local e = entries[id]
  if not e then
    return false
  end
  e.closed = true
  entries[id] = nil
  local i = index_of(id)
  if i then
    table.remove(order, i)
  end
  return true
end

function Registry.new_id()
  local id
  repeat
    counter = counter + 1
    id = "w" .. counter
  until entries[id] == nil
  return id
end

function Registry.put(entry)
  if type(entry) ~= "table" or type(entry.id) ~= "string" or entry.id == "" then
    return nil
  end
  entry.created_at = entry.created_at or now()
  entry.closed = false
  local id = entry.id
  if entries[id] then
    entries[id] = entry
  else
    entries[id] = entry
    order[#order + 1] = id
  end
  while #order > Registry.MAX_LIVE do
    drop(order[1])
  end
  return entry
end

function Registry.get(id)
  if type(id) ~= "string" then
    return nil
  end
  local e = entries[id]
  if e and not e.closed then
    return e
  end
  return nil
end

function Registry.remove(id)
  if type(id) ~= "string" then
    return false
  end
  return drop(id)
end

function Registry.clear_session(session_id)
  if session_id == nil then
    return 0
  end
  local n = 0
  local ids = {}
  for _, id in ipairs(order) do
    ids[#ids + 1] = id
  end
  for _, id in ipairs(ids) do
    local e = entries[id]
    if e and e.session_id == session_id then
      drop(id)
      n = n + 1
    end
  end
  return n
end

function Registry.list()
  local out = {}
  for _, id in ipairs(order) do
    local e = entries[id]
    if e then
      out[#out + 1] = e
    end
  end
  return out
end

function Registry._reset()
  for _, id in ipairs(order) do
    local e = entries[id]
    if e then
      e.closed = true
    end
  end
  entries = {}
  order = {}
  counter = 0
end

return Registry
