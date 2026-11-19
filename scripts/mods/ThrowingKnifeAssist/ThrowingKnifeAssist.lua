-- Author: ImperialSkoom

local mod = get_mod("ThrowingKnifeAssist")

local MinionMovement = require("scripts/utilities/minion_movement")
local MinionPerception = require("scripts/utilities/minion_perception")
local Breed = require("scripts/utilities/breed")

local ZEALOT_THROWING_KNIVES = "zealot_throwing_knives"
local ZEALOT_KNIFE_ITEM = "content/items/weapons/player/zealot_throwing_knives"
local TARGET_NODE = "enemy_aim_target_03"
local TORSO_NODE = "enemy_aim_target_02"
local TARGET_RESULTS = {}
local NORMAL_CONE_ANGLE = 10
local THREAT_CONE_ANGLE = 35
local TARGET_RANGE = 58
local SNAP_SPEED = 30
local SNAP_TIMEOUT = 0.65
local HOLD_REPEAT_INTERVAL = 0.25
local KNIFE_PROJECTILE_SPEED = 75
local KNIFE_PROJECTILE_GRAVITY = 17.5
local KNIFE_RADIUS = 0.2
local KNIFE_MASS = 0.8
local KNIFE_AIR_DENSITY = 0.7
local KNIFE_DRAG_COEFFICIENT = 0.2
local KNIFE_AIR_DRAG = 0.5 * KNIFE_DRAG_COEFFICIENT * math.pi * KNIFE_RADIUS * KNIFE_RADIUS * KNIFE_AIR_DENSITY / KNIFE_MASS
local TRAJECTORY_STEP = 1 / 120
local TRAJECTORY_ITERATIONS = 5
local MAX_FLIGHT_TIME = 1.5
local MAX_TARGET_SPEED = 18

local PRIMARY_THREATS = {
	renegade_radio_operator = true,
	renegade_netgunner = true,
	renegade_sniper = true,
	chaos_poxwalker_bomber = true,
	chaos_armored_hound = true,
	chaos_hound = true,
	chaos_hound_armoured = true,
	chaos_hound_mutator = true,
	cultist_flamer = true,
	cultist_grenadier = true,
	renegade_flamer = true,
	renegade_flamer_mutator = true,
	renegade_grenadier = true,
}

local state = {
	enabled = true,
	grenade_ability_name = nil,
	grenade_ability_component = nil,
	grenade_ability_action_component = nil,
	smart_targeting_extension = nil,
	snap_target_unit = nil,
	snap_position_box = nil,
	target_velocity_box = nil,
	target_sample_position_box = nil,
	target_sample_t = 0,
	snap_until_t = 0,
	snap_action_seen = false,
	release_override = false,
	frame_index = 0,
	hold_to_throw = true,
	input_frame_index = nil,
	input_frame_value = false,
	next_repeat_t = 0,
	network_lead_time = 0,
	next_network_sample_t = 0,
}

local hooked_tables = setmetatable({}, { __mode = "k" })
local diagnostic = {
	search = "not queried",
	source = "none",
	candidates = 0,
	presses = 0,
	locks = 0,
	camera_snaps = 0,
	redirects = 0,
	error_reported = false,
}

local function clamp(value, min_value, max_value)
	if value < min_value then
		return min_value
	elseif value > max_value then
		return max_value
	end

	return value
end

local function clear_table(t)
	for key in pairs(t) do
		t[key] = nil
	end
end

local function time_now()
	local time_manager = Managers and Managers.time

	if not time_manager then
		return 0
	end

	local ok_gameplay, gameplay_t = pcall(time_manager.time, time_manager, "gameplay")

	if ok_gameplay and type(gameplay_t) == "number" then
		return gameplay_t
	end

	local ok_main, main_t = pcall(time_manager.time, time_manager, "main")

	return ok_main and type(main_t) == "number" and main_t or 0
end

local function refresh_settings()
	state.enabled = mod:get("enabled") ~= false
	state.aim_for_head = mod:get("aim_zone") == "weakspot"
	state.hold_to_throw = mod:get("hold_to_throw") ~= false
end

local function sample_network_lead_time(t)
	if t < state.next_network_sample_t then
		return state.network_lead_time
	end

	state.next_network_sample_t = t + 0.25
	state.network_lead_time = 0

	local connection_manager = Managers and Managers.connection

	if not connection_manager or not connection_manager.is_client or not connection_manager:is_client() then
		return 0
	end

	local host_peer_id = connection_manager.host and connection_manager:host()

	if not host_peer_id or not Network or not Network.ping then
		return 0
	end

	local ok, round_trip_time = pcall(Network.ping, host_peer_id)

	if ok and type(round_trip_time) == "number" then
		state.network_lead_time = clamp(round_trip_time * 0.5, 0, 0.12)
	end

	return state.network_lead_time
