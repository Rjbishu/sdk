// Copyright (c) 2017, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:analyzer/dart/analysis/analysis_context.dart';
import 'package:analyzer/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/analysis/session.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/src/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/src/dart/analysis/session.dart';
import 'package:analyzer/src/generated/source.dart';
import 'package:analyzer/src/test_utilities/mock_sdk.dart';
import 'package:analyzer/src/test_utilities/resource_provider_mixin.dart';
import 'package:test/test.dart';
import 'package:test_reflective_loader/test_reflective_loader.dart';

import '../resolution/context_collection_resolution.dart';

main() {
  defineReflectiveSuite(() {
    defineReflectiveTests(AnalysisSessionImplTest);
    defineReflectiveTests(AnalysisSessionImpl_BazelWorkspaceTest);
  });
}

@reflectiveTest
class AnalysisSessionImpl_BazelWorkspaceTest
    extends BazelWorkspaceResolutionTest {
  void test_getErrors_notFileOfUri() async {
    var relPath = 'dart/my/lib/a.dart';
    newFile('$workspaceRootPath/bazel-bin/$relPath');

    var path = convertPath('$workspaceRootPath/$relPath');
    var session = contextFor(path).currentSession;
    var result = await session.getErrors(path);
    expect(result.state, ResultState.NOT_FILE_OF_URI);
    expect(() => result.errors, throwsStateError);
  }

  void test_getErrors_valid() async {
    var file = newFile(
      '$workspaceRootPath/dart/my/lib/a.dart',
      content: 'var x = 0',
    );

    var session = contextFor(file.path).currentSession;
    var result = await session.getErrors(file.path);
    expect(result.state, ResultState.VALID);
    expect(result.path, file.path);
    expect(result.errors, hasLength(1));
    expect(result.uri.toString(), 'package:dart.my/a.dart');
  }

  void test_getResolvedLibrary2_notFileOfUri() async {
    var relPath = 'dart/my/lib/a.dart';
    newFile('$workspaceRootPath/bazel-bin/$relPath');

    var path = convertPath('$workspaceRootPath/$relPath');
    var session = contextFor(path).currentSession;
    var result = await session.getResolvedLibrary2(path);
    expect(result, isA<NotPathOfUriResult>());
  }

  void test_getResolvedUnit2_notFileOfUri() async {
    var relPath = 'dart/my/lib/a.dart';
    newFile('$workspaceRootPath/bazel-bin/$relPath');

    var path = convertPath('$workspaceRootPath/$relPath');
    var session = contextFor(path).currentSession;
    var result = await session.getResolvedUnit2(path);
    expect(result, isA<NotPathOfUriResult>());
  }

  void test_getResolvedUnit2_valid() async {
    var file = newFile(
      '$workspaceRootPath/dart/my/lib/a.dart',
      content: 'class A {}',
    );

    var session = contextFor(file.path).currentSession;
    var result =
        await session.getResolvedUnit2(file.path) as ResolvedUnitResult;
    expect(result.state, ResultState.VALID);
    expect(result.path, file.path);
    expect(result.errors, isEmpty);
    expect(result.uri.toString(), 'package:dart.my/a.dart');
  }

  @deprecated
  void test_getResolvedUnit_notFileOfUri() async {
    var relPath = 'dart/my/lib/a.dart';
    newFile('$workspaceRootPath/bazel-bin/$relPath');

    var path = convertPath('$workspaceRootPath/$relPath');
    var session = contextFor(path).currentSession;
    var result = await session.getResolvedUnit(path);
    expect(result.state, ResultState.NOT_FILE_OF_URI);
    expect(() => result.errors, throwsStateError);
  }

  @deprecated
  void test_getResolvedUnit_valid() async {
    var file = newFile(
      '$workspaceRootPath/dart/my/lib/a.dart',
      content: 'class A {}',
    );

    var session = contextFor(file.path).currentSession;
    var result = await session.getResolvedUnit(file.path);
    expect(result.state, ResultState.VALID);
    expect(result.path, file.path);
    expect(result.errors, isEmpty);
    expect(result.uri.toString(), 'package:dart.my/a.dart');
  }

  void test_getUnitElement2_invalidPath_notAbsolute() async {
    var file = newFile(
      '$workspaceRootPath/dart/my/lib/a.dart',
      content: 'class A {}',
    );

    var session = contextFor(file.path).currentSession;
    var result = await session.getUnitElement2('not_absolute.dart');
    expect(result, isA<InvalidPathResult>());
  }

  void test_getUnitElement2_notPathOfUri() async {
    var relPath = 'dart/my/lib/a.dart';
    newFile('$workspaceRootPath/bazel-bin/$relPath');

    var path = convertPath('$workspaceRootPath/$relPath');
    var session = contextFor(path).currentSession;
    var result = await session.getUnitElement2(path);
    expect(result, isA<NotPathOfUriResult>());
  }

  void test_getUnitElement2_valid() async {
    var file = newFile(
      '$workspaceRootPath/dart/my/lib/a.dart',
      content: 'class A {}',
    );

    var session = contextFor(file.path).currentSession;
    var result = await session.getUnitElementValid(file.path);
    expect(result.state, ResultState.VALID);
    expect(result.path, file.path);
    expect(result.element.types, hasLength(1));
    expect(result.uri.toString(), 'package:dart.my/a.dart');
  }

  @deprecated
  void test_getUnitElement_notFileOfUri() async {
    var relPath = 'dart/my/lib/a.dart';
    newFile('$workspaceRootPath/bazel-bin/$relPath');

    var path = convertPath('$workspaceRootPath/$relPath');
    var session = contextFor(path).currentSession;
    var result = await session.getUnitElement(path);
    expect(result.state, ResultState.NOT_FILE_OF_URI);
    expect(() => result.element, throwsStateError);
  }

  @deprecated
  void test_getUnitElement_valid() async {
    var file = newFile(
      '$workspaceRootPath/dart/my/lib/a.dart',
      content: 'class A {}',
    );

    var session = contextFor(file.path).currentSession;
    var result = await session.getUnitElement(file.path);
    expect(result.state, ResultState.VALID);
    expect(result.path, file.path);
    expect(result.element.types, hasLength(1));
    expect(result.uri.toString(), 'package:dart.my/a.dart');
  }
}

