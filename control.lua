require("util")
require("scripts/CnC_Walls") --Note, to make SonicWalls work / be passable
local migration = require("scripts/migration")

local debugText = settings.startup["laserfence-debug-text"].value
local baseDamage = settings.startup["laserfence-base-damage"].value
local beamScaling = settings.startup["laserfence-beam-weapon-scaling"].value
local connectorNames = {"laserfence-connector", "laserfence-connector-0", "laserfence-connector-1", "laserfence-connector-2", "laserfence-connector-3", "laserfence-connector-gate"}
local offset = 0.0625

script.on_init(function()
	storage.laserfenceOnEntityDestroyed = {}
	storage.laserfenceObstruction = {}
	storage.laserfenceDamageMulti = {}
	storage.laserfenceRangeUpgradeLevel = {}
	storage.laserfenceEfficiencyUpgradeLevel = {}
	for name, force in pairs(game.forces) do
		local multi = force.get_ammo_damage_modifier("laser") or 0
		storage.laserfenceDamageMulti[name] = multi
		storage.laserfenceRangeUpgradeLevel[name] = 0
		storage.laserfenceEfficiencyUpgradeLevel[name] = 0
	end
	CnC_SonicWall_OnInit()
end)

script.on_configuration_changed(function(event)
	if migration.upgradingToVersion(event, "1.1.1") then
		game.print("Ran conversion for Laser Fence version 1.1.1")
		storage.SRF_nodes = {}
		storage.SRF_node_ticklist = {}
		storage.SRF_low_power_ticklist = {}

		for _, surface in pairs(game.surfaces) do
			-- Reposition emitters
			for _, post in pairs(surface.find_entities_filtered{name = "laserfence-post"}) do
				post.teleport({post.position.x, math.floor(post.position.y) + 0.5625})
				CnC_SonicWall_AddNode(post, game.tick)
			end
		end
		-- Update storage for new shared-obstruction registration
		for registration_number, entityInfo in pairs(storage.laserfenceObstruction) do
			storage.laserfenceObstruction[registration_number] = {entityInfo}
		end
	end
	if migration.upgradingToVersion(event, "1.1.2") then
		game.print("Ran conversion for Laser Fence version 1.1.2")
		storage.laserfenceRangeUpgradeLevel = {}
		for _, force in pairs(game.forces) do
			if force.technologies["laserfence"].researched then
				force.technologies["laserfence-range-1"].researched = true  -- Grant them the extra range to get back to 15 if they converted
			end
			updateConnectorLevel(force)
		end
	end
	if migration.upgradingToVersion(event, "1.1.3") then
		for _, surface in pairs(game.surfaces) do
			-- Convert ghosts
			for _, ghost in pairs(surface.find_entities_filtered{ghost_name = "laserfence-post"}) do
				local force = ghost.force.name
				local connector = "laserfence-connector-"..tostring(storage.laserfenceRangeUpgradeLevel[force])
				ghost.destroy()
				surface.create_entity{
					name = "entity-ghost",
					inner_name = connector,
					force = force,
					position = connectorPosition(ghost.position),
					create_build_effect_smoke = false
				}
			end
			-- Re-pair missing connectors
			for _, post in pairs(surface.find_entities_filtered{name = "laserfence-post"}) do
				local position = connectorPosition(post.position)
				local force = post.force.name
				local connector = "laserfence-connector-"..tostring(storage.laserfenceRangeUpgradeLevel[force])
				if not surface.find_entity(connector, position) then
					surface.create_entity{
						name = connector,
						force = force,
						position = position,
						create_build_effect_smoke = false
					}
					registerEntity(post)
					CnC_SonicWall_AddNode(post, game.tick)
				end
			end
			for _, connector in pairs(surface.find_entities_filtered{name = connectorNames}) do
				connector.destructible = false
			end
		end
	end
	if migration.upgradingToVersion(event, "1.1.4") then
		game.print("Ran conversion for Laser Fence version 1.1.4")
		storage.SRF_nodes = {}
		storage.SRF_node_ticklist = {}
		storage.SRF_low_power_ticklist = {}
		storage.SRF_segments = {}
		storage.laserfenceEfficiencyUpgradeLevel = {}
		for _, force in pairs(game.forces) do
			updateEfficiencyLevel(force)
		end

		for _, surface in pairs(game.surfaces) do
			for _, beam in pairs(surface.find_entities_filtered{name = "laserfence-beam"}) do
				beam.destroy()
			end
			for _, post in pairs(surface.find_entities_filtered{name = "laserfence-post"}) do
				CnC_SonicWall_AddNode(post, game.tick)
			end
		end
	end
	if migration.upgradingToVersion(event, "1.1.6") then
		--Clean up posts without connectors
		for _, surface in pairs(game.surfaces) do
			for _, post in pairs(surface.find_entities_filtered{name = {"laserfence-post", "laserfence-post-gate"}}) do
				if not surface.find_entities_filtered{name = connectorNames, position = connectorPosition(post.position)} then
					post.destroy()
				end
			end
		end
	end
end)

