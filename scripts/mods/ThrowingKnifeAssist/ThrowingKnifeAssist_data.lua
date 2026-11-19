local mod = get_mod("ThrowingKnifeAssist")

return {
	name = mod:localize("mod_name"),
	description = mod:localize("mod_description"),
	is_togglable = true,
	options = {
		widgets = {
			{
				setting_id = "enabled",
				type = "checkbox",
				default_value = true,
			},
			{
				setting_id = "aim_zone",
				type = "dropdown",
				default_value = "torso",
				options = {
					{ text = "aim_torso", value = "torso" },
					{ text = "aim_weakspot", value = "weakspot" },
				},
			},
			{
				setting_id = "hold_to_throw",
				type = "checkbox",
				default_value = true,
			},
		},
	},
}
