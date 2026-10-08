import XCTest

@testable import HexLensCore

final class JavaAnalyzerTests: XCTestCase {
  let source = """
    package com.inditex.micpcprods.infrastructure.newin.components.mongo.repository;

    import com.inditex.micpcprods.domain.newin.repository.NewInMarkRepository;
    import com.inditex.micpcprods.domain.newin.entity.mark.*;
    import static java.util.Objects.requireNonNull;

    /** Adaptador { con llaves en el comentario } */
    @Repository
    @RequiredArgsConstructor
    public class NewInMarkRepositoryMongo implements NewInMarkRepository, Closeable {

      private static final String TEXT = "no es { un bloque";

      @Override
      public Optional<NewInMark> findById(NewInMarkId id) {
        return dao.findById(id.value()).map(mapper::toEntity);
      }

      @SuppressWarnings({"unchecked"})
      public void saveAll(List<NewInMark> marks, boolean upsert) {
        if (marks.isEmpty()) { return; }
      }
    }
    """

  func testFacts() {
    let f = JavaAnalyzer().analyze(path: "x/src/main/java/NewInMarkRepositoryMongo.java", source: source)
    XCTAssertEqual(f.packageName, "com.inditex.micpcprods.infrastructure.newin.components.mongo.repository")
    XCTAssertEqual(f.primary, TypeDecl(name: "NewInMarkRepositoryMongo", kind: .class))
    XCTAssertEqual(f.supertypes, ["NewInMarkRepository", "Closeable"])
    XCTAssertEqual(f.annotations, ["Repository", "RequiredArgsConstructor"])
    XCTAssertEqual(f.imports.count, 3)
    XCTAssertTrue(f.imports[1].isWildcard)
    XCTAssertTrue(f.imports[2].isStatic)
    XCTAssertTrue(f.identifiers.contains("NewInMarkId"))
  }

  func testMembers() {
    let members = JavaAnalyzer().analyze(path: "A.java", source: source).members
    // Los campos sin llamada caen en "imports / campos", no son miembros.
    XCTAssertEqual(members.map(\.key), ["findById/1", "saveAll/2"])
    let save = members.last!
    XCTAssertEqual(save.startLine, 19)  // incluye la anotación
    XCTAssertEqual(save.endLine, 22)
  }
}

final class ProfileTests: XCTestCase {
  let profile = ItxHexagonalProfile()

  func layer(_ pkg: String, _ name: String, kind: TypeKind = .class, annotations: Set<String> = []) -> (Layer, Role) {
    let i = profile.classify(packageName: pkg, typeName: name, kind: kind, annotations: annotations)
    return (i.layer, i.role)
  }

  func testAmigaLayout() {
    let root = "com.inditex.micpcprods"
    XCTAssertTrue(layer("\(root).domain.newin.repository", "NewInRepository", kind: .interface) == (.domain, .port))
    XCTAssertTrue(layer("\(root).domain.newin.entity.mark", "NewInMark") == (.domain, .entity))
    XCTAssertTrue(layer("\(root).application.newin.usecase.mark", "CreateNewInMarks") == (.application, .useCase))
    XCTAssertTrue(layer("\(root).application.newin.usecase.mark.params", "CreateNewInMarksParams") == (.application, .params))
    XCTAssertTrue(layer("\(root).infrastructure.newin.components.rest.controller", "NewsInRestController", annotations: ["RestController"]) == (.inbound, .controller))
    XCTAssertTrue(layer("\(root).infrastructure.newin.components.rest.mapper.mark", "NewInMarkRestMapper") == (.inbound, .mapper))
    XCTAssertTrue(layer("\(root).infrastructure.newin.components.mongo.repository", "NewInMarkRepositoryMongo") == (.outbound, .adapter))
    XCTAssertTrue(layer("\(root).infrastructure.core.service.worker.jobs.handlers.newin", "NewInMarkDeletedJobHandler") == (.inbound, .handler))
    XCTAssertTrue(layer("\(root).components.amanda.rest.service", "AmandaService") == (.outbound, .client))
    XCTAssertTrue(layer("\(root).infrastructure.featured.service", "FeaturedRecalculationRequester") == (.outbound, .infraService))
  }

