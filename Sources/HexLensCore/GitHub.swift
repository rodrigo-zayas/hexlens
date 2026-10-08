import Foundation

public struct PullRequestSummary: Codable, Identifiable, Hashable, Sendable {
  public struct Author: Codable, Hashable, Sendable { public let login: String }

  public let number: Int
  public let title: String
  public let author: Author?
  public let headRefName: String
  public let baseRefName: String
  public let isDraft: Bool?
  public let additions: Int?
  public let deletions: Int?
  public let changedFiles: Int?
  public let updatedAt: String?
  public let url: String?

  public var id: Int { number }
}

public enum PRFilter: String, CaseIterable, Identifiable, Sendable {
  case reviewRequested, open, mine

  public var id: String { rawValue }

  public var title: String {
    switch self {
    case .reviewRequested: "Pedidas a mí"
    case .open: "Abiertas"
    case .mine: "Mías"
    }
  }

  var args: [String] {
    switch self {
    case .reviewRequested: ["--search", "review-requested:@me"]
    case .open: []
    case .mine: ["--author", "@me"]
    }
  }
}

/// Acceso a GitHub a través de `gh`, que ya tiene la sesión del usuario.
public enum GitHub {
  static let fields = "number,title,author,headRefName,baseRefName,isDraft,additions,deletions,changedFiles,updatedAt,url"

  public static func pullRequests(in repo: GitRepo, filter: PRFilter, limit: Int = 60) throws -> [PullRequestSummary] {
    let json = try Shell.runData(
      "gh", ["pr", "list", "--state", "open", "--limit", "\(limit)", "--json", fields] + filter.args,
      cwd: repo.root)
    return try JSONDecoder().decode([PullRequestSummary].self, from: json)
  }

  public static func pullRequest(_ number: Int, in repo: GitRepo) throws -> PullRequestSummary {
    let json = try Shell.runData("gh", ["pr", "view", "\(number)", "--json", fields], cwd: repo.root)
    return try JSONDecoder().decode(PullRequestSummary.self, from: json)
  }

  /// Trae cabeza y base de la PR a refs propias (`refs/hexlens/…`) sin tocar ramas locales.
  /// `baseOverride` compara contra otra rama (p. ej. develop en una PR apilada) sin cambiar la PR.
  public static func fetch(_ pr: PullRequestSummary, into repo: GitRepo, baseOverride: String? = nil) throws -> (base: String, head: String) {
    let branch = baseOverride ?? pr.baseRefName
    let head = "refs/hexlens/pr/\(pr.number)"
    let base = "refs/hexlens/base/\(branch)"
    try repo.git([
      "fetch", "--no-tags", "--quiet", "origin",
      "+refs/pull/\(pr.number)/head:\(head)",
      "+refs/heads/\(branch):\(base)",
    ])
    return (base, head)
  }
}
