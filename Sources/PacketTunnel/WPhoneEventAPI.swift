import CoreFoundation
import CryptoKit
import Foundation

struct WPhoneEvent {
    let specVersion: Int
    let id: String
    let source: String
    let type: String
    let occurredAtMilliseconds: Int64
    let payload: [String: Any]
    let priority: String
    let sound: String

    var idempotencyKey: String { "\(source):\(id)" }

    func payloadString(_ key: String) -> String? {
        payload[key] as? String
    }
}

struct WPhoneEventAPIError: Error {
    let httpStatus: Int
    let code: String
    let message: String
    let field: String?

    init(httpStatus: Int, code: String, message: String, field: String? = nil) {
        self.httpStatus = httpStatus
        self.code = code
        self.message = message
        self.field = field
    }
}

enum WPhoneEventContract {
    static let specVersion = 1
    static let endpoint = "/api/v1/events"
    static let maximumBodyBytes = 12 * 1024
    static let supportedEventTypes = [
        "message.received",
        "call.incoming",
        "call.ended",
        "notification.show",
        "notification.dismiss"
    ]

    static func decode(_ data: Data) throws -> WPhoneEvent {
        guard !data.isEmpty else {
            throw WPhoneEventAPIError(
                httpStatus: 400,
                code: "empty_body",
                message: "A JSON request body is required."
            )
        }
        guard data.count <= maximumBodyBytes else {
            throw WPhoneEventAPIError(
                httpStatus: 413,
                code: "body_too_large",
                message: "The JSON body exceeds 12288 bytes."
            )
        }

        let object: [String: Any]
        do {
            guard let decoded = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw WPhoneEventAPIError(
                    httpStatus: 400,
                    code: "invalid_json",
                    message: "The JSON root must be an object."
                )
            }
            object = decoded
        } catch let error as WPhoneEventAPIError {
            throw error
        } catch {
            throw WPhoneEventAPIError(
                httpStatus: 400,
                code: "invalid_json",
                message: "The request body is not valid JSON."
            )
        }

        guard let version = jsonInteger(object["specVersion"]) else {
            throw validationError("specVersion must be an integer.", field: "specVersion")
        }
        guard version == Int64(specVersion) else {
            throw WPhoneEventAPIError(
                httpStatus: 422,
                code: "unsupported_spec_version",
                message: "Only specVersion 1 is supported.",
                field: "specVersion"
            )
        }

        let id = try requiredString(
            in: object,
            key: "id",
            field: "id",
            maximumCharacters: 128,
            validator: isValidEventID
        )
        let source = try requiredString(
            in: object,
            key: "source",
            field: "source",
            maximumCharacters: 64,
            validator: isValidSource
        )
        let type = try requiredString(
            in: object,
            key: "type",
            field: "type",
            maximumCharacters: 64,
            validator: isValidEventType
        )
        guard supportedEventTypes.contains(type) || isCustomEventType(type) else {
            throw WPhoneEventAPIError(
                httpStatus: 422,
                code: "unsupported_event_type",
                message: "Use a documented event type or custom.<vendor>.<name>.",
                field: "type"
            )
        }

        guard let occurredAt = jsonInteger(object["occurredAt"]), occurredAt > 0 else {
            throw validationError(
                "occurredAt must be a positive Unix timestamp in milliseconds.",
                field: "occurredAt"
            )
        }
        guard let payload = object["payload"] as? [String: Any] else {
            throw validationError("payload must be a JSON object.", field: "payload")
        }

        try validatePayload(payload, for: type)
        try validateExtensions(object["extensions"])
        let delivery = try decodeDelivery(object["delivery"], eventType: type)

