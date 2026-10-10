import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import ZeroOne

/// Club live doorbell and photos (supabase/migrations/202610100004_club_live_photos.sql).
@MainActor
final class ClubLivePhotosTests: XCTestCase {
    private let userID = "0a1b2c3d-0000-4000-8000-00000000a1b2"
    private var photoKey: String { userID + "/" + String(repeating: "ab", count: 32) }

    // MARK: Doorbell protocol

    func testAuthUserIDComesFromTheTokenSubjectLowercased() {
        XCTAssertEqual(ClubLiveProtocol.authUserID(fromToken: token(sub: userID.uppercased())), userID)
        XCTAssertNil(ClubLiveProtocol.authUserID(fromToken: "not-a-token"))
        XCTAssertNil(ClubLiveProtocol.authUserID(fromToken: token(sub: "someone")))
    }

    func testSocketURLAndPrivateJoin() throws {
        let configuration = ZeroOneAccountConfiguration(url: URL(string: "https://abc.supabase.co")!, publishableKey: "pk",
                                                        googleEnabled: false, appleEnabled: false)
        let url = try XCTUnwrap(ClubLiveProtocol.socketURL(configuration))
        XCTAssertEqual(url.scheme, "wss")
        XCTAssertEqual(url.path, "/realtime/v1/websocket")
        XCTAssertTrue(url.query?.contains("apikey=pk") == true)
        XCTAssertTrue(url.query?.contains("vsn=1.0.0") == true)

        let topic = ClubLiveProtocol.topic(authUserID: userID)
        XCTAssertEqual(topic, "realtime:inbox:" + userID)
        let join = try XCTUnwrap(ClubLiveProtocol.join(topic: topic, token: "jwt", ref: "1"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: join) as? [String: Any])
        XCTAssertEqual(object["event"] as? String, "phx_join")
        let payload = try XCTUnwrap(object["payload"] as? [String: Any])
        XCTAssertEqual(payload["access_token"] as? String, "jwt")
        XCTAssertEqual((payload["config"] as? [String: Any])?["private"] as? Bool, true)
    }

    func testDoorbellParsingAcceptsOnlyOwnTopicAndKnownConversations() {
        let topic = ClubLiveProtocol.topic(authUserID: userID)
        let nested = #"{"topic":"\#(topic)","event":"broadcast","payload":{"event":"chat","type":"broadcast","payload":{"conversation":"crew:ABC"}},"ref":null}"#
        XCTAssertEqual(ClubLiveProtocol.parse(Data(nested.utf8), topic: topic), .doorbell("crew:abc"))
        let flat = #"{"topic":"\#(topic)","event":"broadcast","payload":{"conversation":"dm:xyz"}}"#
        XCTAssertEqual(ClubLiveProtocol.parse(Data(flat.utf8), topic: topic), .doorbell("dm:xyz"))
        let other = #"{"topic":"realtime:inbox:someone","event":"broadcast","payload":{"conversation":"dm:xyz"}}"#
        XCTAssertEqual(ClubLiveProtocol.parse(Data(other.utf8), topic: topic), .other)
        let odd = #"{"topic":"\#(topic)","event":"broadcast","payload":{"conversation":"post:1"}}"#
        XCTAssertEqual(ClubLiveProtocol.parse(Data(odd.utf8), topic: topic), .other)
        let ok = #"{"topic":"\#(topic)","event":"phx_reply","payload":{"status":"ok","response":{}},"ref":"1"}"#
        XCTAssertEqual(ClubLiveProtocol.parse(Data(ok.utf8), topic: topic), .joined)
        let refused = #"{"topic":"\#(topic)","event":"phx_reply","payload":{"status":"error","response":{}},"ref":"1"}"#
        XCTAssertEqual(ClubLiveProtocol.parse(Data(refused.utf8), topic: topic), .refused)
    }

    // MARK: Photos

    func testPhotoKeysMustBeOwnFolderAndContentHash() {
        XCTAssertNotNil(ClubPhotoKey(photoKey))
        XCTAssertEqual(ClubPhotoKey(photoKey)?.objectName(thumbnail: true), photoKey + "-thumb.heic")
        XCTAssertNil(ClubPhotoKey(userID.uppercased() + "/" + String(repeating: "ab", count: 32)))
        XCTAssertNil(ClubPhotoKey(userID + "/" + String(repeating: "AB", count: 32)))
        XCTAssertNil(ClubPhotoKey(userID + "/short"))
        XCTAssertNil(ClubPhotoKey("../" + photoKey))
    }

    func testEncoderShrinksToHEICAndDropsLocation() throws {
        let original = try photoWithLocation(width: 4032, height: 3024)
        let prepared = try XCTUnwrap(ClubPhotoEncoder.prepare(original))
        XCTAssertEqual(max(prepared.width, prepared.height), ClubPhotoEncoder.fullSide)
        XCTAssertLessThanOrEqual(prepared.full.count, ClubPhotoEncoder.maximumBytes)
        XCTAssertLessThan(prepared.thumbnail.count, prepared.full.count)
        XCTAssertEqual(prepared.hash.count, 64)
        for file in [prepared.full, prepared.thumbnail] {
            let source = try XCTUnwrap(CGImageSourceCreateWithData(file as CFData, nil))
            XCTAssertEqual(CGImageSourceGetType(source) as String?, UTType.heic.identifier)
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
            XCTAssertNil(properties[kCGImagePropertyGPSDictionary], "location must never leave the iPhone")
        }
        let thumb = try XCTUnwrap(CGImageSourceCreateWithData(prepared.thumbnail as CFData, nil))
        let size = CGImageSourceCopyPropertiesAtIndex(thumb, 0, nil) as? [CFString: Any] ?? [:]
        XCTAssertEqual(max(size[kCGImagePropertyPixelWidth] as? Int ?? 0, size[kCGImagePropertyPixelHeight] as? Int ?? 0),
                       ClubPhotoEncoder.thumbnailSide)
    }

