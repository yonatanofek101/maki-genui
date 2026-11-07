-- Registry suite: put/get/remove/eviction/clear_session.
local Registry = require("genui.registry")

local function entry(id, session)
  return {
    id = id,
    buf = {},
    spec = { id = id, root = { type = "stack", id = "c1", children = {} }, warnings = {} },
    state = { v = 1 },
    card = {},
    session_id = session,
  }
end

return function(h)
  h.case("new_id counts up from a fresh state", function()
    Registry._reset()
    h.eq(Registry.new_id(), "w1")
    h.eq(Registry.new_id(), "w2")
  end)

  h.case("new_id skips ids in use", function()
    Registry._reset()
    Registry.put(entry("w1", "s"))
    h.eq(Registry.new_id(), "w2")
  end)

  h.case("put/get/remove", function()
    Registry._reset()
    local e = Registry.put(entry("a", "s1"))
    h.eq(e.closed, false)
    h.ok(type(e.created_at) == "number", "created_at set")
    h.eq(Registry.get("a"), e)
    h.eq(Registry.get("zzz"), nil)
    h.eq(Registry.get(nil), nil)
    h.eq(Registry.remove("a"), true)
    h.eq(e.closed, true, "removed entry is marked closed")
    h.eq(Registry.get("a"), nil)
    h.eq(Registry.remove("a"), false)
    h.eq(#Registry.list(), 0)
  end)

  h.case("put with the same id replaces in place", function()
    Registry._reset()
    Registry.put(entry("a", "s"))
    Registry.put(entry("b", "s"))
    local e2 = Registry.put(entry("a", "s"))
    h.eq(Registry.get("a"), e2)
    local ids = {}
    for _, x in ipairs(Registry.list()) do
      ids[#ids + 1] = x.id
    end
    h.deep_eq(ids, { "a", "b" })
  end)

  h.case("put rejects junk", function()
    Registry._reset()
    h.eq(Registry.put(nil), nil)
    h.eq(Registry.put({}), nil)
    h.eq(Registry.put({ id = 3 }), nil)
    h.eq(#Registry.list(), 0)
  end)

  h.case("evicts the oldest beyond MAX_LIVE", function()
    Registry._reset()
    local first
    for i = 1, Registry.MAX_LIVE + 1 do
      local e = Registry.put(entry("w" .. i, "s"))
      if i == 1 then
        first = e
      end
    end
    h.eq(#Registry.list(), Registry.MAX_LIVE)
    h.eq(Registry.get("w1"), nil)
    h.eq(first.closed, true)
    h.eq(Registry.list()[1].id, "w2")
    h.ok(Registry.get("w" .. (Registry.MAX_LIVE + 1)) ~= nil, "newest kept")
  end)

  h.case("clear_session removes only that session's entries", function()
    Registry._reset()
    Registry.put(entry("a", "s1"))
    Registry.put(entry("b", "s2"))
    Registry.put(entry("c", "s1"))
    Registry.put(entry("d", nil))
    h.eq(Registry.clear_session("s1"), 2)
    h.eq(Registry.get("a"), nil)
    h.eq(Registry.get("c"), nil)
    h.ok(Registry.get("b") ~= nil, "other session kept")
    h.ok(Registry.get("d") ~= nil, "sessionless kept")
    h.eq(Registry.clear_session(nil), 0)
    h.eq(Registry.clear_session("s1"), 0)
  end)

  h.case("list keeps insertion order", function()
    Registry._reset()
    for _, id in ipairs({ "x", "y", "z" }) do
      Registry.put(entry(id, "s"))
    end
    Registry.remove("y")
    local ids = {}
    for _, e in ipairs(Registry.list()) do
      ids[#ids + 1] = e.id
    end
    h.deep_eq(ids, { "x", "z" })
    Registry._reset()
  end)
end
