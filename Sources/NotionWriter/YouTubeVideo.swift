import Foundation
import NotionWriterCore

struct YouTubeVideo: Sendable {
    let sourceURL: URL
    let id: String

    init(url: URL) throws {
        let invalid = WriterError.validation("YouTubeの動画URLを入力してください。")
        guard url.absoluteString.utf16.count <= 2000,
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = parts.scheme?.lowercased(), ["http", "https"].contains(scheme),
              parts.user == nil, parts.password == nil, parts.port == nil else { throw invalid }

        let path = parts.path.split(separator: "/")
        let videoID: String?
        switch parts.host?.lowercased() {
        case "youtu.be" where path.count == 1:
            videoID = path.first.map(String.init)
        case "youtube.com", "www.youtube.com", "m.youtube.com", "music.youtube.com":
            if parts.path == "/watch" {
                videoID = parts.queryItems?.first(where: { $0.name == "v" })?.value
            } else if path.count == 2, let kind = path.first, ["shorts", "live", "embed"].contains(kind) {
                videoID = String(path[1])
            } else {
                videoID = nil
            }
        default:
            videoID = nil
        }
        guard let videoID, videoID.utf8.count == 11,
              videoID.range(of: #"^[A-Za-z0-9_-]{11}$"#, options: .regularExpression) != nil else { throw invalid }
        self.sourceURL = url
        self.id = videoID
    }

    var metadataURL: URL {
        var endpoint = URLComponents()
        endpoint.scheme = "https"
        endpoint.host = "www.youtube.com"
        endpoint.path = "/oembed"
        endpoint.queryItems = [
            URLQueryItem(name: "url", value: "https://www.youtube.com/watch?v=\(id)"),
            URLQueryItem(name: "format", value: "json")
        ]
        return endpoint.url!
    }

    func loadTitle() async throws -> String {
        struct Metadata: Decodable {
            let title: String
        }
        do {
            let (data, responseURL) = try await WebResource.read(metadataURL, limit: 128 * 1024)
            if responseURL.host == "www.youtube.com", responseURL.path == "/oembed",
               let title = try JSONDecoder().decode(Metadata.self, from: data).title.webText {
                return title
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
        }
        throw WriterError.validation("YouTubeから動画のタイトルを取得できませんでした。URLと動画の公開状態を確認してください。")
    }
}