  func testViolations() {
    let domain = ArchInfo(module: "", layer: .domain, role: .entity, context: nil, packageLabel: "", isTest: false)
    let pkg = "com.inditex.micpcprods.domain.newin"
    XCTAssertEqual(profile.violation(from: domain, fromPackage: pkg, importing: "com.inditex.micpcprods.infrastructure.newin.components.mongo.dao.NewInDao")?.1, .error)
    XCTAssertEqual(profile.violation(from: domain, fromPackage: pkg, importing: "org.springframework.stereotype.Component")?.1, .warning)
    XCTAssertNil(profile.violation(from: domain, fromPackage: pkg, importing: "com.inditex.micpcprods.domain.core.entity.SectionId"))

    let controller = ArchInfo(module: "", layer: .inbound, role: .controller, context: nil, packageLabel: "", isTest: false)
    let cpkg = "com.inditex.micpcprods.infrastructure.newin.components.rest.controller"
    XCTAssertNotNil(profile.violation(from: controller, fromPackage: cpkg, importing: "com.inditex.micpcprods.components.mongo.dao.NewInJpaDao"))
    // Librería común: no es un adaptador del micro.
    XCTAssertNil(profile.violation(from: controller, fromPackage: cpkg, importing: "com.inditex.pacman.infrastructure.service.infrastructure.auth.AuthCalculator"))
  }
}

final class DiffTests: XCTestCase {
  func testParse() {
    let text = """
      diff --git a/A.java b/B.java
      similarity index 90%
      rename from A.java
      rename to B.java
      --- a/A.java
      +++ b/B.java
      @@ -10,3 +10,4 @@ class A {
       uno
      -dos
      +DOS
      +tres
       cuatro
      diff --git a/C.java b/C.java
      deleted file mode 100644
      --- a/C.java
      +++ /dev/null
      @@ -1 +0,0 @@
      -fuera
      """
    let diffs = DiffParser.parse(text)
    XCTAssertEqual(diffs["B.java"]?.addedLineNumbers, [11, 12])
    XCTAssertEqual(diffs["B.java"]?.removedLineNumbers, [11])
    XCTAssertEqual(diffs["B.java"]?.oldPath, "A.java")
    XCTAssertEqual(diffs["C.java"]?.removedLineNumbers, [1])
  }
}

final class ReadingOrderTests: XCTestCase {
  func unit(_ path: String, code: Bool, test: Bool) -> CodeUnit {
    CodeUnit(
      path: path, oldPath: nil, status: .modified, additions: 1, deletions: 0, language: code ? "java" : "other",
      packageName: "", typeName: (path as NSString).lastPathComponent, kind: .class, module: "m", layer: .config,
      role: .resource, context: nil, packageLabel: "", isTest: test, annotations: [], supertypes: [], members: [],
      touchesOutsideMembers: false, isKeyContext: false)
  }

  /// Un recurso dentro de src/test no puede salir dos veces (test huérfano y no-código).
  func testNoDuplicates() {
    let g = PRGraph(
      units: [unit("a/src/test/resources/x.yml", code: false, test: true), unit("a/src/test/java/FooTest.java", code: true, test: true)],
      edges: [], violations: [], subjectByTest: [:])
    for s in ReadingStrategy.allCases {
      let order = g.readingOrder(s)
      XCTAssertEqual(order.count, Set(order).count, "\(s)")
    }
  }

  func testTextSearch() {
    let t = "id idValue userId ID"
    XCTAssertEqual(TextSearch.matches(of: "id", in: t, caseSensitive: false, wholeWord: false).count, 4)
    XCTAssertEqual(TextSearch.matches(of: "id", in: t, caseSensitive: true, wholeWord: false).count, 2)
    XCTAssertEqual(TextSearch.matches(of: "id", in: t, caseSensitive: false, wholeWord: true), [NSRange(location: 0, length: 2), NSRange(location: 18, length: 2)])
    XCTAssertEqual(TextSearch.matches(of: "a.b(", in: "x a.b(1) axb(", caseSensitive: true, wholeWord: false), [NSRange(location: 2, length: 4)])
    XCTAssertTrue(TextSearch.matches(of: "", in: t, caseSensitive: false, wholeWord: false).isEmpty)
    // El emoji ocupa 2 unidades UTF-16.
    XCTAssertEqual(TextSearch.matches(of: "ñu", in: "😀 ñu", caseSensitive: true, wholeWord: false), [NSRange(location: 3, length: 2)])
  }
}
