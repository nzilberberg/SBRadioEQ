-- cd /tmp && jive keydump   -- what are the key constants actually worth?
local names = {
	"KEY_NONE", "KEY_GO", "KEY_UP", "KEY_DOWN", "KEY_LEFT", "KEY_RIGHT",
	"KEY_BACK", "KEY_HOME", "KEY_PLAY", "KEY_ADD", "KEY_PAUSE", "KEY_REW",
	"KEY_FWD", "KEY_VOLUME_UP", "KEY_VOLUME_DOWN", "KEY_MUTE", "KEY_ALARM",
	"KEY_POWER", "KEY_PRESET_0", "KEY_PRESET_1", "KEY_PRINT",
}
print("--- key constants ---")
for _, n in ipairs(names) do
	local v = jive.ui[n]
	if v then print(string.format("%-18s = %d", n, v)) end
end
print("--- the two codes the Radio actually sent ---")
for _, n in ipairs(names) do
	local v = jive.ui[n]
	if v == 1 then print("  1        = " .. n) end
	if v == 16777216 then print("  16777216 = " .. n) end
end
print("--- event type constants ---")
for _, n in ipairs({ "EVENT_SCROLL", "EVENT_KEY_DOWN", "EVENT_KEY_UP",
                     "EVENT_KEY_PRESS", "EVENT_KEY_HOLD", "EVENT_ACTION",
                     "EVENT_ALL_INPUT", "EVENT_WINDOW_POP" }) do
	local v = jive.ui[n]
	if v then print(string.format("%-18s = %d", n, v)) end
end
