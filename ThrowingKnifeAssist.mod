return {
	run = function()
		fassert(rawget(_G, "new_mod"), "`ThrowingKnifeAssist` encountered an error loading the Darktide Mod Framework.")

		new_mod("ThrowingKnifeAssist", {
			mod_script = "ThrowingKnifeAssist/scripts/mods/ThrowingKnifeAssist/ThrowingKnifeAssist",
			mod_data = "ThrowingKnifeAssist/scripts/mods/ThrowingKnifeAssist/ThrowingKnifeAssist_data",
			mod_localization = "ThrowingKnifeAssist/scripts/mods/ThrowingKnifeAssist/ThrowingKnifeAssist_localization",
		})
	end,
	load_after = {
		"TakeAim",
	},
	packages = {},
}
