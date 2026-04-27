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

    init(session: URLSession = .shared) {
        self.session = session
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

    /// Phase 1: lightweight list. Excludes mergeStateStatus/mergeable/reviewDecision
    /// because GitHub computes those lazily and they can be slow. The UI shows
    /// these PRs immediately; per-PR enrichment fills the missing fields.
    func fetchMyOpenPRs() async throws -> [PullRequest] {
        let login = try currentLogin()
        let query = """
        {
          search(query: "is:pr is:open author:\(login)", type: ISSUE, first: 25) {
            nodes {
              ... on PullRequest {
                id
                number
                title
                url
                headRefName
                baseRefName
                isDraft
                repository { name owner { login } }
              }
            }
          }
        }
        """
        let data = try await graphQL(payload: ["query": query])

        struct GQLResponse: Decodable {
            struct Data: Decodable {
                struct Search: Decodable { let nodes: [PRNode] }
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
                let repository: Repo
                struct Repo: Decodable {
                    let name: String
                    let owner: Owner
                    struct Owner: Decodable { let login: String }
                }
            }
            let data: Data
        }

        do {
            let decoded = try JSONDecoder().decode(GQLResponse.self, from: data)
            return decoded.data.search.nodes.map { node in
                PullRequest(
                    nodeId: node.id,
                    number: node.number,
                    title: node.title,
                    url: node.url,
                    headRefName: node.headRefName,
                    baseRefName: node.baseRefName,
                    isDraft: node.isDraft,
                    repoOwner: node.repository.owner.login,
                    repoName: node.repository.name,
                    mergeable: nil,
                    mergeStateStatus: nil,
                    reviewDecision: nil
                )
            }
        } catch {
            throw GitHubClientError.decodingFailed(String(describing: error))
        }
    }

    /// Phase 2: per-PR enrichment with the slow fields. Run these in parallel from the caller.
    func enrichPR(nodeId: String) async throws -> PREnrichment {
        let query = """
        query($id: ID!) {
          node(id: $id) {
            ... on PullRequest {
              mergeable
              mergeStateStatus
              reviewDecision
            }
          }
        }
        """
        let payload: [String: Any] = ["query": query, "variables": ["id": nodeId]]
        let data = try await graphQL(payload: payload)

        struct GQLResponse: Decodable {
            struct Data: Decodable { let node: Node? }
            struct Node: Decodable {
                let mergeable: String?
                let mergeStateStatus: String?
                let reviewDecision: String?
            }
            let data: Data
        }

        do {
            let decoded = try JSONDecoder().decode(GQLResponse.self, from: data)
            guard let node = decoded.data.node else {
                throw GitHubClientError.decodingFailed("missing node for \(nodeId)")
            }
            return PREnrichment(
                mergeable: node.mergeable ?? "UNKNOWN",
                mergeStateStatus: MergeStateStatus(rawValue: node.mergeStateStatus ?? "UNKNOWN") ?? .unknown,
                reviewDecision: node.reviewDecision
            )
        } catch {
            throw GitHubClientError.decodingFailed(String(describing: error))
        }
    }

    // MARK: - Update branch

    enum UpdateMethod: String {
        case rebase = "REBASE"
        case merge = "MERGE"
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

    // MARK: - GraphQL helper

    private func graphQL(payload: [String: Any]) async throws -> Data {
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
        return data
    }
}
