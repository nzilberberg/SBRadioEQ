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

	--[[
	⛔ THE SERVICE IS REGISTERED HERE, NOT FROM Applet:init().

	It used to be registered in the applet's own init with

	    appletManager:registerService(self, "sbRadioEQApply")

	which was broken twice over, and the result was that the saved curve was
	never restored at boot while the comments claimed it was:

	  * WRONG ARGUMENT. AppletManager:registerService(self, appletName, service)
	    wants the applet NAME. Passing `self` stored the applet OBJECT, so
	    callService's `loadApplet(_appletName)` was handed an object, failed, and
	    returned nil -- silently, because callService just `return`s when it
	    cannot resolve. (Verified on-device: AppletManager.lua:806-815.)

	  * TOO LATE. Applets are loaded lazily, so init() does not run until
	    something opens the applet. configureApplet() fires at startup
	    (AppletManager.lua:325, after registerApplet at :318) and called a service
	    nobody had registered yet.

	meta:registerService passes self._entry.appletName for us (AppletMeta.lua:163),
	and registerApplet runs before configureApplet, so the service exists by the
	time boot asks for it.
	]]
	meta:registerService("sbRadioEQApply")

	-- Settings > Audio Settings now opens the TONE MENU, not the EQ directly.
	-- The EQ is one row inside it. SBRADIOEQ_MENU names the parent so the
	-- SBRADIOEQ string stays with the EQ itself, which is both the row's label
	-- and that window's title.
	jiveMain:addItem(meta:menuItem('appletSBRadioEQ', 'settingsAudio', "SBRADIOEQ_MENU",
		function(applet, ...) applet:menuShow(...) end))
end


function configureApplet(meta)
	if System:getMachine() ~= "baby" then
		return
	end
	-- Push the saved curve into the codec at boot.
	appletManager:callService("sbRadioEQApply")
end