commands.add_command("laserfenceRebuild",
	"Update storages",
	function()
		storage.SRF_nodes = {}
		storage.SRF_node_ticklist = {}
		storage.SRF_low_power_ticklist = {}
		storage.SRF_segments = {}
		for _, surface in pairs(game.surfaces) do
			for _, beam in pairs(surface.find_entities_filtered{name = {"laserfence-beam", "laserfence-beam-gate"}}) do
				beam.destroy()
			end
			for _, post in pairs(surface.find_entities_filtered{name = {"laserfence-post", "laserfence-post-gate"}}) do
				CnC_SonicWall_AddNode(post, game.tick)
			end
		end
		game.player.print("Found " .. #storage.SRF_nodes .. " laser fence posts")
		
		storage.laserfenceDamageMulti = {}
		storage.laserfenceRangeUpgradeLevel = {}
		storage.laserfenceEfficiencyUpgradeLevel = {}
		for _, force in pairs(game.forces) do
			local multi = force.get_ammo_damage_modifier("laser") or 0
			storage.laserfenceDamageMulti[force.name] = multi
			updateConnectorLevel(force)
			updateEfficiencyLevel(force)
		end
	end
)

script.on_event(defines.events.on_tick, function(event)
	-- Update SRF Walls
	CnC_SonicWall_OnTick(event)
end
)

script.on_event(defines.events.on_script_trigger_effect, function(event)
	--Liquid Seed trigger
	if event.effect_id == "laserfence-reflect-damage" and baseDamage > 0 then
		local multi = 0
		if beamScaling then
			multi = storage.laserfenceDamageMulti[event.source_entity.force.name]
		end
		if debugText and event.target_entity then game.print("Dealing "..(baseDamage * (1 + multi)).." reflect damage to "..event.target_entity.name) end
		safeDamage(event.target_entity, baseDamage * (1 + multi))
	end
end
)

function safeDamage(entityOrPlayer, damageAmount)
	if not entityOrPlayer.valid then return end
	if damageAmount <= 0 then return end
	local entity = entityOrPlayer
	if entityOrPlayer.is_player() then
		entity = entityOrPlayer.character  -- Need to damage character instead of player
	end
	if entity.valid and entity.health and entity.health > 0 then
		entity.damage(damageAmount, game.forces.player, "laser")
	end
end

function connectorPosition(postPos)  -- Make these so I don't have to remember how the offset works
	if not postPos then return postPos end
	if postPos.x then
		return {x = postPos.x, y = postPos.y - offset}
	end
	return {postPos[1], postPos[2] - offset}
end

function postPosition(connectorPos)
	if not connectorPos then return connectorPos end
	if connectorPos.x then
		return {x = connectorPos.x, y = connectorPos.y + offset}
	end
	return {connectorPos[1], connectorPos[2] + offset}
end

function registerEntity(entity)  -- Cache relevant information to storage and register
	local entityInfo = {}
	for _, property in pairs({"name", "type", "position", "surface", "force"}) do
		entityInfo[property] = entity[property]
	end
	local registration_number = script.register_on_object_destroyed(entity)
	storage.laserfenceOnEntityDestroyed[registration_number] = entityInfo
end

function registerObstruction(entity, node1, node2)  -- Cache relevant information to storage and register
	local entityInfo = {}
	entityInfo["node1"] = node1
	entityInfo["node2"] = node2
	for _, property in pairs({"name", "type", "position", "surface", "force"}) do
		entityInfo[property] = entity[property]
	end
	local registration_number = script.register_on_object_destroyed(entity)
	if storage.laserfenceObstruction[registration_number] then
		table.insert(storage.laserfenceObstruction[registration_number], entityInfo)
	else
		storage.laserfenceObstruction[registration_number] = {entityInfo}
	end
end

function updateConnectorLevel(force)
	-- Update storage
	local level = 0
	for i = 3,1,-1 do
		if force.technologies["laserfence-range-"..tostring(i)].researched then
			level = i
			break
		end
	end
	storage.laserfenceRangeUpgradeLevel[force.name] = level

	for _, surface in pairs(game.surfaces) do
		-- Swap pipe-to-ground to update range
		for _, connector in pairs(surface.find_entities_filtered{name = connectorNames, force = force}) do
			if connector.name ~= "laserfence-connector-gate" then
				surface.create_entity{
					name = "laserfence-connector-"..tostring(level),
					force = force,
					position = connector.position,
					create_build_effect_smoke = false
				}
				connector.destroy()
			end
		end
		-- Reconnect emitters
		for _, post in pairs(surface.find_entities_filtered{name = "laserfence-post"}) do
			CnC_SonicWall_AddNode(post, game.tick)
		end
	end
end

function updateEfficiencyLevel(force)
	-- Update storage
	local level = 0
	for i = 3,1,-1 do
		if force.technologies["laserfence-efficiency-"..tostring(i)].researched then
			level = i
			break
		end
	end
	storage.laserfenceEfficiencyUpgradeLevel[force.name] = level

	for _, surface in pairs(game.surfaces) do
		for _, emitter in pairs(surface.find_entities_filtered{name = {"laserfence-post", "laserfence-post-gate"}, force = force}) do
			CnC_SonicWall_updatePowerUsage(emitter)
		end
	end
end

function on_new_entity(event)
	local new_entity = event.created_entity or event.entity --Handle multiple event types
	local surface = new_entity.surface
	local position = new_entity.position
	local force = new_entity.force
	if new_entity.name == "laserfence-connector-gate" then
		new_entity.destructible = false
		-- Create actual emitter
		local emitter = surface.create_entity{
			name = "laserfence-post-gate",
			position = postPosition(position),
			force = force,
			raise_built = true
		}
		registerEntity(emitter)
		CnC_SonicWall_AddNode(emitter, event.tick)
	elseif string.sub(new_entity.name, 1, 20) == "laserfence-connector" then
		-- Swap the generic pipe-to-ground to the correct length version
		new_entity.destroy()
		local connector = surface.create_entity{
			name = "laserfence-connector-"..tostring(storage.laserfenceRangeUpgradeLevel[force.name]),
			force = force,
			position = position,
			create_build_effect_smoke = false
		}
		connector.destructible = false
		-- Create actual emitter
		local emitter = surface.create_entity{
			name = "laserfence-post",
			position = postPosition(position),
			force = force,
			raise_built = true
		}
		registerEntity(emitter)
		CnC_SonicWall_AddNode(emitter, event.tick)
	end
end

script.on_event(defines.events.on_built_entity, on_new_entity)
script.on_event(defines.events.on_robot_built_entity, on_new_entity)
script.on_event(defines.events.script_raised_built, on_new_entity)
script.on_event(defines.events.script_raised_revive, on_new_entity)

function on_remove_entity(event)
	local entity = storage.laserfenceOnEntityDestroyed[event.registration_number]
	if entity then
		local surface = entity.surface
		local position = entity.position
		local force = entity.force
		if (entity.name == "laserfence-post") or (entity.name == "laserfence-post-gate") then
			if surface and surface.valid then
				local ghost = surface.find_entities_filtered{position = entity.position, ghost_name = entity.name}[1]
				for _, connector in pairs(surface.find_entities_filtered{name = connectorNames, position = connectorPosition(position), force = force}) do
					if ghost then
						connector.destructible = true
						connector.die()
					else
						connector.destroy()
					end
				end
				if ghost then
					ghost.destroy()
				end
			end
			CnC_SonicWall_DeleteNode(entity, event.tick)
		end
		storage.laserfenceOnEntityDestroyed[event.registration_number] = nil  -- Avoid this storage growing forever
	elseif storage.laserfenceObstruction[event.registration_number] then
		for _, entityInfo in pairs(storage.laserfenceObstruction[event.registration_number]) do --TODO crash?
			if entityInfo then
				local node1 = entityInfo.node1
				local node2 = entityInfo.node2
				if node1.valid and node2.valid then
					tryCnC_SonicWall_MakeWall(node1, node2)
				end
			end
		end
		storage.laserfenceObstruction[event.registration_number] = nil  -- Avoid this storage growing forever
	end
end

script.on_event(defines.events.on_object_destroyed, on_remove_entity)

script.on_event(defines.events.on_entity_died, function(event)
	if event.entity and ((event.entity.name == "laserfence-beam") or (event.entity.name == "laserfence-beam-gate")) then
		CnC_SonicWall_DestroyedWall(event.entity)
	end
end
)

script.on_event({defines.events.on_research_finished, defines.events.on_research_reversed}, function(event)
	local force = event.research.force
	local multi = force.get_ammo_damage_modifier("laser") or 0
	storage.laserfenceDamageMulti[force.name] = multi
	if string.sub(event.research.name, 1, 16) == "laserfence-range" then
		updateConnectorLevel(force)
	elseif string.sub(event.research.name, 1, 21) == "laserfence-efficiency" then
		updateEfficiencyLevel(force)
	end
end
)

script.on_event({defines.events.on_force_created, defines.events.on_force_reset}, function(event)
	local multi = event.force.get_ammo_damage_modifier("laser") or 0
	storage.laserfenceDamageMulti[event.force.name] = multi
	updateConnectorLevel(event.force)
	updateEfficiencyLevel(event.force)
end
)

script.on_event(defines.events.on_forces_merged, function(event)
	for _, storageName in pairs({storage.laserfenceOnEntityDestroyed, storage.laserfenceObstruction}) do
		for registration_number, entityInfo in pairs(storageName) do
			if entityInfo.force.name == event.source_name then
				storageName[registration_number].force = event.destination
			end
		end
	end
	updateConnectorLevel(event.destination)
	updateEfficiencyLevel(event.destination)
end
)
