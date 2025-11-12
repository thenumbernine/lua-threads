require 'ext.gc'
local ffi = require 'ffi'
local class = require 'ext.class'
local sem = require 'ffi.req' 'c.semaphore'	-- sem_t

local Semaphore = class()

function Semaphore:init(n)
	n = n or 0
	self.id = ffi.new'sem_t[1]'
	sem.sem_init(self.id, 0, n)
end

function Semaphore:wait()
	sem.sem_wait(self.id)
end

function Semaphore:post()
	sem.sem_post(self.id)
end

function Semaphore:destroy()
	if self.id then
		ffi.C.sem_destroy(self.id)
		self.id = nil
	end
end

function Semaphore:__gc()
	self:destroy()
end

return Semaphore
