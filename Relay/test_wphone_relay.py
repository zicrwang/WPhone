import asyncio
import json
import unittest

from wphone_relay import RelayServer


class RelayServerTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.relay = RelayServer(
            host="127.0.0.1",
            http_port=0,
            provider_port=0,
            ack_timeout=0.2,
        )
        await self.relay.start()

    async def asyncTearDown(self):
        await self.relay.close()

    async def request(self, method, path, body=b"", content_type="application/json"):
        reader, writer = await asyncio.open_connection("127.0.0.1", self.relay.bound_http_port)
        request = (
            "{} {} HTTP/1.1\r\n"
            "Host: relay\r\n"
            "Content-Type: {}\r\n"
            "Content-Length: {}\r\n"
            "Connection: close\r\n\r\n"
        ).format(method, path, content_type, len(body)).encode("ascii") + body
        writer.write(request)
        await writer.drain()
        response = await reader.read()
        writer.close()
        await writer.wait_closed()
        head, payload = response.split(b"\r\n\r\n", 1)
        status = int(head.split(b" ", 2)[1])
        return status, json.loads(payload)

    async def connect_provider(self):
        reader, writer = await asyncio.open_connection("127.0.0.1", self.relay.bound_provider_port)
        writer.write(b'{"kind":"register","protocolVersion":1,"deviceID":"test-phone"}\n')
        await writer.drain()
        registered = json.loads(await reader.readline())
        self.assertEqual(registered["kind"], "registered")
        return reader, writer

    async def test_health_reports_provider_count(self):
        status, payload = await self.request("GET", "/health")
        self.assertEqual(status, 200)
        self.assertEqual(payload["service"], "wphone-vpn-relay")
        self.assertEqual(payload["providers"], 0)

    async def test_event_requires_connected_provider(self):
        status, payload = await self.request("POST", "/api/v1/events", b"{}")
        self.assertEqual(status, 503)
        self.assertEqual(payload["error"]["code"], "provider_unavailable")

    async def test_event_is_forwarded_and_acknowledged(self):
        provider_reader, provider_writer = await self.connect_provider()
        event = {
            "specVersion": 1,
            "id": "call-1",
            "source": "test.phone",
            "type": "call.incoming",
            "occurredAt": 1784800000123,
            "payload": {"caller": "Alice"},
        }
        body = json.dumps(event, separators=(",", ":")).encode("utf-8")

        async def acknowledge():
            frame = json.loads(await provider_reader.readline())
            self.assertEqual(frame["kind"], "event")
            ack = {
                "kind": "ack",
                "deliveryID": frame["deliveryID"],
                "status": "accepted",
                "source": event["source"],
                "id": event["id"],
                "eventType": event["type"],
                "effect": "notification_submitted",
                "firstAcceptedAt": 1784800000456,
            }
            provider_writer.write(json.dumps(ack).encode("utf-8") + b"\n")
            await provider_writer.drain()

        ack_task = asyncio.create_task(acknowledge())
        status, payload = await self.request("POST", "/api/v1/events", body)
        await ack_task
        self.assertEqual(status, 202)
        self.assertTrue(payload["ok"])
        self.assertEqual(payload["event"]["id"], "call-1")
        self.assertEqual(payload["firstAcceptedAt"], 1784800000456)
        provider_writer.close()
        await provider_writer.wait_closed()

    async def test_invalid_json_is_rejected_before_delivery(self):
        status, payload = await self.request("POST", "/api/v1/events", b"{")
        self.assertEqual(status, 400)
        self.assertEqual(payload["error"]["code"], "invalid_json")


if __name__ == "__main__":
    unittest.main()
