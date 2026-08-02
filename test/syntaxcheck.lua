-- cd /tmp && jive syntaxcheck   -- loadfile() parses without executing.
local files = {
	"/usr/share/jive/applets/SBRadioEQ/SBRadioEQApplet.lua",
	"/usr/share/jive/applets/SBRadioEQ/SBRadioEQMeta.lua",
	"/usr/share/jive/applets/SBRadioEQ/eqdesign.lua",
	"/usr/share/jive/applets/SBRadioEQ/eqapply.lua",
}
local bad = 0
for _, f in ipairs(files) do
	local chunk, err = loadfile(f)
	if chunk then
		print(string.format("  ok    %s", f))
	else
		bad = bad + 1
		print(string.format("  SYNTAX %s\n         %s", f, tostring(err)))
	end
end
local fh = io.open("/usr/share/jive/applets/SBRadioEQ/strings.txt")
if fh then print("  ok    strings.txt present"); fh:close()
else bad = bad + 1; print("  MISSING strings.txt") end
print("")
print("syntax errors: " .. bad)
