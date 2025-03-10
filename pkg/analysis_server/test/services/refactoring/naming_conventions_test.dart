// Copyright (c) 2014, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:analysis_server/src/services/correction/status.dart';
import 'package:analysis_server/src/services/refactoring/naming_conventions.dart';
import 'package:analysis_server/src/services/refactoring/refactoring.dart';
import 'package:analyzer_plugin/protocol/protocol_common.dart'
    show RefactoringProblemSeverity;
import 'package:test_reflective_loader/test_reflective_loader.dart';

import 'abstract_refactoring.dart';

void main() {
  defineReflectiveSuite(() {
    defineReflectiveTests(NamingConventionsTest);
  });
}

@reflectiveTest
class NamingConventionsTest extends RefactoringTest {
  @override
  Refactoring get refactoring => throw UnimplementedError();

  void test_validateClassName_doesNotStartWithLowerCase() {
    assertRefactoringStatus(
        validateClassName('newName'), RefactoringProblemSeverity.WARNING,
        expectedMessage: 'Class name should start with an uppercase letter.');
  }

  void test_validateClassName_empty() {
    assertRefactoringStatus(
        validateClassName(''), RefactoringProblemSeverity.FATAL,
        expectedMessage: 'Class name must not be empty.');
  }

  void test_validateClassName_invalidCharacter() {
    assertRefactoringStatus(
        validateClassName('-NewName'), RefactoringProblemSeverity.FATAL,
        expectedMessage: "Class name must not contain '-'.");
  }

  void test_validateClassName_leadingBlanks() {
    assertRefactoringStatus(
        validateClassName(' NewName'), RefactoringProblemSeverity.FATAL,
        expectedMessage: 'Class name must not start or end with a blank.');
  }

  void test_validateClassName_notIdentifierMiddle() {
    assertRefactoringStatus(
        validateClassName('New-Name'), RefactoringProblemSeverity.FATAL,
        expectedMessage: "Class name must not contain '-'.");
  }

  void test_validateClassName_notIdentifierStart() {
    assertRefactoringStatus(
        validateClassName('badName'), RefactoringProblemSeverity.WARNING,
        expectedMessage: 'Class name should start with an uppercase letter.');
  }

  void test_validateClassName_OK() {
    assertRefactoringStatusOK(validateClassName('NewName'));
  }

  void test_validateClassName_OK_leadingDollar() {
    assertRefactoringStatusOK(validateClassName('\$NewName'));
  }

  void test_validateClassName_OK_leadingUnderscore() {
    assertRefactoringStatusOK(validateClassName('_NewName'));
  }

  void test_validateClassName_OK_middleDollar() {
    assertRefactoringStatusOK(validateClassName('New\$Name'));
  }

  void test_validateClassName_trailingBlanks() {
    assertRefactoringStatus(
        validateClassName('NewName '), RefactoringProblemSeverity.FATAL,
        expectedMessage: 'Class name must not start or end with a blank.');
  }

  void test_validateConstructorName_doesNotStartWithLowerCase() {
    assertRefactoringStatus(
        validateConstructorName('NewName'), RefactoringProblemSeverity.WARNING,
        expectedMessage:
            'Constructor name should start with a lowercase letter.');
  }

  void test_validateConstructorName_empty() {
    assertRefactoringStatusOK(validateConstructorName(''));
  }

  void test_validateConstructorName_leadingBlanks() {
    assertRefactoringStatus(
        validateConstructorName(' newName'), RefactoringProblemSeverity.FATAL,
        expectedMessage:
            'Constructor name must not start or end with a blank.');
  }

  void test_validateConstructorName_notIdentifierMiddle() {
    assertRefactoringStatus(
        validateConstructorName('na-me'), RefactoringProblemSeverity.FATAL,
        expectedMessage: "Constructor name must not contain '-'.");
  }

  void test_validateConstructorName_notIdentifierStart() {
    assertRefactoringStatus(
        validateConstructorName('2name'), RefactoringProblemSeverity.FATAL,
        expectedMessage:
            'Constructor name must begin with a lowercase letter or underscore.');
  }

  void test_validateConstructorName_null() {
    assertRefactoringStatus(
        validateConstructorName(null), RefactoringProblemSeverity.FATAL,
        expectedMessage: 'Constructor name must not be null.');
  }

  void test_validateConstructorName_OK() {
    assertRefactoringStatusOK(validateConstructorName('newName'));
  }

