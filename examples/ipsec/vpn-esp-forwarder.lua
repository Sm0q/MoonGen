local dpdk	= require "dpdk"
local ipsec	= require "ipsec"
local memory	= require "memory"
local device	= require "device"
local ffi	= require "ffi"
local stats	= require "stats"
local math	= require "math"
local ip	= require "proto.ip4"

function master(A, B)
	if not A or not B then
		return print("Usage: A B")
	end

	local dev_A = device.config({port=A, rxQueues=1, txQueues=1})
	local dev_B = device.config({port=B, rxQueues=1, txQueues=1})
	device.waitForLinks()

	-- Enable hw crypto engine
	ipsec.enable(A)
	ipsec.enable(B)

	-- Direction: B -> A
	-- Install TX Security Association (SA)
	ipsec.tx_set_key(B, 0, "77777777deadbeef77777777DEADBEEF", "ff0000ff")
	-- Install RX Security Association (SA)
	ipsec.rx_set_key(A, 0, "77777777deadbeef77777777DEADBEEF", "ff0000ff", 4, "esp", 1)
	ipsec.rx_set_spi(A, 0, 0xdeadbeef, 127)
	ipsec.rx_set_ip(A, 127, "192.168.1.2")

	dpdk.launchLua("vpnEndpoint", dev_B:getRxQueue(0), dev_B:getTxQueue(0),
		"A0:36:9F:3B:71:DA", "192.168.1.1", "A0:36:9F:3B:71:D8", "192.168.1.2", 0xdeadbeef, 0)

	dpdk.launchLua("dumpSlave", dev_A:getRxQueue(0), dev_A)
	dpdk.launchLua("loadSlave", dev_A:getTxQueue(0), dev_A, 60)

	dpdk.waitForSlaves()

	-- Disable hw crypto engine
	ipsec.disable(A)
	ipsec.disable(B)
end

function vpn_decapsulate(buf, src_mac, dst_mac)
	local new_mem = memory.createMemPool(function(buf)
		buf:getEthPacket():fill{
			--pktLength = new_len,
			ethSrc = src_mac,
			ethDst = dst_mac,
		}
	end)
	local new_bufs = new_mem:bufArray(1) -- allocate one ETH packet

	local pkt = buf:getIPPacket()
	local esp_pkt = buf:getEspPacket()

	local len = pkt.ip4:getLength()

	--local extra_pad = ipsec.get_extra_pad(buf)
	local pkt = buf:getIPPacket()
	local payload_len = pkt.ip4:getLength()-20 --IP4 Length less 20 bytes IP4 Header
	--ESP_ICV(16), ESP_next_hdr(1), array_offset(1)
	local esp_padding_len = pkt.payload.uint8[payload_len-16-1-1]
	local extra_pad = esp_padding_len-2 --subtract default padding of 2 bytes, which is always there

	-- eth(14), pkt(len), pad(extra_pad), outer_ip(20), esp_header(16), esp_trailer(20)
	local new_len = 14+len-extra_pad-20-16-20

	new_bufs:alloc(new_len)
	local new_buf = new_bufs[1]
	local new_pkt = new_buf:getEthPacket()
	new_pkt:setLength(new_len)

	-- copy old (inner) pkt into new ETH pkt
	for i = 0, new_len-14-1 do
		new_pkt.payload.uint8[i] = esp_pkt.payload.uint8[i]
	end

	return new_bufs
end

function vpn_encapsulate(buf, spi, sa_idx, src_mac, src_ip, dst_mac, dst_ip)
	local new_mem = memory.createMemPool(function(buf)
		buf:getEspPacket():fill{
			--pktLength = new_len,
			ethSrc = src_mac,
			ethDst = dst_mac,
			ip4Protocol = 0x32, --ESP
			ip4Src = src_ip,
			ip4Dst = dst_ip,
			espSPI = spi,
			espSQN = 0,
		}
	end)
	local new_bufs = new_mem:bufArray(1) -- allocate one ESP packet

	local pkt = buf:getIPPacket()
	local eth_pkt = buf:getEthPacket()

	local len = pkt.ip4:getLength()
	local extra_pad = ipsec.calc_extra_pad(len) --for 4 byte alignment
	-- eth(14), ip4(20), esp(16), pkt(len), pad(extra_pad), esp_trailer(20)
	local new_len = 14+20+16+len+extra_pad+20

	new_bufs:alloc(new_len)
	local new_buf = new_bufs[1]
	local new_pkt = new_buf:getEspPacket()
	new_pkt:setLength(new_len)

	-- copy old pkt (starting with IP header) into new ESP pkt
	for i = 0, len-1 do
		new_pkt.payload.uint8[i] = eth_pkt.payload.uint8[i]
	end

	ipsec.add_esp_trailer(new_buf, len, 0x4) -- Tunnel mode: next_header = 0x4 (IPv4)

	new_bufs:offloadIPChecksums()
	new_bufs:offloadIPSec(sa_idx, "esp", 1)

	return new_bufs