@reflectiveTest
class AnalysisSessionImplTest with ResourceProviderMixin {
  late final AnalysisContextCollection contextCollection;
  late final AnalysisContext context;
  late final AnalysisSessionImpl session;

  late final String testContextPath;
  late final String aaaContextPath;
  late final String bbbContextPath;

  late final String testPath;

  void setUp() {
    MockSdk(resourceProvider: resourceProvider);

    testContextPath = newFolder('/home/test').path;
    aaaContextPath = newFolder('/home/aaa').path;
    bbbContextPath = newFolder('/home/bbb').path;

    newFile('/home/test/.packages', content: r'''
test:lib/
''');

    contextCollection = AnalysisContextCollectionImpl(
      includedPaths: [testContextPath, aaaContextPath, bbbContextPath],
      resourceProvider: resourceProvider,
      sdkPath: convertPath(sdkRoot),
    );
    context = contextCollection.contextFor(testContextPath);
    session = context.currentSession as AnalysisSessionImpl;

    testPath = convertPath('/home/test/lib/test.dart');
  }

  test_getErrors() async {
    newFile(testPath, content: 'class C {');
    var errorsResult = await session.getErrors(testPath);
    expect(errorsResult.session, session);
    expect(errorsResult.path, testPath);
    expect(errorsResult.errors, isNotEmpty);
  }

  test_getLibraryByUri() async {
    newFile(testPath, content: r'''
class A {}
class B {}
''');

    var library = await session.getLibraryByUri('package:test/test.dart');
    expect(library.getType('A'), isNotNull);
    expect(library.getType('B'), isNotNull);
    expect(library.getType('C'), isNull);
  }

  test_getLibraryByUri_unresolvedUri() async {
    expect(() async {
      await session.getLibraryByUri('package:foo/foo.dart');
    }, throwsArgumentError);
  }

  test_getParsedLibrary() async {
    newFile(testPath, content: r'''
class A {}
class B {}
''');

    var parsedLibrary = session.getParsedLibrary(testPath);
    expect(parsedLibrary.session, session);
    expect(parsedLibrary.path, testPath);
    expect(parsedLibrary.uri, Uri.parse('package:test/test.dart'));

    expect(parsedLibrary.units, hasLength(1));
    {
      var parsedUnit = parsedLibrary.units![0];
      expect(parsedUnit.session, session);
      expect(parsedUnit.path, testPath);
      expect(parsedUnit.uri, Uri.parse('package:test/test.dart'));
      expect(parsedUnit.unit.declarations, hasLength(2));
    }
  }

