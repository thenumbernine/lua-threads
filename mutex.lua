require 'ext.gc'
local ffi = require 'ffi'
local class = require 'ext.class'
local pthread = require 'ffi.req' 'c.pthread'	-- pthread_mutex_t
local thread_assert = require 'thread.assert'


local pthread_mutex_t_1 = ffi.typeof'pthread_mutex_t[1]'


local Mutex = class()

function Mutex:init()
	self.id = ffi.new(pthread_mutex_t_1)
	thread_assert(pthread.pthread_mutex_init(self.id, nil), 'pthread_mutex_init')	-- attrs?
end

function Mutex:destroy()
	if not self.id then return true end
	local err = pthread.pthread_mutex_destroy(self.id)
	-- destory success, clear id
	if err == 0 then self.id = nil end
	return 0 == err, err
end

function Mutex:lock()
	local err = pthread.pthread_mutex_lock(self.id)
	return 0 == err, err
end

function Mutex:unlock()
	local err = pthread.pthread_mutex_unlock(self.id)
	return 0 == err, err
end

function Mutex:__gc()
	self:destroy()
end

return Mutex
