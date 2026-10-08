import XCTest

@testable import HexLensCore

final class ProfileDetectionTests: XCTestCase {
  let itxPaths = [
    "pcproducts-domain/src/main/java/com/inditex/micpcprods/domain/core/Product.java",
    "pcproducts-application/src/main/java/com/inditex/micpcprods/application/core/GetProduct.java",
    "pcproducts-infrastructure-components/pcproducts-components-amanda-pipe/src/main/java/com/inditex/micpcprods/components/amanda/pipe/Consumer.java",
  ]

  func testDetectsItx() {
    XCTAssertEqual(ProfileRegistry.detect(paths: itxPaths).id, "itx-hexagonal")
  }

  func testDetectsGenericJava() {
    let p = ProfileRegistry.detect(paths: ["src/main/java/com/acme/Util.java", "src/main/java/com/acme/Main.java"])
    XCTAssertEqual(p.id, "generic-layered-java")
  }

  func testDetectsGenericForPython() {
    XCTAssertEqual(ProfileRegistry.detect(paths: ["app/main.py", "app/util.py"]).id, "generic")
  }

  func testComponentNames() {
    XCTAssertEqual(ItxHexagonalProfile.component(of: "pcproducts-components-amanda-pipe"), "amanda · pipe")
    XCTAssertEqual(ItxHexagonalProfile.component(of: "pcproducts-components-rest"), "rest (API propio)")
    XCTAssertEqual(ItxHexagonalProfile.component(of: "pcproducts-components-mongo"), "mongo")
    XCTAssertNil(ItxHexagonalProfile.component(of: "pcproducts-domain"))
    let info = ItxHexagonalProfile().classify(path: itxPaths[2], facts: nil)
    XCTAssertEqual(info.component, "amanda · pipe")
    XCTAssertEqual(GraphLayout.technology(of: info.component), "pipe")
  }

  func testItxZoneOrder() {
    let p = ItxHexagonalProfile()
    func z(_ l: Layer) -> MapZone { p.zone(for: ArchInfo(module: "", layer: l, role: .other, context: nil, packageLabel: "", isTest: false)) }
    let ordered = [Layer.outbound, .application, .domain, .config, .other].map(z).map(\.order)
    XCTAssertEqual(ordered, ordered.sorted())
    XCTAssertEqual(z(.inbound), z(.outbound))
    XCTAssertEqual([z(.inbound), z(.application), z(.domain)].map(\.title), ["Infraestructura", "Aplicación", "Dominio"])
  }
}

final class LayoutHierarchyTests: XCTestCase {
  func unit(_ path: String, module: String, layer: Layer, component: String? = nil, context: String?) -> CodeUnit {
    CodeUnit(
      path: path, oldPath: nil, status: .modified, additions: 1, deletions: 0, language: "java",
      packageName: "p", typeName: path, kind: .class, module: module, layer: layer, role: .other,
      context: context, packageLabel: "", isTest: false, component: component, annotations: [], supertypes: [],
      members: [], touchesOutsideMembers: false, isKeyContext: false)
  }

  func testZonesAndContainers() {
    let units = [
      unit("a", module: "x-domain", layer: .domain, context: "core"),
      unit("b", module: "x-application", layer: .application, context: "core"),
      unit("c", module: "x-components-amanda-pipe", layer: .inbound, component: "amanda · pipe", context: "in"),
      unit("d", module: "x-components-mongo", layer: .outbound, component: "mongo", context: "db"),
    ]
    let edges = [Dependency(from: "c", to: "b", kind: .uses), Dependency(from: "b", to: "a", kind: .uses)]
    let l = GraphLayout.compute(units: units, edges: edges, profile: ItxHexagonalProfile())
    XCTAssertEqual(l.zones.map(\.zone.title), ["Infraestructura", "Aplicación", "Dominio"])
    XCTAssertEqual(l.containers.filter { $0.level == 1 }.count, 4)
    XCTAssertEqual(l.containers.filter { $0.level == 1 && $0.technology == "pipe" }.count, 1)
    XCTAssertEqual(l.frames.count, 4)
  }
}
