require 'ext.gc'
local ffi = require 'ffi'
local class = require 'ext.class'
local sem = require 'ffi.req' 'c.semaphore'	-- sem_t
local thread_assert = require 'thread.assert'


local sem_t_1 = ffi.typeof'sem_t[1]'


local Semaphore = class()

function Semaphore:init(n)
	n = n or 0
	self.id = ffi.new(sem_t_1)
	thread_assert(sem.sem_init(self.id, 0, n), 'sem_init')
end

function Semaphore:wait()
	local err = sem.sem_wait(self.id)
	return 0 == err, err
end

function Semaphore:post()
	local err = sem.sem_post(self.id)
	return 0 == err, err
end

function Semaphore:destroy()
	if not self.id then return true end
	local err = sem.sem_destroy(self.id)
	if err == 0 then self.id = nil end
	return 0 == err
end

function Semaphore:__gc()
	self:destroy()
end

return Semaphore
