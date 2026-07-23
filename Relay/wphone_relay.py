#!/usr/bin/env python3
"""Trusted-LAN HTTP-to-WPhone Local Push relay."""

import argparse
import asyncio
import base64
import ipaddress
import json
import logging
import signal
import uuid
from urllib.parse import urlsplit


MAXIMUM_BODY_BYTES = 12 * 1024
MAXIMUM_HEADER_BYTES = 16 * 1024
MAXIMUM_PROVIDER_FRAME_BYTES = 24 * 1024


class HTTPFailure(Exception):
    def __init__(self, status, code, message):
        super().__init__(message)
        self.status = status
        self.code = code
        self.message = message


class RelayServer:
    def __init__(self, host="0.0.0.0", http_port=8080, provider_port=8081, ack_timeout=5.0):
        self.host = host
        self.http_port = http_port
        self.provider_port = provider_port
        self.ack_timeout = ack_timeout
        self._http_server = None
        self._provider_server = None
        self._providers = {}
        self._pending_acks = {}
        self.log = logging.getLogger("wphone-relay")

    @property
    def bound_http_port(self):
        return self._http_server.sockets[0].getsockname()[1]

    @property
    def bound_provider_port(self):
        return self._provider_server.sockets[0].getsockname()[1]

    async def start(self):
        self._http_server = await asyncio.start_server(
            self._handle_http,
            self.host,
            self.http_port,
            limit=MAXIMUM_HEADER_BYTES + MAXIMUM_BODY_BYTES + 1024,
        )
        self._provider_server = await asyncio.start_server(
            self._handle_provider,
            self.host,
            self.provider_port,
            limit=MAXIMUM_PROVIDER_FRAME_BYTES + 1,
        )
        self.log.info(
            "HTTP ingress listening on %s:%s; provider channel on %s:%s",
            self.host,
            self.bound_http_port,
            self.host,
            self.bound_provider_port,
        )

    async def close(self):
        for server in (self._http_server, self._provider_server):
            if server is not None:
                server.close()
        for server in (self._http_server, self._provider_server):
            if server is not None:
                await server.wait_closed()
        for writer in list(self._providers):
            writer.close()
        self._providers.clear()
        for future in self._pending_acks.values():
            if not future.done():
                future.cancel()
        self._pending_acks.clear()

    async def serve_forever(self):
        async with self._http_server, self._provider_server:
            await asyncio.gather(
                self._http_server.serve_forever(),
                self._provider_server.serve_forever(),
            )

    async def _handle_provider(self, reader, writer):
        peer = writer.get_extra_info("peername")
        device_id = None
        if not self._is_private_peer(peer):
            self.log.warning("rejected non-private provider peer=%s", peer)
            writer.close()
            await writer.wait_closed()
            return
        try:
            while True:
                frame = await reader.readline()
                if not frame:
                    break
                if len(frame) > MAXIMUM_PROVIDER_FRAME_BYTES:
                    raise ValueError("provider frame is too large")
                try:
                    message = json.loads(frame)
                except (UnicodeDecodeError, json.JSONDecodeError) as error:
                    raise ValueError("provider frame is not valid JSON") from error
                if not isinstance(message, dict):
                    raise ValueError("provider frame must be a JSON object")

                kind = message.get("kind")
                if kind == "register":
                    candidate = message.get("deviceID")
                    if not isinstance(candidate, str) or not candidate or len(candidate) > 128:
                        raise ValueError("registration requires a valid deviceID")
                    device_id = candidate
                    self._providers[writer] = device_id
                    await self._write_provider_frame(
                        writer,
                        {"kind": "registered", "protocolVersion": 1},
                    )
                    self.log.info("iPhone provider connected device=%s peer=%s", device_id, peer)
                elif kind == "ack" and device_id is not None:
                    delivery_id = message.get("deliveryID")
                    future = self._pending_acks.get(delivery_id)
                    if future is not None and not future.done():
                        future.set_result(message)
                elif kind == "ping":
                    await self._write_provider_frame(
                        writer,
                        {"kind": "pong", "timestamp": message.get("timestamp")},
                    )
                elif kind == "pong":
                    continue
                else:
                    raise ValueError("provider sent an unsupported frame")
        except (asyncio.IncompleteReadError, ConnectionError, ValueError) as error:
            self.log.warning("provider connection ended peer=%s reason=%s", peer, error)
        finally:
            self._providers.pop(writer, None)
            writer.close()
            try:
                await writer.wait_closed()
            except ConnectionError:
                pass
            if device_id is not None:
                self.log.info("iPhone provider disconnected device=%s", device_id)

    async def _handle_http(self, reader, writer):
        status = 500
        payload = self._error_payload("internal_error", "The request could not be processed.")
        try:
            if not self._is_private_peer(writer.get_extra_info("peername")):
                raise HTTPFailure(403, "private_network_required", "Only private-LAN clients are allowed.")
            status, payload = await self._dispatch_http(reader)
        except HTTPFailure as error:
            status = error.status
            payload = self._error_payload(error.code, error.message)
        except (asyncio.IncompleteReadError, ConnectionError):
            status = 400
            payload = self._error_payload("incomplete_request", "The HTTP request was incomplete.")
        except Exception:
            self.log.exception("unexpected HTTP ingress failure")

        try:
            await self._write_http_response(writer, status, payload)
        except ConnectionError:
            pass
        finally:
            writer.close()
            try:
                await writer.wait_closed()
            except ConnectionError:
                pass

    async def _dispatch_http(self, reader):
        try:
            header_data = await reader.readuntil(b"\r\n\r\n")
        except (asyncio.LimitOverrunError, asyncio.IncompleteReadError) as error:
            raise HTTPFailure(400, "invalid_http", "A complete HTTP header is required.") from error
        if len(header_data) > MAXIMUM_HEADER_BYTES:
            raise HTTPFailure(431, "headers_too_large", "HTTP headers exceed 16384 bytes.")

        try:
            header_text = header_data.decode("iso-8859-1")
            lines = header_text[:-4].split("\r\n")
            method, raw_target, version = lines[0].split(" ")
        except (UnicodeDecodeError, ValueError, IndexError) as error:
            raise HTTPFailure(400, "invalid_http", "The HTTP request line is invalid.") from error
        if version not in ("HTTP/1.0", "HTTP/1.1"):
            raise HTTPFailure(505, "unsupported_http_version", "Use HTTP/1.0 or HTTP/1.1.")

        headers = {}
        for line in lines[1:]:
            if ":" not in line:
                raise HTTPFailure(400, "invalid_http", "An HTTP header is invalid.")
            name, value = line.split(":", 1)
            normalized_name = name.strip().lower()
            if not normalized_name or normalized_name in headers:
                raise HTTPFailure(400, "invalid_http", "Duplicate or empty HTTP headers are not supported.")
            headers[normalized_name] = value.strip()

        path = urlsplit(raw_target).path
        if method == "GET" and path in ("/health", "/api/status"):
            return 200, {
                "ok": True,
                "service": "wphone-local-push-relay",
                "providers": len(self._providers),
            }
        if method != "POST" or path != "/api/v1/events":
            raise HTTPFailure(404, "not_found", "The requested endpoint does not exist.")
        if "transfer-encoding" in headers:
            raise HTTPFailure(400, "unsupported_transfer_encoding", "Chunked requests are not supported.")
        content_type = headers.get("content-type", "").split(";", 1)[0].strip().lower()
        if content_type != "application/json":
            raise HTTPFailure(415, "unsupported_media_type", "Content-Type must be application/json.")
        try:
            content_length = int(headers["content-length"])
        except (KeyError, ValueError) as error:
            raise HTTPFailure(411, "content_length_required", "A valid Content-Length is required.") from error
        if content_length < 1:
            raise HTTPFailure(400, "empty_body", "A JSON request body is required.")
        if content_length > MAXIMUM_BODY_BYTES:
            raise HTTPFailure(413, "body_too_large", "The JSON body exceeds 12288 bytes.")
        body = await reader.readexactly(content_length)

        try:
            event = json.loads(body)
        except (UnicodeDecodeError, json.JSONDecodeError) as error:
            raise HTTPFailure(400, "invalid_json", "The request body is not valid JSON.") from error
        if not isinstance(event, dict):
            raise HTTPFailure(400, "invalid_json", "The JSON root must be an object.")

        ack = await self._deliver_event(body)
        return self._event_response(ack, event)

    async def _deliver_event(self, body):
        available = [writer for writer in self._providers if not writer.is_closing()]
        if not available:
            raise HTTPFailure(503, "provider_unavailable", "No iPhone Local Push provider is connected.")

        delivery_id = str(uuid.uuid4())
        frame = {
            "kind": "event",
            "deliveryID": delivery_id,
            "eventBase64": base64.b64encode(body).decode("ascii"),
        }
        future = asyncio.get_running_loop().create_future()
        self._pending_acks[delivery_id] = future
        delivered = 0
        try:
            for writer in available:
                try:
                    await self._write_provider_frame(writer, frame)
                    delivered += 1
                except ConnectionError:
                    self._providers.pop(writer, None)
            if delivered == 0:
                raise HTTPFailure(503, "provider_unavailable", "No iPhone Local Push provider is connected.")
            try:
                return await asyncio.wait_for(future, timeout=self.ack_timeout)
            except asyncio.TimeoutError as error:
                raise HTTPFailure(504, "provider_timeout", "The iPhone did not acknowledge the event.") from error
        finally:
            self._pending_acks.pop(delivery_id, None)
            if not future.done():
                future.cancel()

    @staticmethod
    async def _write_provider_frame(writer, payload):
        data = json.dumps(payload, ensure_ascii=True, separators=(",", ":")).encode("utf-8") + b"\n"
        if len(data) > MAXIMUM_PROVIDER_FRAME_BYTES:
            raise ValueError("provider frame is too large")
        writer.write(data)
        await writer.drain()

    @staticmethod
    def _event_response(ack, event):
        status = ack.get("status")
        if status == "accepted":
            http_status = 202
        elif status == "duplicate":
            http_status = 200
        elif status == "conflict":
            raise HTTPFailure(409, "idempotency_conflict", "The idempotency key was reused with different content.")
        elif status == "rejected":
            code = ack.get("errorCode", "event_rejected")
            http_status = 500 if code == "internal_error" else 422
            raise HTTPFailure(http_status, code, "The iPhone rejected the event.")
        else:
            raise HTTPFailure(502, "invalid_provider_ack", "The iPhone returned an invalid acknowledgement.")

        return http_status, {
            "ok": True,
            "apiVersion": 1,
            "status": status,
            "duplicate": status == "duplicate",
            "effect": ack.get("effect"),
            "firstAcceptedAt": ack.get("firstAcceptedAt"),
            "event": {
                "id": ack.get("id", event.get("id")),
                "source": ack.get("source", event.get("source")),
                "type": ack.get("eventType", event.get("type")),
            },
        }

    @staticmethod
    def _error_payload(code, message):
        return {
            "ok": False,
            "error": {
                "code": code,
                "message": message,
            },
        }

    @staticmethod
    def _is_private_peer(peer):
        if not peer:
            return False
        try:
            address = ipaddress.ip_address(peer[0].split("%", 1)[0])
        except ValueError:
            return False
        return address.is_private or address.is_loopback or address.is_link_local

    @staticmethod
    async def _write_http_response(writer, status, payload):
        reasons = {
            200: "OK",
            202: "Accepted",
            400: "Bad Request",
            403: "Forbidden",
            404: "Not Found",
            409: "Conflict",
            411: "Length Required",
            413: "Payload Too Large",
            415: "Unsupported Media Type",
            422: "Unprocessable Content",
            431: "Request Header Fields Too Large",
            500: "Internal Server Error",
            502: "Bad Gateway",
            503: "Service Unavailable",
            504: "Gateway Timeout",
            505: "HTTP Version Not Supported",
        }
        body = json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        head = (
            "HTTP/1.1 {} {}\r\n"
            "Content-Type: application/json; charset=utf-8\r\n"
            "Content-Length: {}\r\n"
            "Cache-Control: no-store\r\n"
            "Connection: close\r\n\r\n"
        ).format(status, reasons.get(status, "Error"), len(body))
        writer.write(head.encode("ascii") + body)
        await writer.drain()


async def run(args):
    relay = RelayServer(
        host=args.host,
        http_port=args.http_port,
        provider_port=args.provider_port,
        ack_timeout=args.ack_timeout,
    )
    await relay.start()
    stop_event = asyncio.Event()
    loop = asyncio.get_running_loop()
    for name in ("SIGINT", "SIGTERM"):
        if hasattr(signal, name):
            try:
                loop.add_signal_handler(getattr(signal, name), stop_event.set)
            except NotImplementedError:
                pass
    await stop_event.wait()
    await relay.close()


def parse_args():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", default="0.0.0.0", help="listen address (default: 0.0.0.0)")
    parser.add_argument("--http-port", type=int, default=8080, help="event HTTP port (default: 8080)")
    parser.add_argument("--provider-port", type=int, default=8081, help="iPhone channel port (default: 8081)")
    parser.add_argument("--ack-timeout", type=float, default=5.0, help="iPhone acknowledgement timeout")
    return parser.parse_args()


def main():
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    try:
        asyncio.run(run(parse_args()))
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