end

local function local_player()
	local player_manager = Managers and Managers.player

	return player_manager and player_manager.local_player_safe and player_manager:local_player_safe(1) or nil
end

local function local_player_unit()
	local player = local_player()

	return player and player.player_unit or nil
end

local function unit_alive(unit)
	if not unit then
		return false
	end

	if HEALTH_ALIVE and HEALTH_ALIVE[unit] ~= nil then
		return HEALTH_ALIVE[unit] == true
	end

	if not Unit or not Unit.alive then
		return false
	end

	local ok, alive = pcall(Unit.alive, unit)

	return ok and alive == true
end

local function local_unit_data_extension()
	local unit = local_player_unit()

	return unit_alive(unit) and ScriptUnit and ScriptUnit.has_extension and ScriptUnit.has_extension(unit, "unit_data_system") or nil
end

local function local_smart_targeting_extension()
	if state.smart_targeting_extension then
		return state.smart_targeting_extension
	end

	local unit = local_player_unit()

	return unit_alive(unit) and ScriptUnit and ScriptUnit.has_extension and ScriptUnit.has_extension(unit, "smart_targeting_system") or nil
end

local function read_grenade_ability_action_component()
	if state.grenade_ability_action_component then
		return state.grenade_ability_action_component
	end

	local unit_data_extension = local_unit_data_extension()

	if not unit_data_extension or not unit_data_extension.read_component then
		return nil
	end

	local ok, component = pcall(unit_data_extension.read_component, unit_data_extension, "grenade_ability_action")

	return ok and component or nil
end

local function read_grenade_ability_component()
	if state.grenade_ability_component then
		return state.grenade_ability_component
	end

	local unit_data_extension = local_unit_data_extension()

	if not unit_data_extension or not unit_data_extension.read_component then
		return nil
	end

	local ok, component = pcall(unit_data_extension.read_component, unit_data_extension, "grenade_ability")

	return ok and component or nil
end

local function current_grenade_action_name()
	local component = read_grenade_ability_action_component()

	return component and component.current_action_name or nil
end

local function cache_ability_extension(ability_extension)
	local equipped_abilities = ability_extension and ability_extension._equipped_abilities
	local grenade_ability = equipped_abilities and equipped_abilities.grenade_ability

	state.grenade_ability_name = grenade_ability and grenade_ability.name or nil
end

local function current_grenade_ability_name()
	if state.grenade_ability_name then
		return state.grenade_ability_name
	end

	local unit = local_player_unit()
	local ability_extension = unit_alive(unit) and ScriptUnit and ScriptUnit.has_extension and ScriptUnit.has_extension(unit, "ability_system") or nil
	local equipped_abilities = ability_extension and ability_extension._equipped_abilities
	local grenade_ability = equipped_abilities and equipped_abilities.grenade_ability

	return grenade_ability and grenade_ability.name or nil
end

local function throwing_knives_equipped()
	local component = read_grenade_ability_action_component()
	local template_name = component and component.template_name

	return template_name == ZEALOT_THROWING_KNIVES or current_grenade_ability_name() == ZEALOT_THROWING_KNIVES
end

local function throwing_knives_available()
	local component = read_grenade_ability_component()
	local num_charges = component and component.num_charges or nil

	-- Fail open if the component is unavailable so a transient read failure cannot eat the input.
	return type(num_charges) ~= "number" or num_charges > 0
end

local function ui_using_input()
	local ui_manager = Managers and Managers.ui

	return ui_manager and ui_manager.using_input and ui_manager:using_input() or false
end

local function degrees_to_radians(degrees)
	return degrees * 0.017453292519943
end

local function breed_from_unit_data(unit_data_extension)
	if not unit_data_extension then
		return nil
	end

	if unit_data_extension.breed then
		local ok, breed = pcall(unit_data_extension.breed, unit_data_extension)

		if ok and breed then
			return breed
		end
	end

	return unit_data_extension._breed
end

local function is_boss_breed(breed)
	local tags = breed and breed.tags

	return breed and (breed.is_boss or tags and (tags.monster or tags.captain or tags.cultist_captain))
end