  void test_validateConstructorName_OK_leadingUnderscore() {
    assertRefactoringStatusOK(validateConstructorName('_newName'));
  }

  void test_validateConstructorName_trailingBlanks() {
    assertRefactoringStatus(
        validateConstructorName('newName '), RefactoringProblemSeverity.FATAL,
        expectedMessage:
            'Constructor name must not start or end with a blank.');
  }

  void test_validateFieldName_doesNotStartWithLowerCase() {
    assertRefactoringStatus(
        validateFieldName('NewName'), RefactoringProblemSeverity.WARNING,
        expectedMessage: 'Field name should start with a lowercase letter.');
  }

  void test_validateFieldName_empty() {
    assertRefactoringStatus(
        validateFieldName(''), RefactoringProblemSeverity.FATAL,
        expectedMessage: 'Field name must not be empty.');
  }

  void test_validateFieldName_keyword() {
    assertRefactoringStatus(
        validateFieldName('for'), RefactoringProblemSeverity.FATAL,
        expectedMessage: 'Field name must not be a keyword.');
  }

  void test_validateFieldName_leadingBlanks() {
    assertRefactoringStatus(
        validateFieldName(' newName'), RefactoringProblemSeverity.FATAL,
        expectedMessage: 'Field name must not start or end with a blank.');
  }

  void test_validateFieldName_notIdentifierMiddle() {
    assertRefactoringStatus(
        validateFieldName('new-Name'), RefactoringProblemSeverity.FATAL,
        expectedMessage: "Field name must not contain '-'.");
  }

  void test_validateFieldName_notIdentifierStart() {
    assertRefactoringStatus(
        validateFieldName('2newName'), RefactoringProblemSeverity.FATAL,
        expectedMessage:
            'Field name must begin with a lowercase letter or underscore.');
  }

  void test_validateFieldName_OK() {
    assertRefactoringStatusOK(validateFieldName('newName'));
  }

  void test_validateFieldName_OK_leadingUnderscore() {
    assertRefactoringStatusOK(validateFieldName('_newName'));
  }

  void test_validateFieldName_OK_middleUnderscore() {
    assertRefactoringStatusOK(validateFieldName('new_name'));
  }

  void test_validateFieldName_pseudoKeyword() {
    _assertWarningBuiltIn(validateFieldName('await'));
  }

  void test_validateFieldName_trailingBlanks() {
    assertRefactoringStatus(
        validateFieldName('newName '), RefactoringProblemSeverity.FATAL,
        expectedMessage: 'Field name must not start or end with a blank.');
  }

  void test_validateFunctionName_doesNotStartWithLowerCase() {
    assertRefactoringStatus(
        validateFunctionName('NewName'), RefactoringProblemSeverity.WARNING,
        expectedMessage: 'Function name should start with a lowercase letter.');
  }

  void test_validateFunctionName_empty() {
    assertRefactoringStatus(
        validateFunctionName(''), RefactoringProblemSeverity.FATAL,
        expectedMessage: 'Function name must not be empty.');
  }

  void test_validateFunctionName_keyword() {
    assertRefactoringStatus(
        validateFunctionName('new'), RefactoringProblemSeverity.FATAL,
        expectedMessage: 'Function name must not be a keyword.');
  }

  void test_validateFunctionName_leadingBlanks() {
    assertRefactoringStatus(
        validateFunctionName(' newName'), RefactoringProblemSeverity.FATAL,
        expectedMessage: 'Function name must not start or end with a blank.');
  }

  void test_validateFunctionName_notIdentifierMiddle() {
    assertRefactoringStatus(
        validateFunctionName('new-Name'), RefactoringProblemSeverity.FATAL,
        expectedMessage: "Function name must not contain '-'.");
  }

  void test_validateFunctionName_notIdentifierStart() {
    assertRefactoringStatus(
        validateFunctionName('2newName'), RefactoringProblemSeverity.FATAL,
        expectedMessage:
            'Function name must begin with a lowercase letter or underscore.');
  }

  void test_validateFunctionName_OK() {
    assertRefactoringStatusOK(validateFunctionName('newName'));
  }

  void test_validateFunctionName_OK_leadingUnderscore() {
    assertRefactoringStatusOK(validateFunctionName('_newName'));
  }

  void test_validateFunctionName_OK_middleUnderscore() {
    assertRefactoringStatusOK(validateFunctionName('new_name'));
  }

