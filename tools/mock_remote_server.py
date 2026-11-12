#!/usr/bin/env python3
"""VOFA2 remote tuning mock server.

Implements the PC side of 协议手册 v1 so the iOS client can be exercised
without running the Qt application:

  * UDP discovery on 47901 (`{"t":"discover"}` -> `{"t":"offer",...}`)
  * WebSocket control channel on 47900 (RFC 6455 subset: text, ping, close)
  * hello/welcome/state, value, commit, action, oneclick, sync, ping

Zero third-party dependencies.

Usage:
    python3 ios/tools/mock_remote_server.py            # 47900 control / 47901 udp
    python3 ios/tools/mock_remote_server.py --pin 1234  # require an access code
    python3 ios/tools/mock_remote_server.py --wiggle    # simulate PC-side edits
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
import socket
import struct
import sys
import threading
import time
import traceback

GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
MAX_CLIENTS = 16
MAX_MESSAGE = 64 * 1024


# --------------------------------------------------------------------------- model
class Control:
    def __init__(self, cid, label, group, value, minimum, maximum, step, inc, order):
        self.id = cid
        self.label = label
        self.group = group
        self.value = value
        self.minimum = minimum
        self.maximum = maximum
        self.step = step
        self.inc = inc
        self.order = order

    def to_json(self):
        return {
            "id": self.id,
            "label": self.label,
            "group": self.group,
            "v": self.value,
            "min": self.minimum,
            "max": self.maximum,
            "step": self.step,
            "inc": self.inc,
            "order": self.order,
        }


class Action:
    def __init__(self, aid, label, group, kind, on=False):
        self.id = aid
        self.label = label
        self.group = group
        self.kind = kind
        self.on = on

    def to_json(self):
        return {
            "id": self.id,
            "label": self.label,
            "group": self.group,
            "kind": self.kind,
            "on": self.on,
        }


class Model:
    def __init__(self, server_name, pin_required, pin):
        self.lock = threading.RLock()
        self.server_name = server_name
        self.pin_required = pin_required
        self.pin = pin
        self.groups = ["默认", "底盘", "底盘/PID", "视觉/曝光"]
        self.pc_group = "底盘/PID"
        self.controls = [
            Control(1000, "kp", "默认", 1.5, 0, 10, 0.01, True, 1),
            Control(1001, "ki", "默认", 0.2, 0, 5, 0.001, True, 2),
            Control(1002, "kd", "默认", 0.05, 0, 2, 0.001, True, 3),
            Control(1003, "目标速度", "底盘", 320, 0, 1000, 5, True, 1),
            Control(1004, "转向增益", "底盘", 1.2, 0, 3, 0.05, True, 2),
            Control(2000, "位置环 Kp", "底盘/PID", 2.4, 0, 12, 0.01, True, 1),
            Control(2001, "位置环 Ki", "底盘/PID", 0.015, 0, 1, 0.001, False, 2),
            Control(2002, "位置环 Kd", "底盘/PID", 0.35, 0, 5, 0.01, True, 3),
            Control(2003, "积分限幅", "底盘/PID", 500, 0, 2000, 10, True, 4),
            Control(3000, "曝光时间", "视觉/曝光", 12.5, 0.1, 60, 0.1, True, 1),
            Control(3001, "模拟增益", "视觉/曝光", 8, 1, 32, 1, False, 2),
        ]
        self.actions = [
            Action(3, "启动", "默认", 0),
            Action(4, "闭环", "默认", 1, True),
            Action(5, "急停", "底盘", 0),
            Action(6, "底盘使能", "底盘", 1, False),
            Action(7, "复位编码器", "底盘/PID", 0),
            Action(8, "自动曝光", "视觉/曝光", 1, True),
        ]
        self.conn_connected = True
        self.conn_text = "已连接"
        # link 与 conn 解耦：连接面板默认未连接，conn 仍表示“PC 认为有设备”，
        # 这样两类测试互不影响。
        self.link = {
            "kind": 0,
            "connected": False,
            "state": "未连接",
            "ports": ["COM3", "COM4"],
            "serialPort": "COM3",
            "baud": 115200,
            "tcpHost": "127.0.0.1",
            "tcpClientPort": 1346,
            "tcpServerPort": 1347,
            "tcpClients": 0,
            "udpHost": "127.0.0.1",
            "udpRemotePort": 1346,
            "udpLocalPort": 1347,
        }
        self.seq = 0
        self.oneclick = {"sending": False, "sent": 0, "total": 0, "status": "", "interval": 100}

    def state_payload(self):
        with self.lock:
            self.seq += 1
            return {
                "t": "state",
                "proto": 1,
                "seq": self.seq,
                "server": self.server_name,
                "version": "0.1.0-mock",
                "groups": list(self.groups),
                "pcGroup": self.pc_group,
                "controls": [c.to_json() for c in self.controls],
                "actions": [a.to_json() for a in self.actions],
                "conn": {"connected": self.conn_connected, "state": self.conn_text},
                "link": dict(self.link),
                "oneclick": dict(self.oneclick),
            }

    def control(self, cid):
        for control in self.controls:
            if control.id == cid:
                return control
        return None

    def action(self, aid):
        for action in self.actions:
            if action.id == aid:
                return action
        return None


# ----------------------------------------------------------------------- websocket
class Client:
    def __init__(self, sock, address, model):
        self.sock = sock
        self.address = address
        self.model = model
        self.session = 0
        self.send_lock = threading.Lock()
        self.alive = True
        self.hello_done = False
        self.name = ""
        self.client_id = ""

    # -- frame io ---------------------------------------------------------
    def recv_exact(self, count):
        chunks = b""
        while len(chunks) < count:
            chunk = self.sock.recv(count - len(chunks))
            if not chunk:
                raise ConnectionError("peer closed")
            chunks += chunk
        return chunks

    def read_frame(self):
        header = self.recv_exact(2)
        fin = bool(header[0] & 0x80)
        opcode = header[0] & 0x0F
        masked = bool(header[1] & 0x80)
        length = header[1] & 0x7F
        if length == 126:
            length = struct.unpack("!H", self.recv_exact(2))[0]
        elif length == 127:
            length = struct.unpack("!Q", self.recv_exact(8))[0]
        if length > MAX_MESSAGE:
            self.close(1009, "message too big")
            raise ConnectionError("too big")
        mask = self.recv_exact(4) if masked else b""
        payload = self.recv_exact(length) if length else b""
        if masked and payload:
            payload = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
        return fin, opcode, payload

    def send_frame(self, opcode, payload=b""):
        header = bytearray([0x80 | opcode])
        length = len(payload)
        if length < 126:
            header.append(length)
        elif length <= 0xFFFF:
            header.append(126)
            header += struct.pack("!H", length)
        else:
            header.append(127)
            header += struct.pack("!Q", length)
        with self.send_lock:
            if not self.alive:
                return
            try:
                self.sock.sendall(bytes(header) + payload)
            except OSError:
                self.alive = False

    def send_json(self, payload):
        data = json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        self.send_frame(0x1, data)

    def close(self, code=1000, reason=""):
        if not self.alive:
            return
        body = struct.pack("!H", code) + reason.encode("utf-8")[:120]
        self.send_frame(0x8, body)
        self.alive = False
        try:
            self.sock.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass

    # -- handshake --------------------------------------------------------
    def handshake(self):
        data = b""
        while b"\r\n\r\n" not in data:
            chunk = self.sock.recv(4096)
            if not chunk:
                return False
            data += chunk
            if len(data) > 8192:
                return False
        head = data.split(b"\r\n\r\n", 1)[0].decode("latin1")
        lines = head.split("\r\n")
        if not lines or "upgrade" not in head.lower():
            self.sock.sendall(b"HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\n")
            return False
        key = ""
        for line in lines[1:]:
            if line.lower().startswith("sec-websocket-key:"):
                key = line.split(":", 1)[1].strip()
        if not key:
            self.sock.sendall(b"HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\n")
            return False
        accept = base64.b64encode(hashlib.sha1((key + GUID).encode()).digest()).decode()
        response = (
            "HTTP/1.1 101 Switching Protocols\r\n"
            "Upgrade: websocket\r\n"
            "Connection: Upgrade\r\n"
            f"Sec-WebSocket-Accept: {accept}\r\n\r\n"
        )
        self.sock.sendall(response.encode())
        return True


class Server:
    def __init__(self, model, port, discovery_port, verbose=True, legacy=False):
        self.model = model
        self.port = port
        self.discovery_port = discovery_port
        self.clients = []
        self.lock = threading.RLock()
        self.verbose = verbose
        self.sessions = 0
        self.running = True
        # Reject `{"t":"inc"}` like a PC build that predates the message.
        self.legacy = legacy

    def log(self, text):
        if self.verbose:
            print(f"[{time.strftime('%H:%M:%S')}] {text}", flush=True)

    # -- broadcast --------------------------------------------------------
    def broadcast(self, payload, exclude=None):
        with self.lock:
            targets = list(self.clients)
        for client in targets:
            if client is exclude or not client.alive or not client.hello_done:
                continue
            client.send_json(payload)

    # -- discovery --------------------------------------------------------
    def discovery_loop(self):
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
        try:
            sock.bind(("0.0.0.0", self.discovery_port))
        except OSError as error:
            self.log(f"discovery bind failed: {error}")
            return
        self.log(f"discovery listening on udp/{self.discovery_port}")

        while self.running:
            try:
                data, address = sock.recvfrom(2048)
            except OSError:
                break
            try:
                message = json.loads(data.decode("utf-8"))
            except (ValueError, UnicodeDecodeError):
                continue
            if message.get("t") != "discover":
                continue
            offer = {
                "t": "offer",
                "proto": 1,
                "name": self.model.server_name,
                "port": self.port,
                "pin": self.model.pin_required,
                "version": "0.1.0-mock",
                "ips": [self.local_ip()],
            }
            try:
                sock.sendto(json.dumps(offer, ensure_ascii=False).encode("utf-8"), address)
                self.log(f"offer -> {address[0]}:{address[1]}")
            except OSError as error:
                self.log(f"offer failed: {error}")

    @staticmethod
    def local_ip():
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        try:
            sock.connect(("8.8.8.8", 80))
            return sock.getsockname()[0]
        except OSError:
            return "127.0.0.1"
        finally:
            sock.close()

    # -- control channel --------------------------------------------------
    def serve(self):
        listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        listener.bind(("0.0.0.0", self.port))
        listener.listen(16)
        self.log(f"control channel on ws://0.0.0.0:{self.port}/")

        threading.Thread(target=self.discovery_loop, daemon=True).start()
        threading.Thread(target=self.heartbeat_loop, daemon=True).start()
        threading.Thread(target=self.wiggle_loop, daemon=True).start()

        try:
            while True:
                conn, address = listener.accept()
                with self.lock:
                    if len(self.clients) >= MAX_CLIENTS:
                        self.log(f"reject {address[0]}: too many clients")
                        conn.sendall(b"HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\n\r\n")
                        conn.close()
                        continue
                threading.Thread(target=self.handle_client, args=(conn, address),
                                 daemon=True).start()
        except KeyboardInterrupt:
            self.log("shutting down")
        finally:
            listener.close()

    def handle_client(self, conn, address):
        conn.settimeout(60)
        client = Client(conn, address, self.model)
        with self.lock:
            self.sessions += 1
            client.session = self.sessions
            self.clients.append(client)

        try:
            if not client.handshake():
                return
            self.log(f"session {client.session} handshake from {address[0]}")

            deadline = time.time() + 5
            assembled = b""
            while client.alive:
                fin, opcode, payload = client.read_frame()

                if opcode == 0x8:
                    client.close(1000, "")
                    break
                if opcode == 0x9:
                    client.send_frame(0xA, payload)
                    continue
                if opcode == 0xA:
                    continue
                if opcode == 0x1 or opcode == 0x0:
                    assembled += payload
                    if not fin:
                        continue
                    text = assembled.decode("utf-8", "replace")
                    assembled = b""
                else:
                    client.close(1003, "text frames only")
                    break

                if not client.hello_done:
                    if time.time() > deadline:
                        client.close(1001, "hello timeout")
                        break
                    if not self.handle_hello(client, text):
                        continue
                    # `hello` is consumed here; do not dispatch it as an operation.
                    continue

                self.handle_message(client, text)

        except (ConnectionError, OSError) as error:
            if client.hello_done:
                self.log(f"session {client.session} closed: {error}")
        except Exception:  # noqa: BLE001 - mock server, keep serving
            traceback.print_exc()
        finally:
            client.alive = False
            with self.lock:
                if client in self.clients:
                    self.clients.remove(client)
                remaining = len([c for c in self.clients if c.hello_done])
            try:
                conn.close()
            except OSError:
                pass
            self.log(f"session {client.session} disconnected")
            self.broadcast({"t": "clients", "count": remaining})

    def handle_hello(self, client, text):
        self.log(f"hello? c{client.session} {text[:120]}")
        try:
            message = json.loads(text)
        except ValueError:
            client.close(1002, "bad json")
            return False
        if message.get("t") != "hello":
            client.send_json({"t": "error", "code": "hello_required", "message": "先发 hello"})
            return False
        if self.model.pin_required and str(message.get("pin", "")) != str(self.model.pin):
            client.send_json({"t": "error", "code": "bad_pin", "message": "访问码错误"})
            client.close(4003, "bad pin")
            return False

        client.client_id = str(message.get("clientId", ""))[:64]
        client.name = str(message.get("name", ""))[:64] or f"手机 {client.session}"
        client.hello_done = True

        client.send_json({
            "t": "welcome",
            "proto": 1,
            "session": client.session,
            "name": self.model.server_name,
            "version": "0.1.0-mock",
            "pin": self.model.pin_required,
            "maxClients": MAX_CLIENTS,
        })
        client.send_json(self.model.state_payload())
        with self.lock:
            count = len([c for c in self.clients if c.hello_done])
        self.broadcast({"t": "clients", "count": count})
        self.log(f"session {client.session} hello from {client.name!r}")
        return True

    def handle_message(self, client, text):
        try:
            message = json.loads(text)
        except ValueError:
            client.send_json({"t": "error", "code": "bad_request", "message": "JSON 无效"})
            return

        kind = message.get("t")
        origin = f"c{client.session}"
        model = self.model
        self.log(f"<- c{client.session} {text[:160]}")

        if kind == "value" or kind == "commit":
            cid = message.get("id")
            value = message.get("v")
            control = model.control(cid) if isinstance(cid, int) else None
            if control is None:
                client.send_json({"t": "error", "code": "unknown_control", "message": "控件不存在"})
                return
            if not isinstance(value, (int, float)):
                client.send_json({"t": "error", "code": "bad_value", "message": "数值非法"})
                return
            if kind == "commit" and message.get("exact"):
                control.value = float(value)
            else:
                control.value = min(max(float(value), control.minimum), control.maximum)
            self.broadcast({"t": "value", "id": control.id, "v": control.value, "from": origin})

        elif kind == "action":
            aid = message.get("id")
            action = model.action(aid) if isinstance(aid, int) else None
            if action is None:
                client.send_json({"t": "error", "code": "unknown_control", "message": "开关不存在"})
                return
            if action.kind == 1 and "on" in message:
                action.on = bool(message["on"])
                self.broadcast({"t": "action", "id": action.id, "kind": 1,
                                "on": action.on, "from": origin})
            elif action.kind == 0 and message.get("trigger"):
                self.broadcast({"t": "action", "id": action.id, "kind": 0,
                                "on": False, "from": origin, "flash": True})
                self.log(f"button {action.label} triggered by {origin}")

        elif kind == "inc":
            cid = message.get("id")
            control = model.control(cid) if isinstance(cid, int) else None
            if control is None:
                client.send_json({"t": "error", "code": "unknown_control", "message": "控件不存在"})
                return
            if self.legacy:
                # Older PC builds do not know this message at all.
                client.send_json({"t": "error", "code": "bad_request",
                                  "message": "未知消息类型：inc"})
                return
            flag = message.get("inc")
            if not isinstance(flag, bool):
                client.send_json({"t": "error", "code": "bad_request", "message": "inc 必须是布尔值"})
                return
            with model.lock:
                control.inc = flag
            self.log(f"inc {control.label} -> {flag}")
            self.broadcast(model.state_payload())

        elif kind == "link":
            self.handle_link(client, message, model, origin)

        elif kind == "oneclick":
            self.start_oneclick(client, message)

        elif kind == "oneclick.stop":
            with model.lock:
                if not model.oneclick["sending"]:
                    return
                model.oneclick["sending"] = False
            self.broadcast({"t": "oneclick", "phase": "cancel",
                            "sent": model.oneclick["sent"], "total": model.oneclick["total"],
                            "status": "已取消"})

        elif kind == "sync":
            client.send_json(model.state_payload())

        elif kind == "ping":
            client.send_json({"t": "pong"})

        else:
            client.send_json({"t": "error", "code": "bad_request", "message": f"未知类型 {kind}"})

    def handle_link(self, client, message, model, origin):
        cmd = message.get("cmd")
        if cmd == "refresh":
            self.broadcast({"t": "link", **model.link})
            return
        if cmd == "close":
            with model.lock:
                model.link["connected"] = False
                model.link["state"] = "未连接"
                payload = dict(model.link)
            self.broadcast({"t": "link", **payload})
            self.broadcast(model.state_payload())
            return
        if cmd != "open":
            client.send_json({"t": "error", "code": "bad_request",
                              "message": "link.cmd 只能是 open/close/refresh"})
            return
        if model.link["connected"]:
            client.send_json({"t": "error", "code": "link_busy", "message": "请先断开"})
            return

        kind = message.get("kind")
        if not isinstance(kind, int) or not 0 <= kind <= 4:
            client.send_json({"t": "error", "code": "bad_link", "message": "kind 不合法"})
            return

        port = message.get("port")
        if kind == 0 and not (isinstance(port, str) and port) and not model.link["serialPort"]:
            client.send_json({"t": "error", "code": "no_port", "message": "没有可用串口"})
            return

        names = ["串口", "TCP 客户端", "TCP 服务端", "UDP", "演示"]
        with model.lock:
            model.link["kind"] = kind
            model.link["connected"] = True
            model.link["state"] = names[kind]
            if isinstance(port, str) and port:
                model.link["serialPort"] = port
            baud = message.get("baud")
            if isinstance(baud, int) and baud > 0:
                model.link["baud"] = baud
            if isinstance(port, int) and port > 0:
                if kind == 1:
                    model.link["tcpClientPort"] = port
                elif kind == 2:
                    model.link["tcpServerPort"] = port
            payload = dict(model.link)

        self.log(f"link open kind={kind} port={port}")
        self.broadcast({"t": "link", **payload})
        self.broadcast(model.state_payload())

    def start_oneclick(self, client, message):
        model = self.model
        group = message.get("group") or model.pc_group
        if group not in model.groups:
            client.send_json({"t": "error", "code": "unknown_group", "message": "组不存在"})
            return
        with model.lock:
            if model.oneclick["sending"]:
                client.send_json({"t": "error", "code": "busy", "message": "正在一键发送"})
                return
            if not model.conn_connected:
                # Mirrors the PC: no transport means the run is refused before a
                # plan is even built, and `phase=idle` unlocks the phone.
                offline_status = "未连接：请先连接设备再一键发送"
                model.oneclick.update({"sending": False, "sent": 0, "total": 0,
                                       "status": offline_status})
                plan = None
                interval = 0
            else:
                plan = sorted([c for c in model.controls if c.group == group and c.inc],
                              key=lambda c: c.order)
                if not plan:
                    client.send_json({"t": "error", "code": "empty_plan", "message": "该组没有可发送的滑块"})
                    return
                interval = min(max(int(message.get("intervalMs") or 100), 10), 5000)
                model.oneclick.update({"sending": True, "sent": 0, "total": len(plan),
                                       "status": "", "interval": interval})

        if plan is None:
            self.broadcast({"t": "oneclick", "phase": "idle", "sent": 0, "total": 0,
                            "status": offline_status})
            client.send_json({"t": "error", "code": "not_connected", "message": offline_status})
            self.log("oneclick refused: not_connected")
            return

        self.log(f"oneclick group={group} plan={len(plan)} interval={interval}")

        self.broadcast({"t": "oneclick", "phase": "start", "sent": 0,
                        "total": len(plan), "status": "开始发送"})

        def run():
            for index, control in enumerate(plan, start=1):
                with model.lock:
                    if not model.oneclick["sending"]:
                        return
                    model.oneclick["sent"] = index
                    model.oneclick["status"] = f"已发送 {index}/{len(plan)}: {control.label}"
                self.broadcast({"t": "oneclick", "phase": "step", "sent": index,
                                "total": len(plan), "status": f"已发送 {index}/{len(plan)}: {control.label}"})
                time.sleep(interval / 1000.0)
            with model.lock:
                if not model.oneclick["sending"]:
                    return
                model.oneclick["sending"] = False
            self.broadcast({"t": "oneclick", "phase": "done", "sent": len(plan),
                            "total": len(plan), "status": f"完成 {len(plan)} 项"})

        threading.Thread(target=run, daemon=True).start()

    # -- background ------------------------------------------------------
    def heartbeat_loop(self):
        while self.running:
            time.sleep(15)
            with self.lock:
                targets = [c for c in self.clients if c.alive and c.hello_done]
            for client in targets:
                client.send_frame(0x9, b"vofa")

    def wiggle_loop(self):
        """Simulate the PC editing a value every few seconds."""
        if not os.environ.get("VOFA_MOCK_WIGGLE"):
            return
        import math
        step = 0
        while self.running:
            time.sleep(3)
            with self.model.lock:
                control = self.model.control(1000)
                if control is None:
                    continue
                step += 1
                value = round(control.minimum + (control.maximum - control.minimum) *
                              (0.5 + 0.45 * math.sin(step / 3.0)), 2)
                control.value = value
            self.broadcast({"t": "value", "id": 1000, "v": value, "from": "pc"})


def main():
    parser = argparse.ArgumentParser(description="VOFA2 remote tuning mock server")
    parser.add_argument("--port", type=int, default=47900)
    parser.add_argument("--discovery-port", type=int, default=47901)
    parser.add_argument("--name", default="调试台 (mock)")
    parser.add_argument("--pin", default="")
    parser.add_argument("--wiggle", action="store_true", help="simulate PC-side value edits")
    parser.add_argument("--offline", action="store_true",
                        help="simulate a PC that is not connected to a board")
    parser.add_argument("--legacy", action="store_true",
                        help="reject {\"t\":\"inc\"} like an old PC build")
    parser.add_argument("--quiet", action="store_true")
    args = parser.parse_args()

    if args.wiggle:
        os.environ["VOFA_MOCK_WIGGLE"] = "1"

    model = Model(args.name, bool(args.pin), args.pin)
    if args.offline:
        model.conn_connected = False
        model.conn_text = "未连接"
        model.link["connected"] = False
        model.link["state"] = "未连接"
    server = Server(model, args.port, args.discovery_port, verbose=not args.quiet,
                    legacy=args.legacy)
    print(f"mock server '{args.name}' control={args.port} discovery={args.discovery_port} "
          f"pin={'yes' if args.pin else 'no'} conn={'offline' if args.offline else 'online'} "
          f"inc={'legacy' if args.legacy else 'supported'}", flush=True)
    try:
        server.serve()
    except KeyboardInterrupt:
        sys.exit(0)


if __name__ == "__main__":
    main()