  test_getParsedLibrary_getElementDeclaration_class() async {
    newFile(testPath, content: r'''
class A {}
class B {}
''');

    var library = await session.getLibraryByUri('package:test/test.dart');
    var parsedLibrary = session.getParsedLibrary(testPath);

    var element = library.getType('A')!;
    var declaration = parsedLibrary.getElementDeclaration(element)!;
    var node = declaration.node as ClassDeclaration;
    expect(node.name.name, 'A');
    expect(node.offset, 0);
    expect(node.length, 10);
  }

  @deprecated
  test_getParsedLibrary_getElementDeclaration_notThisLibrary() async {
    newFile(testPath, content: '');

    var resolvedUnit = await session.getResolvedUnit(testPath);
    var typeProvider = resolvedUnit.typeProvider;
    var intClass = typeProvider.intType.element;

    var parsedLibrary = session.getParsedLibrary(testPath);

    expect(() {
      parsedLibrary.getElementDeclaration(intClass);
    }, throwsArgumentError);
  }

  test_getParsedLibrary_getElementDeclaration_notThisLibrary2() async {
    newFile(testPath, content: '');

    var resolvedUnit =
        await session.getResolvedUnit2(testPath) as ResolvedUnitResult;
    var typeProvider = resolvedUnit.typeProvider;
    var intClass = typeProvider.intType.element;

    var parsedLibrary = session.getParsedLibrary(testPath);

    expect(() {
      parsedLibrary.getElementDeclaration(intClass);
    }, throwsArgumentError);
  }

  test_getParsedLibrary_getElementDeclaration_synthetic() async {
    newFile(testPath, content: r'''
int foo = 0;
''');

    var parsedLibrary = session.getParsedLibrary(testPath);

    var unitResult = await session.getUnitElement2(testPath);
    var unitElement = (unitResult as UnitElementResult).element;
    var fooElement = unitElement.topLevelVariables[0];
    expect(fooElement.name, 'foo');

    // We can get the variable element declaration.
    var fooDeclaration = parsedLibrary.getElementDeclaration(fooElement)!;
    var fooNode = fooDeclaration.node as VariableDeclaration;
    expect(fooNode.name.name, 'foo');
    expect(fooNode.offset, 4);
    expect(fooNode.length, 7);
    expect(fooNode.name.staticElement, isNull);

    // Synthetic elements don't have nodes.
    expect(parsedLibrary.getElementDeclaration(fooElement.getter!), isNull);
    expect(parsedLibrary.getElementDeclaration(fooElement.setter!), isNull);
  }

  @deprecated
  test_getParsedLibrary_getElementDeclaration_synthetic_deprecated() async {
    newFile(testPath, content: r'''
int foo = 0;
''');

    var parsedLibrary = session.getParsedLibrary(testPath);

    var unitElement = (await session.getUnitElement(testPath)).element;
    var fooElement = unitElement.topLevelVariables[0];
    expect(fooElement.name, 'foo');

    // We can get the variable element declaration.
    var fooDeclaration = parsedLibrary.getElementDeclaration(fooElement)!;
    var fooNode = fooDeclaration.node as VariableDeclaration;
    expect(fooNode.name.name, 'foo');
    expect(fooNode.offset, 4);
    expect(fooNode.length, 7);
    expect(fooNode.name.staticElement, isNull);

    // Synthetic elements don't have nodes.
    expect(parsedLibrary.getElementDeclaration(fooElement.getter!), isNull);
    expect(parsedLibrary.getElementDeclaration(fooElement.setter!), isNull);
  }

  test_getParsedLibrary_invalidPartUri() async {
    newFile(testPath, content: r'''
part 'a.dart';
part ':[invalid uri].dart';
part 'c.dart';
''');

    var parsedLibrary = session.getParsedLibrary(testPath);

    expect(parsedLibrary.units, hasLength(3));
    expect(
      parsedLibrary.units![0].path,
      convertPath('/home/test/lib/test.dart'),
    );
    expect(
      parsedLibrary.units![1].path,
      convertPath('/home/test/lib/a.dart'),
    );
    expect(
      parsedLibrary.units![2].path,
      convertPath('/home/test/lib/c.dart'),
    );
  }