local function is_witch_aggroed(unit)
	local game_session_manager = Managers and Managers.state and Managers.state.game_session
	local unit_spawner = Managers and Managers.state and Managers.state.unit_spawner
	local game_session = game_session_manager and game_session_manager:game_session()
	local game_object_id = nil

	if unit_spawner then
		local id_ok, id = pcall(unit_spawner.game_object_id, unit_spawner, unit)

		game_object_id = id_ok and id or nil
	end

	if not game_session or not game_object_id then
		return false
	end

	local ok, target_unit = pcall(MinionPerception.target_unit, game_session, game_object_id)

	return ok and target_unit ~= nil
end

local function is_passive_witch(unit, breed)
	return breed and breed.tags and breed.tags.witch and not is_witch_aggroed(unit)
end

local function target_rank(breed)
	if not Breed.is_minion(breed) or breed.is_untargetable or is_boss_breed(breed) then
		return nil
	end

	local breed_name = breed and breed.name

	if PRIMARY_THREATS[breed_name] then
		return 0
	end

	local tags = breed and breed.tags

	if tags and tags.special then
		return 2
	elseif tags and (tags.elite or tags.ogryn) then
		return 4
	end

	return nil
end

local function is_primary_threat(breed)
	return breed and PRIMARY_THREATS[breed.name] == true
end

local function unit_world_position(unit, node_index)
	if not unit_alive(unit) or not Unit or not Unit.world_position then
		return nil
	end

	local ok, position = pcall(Unit.world_position, unit, node_index)

	return ok and position or nil
end

local function target_root_position(unit)
	return unit_world_position(unit, 1)
end

local function named_target_node_position(unit, node_name)
	if not unit_alive(unit) or not Unit then
		return nil
	end

	local ok, has_node = pcall(Unit.has_node, unit, node_name)

	if not ok or not has_node then
		return nil
	end

	local node_ok, node_index = pcall(Unit.node, unit, node_name)

	return node_ok and unit_world_position(unit, node_index) or nil
end

local function target_node_position(unit)
	local preferred = state.aim_for_head and TARGET_NODE or TORSO_NODE
	local fallback = state.aim_for_head and TORSO_NODE or TARGET_NODE

	return named_target_node_position(unit, preferred)
		or named_target_node_position(unit, fallback)
		or target_root_position(unit)
end

local function has_line_of_sight(smart_targeting_extension, ray_origin, target_position)
	local raycast_object = smart_targeting_extension and smart_targeting_extension._visibility_raycast_object

	if not raycast_object or not Raycast or not Raycast.cast then
		return false
	end

	local to_target = target_position - ray_origin
	local distance = Vector3.length(to_target)

	if distance <= 0 then
		return false
	end

	local ok, hit = pcall(Raycast.cast, raycast_object, ray_origin, Vector3.normalize(to_target), distance)

	return ok and not hit
end

local function player_side_system()
	local extension_manager = Managers and Managers.state and Managers.state.extension
	local side_system = extension_manager and extension_manager.has_system and extension_manager:has_system("side_system") and extension_manager:system("side_system")

	return side_system
end

local function is_enemy(target_unit)
	local side_system = player_side_system()
	local player_unit = local_player_unit()

	return player_unit and side_system and side_system.is_enemy and side_system:is_enemy(player_unit, target_unit) or false
end

local function broadphase()
	local extension_manager = Managers and Managers.state and Managers.state.extension
	local broadphase_system = extension_manager and extension_manager.has_system and extension_manager:has_system("broadphase_system") and extension_manager:system("broadphase_system")

	return broadphase_system and broadphase_system.broadphase or nil
end

local ZERO_PROJECTILE_OFFSET = {
	min = 0,
	max = 0,
}

local function zealot_knife_spawn_parameters(action)
	if not action or not action._projectile_template then
		return nil
	end

	local ok, projectile_template = pcall(action._projectile_template, action)

	if not ok or not projectile_template or projectile_template.item_name ~= ZEALOT_KNIFE_ITEM then
		return nil
	end

	local locomotion_template = projectile_template.locomotion_template

	return locomotion_template and locomotion_template.spawn_projectile_parameters or nil
end

local function should_override_projectile_release(action)
	return state.enabled
		and mod:is_enabled()
		and action._player_unit == local_player_unit()
		and not ui_using_input()
		and time_now() <= state.snap_until_t
		and state.snap_position_box ~= nil
		and throwing_knives_equipped()
		and zealot_knife_spawn_parameters(action) ~= nil
end

