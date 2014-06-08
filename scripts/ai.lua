local mb = require('messagebus')

-- we need new instances of these variables for each script that uses ai, so we
-- have to return a factory function
return function(bf, bot)
	local DEBUG_FAST = false
	local gLastChatter = 0
	local gTasks = { }
	local gFighting = false

	local function pause(millis)
		local start
		table.insert(gTasks, function()
			if not start then
				start = getMachineTime()
			end

			return getMachineTime() - start >= millis
		end)
	end

	local function chatter(...)
		local chatters = { ... }
		if #chatters > 0 and getMachineTime() - gLastChatter > 10000 then
			bot:globalMsg(chatters[math.random(1, #chatters)])
			gLastChatter = getMachineTime() + math.random(1, 1000)
		end
	end

	local function moveTo(p, fast)

		-- Allow moveTo(zone) or moveTo(p)
		if type(p) == 'userdata' then
			p = p:getPos()
		end

		table.insert(gTasks, function()
			if DEBUG_FAST then
				bot:setPos(p)
			end

			if bot then
				if bot:getPos() and point.distanceTo(bot:getPos(), p) < 10 then
					-- close enough, we're done
					return true
				end

				waypoint = bot:getWaypoint(p)
				if waypoint then
					bot:setThrustToPt(waypoint)
					if fast then
						bot:fireModule(Module.Turbo)
					end
				end
			end
		end)
	end

	local function say(s, immediate)
		table.insert(gTasks, function()
			bot:globalMsg(s)
			return true
		end)

		-- wait a moment for players to read
		if not immediate and not DEBUG_FAST then
			pause(math.max(1000, #s * 75))
		end
	end

	-- await('event name', count = 1)
	-- waits for the named event to occur count times
	-- await(fn, arg1, arg2, ...)
	-- calls fn with the supplied args until it returns true
	local function await(fn, ...)
		local args = { ... }

		-- given an event name and an optional limit
		-- we'll set fn to a counting callback to use
		if type(fn) == 'string' then
			local msgName = fn
			local count = 0
			local limit = 1
			if type(args[1]) == 'number' then
				limit = args[1]
				table.remove(args, 1, 1)
			end

			-- message bus listener to do the counting
			mb.listen(function(msg, data)
				if msg ==  msgName then
					count = count + 1
				end

				if count >= limit then
					-- we can stop listening now
					return true
				end
			end)

			-- task function to manage task completion
			fn = function()
				return count >= limit
			end
		end

		-- task callback
		table.insert(gTasks, function()
			if fn() then
				return true
			else
				chatter(unpack(args))
			end
		end)
	end

	-- accepts an object or a callback function that returns an object
	local function kill(obj)
		table.insert(gTasks, function()
			if type(obj) == 'function' then
				-- evaluate passed functions only once
				obj = obj()
			elseif type(obj) == 'number' then
				obj = bf:findObjectById(obj)
			end

			local health = 1
			pcall(function()
				health = obj:getHealth()
			end)

			if not obj or health == nil or health <= 0  or obj:getPos() == nil then
				-- it's dead or gone
				return true
			end

			waypoint = bot:getWaypoint(obj:getPos())
			if waypoint then
				if point.distanceTo(obj:getPos(), bot:getPos()) > 100 then
					-- approach the target
					bot:setThrustToPt(waypoint)
				else
					-- back off a bit
					bot:setThrustToPt(2 * bot:getPos() - waypoint)
				end
			end

			bot:setAngle(obj:getPos())
			bot:fireWeapon(Weapon.Phaser)
		end)
	end

	local function done(f, ...)
		local args = { ... } or { }
		table.insert(gTasks, function()
			return f(unpack(args))
		end)
	end

	local function once(f, ...)
		local args = { ... } or { }
		table.insert(gTasks, function()
			f(unpack(args))
			return true
		end)
	end

	local function disable(...)
		local ids = { ... }
		once(function()
			for k, id in pairs(ids) do
				bf:findObjectById(id):setHealth(0)
			end
		end)
	end

	local function signal(msg, data)
		once(function()
			if type(data) == 'function' then
				data = data()
			end

			if type(msg) == 'function' then
				msg = msg()
			end
			mb.emit(msg, data)
		end)
	end

	local function setSpawn(team, id)
		table.insert(gTasks, function()
			local spawns = { }
			bf:findAllObjects(spawns, ObjType.ShipSpawn)
			for k,spawn in pairs(spawns) do
				if spawn:getTeamIndex() == team then
					spawn:setTeam(Team.Hostile)
				end
			end
			bf:findObjectById(id):setTeam(team)
			return true
		end)	
	end

	local function spawnAt(id, team, name, ...)
		local args = { ... }
		once(function()
			local pos = bf:findObjectById(id):getPos()
			bf:addItem(Robot.new(pos, team, name, unpack(args)))
		end)
	end

	local function performTasks()
		if #gTasks > 0 then
			if gTasks[1]() then
				-- result of true means the task is done, so remove the callback room the queue
				table.remove(gTasks, 1, 1)
			end
		end

		if gFighting then
			local target = bot:findClosestEnemy()
			if target then
				local waypoint = bot:getWaypoint(target:getPos())
				if waypoint and point.distSquared(bot:getPos(), target:getPos()) > 2500 then
					bot:setThrustToPt(waypoint)
				end

				if bot:canSeePoint(target:getPos()) then
					bot:setAngle(target:getPos())
					bot:fireWeapon(Weapon.Phaser)
				end
			end
		end
	end

	local function closest(...)
		local types = { ... }
		local result = { }
		bf:findAllObjects(result, unpack(types))

		local best = nil
		local bestDist = math.huge
		for i,obj in ipairs(result) do
			local dist = point.distSquared(bot:getPos(), obj:getPos())
			if dist < bestDist then
				best = obj
				bestDist = dist
			end
		end
		return best
	end

	-- creates a callback that returns true when all targets are disabled
	-- accepts IDs or objects
	local function whenDisabled(...)
		local targets = { ... }

		for k,target in pairs(targets) do
			if type(target) == 'number' then
				targets[k] = bf:findObjectById(target)
			end
		end

		return function()
			for k,target in pairs(targets) do
				local active = false

				-- try isActive
				local ok, err = pcall(function()
					active = target:isActive()
				end)

				-- if that fails, get the health
				if not ok then
					ok, msg = pcall(function()
						active = target:getHealth() > 0
					end)
				end

				-- or maybe the position?
				if not ok then
					ok, msg = pcall(function()
						active = target:getPos() ~= nil
					end)
				end

				-- if that fails, see if the object is nil
				if not ok then
					active = target ~= nil
				end

				if active then
					return false
				end
			end
			return true
		end
	end

	local function whenRecieved(msgName)
		local received = false
		local listening = false
		return function()
			if not listening then
				listening = true
				mb.listen(function(msg, data)
					if msg == msgName then
						received = true
						return true
					end
				end)
			end
			return received
		end
	end

	local function fight(doIt)
		if doIt == nil then
			doIt = true
		end
		once(function()
			gFighting = doIt
		end)
	end

	return {
		chatter = chatter,
		done = done,
		whenRecieved = whenRecieved,
		moveTo = moveTo,
		say = say,
		await = await,
		pause = pause,
		kill = kill,
		done = done,
		once = once,
		disable = disable,
		signal = signal,
		setSpawn = setSpawn,
		spawnAt = spawnAt,
		performTasks = performTasks,
		closest = closest,
		fight = fight,
		whenDisabled = whenDisabled
	}
end