  test_getParsedLibrary_notLibrary() async {
    newFile(testPath, content: 'part of "a.dart";');

    expect(() {
      session.getParsedLibrary(testPath);
    }, throwsArgumentError);
  }

  test_getParsedLibrary_parts() async {
    var a = convertPath('/home/test/lib/a.dart');
    var b = convertPath('/home/test/lib/b.dart');
    var c = convertPath('/home/test/lib/c.dart');

    var aContent = r'''
part 'b.dart';
part 'c.dart';

class A {}
''';

    var bContent = r'''
part of 'a.dart';

class B1 {}
class B2 {}
''';

    var cContent = r'''
part of 'a.dart';

class C1 {}
class C2 {}
class C3 {}
''';

    newFile(a, content: aContent);
    newFile(b, content: bContent);
    newFile(c, content: cContent);

    var parsedLibrary = session.getParsedLibrary(a);
    expect(parsedLibrary.path, a);
    expect(parsedLibrary.uri, Uri.parse('package:test/a.dart'));
    expect(parsedLibrary.units, hasLength(3));

    {
      var aUnit = parsedLibrary.units![0];
      expect(aUnit.path, a);
      expect(aUnit.uri, Uri.parse('package:test/a.dart'));
      expect(aUnit.unit.declarations, hasLength(1));
    }

    {
      var bUnit = parsedLibrary.units![1];
      expect(bUnit.path, b);
      expect(bUnit.uri, Uri.parse('package:test/b.dart'));
      expect(bUnit.unit.declarations, hasLength(2));
    }

    {
      var cUnit = parsedLibrary.units![2];
      expect(cUnit.path, c);
      expect(cUnit.uri, Uri.parse('package:test/c.dart'));
      expect(cUnit.unit.declarations, hasLength(3));
    }
  }

  test_getParsedLibraryByElement() async {
    newFile(testPath, content: '');

    var element = await session.getLibraryByUri('package:test/test.dart');

    var parsedLibrary = session.getParsedLibraryByElement(element);
    expect(parsedLibrary.session, session);
    expect(parsedLibrary.path, testPath);
    expect(parsedLibrary.uri, Uri.parse('package:test/test.dart'));
    expect(parsedLibrary.units, hasLength(1));
  }

  test_getParsedLibraryByElement_differentSession() async {
    newFile(testPath, content: '');

    var element = await session.getLibraryByUri('package:test/test.dart');

    var aaaSession =
        contextCollection.contextFor(aaaContextPath).currentSession;

    expect(() {
      aaaSession.getParsedLibraryByElement(element);
    }, throwsArgumentError);
  }

  test_getParsedUnit() async {
    newFile(testPath, content: r'''
class A {}
class B {}
''');

    var unitResult = session.getParsedUnit(testPath);
    expect(unitResult.session, session);
    expect(unitResult.path, testPath);
    expect(unitResult.uri, Uri.parse('package:test/test.dart'));
    expect(unitResult.unit.declarations, hasLength(2));
  }

  test_getResolvedLibrary() async {
    var a = convertPath('/home/test/lib/a.dart');
    var b = convertPath('/home/test/lib/b.dart');

    var aContent = r'''
part 'b.dart';

class A /*a*/ {}
''';
    newFile(a, content: aContent);

    var bContent = r'''
part of 'a.dart';

class B /*b*/ {}
class B2 extends X {}
''';
    newFile(b, content: bContent);

    var resolvedLibrary = await session.getResolvedLibraryValid(a);
    expect(resolvedLibrary.session, session);
    expect(resolvedLibrary.path, a);
    expect(resolvedLibrary.uri, Uri.parse('package:test/a.dart'));

    var typeProvider = resolvedLibrary.typeProvider;
    expect(typeProvider.intType.element.name, 'int');

    var libraryElement = resolvedLibrary.element!;

    var aClass = libraryElement.getType('A')!;

    var bClass = libraryElement.getType('B')!;

    var aUnitResult = resolvedLibrary.units![0];
    expect(aUnitResult.path, a);
    expect(aUnitResult.uri, Uri.parse('package:test/a.dart'));
    expect(aUnitResult.content, aContent);
    expect(aUnitResult.unit, isNotNull);
    expect(aUnitResult.unit!.directives, hasLength(1));
    expect(aUnitResult.unit!.declarations, hasLength(1));
    expect(aUnitResult.errors, isEmpty);

    var bUnitResult = resolvedLibrary.units![1];
    expect(bUnitResult.path, b);
    expect(bUnitResult.uri, Uri.parse('package:test/b.dart'));
    expect(bUnitResult.content, bContent);
    expect(bUnitResult.unit, isNotNull);
    expect(bUnitResult.unit!.directives, hasLength(1));
    expect(bUnitResult.unit!.declarations, hasLength(2));
    expect(bUnitResult.errors, isNotEmpty);

    var aDeclaration = resolvedLibrary.getElementDeclaration(aClass)!;
    var aNode = aDeclaration.node as ClassDeclaration;
    expect(aNode.name.name, 'A');
    expect(aNode.offset, 16);
    expect(aNode.length, 16);
    expect(aNode.declaredElement!.name, 'A');

    var bDeclaration = resolvedLibrary.getElementDeclaration(bClass)!;
    var bNode = bDeclaration.node as ClassDeclaration;
    expect(bNode.name.name, 'B');
    expect(bNode.offset, 19);
    expect(bNode.length, 16);
    expect(bNode.declaredElement!.name, 'B');
  }

