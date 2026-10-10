import Foundation

/// Fetches LRC lyrics from NetEase Cloud Music's public (unauthenticated)
/// search/lyric endpoints.
///
/// Note on Apple Music: Apple's own time-synced lyrics are NOT accessible to
/// third-party apps — AppleScript's `lyrics of current track` only returns
/// manually-embedded lyrics (empty for streaming tracks), and the synced
/// lyrics panel is private Music.app UI state. So a third-party source like
/// this is the only option for synced lyrics.
struct RemoteLyricsSource {
    private let session: URLSession = .shared

    func fetchLyrics(title: String, artist: String) async -> [LyricLine]? {
        let candidates = await searchSongs(title: title, artist: artist)
        guard !candidates.isEmpty else { return nil }

        // NetEase returns empty lyrics for some licensed tracks (e.g. the
        // official "我记得"), while a live/cover version of the same song still
        // has them. So try candidates in order — artist matches first — and use
        // the first one that actually returns a non-empty LRC.
        let target = artist.lowercased()
        let ordered = candidates.sorted { a, b in
            let am = a.artist.lowercased().contains(target) || target.contains(a.artist.lowercased())
            let bm = b.artist.lowercased().contains(target) || target.contains(b.artist.lowercased())
            return am && !bm
        }
        for song in ordered.prefix(6) {
            if let lines = await fetchLRC(songID: song.id) { return lines }
        }
        return nil
    }

    /// Resolves a cover image for a track.
    ///
    /// Needed because the system "Now Playing" payload carries no image data on
    /// current macOS, so players like NetEase Cloud Music would otherwise show
    /// a blank square.
    func fetchArtworkURL(title: String, artist: String) async -> URL? {
        let candidates = await searchSongs(title: title, artist: artist)
        guard !candidates.isEmpty else { return nil }
        let target = artist.lowercased()
        let ordered = candidates.sorted { a, b in
            let am = !target.isEmpty && (a.artist.lowercased().contains(target) || target.contains(a.artist.lowercased()))
            let bm = !target.isEmpty && (b.artist.lowercased().contains(target) || target.contains(b.artist.lowercased()))
            return am && !bm
        }
        for song in ordered.prefix(4) {
            if let url = await fetchCoverURL(songID: song.id) { return url }
        }
        return nil
    }

    private func fetchCoverURL(songID: Int) async -> URL? {
        // Note the trailing slash and the explicit `id=` — without them this
        // endpoint answers with an empty body (verified on 2026-10).
        guard let url = URL(string: "https://music.163.com/api/song/detail/?id=\(songID)&ids=%5B\(songID)%5D") else {
            return nil
        }
        do {
            let (data, _) = try await session.data(for: makeRequest(url))
            let result = try JSONDecoder().decode(DetailResponse.self, from: data)
            guard let album = result.songs?.first?.album else { return nil }
            let pic = album.picUrl ?? album.blurPicUrl ?? ""
            guard !pic.isEmpty else { return nil }
            guard var components = URLComponents(string: pic) else { return nil }
            // NetEase's API commonly returns plain HTTP artwork URLs. App
            // Transport Security blocks those by default, so use the same CDN
            // URL over HTTPS before handing it to URLSession.
            if components.scheme?.lowercased() == "http" { components.scheme = "https" }
            return components.url
        } catch {
            return nil
        }
    }

    /// NetEase blocks requests without browser-like headers, which is why
    /// popular songs were coming back empty.
    private func makeRequest(_ url: URL) -> URLRequest {
        var req = URLRequest(url: url)
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36",
                     forHTTPHeaderField: "User-Agent")
        req.setValue("https://music.163.com/", forHTTPHeaderField: "Referer")
        req.setValue("https://music.163.com", forHTTPHeaderField: "Origin")
        req.setValue("appver=2.0.2;", forHTTPHeaderField: "Cookie")
        return req
    }

    private func searchSongs(title: String, artist: String) async -> [Song] {
        let keywords = "\(title) \(artist)".trimmingCharacters(in: .whitespaces)
        guard let encoded = keywords.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://music.163.com/api/search/get/web?type=1&limit=8&offset=0&s=\(encoded)") else {
            return []
        }
        do {
            let (data, _) = try await session.data(for: makeRequest(url))
            let result = try JSONDecoder().decode(SearchResponse.self, from: data)
            return result.result?.songs ?? []
        } catch {
            return []
        }
    }

    private func fetchLRC(songID: Int) async -> [LyricLine]? {
        guard let url = URL(string: "https://music.163.com/api/song/lyric?id=\(songID)&lv=1&kv=1&tv=-1") else {
            return nil
        }
        do {
            let (data, _) = try await session.data(for: makeRequest(url))
            let result = try JSONDecoder().decode(LyricResponse.self, from: data)
            guard let lrc = result.lrc?.lyric, !lrc.isEmpty else { return nil }
            let parsed = LRCParser.parse(lrc)
            return parsed.isEmpty ? nil : parsed
        } catch {
            return nil
        }
    }

    private struct SearchResponse: Decodable {
        struct Result: Decodable { let songs: [Song]? }
        let result: Result?
    }

    private struct Song: Decodable {
        let id: Int
        let artists: [Artist]?
        struct Artist: Decodable { let name: String }
        var artist: String { artists?.first?.name ?? "" }
    }

    private struct LyricResponse: Decodable {
        struct LRC: Decodable { let lyric: String? }
        let lrc: LRC?
    }

    private struct DetailResponse: Decodable {
        struct Song: Decodable {
            struct Album: Decodable {
                let picUrl: String?
                let blurPicUrl: String?
            }
            let album: Album?
        }
        let songs: [Song]?
    }
}