  void test_validateFunctionName_pseudoKeyword() {
    _assertWarningBuiltIn(validateFunctionName('yield'));
  }

  void test_validateFunctionName_trailingBlanks() {
    assertRefactoringStatus(
        validateFunctionName('newName '), RefactoringProblemSeverity.FATAL,
        expectedMessage: 'Function name must not start or end with a blank.');
  }

  void test_validateImportPrefixName_doesNotStartWithLowerCase() {
    assertRefactoringStatus(
        validateImportPrefixName('NewName'), RefactoringProblemSeverity.WARNING,
        expectedMessage:
            'Import prefix name should start with a lowercase letter.');
  }

  void test_validateImportPrefixName_empty() {
    assertRefactoringStatusOK(validateImportPrefixName(''));
  }

  void test_validateImportPrefixName_keyword() {
    assertRefactoringStatus(
        validateImportPrefixName('while'), RefactoringProblemSeverity.FATAL,
        expectedMessage: 'Import prefix name must not be a keyword.');
  }

  void test_validateImportPrefixName_leadingBlanks() {
    assertRefactoringStatus(
        validateImportPrefixName(' newName'), RefactoringProblemSeverity.FATAL,
        expectedMessage:
            'Import prefix name must not start or end with a blank.');
  }

  void test_validateImportPrefixName_notIdentifierMiddle() {
    assertRefactoringStatus(
        validateImportPrefixName('new-Name'), RefactoringProblemSeverity.FATAL,
        expectedMessage: "Import prefix name must not contain '-'.");
  }

  void test_validateImportPrefixName_notIdentifierStart() {
    assertRefactoringStatus(
        validateImportPrefixName('2newName'), RefactoringProblemSeverity.FATAL,
        expectedMessage:
            'Import prefix name must begin with a lowercase letter or underscore.');
  }

  void test_validateImportPrefixName_null() {
    assertRefactoringStatus(
        validateImportPrefixName(null), RefactoringProblemSeverity.FATAL,
        expectedMessage: 'Import prefix name must not be null.');
  }

  void test_validateImportPrefixName_OK() {
    assertRefactoringStatusOK(validateImportPrefixName('newName'));
  }

  void test_validateImportPrefixName_OK_leadingUnderscore() {
    assertRefactoringStatusOK(validateImportPrefixName('_newName'));
  }

  void test_validateImportPrefixName_OK_middleUnderscore() {
    assertRefactoringStatusOK(validateImportPrefixName('new_name'));
  }

  void test_validateImportPrefixName_pseudoKeyword() {
    assertRefactoringStatus(
        validateImportPrefixName('await'), RefactoringProblemSeverity.FATAL,
        expectedMessage: 'Import prefix name must not be a keyword.');
  }

  void test_validateImportPrefixName_trailingBlanks() {
    assertRefactoringStatus(
        validateImportPrefixName('newName '), RefactoringProblemSeverity.FATAL,
        expectedMessage:
            'Import prefix name must not start or end with a blank.');
  }

  void test_validateLabelName_doesNotStartWithLowerCase() {
    assertRefactoringStatus(
        validateLabelName('NewName'), RefactoringProblemSeverity.WARNING,
        expectedMessage: 'Label name should start with a lowercase letter.');
  }

  void test_validateLabelName_empty() {
    assertRefactoringStatus(
        validateLabelName(''), RefactoringProblemSeverity.FATAL,
        expectedMessage: 'Label name must not be empty.');
  }

  void test_validateLabelName_keyword() {
    assertRefactoringStatus(
        validateLabelName('for'), RefactoringProblemSeverity.FATAL,
        expectedMessage: 'Label name must not be a keyword.');
  }

  void test_validateLabelName_leadingBlanks() {
    assertRefactoringStatus(
        validateLabelName(' newName'), RefactoringProblemSeverity.FATAL,
        expectedMessage: 'Label name must not start or end with a blank.');
  }

  void test_validateLabelName_notIdentifierMiddle() {
    assertRefactoringStatus(
        validateLabelName('new-Name'), RefactoringProblemSeverity.FATAL,
        expectedMessage: "Label name must not contain '-'.");
  }

  void test_validateLabelName_notIdentifierStart() {
    assertRefactoringStatus(
        validateLabelName('2newName'), RefactoringProblemSeverity.FATAL,
        expectedMessage:
            'Label name must begin with a lowercase letter or underscore.');
  }

