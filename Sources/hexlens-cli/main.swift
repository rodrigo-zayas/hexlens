import AppKit
import Foundation
import HexLensCore
import HexLensUI

// hexlens summary  [--repo DIR] (--pr N | --base REF --head REF) [--order insideOut|outsideIn|testsFirst|largestFirst]
// hexlens mcp     (servidor MCP por stdio con las notas de revisión)
// hexlens snapshot [--repo DIR] (--pr N | --base REF --head REF) --out grafo.png [--context none|key|all] [--tests]

let args = Array(CommandLine.arguments.dropFirst())
func value(_ flag: String) -> String? {
  guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
  return args[i + 1]
}

let command = args.first.flatMap { $0.hasPrefix("--") ? nil : $0 } ?? "summary"

if command == "mcp" {
  MCPServer().run()
  exit(0)
}

do {
  let repo = try GitRepo(at: URL(fileURLWithPath: value("--repo") ?? FileManager.default.currentDirectoryPath))
  var base = value("--base") ?? "origin/develop"
  var head = value("--head") ?? "HEAD"
  var title: String?
  if let number = value("--pr").flatMap(Int.init) {
    let pr = try GitHub.pullRequest(number, in: repo)
    (base, head) = try GitHub.fetch(pr, into: repo)
    title = "#\(pr.number) \(pr.title)"
  }
  let session = try ReviewLoader.load(repo: repo, base: base, head: head, title: title) {
    FileHandle.standardError.write(Data("· \($0)\n".utf8))
  }

  switch command {
  case "summary":
    let strategy = value("--order").flatMap(ReadingStrategy.init(rawValue:)) ?? .insideOut
    print(Report.text(session, strategy: strategy))
  case "prompt":
    print(ExplainPrompt.pr(session))
  case "snapshot":
    let out = URL(fileURLWithPath: value("--out") ?? "hexlens.png")
    let context = value("--context").flatMap(ContextMode.init(rawValue:)) ?? .key
    try MainActor.assumeIsolated {
      try Snapshot.render(session: session, context: context, showTests: args.contains("--tests"), to: out)
    }
    print(out.path)
  default:
    FileHandle.standardError.write(Data("comando desconocido: \(command)\n".utf8))
    exit(2)
  }
} catch {
  FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
  exit(1)
}
