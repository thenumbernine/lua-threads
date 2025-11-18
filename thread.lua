-- posix threads library
require 'ext.gc'	-- enable __gc for Lua tables in LuaJIT
local ffi = require 'ffi'
local class = require 'ext.class'
local pthread = require 'ffi.req' 'c.pthread'
require 'ffi.req' 'c.unistd'	-- sysconf
local thread_assert = require 'thread.assert'


local threadFuncTypeName = 'void*(*)(void*)'
local threadFuncType = ffi.typeof(threadFuncTypeName)

local voidp = ffi.typeof'void*'
local voidp_1 = ffi.typeof'void*[1]'
local pthread_t_1 = ffi.typeof'pthread_t[1]'


local Thread = class()

if langfix then
	Thread.Lua = require 'lua.langfix'
else
	Thread.Lua = require 'lua'
end

--[[
code = Lua code to load and run on the new thread
arg = cdata to pass to the thread
--]]
function Thread:init(code, arg)
	-- each thread needs its own lua_State
	self.lua = self.Lua()

	-- load our thread code within the new Lua state
	-- this will put a function on top of self.lua's stack
	--self.lua:load(code)

	-- or lazy way for now, just gen the code inside here:
	-- TODO instead of the extra lua closure, how about using self.lua:load() to load the code as a function, then use the lua lib for calling ffi.cast?
	-- then call it with xpcall?
	-- but no, the xpcall needs to be called from the new thread,
	-- so maybe it is safest to do here?
	local funcptr = self.lua([[
function _G.run(arg)
	local function collect(exitStatus, ...)
		_G.exitStatus = exitStatus
		if not exitStatus then
			_G.errmsg = ...
		else
			_G.results = table.pack(...)
		end
	end

	-- assign a global of the results when it's done
	collect(xpcall(function()
]]..code..[[
	end, function(err)
		return err..'\n'..debug.traceback()
	end))

	return nil	-- so it can be cast to void* safely, for the thread's cfunc closure's sake
end

-- just in case luajit gc's this, assign it to _G
-- in its docs luajit warns that you have to gc the closures manually, so I think I'm safe (except for leaking memory)
local ffi = require 'ffi'
_G.funcptr = ffi.cast(']]..threadFuncTypeName..[[', _G.run)
return _G.funcptr
]])

	self.funcptr = ffi.cast(threadFuncType, funcptr)

	self.arg = arg	-- store before cast, so nils stay nils, for ease of truth testing
	local argtype = type(arg)
	if not (argtype == 'nil' or argtype == 'cdata') then
		error("I don't know how to pass arg of type "..argtype.." into a new thread")
	end
	arg = ffi.cast(voidp, arg)

	local id = ffi.new(pthread_t_1)
	thread_assert(pthread.pthread_create(id, nil, funcptr, arg), 'pthread_create')
	self.id = id[0]
end

function Thread:join()
	local result = ffi.new(voidp_1)
	thread_assert(pthread.pthread_join(self.id, result), 'pthread_join')
	return result[0]
end

-- should be called from the thread
function Thread:exit(value)
	pthread.pthread_exit(ffi.cast(voidp, value))
end

function Thread:detach()
	thread_assert(pthread.pthread_detach(self.id))
end

-- returns a pthread_t, not a Thread
-- I could wrap this in a Thread, but it'd still have no Lua state...
function Thread:self()
	return pthread.pthread_self()
end

function Thread.__eq(a,b)
	--[[ this seems like a nice thing for flexibility of testing Thread or pthread_t
	-- but then again LuaJIT goes and made its __index fail INTO AN ERROR INSTEAD OF JUST RETURNING NIL
	-- which I can circumvent using op.safeindex/xpcall
	-- but that'd slow things down a lot
	-- so instead this is only going to work for Thread objects
	a = a.id or a
	b = b.id or b
	--]]
	return 0 ~= pthread.pthread_equal(a.id, b.id)
end

-- TODO pthread_attr_* functions
-- TODO pthread_*sched* functions
-- TODO pthread_*cancel* functions
-- TODO pthread_*key* functions
-- TODO a lot more

function Thread:__gc()
	self:close()
end

function Thread:close()
	if self.lua then
		self.lua:close()
		self.lua = nil
	end
end

function Thread.numThreads()
	return tonumber(ffi.C.sysconf(ffi.C._SC_NPROCESSORS_ONLN))
end

return Thread