local function find_knife_target()
	diagnostic.source = "none"
	diagnostic.candidates = 0
	local smart_targeting_extension = local_smart_targeting_extension()
	local player_unit = local_player_unit()

	if not smart_targeting_extension or not unit_alive(player_unit) then
		diagnostic.search = "missing player or targeting extension"
		return nil, nil
	end

	local ray_origin, forward = smart_targeting_extension:_targeting_parameters()

	if not ray_origin or not forward then
		diagnostic.search = "missing camera parameters"
		return nil, nil
	end

	local side_system = player_side_system()
	local side = side_system and side_system.side_by_unit and side_system.side_by_unit[player_unit]

	if not side then
		diagnostic.search = "missing player side"
		return nil, nil
	end

	local normal_max_angle = degrees_to_radians(NORMAL_CONE_ANGLE)
	local threat_max_angle = degrees_to_radians(THREAT_CONE_ANGLE)
	local query_range = TARGET_RANGE
	-- The side registry includes hostile units even when the engine's spatial
	-- query is empty. Filter our aim points below; never mutate the shared array.
	local target_results = side.relation_units and side:relation_units("enemy")
	local num_targets = target_results and #target_results or 0

	if target_results then
		diagnostic.source = "enemy registry"
	else
		clear_table(TARGET_RESULTS)
		local broadphase_object = broadphase()
		local enemy_side_names = side.relation_side_names and side:relation_side_names("enemy")
		local ok, count = false, nil

		if broadphase_object and enemy_side_names and Broadphase and Broadphase.query then
			ok, count = pcall(Broadphase.query, broadphase_object, ray_origin, query_range, TARGET_RESULTS, enemy_side_names)
		end

		target_results = TARGET_RESULTS
		num_targets = ok and type(count) == "number" and count or 0
		diagnostic.source = "broadphase"
	end

	diagnostic.candidates = num_targets
	diagnostic.search = "no eligible target"

	if num_targets <= 0 then
		diagnostic.search = "no enemies found"
		return nil, nil
	end

	local normal_max_dot = math.cos(normal_max_angle)
	local threat_max_dot = math.cos(threat_max_angle)
	local best_threat_unit = nil
	local best_threat_position = nil
	local best_threat_score = math.huge
	local best_normal_unit = nil
	local best_normal_position = nil
	local best_normal_score = math.huge

	for i = 1, num_targets do
		local target_unit = target_results[i]

		if target_unit and target_unit ~= player_unit and unit_alive(target_unit) and is_enemy(target_unit) then
			local unit_data_extension = ScriptUnit.has_extension(target_unit, "unit_data_system")
			local breed = breed_from_unit_data(unit_data_extension)
			local rank = not is_passive_witch(target_unit, breed) and target_rank(breed) or nil
			local primary_threat = rank ~= nil and is_primary_threat(breed)
			local target_position = target_node_position(target_unit)

			if rank and target_position then
				local to_target = target_position - ray_origin
				local distance = Vector3.length(to_target)
				local direction = distance > 0 and Vector3.normalize(to_target) or nil
				local dot = direction and Vector3.dot(forward, direction) or -1

				local max_dot = primary_threat and threat_max_dot or normal_max_dot
				local visible = distance > 0 and distance <= query_range and dot >= max_dot
					and has_line_of_sight(smart_targeting_extension, ray_origin, target_position)

				if visible and primary_threat then
					local angle = math.acos(clamp(dot, -1, 1))
					local angle_score = threat_max_angle > 0 and angle / threat_max_angle or 0
					local distance_score = query_range > 0 and distance / query_range or 0
					local score = angle_score * 10 + distance_score * 0.35

					if score < best_threat_score then
						best_threat_score = score
						best_threat_unit = target_unit
						best_threat_position = target_position
					end
				elseif visible then
					local angle = math.acos(clamp(dot, -1, 1))
					local angle_score = normal_max_angle > 0 and angle / normal_max_angle or 0
					local distance_score = query_range > 0 and distance / query_range or 0
					local score = angle_score * 10 + distance_score * 0.35

					if score < best_normal_score then
						best_normal_score = score
						best_normal_unit = target_unit
						best_normal_position = target_position
					end
				end
			end
		end
	end

	if best_threat_unit then
		diagnostic.search = "priority threat selected"
		return best_threat_unit, best_threat_position
	end

	if best_normal_unit then
		diagnostic.search = "elite or special selected"
	end

	return best_normal_unit, best_normal_position
end

local function begin_snap(target_unit, target_position)
	local t = time_now()
	sample_network_lead_time(t)

	state.snap_target_unit = target_unit
	state.snap_position_box = Vector3Box(target_position)
	state.target_velocity_box = Vector3Box(Vector3.zero())

	local root_position = target_root_position(target_unit)

	state.target_sample_position_box = root_position and Vector3Box(root_position) or nil
	state.target_sample_t = t
	state.snap_until_t = t + SNAP_TIMEOUT
	state.snap_action_seen = false
end