        return WPhoneEvent(
            specVersion: specVersion,
            id: id,
            source: source,
            type: type,
            occurredAtMilliseconds: occurredAt,
            payload: payload,
            priority: delivery.priority,
            sound: delivery.sound
        )
    }

    static func requestDigest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func notificationIdentifier(source: String, eventID: String) -> String {
        let key = Data("\(source)\u{0}\(eventID)".utf8)
        let digest = SHA256.hash(data: key).prefix(16)
        let suffix = digest.map { String(format: "%02x", $0) }.joined()
        return "app.wephone.vpn.event.\(suffix)"
    }

    static func effect(for eventType: String) -> String {
        switch eventType {
        case "message.received", "notification.show":
            return "notification_submitted"
        case "call.incoming":
            return "call_notification_submitted"
        case "call.ended", "notification.dismiss":
            return "notification_removed"
        default:
            return "logged_only"
        }
    }

    private static func validatePayload(_ payload: [String: Any], for type: String) throws {
        switch type {
        case "message.received":
            _ = try requiredString(
                in: payload,
                key: "body",
                field: "payload.body",
                maximumCharacters: 1_000
            )
            _ = try optionalString(in: payload, key: "title", field: "payload.title", maximumCharacters: 120)
            _ = try optionalString(in: payload, key: "sender", field: "payload.sender", maximumCharacters: 120)
            _ = try optionalString(
                in: payload,
                key: "conversationId",
                field: "payload.conversationId",
                maximumCharacters: 128
            )
            _ = try optionalString(
                in: payload,
                key: "mediaKind",
                field: "payload.mediaKind",
                maximumCharacters: 32
            )
        case "call.incoming":
            _ = try requiredString(
                in: payload,
                key: "caller",
                field: "payload.caller",
                maximumCharacters: 120
            )
            _ = try optionalString(in: payload, key: "title", field: "payload.title", maximumCharacters: 120)
            _ = try optionalString(
                in: payload,
                key: "callKind",
                field: "payload.callKind",
                maximumCharacters: 32
            )
        case "call.ended", "notification.dismiss":
            _ = try requiredString(
                in: payload,
                key: "targetId",
                field: "payload.targetId",
                maximumCharacters: 128,
                validator: isValidEventID
            )
        case "notification.show":
            _ = try requiredString(
                in: payload,
                key: "body",
                field: "payload.body",
                maximumCharacters: 1_000
            )
            _ = try optionalString(in: payload, key: "title", field: "payload.title", maximumCharacters: 120)
        default:
            break
        }
    }

    private static func decodeDelivery(
        _ rawValue: Any?,
        eventType: String
    ) throws -> (priority: String, sound: String) {
        let defaultPriority = eventType == "call.incoming" ? "timeSensitive" : "normal"
        guard let rawValue else { return (defaultPriority, "default") }
        guard let delivery = rawValue as? [String: Any] else {
            throw validationError("delivery must be a JSON object.", field: "delivery")
        }

        let priority = try optionalString(
            in: delivery,
            key: "priority",
            field: "delivery.priority",
            maximumCharacters: 32
        ) ?? defaultPriority
        guard priority == "normal" || priority == "timeSensitive" else {
            throw validationError(
                "delivery.priority must be normal or timeSensitive.",
                field: "delivery.priority"
            )
        }

        let sound = try optionalString(
            in: delivery,
            key: "sound",
            field: "delivery.sound",
            maximumCharacters: 16
        ) ?? "default"
        guard sound == "default" || sound == "none" else {
            throw validationError(
                "delivery.sound must be default or none.",
                field: "delivery.sound"
            )
        }
        return (priority, sound)
    }

    private static func validateExtensions(_ rawValue: Any?) throws {
        guard let rawValue else { return }
        guard let extensions = rawValue as? [String: Any] else {
            throw validationError("extensions must be a JSON object.", field: "extensions")
        }
        guard extensions.count <= 16 else {
            throw validationError("extensions may contain at most 16 entries.", field: "extensions")
        }
        for key in extensions.keys {
            guard key.count <= 128, isValidExtensionKey(key) else {
                throw validationError(
                    "Extension keys must use a reverse-domain name such as com.example.feature.",
                    field: "extensions"
                )
            }
        }
    }

    private static func requiredString(
        in object: [String: Any],
        key: String,
        field: String,
        maximumCharacters: Int,
        validator: ((String) -> Bool)? = nil
    ) throws -> String {
        guard let value = object[key] as? String, !value.isEmpty else {
            throw validationError("\(field) must be a non-empty string.", field: field)
        }
        guard value.count <= maximumCharacters else {
            throw validationError("\(field) exceeds \(maximumCharacters) characters.", field: field)
        }
        if let validator, !validator(value) {
            throw validationError("\(field) has an invalid format.", field: field)
        }
        return value
    }

    private static func optionalString(
        in object: [String: Any],
        key: String,
        field: String,
        maximumCharacters: Int
    ) throws -> String? {
        guard let rawValue = object[key] else { return nil }
        guard let value = rawValue as? String, !value.isEmpty else {
            throw validationError("\(field) must be a non-empty string when provided.", field: field)
        }
        guard value.count <= maximumCharacters else {
            throw validationError("\(field) exceeds \(maximumCharacters) characters.", field: field)
        }
        return value
    }

    private static func jsonInteger(_ value: Any?) -> Int64? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number as CFTypeRef) != CFBooleanGetTypeID() else {
            return nil
        }
        let doubleValue = number.doubleValue
        guard doubleValue.isFinite,
              doubleValue.rounded(.towardZero) == doubleValue,
              doubleValue >= Double(Int64.min),
              doubleValue <= Double(Int64.max) else {
            return nil
        }
        return number.int64Value
    }

    private static func isValidEventID(_ value: String) -> Bool {
        value.unicodeScalars.allSatisfy { scalar in
            isASCIILetterOrDigit(scalar)
                || scalar == "."
                || scalar == "_"
                || scalar == ":"
                || scalar == "-"
        }
    }

    private static func isValidSource(_ value: String) -> Bool {
        guard let first = value.unicodeScalars.first, isASCIILowercase(first) else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            isASCIILowercase(scalar)
                || (scalar.value >= 48 && scalar.value <= 57)
                || scalar == "."
                || scalar == "_"
                || scalar == "-"
        }
    }

    private static func isValidEventType(_ value: String) -> Bool {
        let components = value.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count >= 2, components.allSatisfy({ !$0.isEmpty }) else { return false }
        return components.allSatisfy { component in
            guard let first = component.unicodeScalars.first, isASCIILowercase(first) else { return false }
            return component.unicodeScalars.allSatisfy { scalar in
                isASCIILowercase(scalar)
                    || (scalar.value >= 48 && scalar.value <= 57)
                    || scalar == "_"
                    || scalar == "-"
            }
        }
    }

    private static func isCustomEventType(_ value: String) -> Bool {
        value.split(separator: ".").count >= 3 && value.hasPrefix("custom.")
    }

    private static func isValidExtensionKey(_ value: String) -> Bool {
        let components = value.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count >= 3, components.allSatisfy({ !$0.isEmpty }) else { return false }
        return components.allSatisfy { component in
            guard let first = component.unicodeScalars.first, isASCIILowercase(first) else { return false }
            return component.unicodeScalars.allSatisfy { scalar in
                isASCIILowercase(scalar)
                    || (scalar.value >= 48 && scalar.value <= 57)
                    || scalar == "-"
            }
        }
    }

    private static func isASCIILowercase(_ scalar: UnicodeScalar) -> Bool {
        scalar.value >= 97 && scalar.value <= 122
    }

    private static func isASCIILetterOrDigit(_ scalar: UnicodeScalar) -> Bool {
        (scalar.value >= 48 && scalar.value <= 57)
            || (scalar.value >= 65 && scalar.value <= 90)
            || (scalar.value >= 97 && scalar.value <= 122)
    }

    private static func validationError(_ message: String, field: String) -> WPhoneEventAPIError {
        WPhoneEventAPIError(
            httpStatus: 422,
            code: "validation_failed",
            message: message,
            field: field
        )
    }

    static let openAPIJSON = #"""
    {
      "openapi": "3.0.3",
      "info": {
        "title": "WPhone LAN API",
        "version": "1.3.0",
        "description": "Versioned event delivery and private-LAN debug API for WPhone. This API has no authentication or TLS and must remain on a trusted private network."
      },
      "servers": [{ "url": "/" }],
      "security": [],
      "paths": {
        "/.well-known/wphone": {
          "get": {
            "operationId": "discoverWPhone",
            "responses": { "200": { "$ref": "#/components/responses/Success" } }
          }
        },
        "/health": {
          "get": {
            "operationId": "getHealth",
            "responses": { "200": { "$ref": "#/components/responses/Success" } }
          }
        },
        "/api/status": {
          "get": {
            "operationId": "getStatus",
            "responses": { "200": { "$ref": "#/components/responses/Success" } }
          }
        },
        "/api/logs": {
          "get": {
            "operationId": "getIncrementalLogs",
            "parameters": [{
              "name": "cursor",
              "in": "query",
              "required": false,
              "schema": { "type": "integer", "format": "int64", "minimum": 0 }
            }],
            "responses": { "200": { "$ref": "#/components/responses/Success" } }
          }
        },
        "/api/v1/events": {
          "post": {
            "operationId": "submitEventV1",
            "summary": "Submit an idempotent event",
            "requestBody": {
              "required": true,
              "content": {
                "application/json": {
                  "schema": { "$ref": "#/components/schemas/EventV1" }
                }
              }
            },
            "responses": {
              "200": {
                "description": "A byte-identical event was already accepted and was not executed again.",
                "content": { "application/json": { "schema": { "$ref": "#/components/schemas/EventResponse" } } }
              },
              "202": {
                "description": "The event was accepted for local processing.",
                "content": { "application/json": { "schema": { "$ref": "#/components/schemas/EventResponse" } } }
              },
              "400": { "$ref": "#/components/responses/Error" },
              "409": { "$ref": "#/components/responses/Error" },
              "413": { "$ref": "#/components/responses/Error" },
              "415": { "$ref": "#/components/responses/Error" },
              "422": { "$ref": "#/components/responses/Error" },
              "500": { "$ref": "#/components/responses/Error" }
            }
          }
        },
        "/api/debug/message": {
          "post": {
            "operationId": "showDebugMessage",
            "parameters": [
              {
                "name": "title",
                "in": "query",
                "required": false,
                "schema": { "type": "string", "maxLength": 80 }
              },
              {
                "name": "body",
                "in": "query",
                "required": false,
                "schema": { "type": "string", "maxLength": 240 }
              }
            ],
            "responses": { "202": { "$ref": "#/components/responses/Success" } }
          }
        },
        "/api/debug/call": {
          "post": {
            "operationId": "reportDebugCallKitCall",
            "description": "Queues an incoming call for the main-app CallKit provider through the App Group bridge. If the host app does not acknowledge it, WPhone falls back to a sound notification. Answer immediately ends the synthetic call and posts a silent foreground-action notification that launches WPhone and then opens WeChat.",
            "parameters": [{
              "name": "caller",
              "in": "query",
              "required": false,
              "schema": { "type": "string", "maxLength": 80 }
            }],
            "responses": { "202": { "$ref": "#/components/responses/Success" } }
          }
        },
        "/api/debug/stop": {
          "post": {
            "operationId": "stopDebugAlerts",
            "responses": { "200": { "$ref": "#/components/responses/Success" } }
          }
        }
      },
      "components": {
        "schemas": {
          "EventV1": {
            "type": "object",
            "required": ["specVersion", "id", "source", "type", "occurredAt", "payload"],
            "additionalProperties": true,
            "properties": {
              "specVersion": { "type": "integer", "enum": [1] },
              "id": {
                "type": "string",
                "minLength": 1,
                "maxLength": 128,
                "pattern": "^[A-Za-z0-9._:-]+$"
              },
              "source": {
                "type": "string",
                "minLength": 1,
                "maxLength": 64,
                "pattern": "^[a-z][a-z0-9._-]*$"
              },
              "type": {
                "oneOf": [
                  {
                    "type": "string",
                    "enum": [
                      "message.received",
                      "call.incoming",
                      "call.ended",
                      "notification.show",
                      "notification.dismiss"
                    ]
                  },
                  {
                    "type": "string",
                    "pattern": "^custom\\.[a-z][a-z0-9_-]*(\\.[a-z][a-z0-9_-]*)+$"
                  }
                ]
              },
              "occurredAt": {
                "type": "integer",
                "format": "int64",
                "minimum": 1,
                "description": "Unix timestamp in milliseconds at the source."
              },
              "payload": {
                "type": "object",
                "additionalProperties": true,
                "properties": {
                  "title": { "type": "string", "minLength": 1, "maxLength": 120 },
                  "body": { "type": "string", "minLength": 1, "maxLength": 1000 },
                  "sender": { "type": "string", "minLength": 1, "maxLength": 120 },
                  "conversationId": { "type": "string", "minLength": 1, "maxLength": 128 },
                  "mediaKind": { "type": "string", "minLength": 1, "maxLength": 32 },
                  "caller": { "type": "string", "minLength": 1, "maxLength": 120 },
                  "callKind": { "type": "string", "minLength": 1, "maxLength": 32 },
                  "targetId": {
                    "type": "string",
                    "minLength": 1,
                    "maxLength": 128,
                    "pattern": "^[A-Za-z0-9._:-]+$"
                  }
                }
              },
              "delivery": {
                "type": "object",
                "additionalProperties": true,
                "properties": {
                  "priority": { "type": "string", "enum": ["normal", "timeSensitive"] },
                  "sound": { "type": "string", "enum": ["default", "none"] }
                }
              },
              "extensions": {
                "type": "object",
                "maxProperties": 16,
                "additionalProperties": {},
                "description": "Opaque vendor metadata. Keys use reverse-domain names such as com.example.feature and values are ignored by WPhone v1."
              }
            },
            "oneOf": [
              {
                "title": "MessageReceived",
                "properties": {
                  "type": { "enum": ["message.received"] },
                  "payload": { "required": ["body"] }
                }
              },
              {
                "title": "CallIncoming",
                "properties": {
                  "type": { "enum": ["call.incoming"] },
                  "payload": { "required": ["caller"] }
                }
              },
              {
                "title": "CallEnded",
                "properties": {
                  "type": { "enum": ["call.ended"] },
                  "payload": { "required": ["targetId"] }
                }
              },
              {
                "title": "NotificationShow",
                "properties": {
                  "type": { "enum": ["notification.show"] },
                  "payload": { "required": ["body"] }
                }
              },
              {
                "title": "NotificationDismiss",
                "properties": {
                  "type": { "enum": ["notification.dismiss"] },
                  "payload": { "required": ["targetId"] }
                }
              },
              {
                "title": "CustomEvent",
                "properties": {
                  "type": { "type": "string", "pattern": "^custom\\." }
                }
              }
            ]
          },
          "EventResponse": {
            "type": "object",
            "required": ["ok", "apiVersion", "status", "duplicate", "effect", "firstAcceptedAt", "event"],
            "properties": {
              "ok": { "type": "boolean", "enum": [true] },
              "apiVersion": { "type": "integer", "enum": [1] },
              "status": { "type": "string", "enum": ["accepted", "duplicate"] },
              "duplicate": { "type": "boolean" },
              "effect": {
                "type": "string",
                "enum": [
                  "notification_submitted",
                  "call_notification_submitted",
                  "notification_removed",
                  "logged_only"
                ]
              },
              "event": {
                "type": "object",
                "required": ["id", "source", "type"],
                "properties": {
                  "id": { "type": "string" },
                  "source": { "type": "string" },
                  "type": { "type": "string" }
                }
              },
              "firstAcceptedAt": { "type": "integer", "format": "int64" }
            }
          },
          "ErrorResponse": {
            "type": "object",
            "required": ["ok", "error"],
            "properties": {
              "ok": { "type": "boolean", "enum": [false] },
              "error": {
                "type": "object",
                "required": ["code", "message"],
                "properties": {
                  "code": {
                    "type": "string",
                    "enum": [
                      "invalid_http_request",
                      "invalid_json",
                      "empty_body",
                      "idempotency_conflict",
                      "request_too_large",
                      "body_too_large",
                      "unsupported_media_type",
                      "validation_failed",
                      "unsupported_spec_version",
                      "unsupported_event_type",
                      "invalid_cursor",
                      "route_not_found",
                      "internal_error"
                    ]
                  },
                  "message": { "type": "string" },
                  "field": { "type": "string" }
                }
              }
            }
          }
        },
        "responses": {
          "Success": {
            "description": "Successful JSON response",
            "content": { "application/json": { "schema": { "type": "object" } } }
          },
          "Error": {
            "description": "Error response",
            "content": { "application/json": { "schema": { "$ref": "#/components/schemas/ErrorResponse" } } }
          }
        }
      }
    }
    """#
}

final class WPhoneEventIdempotencyStore {
    struct Record: Codable {
        let key: String
        let requestDigest: String
        let firstAcceptedAtMilliseconds: Int64
        let effect: String
    }

    enum Decision {
        case accepted(Record)
        case duplicate(Record)
        case conflict(Record)
    }

    private static let retentionMilliseconds: Int64 = 24 * 60 * 60 * 1_000
    private static let maximumRecords = 512

    private let log: SharedLogger
    private let fileURL: URL?
    private var records: [Record] = []

    init(log: SharedLogger) {
        self.log = log
        fileURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: SharedLogger.appGroupIdentifier
        )?.appendingPathComponent("event-idempotency-v1.json", isDirectory: false)
        load()
    }

    var count: Int { records.count }

    func evaluate(key: String, requestDigest: String, effect: String) -> Decision {
        let now = Int64(Date().timeIntervalSince1970 * 1_000)
        prune(now: now)

        if let existing = records.first(where: { $0.key == key }) {
            return existing.requestDigest == requestDigest ? .duplicate(existing) : .conflict(existing)
        }

        let record = Record(
            key: key,
            requestDigest: requestDigest,
            firstAcceptedAtMilliseconds: now,
            effect: effect
        )
        records.append(record)
        if records.count > Self.maximumRecords {
            records.removeFirst(records.count - Self.maximumRecords)
        }
        persist()
        return .accepted(record)
    }

    private func load() {
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return }
        do {
            records = try JSONDecoder().decode([Record].self, from: data)
            prune(now: Int64(Date().timeIntervalSince1970 * 1_000), persistChanges: false)
        } catch {
            log.error("Unable to decode event idempotency store: \(error.localizedDescription)")
            records = []
        }
    }

    private func prune(now: Int64, persistChanges: Bool = true) {
        let previousCount = records.count
        records.removeAll { now - $0.firstAcceptedAtMilliseconds > Self.retentionMilliseconds }
        if records.count > Self.maximumRecords {
            records.removeFirst(records.count - Self.maximumRecords)
        }
        if persistChanges && records.count != previousCount {
            persist()
        }
    }

    private func persist() {
        guard let fileURL else {
            log.error("App Group container is unavailable for event idempotency")
            return
        }
        do {
            let data = try JSONEncoder().encode(records)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            log.error("Unable to persist event idempotency store: \(error.localizedDescription)")
        }
    }
}