  test_getResolvedLibrary2_invalidPath_notAbsolute() async {
    var result = await session.getResolvedLibrary2('not_absolute.dart');
    expect(result, isA<InvalidPathResult>());
  }

  test_getResolvedLibrary2_notLibrary() async {
    newFile(testPath, content: 'part of "a.dart";');

    var result = await session.getResolvedLibrary2(testPath);
    expect(result, isA<NotLibraryButPartResult>());
  }

  test_getResolvedLibrary_getElementDeclaration_notThisLibrary() async {
    newFile(testPath, content: '');

    var resolvedLibrary = await session.getResolvedLibraryValid(testPath);

    expect(() {
      var intClass = resolvedLibrary.typeProvider.intType.element;
      resolvedLibrary.getElementDeclaration(intClass);
    }, throwsArgumentError);
  }

  test_getResolvedLibrary_getElementDeclaration_synthetic() async {
    newFile(testPath, content: r'''
int foo = 0;
''');

    var resolvedLibrary = await session.getResolvedLibraryValid(testPath);
    var unitElement = resolvedLibrary.element!.definingCompilationUnit;

    var fooElement = unitElement.topLevelVariables[0];
    expect(fooElement.name, 'foo');

    // We can get the variable element declaration.
    var fooDeclaration = resolvedLibrary.getElementDeclaration(fooElement)!;
    var fooNode = fooDeclaration.node as VariableDeclaration;
    expect(fooNode.name.name, 'foo');
    expect(fooNode.offset, 4);
    expect(fooNode.length, 7);
    expect(fooNode.declaredElement!.name, 'foo');

    // Synthetic elements don't have nodes.
    expect(resolvedLibrary.getElementDeclaration(fooElement.getter!), isNull);
    expect(resolvedLibrary.getElementDeclaration(fooElement.setter!), isNull);
  }

  test_getResolvedLibrary_invalidPartUri() async {
    newFile(testPath, content: r'''
part 'a.dart';
part ':[invalid uri].dart';
part 'c.dart';
''');

    var resolvedLibrary = await session.getResolvedLibraryValid(testPath);

    expect(resolvedLibrary.units, hasLength(3));
    expect(
      resolvedLibrary.units![0].path,
      convertPath('/home/test/lib/test.dart'),
    );
    expect(
      resolvedLibrary.units![1].path,
      convertPath('/home/test/lib/a.dart'),
    );
    expect(
      resolvedLibrary.units![2].path,
      convertPath('/home/test/lib/c.dart'),
    );
  }

  @deprecated
  test_getResolvedLibrary_notLibrary() async {
    newFile(testPath, content: 'part of "a.dart";');

    expect(() async {
      await session.getResolvedLibrary(testPath);
    }, throwsArgumentError);
  }

  @deprecated
  test_getResolvedLibraryByElement() async {
    newFile(testPath, content: '');

    var element = await session.getLibraryByUri('package:test/test.dart');

    var resolvedLibrary = await session.getResolvedLibraryByElement(element);
    expect(resolvedLibrary.session, session);
    expect(resolvedLibrary.path, testPath);
    expect(resolvedLibrary.uri, Uri.parse('package:test/test.dart'));
    expect(resolvedLibrary.units, hasLength(1));
    expect(resolvedLibrary.units![0].unit!.declaredElement, isNotNull);
  }

