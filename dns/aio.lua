-- Asynchronous I/O with scoped coroutines
--
-- It works like this:
-- 1. a coroutine is spawned in current scope, it may start any asynchronous operation
-- 2. if the socket blocks, coroutine yields a waitlist (and a socket) on which it blocked
-- 3. the coroutine ownership is transferred to that socket and waits
-- 4. the coroutine is resumed (2) with that event or collapsed if the socket is closed
--
-- The module itself holds tables of readers and writers and poller backend (platform specific)
--
-- Note: if a coroutine collapses, it also collapses its child coroutines. This is basically
--       a structured concurrency as in http://250bpm.com/blog:71 without grace periods.

if not pcall(function() require('syscall') end) then
	return setmetatable({}, {__index = function (t, k)
		error('"syscall" module missing, no I/O available')
	end})
end
local S = require('syscall')
local c, t = S.c, S.t
local ffi, bit = require('ffi'), require('bit')
local n16 = require('dns.utils').n16
local gettime = function()
	local tv = S.gettimeofday()
	return (0.000001 * tonumber(tv.tv_usec) + tonumber(tv.tv_sec))
end

if not table.clear then table.clear = function(t) t = {} end end -- luacheck: ignore
-- Negotiate buffer sizes
local bufsize_min = 256 * 1024
-- No SIGPIPE on broken connections
S.sigaction('pipe', 'ign')
-- Support MSG_FASTOPEN
if c.TCP.FASTOPEN then c.MSG.FASTOPEN = 0x20000000 end

-- Create platform-specific poller
-- (Taken from ljsyscall examples)
local poll = nil
if S.epoll_create then
	poll = {
		init = function(p, maxevents)
			p.events = t.epoll_events(maxevents)
			return setmetatable({fd = assert(S.epoll_create())}, {__index = p})
		end,
		event = t.epoll_event(),
		add = function(p, s, write)
			local ev = p.event
			ev.events = write and c.EPOLL.OUT or c.EPOLL.IN
			ev.data.fd = s
			return p.fd:epoll_ctl(c.EPOLL_CTL.ADD, s, ev)
		end,
		del = function(p, s, write)
			local ev = p.event
			ev.events = write and c.EPOLL.OUT or c.EPOLL.IN
			ev.data.fd = s
			return p.fd:epoll_ctl(c.EPOLL_CTL.DEL, s, ev)
		end,
		get = function(p)
			return p.fd:epoll_wait(p.events)
		end,
		eof = function(ev) return ev.HUP or ev.ERR or ev.RDHUP end,
		ein = function(ev) return bit.band(ev.events, c.EPOLL.IN) ~= 0 end,
		eout = function(ev) return bit.band(ev.events, c.EPOLL.OUT) ~= 0 end,
	}
elseif S.kqueue then
	poll = {
		init = function(p, maxevents)
			p.events = t.kevents(maxevents)
			return setmetatable({fd = assert(S.kqueue())}, {__index = p})
		end,
		event = t.kevents(1),
		add = function(p, s, write)
			local ev = p.event.kev[0]
			ev.fd = s
			ev.setfilter = write and c.EVFILT.WRITE or c.EVFILT.READ
			ev.setflags = c.EV.ADD
			return p.fd:kevent(p.event, nil)
		end,
		del = function (p, s, write)
			local ev = p.event.kev[0]
			ev.fd = s
			ev.setfilter = write and c.EVFILT.WRITE or c.EVFILT.READ
			ev.setflags = c.EV.DELETE
			return p.fd:kevent(p.event, nil)
		end,
		get = function(p, timeout)
			return p.fd:kevent(nil, p.events, timeout)
		end,
		eof = function(ev) return ev.EOF or ev.ERROR end,
		ein = function(ev) return ev.filter == c.EVFILT.READ end,
		eout = function(ev) return ev.filter == c.EVFILT.WRITE end,
	}
else
	error('no epoll or kqueue support')
end

-- Module interface
local M = {
	backend = 'ljsyscall',
	pollfd = poll:init(64),
	coroutines = 0,
	readers = {},
	writers = {}
}

-- Create socket address
local function getaddr(host, port)
	if port == nil then port = 53 end
	local socktype = host:find(':', 1, true) and t.sockaddr_in6 or t.sockaddr_in
	return socktype(port, host)
end