local function clear_snap()
	state.snap_target_unit = nil
	state.snap_position_box = nil
	state.target_velocity_box = nil
	state.target_sample_position_box = nil
	state.target_sample_t = 0
	state.snap_until_t = 0
	state.snap_action_seen = false
	state.release_override = false
end

local function current_target_velocity()
	local velocity_box = state.target_velocity_box

	return velocity_box and velocity_box:unbox() or Vector3.zero()
end

local function store_target_velocity(velocity)
	if state.target_velocity_box then
		state.target_velocity_box:store(velocity)
	else
		state.target_velocity_box = Vector3Box(velocity)
	end
end

local function target_locomotion_velocity(target_unit)
	local ok, velocity = pcall(MinionMovement.target_velocity, target_unit)

	if not ok or not velocity then
		return nil
	end

	local speed = Vector3.length(velocity)

	if speed > MAX_TARGET_SPEED then
		velocity = velocity * (MAX_TARGET_SPEED / speed)
	end

	return velocity
end

local function sample_target_velocity(target_unit)
	if not unit_alive(target_unit) then
		return current_target_velocity()
	end

	local position = target_root_position(target_unit)

	if not position then
		return current_target_velocity()
	end

	local t = time_now()
	local position_box = state.target_sample_position_box
	local previous_position = position_box and position_box:unbox() or nil
	local dt = t - state.target_sample_t
	local locomotion_velocity = target_locomotion_velocity(target_unit)

	if locomotion_velocity then
		store_target_velocity(locomotion_velocity)

		if position_box then
			position_box:store(position)
		else
			state.target_sample_position_box = Vector3Box(position)
		end

		state.target_sample_t = t

		return locomotion_velocity
	end

	if not previous_position then
		state.target_sample_position_box = Vector3Box(position)
		state.target_sample_t = t
	elseif dt >= 0.008 then
		local displacement = position - previous_position
		local velocity = Vector3.zero()

		if dt <= 0.25 and Vector3.length(displacement) > 0.001 then
			velocity = displacement / dt
			local speed = Vector3.length(velocity)

			if speed > MAX_TARGET_SPEED then
				velocity = velocity * (MAX_TARGET_SPEED / speed)
			end
		end

		local previous_velocity = current_target_velocity()
		local blend = dt > 0.25 and 1 or clamp(dt * 20, 0.55, 0.9)
		local blended_velocity = previous_velocity + (velocity - previous_velocity) * blend

		store_target_velocity(blended_velocity)

		position_box:store(position)
		state.target_sample_t = t
	end

	return current_target_velocity()
end

local function estimated_flight_time(distance, projectile_speed)
	projectile_speed = projectile_speed or KNIFE_PROJECTILE_SPEED

	if KNIFE_AIR_DRAG <= 0 then
		return clamp(distance / projectile_speed, 0.01, MAX_FLIGHT_TIME)
	end

	local time = (math.exp(KNIFE_AIR_DRAG * distance) - 1) / (KNIFE_AIR_DRAG * projectile_speed)

	return clamp(time, 0.01, MAX_FLIGHT_TIME)
end

local function simulate_projectile_position(origin, direction, flight_time, projectile_speed)
	local position = origin
	local velocity = direction * (projectile_speed or KNIFE_PROJECTILE_SPEED)
	local acceleration = Vector3.zero()
	local elapsed = 0

	while elapsed < flight_time do
		local dt = math.min(TRAJECTORY_STEP, flight_time - elapsed)
		local old_acceleration = acceleration

		position = position + velocity * dt + old_acceleration * (0.5 * dt * dt)
		acceleration = -KNIFE_AIR_DRAG * Vector3.length(velocity) * velocity
		acceleration.z = acceleration.z - KNIFE_PROJECTILE_GRAVITY
		velocity = velocity + (old_acceleration + acceleration) * (0.5 * dt)
		elapsed = elapsed + dt
	end

	return position
end

local function predicted_target_position(target_position, target_velocity, flight_time)
	-- Each target gets its own lead from its live velocity, the knife's calculated flight
	-- time, and the client's measured one-way latency. Faster crossing targets therefore
	-- receive more lateral correction automatically without a user-tuned multiplier.
	return target_position + target_velocity * (flight_time + state.network_lead_time)
end