  void test_validateLabelName_OK() {
    assertRefactoringStatusOK(validateLabelName('newName'));
  }

  void test_validateLabelName_OK_leadingDollar() {
    assertRefactoringStatusOK(validateLabelName('\$newName'));
  }

  void test_validateLabelName_OK_leadingUnderscore() {
    assertRefactoringStatusOK(validateLabelName('_newName'));
  }

  void test_validateLabelName_OK_middleUnderscore() {
    assertRefactoringStatusOK(validateLabelName('new_name'));
  }

  void test_validateLabelName_pseudoKeyword() {
    _assertWarningBuiltIn(validateLabelName('await'));
  }

  void test_validateLabelName_trailingBlanks() {
    assertRefactoringStatus(
        validateLabelName('newName '), RefactoringProblemSeverity.FATAL,
        expectedMessage: 'Label name must not start or end with a blank.');
  }

  void test_validateLibraryName_blank() {
    assertRefactoringStatus(
        validateLibraryName(''), RefactoringProblemSeverity.FATAL,
        expectedMessage: 'Library name must not be blank.');
    assertRefactoringStatus(
        validateLibraryName(' '), RefactoringProblemSeverity.FATAL,
        expectedMessage: 'Library name must not be blank.');
  }

  void test_validateLibraryName_blank_identifier() {
    assertRefactoringStatus(
        validateLibraryName('my..name'), RefactoringProblemSeverity.FATAL,
        expectedMessage: 'Library name identifier must not be empty.');
    assertRefactoringStatus(
        validateLibraryName('my. .name'), RefactoringProblemSeverity.FATAL,
        expectedMessage:
            'Library name identifier must not start or end with a blank.');
  }

  void test_validateLibraryName_hasUpperCase() {
    assertRefactoringStatus(
        validateLibraryName('my.newName'), RefactoringProblemSeverity.WARNING,
        expectedMessage:
            'Library name should consist of lowercase identifier separated by dots.');
  }

  void test_validateLibraryName_keyword() {
    assertRefactoringStatus(
        validateLibraryName('my.for.name'), RefactoringProblemSeverity.FATAL,
        expectedMessage: 'Library name identifier must not be a keyword.');
  }

  void test_validateLibraryName_leadingBlanks() {
    assertRefactoringStatus(
        validateLibraryName('my. name'), RefactoringProblemSeverity.FATAL,
        expectedMessage:
            'Library name identifier must not start or end with a blank.');
  }

  void test_validateLibraryName_notIdentifierMiddle() {
    assertRefactoringStatus(
        validateLibraryName('my.ba-d.name'), RefactoringProblemSeverity.FATAL,
        expectedMessage: "Library name identifier must not contain '-'.");
  }

  void test_validateLibraryName_notIdentifierStart() {
    assertRefactoringStatus(
        validateLibraryName('my.2bad.name'), RefactoringProblemSeverity.FATAL,
        expectedMessage:
            'Library name identifier must begin with a lowercase letter or underscore.');
  }

  void test_validateLibraryName_null() {
    assertRefactoringStatus(
        validateLibraryName(null), RefactoringProblemSeverity.FATAL,
        expectedMessage: 'Library name must not be null.');
  }

  void test_validateLibraryName_OK_oneIdentifier() {
    assertRefactoringStatusOK(validateLibraryName('name'));
  }

  void test_validateLibraryName_OK_severalIdentifiers() {
    assertRefactoringStatusOK(validateLibraryName('my.lib.name'));
  }

  void test_validateLibraryName_trailingBlanks() {
    assertRefactoringStatus(
        validateLibraryName('my.bad .name'), RefactoringProblemSeverity.FATAL,
        expectedMessage:
            'Library name identifier must not start or end with a blank.');
  }

  void test_validateMethodName_doesNotStartWithLowerCase() {
    assertRefactoringStatus(
        validateMethodName('NewName'), RefactoringProblemSeverity.WARNING,
        expectedMessage: 'Method name should start with a lowercase letter.');
  }

  void test_validateMethodName_empty() {
    assertRefactoringStatus(
        validateMethodName(''), RefactoringProblemSeverity.FATAL,
        expectedMessage: 'Method name must not be empty.');
  }

  void test_validateMethodName_keyword() {
    assertRefactoringStatus(
        validateMethodName('for'), RefactoringProblemSeverity.FATAL,
        expectedMessage: 'Method name must not be a keyword.');
  }

