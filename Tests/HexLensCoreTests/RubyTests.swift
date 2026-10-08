import XCTest

@testable import HexLensCore

final class RubyAnalyzerTests: XCTestCase {
  private let source = """
    # frozen_string_literal: true
    module Flow
      module Cards
        class ExportService < ApplicationService
          include Concerns::Loggable
          extend Memoizable

          # Foo::Comentado no cuenta
          def call(card, options = {})
            Flow::Cards::Builder.new(card).build
            Policy.new("Texto::Literal")
            helper
          end

          def helper = Config.value

          private def secret
            Pundit.authorize(self)
          end

          def self.build(a, b)
            new(a).call(b)
          end
        end
      end
    end
    """

  func testNamespaceClassAndSuper() {
    let f = RubyAnalyzer().analyze(path: "app/services/flow/cards/export_service.rb", source: source)
    XCTAssertEqual(f.packageName, "Flow.Cards")
    XCTAssertEqual(f.primary?.name, "ExportService")
    XCTAssertEqual(f.primaryLine, 4)
    XCTAssertEqual(f.supertypes, ["ApplicationService", "Loggable", "Memoizable"])
  }

  func testMembersWithRanges() {
    let f = RubyAnalyzer().analyze(path: "app/services/flow/cards/export_service.rb", source: source)
    let byName = Dictionary(uniqueKeysWithValues: f.members.map { ($0.name, $0) })
    XCTAssertEqual(byName["call"]?.startLine, 9)
    XCTAssertEqual(byName["call"]?.endLine, 13)
    XCTAssertEqual(byName["call"]?.key, "call/2")
    XCTAssertEqual(byName["helper"]?.startLine, 15)
    XCTAssertEqual(byName["helper"]?.endLine, 15)
    XCTAssertEqual(byName["secret"]?.endLine, 19)
    XCTAssertEqual(byName["build"]?.signature, "def self.build(a, b)")
  }

  func testImportCandidatesFollowLexicalLookup() {
    let f = RubyAnalyzer().analyze(path: "app/services/flow/cards/export_service.rb", source: source)
    let names = f.imports.map(\.name)
    XCTAssertTrue(names.contains("Flow.Cards.Builder"))
    XCTAssertTrue(names.contains("Flow.Cards.Policy"))
    XCTAssertTrue(names.contains("Flow.Policy"))
    XCTAssertTrue(names.contains("Policy"))
    XCTAssertTrue(names.contains("Flow.Cards.Config"))
    XCTAssertFalse(names.contains { $0.hasSuffix("Comentado") || $0.hasSuffix("Literal") })
    XCTAssertTrue(f.identifiers.isSuperset(of: ["Flow", "Builder", "Policy", "Pundit"]))
  }

  func testCompactClassAndHeredoc() {
    let src = """
      class Flow::Cards::Foo < Base
        def run
          <<~SQL
            SELECT Hidden::Const
          SQL
        end
      end
      """
    let f = RubyAnalyzer().analyze(path: "app/services/flow/cards/foo.rb", source: src)
    XCTAssertEqual(f.packageName, "Flow.Cards")
    XCTAssertEqual(f.primary?.name, "Foo")
    XCTAssertEqual(f.members.first?.endLine, 6)
    XCTAssertFalse(f.imports.contains { $0.name.contains("Hidden") })
  }

  func testQualifiedNames() {
    let a = RubyAnalyzer()
    XCTAssertEqual(a.qualifiedName(forPath: "app/controllers/dam/v1/access_control_lists_controller.rb"), "Dam.V1.AccessControlListsController")
    XCTAssertEqual(a.qualifiedName(forPath: "app/services/flow/chroma_config_service.rb"), "Flow.ChromaConfigService")
    XCTAssertEqual(a.qualifiedName(forPath: "app/models/concerns/trackable.rb"), "Trackable")
    XCTAssertEqual(a.qualifiedName(forPath: "lib/api_clients/dam/client.rb"), "ApiClients.Dam.Client")
    XCTAssertNil(a.qualifiedName(forPath: "spec/services/flow/x_spec.rb"))
    XCTAssertNil(a.qualifiedName(forPath: "app/views/dam/show.json.jbuilder"))
    XCTAssertNil(a.qualifiedName(forPath: "config/routes.rb"))
  }

  func testAnalyzersByExtension() {
    XCTAssertEqual(Analyzers.for("a/B.java")?.language, "java")
    XCTAssertEqual(Analyzers.for("a/b.rb")?.language, "ruby")
    XCTAssertEqual(Analyzers.for("a/b.jbuilder")?.language, "ruby")
    XCTAssertNil(Analyzers.for("a/b.ts"))
  }

  func testRubyOutline() {
    let entries = Outline.entries(path: "app/services/flow/cards/export_service.rb", source: source)
    XCTAssertEqual(entries.first?.name, "ExportService")
    XCTAssertEqual(entries.filter { $0.kind == .method }.map(\.name), ["call", "helper", "secret", "build"])
  }
}

final class RailsProfileTests: XCTestCase {
  let rails = RailsProfile()

