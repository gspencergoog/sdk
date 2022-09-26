// Copyright (c) 2017, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/src/test_utilities/resource_provider_mixin.dart';
import 'package:analyzer_plugin/src/utilities/navigation/navigation.dart';
import 'package:analyzer_plugin/utilities/navigation/navigation_dart.dart';
import 'package:test_reflective_loader/test_reflective_loader.dart';

void main() {
  defineReflectiveTests(DartNavigationComputerTest);
}

@reflectiveTest
class DartNavigationComputerTest with ResourceProviderMixin {
  CompilationUnit parseCompilationUnit(String content, String path) {
    return parseString(content: content, path: path).unit;
  }

  void test_compute_navigation() {
    const sourceCode = '''
/// Dartdoc comment
/// {@tool dartpad}
/// Example description.
///
/// ** See code in examples/api/lib/test_file.dart **
/// {@end-tool}
const int foo = 0;
''';
    resourceProvider.newFile('/test/packages/test/lib/test_file.dart', sourceCode);
    var unit = parseCompilationUnit(sourceCode, '/test/packages/test/lib/test_file.dart');
    resourceProvider.newFile('/test/examples/api/lib/test_file.dart', '// Test');
    var collector = NavigationCollectorImpl();
    computeDartNavigation(resourceProvider, collector, unit, 0, sourceCode.length);
    collector.createRegions();
    print('collector: $collector');
  }
}