    func testPostPhotosDecodeAndBadKeysAreSkipped() throws {
        let json = #"{"id":"\#(UUID().uuidString)","author":null,"text":"","sets":[],"created_at":"2026-10-10T08:00:00+00:00","respect_count":0,"respected":false,"photos":["\#(photoKey)","nope"]}"#
        let post = try ClubDate.decoder().decode(ClubPost.self, from: Data(json.utf8))
        XCTAssertEqual(post.photos.map(\.value), [photoKey])
        let older = #"{"id":"\#(UUID().uuidString)","author":null,"text":"Legs","sets":[],"created_at":"2026-10-10T08:00:00+00:00","respect_count":0,"respected":false}"#
        XCTAssertEqual(try ClubDate.decoder().decode(ClubPost.self, from: Data(older.utf8)).photos, [])
    }

    func testPhotoMessageDecodes() throws {
        let person = #"{"account_id":"\#(UUID().uuidString)","handle":"maya","display_name":"Maya","member_no":2,"joined_at":null,"trained_this_week":false,"i_follow":true,"follows_me":true}"#
        let json = #"{"id":"\#(UUID().uuidString)","author":\#(person),"mine":false,"kind":"photo","body":"","payload":{"photo":"\#(photoKey)","w":1600,"h":1200},"created_at":"2026-10-10T08:00:00+00:00","answers":null}"#
        let message = try ClubDate.decoder().decode(ClubMessage.self, from: Data(json.utf8))
        XCTAssertEqual(message.kind, .photo)
        XCTAssertEqual(message.payload.photo?.value, photoKey)
        XCTAssertEqual(message.payload.w, 1600)
    }

    func testPublishWithPhotosAttachesThemAfterThePost() async {
        let service = RecordingClubService()
        let club = store(service)
        let key = try! XCTUnwrap(ClubPhotoKey(photoKey))
        let posted = await club.publish(id: UUID(), text: "Legs", sets: [], photos: [key])
        XCTAssertTrue(posted)
        XCTAssertEqual(service.calls.map(\.action).prefix(2), ["publish", "attach"])
        XCTAssertEqual(service.calls.first { $0.action == "attach" }?.endpoint, .photo)
        XCTAssertEqual(service.calls.first { $0.action == "attach" }?.payload["photos"], .strings([photoKey]))
    }

    // MARK: Fixtures

    private func token(sub: String) -> String {
        let claims = try! JSONSerialization.data(withJSONObject: ["sub": sub, "role": "authenticated"])
        let body = claims.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return "eyJhbGciOiJIUzI1NiJ9." + body + ".signature"
    }

    /// A detailed JPEG with GPS, like a phone photo.
    private func photoWithLocation(width: Int, height: Int) throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        for row in stride(from: 0, to: height, by: 24) {
            for column in stride(from: 0, to: width, by: 24) {
                context.setFillColor(red: CGFloat(column % 255) / 255, green: CGFloat(row % 199) / 199,
                                     blue: CGFloat((row + column) % 97) / 97, alpha: 1)
                context.fill(CGRect(x: column, y: row, width: 24, height: 24))
            }
        }
        let image = try XCTUnwrap(context.makeImage())
        let output = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [
            kCGImageDestinationLossyCompressionQuality: 0.95,
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 42.69, kCGImagePropertyGPSLatitudeRef: "N",
                                            kCGImagePropertyGPSLongitude: 23.32, kCGImagePropertyGPSLongitudeRef: "E"],
        ] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let source = try XCTUnwrap(CGImageSourceCreateWithData(output as CFData, nil))
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        XCTAssertNotNil(properties[kCGImagePropertyGPSDictionary], "fixture must carry a location")
        return output as Data
    }

    private func store(_ service: RecordingClubService) -> ClubStore {
        let id = UUID()
        let session = ZeroOneAccountSession(accessToken: token(sub: userID), refreshToken: "refresh",
            expiresAt: Date().addingTimeInterval(3_600), identity: .init(id: id, authenticationID: id, email: nil))
        let club = ClubStore(service: service, sessions: { session })
        club.accountChanged(to: id)
        return club
    }
}

private final class RecordingClubService: ClubServicing, @unchecked Sendable {
    struct Call { let endpoint: ClubEndpoint; let action: String; let payload: [String: ClubValue] }
    var calls: [Call] = []

    func execute(_ endpoint: ClubEndpoint, _ action: String, payload: [String: ClubValue],
                 session: ZeroOneAccountSession) async throws -> Data {
        calls.append(Call(endpoint: endpoint, action: action, payload: payload))
        switch action {
        case "read_me": return Data(#"{"member":null,"is_admin":false}"#.utf8)
        default: return Data(#"{"accepted":true}"#.utf8)
        }
    }
}