end


function vpnEndpoint(rxQ, txQ, src_mac, src_ip, dst_mac, dst_ip, spi, sa_idx)
	local bufs = memory.bufArray()
	while dpdk.running() do
		local rx = rxQ:recv(bufs)
		--encapsulate all received packets
		for i = 1, rx do
			local buf = bufs[i]
			local pkt = buf:getIPPacket()
			if pkt.ip4:getProtocol() == ip.PROTO_ESP then
				--local secp, secerr = buf:getSecFlags()
				--if secp == 1 and secerr == 0x0 then
				--	local decapsulated_bufs = vpn_decapsulate(
				--		buf, rxQ, "a0:36:9f:3b:71:da")

				--	--TODO: Send to destination network (from VPN tunnel)
				--	--txQ:send(decapsulated_bufs)
				--	decapsulated_bufs:freeAll() --discard all generated pkts (so it wont segfault)
				--else
				--	print("VPN/ESP error: SECP("..secp.."), SECERR("..secerr..")")
				--end
			else
				local encapsulated_bufs = vpn_encapsulate(
					buf, spi, sa_idx, src_mac, src_ip, dst_mac, dst_ip)

				--Send to VPN tunnel (from destination network)
				txQ:send(encapsulated_bufs)
				--encapsulated_bufs:freeAll() -- free new pkts
			end
		end
		bufs:freeAll()
	end
end

function dumpSlave(rxQ, dev)
	local bufs = memory.bufArray()
	local ctr = stats:newDevRxCounter(dev, "plain")
	while dpdk.running() do
		local rx = rxQ:recv(bufs)
		for i = 1, rx do
			local buf = bufs[i]
			local secp, secerr = buf:getSecFlags()
			local pkt = buf:getIPPacket()
			if pkt.ip4:getProtocol() == ip.PROTO_ESP and secp == 1 and secerr == 0x0 then
				--TODO: define next hop's MAC address
				local next_hop = "01:02:03:04:05:06"
				--local decapsulated_bufs = vpn_decapsulate(buf, rxQ, next_hop)
				print("VPN/ESP success: SECP("..secp.."), SECERR("..secerr..")")
				--decapsulated_bufs[1]:dump()

				--TODO: Send to destination network (from VPN tunnel)
				--txQ:send(decapsulated_bufs)
				--decapsulated_bufs:freeAll() -- free all decapsulated pkts (so it won't segfault)
				ctr:update()
			else
				print("VPN/ESP error: SECP("..secp.."), SECERR("..secerr..")")
			end
		end
		bufs:freeAll()
	end
	ctr:finalize()
end

function loadSlave(txQ, dev, size)
	local pkt_size = size or 60
	local numFlows = 256
	local mem = memory.createMemPool(function(buf)
		buf:getUdpPacket():fill{
			pktLength = pkt_size,
			ethSrc = txQ,
			ethDst = "10:11:12:13:14:15",
			ip4Dst = "10.0.1.1",
			udpSrc = 1234,
			udpDst = 5678,
		}
	end)
	bufs = mem:bufArray(128)
	local baseIP = parseIPAddress("10.0.0.1")
	local flow = 0
	local ctr = stats:newDevTxCounter(dev, "plain")
	while dpdk.running() do
		bufs:alloc(pkt_size)
		for _, buf in ipairs(bufs) do
			local pkt = buf:getUdpPacket()
			pkt.ip4.src:set(baseIP + flow)
			flow = incAndWrap(flow, numFlows)
		end
		-- UDP checksums are optional, so just IP checksums are sufficient here
		bufs:offloadIPChecksums()
		txQ:send(bufs)
		ctr:update()
	end
	ctr:finalize()
end
