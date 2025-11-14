require 'ext.gc'
local ffi = require 'ffi'
local template = require 'template'
local class = require 'ext.class'
local assert = require 'ext.assert'
local pthread = require 'ffi.req' 'c.pthread'
local Thread = require 'thread'
local Semaphore = require 'thread.semaphore'
local Mutex = require 'thread.mutex'

local numThreads = Thread.numThreads()

local poolTypeCode = [[
typedef struct ThreadPool {
	// each thread arg has its own thread arg, for the user
	// alternatively I could allow overloading & extending this struct ...
	void * userdata;

	pthread_mutex_t* tasksMutex;

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
	size_t threadIndex;

	//pointer to the shared threadpool info
	ThreadPool * pool;

	//each thread sets this when they are done
	sem_t *semDone;

	//tell each thread to wake up when pool:ready() is called
	sem_t *semReady;
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
	code / initcode / donecode
		= string to provide worker code
			= table to provide worker code per index (1-based)
			= function(pool, index) to provide worker code per worker (0-based)
				where i is the 0-based index
	userdata = user defined cdata ptr or nil
--]]
function Pool:init(args)
	self.size = self.size or Thread.numThreads()
	self.tasksMutex = Mutex()
	self.poolArg = ffi.new'ThreadPool[1]'
	self.poolArg[0].tasksMutex = self.tasksMutex.id
	self.poolArg[0].done = false
	local userdata = args.userdata
	assert(type(userdata) == 'nil' or type(userdata) == 'cdata')
	self.poolArg[0].userdata = userdata

	for i=1,self.size do
		local worker = Worker()
		worker.semReady = Semaphore()
		worker.semDone = Semaphore()

		-- TODO how to allow the caller to override this
		local threadArg = ffi.new'ThreadArg'
		threadArg.pool = self.poolArg
		threadArg.semDone = worker.semDone.id
		threadArg.semReady = worker.semReady.id
		threadArg.threadIndex = i-1
		worker.arg = threadArg

		local initcode = args.initcode and getcode(self, args.initcode, i)
		local code = getcode(self, args.code, i)
		local donecode = args.donecode and getcode(self, args.donecode, i)

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
local tasksMutex = pool.tasksMutex
local threadIndex = arg.threadIndex
local userdata = pool.userdata

<?=initcode or ''?>

while true do
	while true do
		pthread.pthread_mutex_lock(tasksMutex)
		local gotEmpty
		local done = pool.done
		local task
		if not done then
			if pool.taskIndex < pool.taskCount then
				task = pool.taskIndex
				pool.taskIndex = pool.taskIndex + 1
			end
			if pool.taskIndex >= pool.taskCount then
				gotEmpty = true
			end
		end
		pthread.pthread_mutex_unlock(tasksMutex)

		if done then return end

		if task then
			<?=code or ''?>
		end

		if gotEmpty then
			sem.sem_post(arg.semDone)
			-- break and wait for the semReady to start another work loop
			break
		end
	end

	-- wait til 'pool:ready()' is called
	sem.sem_wait(arg.semReady)
end

<?=donecode or ''?>
]===],			{
					poolTypeCode = poolTypeCode,
					threadArgTypeCode = threadArgTypeCode,
					initcode = initcode,
					code = code,
					donecode = donecode,
				}),
			threadArg)

		self[i] = worker
	end
end

function Pool:ready(size)
	self.tasksMutex:lock()
	self.poolArg[0].taskIndex = 0
	self.poolArg[0].taskCount = size or self.size
	self.tasksMutex:unlock()

	for _,worker in ipairs(self) do
		worker.semReady:post()
	end
end

function Pool:wait()
	for _,worker in ipairs(self) do
		worker.semDone:wait()
	end
end

function Pool:cycle(size)
	self:ready(size)
	self:wait()
end

-- pool's closed
function Pool:closed()
	-- if we don't have the tasksMutex then we can't really talk to the threads anymore
	-- so assume it's already closed
	if not self.tasksMutex then return end

	-- set thread done flag so they will end and we can join them
	self.tasksMutex:lock()
	self.poolArg[0].done = true
	self.tasksMutex:unlock()

	for _,worker in ipairs(self) do
		-- resume so we can shut down
		worker.semReady:post()

		-- join <-> wait for it to return
		worker.thread:join()
		-- destroy semaphores
		worker.semDone:destroy()
		worker.semDone = nil
		worker.semReady:destroy()
		worker.semReady = nil
		-- destroy thread Lua state:
		worker.thread:close()
		worker.thread = nil

		worker.arg.semReady = nil
		worker.arg.semDone = nil
		worker.arg.pool = nil
	end

	self.tasksMutex:destroy()
	self.tasksMutex = nil
end

function Pool:__gc()
	self:closed()
end

return Pool
