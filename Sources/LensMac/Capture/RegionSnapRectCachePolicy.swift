import Foundation

/// When a cached window layout may still drive region snapping, and when it is
/// worth enumerating windows again.
///
/// Enumerating windows competes with overlay rendering on the main thread and
/// has been measured at several hundred milliseconds from cold, which is long
/// enough that an early drag gets no snapping at all. Keeping a warm entry
/// removes that path entirely, so the only real question is how stale an entry
/// may be before it describes windows that have since moved.
struct RegionSnapRectCachePolicy: Equatable, Sendable {
    /// How long a cached layout may still be shown to the user. This is only
    /// safe because the cache is refreshed on every application switch and
    /// after every capture, so entries are normally seconds old in practice.
    let usableLifetime: TimeInterval

    /// A floor on how often windows are enumerated. Refreshing faster than this
    /// cannot change the answer meaningfully and only burns lookups while the
    /// user cycles through applications.
    let minimumRefreshInterval: TimeInterval

    static let standard = Self(usableLifetime: 30, minimumRefreshInterval: 1)

    init(usableLifetime: TimeInterval, minimumRefreshInterval: TimeInterval) {
        self.usableLifetime = max(usableLifetime.isFinite ? usableLifetime : 0, 0)
        self.minimumRefreshInterval = max(
            minimumRefreshInterval.isFinite ? minimumRefreshInterval : 0,
            0
        )
    }

    /// Whether a layout cached at `cachedAt` may still seed a new overlay.
    /// A never-populated cache reads as `-.infinity` and is never usable.
    func isUsable(cachedAt: TimeInterval, now: TimeInterval) -> Bool {
        let age = now - cachedAt
        guard age.isFinite, age >= 0 else { return false }
        return age <= usableLifetime
    }

    /// Whether a background refresh should start. A refresh already in flight
    /// wins, so a burst of application switches cannot queue several
    /// enumerations against each other.
    func shouldRefresh(
        cachedAt: TimeInterval,
        now: TimeInterval,
        isRefreshing: Bool
    ) -> Bool {
        guard !isRefreshing else { return false }
        let age = now - cachedAt
        guard age.isFinite else { return true }
        return age >= minimumRefreshInterval
    }
}
