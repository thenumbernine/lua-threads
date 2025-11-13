local ffi = require 'ffi'
local template = require 'template'
local class = require 'ext.class'
local assert = require 'ext.assert'
local pthread = require 'ffi.req' 'c.pthread'
local Thread = require 'thread'
local Semaphore = require 'thread.semaphore'
local numThreads = Thread.numThreads()

local poolTypeCode = [[
typedef struct ThreadPool {
	pthread_mutex_t tasksMutex[1];

//only access the rest after grabbing 'tasksMutex'
// (rename it to 'poolMutex' ?)

	// starts at 0, only access through tasksMutex, threads get tasksMutex then increment this
	// if it's at taskCount then set 'gotEmpty' so we can post to our semDone
	size_t taskIndex;

	// max # tasks
	size_t taskCount;

	// set this to end thread execution
	bool done;
} ThreadPool;
]]
ffi.cdef(poolTypeCode)

-- save code separately so the threads can cdef this too
-- TODO change design to be like Parallel: http://github.com/thenumbernine/Parallel
-- with critsec-mutex to access job pool, another mutex to notify when done
-- and only one semaphore-per-thread to notify to wakeup
local threadArgTypeCode = [[
typedef struct ThreadArg {
	//pointer to the shared threadpool info
	ThreadPool * pool;

	//each thread sets this when they are done
	sem_t *semDone;
} ThreadArg;
]]
ffi.cdef(threadArgTypeCode)


-- TODO should semaphore be created here?
-- TODO how to override ThreadArg?
local Worker = class()


local Pool = class()

Pool.Worker = Worker

local function getcode(self, code, i)
	local codetype = type(code)
	if codetype == 'string' then
	elseif codetype == 'table' then
		code = code[i]
	elseif codetype == 'function' then
		code = code(self, i-1)
	else
		error("can't interpret code of type "..codetype)
	end
	assert.type(code, 'string')
	return code
end

--[[
args:
	size = pool size, defaults to Thread.numThreads()
	initcode / code = string to provide worker code
		= table to provide worker code per index (1-based)
		= function(pool, index) to provide worker code per worker (0-based)
			where i is the 0-based index
--]]
function Pool:init(args)
	self.size = self.size or Thread.numThreads()
	self.poolArg = ffi.new'ThreadPool[1]'
	pthread.pthread_mutex_init(self.poolArg[0].tasksMutex+0, nil)
	self.poolArg[0].done = false
	for i=1,self.size do
		local worker = Worker()
		worker.semDone = Semaphore()

		-- TODO how to allow the caller to override this
		local threadArg = ffi.new'ThreadArg'
		threadArg.pool = self.poolArg
		threadArg.semDone = worker.semDone.id
		worker.arg = threadArg

		local initcode = getcode(self, args.initcode, i)
		local code = getcode(self, args.code, i)

		-- TODO in lua-lua, change the pcalls to use error handlers, AND REPORT THE ERRORS
		-- TODO how to separate init code vs update code and make it modular ...
		worker.thread = Thread(template([===[
local ffi = require 'ffi'
local assert = require 'ext.assert'
local pthread = require 'ffi.req' 'c.pthread'
local sem = require 'ffi.req' 'c.semaphore'	-- sem_t

-- will ffi.C carry across?
-- because its the same luajit process?
-- nope, ffi.C is unique per lua-state
ffi.cdef[[<?=poolTypeCode?>]]
ffi.cdef[[<?=threadArgTypeCode?>]]

-- holds semaphores etc of the thread
assert(arg, 'expected thread argument')
assert.type(arg, 'cdata')
arg = ffi.cast('ThreadArg*', arg)
local pool = arg.pool

<?=initcode or ''?>

while true do

	pthread.pthread_mutex_lock(pool[0].tasksMutex)
	local gotEmpty
	local done = pool[0].done
	local task
	if not done then
		if pool[0].taskIndex < pool[0].taskCount then
			task = pool[0].taskIndex
			pool[0].taskIndex = pool[0].taskIndex + 1
		end
		if pool[0].taskIndex >= pool[0].taskCount then
			gotEmpty = true
		end
	end
	pthread.pthread_mutex_unlock(pool[0].tasksMutex)
	if done then return end

	if task then
		<?=code or ''?>
	end

	if gotEmpty then
		sem.sem_post(arg.semDone)
	end
end
]===],			{
					poolTypeCode = poolTypeCode,
					threadArgTypeCode = threadArgTypeCode,
					initcode = initcode,
					code = code,
				}),
			threadArg)

		self[i] = worker
	end
end

function Pool:ready(size)
	pthread.pthread_mutex_lock(self.poolArg[0].tasksMutex)
	self.poolArg[0].taskIndex = 0
	self.poolArg[0].taskCount = size or self.size
	pthread.pthread_mutex_unlock(self.poolArg[0].tasksMutex)
end

function Pool:wait()
	for _,worker in ipairs(self) do
		worker.semDone:wait()
	end
end

function Pool:cycle()
	self:ready()
	self:wait()
end

-- pool's closed
function Pool:closed()
	-- set thread done flag so they will end and we can join them
	pthread.pthread_mutex_lock(self.poolArg[0].tasksMutex)
	self.poolArg[0].done = true
	pthread.pthread_mutex_unlock(self.poolArg[0].tasksMutex)

	for _,worker in ipairs(self) do
		local arg = worker.arg
		-- join <-> wait for it to return
		worker.thread:join()
		-- destroy semaphores
		worker.semDone:destroy()
		-- destroy thread Lua state:
		worker.thread:close()
	end

	pthread.pthread_mutex_destroy(self.poolArg[0].tasksMutex)
end

return Pool
