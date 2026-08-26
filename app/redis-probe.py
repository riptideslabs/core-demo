#!/usr/bin/env python3
"""Ask the kernel what it did to this connection.

Opens its own TLS to Redis, speaks a little RESP, then reads the driver's
getsockopt(SOL_RIPTIDES, RIPTIDES_TLS_INFO) and prints what riptides negotiated.
That is the point of the passthrough act: rather than inferring the mode from a
packet capture, the application asks and the kernel answers.

The struct and constants are inlined from driver/include/riptides.h — the same
shape driver/test/riptides.py uses, and the driver's own passthrough test
asserts alpn == b"riptides/passthrough". getsockopt is a shipped API:
riptides_getsockopt is installed on both riptides_prot and riptides_ktls_prot.

Usage: redis-probe.py [host] [port] [ca-cert]
"""
import ctypes
import socket
import ssl
import sys
import time

SOL_RIPTIDES = 7891
RIPTIDES_TLS_INFO = 1


class RiptidesTlsInfo(ctypes.Structure):
    _fields_ = [
        ("riptides_enabled", ctypes.c_bool),
        ("mtls_type", ctypes.c_char * 16),
        ("spiffe_id", ctypes.c_char * 256),
        ("peer_spiffe_id", ctypes.c_char * 256),
        ("alpn", ctypes.c_char * 256),
    ]


host = sys.argv[1] if len(sys.argv) > 1 else "127.0.0.1"
port = int(sys.argv[2]) if len(sys.argv) > 2 else 6379
ca = sys.argv[3] if len(sys.argv) > 3 else None

# The application's own TLS — nothing to do with riptides. Verified against the
# demo CA when one is given, so this is a real handshake and not a skipped one.
ctx = ssl.create_default_context(cafile=ca) if ca else ssl.create_default_context()
if not ca:
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE

def probe():
    """One attempt: own TLS, a PING, then ask the kernel what happened."""
    with socket.create_connection((host, port), timeout=10) as sock:
        with ctx.wrap_socket(sock, server_hostname=host) as tls:
            tls.sendall(b"*1\r\n$4\r\nPING\r\n")
            reply = tls.recv(64)
            print(f"  the application's own TLS : {tls.version()}  (reply {reply!r})")

            # The driver refuses this sockopt when the socket is not a riptides
            # socket, or when its handshake has not completed. That is the "no
            # policy yet" answer, and it is worth showing rather than crashing on.
            try:
                raw = tls.getsockopt(
                    SOL_RIPTIDES, RIPTIDES_TLS_INFO, ctypes.sizeof(RiptidesTlsInfo)
                )
            except OSError as err:
                print(f"  riptides                  : not managing this connection "
                      f"({err.strerror})")
                print("\n  The payload is encrypted — by the application. Nobody has")
                print("  authenticated either end, and no policy applies to it.")
                return

            info = RiptidesTlsInfo.from_buffer_copy(raw)
            dec = lambda b: b.decode(errors="replace") or "(none)"  # noqa: E731
            print(f"  riptides enabled          : {info.riptides_enabled}")
            print(f"  negotiated ALPN           : {dec(info.alpn)}")
            print(f"  mTLS mode                 : {dec(info.mtls_type)}")
            print(f"  this workload             : {dec(info.spiffe_id)}")
            print(f"  peer workload             : {dec(info.peer_spiffe_id)}")

            if info.alpn == b"riptides/passthrough":
                print("\n  PASSTHROUGH: riptides authenticated both ends and handed the")
                print("  socket back. It never saw a byte of the payload.")
            elif info.alpn == b"riptides":
                print("\n  riptides is terminating TLS on this connection (not passthrough).")
            else:
                print(f"\n  unexpected ALPN: {dec(info.alpn)}")


# Retry, because the first connection after a policy change loses the race with
# the driver acquiring its SVID and gets dropped. Every real client reconnects;
# so does this one, rather than making the answer a coin flip.
for attempt in range(1, 5):
    try:
        probe()
        break
    except (ssl.SSLError, OSError) as err:
        if attempt == 4:
            print(f"  failed after {attempt} attempts: {err}")
            raise SystemExit(1)
        print(f"  attempt {attempt} dropped ({type(err).__name__}), retrying…")
        time.sleep(2)