local function solve_intercept(origin, target_position, target_velocity, projectile_speed)
	if not origin or not target_position then
		return nil, target_position
	end

	target_velocity = target_velocity or Vector3.zero()

	local flight_time = estimated_flight_time(Vector3.length(target_position - origin), projectile_speed)
	local aim_position = predicted_target_position(target_position, target_velocity, flight_time)

	for _ = 1, TRAJECTORY_ITERATIONS do
		flight_time = estimated_flight_time(Vector3.length(aim_position - origin), projectile_speed)

		local to_aim = aim_position - origin
		local distance = Vector3.length(to_aim)

		if distance <= 0.001 then
			return nil, target_position
		end

		local direction = Vector3.normalize(to_aim)
		local projectile_position = simulate_projectile_position(origin, direction, flight_time, projectile_speed)
		local future_target_position = predicted_target_position(target_position, target_velocity, flight_time)

		aim_position = aim_position + future_target_position - projectile_position
	end

	local final_direction = aim_position - origin

	if Vector3.length(final_direction) <= 0.001 then
		return nil, target_position
	end

	return Vector3.normalize(final_direction), aim_position
end

local function current_smart_aim(origin, projectile_speed)
	sample_network_lead_time(time_now())

	local target_unit = state.snap_target_unit
	if not unit_alive(target_unit) or not is_enemy(target_unit) then
		clear_snap()
		return nil, nil
	end
	local fallback_position = state.snap_position_box and state.snap_position_box:unbox() or nil
	local target_position = target_unit and target_node_position(target_unit) or fallback_position

	if not target_position or Vector3.length(target_position - origin) > TARGET_RANGE
		or not has_line_of_sight(local_smart_targeting_extension(), origin, target_position) then
		clear_snap()
		return nil, nil
	end

	local target_velocity = target_unit and sample_target_velocity(target_unit) or Vector3.zero()

	return solve_intercept(origin, target_position, target_velocity, projectile_speed)
end

local function preview_smart_aim(origin, target_position, target_velocity)
	local flight_time = estimated_flight_time(Vector3.length(target_position - origin))
	local predicted_position = predicted_target_position(target_position, target_velocity, flight_time)

	flight_time = estimated_flight_time(Vector3.length(predicted_position - origin))
	predicted_position = predicted_target_position(target_position, target_velocity, flight_time)

	-- The release hook performs the exact iterative simulation. This approximation keeps
	-- the camera preview responsive without running hundreds of trajectory steps per frame.
	return predicted_position + Vector3.up() * (0.5 * KNIFE_PROJECTILE_GRAVITY * flight_time * flight_time)
end

local function mark_throw_action_if_running()
	local action_name = current_grenade_action_name()

	if action_name and action_name ~= "none" then
		state.snap_action_seen = true
	end
end

local function release_snap_after_throw()
	if state.snap_position_box then
		state.snap_action_seen = true
		state.snap_until_t = math.min(state.snap_until_t, time_now() + 0.06)
	end
end

local function snap_position(position)
	if not position or not state.snap_position_box then
		return nil
	end

	local t = time_now()

	mark_throw_action_if_running()

	if not state.enabled or not mod:is_enabled() or ui_using_input()
		or not throwing_knives_equipped() or t > state.snap_until_t
		or not unit_alive(state.snap_target_unit) or not is_enemy(state.snap_target_unit) then
		clear_snap()

		return nil
	end

	local target_unit = state.snap_target_unit
	local fallback_position = state.snap_position_box and state.snap_position_box:unbox() or nil
	local target_position = target_unit and target_node_position(target_unit) or fallback_position

	if not target_position or Vector3.length(target_position - position) > TARGET_RANGE
		or not has_line_of_sight(local_smart_targeting_extension(), position, target_position) then
		clear_snap()
		return nil
	end

	local target_velocity = target_unit and sample_target_velocity(target_unit) or Vector3.zero()

	return preview_smart_aim(position, target_position, target_velocity)
end

local function clear_throw_input()
	state.input_frame_index = nil
	state.input_frame_value = false
	state.next_repeat_t = 0
end

local function physical_input(input_service, action_name)
	-- Evaluate the game's bound keyboard/mouse/controller callbacks directly.
	-- Calling get/_get here would read injected presses and can recurse.
	local rule = input_service._actions and input_service._actions[action_name]
	if not rule then
		return nil
	end
	if rule.filter then
		return rule.eval_func(rule.eval_obj, rule.eval_param)
	end
	local action_type = CLASS.InputService.ACTION_TYPES[rule.type]
	local value = rule.default_func()
	for _, callback in ipairs(rule.callbacks) do
		value = action_type.combine_func(value, callback())
	end
	return value
end

local function should_handle_input(input_service, action_name)
	return input_service.type == "Ingame"
		and action_name == "grenade_ability_pressed"
		and state.enabled and mod:is_enabled()
		and not ui_using_input()
		and throwing_knives_equipped()
end

