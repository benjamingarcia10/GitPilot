import Foundation

/// Errors surfaced by the GitHub client.
enum GitHubClientError: Error, LocalizedError {
    case authMissing
    case ghCLIFailed(String)
    case requestFailed(Int, String)
    case decodingFailed(String)

    var errorDescription: String? {
        switch self {
        case .authMissing:
            return "No GitHub auth token. Run `gh auth login`."
        case .ghCLIFailed(let msg):
            return "gh CLI failed: \(msg)"
        case .requestFailed(let code, let body):
            return "GitHub API error \(code): \(body)"
        case .decodingFailed(let msg):
            return "Failed to decode GitHub response: \(msg)"
        }
    }

    /// True when the right user response is "run `gh auth login`", not "report a bug".
    var isAuthError: Bool {
        switch self {
        case .authMissing:
            return true
        case .requestFailed(let code, _):
            return code == 401
        case .ghCLIFailed(let msg):
            let m = msg.lowercased()
            return m.contains("not logged") || m.contains("authentication") || m.contains("auth status")
        case .decodingFailed:
            return false
        }
    }
}

/// Talks to GitHub. Auth via the `gh` CLI (it manages the token store).
/// PRs are fetched with GraphQL so we get mergeStateStatus in one round trip.
/// Login + token are cached for the lifetime of the process; cleared on auth failure.
actor GitHubClient {
    private let session: URLSession
    private var cachedToken: String?
    private var cachedLogin: String?

    init(session: URLSession? = nil) {
        // URLSession.shared defaults to 6 connections per host, which serializes
        // our parallel enrichment fan-out into batches of 6. With 25 PRs that's
        // ~4 sequential batches. Bump it so true parallelism is possible.
        self.session = session ?? {
            let config = URLSessionConfiguration.default
            config.httpMaximumConnectionsPerHost = 32
            config.timeoutIntervalForRequest = 30
            return URLSession(configuration: config)
        }()
    }

    // MARK: - Auth

    /// Reads the user's gh CLI token, caching it. Reset on any 401.
    private func token() throws -> String {
        if let cached = cachedToken { return cached }
        let value = try runGH(args: ["auth", "token"])
        guard !value.isEmpty else { throw GitHubClientError.authMissing }
        cachedToken = value
        return value
    }

    /// Returns the authenticated GitHub username. Cached for the process lifetime —
    /// login does not change between launches without a re-auth.
    func currentLogin() throws -> String {
        if let cached = cachedLogin { return cached }
        let value = try runGH(args: ["api", "user", "--jq", ".login"])
        cachedLogin = value
        return value
    }

    /// Fetches every team slug the viewer belongs to across all their orgs.
    /// Used to filter "Reviewing" tab pills so we only show team requests that
    /// actually mean the user is being asked — not every team on the PR.
    func fetchViewerTeamSlugs() async throws -> Set<String> {
        let login = try currentLogin()
        let query = """
        query($login: String!) {
          viewer {
            organizations(first: 50) {
              nodes {
                teams(first: 100, userLogins: [$login]) {
                  nodes { slug }
                }
              }
            }
          }
        }
        """
        let payload: [String: Any] = ["query": query, "variables": ["login": login]]
        let data = try await graphQL(payload: payload)

        struct Resp: Decodable {
            struct Data: Decodable {
                struct Viewer: Decodable {
                    struct Orgs: Decodable {
                        let nodes: [Org]
                        struct Org: Decodable {
                            let teams: Teams
                            struct Teams: Decodable {
                                let nodes: [Team]
                                struct Team: Decodable { let slug: String }
                            }
                        }
                    }
                    let organizations: Orgs
                }
                let viewer: Viewer
            }
            let data: Data
        }
        let decoded = try JSONDecoder().decode(Resp.self, from: data)
        var slugs: Set<String> = []
        for org in decoded.data.viewer.organizations.nodes {
            for team in org.teams.nodes {
                slugs.insert(team.slug)
            }
        }
        return slugs
    }

    /// Cleared on 401 so the next call re-fetches.
    private func invalidateAuth() {
        cachedToken = nil
        cachedLogin = nil
    }

    private func runGH(args: [String]) throws -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = ["gh"] + args
        let out = Pipe()
        let err = Pipe()
        proc.standardOutput = out
        proc.standardError = err
        try proc.run()
        proc.waitUntilExit()

        guard proc.terminationStatus == 0 else {
            let msg = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw GitHubClientError.ghCLIFailed(msg)
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    // MARK: - PR fetch (two-phase)

    /// Sanity cap on total PRs fetched per refresh, across all pages. Protects
    /// against a runaway loop if GitHub's pagination misbehaves and against
    /// degenerate accounts (bots, machine users) where fetching everything
    /// would burn the rate limit each refresh. 1000 is generous for humans.
    private static let pageFetchCap = 1000

    /// Phase 1: lightweight list via `viewer.pullRequests` — a direct association lookup,
    /// faster than going through the search index. Excludes mergeStateStatus/mergeable/
    /// reviewDecision because GitHub computes those lazily and they can be slow.
    /// Paginates with first:100 + endCursor until hasNextPage is false (or we hit
    /// the safety cap). Replaces the previous hard-coded 25-PR limit so users
    /// with many open PRs don't silently lose the tail of their list.
    func fetchMyOpenPRs() async throws -> [PullRequest] {
        let query = """
        query($cursor: String) {
          viewer {
            pullRequests(states: OPEN, first: 100, after: $cursor, orderBy: {field: UPDATED_AT, direction: DESC}) {
              pageInfo { hasNextPage endCursor }
              nodes {
                id
                number
                title
                url
                headRefName
                baseRefName
                isDraft
                additions
                deletions
                changedFiles
                repository {
                  name
                  owner { login }
                  mergeCommitAllowed
                  squashMergeAllowed
                  rebaseMergeAllowed
                }
              }
            }
          }
        }
        """
        struct GQLResponse: Decodable {
            struct Data: Decodable {
                struct Viewer: Decodable {
                    struct PRConnection: Decodable {
                        let pageInfo: PageInfo
                        let nodes: [PRNode]
                        struct PageInfo: Decodable {
                            let hasNextPage: Bool
                            let endCursor: String?
                        }
                    }
                    let pullRequests: PRConnection
                }
                let viewer: Viewer
            }
            struct PRNode: Decodable {
                let id: String
                let number: Int
                let title: String
                let url: URL
                let headRefName: String
                let baseRefName: String
                let isDraft: Bool
                let additions: Int
                let deletions: Int
                let changedFiles: Int
                let repository: Repo
                struct Repo: Decodable {
                    let name: String
                    let owner: Owner
                    let mergeCommitAllowed: Bool?
                    let squashMergeAllowed: Bool?
                    let rebaseMergeAllowed: Bool?
                    struct Owner: Decodable { let login: String }
                }
            }
            let data: Data
        }

        var all: [PullRequest] = []
        var cursor: String? = nil
        let t0 = Date()
        while all.count < Self.pageFetchCap {
            let payload: [String: Any] = [
                "query": query,
                "variables": ["cursor": cursor as Any],
            ]
            let data = try await graphQL(payload: payload)
            let decoded: GQLResponse
            do { decoded = try JSONDecoder().decode(GQLResponse.self, from: data) }
            catch { throw GitHubClientError.decodingFailed(String(describing: error)) }
            let conn = decoded.data.viewer.pullRequests
            for node in conn.nodes {
                var allowed: Set<String> = []
                if node.repository.mergeCommitAllowed == true { allowed.insert("MERGE") }
                if node.repository.squashMergeAllowed == true { allowed.insert("SQUASH") }
                if node.repository.rebaseMergeAllowed == true { allowed.insert("REBASE") }
                all.append(PullRequest(
                    nodeId: node.id,
                    number: node.number,
                    title: node.title,
                    url: node.url,
                    headRefName: node.headRefName,
                    baseRefName: node.baseRefName,
                    isDraft: node.isDraft,
                    repoOwner: node.repository.owner.login,
                    repoName: node.repository.name,
                    additions: node.additions,
                    deletions: node.deletions,
                    changedFiles: node.changedFiles,
                    mergeable: nil,
                    mergeStateStatus: nil,
                    reviewDecision: nil,
                    allowedMergeMethods: allowed
                ))
            }
            if !conn.pageInfo.hasNextPage { break }
            cursor = conn.pageInfo.endCursor
            if cursor == nil { break }  // defensive: hasNextPage true but no cursor
        }
        if all.count >= Self.pageFetchCap {
            Log.warn("fetchMyOpenPRs hit cap of \(Self.pageFetchCap) — older PRs are not loaded")
        }
        Log.debug("phase1 fetchMyOpenPRs returned \(all.count) PRs", elapsed: t0)
        return all
    }

    /// Fetches PRs where the viewer is requested as a reviewer — directly OR via
    /// a team they belong to. GitHub's `review-requested:@me` filter covers both.
    /// We also fetch each PR's reviewRequests so we can tell *how* (direct vs team)
    /// and surface that on the row.
    /// `viewerTeamSlugs` filters team-based reviewer pills to teams the user is
    /// actually a member of. Without this, large PRs with many team reviewers
    /// would render irrelevant pills.
    func fetchReviewingPRs(viewerTeamSlugs: Set<String>) async throws -> [PullRequest] {
        let viewerLogin = try currentLogin()
        let query = """
        query($cursor: String) {
          search(query: "is:pr is:open review-requested:@me", type: ISSUE, first: 100, after: $cursor) {
            pageInfo { hasNextPage endCursor }
            nodes {
              ... on PullRequest {
                id number title url
                headRefName baseRefName isDraft
                additions deletions changedFiles
                repository {
                  name
                  owner { login }
                  mergeCommitAllowed
                  squashMergeAllowed
                  rebaseMergeAllowed
                }
                reviewRequests(first: 25) {
                  nodes {
                    requestedReviewer {
                      __typename
                      ... on User { login }
                      ... on Team { slug name }
                    }
                  }
                }
              }
            }
          }
        }
        """

        struct GQLResponse: Decodable {
            struct Data: Decodable {
                struct Search: Decodable {
                    let pageInfo: PageInfo
                    let nodes: [PRNode]
                    struct PageInfo: Decodable {
                        let hasNextPage: Bool
                        let endCursor: String?
                    }
                }
                let search: Search
            }
            struct PRNode: Decodable {
                let id: String
                let number: Int
                let title: String
                let url: URL
                let headRefName: String
                let baseRefName: String
                let isDraft: Bool
                let additions: Int
                let deletions: Int
                let changedFiles: Int
                let repository: Repo
                struct Repo: Decodable {
                    let name: String
                    let owner: Owner
                    let mergeCommitAllowed: Bool?
                    let squashMergeAllowed: Bool?
                    let rebaseMergeAllowed: Bool?
                    struct Owner: Decodable { let login: String }
                }
                let reviewRequests: ReviewRequests?
                struct ReviewRequests: Decodable {
                    let nodes: [ReviewRequestNode]
                    struct ReviewRequestNode: Decodable {
                        let requestedReviewer: Reviewer?
                        struct Reviewer: Decodable {
                            let __typename: String
                            let login: String?
                            let slug: String?
                            let name: String?
                        }
                    }
                }
            }
            let data: Data
        }

        var all: [PullRequest] = []
        var cursor: String? = nil
        let t0 = Date()
        while all.count < Self.pageFetchCap {
            let payload: [String: Any] = [
                "query": query,
                "variables": ["cursor": cursor as Any],
            ]
            let data = try await graphQL(payload: payload)
            let decoded: GQLResponse
            do { decoded = try JSONDecoder().decode(GQLResponse.self, from: data) }
            catch { throw GitHubClientError.decodingFailed(String(describing: error)) }
            let conn = decoded.data.search
            for node in conn.nodes {
                var allowed: Set<String> = []
                if node.repository.mergeCommitAllowed == true { allowed.insert("MERGE") }
                if node.repository.squashMergeAllowed == true { allowed.insert("SQUASH") }
                if node.repository.rebaseMergeAllowed == true { allowed.insert("REBASE") }
                // Determine why the viewer is on this PR's reviewer list.
                var sources: [ReviewerSource] = []
                for req in node.reviewRequests?.nodes ?? [] {
                    guard let r = req.requestedReviewer else { continue }
                    if r.__typename == "User", r.login == viewerLogin {
                        sources.append(ReviewerSource(kind: .direct, teamSlug: nil))
                    } else if r.__typename == "Team", let slug = r.slug,
                              viewerTeamSlugs.contains(slug) {
                        // Only show team requests where the viewer is actually a member.
                        // PRs may have other team reviewers we want to ignore.
                        sources.append(ReviewerSource(kind: .team, teamSlug: slug))
                    }
                }
                all.append(PullRequest(
                    nodeId: node.id,
                    number: node.number,
                    title: node.title,
                    url: node.url,
                    headRefName: node.headRefName,
                    baseRefName: node.baseRefName,
                    isDraft: node.isDraft,
                    repoOwner: node.repository.owner.login,
                    repoName: node.repository.name,
                    additions: node.additions,
                    deletions: node.deletions,
                    changedFiles: node.changedFiles,
                    reviewerSources: sources,
                    mergeable: nil,
                    mergeStateStatus: nil,
                    reviewDecision: nil,
                    allowedMergeMethods: allowed
                ))
            }
            if !conn.pageInfo.hasNextPage { break }
            cursor = conn.pageInfo.endCursor
            if cursor == nil { break }
        }
        if all.count >= Self.pageFetchCap {
            Log.warn("fetchReviewingPRs hit cap of \(Self.pageFetchCap) — older PRs are not loaded")
        }
        Log.debug("fetchReviewingPRs returned \(all.count) PRs", elapsed: t0)
        return all
    }

    /// Phase 2: batched enrichment via `nodes(ids:)`. Replaces the previous per-PR
    /// fan-out which was the dominant source of API call volume — for N PRs, the
    /// old design fired N concurrent GraphQL requests every refresh tick (plus up
    /// to 3× retries each on UNKNOWN), tripping GitHub's secondary rate limits
    /// ("avoid concurrent requests", concurrent-request cap, points-per-minute).
    /// One batched query collapses N enrichments into a single round trip.
    ///
    /// Returns a map keyed by nodeId. Missing entries indicate a PR that GitHub
    /// returned null for (e.g. became private, was deleted) — caller treats those
    /// as enrichment failures.
    ///
    /// Retries entries whose mergeStateStatus came back UNKNOWN (GitHub computes
    /// it lazily) up to 3 more times with 0.5/1/2s backoff, just like the old
    /// per-PR retry — the retry is now also batched, so it stays cheap.
    ///
    /// Chunked at 25 PRs per request to keep response size bounded; chunks run
    /// sequentially (not concurrently) to follow GitHub's "avoid concurrent
    /// requests" guidance.
    func enrichPRs(nodeIds: [String]) async throws -> [String: PREnrichment] {
        guard !nodeIds.isEmpty else { return [:] }
        var results: [String: PREnrichment] = [:]
        let chunkSize = 25
        var i = 0
        while i < nodeIds.count {
            let chunk = Array(nodeIds[i..<min(i + chunkSize, nodeIds.count)])
            let chunkResults = try await enrichPRsBatchWithRetry(nodeIds: chunk)
            for (k, v) in chunkResults { results[k] = v }
            i += chunkSize
        }
        return results
    }

    private func enrichPRsBatchWithRetry(nodeIds: [String]) async throws -> [String: PREnrichment] {
        var pending = nodeIds
        var results: [String: PREnrichment] = [:]
        var attempt = 0
        while !pending.isEmpty {
            attempt += 1
            let batch = try await enrichPRsOnce(nodeIds: pending)
            var stillUnknown: [String] = []
            for id in pending {
                guard let e = batch[id] else { continue }  // null node — drop
                if e.mergeStateStatus == .unknown && attempt < 4 {
                    stillUnknown.append(id)
                } else {
                    results[id] = e
                }
            }
            if stillUnknown.isEmpty { break }
            // Final attempt: surface whatever we got, even if still UNKNOWN —
            // matches old per-PR behavior (give up after 4 attempts).
            if attempt >= 4 {
                for id in stillUnknown {
                    if let e = batch[id] { results[id] = e }
                }
                break
            }
            let delayMs: UInt64 = [500, 1_000, 2_000][min(attempt - 1, 2)]
            Log.debug("enrichPRs UNKNOWN: \(stillUnknown.count) PRs, retry in \(delayMs)ms (attempt \(attempt))")
            try await Task.sleep(nanoseconds: delayMs * 1_000_000)
            pending = stillUnknown
        }
        return results
    }

    private func enrichPRsOnce(nodeIds: [String]) async throws -> [String: PREnrichment] {
        let query = """
        query($ids: [ID!]!) {
          nodes(ids: $ids) {
            __typename
            ... on PullRequest {
              id
              mergeable
              mergeStateStatus
              reviewDecision
              commits(last: 1) {
                nodes {
                  commit {
                    statusCheckRollup {
                      state
                      contexts(first: 50) {
                        nodes {
                          __typename
                          ... on CheckRun {
                            id
                            name
                            conclusion
                            status
                            detailsUrl
                            permalink
                          }
                          ... on StatusContext {
                            id
                            context
                            state
                            targetUrl
                          }
                        }
                      }
                    }
                  }
                }
              }
            }
          }
        }
        """
        let payload: [String: Any] = ["query": query, "variables": ["ids": nodeIds]]
        let t0 = Date()
        let data = try await graphQL(payload: payload)
        Log.debug("enrichPRs(\(nodeIds.count))", elapsed: t0)

        struct GQLResponse: Decodable {
            struct Data: Decodable { let nodes: [Node?] }
            struct Node: Decodable {
                let id: String
                let mergeable: String?
                let mergeStateStatus: String?
                let reviewDecision: String?
                let commits: Commits?
                struct Commits: Decodable {
                    let nodes: [CommitNode]
                    struct CommitNode: Decodable {
                        let commit: Commit
                        struct Commit: Decodable {
                            let statusCheckRollup: Rollup?
                            struct Rollup: Decodable {
                                let state: String?
                                let contexts: Contexts?
                                struct Contexts: Decodable {
                                    let nodes: [ContextNode]
                                }
                                /// Discriminated union: GraphQL response uses __typename
                                /// to distinguish CheckRun vs StatusContext.
                                struct ContextNode: Decodable {
                                    let __typename: String
                                    let id: String
                                    // CheckRun fields
                                    let name: String?
                                    let conclusion: String?
                                    let status: String?
                                    let detailsUrl: URL?
                                    let permalink: URL?
                                    // StatusContext fields
                                    let context: String?
                                    let state: String?
                                    let targetUrl: URL?
                                }
                            }
                        }
                    }
                }
            }
            let data: Data
        }

        let decoded: GQLResponse
        do { decoded = try JSONDecoder().decode(GQLResponse.self, from: data) }
        catch { throw GitHubClientError.decodingFailed(String(describing: error)) }

        var out: [String: PREnrichment] = [:]
        for node in decoded.data.nodes {
            guard let node else { continue }  // GitHub returns null for unknown ids
            let rollup = node.commits?.nodes.first?.commit.statusCheckRollup
            let rollupRaw = rollup?.state ?? "UNKNOWN"
            let checks: [PRCheck] = (rollup?.contexts?.nodes ?? []).map { ctx in
                if ctx.__typename == "CheckRun" {
                    // CheckRun's "state" comes from conclusion (when finished) or status (when in flight).
                    let stateRaw = (ctx.conclusion ?? ctx.status ?? "UNKNOWN").uppercased()
                    return PRCheck(
                        id: ctx.id,
                        name: ctx.name ?? "(unnamed check)",
                        state: mapCheckRunState(stateRaw),
                        url: ctx.detailsUrl ?? ctx.permalink
                    )
                } else {
                    // StatusContext: classic commit status, "context" is the name.
                    return PRCheck(
                        id: ctx.id,
                        name: ctx.context ?? "(status)",
                        state: CheckRollupState(rawValue: ctx.state ?? "UNKNOWN") ?? .unknown,
                        url: ctx.targetUrl
                    )
                }
            }
            out[node.id] = PREnrichment(
                mergeable: node.mergeable ?? "UNKNOWN",
                mergeStateStatus: MergeStateStatus(rawValue: node.mergeStateStatus ?? "UNKNOWN") ?? .unknown,
                reviewDecision: node.reviewDecision,
                checkRollupState: CheckRollupState(rawValue: rollupRaw) ?? .unknown,
                checks: checks
            )
        }
        return out
    }

    /// Bridge CheckRun's flat enum (conclusion or status) into our common rollup state.
    private nonisolated func mapCheckRunState(_ raw: String) -> CheckRollupState {
        switch raw {
        case "SUCCESS", "NEUTRAL", "SKIPPED": return .success
        case "FAILURE", "TIMED_OUT", "CANCELLED", "STARTUP_FAILURE", "ACTION_REQUIRED": return .failure
        case "PENDING", "QUEUED", "IN_PROGRESS", "WAITING", "REQUESTED": return .pending
        case "ERROR": return .error
        case "STALE": return .expected
        default: return .unknown
        }
    }

    // MARK: - Update branch

    enum UpdateMethod: String {
        case rebase = "REBASE"
        case merge = "MERGE"
    }

    /// Methods accepted by `enablePullRequestAutoMerge`. The actual allowed set is
    /// gated by repo settings — the mutation will error if the repo doesn't allow
    /// the chosen method, and we surface that to the user.
    enum MergeMethod: String, Codable, CaseIterable {
        case merge = "MERGE"
        case squash = "SQUASH"
        case rebase = "REBASE"

        var label: String {
            switch self {
            case .merge:  return "Merge commit"
            case .squash: return "Squash"
            case .rebase: return "Rebase"
            }
        }
    }

    /// Calls the GraphQL `updatePullRequestBranch` mutation. Equivalent to clicking
    /// "Update with rebase" (or "Update branch") on the PR page.
    @discardableResult
    func updateBranch(prNodeId: String, method: UpdateMethod = .rebase) async throws -> Bool {
        let mutation = """
        mutation($id: ID!, $method: PullRequestBranchUpdateMethod!) {
          updatePullRequestBranch(input: { pullRequestId: $id, updateMethod: $method }) {
            pullRequest { mergeStateStatus }
          }
        }
        """
        let payload: [String: Any] = [
            "query": mutation,
            "variables": ["id": prNodeId, "method": method.rawValue],
        ]
        let data = try await graphQL(payload: payload)

        // GraphQL returns 200 with an `errors` array on failure; surface those.
        struct GQLEnvelope: Decodable {
            struct GQLError: Decodable { let message: String }
            let errors: [GQLError]?
        }
        if let envelope = try? JSONDecoder().decode(GQLEnvelope.self, from: data),
           let errors = envelope.errors, !errors.isEmpty {
            throw GitHubClientError.requestFailed(200, errors.map(\.message).joined(separator: "; "))
        }
        return true
    }

    // MARK: - Auto-merge

    /// Tells GitHub to merge the PR automatically once branch protection requirements
    /// are satisfied. Equivalent to clicking "Enable auto-merge" on the PR page.
    @discardableResult
    func enableAutoMerge(prNodeId: String, method: MergeMethod) async throws -> Bool {
        let mutation = """
        mutation($id: ID!, $method: PullRequestMergeMethod!) {
          enablePullRequestAutoMerge(input: { pullRequestId: $id, mergeMethod: $method }) {
            pullRequest { autoMergeRequest { enabledAt } }
          }
        }
        """
        let payload: [String: Any] = [
            "query": mutation,
            "variables": ["id": prNodeId, "method": method.rawValue],
        ]
        let data = try await graphQL(payload: payload)
        return try ensureNoGraphQLErrors(data)
    }

    /// Merges the PR immediately. Used by the client-side auto-merge fallback
    /// when GitHub-side auto-merge isn't allowed for the repo.
    @discardableResult
    func mergePullRequest(prNodeId: String, method: MergeMethod) async throws -> Bool {
        let mutation = """
        mutation($id: ID!, $method: PullRequestMergeMethod!) {
          mergePullRequest(input: { pullRequestId: $id, mergeMethod: $method }) {
            pullRequest { merged }
          }
        }
        """
        let payload: [String: Any] = [
            "query": mutation,
            "variables": ["id": prNodeId, "method": method.rawValue],
        ]
        let data = try await graphQL(payload: payload)
        return try ensureNoGraphQLErrors(data)
    }

    /// Cancels auto-merge for the given PR.
    @discardableResult
    func disableAutoMerge(prNodeId: String) async throws -> Bool {
        let mutation = """
        mutation($id: ID!) {
          disablePullRequestAutoMerge(input: { pullRequestId: $id }) {
            pullRequest { autoMergeRequest { enabledAt } }
          }
        }
        """
        let payload: [String: Any] = ["query": mutation, "variables": ["id": prNodeId]]
        let data = try await graphQL(payload: payload)
        return try ensureNoGraphQLErrors(data)
    }

    /// Throws GitHubClientError.requestFailed when GraphQL returned a 200 with errors.
    private func ensureNoGraphQLErrors(_ data: Data) throws -> Bool {
        struct Envelope: Decodable {
            struct GQLError: Decodable { let message: String }
            let errors: [GQLError]?
        }
        if let env = try? JSONDecoder().decode(Envelope.self, from: data),
           let errors = env.errors, !errors.isEmpty {
            throw GitHubClientError.requestFailed(200, errors.map(\.message).joined(separator: "; "))
        }
        return true
    }

    // MARK: - GraphQL helper

    /// Runs a GraphQL operation against api.github.com and returns the raw body.
    /// Surfaces GraphQL `errors` arrays (200-with-errors) as proper errors so
    /// callers don't see a generic "decode failed" when GitHub actually told us
    /// something useful. Each call site decodes the `data` envelope itself
    /// because each query has its own response shape.
    private func graphQLRaw(payload: [String: Any]) async throws -> Data {
        var req = URLRequest(url: URL(string: "https://api.github.com/graphql")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(try token())", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw GitHubClientError.requestFailed(-1, "no http response")
        }
        if http.statusCode == 401 {
            // Cached token is stale; drop it so the next attempt re-reads from gh.
            invalidateAuth()
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw GitHubClientError.requestFailed(http.statusCode, body)
        }
        // Peek for GraphQL-level errors. GitHub returns 200 for these with an
        // `errors` array, which would otherwise fail downstream decoding with a
        // confusing missing-keys message.
        struct ErrorPeek: Decodable {
            struct Err: Decodable { let message: String }
            let errors: [Err]?
        }
        if let peek = try? JSONDecoder().decode(ErrorPeek.self, from: data),
           let errors = peek.errors, !errors.isEmpty {
            throw GitHubClientError.requestFailed(200, errors.map(\.message).joined(separator: "; "))
        }
        return data
    }
}

extension GitHubClient {
    /// Convenience alias used by the existing call sites. Always returns the
    /// raw response body; each caller decodes its own response shape.
    fileprivate func graphQL(payload: [String: Any]) async throws -> Data {
        try await graphQLRaw(payload: payload)
    }
}