  test_getResolvedLibraryByElement2() async {
    newFile(testPath, content: '');

    var element = await session.getLibraryByUri('package:test/test.dart');

    var result = await session.getResolvedLibraryByElementValid(element);
    expect(result.session, session);
    expect(result.path, testPath);
    expect(result.uri, Uri.parse('package:test/test.dart'));
    expect(result.units, hasLength(1));
    expect(result.units![0].unit!.declaredElement, isNotNull);
  }

  test_getResolvedLibraryByElement2_differentSession() async {
    newFile(testPath, content: '');

    var element = await session.getLibraryByUri('package:test/test.dart');

    var aaaSession =
        contextCollection.contextFor(aaaContextPath).currentSession;

    var result = await aaaSession.getResolvedLibraryByElement2(element);
    expect(result, isA<NotElementOfThisSessionResult>());
  }

  @deprecated
  test_getResolvedLibraryByElement_differentSession() async {
    newFile(testPath, content: '');

    var element = await session.getLibraryByUri('package:test/test.dart');

    var aaaSession =
        contextCollection.contextFor(aaaContextPath).currentSession;

    expect(() async {
      await aaaSession.getResolvedLibraryByElement(element);
    }, throwsArgumentError);
  }

  @deprecated
  test_getResolvedUnit() async {
    newFile(testPath, content: r'''
class A {}
class B {}
''');

    var unitResult = await session.getResolvedUnit(testPath);
    expect(unitResult.session, session);
    expect(unitResult.path, testPath);
    expect(unitResult.uri, Uri.parse('package:test/test.dart'));
    expect(unitResult.unit!.declarations, hasLength(2));
    expect(unitResult.typeProvider, isNotNull);
    expect(unitResult.libraryElement, isNotNull);
  }

  test_getResolvedUnit2() async {
    newFile(testPath, content: r'''
class A {}
class B {}
''');

    var unitResult =
        await session.getResolvedUnit2(testPath) as ResolvedUnitResult;
    expect(unitResult.session, session);
    expect(unitResult.path, testPath);
    expect(unitResult.uri, Uri.parse('package:test/test.dart'));
    expect(unitResult.unit!.declarations, hasLength(2));
    expect(unitResult.typeProvider, isNotNull);
    expect(unitResult.libraryElement, isNotNull);
  }

  test_getSourceKind() async {
    newFile(testPath, content: 'class C {}');

    var kind = await session.getSourceKind(testPath);
    expect(kind, SourceKind.LIBRARY);
  }

  test_getSourceKind_part() async {
    newFile(testPath, content: 'part of "a.dart";');

    var kind = await session.getSourceKind(testPath);
    expect(kind, SourceKind.PART);
  }

  @deprecated
  test_getUnitElement() async {
    newFile(testPath, content: r'''
class A {}
class B {}
''');

    var unitResult = await session.getUnitElement(testPath);
    expect(unitResult.session, session);
    expect(unitResult.path, testPath);
    expect(unitResult.uri, Uri.parse('package:test/test.dart'));
    expect(unitResult.element.types, hasLength(2));

    var signature = await session.getUnitElementSignature(testPath);
    expect(unitResult.signature, signature);
  }

  test_getUnitElement2() async {
    newFile(testPath, content: r'''
class A {}
class B {}
''');

    var unitResult = await session.getUnitElementValid(testPath);
    expect(unitResult.session, session);
    expect(unitResult.path, testPath);
    expect(unitResult.uri, Uri.parse('package:test/test.dart'));
    expect(unitResult.element.types, hasLength(2));

    var signature = await session.getUnitElementSignature(testPath);
    expect(unitResult.signature, signature);
  }

  test_resourceProvider() async {
    expect(session.resourceProvider, resourceProvider);
  }
}

extension on AnalysisSession {
  Future<UnitElementResult> getUnitElementValid(String path) async {
    return await getUnitElement2(path) as UnitElementResult;
  }

  Future<ResolvedLibraryResult> getResolvedLibraryValid(String path) async {
    return await getResolvedLibrary2(path) as ResolvedLibraryResult;
  }

  Future<ResolvedLibraryResult> getResolvedLibraryByElementValid(
      LibraryElement element) async {
    return await getResolvedLibraryByElement2(element) as ResolvedLibraryResult;
  }
}