local function knife_input_hook(func, self, action_name)
	local result = func(self, action_name)
	if not should_handle_input(self, action_name) then
		return result
	end

	local pressed = physical_input(self, "grenade_ability_pressed")
	local held = physical_input(self, "grenade_ability_hold")
	if pressed == nil or held == nil then
		-- An unfamiliar service must not manufacture repeats or swallow a press.
		return result
	end
	if not pressed and not held then
		clear_throw_input()
		return false
	end
	if not throwing_knives_available() then
		clear_throw_input()
		clear_snap()
		return false
	end

	-- Both _get_simulate and _get can be reached for one query. Keep a single
	-- decision for all consumers in this frame, including nested hook calls.
	if state.input_frame_index == state.frame_index then
		return state.input_frame_value
	end
	state.input_frame_index = state.frame_index
	state.input_frame_value = false

	local t = time_now()
	local action = current_grenade_action_name()
	local idle = not action or action == "none"
	local repeat_press = state.hold_to_throw and held and idle and t >= state.next_repeat_t
	if not pressed and not repeat_press then
		return false
	end

	state.input_frame_value = true
	state.next_repeat_t = t + HOLD_REPEAT_INTERVAL
	diagnostic.presses = diagnostic.presses + 1
	local ok, target_unit, target_position = pcall(find_knife_target)
	if not ok then
		clear_snap()
		diagnostic.search = "search error: " .. tostring(target_unit)
		if not diagnostic.error_reported then
			diagnostic.error_reported = true
			mod:error("Knife target search failed: %s", tostring(target_unit))
		end
	elseif target_position then
		begin_snap(target_unit, target_position)
		diagnostic.locks = diagnostic.locks + 1
	else
		clear_snap()
	end

	-- Send the real press immediately. Release-time ballistic correction does
	-- not need a delayed synthetic press, which can feed other input queues.
	return true
end

local function install_aim_assist_hook(AimAssist)
	if not AimAssist or hooked_tables[AimAssist] then
		return
	end

	hooked_tables[AimAssist] = true

	mod:hook(AimAssist, "apply_aim_assist", function(func, main_t, main_dt, input, targeting_data, aim_assist_ramp_component, weapon_action_component, look_yaw, look_pitch, position, combat_ability_action_component, grenade_ability_action_component, ...)
		local yaw, pitch = func(main_t, main_dt, input, targeting_data, aim_assist_ramp_component, weapon_action_component, look_yaw, look_pitch, position, combat_ability_action_component, grenade_ability_action_component, ...)
		local snap_target_position = snap_position(position)

		if not snap_target_position or not position then
			return yaw, pitch
		end

		local target_rotation = Quaternion.look(snap_target_position - position, Vector3.up())
		local current_rotation = Quaternion.from_yaw_pitch_roll(yaw, pitch, 0)
		local lerp_t = clamp((main_dt or 0) * SNAP_SPEED, 0, 1)
		local snapped_rotation = Quaternion.lerp(current_rotation, target_rotation, lerp_t)
		diagnostic.camera_snaps = diagnostic.camera_snaps + 1

		return Quaternion.yaw(snapped_rotation), Quaternion.pitch(snapped_rotation)
	end)
end

mod:hook(CLASS.ActionSpawnProjectile, "_fire_projectile", function(func, self, ...)
	if not should_override_projectile_release(self) then
		return func(self, ...)
	end

	local spawn_projectile_parameters = zealot_knife_spawn_parameters(self)
	local pitch_offset = spawn_projectile_parameters and spawn_projectile_parameters.pitch_offset
	local yaw_offset = spawn_projectile_parameters and spawn_projectile_parameters.yaw_offset

	spawn_projectile_parameters.pitch_offset = pitch_offset and ZERO_PROJECTILE_OFFSET or pitch_offset
	spawn_projectile_parameters.yaw_offset = yaw_offset and ZERO_PROJECTILE_OFFSET or yaw_offset
	state.release_override = true

	local ok, error_message = pcall(func, self, ...)

	state.release_override = false
	spawn_projectile_parameters.pitch_offset = pitch_offset
	spawn_projectile_parameters.yaw_offset = yaw_offset
	release_snap_after_throw()

	if not ok then
		error(error_message)
	end
end)

mod:hook(CLASS.ProjectileUnitLocomotionExtension, "switch_to_manual_physics", function(func, self, position, rotation, direction, speed, ...)
	local projectile_template = self and self._projectile_template

	if state.release_override and projectile_template and projectile_template.item_name == ZEALOT_KNIFE_ITEM then
		local smart_direction = current_smart_aim(position, speed)

		if smart_direction then
			direction = smart_direction
			diagnostic.redirects = diagnostic.redirects + 1
		end
	end

	return func(self, position, rotation, direction, speed, ...)
end)