-- Create either bound/unbound socket depending
-- on whether the caller provides address
local function getsocket(addr, tcp)
	-- Get either address type or family name
	local family
	if type(addr) ~= 'cdata' then
		family, addr = addr, nil
	else
		family = addr.family
	end
	local proto = tcp and c.SOCK.STREAM or c.SOCK.DGRAM
	local sock, err = S.socket(family, proto)
	assert(sock, tostring(err))
	-- Bind (or listen) on socket if address provided
	if addr then
		-- Reuse address (if not reusing port)
		sock:setsockopt(c.SOL.SOCKET, c.SO.REUSEPORT or c.SO.REUSEADDR, true)
		local ok, err = sock:bind(addr)
		assert(ok, tostring(err))
		if tcp then
			-- Support TCP fast open
			if c.TCP.FASTOPEN then
				sock:setsockopt(c.IPPROTO.TCP, c.TCP.FASTOPEN, 10)
			end
			-- Use deferred accept
			if c.TCP.DEFER_ACCEPT then
				sock:setsockopt(c.IPPROTO.TCP, c.TCP.DEFER_ACCEPT, true)
			end
			ok, err = sock:listen(128)
			assert(ok, tostring(err))
		end
		-- Negotiate socket buffers for bound sockets to make sure we can get 64K datagrams through
		ok = sock:getsockopt(c.SOL.SOCKET, c.SO.RCVBUF)
		if ok then sock:setsockopt(c.SOL.SOCKET, c.SO.RCVBUF, math.min(ok, bufsize_min)) end
		ok = sock:getsockopt(c.SOL.SOCKET, c.SO.SNDBUF)
		if ok then sock:setsockopt(c.SOL.SOCKET, c.SO.SNDBUF, math.min(ok, bufsize_min)) end
	end
	sock:nonblock()
	return sock, err
end

-- Receive bytes from stream (with yielding when not ready)
local function nbrecv(sock, buf, buflen)
	buf = ffi.cast('char *', buf)
	local rcvd = 0
	local len, err = sock:recv(buf, buflen)
	repeat
		if not len then
			-- Receiving failed, bail out on errors
			if err.errno == c.E.AGAIN then
				coroutine.yield(M.readers, sock)
			else break end
		else
			rcvd = rcvd + len
			if len == 0 or rcvd == buflen then break end
			coroutine.yield(M.readers, sock)
			buf = buf + len
		end
		len, err = sock:recv(buf, buflen - rcvd)
	until rcvd == buflen
	return rcvd, err
end

-- Receive datagrams (with yielding when not ready)
local function nbrecvfrom(sock, addr, buf, buflen)
	local ret, err, saddr = sock:recvfrom(buf, buflen, nil, addr)
	if err and err.errno == c.E.AGAIN then
		coroutine.yield(M.readers, sock)
		ret, err, saddr = sock:recvfrom(buf, buflen, nil, addr)
	end
	return ret, err or saddr
end

-- Send bytes to stream (with yielding when not ready)
local function nbsend(sock, buf, buflen)
	local ret, err = sock:send(buf, buflen)
	if err and err.errno == c.E.AGAIN then
		coroutine.yield(M.writers, sock)
		ret, err = sock:send(buf, buflen)
	end
	return ret, err
end

-- Send datagrams (with yielding when not ready)
local function nbsendto(sock, addr, buf, buflen)
	local ret, err = sock:sendto(buf, buflen, 0, addr)
	while not ret do
		if err.errno ~= c.E.AGAIN then break end
		coroutine.yield(M.writers, sock)
		ret, err = sock:sendto(buf, buflen, 0, addr)
	end
	return ret, err
end

-- Wrapper for asynchronous I/O
local rcvbuf = ffi.new('char [?]', 4096)
local function udpsend(sock, msg, msglen, addr)
	if not msglen then msglen = #msg end
	return addr and nbsendto(sock, addr, msg, msglen) or nbsend(sock, msg, msglen)
end
local function tcpsend(sock, msg, msglen)
	-- Encode message length
	if not msglen then msglen = #msg end
	local rcvlenbuf = ffi.new('uint16_t [1]')
	rcvlenbuf[0] = n16(tonumber(msglen))
	local ok, err = nbsend(sock, rcvlenbuf, 2)
	if ok == 2 then
		ok, err = nbsend(sock, msg, msglen)
	end
	return ok, err and tostring(err)
end
local function udprecv(sock, buf, buflen, addr)
	local ret, err
	if not buf then -- Receive into new buffer
		ret, err, addr = nbrecvfrom(sock, addr, rcvbuf, ffi.sizeof(rcvbuf))
		if ret then ret = ffi.string(rcvbuf, ret) end
	else -- Reuse existing buffer, make sure we don't exceed bounds
		ret, err, addr = nbrecvfrom(sock, addr, buf, buflen)
	end
	return ret, err, addr
