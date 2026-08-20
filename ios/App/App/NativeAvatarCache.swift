import Foundation
import SwiftUI
import UIKit

@MainActor
final class NativeAvatarLoader: ObservableObject {
    @Published private(set) var image: UIImage?

    private static let refreshInterval: TimeInterval = 6 * 60 * 60
    private static let memoryCache = NSCache<NSURL, UIImage>()
    private static let responseCache = URLCache(
        memoryCapacity: 20 * 1_024 * 1_024,
        diskCapacity: 100 * 1_024 * 1_024,
        diskPath: "SafeBrowserNativeAvatars"
    )
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.urlCache = NativeAvatarLoader.responseCache
        configuration.requestCachePolicy = .useProtocolCachePolicy
        return URLSession(configuration: configuration)
    }()
    private static var downloads: [URL: Task<UIImage?, Never>] = [:]

    private var currentURL: URL?
    private var generation = 0
    private var refreshTask: Task<Void, Never>?

    func load(_ url: URL?) {
        guard currentURL != url || image == nil else {
            if let url { refreshIfStale(url) }
            return
        }
        currentURL = url
        generation += 1
        let expectedGeneration = generation
        refreshTask?.cancel()
        image = nil
        guard let url else { return }

        let request = URLRequest(url: url)
        if let cached = Self.memoryCache.object(forKey: url as NSURL) {
            image = cached
        } else if
            let response = Self.responseCache.cachedResponse(for: request),
            let cached = UIImage(data: response.data)
        {
            Self.memoryCache.setObject(cached, forKey: url as NSURL)
            image = cached
        }

        if Self.shouldRefresh(url) {
            Task {
                let refreshed = await Self.download(url)
                guard expectedGeneration == generation, currentURL == url else { return }
                if let refreshed { image = refreshed }
                scheduleRefresh(url, generation: expectedGeneration)
            }
        } else {
            scheduleRefresh(url, generation: expectedGeneration)
        }
    }

    private func refreshIfStale(_ url: URL) {
        guard Self.shouldRefresh(url) else { return }
        let expectedGeneration = generation
        Task {
            let refreshed = await Self.download(url)
            guard expectedGeneration == generation, currentURL == url else { return }
            if let refreshed { image = refreshed }
            scheduleRefresh(url, generation: expectedGeneration)
        }
    }

    private func scheduleRefresh(_ url: URL, generation expectedGeneration: Int) {
        refreshTask?.cancel()
        let lastRefresh = UserDefaults.standard.double(forKey: Self.refreshKey(url))
        let age = Date().timeIntervalSince1970 - lastRefresh
        let delay = max(60, Self.refreshInterval - age)
        refreshTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard
                !Task.isCancelled,
                let self,
                self.generation == expectedGeneration,
                self.currentURL == url
            else { return }
            if let refreshed = await Self.download(url) { self.image = refreshed }
            self.scheduleRefresh(url, generation: expectedGeneration)
        }
    }

    private static func shouldRefresh(_ url: URL) -> Bool {
        Date().timeIntervalSince1970 - UserDefaults.standard.double(forKey: refreshKey(url)) >= refreshInterval
    }

    private static func download(_ url: URL) async -> UIImage? {
        if let existing = downloads[url] { return await existing.value }
        let task = Task<UIImage?, Never> {
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
            request.setValue("image/*", forHTTPHeaderField: "Accept")
            do {
                let (data, response) = try await NativeAvatarLoader.session.data(for: request)
                guard
                    let http = response as? HTTPURLResponse,
                    (200..<300).contains(http.statusCode),
                    let image = UIImage(data: data)
                else { return nil }
                let cacheRequest = URLRequest(url: url)
                NativeAvatarLoader.responseCache.storeCachedResponse(
                    CachedURLResponse(response: response, data: data, storagePolicy: .allowed),
                    for: cacheRequest
                )
                NativeAvatarLoader.memoryCache.setObject(image, forKey: url as NSURL)
                UserDefaults.standard.set(
                    Date().timeIntervalSince1970,
                    forKey: NativeAvatarLoader.refreshKey(url)
                )
                return image
            } catch {
                return nil
            }
        }
        downloads[url] = task
        let result = await task.value
        downloads[url] = nil
        return result
    }

    private static func refreshKey(_ url: URL) -> String {
        let encoded = Data(url.absoluteString.utf8).base64EncodedString()
        return "SafeBrowser.NativeAvatar.refresh.\(encoded)"
    }
}
