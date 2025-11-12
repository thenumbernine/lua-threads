-- posix threads library
require 'ext.gc'	-- enable __gc for Lua tables in LuaJIT
local ffi = require 'ffi'
local class = require 'ext.class'
local Lua = require 'lua'
local pthread = require 'ffi.req' 'c.pthread'
require 'ffi.req' 'c.unistd'	-- sysconf
local errno = require 'ffi.req' 'c.errno'


local function pthread_assert(err, msg)
	if err == 0 then return end
	error(ffi.string(ffi.C.strerror(err))..(msg and ' '..msg or ''))
end


local Thread = class()

local threadFuncType = 'void*(*)(void*)'

--[[
code = Lua code to load and run on the new thread
arg = cdata to pass to the thread
--]]
function Thread:init(code, arg)
	-- each thread needs its own lua_State
	self.lua = Lua()

	-- load our thread code within the new Lua state
	-- this will put a function on top of self.lua's stack
	--self.lua:load(code)

	-- or lazy way for now, just gen the code inside here:
	-- TODO lua() call will cast the function closure to a uintptr_t ...
	-- TODO instead do void* ?
	local funcptr = self.lua([[
local run = function(arg)
]]..code..[[
end

local ffi = require 'ffi'
local runClosure = ffi.cast(']]..threadFuncType..[[', run)
-- just in case luajit gc's this
-- in its docs luajit warns that you have to gc the closures manually, so I think I'm safe (except for leaking memory)
_G.run = run
_G.runClosure = runClosure
return runClosure
]])

	self.funcptr = ffi.cast(threadFuncType, funcptr)

	self.arg = arg	-- store before cast, so nils stay nils, for ease of truth testing
	assert(type(arg) == 'nil' or type(arg) == 'cdata')
	arg = ffi.cast('void*', arg)

	local result = ffi.new'pthread_t[1]'
	pthread_assert(pthread.pthread_create(result, nil, funcptr, arg), 'pthread_create')
	self.id = result[0]
end

function Thread:join()
	local result = ffi.new'void*[1]'
	pthread_assert(pthread.pthread_join(self.id, result), 'pthread_join')
	return result[0]
end

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
