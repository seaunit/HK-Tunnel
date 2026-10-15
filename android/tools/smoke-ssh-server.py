"""Throwaway SSH server for end-to-end smoke tests of the Android client.

It accepts password login and any number of `direct-tcpip` channels, which is
exactly the subset of SSH the app relies on. Every forwarded destination is
printed, so a run proves that traffic really travelled through the tunnel.

    python tools/smoke-ssh-server.py --port 2222 --user tester --password tunnelpass

Point the app at the host with `10.0.2.2:<port>` when using an emulator.
"""

import argparse
import socket
import sys
import threading

import paramiko


class DirectTcpipServer(paramiko.ServerInterface):
    def __init__(self, user, password, reject_ipv6):
        self.user = user
        self.password = password
        self.reject_ipv6 = reject_ipv6
        self.destinations = {}
        self.lock = threading.Lock()

    def check_auth_password(self, username, password):
        if username == self.user and password == self.password:
            return paramiko.AUTH_SUCCESSFUL
        return paramiko.AUTH_FAILED

    def get_allowed_auths(self, username):
        return "password"

    def check_channel_request(self, kind, chanid):
        if kind in ("session", "direct-tcpip"):
            return paramiko.OPEN_SUCCEEDED
        return paramiko.OPEN_FAILED_ADMINISTRATIVELY_PROHIBITED

    def check_channel_direct_tcpip_request(self, chanid, origin, destination):
        # OpenSSH connects before confirming the channel, so a server without
        # IPv6 egress refuses IPv6 destinations outright. Mirror that here.
        if self.reject_ipv6 and ":" in destination[0]:
            print(f"[forward] -> {destination[0]}:{destination[1]} rejected", flush=True)
            return paramiko.OPEN_FAILED_CONNECT_FAILED
        with self.lock:
            self.destinations[chanid] = destination
        print(f"[forward] -> {destination[0]}:{destination[1]}", flush=True)
        return paramiko.OPEN_SUCCEEDED

    def take_destination(self, chanid):
        with self.lock:
            return self.destinations.pop(chanid, None)


def pump(source, sink, destination, label):
    total = 0
    try:
        while True:
            data = source.recv(32768)
            if not data:
                break
            if total == 0:
                print(f"[data] {destination} {label} first={data[:60]!r}", flush=True)
            total += len(data)
            sink.sendall(data)
    except OSError:
        pass
    finally:
        print(f"[data] {destination} {label} total={total}", flush=True)
        try:
            sink.shutdown(socket.SHUT_WR)
        except OSError:
            pass


def serve_forward(chan, destination):
    try:
        target = socket.create_connection(destination, timeout=15)
    except OSError as exc:
        print(f"[forward] {destination} failed: {exc}", flush=True)
        chan.close()
        return

    threading.Thread(target=pump, args=(chan, target, destination, "up"), daemon=True).start()
    threading.Thread(target=pump, args=(target, chan, destination, "down"), daemon=True).start()


def handle_connection(client, host_key, user, password, reject_ipv6):
    transport = paramiko.Transport(client)
    transport.add_server_key(host_key)
    server = DirectTcpipServer(user, password, reject_ipv6)
    try:
        transport.start_server(server=server)
    except Exception as exc:  # noqa: BLE001 - smoke harness, report and move on
        print(f"[ssh] handshake failed: {exc}", flush=True)
        transport.close()
        return

    print("[ssh] client authenticated", flush=True)
    try:
        while transport.is_active():
            channel = transport.accept(1)
            if channel is None:
                continue
            destination = server.take_destination(channel.get_id())
            if destination is None:
                channel.close()
                continue
            serve_forward(channel, destination)
    finally:
        transport.close()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default="0.0.0.0")
    parser.add_argument("--port", type=int, default=2222)
    parser.add_argument("--user", default="tester")
    parser.add_argument("--password", default="tunnelpass")
    parser.add_argument(
        "--reject-ipv6",
        action="store_true",
        help="refuse IPv6 destinations, like a server without IPv6 egress",
    )
    args = parser.parse_args()

    host_key = paramiko.RSAKey.generate(2048)
    listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    listener.bind((args.host, args.port))
    listener.listen(16)
    print(f"[ssh] listening on {args.host}:{args.port}", flush=True)

    try:
        while True:
            client, _ = listener.accept()
            threading.Thread(
                target=handle_connection,
                args=(client, host_key, args.user, args.password, args.reject_ipv6),
                daemon=True,
            ).start()
    except KeyboardInterrupt:
        pass
    finally:
        listener.close()


if __name__ == "__main__":
    sys.exit(main())
