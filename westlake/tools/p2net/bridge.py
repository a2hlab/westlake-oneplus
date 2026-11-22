#!/usr/bin/env python3
"""TCP <-> passt UNIX socket bridge for phone 2's tunnel.

Windows hdc.exe (rport) connects to localhost:PORT, which WSL forwards to this
listener. Each connection is spliced to passt's UNIX socket (QEMU stream
framing passes through untouched). passt serves one guest at a time, so a new
connection replaces the old one (the phone reconnects after a dropped forward).

usage: bridge.py PORT PASST_SOCKET
"""
import asyncio
import sys
import time

PORT = int(sys.argv[1])
SOCK = sys.argv[2]
current = None  # (task, writer_a, writer_b) of the active session


def log(msg):
    print(time.strftime("%Y-%m-%d %H:%M:%S"), "bridge:", msg, flush=True)


async def pump(reader, writer, counter, key):
    try:
        while True:
            data = await reader.read(262144)
            if not data:
                break
            counter[key] += len(data)
            writer.write(data)
            await writer.drain()
    except (ConnectionError, OSError):
        pass
    finally:
        try:
            writer.close()
        except Exception:
            pass


async def session(tr, tw):
    global current
    peer = tw.get_extra_info("peername")
    if current is not None:
        log("new connection from %s replaces the active one" % (peer,))
        for w in current[1:]:
            try:
                w.close()
            except Exception:
                pass
        await asyncio.sleep(0.2)
    try:
        pr, pw = await asyncio.open_unix_connection(SOCK)
    except OSError as e:
        log("passt socket %s: %s" % (SOCK, e))
        tw.close()
        return
    me = (asyncio.current_task(), tw, pw)
    current = me
    counter = {"up": 0, "down": 0}
    log("session from %s started" % (peer,))
    t0 = time.time()
    await asyncio.gather(pump(tr, pw, counter, "up"), pump(pr, tw, counter, "down"))
    log("session from %s ended after %.0f s: phone->net %d bytes, net->phone %d bytes"
        % (peer, time.time() - t0, counter["up"], counter["down"]))
    if current is me:
        current = None


async def main():
    srv = await asyncio.start_server(session, "127.0.0.1", PORT)
    log("listening on 127.0.0.1:%d -> %s" % (PORT, SOCK))
    async with srv:
        await srv.serve_forever()


asyncio.run(main())