mod:hook(CLASS.InputService, "_get", knife_input_hook)
mod:hook(CLASS.InputService, "_get_simulate", knife_input_hook)

mod:hook_safe(CLASS.PlayerUnitAbilityExtension, "init", function(self)
	if self._player and self._player.viewport_name == "player1" then
		cache_ability_extension(self)
	end
end)

mod:hook_safe(CLASS.PlayerUnitAbilityExtension, "_equip_ability", function(self)
	if self._player and self._player.viewport_name == "player1" then
		cache_ability_extension(self)
	end
end)

mod:hook_safe(CLASS.PlayerUnitAbilityExtension, "delete", function(self)
	if self._player and self._player.viewport_name == "player1" then
		state.grenade_ability_name = nil
	end
end)

mod:hook_safe(CLASS.PlayerUnitDataExtension, "init", function(self)
	if self._player and self._player.viewport_name == "player1" then
		local ability_ok, ability_component = pcall(self.read_component, self, "grenade_ability")
		local action_ok, action_component = pcall(self.read_component, self, "grenade_ability_action")

		state.grenade_ability_component = ability_ok and ability_component or nil
		state.grenade_ability_action_component = action_ok and action_component or nil
	end
end)

mod:hook_safe(CLASS.PlayerUnitDataExtension, "destroy", function(self)
	if self._player and self._player.viewport_name == "player1" then
		state.grenade_ability_component = nil
		state.grenade_ability_action_component = nil
	end
end)

mod:hook_safe(CLASS.PlayerUnitSmartTargetingExtension, "init", function(self)
	if self._player and self._player.viewport_name == "player1" then
		state.smart_targeting_extension = self
	end
end)

mod:hook_safe(CLASS.PlayerUnitSmartTargetingExtension, "delete", function(self)
	if self._player and self._player.viewport_name == "player1" then
		state.smart_targeting_extension = nil
	end
end)

local function action_handler_is_local_player(action_handler)
	local unit_data_extension = action_handler and action_handler._unit_data_extension
	local player = unit_data_extension and unit_data_extension._player

	return player and player.viewport_name == "player1"
end

mod:hook_safe(CLASS.ActionHandler, "_finish_action", function(self, handler_data)
	if action_handler_is_local_player(self) and handler_data and handler_data.id == "grenade_ability_action" then
		release_snap_after_throw()
	end
end)

mod:hook_safe(CLASS.ActionHandler, "server_correction_occurred", function(self, id)
	if not action_handler_is_local_player(self) or id ~= "grenade_ability_action" then
		return
	end

	local registered_component = self._registered_components and self._registered_components[id]
	local component = registered_component and registered_component.component

	if component and component.current_action_name == "none" then
		release_snap_after_throw()
	end
end)

mod:hook_require("scripts/utilities/aim_assist", install_aim_assist_hook)

mod.on_all_mods_loaded = function()
	refresh_settings()

	local ok, AimAssist = pcall(require, "scripts/utilities/aim_assist")

	if ok then
		install_aim_assist_hook(AimAssist)
	end
end

mod.on_setting_changed = function()
	refresh_settings()
	if not state.enabled then
		clear_snap()
		clear_throw_input()
	end
end

mod:command("knifeassist_status", "Show throwing knife targeting diagnostics.", function()
	local ok, target_unit = pcall(find_knife_target)
	if not ok then
		diagnostic.search = "search error: " .. tostring(target_unit)
	end
	mod:echo("Knife assist: enabled=%s, knives=%s, charges=%s; source=%s, candidates=%d; %s",
		tostring(state.enabled and mod:is_enabled()), tostring(throwing_knives_equipped()),
		tostring(throwing_knives_available()), diagnostic.source, diagnostic.candidates, diagnostic.search)
	mod:echo("Presses=%d, locks=%d, camera snaps=%d, projectile redirects=%d",
		diagnostic.presses, diagnostic.locks, diagnostic.camera_snaps, diagnostic.redirects)
end)

mod.update = function()
	state.frame_index = state.frame_index + 1
end

mod.on_enabled = function()
	state.enabled = true
	refresh_settings()
end

mod.on_disabled = function()
	state.enabled = false
	clear_snap()
	clear_throw_input()
end

mod.on_game_state_changed = function()
	clear_snap()
	clear_throw_input()
	state.smart_targeting_extension = nil
	state.grenade_ability_component = nil
	state.grenade_ability_action_component = nil
	state.grenade_ability_name = nil
	state.network_lead_time = 0
	state.next_network_sample_t = 0
end

refresh_settings()
