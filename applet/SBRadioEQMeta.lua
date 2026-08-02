--[[
SBRadioEQ -- Meta

Registers the EQ under Home > Settings > Audio Settings, and re-applies the
saved curve at startup (codec coefficients are volatile -- a power cycle returns
the chip to driver defaults with the filter bypassed).
]]

local oo            = require("loop.simple")
local AppletMeta    = require("jive.AppletMeta")
local System        = require("jive.System")

local appletManager = appletManager
local jiveMain      = jiveMain

module(...)
oo.class(_M, AppletMeta)


function jiveVersion(meta)
	return 1, 1
end


function defaultSettings(meta)
	return {
		enabled   = true,
		bassGain  = 0,     -- dB, -15..+15
		bassFreq  = 150,   -- Hz
		bassQ     = 0.9,
		trebGain  = 0,
		trebFreq  = 4000,
		trebQ     = 0.9,
		-- How much make-up gain is currently folded into the player volume.
		-- Persisted so a re-apply at boot computes a zero delta and does not
		-- jump the volume on every startup.
		appliedAtten = 0,
	}
end


function registerApplet(meta)
	-- Radio only: the coefficient controls exist on the baby's AIC3104 and
	-- nowhere else. Registering on a Touch would put a menu item in front of
	-- controls that are not there.
	if System:getMachine() ~= "baby" then
		return
	end

	jiveMain:addItem(meta:menuItem('appletSBRadioEQ', 'settingsAudio', "SBRADIOEQ",
		function(applet, ...) applet:settingsShow(...) end))
end


function configureApplet(meta)
	if System:getMachine() ~= "baby" then
		return
	end
	-- Push the saved curve into the codec at boot.
	appletManager:callService("sbRadioEQApply")
end
