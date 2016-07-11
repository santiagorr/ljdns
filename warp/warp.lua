#!/usr/bin/env luajit
local kdns = require('kdns')
local go, utils = require('kdns.aio'), require('kdns.utils')
local zonefile = require('hurricane.route.file')

-- Logging code
local vlog = function () end
local function log(req, level, msg, ...)
	if not msg then return end
	if req and type(req) == 'table' then
		req = string.format('%s#%d ', req.addr.addr, req.addr.port)
	end
	print(string.format('[%s] %s%s', level, req or '', string.format(msg, ...)))
end

-- Pooled objects
local reqpool = {}
local function pool(list, elm)
	if #list < 100 then table.insert(list, elm) end
end
local function drain(list)
	return table.remove(list)
end
local function getrequest(sock, addr)
	local req = drain(reqpool) or {
		query = kdns.packet(512),
		answer = kdns.packet(4096),
	}
	req.log, req.vlog = log, vlog
	req.sock = sock
	req.addr = addr
	return req
end

-- Parse message, then answer to client
local function serve(req, writer, is_tcp)
	if not req.query:parse() then
		error('query parse error')
	end
	local qtype = req.query:qtype()
	req.xfer = (qtype == kdns.type.AXFR or qtype == kdns.type.IXFR)
	req.query:toanswer(req.answer)
	-- Do not process transfers over UDP
	if req.xfer and not is_tcp then
		req.answer:tc(true)
	else -- If found zonefile, stream answer from zone
		if zonefile.accept(req) then
			assert(zonefile.serve(req, writer))
		end
	end
	-- Finalize answer and stream it
	writer(req, req.answer)
	req.query:clear()
	req.sock, req.addr = nil, nil
	pool(reqpool, req)
end

-- Writer closures for UDP and TCP
local function writer_udp(req, msg)
	return go.udpsend(req.sock, msg.wire, msg.size, req.addr)
end
local function writer_tcp(req, msg)
	return go.tcpsend(req.sock, msg.wire, msg.size)
end

-- TCP can pipeline multiple queries in single connection
local function read_tcp(sock)
	local addr, queries = sock:getpeername(), 0
	while true do
		local req = getrequest(sock, addr)
		-- Read query off socket
		local ok, err = go.tcprecv(sock, req.query.wire, req.query.max_size)
		if ok == 0 then break end
		if err then req:log('error', err) break end
		-- Spawn off new coroutine for request
		if queries > 0 then req.sock = sock:dup() end
		req.query.size = ok
		ok, err = go(serve, req, writer_tcp, true)
		if not ok then req:log('error', err) end
		queries = queries + 1
	end
	-- Do not wait for GC
	sock:close()
end

-- Bind to sockets and start serving
local function downstream(host, port)
	-- Create bound sockets
	local msg, addr = string.format('interface "%s#%d: ', host, port), go.addr(host, port)
	local tcp, err = go.socket(addr, true)
	if not tcp then error(msg..err) end
	local udp, err = go.socket(addr)
	if not udp then error(msg..err) end
	vlog(nil, msg .. 'listening')
	-- Spawn coroutines for listeners
	go(function()
		local addr, ok, err = udp:getsockname(), 0
		while ok do
			-- Fetch next request off freelist
			local req = getrequest(udp, addr)
			ok, err = go.udprecv(udp, req.query.wire, req.query.max_size, addr)
			if ok then
				req.query.size = ok
				ok, err = go(serve, req, writer_udp)
			end
			if err then req:log('error', tostring(err)) end
		end
	end)
	go(function ()
		local addr, ok, err = tcp:getsockname(), 0
		while ok do
			ok, err = go(read_tcp, go.accept(tcp))
			if err then log({addr=addr}, 'error', tostring(err)) end
		end
	end)
end

local function help()
	print(string.format('Usage: %s [options] <config>', arg[0]))
	print('Options:')
	print('\t-h,--help        ... print this help')
	print('\t-v               ... verbose logging')
	print('\t@<addr>[#port]   ... listen on given address/port (e.g. ::1#53)')
end

-- Parse arguments and start serving
for k,v in next,arg,0 do
	local chr = string.char(v:byte())
	if k < 1 then break
	elseif chr == '@' then
		local host, port = v:match("@([^#]+)"), tonumber(v:match("#(%d+)")) or 53
		downstream(host, port)
	elseif v == '-v' then
		vlog = function (req, ...) return log(req, 'info', ...) end
	elseif v == '-h' or v == '--help' then
		help()
		return 0
	else
		local ok, err = utils.chdir(v..'/')
		if not ok then error(string.format('invalid pile path: %s (%s)', v, err)) end
	end
end
local ok, err = go.run(1)
if not ok then
	log(nil, 'error', err)
end