  void test_validateMethodName_leadingBlanks() {
    assertRefactoringStatus(
        validateMethodName(' newName'), RefactoringProblemSeverity.FATAL,
        expectedMessage: 'Method name must not start or end with a blank.');
  }

  void test_validateMethodName_notIdentifierMiddle() {
    assertRefactoringStatus(
        validateMethodName('new-Name'), RefactoringProblemSeverity.FATAL,
        expectedMessage: "Method name must not contain '-'.");
  }

  void test_validateMethodName_notIdentifierStart() {
    assertRefactoringStatus(
        validateMethodName('2newName'), RefactoringProblemSeverity.FATAL,
        expectedMessage:
            'Method name must begin with a lowercase letter or underscore.');
  }

  void test_validateMethodName_OK() {
    assertRefactoringStatusOK(validateMethodName('newName'));
  }

  void test_validateMethodName_OK_leadingUnderscore() {
    assertRefactoringStatusOK(validateMethodName('_newName'));
  }

  void test_validateMethodName_OK_middleUnderscore() {
    assertRefactoringStatusOK(validateMethodName('new_name'));
  }

  void test_validateMethodName_pseudoKeyword() {
    _assertWarningBuiltIn(validateMethodName('yield'));
  }

  void test_validateMethodName_trailingBlanks() {
    assertRefactoringStatus(
        validateMethodName('newName '), RefactoringProblemSeverity.FATAL,
        expectedMessage: 'Method name must not start or end with a blank.');
  }

  void test_validateParameterName_builtIn() {
    _assertWarningBuiltIn(validateParameterName('await'));
  }

  void test_validateParameterName_doesNotStartWithLowerCase() {
    assertRefactoringStatus(
        validateParameterName('NewName'), RefactoringProblemSeverity.WARNING,
        expectedMessage:
            'Parameter name should start with a lowercase letter.');
  }

  void test_validateParameterName_empty() {
    assertRefactoringStatus(
        validateParameterName(''), RefactoringProblemSeverity.FATAL,
        expectedMessage: 'Parameter name must not be empty.');
  }

  void test_validateParameterName_keyword() {
    assertRefactoringStatus(
        validateParameterName('while'), RefactoringProblemSeverity.FATAL,
        expectedMessage: 'Parameter name must not be a keyword.');
  }

  void test_validateParameterName_leadingBlanks() {
    assertRefactoringStatus(
        validateParameterName(' newName'), RefactoringProblemSeverity.FATAL,
        expectedMessage: 'Parameter name must not start or end with a blank.');
  }

  void test_validateParameterName_notIdentifierMiddle() {
    assertRefactoringStatus(
        validateParameterName('new-Name'), RefactoringProblemSeverity.FATAL,
        expectedMessage: "Parameter name must not contain '-'.");
  }

  void test_validateParameterName_notIdentifierStart() {
    assertRefactoringStatus(
        validateParameterName('2newName'), RefactoringProblemSeverity.FATAL,
        expectedMessage:
            'Parameter name must begin with a lowercase letter or underscore.');
  }

  void test_validateParameterName_OK() {
    assertRefactoringStatusOK(validateParameterName('newName'));
  }

  void test_validateParameterName_OK_leadingUnderscore() {
    assertRefactoringStatusOK(validateParameterName('_newName'));
  }

  void test_validateParameterName_OK_middleUnderscore() {
    assertRefactoringStatusOK(validateParameterName('new_name'));
  }

  void test_validateParameterName_pseudoKeyword() {
    _assertWarningBuiltIn(validateParameterName('await'));
  }

  void test_validateParameterName_trailingBlanks() {
    assertRefactoringStatus(
        validateParameterName('newName '), RefactoringProblemSeverity.FATAL,
        expectedMessage: 'Parameter name must not start or end with a blank.');
  }

  void test_validateTypeAliasName_doesNotStartWithLowerCase() {
    assertRefactoringStatus(
        validateTypeAliasName('newName'), RefactoringProblemSeverity.WARNING,
        expectedMessage:
            'Type alias name should start with an uppercase letter.');
  }

  void test_validateTypeAliasName_empty() {
    assertRefactoringStatus(
        validateTypeAliasName(''), RefactoringProblemSeverity.FATAL,
        expectedMessage: 'Type alias name must not be empty.');
  }

  void test_validateTypeAliasName_invalidCharacters() {
    assertRefactoringStatus(
        validateTypeAliasName('New-Name'), RefactoringProblemSeverity.FATAL,
        expectedMessage: "Type alias name must not contain \'-\'.");
  }

