describe('tls', function()

	local ffi = require('ffi')
	local nb = require('dns.nbio')
	local dns = require('dns')
	local tls = require('dns.tls')

	it('does ping/pong over TLS', function ()
		local server = nb.socket('inet', 'stream')
		assert(server:bind('127.0.0.1', 0))
		-- Function sends PING to client, expects PONG back
		local writes, reads = 0, 0
		assert.truthy(nb(function ()
			local client = assert(server:accept())
			-- Upgrade to TLS
			client = assert(tls.server(client, tls.creds.x509 {
				certfile = 'test.crt',
				keyfile = 'test.key',
			}))
			local ret, err = client:receive(4)
			assert.same('PING', ret)
			reads = reads + 1
			assert(client:send('PONG'))
			writes = writes + 1
		end))
		assert.truthy(nb(function ()
			local client = nb.socket('inet', 'stream')
			local host, port = server:getsockname()
			client:connect(host, port)
			-- Upgrade to TLS
			client = assert(tls.client(client, 'x509'))
			assert(client:send('PING'))
			local ret = client:receive(4)
			assert.same('PONG', ret)
		end))
		-- Evaluate results
		assert.truthy(nb.run())
		assert.same(1, writes)
		assert.same(1, reads)
	end)


end)