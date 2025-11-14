#!/usr/bin/env luajit
local ffi = require 'ffi'
local Thread = require 'thread'
local Pool = require 'thread.pool'

local numThreads = Thread.numThreads()

local poolData = ffi.new('int[?]', numThreads)

local pool = Pool{
	userdata = poolData,
	size = numThreads,
	initcode = [[
local poolData = ffi.cast('int*', userdata)
]],
	code = [[
poolData[threadIndex] = poolData[threadIndex] + 1
]],
}

local lastsum = 0
for i=1,2*pool.size do
	pool:cycle(i)

	ffi.C.usleep(50000)

	-- now we should be able to assert no pool thread is running (how?)
	-- (can we tell if
	local sum = 0
	for j=0,numThreads-1 do
		sum = sum + poolData[j]
	end
	io.write(sum)
	for j=0,numThreads-1 do
		io.write(' ', poolData[j])
	end
	print()
	if sum ~= lastsum + i then
		print'!!!! THREADS OUT OF SYNC !!!!'
	end
	lastsum = sum
end

pool:closed()
