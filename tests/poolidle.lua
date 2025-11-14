#!/usr/bin/env luajit
-- what do threads do while idle?
local ffi = require 'ffi'

local pool = require 'thread.pool'{code=''}
pool:cycle()

-- this is up to you.  watch your CPU % and see what happens while the pool waits.
ffi.C.sleep(3)

pool:cycle()

pool:closed()