  void test_validateTypeAliasName_leadingBlanks() {
    assertRefactoringStatus(
        validateTypeAliasName(' NewName'), RefactoringProblemSeverity.FATAL,
        expectedMessage: 'Type alias name must not start or end with a blank.');
  }

  void test_validateTypeAliasName_notIdentifierMiddle() {
    assertRefactoringStatus(
        validateTypeAliasName('New-Name'), RefactoringProblemSeverity.FATAL,
        expectedMessage: "Type alias name must not contain '-'.");
  }

  void test_validateTypeAliasName_notIdentifierStart() {
    assertRefactoringStatus(
        validateTypeAliasName('newName'), RefactoringProblemSeverity.WARNING,
        expectedMessage:
            'Type alias name should start with an uppercase letter.');
  }

  void test_validateTypeAliasName_OK() {
    assertRefactoringStatusOK(validateTypeAliasName('NewName'));
  }

  void test_validateTypeAliasName_OK_leadingDollar() {
    assertRefactoringStatusOK(validateTypeAliasName('\$NewName'));
  }

  void test_validateTypeAliasName_OK_leadingUnderscore() {
    assertRefactoringStatusOK(validateTypeAliasName('_NewName'));
  }

  void test_validateTypeAliasName_OK_middleDollar() {
    assertRefactoringStatusOK(validateTypeAliasName('New\$Name'));
  }

  void test_validateTypeAliasName_trailingBlanks() {
    assertRefactoringStatus(
        validateTypeAliasName('NewName '), RefactoringProblemSeverity.FATAL,
        expectedMessage: 'Type alias name must not start or end with a blank.');
  }

  void test_validateVariableName_builtIn() {
    _assertWarningBuiltIn(validateVariableName('abstract'));
  }

  void test_validateVariableName_doesNotStartWithLowerCase() {
    assertRefactoringStatus(
        validateVariableName('NewName'), RefactoringProblemSeverity.WARNING,
        expectedMessage: 'Variable name should start with a lowercase letter.');
  }

  void test_validateVariableName_empty() {
    assertRefactoringStatus(
        validateVariableName(''), RefactoringProblemSeverity.FATAL,
        expectedMessage: 'Variable name must not be empty.');
  }

  void test_validateVariableName_keyword() {
    assertRefactoringStatus(
        validateVariableName('for'), RefactoringProblemSeverity.FATAL,
        expectedMessage: 'Variable name must not be a keyword.');
  }

  void test_validateVariableName_leadingBlanks() {
    assertRefactoringStatus(
        validateVariableName(' newName'), RefactoringProblemSeverity.FATAL,
        expectedMessage: 'Variable name must not start or end with a blank.');
  }

  void test_validateVariableName_notIdentifierMiddle() {
    assertRefactoringStatus(
        validateVariableName('new-Name'), RefactoringProblemSeverity.FATAL,
        expectedMessage: "Variable name must not contain '-'.");
  }

  void test_validateVariableName_notIdentifierStart() {
    assertRefactoringStatus(
        validateVariableName('2newName'), RefactoringProblemSeverity.FATAL,
        expectedMessage:
            'Variable name must begin with a lowercase letter or underscore.');
  }

  void test_validateVariableName_OK() {
    assertRefactoringStatusOK(validateVariableName('newName'));
  }

  void test_validateVariableName_OK_leadingDollar() {
    assertRefactoringStatusOK(validateVariableName('\$newName'));
  }

  void test_validateVariableName_OK_leadingUnderscore() {
    assertRefactoringStatusOK(validateVariableName('_newName'));
  }

  void test_validateVariableName_OK_middleUnderscore() {
    assertRefactoringStatusOK(validateVariableName('new_name'));
  }

  void test_validateVariableName_pseudoKeyword() {
    _assertWarningBuiltIn(validateVariableName('await'));
  }

  void test_validateVariableName_trailingBlanks() {
    assertRefactoringStatus(
        validateVariableName('newName '), RefactoringProblemSeverity.FATAL,
        expectedMessage: 'Variable name must not start or end with a blank.');
  }

  void _assertWarningBuiltIn(RefactoringStatus status) {
    assertRefactoringStatus(status, RefactoringProblemSeverity.WARNING,
        expectedMessage: 'Avoid using built-in identifiers as names.');
  }
}