end
local function tcprecv(sock, buf, buflen)
	local rcvlenbuf = ffi.new('uint16_t [1]')
	local ret, err = nbrecv(sock, rcvlenbuf, 2)
	if ret == 2 then -- Decode message length
		ret = n16(rcvlenbuf[0])
		-- Receive into new buffer
		if not buf then
			buf = ffi.new('char [?]', ret)
			local rcvd = nbrecv(sock, buf, ret)
			ret = ffi.string(buf, rcvd)
		else -- Reuse existing buffer, make sure we don't exceed bounds
			assert(ret <= buflen)
			ret, err = nbrecv(sock, buf, ret)
		end
	end
	return ret, err
end
local function connect(sock, addr, buf, buflen)
	local packed_msg = nil
	if buf and addr and c.MSG.FASTOPEN then
		-- Need to serialize data for first message (no writev support)
		if not buflen then buflen = #buf end
		packed_msg = ffi.new('uint8_t [?]', buflen + 2)
		local txlen = ffi.cast('uint16_t *', packed_msg)
		txlen[0] = n16(tonumber(buflen))
		ffi.copy(packed_msg + 2, buf, buflen)
		-- Attempt TCP Fast Open (fallback if fails)
		local ok, err = sock:sendto(packed_msg, buflen + 2, c.MSG.FASTOPEN, addr)
		if ok then return ok end
	end
	local _, err = sock:connect(addr)
	if err and err.errno == c.E.INPROGRESS then
		coroutine.yield(M.writers, sock)
	end
	assert(sock:getpeername(), 'failed to connect')
	if buf then -- Send data after connecting (assume TFO failed)
		if packed_msg then -- Reuse already serialized message
			return nbsend(sock, packed_msg, buflen + 2)
		else
			return tcpsend(sock, buf, buflen)
		end
	end
	return true
end
local function accept(sock)
	assert(sock)
	coroutine.yield(M.readers, sock)
	return sock:accept('nonblock')
end

-- Transfer ownerwhip to a different waitlist
local function enqueue(waitlist, co, s)
	local fd = s:getfd()
	local queue = waitlist[fd]
	if not queue then
		waitlist[fd] = {co}
	else
		table.insert(queue, co)
	end
end

local function resume(curlist, fd)
	-- Take the coroutine off waitlist
	local co = table.remove(curlist[fd])
	if not co then -- Not listening for this event
		error(string.format('fd=%d attempted to resume invalid %s', fd, curlist == M.writers and 'writer' or 'reader'))
	end
	-- Resume coroutine, check when it's finished
	local ok, nextlist, what = coroutine.resume(co)
	if not ok or not what then
		M.coroutines = M.coroutines - 1
		M.pollfd:del(fd, curlist == M.writers)
		return false, nextlist
	end
	-- Transfer ownerwhip to a different waitlist
	enqueue(nextlist or M.readers, co, what)
	-- Stop listening for current operation if the coroutine changed
	if fd ~= what:getfd() or curlist ~= nextlist then
		assert(M.pollfd:del(fd, curlist == M.writers))
		assert(M.pollfd:add(what:getfd(), nextlist == M.writers))
	end
	return true
end

local function start(closure, ...)
	if not closure then return nil end
	-- Coroutine resume transfers ownership to return socket
	local co = coroutine.create(closure)
	local ok, list, what = coroutine.resume(co, ...)
	if not ok or not what then
		return ok, list
	end
	M.coroutines = M.coroutines + 1
	enqueue(list or M.readers, co, what)
	assert(M.pollfd:add(what:getfd(), list == M.writers))
	return co
end

local function step(timeout)
	local pollfd, ok, err, count = M.pollfd, true, nil, 0
	for _, ev in pollfd:get(timeout) do
		-- Stop listening when error is encountered
		if pollfd.eof(ev) then
			if M.writers[ev.fd] then
				ok, err = resume(M.writers, ev.fd)
				table.clear(M.writers[ev.fd])
			end
			if M.readers[ev.fd] then
				ok, err = resume(M.readers, ev.fd)
				table.clear(M.writers[ev.fd])
			end
		-- Process write events
		elseif pollfd.eout(ev) then
			count = count + 1
			ok, err = resume(M.writers, ev.fd)
		-- Process read events
		elseif pollfd.ein(ev) then
			count = count + 1
			ok, err = resume(M.readers, ev.fd)
		end
		if err then break else ok = true end
	end
	return ok, err
end

-- Compose module interface
M.addr = function (host, port) return getaddr(host, port) end
M.socket = getsocket
M.now = gettime
M.go  = start
M.step = step
M.udpsend, M.tcpsend = udpsend, tcpsend
M.udprecv, M.tcprecv = udprecv, tcprecv
M.connect = connect
M.accept = accept
-- Run until there are coroutines to execute
M.run = function (timeout)
	local ok, err = true
	while ok and M.coroutines > 0 do
		ok, err = step(timeout)
	end
	return ok, err
end

return setmetatable(M, {
	__call = function(c, closure, ...) return start(closure, ...) end,
})