  func testDetection() {
    let paths = ["app/controllers/dam/v1/acl_controller.rb", "app/services/flow/x_service.rb", "spec/services/flow/x_service_spec.rb"]
    XCTAssertEqual(ProfileRegistry.detect(paths: paths).id, "rails")
    XCTAssertEqual(ProfileRegistry.detect(paths: paths + ["app/javascript/a.ts", "app/javascript/b.tsx", "app/javascript/c.ts"]).id, "rails")
    XCTAssertEqual(
      ProfileRegistry.detect(paths: [
        "pcproducts-domain/src/main/java/com/inditex/micpcprods/domain/core/Product.java",
        "pcproducts-application/src/main/java/com/inditex/micpcprods/application/core/GetProduct.java",
      ]).id, "itx-hexagonal")
  }

  private func info(_ path: String) -> ArchInfo { rails.classify(path: path, facts: nil) }

  func testZonesAndComponents() {
    let controller = info("app/controllers/dam/v1/access_control_lists_controller.rb")
    XCTAssertEqual(controller.role, .controller)
    XCTAssertEqual(controller.component, "controllers · Dam::V1")
    XCTAssertEqual(rails.zone(for: controller).id, "entry")

    let service = info("app/services/flow/cards/export_service.rb")
    XCTAssertEqual(service.component, "services · Flow")
    XCTAssertEqual(service.context, "cards")
    XCTAssertEqual(rails.zone(for: service).id, "services")

    let policy = info("app/policies/dam_policy.rb")
    XCTAssertEqual(policy.role, .policy)
    XCTAssertEqual(policy.component, "policies")

    let model = info("app/models/dam/asset.rb")
    XCTAssertEqual(model.component, "models · Dam")
    XCTAssertEqual(rails.zone(for: model).id, "models")

    let job = info("app/jobs/flow/sync_job.rb")
    XCTAssertEqual(rails.zone(for: job).id, "jobs")

    let producer = info("app/producers/asset_producer.rb")
    XCTAssertEqual(producer.role, .publisher)
    XCTAssertEqual(rails.zone(for: producer).id, "output")
    XCTAssertEqual(rails.zone(for: info("lib/api_clients/dam/client.rb")).id, "output")
    XCTAssertEqual(rails.zone(for: info("config/routes.rb")).id, "config")
    XCTAssertEqual(rails.zone(for: info("db/migrate/20240101_x.rb")).id, "config")

    let spec = info("spec/services/flow/cards/export_service_spec.rb")
    XCTAssertTrue(spec.isTest)
    XCTAssertEqual(spec.component, "services · Flow")
    XCTAssertEqual(rails.zone(for: spec).id, "services")
    XCTAssertEqual(info("spec/requests/dam/v1/access_control_lists_spec.rb").component, "controllers · Dam::V1")
    XCTAssertFalse(controller.isTest)
  }

  func testViolations() {
    let model = info("app/models/asset.rb")
    XCTAssertEqual(rails.violation(from: model, fromPackage: "", importing: "Dam.V1.AssetsController")?.1, .error)
    XCTAssertEqual(rails.violation(from: model, fromPackage: "", importing: "SyncJob")?.1, .error)
    let service = info("app/services/x_service.rb")
    XCTAssertEqual(rails.violation(from: service, fromPackage: "", importing: "AssetsController")?.1, .warning)
    XCTAssertNil(rails.violation(from: service, fromPackage: "", importing: "Asset"))
  }

  private func unit(_ path: String) -> CodeUnit {
    let i = rails.classify(path: path, facts: nil)
    return CodeUnit(
      path: path, oldPath: nil, status: .modified, additions: 1, deletions: 0, language: "ruby", packageName: "",
      typeName: ((path as NSString).lastPathComponent as NSString).deletingPathExtension, kind: .class, module: i.module,
      layer: i.layer, role: i.role, context: i.context, packageLabel: i.packageLabel, isTest: i.isTest, component: i.component,
      annotations: [], supertypes: [], members: [], touchesOutsideMembers: false, isKeyContext: false)
  }

  func testSpecSubjectLinking() {
    let units = [
      unit("app/services/flow/x_service.rb"), unit("app/models/flow/x_service.rb"),
      unit("app/controllers/dam/v1/access_control_lists_controller.rb"),
      unit("spec/services/flow/x_service_spec.rb"), unit("spec/requests/dam/v1/access_control_lists_spec.rb"),
      unit("spec/services/other_spec.rb"),
    ]
    XCTAssertEqual(rails.testSubject(of: units[3], among: units)?.path, "app/services/flow/x_service.rb")
    XCTAssertEqual(rails.testSubject(of: units[4], among: units)?.path, "app/controllers/dam/v1/access_control_lists_controller.rb")
    XCTAssertNil(rails.testSubject(of: units[5], among: units))
  }

  func testJavaTestLinkingUnchanged() {
    let profile = ItxHexagonalProfile()
    var test = unit("a/src/test/java/p/FooTest.java")
    test.typeName = "FooTest"
    var subject = unit("a/src/main/java/p/Foo.java")
    subject.typeName = "Foo"
    XCTAssertEqual(profile.testSubject(of: test, among: [test, subject])?.path, subject.path)
  }
}
