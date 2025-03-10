// Copyright (c) 2016, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library kernel.ast_from_binary;

import 'dart:developer';
import 'dart:convert';
import 'dart:typed_data';

import '../ast.dart';
import '../transformations/flags.dart';
import 'tag.dart';

class ParseError {
  final String? filename;
  final int byteIndex;
  final String message;
  final String path;

  ParseError(this.message,
      {required this.filename, required this.byteIndex, required this.path});

  String toString() => '$filename:$byteIndex: $message at $path';
}

class InvalidKernelVersionError {
  final String? filename;
  final int version;

  InvalidKernelVersionError(this.filename, this.version);

  String toString() {
    StringBuffer sb = new StringBuffer();
    sb.write('Unexpected Kernel Format Version ${version} '
        '(expected ${Tag.BinaryFormatVersion})');
    if (filename != null) {
      sb.write(' when reading $filename.');
    }
    return '$sb';
  }
}

class InvalidKernelSdkVersionError {
  final String version;

  InvalidKernelSdkVersionError(this.version);

  String toString() {
    return 'Unexpected Kernel SDK Version ${version} '
        '(expected ${expectedSdkHash}).';
  }
}

class CompilationModeError {
  final String message;

  CompilationModeError(this.message);

  String toString() => "CompilationModeError[$message]";
}

class _ComponentIndex {
  static const int numberOfFixedFields = 10;

  final int binaryOffsetForSourceTable;
  final int binaryOffsetForCanonicalNames;
  final int binaryOffsetForMetadataPayloads;
  final int binaryOffsetForMetadataMappings;
  final int binaryOffsetForStringTable;
  final int binaryOffsetForConstantTable;
  final int mainMethodReference;
  final NonNullableByDefaultCompiledMode compiledMode;
  final List<int> libraryOffsets;
  final int libraryCount;
  final int componentFileSizeInBytes;

  _ComponentIndex(
      {required this.binaryOffsetForSourceTable,
      required this.binaryOffsetForCanonicalNames,
      required this.binaryOffsetForMetadataPayloads,
      required this.binaryOffsetForMetadataMappings,
      required this.binaryOffsetForStringTable,
      required this.binaryOffsetForConstantTable,
      required this.mainMethodReference,
      required this.compiledMode,
      required this.libraryOffsets,
      required this.libraryCount,
      required this.componentFileSizeInBytes});
}

class SubComponentView {
  final List<Library> libraries;
  final int componentStartOffset;
  final int componentFileSize;

  SubComponentView(
      this.libraries, this.componentStartOffset, this.componentFileSize);
}

/// [StringInterner] allows Strings created from the binary to be shared with
/// other components.
///
/// The [StringInterner] is an optional parameter to [BinaryBuilder], so sharing
/// should not be required for correctness, and an implementation of
/// [StringInterner] method may be partial (sometimes not finding an existing
/// object) or trivial (returning the argument).
abstract class StringInterner {
  /// Returns a string with the same contents as [string].
  String internString(String string);
}

class BinaryBuilder {
  final List<VariableDeclaration> variableStack = <VariableDeclaration>[];
  final List<LabeledStatement> labelStack = <LabeledStatement>[];
  int labelStackBase = 0;
  int switchCaseStackBase = 0;
  final List<SwitchCase> switchCaseStack = <SwitchCase>[];
  final List<TypeParameter> typeParameterStack = <TypeParameter>[];
  final String? filename;
  final List<int> _bytes;
  int _byteOffset = 0;
  final List<String> _stringTable = <String>[];
  final List<Uri?> _sourceUriTable = <Uri>[];
  Map<int, Constant> _constantTable = <int, Constant>{};
  late List<CanonicalName> _linkTable;
  int _transformerFlags = 0;
  Library? _currentLibrary;
  int _componentStartOffset = 0;
  NonNullableByDefaultCompiledMode? compilationMode;

  // If something goes wrong, this list should indicate what library,
  // class, and member was being built.
  List<String> debugPath = <String>[];

  final bool alwaysCreateNewNamedNodes;

  /// If binary contains metadata section with payloads referencing other nodes
  /// such Kernel binary can't be read lazily because metadata cross references
  /// will not be resolved correctly.
  bool _disableLazyReading = false;

  /// If binary contains metadata section with payloads referencing other nodes
  /// such Kernel binary can't be read lazily because metadata cross references
  /// will not be resolved correctly.
  bool _disableLazyClassReading = false;

  /// [stringInterner] (optional) may be used to allow components to share
  /// instances of [String] that have the same contents.
  final StringInterner? stringInterner;

  /// When creating lists that *might* be growable, use this boolean as the
  /// setting to pass to `growable` so the dill can be loaded in a more compact
  /// manner if the caller knows that the growability isn't needed.
  final bool useGrowableLists;

  /// Note that [disableLazyClassReading] is incompatible
  /// with checkCanonicalNames on readComponent.
  BinaryBuilder(this._bytes,
      {this.filename,
      bool disableLazyReading = false,
      bool disableLazyClassReading = false,
      bool? alwaysCreateNewNamedNodes,
      this.stringInterner,
      this.useGrowableLists = true})
      : _disableLazyReading = disableLazyReading,
        _disableLazyClassReading = disableLazyReading ||
            disableLazyClassReading ||
            // Disable lazy class reading when forcing the creation of new named
            // nodes as it is a logical "relink" to the new version (overwriting
            // the old one) - which doesn't play well with lazy loading class
            // content as old loaded references will then potentially still
            // point to the old content until the new class has been lazy
            // loaded.
            (alwaysCreateNewNamedNodes == true),
        this.alwaysCreateNewNamedNodes = alwaysCreateNewNamedNodes ?? false;

  fail(String message) {
    throw ParseError(message,
        byteIndex: _byteOffset, filename: filename, path: debugPath.join('::'));
  }

  int get byteOffset => _byteOffset;

  int readByte() => _bytes[_byteOffset++];

  int readUInt30() {
    int byte = readByte();
    if (byte & 0x80 == 0) {
      // 0xxxxxxx
      return byte;
    } else if (byte & 0x40 == 0) {
      // 10xxxxxx
      return ((byte & 0x3F) << 8) | readByte();
    } else {
      // 11xxxxxx
      return ((byte & 0x3F) << 24) |
          (readByte() << 16) |
          (readByte() << 8) |
          readByte();
    }
  }

  int readUint32() {
    return (readByte() << 24) |
        (readByte() << 16) |
        (readByte() << 8) |
        readByte();
  }

  final Float64List _doubleBuffer = new Float64List(1);
  Uint8List? _doubleBufferUint8;

  double readDouble() {
    Uint8List doubleBufferUint8 =
        _doubleBufferUint8 ??= _doubleBuffer.buffer.asUint8List();
    doubleBufferUint8[0] = readByte();
    doubleBufferUint8[1] = readByte();
    doubleBufferUint8[2] = readByte();
    doubleBufferUint8[3] = readByte();
    doubleBufferUint8[4] = readByte();
    doubleBufferUint8[5] = readByte();
    doubleBufferUint8[6] = readByte();
    doubleBufferUint8[7] = readByte();
    return _doubleBuffer[0];
  }

  Uint8List readBytes(int length) {
    Uint8List bytes = new Uint8List(length);
    bytes.setRange(0, bytes.length, _bytes, _byteOffset);
    _byteOffset += bytes.length;
    return bytes;
  }

  Uint8List readByteList() {
    return readBytes(readUInt30());
  }

  String readString() {
    return readStringEntry(readUInt30());
  }

  String readStringEntry(int numBytes) {
    String string = _readStringEntry(numBytes);
    if (stringInterner == null) return string;
    return stringInterner!.internString(string);
  }

  String _readStringEntry(int numBytes) {
    int start = _byteOffset;
    int end = start + numBytes;
    _byteOffset = end;
    for (int i = start; i < end; i++) {
      if (_bytes[i] > 127) {
        return _decodeWtf8(start, end);
      }
    }
    return new String.fromCharCodes(_bytes, start, end);
  }

  String _decodeWtf8(int start, int end) {
    // WTF-8 decoder that trusts its input, meaning that the correctness of
    // the code depends on the bytes from start to end being valid and
    // complete WTF-8. Instead of masking off the control bits from every
    // byte, it simply xor's the byte values together at their appropriate
    // bit shifts, and then xor's out all of the control bits at once.
    Uint16List charCodes = new Uint16List(end - start);
    int i = start;
    int j = 0;
    while (i < end) {
      int byte = _bytes[i++];
      if (byte < 0x80) {
        // ASCII.
        charCodes[j++] = byte;
      } else if (byte < 0xE0) {
        // Two-byte sequence (11-bit unicode value).
        int byte2 = _bytes[i++];
        int value = (byte << 6) ^ byte2 ^ 0x3080;
        assert(value >= 0x80 && value < 0x800);
        charCodes[j++] = value;
      } else if (byte < 0xF0) {
        // Three-byte sequence (16-bit unicode value).
        int byte2 = _bytes[i++];
        int byte3 = _bytes[i++];
        int value = (byte << 12) ^ (byte2 << 6) ^ byte3 ^ 0xE2080;
        assert(value >= 0x800 && value < 0x10000);
        charCodes[j++] = value;
      } else {
        // Four-byte sequence (non-BMP unicode value).
        int byte2 = _bytes[i++];
        int byte3 = _bytes[i++];
        int byte4 = _bytes[i++];
        int value =
            (byte << 18) ^ (byte2 << 12) ^ (byte3 << 6) ^ byte4 ^ 0x3C82080;
        assert(value >= 0x10000 && value < 0x110000);
        charCodes[j++] = 0xD7C0 + (value >> 10);
        charCodes[j++] = 0xDC00 + (value & 0x3FF);
      }
    }
    assert(i == end);
    return new String.fromCharCodes(charCodes, 0, j);
  }

  /// Read metadataMappings section from the binary.
  void _readMetadataMappings(
      Component component, int binaryOffsetForMetadataPayloads) {
    // Default reader ignores metadata section entirely.
  }

  /// Reads metadata for the given [node].
  T _associateMetadata<T extends Node>(T node, int nodeOffset) {
    // Default reader ignores metadata section entirely.
    return node;
  }

  void readStringTable(List<String> table) {
    // Read the table of end offsets.
    int length = readUInt30();
    List<int> endOffsets =
        new List<int>.generate(length, (_) => readUInt30(), growable: false);
    // Read the WTF-8 encoded strings.
    table.length = length;
    int startOffset = 0;
    for (int i = 0; i < length; ++i) {
      table[i] = readStringEntry(endOffsets[i] - startOffset);
      startOffset = endOffsets[i];
    }
  }

  void readConstantTable() {
    final int length = readUInt30();
    final int startOffset = byteOffset;
    for (int i = 0; i < length; i++) {
      _constantTable[byteOffset - startOffset] = readConstantTableEntry();
    }
  }

  Constant readConstantTableEntry() {
    final int constantTag = readByte();
    switch (constantTag) {
      case ConstantTag.NullConstant:
        return _readNullConstant();
      case ConstantTag.BoolConstant:
        return _readBoolConstant();
      case ConstantTag.IntConstant:
        return _readIntConstant();
      case ConstantTag.DoubleConstant:
        return _readDoubleConstant();
      case ConstantTag.StringConstant:
        return _readStringConstant();
      case ConstantTag.SymbolConstant:
        return _readSymbolConstant();
      case ConstantTag.MapConstant:
        return _readMapConstant();
      case ConstantTag.ListConstant:
        return _readListConstant();
      case ConstantTag.SetConstant:
        return _readSetConstant();
      case ConstantTag.InstanceConstant:
        return _readInstanceConstant();
      case ConstantTag.PartialInstantiationConstant:
        return _readPartialInstantiationConstant();
      case ConstantTag.TearOffConstant:
        return _readTearOffConstant();
      case ConstantTag.TypeLiteralConstant:
        return _readTypeLiteralConstant();
      case ConstantTag.UnevaluatedConstant:
        return _readUnevaluatedConstant();
    }

    throw fail('unexpected constant tag: $constantTag');
  }

  Constant _readNullConstant() {
    return new NullConstant();
  }

  Constant _readBoolConstant() {
    return new BoolConstant(readByte() == 1);
  }

  Constant _readIntConstant() {
    return new IntConstant((readExpression() as IntLiteral).value);
  }

  Constant _readDoubleConstant() {
    return new DoubleConstant(readDouble());
  }

  Constant _readStringConstant() {
    return new StringConstant(readStringReference());
  }

  Constant _readSymbolConstant() {
    Reference? libraryReference = readNullableLibraryReference();
    return new SymbolConstant(readStringReference(), libraryReference);
  }

  Constant _readMapConstant() {
    final DartType keyType = readDartType();
    final DartType valueType = readDartType();
    final int length = readUInt30();
    final List<ConstantMapEntry> entries =
        new List<ConstantMapEntry>.generate(length, (_) {
      final Constant key = readConstantReference();
      final Constant value = readConstantReference();
      return new ConstantMapEntry(key, value);
    }, growable: useGrowableLists);
    return new MapConstant(keyType, valueType, entries);
  }

  Constant _readListConstant() {
    final DartType typeArgument = readDartType();
    List<Constant> entries = _readConstantReferenceList();
    return new ListConstant(typeArgument, entries);
  }

  Constant _readSetConstant() {
    final DartType typeArgument = readDartType();
    List<Constant> entries = _readConstantReferenceList();
    return new SetConstant(typeArgument, entries);
  }

  Constant _readInstanceConstant() {
    final Reference classReference = readNonNullClassReference();
    final List<DartType> typeArguments = readDartTypeList();
    final int fieldValueCount = readUInt30();
    final Map<Reference, Constant> fieldValues = <Reference, Constant>{};
    for (int i = 0; i < fieldValueCount; i++) {
      final Reference fieldRef = readNonNullCanonicalNameReference().reference;
      final Constant constant = readConstantReference();
      fieldValues[fieldRef] = constant;
    }
    return new InstanceConstant(classReference, typeArguments, fieldValues);
  }

  Constant _readPartialInstantiationConstant() {
    final TearOffConstant tearOffConstant =
        readConstantReference() as TearOffConstant;
    final List<DartType> types = readDartTypeList();
    return new PartialInstantiationConstant(tearOffConstant, types);
  }

  Constant _readTearOffConstant() {
    final Reference reference = readNonNullCanonicalNameReference().reference;
    return new TearOffConstant.byReference(reference);
  }

  Constant _readTypeLiteralConstant() {
    final DartType type = readDartType();
    return new TypeLiteralConstant(type);
  }

  Constant _readUnevaluatedConstant() {
    final Expression expression = readExpression();
    return new UnevaluatedConstant(expression);
  }

  Constant readConstantReference() {
    final int offset = readUInt30();
    Constant? constant = _constantTable[offset];
    assert(constant != null, "No constant found at offset $offset.");
    return constant!;
  }

  List<Constant> _readConstantReferenceList() {
    final int length = readUInt30();
    return new List<Constant>.generate(length, (_) => readConstantReference(),
        growable: useGrowableLists);
  }

  Uri? readUriReference() {
    return _sourceUriTable[readUInt30()];
  }

  String readStringReference() {
    return _stringTable[readUInt30()];
  }

  List<String> readStringReferenceList() {
    int length = readUInt30();
    return new List<String>.generate(length, (_) => readStringReference(),
        growable: useGrowableLists);
  }

  String? readStringOrNullIfEmpty() {
    String string = readStringReference();
    return string.isEmpty ? null : string;
  }

  bool readAndCheckOptionTag() {
    int tag = readByte();
    if (tag == Tag.Nothing) {
      return false;
    } else if (tag == Tag.Something) {
      return true;
    } else {
      throw fail('unexpected option tag: $tag');
    }
  }

  List<Expression> readAnnotationList([TreeNode? parent]) {
    int length = readUInt30();
    if (length == 0) return const <Expression>[];
    return new List<Expression>.generate(
        length, (_) => readExpression()..parent = parent,
        growable: useGrowableLists);
  }

  void _fillTreeNodeList(
      List<TreeNode> list, TreeNode buildObject(int index), TreeNode parent) {
    int length = readUInt30();
    list.length = length;
    for (int i = 0; i < length; ++i) {
      TreeNode object = buildObject(i);
      list[i] = object..parent = parent;
    }
  }

  void _fillNonTreeNodeList(List<Node> list, Node buildObject()) {
    int length = readUInt30();
    list.length = length;
    for (int i = 0; i < length; ++i) {
      Node object = buildObject();
      list[i] = object;
    }
  }

  /// Reads a list of named nodes, reusing any existing objects already in the
  /// linking tree. The nodes are merged into [list], and if reading the library
  /// implementation, the order is corrected.
  ///
  /// [readObject] should read the object definition and its canonical name.
  /// If an existing object is bound to the canonical name, the existing object
  /// must be reused and returned.
  void _mergeNamedNodeList(
      List<NamedNode> list, NamedNode readObject(int index), TreeNode parent) {
    // When reading the library implementation, overwrite the whole list
    // with the new one.
    _fillTreeNodeList(list, readObject, parent);
  }

  void readLinkTable(CanonicalName linkRoot) {
    int length = readUInt30();
    _linkTable = new List<CanonicalName>.filled(
        length,
        // Use [linkRoot] as a dummy default value.
        linkRoot,
        growable: false);
    for (int i = 0; i < length; ++i) {
      int biasedParentIndex = readUInt30();
      String name = readStringReference();
      CanonicalName parent =
          biasedParentIndex == 0 ? linkRoot : _linkTable[biasedParentIndex - 1];
      _linkTable[i] = parent.getChild(name);
    }
  }

  List<int> _indexComponents() {
    _checkEmptyInput();
    int savedByteOffset = _byteOffset;
    _byteOffset = _bytes.length - 4;
    List<int> index = <int>[];
    while (_byteOffset > 0) {
      int size = readUint32();
      if (size <= 0) {
        throw fail("invalid size '$size' reported at offset $byteOffset");
      }
      int start = _byteOffset - size;
      if (start < 0) {
        throw fail("indicated size does not match file size");
      }
      index.add(size);
      _byteOffset = start - 4;
    }
    _byteOffset = savedByteOffset;
    return new List.from(index.reversed);
  }

  void _checkEmptyInput() {
    if (_bytes.length == 0) throw new StateError("Empty input given.");
  }

  void _readAndVerifySdkHash() {
    final String sdkHash = ascii.decode(readBytes(sdkHashLength));
    if (!isValidSdkHash(sdkHash)) {
      throw InvalidKernelSdkVersionError(sdkHash);
    }
  }

  /// Deserializes a kernel component and stores it in [component].
  ///
  /// When linking with a non-empty component, canonical names must have been
  /// computed ahead of time.
  ///
  /// The input bytes may contain multiple files concatenated.
  ///
  /// If [createView] is true, returns a list of [SubComponentView] - one for
  /// each concatenated dill - each of which knowing where in the combined dill
  /// it came from. If [createView] is false null will be returned.
  List<SubComponentView>? readComponent(Component component,
      {bool checkCanonicalNames: false, bool createView: false}) {
    return Timeline.timeSync<List<SubComponentView>?>(
        "BinaryBuilder.readComponent", () {
      _checkEmptyInput();

      // Check that we have a .dill file and it has the correct version before
      // we start decoding it.  Otherwise we will fail for cryptic reasons.
      int offset = _byteOffset;
      int magic = readUint32();
      if (magic != Tag.ComponentFile) {
        throw ArgumentError('Not a .dill file (wrong magic number).');
      }
      int version = readUint32();
      if (version != Tag.BinaryFormatVersion) {
        throw InvalidKernelVersionError(filename, version);
      }

      _readAndVerifySdkHash();

      _byteOffset = offset;
      List<int> componentFileSizes = _indexComponents();
      if (componentFileSizes.length > 1) {
        _disableLazyReading = true;
        _disableLazyClassReading = true;
      }
      int componentFileIndex = 0;
      List<SubComponentView>? views;
      if (createView) {
        views = <SubComponentView>[];
      }
      while (_byteOffset < _bytes.length) {
        SubComponentView? view = _readOneComponent(
            component, componentFileSizes[componentFileIndex],
            createView: createView);
        if (createView) {
          views!.add(view!);
        }
        ++componentFileIndex;
      }

      if (checkCanonicalNames) {
        component.root.checkCanonicalNameChildren();
      }
      return views;
    });
  }

  /// Deserializes the source and stores it in [component].
  /// Note that the _coverage_ normally included in the source in the
  /// uri-to-source mapping is _not_ included.
  ///
  /// The input bytes may contain multiple files concatenated.
  void readComponentSource(Component component) {
    List<int> componentFileSizes = _indexComponents();
    if (componentFileSizes.length > 1) {
      _disableLazyReading = true;
      _disableLazyClassReading = true;
    }
    int componentFileIndex = 0;
    while (_byteOffset < _bytes.length) {
      _readOneComponentSource(
          component, componentFileSizes[componentFileIndex]);
      ++componentFileIndex;
    }
  }

  /// Reads a single component file from the input and loads it into
  /// [component], overwriting and reusing any existing data in the component.
  ///
  /// When linking with a non-empty component, canonical names must have been
  /// computed ahead of time.
  ///
  /// This should *only* be used when there is a reason to not allow
  /// concatenated files.
  void readSingleFileComponent(Component component,
      {bool checkCanonicalNames: false}) {
    List<int> componentFileSizes = _indexComponents();
    if (componentFileSizes.isEmpty) throw fail("invalid component data");
    _readOneComponent(component, componentFileSizes[0]);
    if (_byteOffset < _bytes.length) {
      if (_byteOffset + 3 < _bytes.length) {
        int magic = readUint32();
        if (magic == Tag.ComponentFile) {
          throw 'Concatenated component file given when a single component '
              'was expected.';
        }
      }
      throw 'Unrecognized bytes following component data';
    }

    if (checkCanonicalNames) {
      component.root.checkCanonicalNameChildren();
    }
  }

  _ComponentIndex _readComponentIndex(int componentFileSize) {
    int savedByteIndex = _byteOffset;

    // There are two fields: file size and library count.
    _byteOffset = _componentStartOffset + componentFileSize - (2) * 4;
    int libraryCount = readUint32();
    // Library offsets are used for start and end offsets, so there is one extra
    // element that this the end offset of the last library
    List<int> libraryOffsets = new List<int>.filled(
        libraryCount + 1,
        // Use `-1` as a dummy default value.
        -1,
        growable: false);
    int componentFileSizeInBytes = readUint32();
    if (componentFileSizeInBytes != componentFileSize) {
      throw "Malformed binary: This component file's component index indicates "
          "that the file size should be $componentFileSize but other component "
          "indexes has indicated that the size should be "
          "${componentFileSizeInBytes}.";
    }

    // Skip to the start of the index.
    _byteOffset -=
        ((libraryCount + 1) + _ComponentIndex.numberOfFixedFields) * 4;

    // Now read the component index.
    int binaryOffsetForSourceTable = _componentStartOffset + readUint32();
    int binaryOffsetForCanonicalNames = _componentStartOffset + readUint32();
    int binaryOffsetForMetadataPayloads = _componentStartOffset + readUint32();
    int binaryOffsetForMetadataMappings = _componentStartOffset + readUint32();
    int binaryOffsetForStringTable = _componentStartOffset + readUint32();
    int binaryOffsetForConstantTable = _componentStartOffset + readUint32();
    int mainMethodReference = readUint32();
    NonNullableByDefaultCompiledMode compiledMode =
        NonNullableByDefaultCompiledMode.values[readUint32()];
    for (int i = 0; i < libraryCount + 1; ++i) {
      libraryOffsets[i] = _componentStartOffset + readUint32();
    }

    _byteOffset = savedByteIndex;

    return new _ComponentIndex(
        libraryCount: libraryCount,
        libraryOffsets: libraryOffsets,
        componentFileSizeInBytes: componentFileSizeInBytes,
        binaryOffsetForSourceTable: binaryOffsetForSourceTable,
        binaryOffsetForCanonicalNames: binaryOffsetForCanonicalNames,
        binaryOffsetForMetadataPayloads: binaryOffsetForMetadataPayloads,
        binaryOffsetForMetadataMappings: binaryOffsetForMetadataMappings,
        binaryOffsetForStringTable: binaryOffsetForStringTable,
        binaryOffsetForConstantTable: binaryOffsetForConstantTable,
        mainMethodReference: mainMethodReference,
        compiledMode: compiledMode);
  }

  void _readOneComponentSource(Component component, int componentFileSize) {
    _componentStartOffset = _byteOffset;

    final int magic = readUint32();
    if (magic != Tag.ComponentFile) {
      throw ArgumentError('Not a .dill file (wrong magic number).');
    }

    final int formatVersion = readUint32();
    if (formatVersion != Tag.BinaryFormatVersion) {
      throw InvalidKernelVersionError(filename, formatVersion);
    }

    _readAndVerifySdkHash();

    // Read component index from the end of this ComponentFiles serialized data.
    _ComponentIndex index = _readComponentIndex(componentFileSize);

    _byteOffset = index.binaryOffsetForSourceTable;
    Map<Uri?, Source> uriToSource = readUriToSource(readCoverage: false);
    _mergeUriToSource(component.uriToSource, uriToSource);

    _byteOffset = _componentStartOffset + componentFileSize;
  }

  SubComponentView? _readOneComponent(
      Component component, int componentFileSize,
      {bool createView: false}) {
    _componentStartOffset = _byteOffset;

    final int magic = readUint32();
    if (magic != Tag.ComponentFile) {
      throw ArgumentError('Not a .dill file (wrong magic number).');
    }

    final int formatVersion = readUint32();
    if (formatVersion != Tag.BinaryFormatVersion) {
      throw InvalidKernelVersionError(filename, formatVersion);
    }

    _readAndVerifySdkHash();

    List<String>? problemsAsJson = readListOfStrings();
    if (problemsAsJson != null) {
      component.problemsAsJson ??= <String>[];
      component.problemsAsJson!.addAll(problemsAsJson);
    }

    // Read component index from the end of this ComponentFiles serialized data.
    _ComponentIndex index = _readComponentIndex(componentFileSize);
    if (compilationMode == null) {
      compilationMode = component.modeRaw;
    }
    compilationMode =
        mergeCompilationModeOrThrow(compilationMode, index.compiledMode);

    _byteOffset = index.binaryOffsetForStringTable;
    readStringTable(_stringTable);

    _byteOffset = index.binaryOffsetForCanonicalNames;
    readLinkTable(component.root);

    // TODO(alexmarkov): reverse metadata mappings and read forwards
    _byteOffset = index.binaryOffsetForStringTable; // Read backwards.
    _readMetadataMappings(component, index.binaryOffsetForMetadataPayloads);

    _associateMetadata(component, _componentStartOffset);

    _byteOffset = index.binaryOffsetForSourceTable;
    Map<Uri?, Source> uriToSource = readUriToSource(readCoverage: true);
    _mergeUriToSource(component.uriToSource, uriToSource);

    _byteOffset = index.binaryOffsetForConstantTable;
    readConstantTable();

    int numberOfLibraries = index.libraryCount;

    SubComponentView? result;
    if (createView) {
      result = new SubComponentView(
          new List<Library>.generate(numberOfLibraries, (int i) {
            _byteOffset = index.libraryOffsets[i];
            return readLibrary(component, index.libraryOffsets[i + 1]);
          }, growable: false),
          _componentStartOffset,
          componentFileSize);
    } else {
      for (int i = 0; i < numberOfLibraries; ++i) {
        _byteOffset = index.libraryOffsets[i];
        readLibrary(component, index.libraryOffsets[i + 1]);
      }
    }

    Reference? mainMethod =
        getNullableMemberReferenceFromInt(index.mainMethodReference);
    component.setMainMethodAndMode(mainMethod, false, compilationMode!);

    _byteOffset = _componentStartOffset + componentFileSize;

    assert(typeParameterStack.isEmpty);

    return result;
  }

  /// Read a list of strings. If the list is empty, [null] is returned.
  List<String>? readListOfStrings() {
    int length = readUInt30();
    if (length == 0) return null;
    return new List<String>.generate(length, (_) => readString(),
        growable: useGrowableLists);
  }

  /// Read the uri-to-source part of the binary.
  /// Note that this can include coverage, but that it is only included if
  /// [readCoverage] is true, otherwise coverage will be skipped. Note also that
  /// if [readCoverage] is true, references are read and that the link table
  /// thus has to be read first.
  Map<Uri?, Source> readUriToSource({required bool readCoverage}) {
    // ignore: unnecessary_null_comparison
    assert(!readCoverage || (readCoverage && _linkTable != null));

    int length = readUint32();

    // Read data.
    _sourceUriTable.length = length;
    Map<Uri?, Source> uriToSource = <Uri, Source>{};
    for (int i = 0; i < length; ++i) {
      String uriString = readString();
      Uri? uri = uriString.isEmpty ? null : Uri.parse(uriString);
      _sourceUriTable[i] = uri;
      Uint8List sourceCode = readByteList();
      int lineCount = readUInt30();
      List<int> lineStarts = new List<int>.filled(
          lineCount,
          // Use `-1` as a dummy default value.
          -1,
          growable: false);
      int previousLineStart = 0;
      for (int j = 0; j < lineCount; ++j) {
        int lineStart = readUInt30() + previousLineStart;
        lineStarts[j] = lineStart;
        previousLineStart = lineStart;
      }
      String importUriString = readString();
      Uri? importUri =
          importUriString.isEmpty ? null : Uri.parse(importUriString);

      Set<Reference>? coverageConstructors;
      {
        int constructorCoverageCount = readUInt30();
        if (constructorCoverageCount > 0) {
          if (readCoverage) {
            coverageConstructors = new Set<Reference>();
            for (int j = 0; j < constructorCoverageCount; ++j) {
              coverageConstructors.add(readNonNullMemberReference());
            }
          } else {
            for (int j = 0; j < constructorCoverageCount; ++j) {
              skipMemberReference();
            }
          }
        }
      }

      uriToSource[uri] = new Source(lineStarts, sourceCode, importUri, uri)
        ..constantCoverageConstructors = coverageConstructors;
    }

    // Read index.
    for (int i = 0; i < length; ++i) {
      readUint32();
    }
    return uriToSource;
  }

  // Add everything from [src] into [dst], but don't overwrite a non-empty
  // source with an empty source. Empty sources may be introduced by
  // synthetic, copy-down implementations such as mixin applications or
  // noSuchMethod forwarders.
  void _mergeUriToSource(Map<Uri?, Source> dst, Map<Uri?, Source> src) {
    if (dst.isEmpty) {
      // Fast path for the common case of one component per binary.
      dst.addAll(src);
    } else {
      src.forEach((Uri? key, Source value) {
        Source? originalDestinationSource = dst[key];
        Source? mergeFrom;
        Source mergeTo;
        if (value.source.isNotEmpty || originalDestinationSource == null) {
          dst[key] = value;
          mergeFrom = originalDestinationSource;
          mergeTo = value;
        } else {
          mergeFrom = value;
          mergeTo = originalDestinationSource;
        }

        // TODO(jensj): Find out what the right thing to do is --- it probably
        // depends on what we do if read the same library twice - do we merge or
        // do we overwrite, and should we even support such a thing?

        // Merge coverage. Note that mergeFrom might be null.
        if (mergeTo.constantCoverageConstructors == null) {
          mergeTo.constantCoverageConstructors =
              mergeFrom?.constantCoverageConstructors;
        } else if (mergeFrom?.constantCoverageConstructors == null) {
          // Nothing to do.
        } else {
          // Both are non-null: Merge.
          mergeTo.constantCoverageConstructors!
              .addAll(mergeFrom!.constantCoverageConstructors!);
        }
      });
    }
  }

  void skipCanonicalNameReference() {
    readUInt30();
  }

  CanonicalName? readNullableCanonicalNameReference() {
    int index = readUInt30();
    if (index == 0) return null;
    return _linkTable[index - 1];
  }

  CanonicalName readNonNullCanonicalNameReference() {
    CanonicalName? canonicalName = readNullableCanonicalNameReference();
    if (canonicalName == null) {
      throw new StateError('No canonical name found.');
    }
    return canonicalName;
  }

  CanonicalName? getNullableCanonicalNameReferenceFromInt(int index) {
    if (index == 0) return null;
    return _linkTable[index - 1];
  }

  Reference? readNullableLibraryReference() {
    CanonicalName? canonicalName = readNullableCanonicalNameReference();
    return canonicalName?.reference;
  }

  Reference readNonNullLibraryReference() {
    CanonicalName? canonicalName = readNullableCanonicalNameReference();
    if (canonicalName != null) return canonicalName.reference;
    throw 'Expected a library reference to be valid but was `null`.';
  }

  LibraryDependency readLibraryDependencyReference() {
    int index = readUInt30();
    return _currentLibrary!.dependencies[index];
  }

  Reference? readNullableClassReference() {
    CanonicalName? name = readNullableCanonicalNameReference();
    return name?.reference;
  }

  Reference readNonNullClassReference() {
    CanonicalName? name = readNullableCanonicalNameReference();
    if (name == null) {
      throw 'Expected a class reference to be valid but was `null`.';
    }
    return name.reference;
  }

  void skipMemberReference() {
    skipCanonicalNameReference();
  }

  Reference? readNullableMemberReference() {
    CanonicalName? name = readNullableCanonicalNameReference();
    return name?.reference;
  }

  Reference readNonNullMemberReference() {
    CanonicalName? name = readNullableCanonicalNameReference();
    if (name == null) {
      throw 'Expected a member reference to be valid but was `null`.';
    }
    return name.reference;
  }

  Reference? readNullableInstanceMemberReference() {
    Reference? reference = readNullableMemberReference();
    readNullableMemberReference(); // Skip origin
    return reference;
  }

  Reference readNonNullInstanceMemberReference() {
    Reference reference = readNonNullMemberReference();
    readNullableMemberReference(); // Skip origin
    return reference;
  }

  Reference? getNullableMemberReferenceFromInt(int index) {
    return getNullableCanonicalNameReferenceFromInt(index)?.reference;
  }

  Reference? readNullableTypedefReference() {
    return readNullableCanonicalNameReference()?.reference;
  }

  Reference readNonNullTypedefReference() {
    return readNonNullCanonicalNameReference().reference;
  }

  Name readName() {
    String text = readStringReference();
    if (text.isNotEmpty && text[0] == '_') {
      return new Name.byReference(text, readNonNullLibraryReference());
    } else {
      return new Name(text);
    }
  }

  Library readLibrary(Component component, int endOffset) {
    // Read index.
    int savedByteOffset = _byteOffset;

    // There is a field for the procedure count.
    _byteOffset = endOffset - (1) * 4;
    int procedureCount = readUint32();
    List<int> procedureOffsets = new List<int>.filled(
        procedureCount + 1,
        // Use `-1` as a dummy default value.
        -1,
        growable: false);

    // There is a field for the procedure count, that number + 1 (for the end)
    // offsets, and then the class count (i.e. procedure count + 3 fields).
    _byteOffset = endOffset - (procedureCount + 3) * 4;
    int classCount = readUint32();
    for (int i = 0; i < procedureCount + 1; i++) {
      procedureOffsets[i] = _componentStartOffset + readUint32();
    }
    List<int> classOffsets = new List<int>.filled(
        classCount + 1,
        // Use `-1` as a dummy default value.
        -1,
        growable: false);

    // There is a field for the procedure count, that number + 1 (for the end)
    // offsets, then the class count and that number + 1 (for the end) offsets.
    // (i.e. procedure count + class count + 4 fields).
    _byteOffset = endOffset - (procedureCount + classCount + 4) * 4;
    for (int i = 0; i < classCount + 1; i++) {
      classOffsets[i] = _componentStartOffset + readUint32();
    }
    _byteOffset = savedByteOffset;

    int flags = readByte();

    int languageVersionMajor = readUInt30();
    int languageVersionMinor = readUInt30();

    CanonicalName canonicalName = readNonNullCanonicalNameReference();
    Reference reference = canonicalName.reference;
    Library? library = reference.node as Library?;
    if (alwaysCreateNewNamedNodes) {
      library = null;
    }
    if (library == null) {
      library =
          new Library(Uri.parse(canonicalName.name), reference: reference);
      component.libraries.add(library..parent = component);
    }
    _currentLibrary = library;
    String? name = readStringOrNullIfEmpty();

    // TODO(jensj): We currently save (almost the same) uri twice.
    Uri? fileUri = readUriReference();

    List<String>? problemsAsJson = readListOfStrings();

    library.flags = flags;
    library.setLanguageVersion(
        new Version(languageVersionMajor, languageVersionMinor));
    library.name = name;
    library.fileUri = fileUri;
    library.problemsAsJson = problemsAsJson;

    assert(
        mergeCompilationModeOrThrow(
                compilationMode, library.nonNullableByDefaultCompiledMode) ==
            compilationMode,
        "Cannot load ${library.nonNullableByDefaultCompiledMode} "
        "into component with mode $compilationMode");

    assert(() {
      debugPath.add(library!.name ?? library.importUri.toString());
      return true;
    }());

    _fillTreeNodeList(
        library.annotations, (index) => readExpression(), library);
    _readLibraryDependencies(library);
    _readAdditionalExports(library);
    _readLibraryParts(library);
    _mergeNamedNodeList(library.typedefs, (index) => readTypedef(), library);

    _mergeNamedNodeList(library.classes, (index) {
      _byteOffset = classOffsets[index];
      return readClass(classOffsets[index + 1]);
    }, library);
    _byteOffset = classOffsets.last;

    _mergeNamedNodeList(library.extensions, (index) {
      return readExtension();
    }, library);

    _mergeNamedNodeList(library.fields, (index) => readField(), library);
    _mergeNamedNodeList(library.procedures, (index) {
      _byteOffset = procedureOffsets[index];
      return readProcedure(procedureOffsets[index + 1]);
    }, library);
    _byteOffset = procedureOffsets.last;

    assert(((_) => true)(debugPath.removeLast()));
    _currentLibrary = null;
    return library;
  }

  void _readLibraryDependencies(Library library) {
    int length = readUInt30();
    library.dependencies.length = length;
    for (int i = 0; i < length; ++i) {
      library.dependencies[i] = readLibraryDependency(library);
    }
  }

  LibraryDependency readLibraryDependency(Library library) {
    int fileOffset = readOffset();
    int flags = readByte();
    List<Expression> annotations = readExpressionList();
    Reference targetLibrary = readNonNullLibraryReference();
    String? prefixName = readStringOrNullIfEmpty();
    List<Combinator> names = readCombinatorList();
    return new LibraryDependency.byReference(
        flags, annotations, targetLibrary, prefixName, names)
      ..fileOffset = fileOffset
      ..parent = library;
  }

  void _readAdditionalExports(Library library) {
    int numExportedReference = readUInt30();
    if (numExportedReference != 0) {
      library.additionalExports.clear();
      for (int i = 0; i < numExportedReference; i++) {
        CanonicalName exportedName = readNonNullCanonicalNameReference();
        Reference reference = exportedName.reference;
        library.additionalExports.add(reference);
      }
    }
  }

  Combinator readCombinator() {
    bool isShow = readByte() == 1;
    List<String> names = readStringReferenceList();
    return new Combinator(isShow, names);
  }

  List<Combinator> readCombinatorList() {
    int length = readUInt30();
    if (!useGrowableLists && length == 0) {
      // When lists don't have to be growable anyway, we might as well use an
      // almost constant one for the empty list.
      return emptyListOfCombinator;
    }
    return new List<Combinator>.generate(length, (_) => readCombinator(),
        growable: useGrowableLists);
  }

  void _readLibraryParts(Library library) {
    int length = readUInt30();
    library.parts.length = length;
    for (int i = 0; i < length; ++i) {
      library.parts[i] = readLibraryPart(library);
    }
  }

  LibraryPart readLibraryPart(Library library) {
    List<Expression> annotations = readExpressionList();
    String partUri = readStringReference();
    return new LibraryPart(annotations, partUri)..parent = library;
  }

  Typedef readTypedef() {
    CanonicalName canonicalName = readNonNullCanonicalNameReference();
    Reference reference = canonicalName.reference;
    Typedef? node = reference.node as Typedef?;
    if (alwaysCreateNewNamedNodes) {
      node = null;
    }
    Uri? fileUri = readUriReference();
    int fileOffset = readOffset();
    String name = readStringReference();
    if (node == null) {
      node = new Typedef(name, null, reference: reference);
    }
    node.annotations = readAnnotationList(node);
    readAndPushTypeParameterList(node.typeParameters, node);
    DartType type = readDartType();
    readAndPushTypeParameterList(node.typeParametersOfFunctionType, node);
    node.positionalParameters.clear();
    node.positionalParameters.addAll(readAndPushVariableDeclarationList());
    setParents(node.positionalParameters, node);
    node.namedParameters.clear();
    node.namedParameters.addAll(readAndPushVariableDeclarationList());
    setParents(node.namedParameters, node);
    typeParameterStack.length = 0;
    variableStack.length = 0;
    node.fileOffset = fileOffset;
    node.name = name;
    node.fileUri = fileUri;
    node.type = type;
    return node;
  }

  Class readClass(int endOffset) {
    int tag = readByte();
    assert(tag == Tag.Class);

    // Read index.
    int savedByteOffset = _byteOffset;
    // There is a field for the procedure count.
    _byteOffset = endOffset - (1) * 4;
    int procedureCount = readUint32();
    // There is a field for the procedure count, that number + 1 (for the end)
    // offsets (i.e. procedure count + 2 fields).
    _byteOffset = endOffset - (procedureCount + 2) * 4;
    List<int> procedureOffsets = new List<int>.generate(
        procedureCount + 1, (_) => _componentStartOffset + readUint32(),
        growable: false);
    _byteOffset = savedByteOffset;

    CanonicalName canonicalName = readNonNullCanonicalNameReference();
    Reference reference = canonicalName.reference;
    Class? node = reference.node as Class?;
    if (alwaysCreateNewNamedNodes) {
      node = null;
    }
    Uri? fileUri = readUriReference();
    int startFileOffset = readOffset();
    int fileOffset = readOffset();
    int fileEndOffset = readOffset();
    int flags = readByte();
    String name = readStringReference();
    if (node == null) {
      node = new Class(name: name, reference: reference)..dirty = false;
    }

    node.startFileOffset = startFileOffset;
    node.fileOffset = fileOffset;
    node.fileEndOffset = fileEndOffset;
    node.flags = flags;
    List<Expression> annotations = readAnnotationList(node);
    assert(() {
      debugPath.add(name);
      return true;
    }());

    assert(typeParameterStack.length == 0);

    readAndPushTypeParameterList(node.typeParameters, node);
    Supertype? supertype = readSupertypeOption();
    Supertype? mixedInType = readSupertypeOption();
    _fillNonTreeNodeList(node.implementedTypes, readSupertype);
    if (_disableLazyClassReading) {
      readClassPartialContent(node, procedureOffsets);
    } else {
      _setLazyLoadClass(node, procedureOffsets);
    }

    typeParameterStack.length = 0;
    // ignore: unnecessary_null_comparison
    assert(debugPath.removeLast() != null);
    node.name = name;
    node.fileUri = fileUri;
    node.annotations = annotations;
    node.supertype = supertype;
    node.mixedInType = mixedInType;

    _byteOffset = endOffset;

    return node;
  }

  Extension readExtension() {
    int tag = readByte();
    assert(tag == Tag.Extension);

    CanonicalName canonicalName = readNonNullCanonicalNameReference();
    Reference reference = canonicalName.reference;
    Extension? node = reference.node as Extension?;
    if (alwaysCreateNewNamedNodes) {
      node = null;
    }

    String name = readStringReference();
    if (node == null) {
      node = new Extension(name: name, reference: reference);
    }
    assert(() {
      debugPath.add(name);
      return true;
    }());

    node.annotations = readAnnotationList(node);

    Uri? fileUri = readUriReference();
    node.fileOffset = readOffset();

    readAndPushTypeParameterList(node.typeParameters, node);
    DartType onType = readDartType();
    typeParameterStack.length = 0;

    node.name = name;
    node.fileUri = fileUri;
    node.onType = onType;

    int length = readUInt30();
    node.members.length = length;
    for (int i = 0; i < length; i++) {
      Name name = readName();
      int kind = readByte();
      int flags = readByte();
      CanonicalName canonicalName = readNonNullCanonicalNameReference();
      node.members[i] = new ExtensionMemberDescriptor(
          name: name,
          kind: ExtensionMemberKind.values[kind],
          member: canonicalName.reference)
        ..flags = flags;
    }
    return node;
  }

  /// Reads the partial content of a class, namely fields, procedures,
  /// constructors and redirecting factory constructors.
  void readClassPartialContent(Class node, List<int> procedureOffsets) {
    _mergeNamedNodeList(node.fieldsInternal, (index) => readField(), node);
    _mergeNamedNodeList(
        node.constructorsInternal, (index) => readConstructor(), node);

    _mergeNamedNodeList(node.proceduresInternal, (index) {
      _byteOffset = procedureOffsets[index];
      return readProcedure(procedureOffsets[index + 1]);
    }, node);
    _byteOffset = procedureOffsets.last;
    _mergeNamedNodeList(node.redirectingFactoryConstructorsInternal,
        (index) => readRedirectingFactoryConstructor(), node);
  }

  /// Set the lazyBuilder on the class so it can be lazy loaded in the future.
  void _setLazyLoadClass(Class node, List<int> procedureOffsets) {
    final int savedByteOffset = _byteOffset;
    final int componentStartOffset = _componentStartOffset;
    final Library? currentLibrary = _currentLibrary;
    node.lazyBuilder = () {
      _byteOffset = savedByteOffset;
      _currentLibrary = currentLibrary;
      assert(typeParameterStack.isEmpty);
      _componentStartOffset = componentStartOffset;
      typeParameterStack.addAll(node.typeParameters);

      readClassPartialContent(node, procedureOffsets);
      typeParameterStack.length = 0;
    };
  }

  int getAndResetTransformerFlags() {
    int flags = _transformerFlags;
    _transformerFlags = 0;
    return flags;
  }

  /// Adds the given flag to the current [Member.transformerFlags].
  void addTransformerFlag(int flags) {
    _transformerFlags |= flags;
  }

  Field readField() {
    int tag = readByte();
    assert(tag == Tag.Field);
    CanonicalName getterCanonicalName = readNonNullCanonicalNameReference();
    Reference getterReference = getterCanonicalName.reference;
    CanonicalName? setterCanonicalName = readNullableCanonicalNameReference();
    Reference? setterReference = setterCanonicalName?.reference;
    Field? node = getterReference.node as Field?;
    if (alwaysCreateNewNamedNodes) {
      node = null;
    }
    Uri? fileUri = readUriReference();
    int fileOffset = readOffset();
    int fileEndOffset = readOffset();
    int flags = readUInt30();
    Name name = readName();
    if (node == null) {
      if (setterReference != null) {
        node = new Field.mutable(name,
            getterReference: getterReference, setterReference: setterReference);
      } else {
        node = new Field.immutable(name, getterReference: getterReference);
      }
    }
    List<Expression> annotations = readAnnotationList(node);
    assert(() {
      debugPath.add(name.text);
      return true;
    }());
    DartType type = readDartType();
    Expression? initializer = readExpressionOption();
    int transformerFlags = getAndResetTransformerFlags();
    assert(((_) => true)(debugPath.removeLast()));
    node.fileOffset = fileOffset;
    node.fileEndOffset = fileEndOffset;
    node.flags = flags;
    node.name = name;
    node.fileUri = fileUri;
    node.annotations = annotations;
    node.type = type;
    node.initializer = initializer;
    node.initializer?.parent = node;
    node.transformerFlags = transformerFlags;
    return node;
  }

  Constructor readConstructor() {
    int tag = readByte();
    assert(tag == Tag.Constructor);
    CanonicalName canonicalName = readNonNullCanonicalNameReference();
    Reference reference = canonicalName.reference;
    Constructor? node = reference.node as Constructor?;
    if (alwaysCreateNewNamedNodes) {
      node = null;
    }
    Uri? fileUri = readUriReference();
    int startFileOffset = readOffset();
    int fileOffset = readOffset();
    int fileEndOffset = readOffset();
    int flags = readByte();
    Name name = readName();
    List<Expression> annotations = readAnnotationList();
    assert(() {
      debugPath.add(name.text);
      return true;
    }());
    FunctionNode function = readFunctionNode();
    if (node == null) {
      node = new Constructor(function, reference: reference, name: name);
    }
    pushVariableDeclarations(function.positionalParameters);
    pushVariableDeclarations(function.namedParameters);
    _fillTreeNodeList(node.initializers, (index) => readInitializer(), node);
    variableStack.length = 0;
    int transformerFlags = getAndResetTransformerFlags();
    assert(((_) => true)(debugPath.removeLast()));
    node.startFileOffset = startFileOffset;
    node.fileOffset = fileOffset;
    node.fileEndOffset = fileEndOffset;
    node.flags = flags;
    node.name = name;
    node.fileUri = fileUri;
    node.annotations = annotations;
    setParents(annotations, node);
    node.function = function..parent = node;
    node.transformerFlags = transformerFlags;
    return node;
  }

  Procedure readProcedure(int endOffset) {
    int tag = readByte();
    assert(tag == Tag.Procedure);
    CanonicalName canonicalName = readNonNullCanonicalNameReference();
    Reference reference = canonicalName.reference;
    Procedure? node = reference.node as Procedure?;
    if (alwaysCreateNewNamedNodes) {
      node = null;
    }
    Uri? fileUri = readUriReference();
    int startFileOffset = readOffset();
    int fileOffset = readOffset();
    int fileEndOffset = readOffset();
    int kindIndex = readByte();
    ProcedureKind kind = ProcedureKind.values[kindIndex];
    ProcedureStubKind stubKind = ProcedureStubKind.values[readByte()];
    int flags = readUInt30();
    Name name = readName();
    List<Expression> annotations = readAnnotationList();
    assert(() {
      debugPath.add(name.text);
      return true;
    }());
    int functionNodeSize = endOffset - _byteOffset;
    // Read small factories up front. Postpone everything else.
    bool readFunctionNodeNow =
        (kind == ProcedureKind.Factory && functionNodeSize <= 50) ||
            _disableLazyReading;
    Reference? stubTargetReference = readNullableMemberReference();
    FunctionNode function = readFunctionNode(
        lazyLoadBody: !readFunctionNodeNow, outerEndOffset: endOffset);
    if (node == null) {
      node = new Procedure(name, kind, function, reference: reference);
    } else {
      assert(node.kind == kind);
    }
    int transformerFlags = getAndResetTransformerFlags();
    assert(((_) => true)(debugPath.removeLast()));
    node.startFileOffset = startFileOffset;
    node.fileOffset = fileOffset;
    node.fileEndOffset = fileEndOffset;
    node.flags = flags;
    node.name = name;
    node.fileUri = fileUri;
    node.annotations = annotations;
    setParents(annotations, node);
    node.function = function..parent = node;
    node.setTransformerFlagsWithoutLazyLoading(transformerFlags);
    node.stubKind = stubKind;
    node.stubTargetReference = stubTargetReference;

    assert((node.stubKind == ProcedureStubKind.ConcreteForwardingStub &&
            node.stubTargetReference != null) ||
        !(node.isForwardingStub && node.function.body != null));
    assert(!(node.isMemberSignature && node.stubTargetReference == null),
        "No member signature origin for member signature $node.");
    return node;
  }

  RedirectingFactoryConstructor readRedirectingFactoryConstructor() {
    int tag = readByte();
    assert(tag == Tag.RedirectingFactoryConstructor);
    CanonicalName canonicalName = readNonNullCanonicalNameReference();
    Reference reference = canonicalName.reference;
    RedirectingFactoryConstructor? node =
        reference.node as RedirectingFactoryConstructor?;
    if (alwaysCreateNewNamedNodes) {
      node = null;
    }
    Uri? fileUri = readUriReference();
    int fileOffset = readOffset();
    int fileEndOffset = readOffset();
    int flags = readByte();
    Name name = readName();
    if (node == null) {
      node = new RedirectingFactoryConstructor(null,
          reference: reference, name: name);
    }
    List<Expression> annotations = readAnnotationList(node);
    assert(() {
      debugPath.add(name.text);
      return true;
    }());
    Reference targetReference = readNonNullMemberReference();
    List<DartType> typeArguments = readDartTypeList();
    int typeParameterStackHeight = typeParameterStack.length;
    List<TypeParameter> typeParameters = readAndPushTypeParameterList();
    readUInt30(); // Total parameter count.
    int requiredParameterCount = readUInt30();
    int variableStackHeight = variableStack.length;
    List<VariableDeclaration> positional = readAndPushVariableDeclarationList();
    List<VariableDeclaration> named = readAndPushVariableDeclarationList();
    variableStack.length = variableStackHeight;
    typeParameterStack.length = typeParameterStackHeight;
    debugPath.removeLast();
    node.fileOffset = fileOffset;
    node.fileEndOffset = fileEndOffset;
    node.flags = flags;
    node.name = name;
    node.fileUri = fileUri;
    node.annotations = annotations;
    node.targetReference = targetReference;
    node.typeArguments.addAll(typeArguments);
    node.typeParameters = typeParameters;
    node.requiredParameterCount = requiredParameterCount;
    node.positionalParameters = positional;
    node.namedParameters = named;
    return node;
  }

  Initializer readInitializer() {
    int tag = readByte();
    bool isSynthetic = readByte() == 1;
    switch (tag) {
      case Tag.InvalidInitializer:
        return _readInvalidInitializer();
      case Tag.FieldInitializer:
        return _readFieldInitializer(isSynthetic);
      case Tag.SuperInitializer:
        return _readSuperInitializer(isSynthetic);
      case Tag.RedirectingInitializer:
        return _readRedirectingInitializer();
      case Tag.LocalInitializer:
        return _readLocalInitializer();
      case Tag.AssertInitializer:
        return _readAssertInitializer();
      default:
        throw fail('unexpected initializer tag: $tag');
    }
  }

  Initializer _readInvalidInitializer() {
    return new InvalidInitializer();
  }

  Initializer _readFieldInitializer(bool isSynthetic) {
    Reference reference = readNonNullMemberReference();
    Expression value = readExpression();
    return new FieldInitializer.byReference(reference, value)
      ..isSynthetic = isSynthetic;
  }

  Initializer _readSuperInitializer(bool isSynthetic) {
    int offset = readOffset();
    Reference reference = readNonNullMemberReference();
    Arguments arguments = readArguments();
    return new SuperInitializer.byReference(reference, arguments)
      ..isSynthetic = isSynthetic
      ..fileOffset = offset;
  }

  Initializer _readRedirectingInitializer() {
    int offset = readOffset();
    return new RedirectingInitializer.byReference(
        readNonNullMemberReference(), readArguments())
      ..fileOffset = offset;
  }

  Initializer _readLocalInitializer() {
    return new LocalInitializer(readAndPushVariableDeclaration());
  }

  Initializer _readAssertInitializer() {
    return new AssertInitializer(readStatement() as AssertStatement);
  }

  FunctionNode readFunctionNode(
      {bool lazyLoadBody: false, int outerEndOffset: -1}) {
    int tag = readByte();
    assert(tag == Tag.FunctionNode);
    int offset = readOffset();
    int endOffset = readOffset();
    AsyncMarker asyncMarker = AsyncMarker.values[readByte()];
    AsyncMarker dartAsyncMarker = AsyncMarker.values[readByte()];
    int typeParameterStackHeight = typeParameterStack.length;
    List<TypeParameter> typeParameters = readAndPushTypeParameterList();
    readUInt30(); // total parameter count.
    int requiredParameterCount = readUInt30();
    int variableStackHeight = variableStack.length;
    List<VariableDeclaration> positional = readAndPushVariableDeclarationList();
    List<VariableDeclaration> named = readAndPushVariableDeclarationList();
    DartType returnType = readDartType();
    DartType? futureValueType = readDartTypeOption();
    int oldLabelStackBase = labelStackBase;
    int oldSwitchCaseStackBase = switchCaseStackBase;

    if (lazyLoadBody && outerEndOffset > 0) {
      lazyLoadBody = outerEndOffset - _byteOffset >
          2; // e.g. outline has Tag.Something and Tag.EmptyStatement
    }

    Statement? body;
    if (!lazyLoadBody) {
      labelStackBase = labelStack.length;
      switchCaseStackBase = switchCaseStack.length;
      body = readStatementOption();
    }

    FunctionNode result = new FunctionNode(body,
        typeParameters: typeParameters,
        requiredParameterCount: requiredParameterCount,
        positionalParameters: positional,
        namedParameters: named,
        returnType: returnType,
        asyncMarker: asyncMarker,
        dartAsyncMarker: dartAsyncMarker,
        futureValueType: futureValueType)
      ..fileOffset = offset
      ..fileEndOffset = endOffset;

    if (lazyLoadBody) {
      _setLazyLoadFunction(result, oldLabelStackBase, oldSwitchCaseStackBase,
          variableStackHeight);
    }

    labelStackBase = oldLabelStackBase;
    switchCaseStackBase = oldSwitchCaseStackBase;
    variableStack.length = variableStackHeight;
    typeParameterStack.length = typeParameterStackHeight;

    return result;
  }

  void _setLazyLoadFunction(FunctionNode result, int oldLabelStackBase,
      int oldSwitchCaseStackBase, int variableStackHeight) {
    final int savedByteOffset = _byteOffset;
    final int componentStartOffset = _componentStartOffset;
    final List<TypeParameter> typeParameters = typeParameterStack.toList();
    final List<VariableDeclaration> variables = variableStack.toList();
    final Library currentLibrary = _currentLibrary!;
    result.lazyBuilder = () {
      _byteOffset = savedByteOffset;
      _currentLibrary = currentLibrary;
      typeParameterStack.clear();
      typeParameterStack.addAll(typeParameters);
      variableStack.clear();
      variableStack.addAll(variables);
      _componentStartOffset = componentStartOffset;

      result.body = readStatementOption();
      result.body?.parent = result;
      labelStackBase = oldLabelStackBase;
      switchCaseStackBase = oldSwitchCaseStackBase;
      variableStack.length = variableStackHeight;
      typeParameterStack.clear();
      TreeNode? parent = result.parent;
      if (parent is Procedure) {
        parent.transformerFlags |= getAndResetTransformerFlags();
      }
    };
  }

  void pushVariableDeclaration(VariableDeclaration variable) {
    variableStack.add(variable);
  }

  void pushVariableDeclarations(List<VariableDeclaration> variables) {
    variableStack.addAll(variables);
  }

  VariableDeclaration readVariableReference() {
    int index = readUInt30();
    if (index >= variableStack.length) {
      throw fail('Unexpected variable index: $index. '
          'Current variable count: ${variableStack.length}.');
    }
    return variableStack[index];
  }

  LogicalExpressionOperator logicalOperatorToEnum(int index) {
    switch (index) {
      case 0:
        return LogicalExpressionOperator.AND;
      case 1:
        return LogicalExpressionOperator.OR;
      default:
        throw fail('unexpected logical operator index: $index');
    }
  }

  List<Expression> readExpressionList() {
    int length = readUInt30();
    if (!useGrowableLists && length == 0) {
      // When lists don't have to be growable anyway, we might as well use a
      // constant one for the empty list.
      return emptyListOfExpression;
    }
    return new List<Expression>.generate(length, (_) => readExpression(),
        growable: useGrowableLists);
  }

  Expression? readExpressionOption() {
    return readAndCheckOptionTag() ? readExpression() : null;
  }

  Expression readExpression() {
    int tagByte = readByte();
    int tag = tagByte & Tag.SpecializedTagHighBit == 0
        ? tagByte
        : (tagByte & Tag.SpecializedTagMask);
    switch (tag) {
      case Tag.LoadLibrary:
        return _readLoadLibrary();
      case Tag.CheckLibraryIsLoaded:
        return _readCheckLibraryIsLoaded();
      case Tag.InvalidExpression:
        return _readInvalidExpression();
      case Tag.VariableGet:
        return _readVariableGet();
      case Tag.SpecializedVariableGet:
        return _readSpecializedVariableGet(tagByte);
      case Tag.VariableSet:
        return _readVariableSet();
      case Tag.SpecializedVariableSet:
        return _readSpecializedVariableSet(tagByte);
      case Tag.PropertyGet:
        return _readPropertyGet();
      case Tag.InstanceGet:
        return _readInstanceGet();
      case Tag.InstanceTearOff:
        return _readInstanceTearOff();
      case Tag.DynamicGet:
        return _readDynamicGet();
      case Tag.PropertySet:
        return _readPropertySet();
      case Tag.InstanceSet:
        return _readInstanceSet();
      case Tag.DynamicSet:
        return _readDynamicSet();
      case Tag.SuperPropertyGet:
        return _readSuperPropertyGet();
      case Tag.SuperPropertySet:
        return _readSuperPropertySet();
      case Tag.StaticGet:
        return _readStaticGet();
      case Tag.StaticTearOff:
        return _readStaticTearOff();
      case Tag.StaticSet:
        return _readStaticSet();
      case Tag.MethodInvocation:
        return _readMethodInvocation();
      case Tag.InstanceInvocation:
        return _readInstanceInvocation();
      case Tag.InstanceGetterInvocation:
        return _readInstanceGetterInvocation();
      case Tag.DynamicInvocation:
        return _readDynamicInvocation();
      case Tag.FunctionInvocation:
        return _readFunctionInvocation();
      case Tag.FunctionTearOff:
        return _readFunctionTearOff();
      case Tag.LocalFunctionInvocation:
        return _readLocalFunctionInvocation();
      case Tag.EqualsNull:
        return _readEqualsNull();
      case Tag.EqualsCall:
        return _readEqualsCall();
      case Tag.SuperMethodInvocation:
        return _readSuperMethodInvocation();
      case Tag.StaticInvocation:
        return _readStaticInvocation();
      case Tag.ConstStaticInvocation:
        return _readConstStaticInvocation();
      case Tag.ConstructorInvocation:
        return _readConstructorInvocation();
      case Tag.ConstConstructorInvocation:
        return _readConstConstructorInvocation();
      case Tag.Not:
        return _readNot();
      case Tag.NullCheck:
        return _readNullCheck();
      case Tag.LogicalExpression:
        return _readLogicalExpression();
      case Tag.ConditionalExpression:
        return _readConditionalExpression();
      case Tag.StringConcatenation:
        return _readStringConcatenation();
      case Tag.ListConcatenation:
        return _readListConcatenation();
      case Tag.SetConcatenation:
        return _readSetConcatenation();
      case Tag.MapConcatenation:
        return _readMapConcatenation();
      case Tag.InstanceCreation:
        return _readInstanceCreation();
      case Tag.FileUriExpression:
        return _readFileUriExpression();
      case Tag.IsExpression:
        return _readIsExpression();
      case Tag.AsExpression:
        return _readAsExpression();
      case Tag.StringLiteral:
        return _readStringLiteral();
      case Tag.SpecializedIntLiteral:
        return _readSpecializedIntLiteral(tagByte);
      case Tag.PositiveIntLiteral:
        return _readPositiveIntLiteral();
      case Tag.NegativeIntLiteral:
        return _readNegativeIntLiteral();
      case Tag.BigIntLiteral:
        return _readBigIntLiteral();
      case Tag.DoubleLiteral:
        return _readDoubleLiteral();
      case Tag.TrueLiteral:
        return _readTrueLiteral();
      case Tag.FalseLiteral:
        return _readFalseLiteral();
      case Tag.NullLiteral:
        return _readNullLiteral();
      case Tag.SymbolLiteral:
        return _readSymbolLiteral();
      case Tag.TypeLiteral:
        return _readTypeLiteral();
      case Tag.ThisExpression:
        return _readThisLiteral();
      case Tag.Rethrow:
        return _readRethrow();
      case Tag.Throw:
        return _readThrow();
      case Tag.ListLiteral:
        return _readListLiteral();
      case Tag.ConstListLiteral:
        return _readConstListLiteral();
      case Tag.SetLiteral:
        return _readSetLiteral();
      case Tag.ConstSetLiteral:
        return _readConstSetLiteral();
      case Tag.MapLiteral:
        return _readMapLiteral();
      case Tag.ConstMapLiteral:
        return _readConstMapLiteral();
      case Tag.AwaitExpression:
        return _readAwaitExpression();
      case Tag.FunctionExpression:
        return _readFunctionExpression();
      case Tag.Let:
        return _readLet();
      case Tag.BlockExpression:
        return _readBlockExpression();
      case Tag.Instantiation:
        return _readInstantiation();
      case Tag.ConstantExpression:
        return _readConstantExpression();
      default:
        throw fail('unexpected expression tag: $tag');
    }
  }

  Expression _readLoadLibrary() {
    return new LoadLibrary(readLibraryDependencyReference());
  }

  Expression _readCheckLibraryIsLoaded() {
    return new CheckLibraryIsLoaded(readLibraryDependencyReference());
  }

  Expression _readInvalidExpression() {
    int offset = readOffset();
    return new InvalidExpression(readStringOrNullIfEmpty())
      ..fileOffset = offset;
  }

  Expression _readVariableGet() {
    int offset = readOffset();
    readUInt30(); // offset of the variable declaration in the binary.
    return new VariableGet(readVariableReference(), readDartTypeOption())
      ..fileOffset = offset;
  }

  Expression _readSpecializedVariableGet(int tagByte) {
    int index = tagByte & Tag.SpecializedPayloadMask;
    int offset = readOffset();
    readUInt30(); // offset of the variable declaration in the binary.
    return new VariableGet(variableStack[index])..fileOffset = offset;
  }

  Expression _readVariableSet() {
    int offset = readOffset();
    readUInt30(); // offset of the variable declaration in the binary.
    return new VariableSet(readVariableReference(), readExpression())
      ..fileOffset = offset;
  }

  Expression _readSpecializedVariableSet(int tagByte) {
    int index = tagByte & Tag.SpecializedPayloadMask;
    int offset = readOffset();
    readUInt30(); // offset of the variable declaration in the binary.
    return new VariableSet(variableStack[index], readExpression())
      ..fileOffset = offset;
  }

  Expression _readPropertyGet() {
    int offset = readOffset();
    return new PropertyGet.byReference(
        readExpression(), readName(), readNullableInstanceMemberReference())
      ..fileOffset = offset;
  }

  Expression _readInstanceGet() {
    InstanceAccessKind kind = InstanceAccessKind.values[readByte()];
    int offset = readOffset();
    return new InstanceGet.byReference(kind, readExpression(), readName(),
        resultType: readDartType(),
        interfaceTargetReference: readNonNullInstanceMemberReference())
      ..fileOffset = offset;
  }

  Expression _readInstanceTearOff() {
    InstanceAccessKind kind = InstanceAccessKind.values[readByte()];
    int offset = readOffset();
    return new InstanceTearOff.byReference(kind, readExpression(), readName(),
        resultType: readDartType(),
        interfaceTargetReference: readNonNullInstanceMemberReference())
      ..fileOffset = offset;
  }

  Expression _readDynamicGet() {
    DynamicAccessKind kind = DynamicAccessKind.values[readByte()];
    int offset = readOffset();
    return new DynamicGet(kind, readExpression(), readName())
      ..fileOffset = offset;
  }

  Expression _readPropertySet() {
    int offset = readOffset();
    return new PropertySet.byReference(readExpression(), readName(),
        readExpression(), readNullableInstanceMemberReference())
      ..fileOffset = offset;
  }

  Expression _readInstanceSet() {
    InstanceAccessKind kind = InstanceAccessKind.values[readByte()];
    int offset = readOffset();
    return new InstanceSet.byReference(
        kind, readExpression(), readName(), readExpression(),
        interfaceTargetReference: readNonNullInstanceMemberReference())
      ..fileOffset = offset;
  }

  Expression _readDynamicSet() {
    DynamicAccessKind kind = DynamicAccessKind.values[readByte()];
    int offset = readOffset();
    return new DynamicSet(kind, readExpression(), readName(), readExpression())
      ..fileOffset = offset;
  }

  Expression _readSuperPropertyGet() {
    int offset = readOffset();
    addTransformerFlag(TransformerFlag.superCalls);
    return new SuperPropertyGet.byReference(
        readName(), readNullableInstanceMemberReference())
      ..fileOffset = offset;
  }

  Expression _readSuperPropertySet() {
    int offset = readOffset();
    addTransformerFlag(TransformerFlag.superCalls);
    return new SuperPropertySet.byReference(
        readName(), readExpression(), readNullableInstanceMemberReference())
      ..fileOffset = offset;
  }

  Expression _readStaticGet() {
    int offset = readOffset();
    return new StaticGet.byReference(readNonNullMemberReference())
      ..fileOffset = offset;
  }

  Expression _readStaticTearOff() {
    int offset = readOffset();
    return new StaticTearOff.byReference(readNonNullMemberReference())
      ..fileOffset = offset;
  }

  Expression _readStaticSet() {
    int offset = readOffset();
    return new StaticSet.byReference(
        readNonNullMemberReference(), readExpression())
      ..fileOffset = offset;
  }

  Expression _readMethodInvocation() {
    int flags = readByte();
    int offset = readOffset();
    return new MethodInvocation.byReference(readExpression(), readName(),
        readArguments(), readNullableInstanceMemberReference())
      ..fileOffset = offset
      ..flags = flags;
  }

  Expression _readInstanceInvocation() {
    InstanceAccessKind kind = InstanceAccessKind.values[readByte()];
    int flags = readByte();
    int offset = readOffset();
    return new InstanceInvocation.byReference(
        kind, readExpression(), readName(), readArguments(),
        functionType: readDartType() as FunctionType,
        interfaceTargetReference: readNonNullInstanceMemberReference())
      ..fileOffset = offset
      ..flags = flags;
  }

  Expression _readInstanceGetterInvocation() {
    InstanceAccessKind kind = InstanceAccessKind.values[readByte()];
    int flags = readByte();
    int offset = readOffset();
    Expression receiver = readExpression();
    Name name = readName();
    Arguments arguments = readArguments();
    DartType functionType = readDartType();
    // `const DynamicType()` is used to encode a missing function type.
    assert(functionType is FunctionType || functionType is DynamicType,
        "Unexpected function type $functionType for InstanceGetterInvocation");
    Reference interfaceTargetReference = readNonNullInstanceMemberReference();
    return new InstanceGetterInvocation.byReference(
        kind, receiver, name, arguments,
        functionType: functionType is FunctionType ? functionType : null,
        interfaceTargetReference: interfaceTargetReference)
      ..fileOffset = offset
      ..flags = flags;
  }

  Expression _readDynamicInvocation() {
    DynamicAccessKind kind = DynamicAccessKind.values[readByte()];
    int offset = readOffset();
    return new DynamicInvocation(
        kind, readExpression(), readName(), readArguments())
      ..fileOffset = offset;
  }

  Expression _readFunctionInvocation() {
    FunctionAccessKind kind = FunctionAccessKind.values[readByte()];
    int offset = readOffset();
    Expression receiver = readExpression();
    Arguments arguments = readArguments();
    DartType functionType = readDartType();
    // `const DynamicType()` is used to encode a missing function type.
    assert(functionType is FunctionType || functionType is DynamicType,
        "Unexpected function type $functionType for FunctionInvocation");
    return new FunctionInvocation(kind, receiver, arguments,
        functionType: functionType is FunctionType ? functionType : null)
      ..fileOffset = offset;
  }

  Expression _readFunctionTearOff() {
    int offset = readOffset();
    return new FunctionTearOff(readExpression())..fileOffset = offset;
  }

  Expression _readLocalFunctionInvocation() {
    int offset = readOffset();
    readUInt30(); // offset of the variable declaration in the binary.
    VariableDeclaration variable = readVariableReference();
    return new LocalFunctionInvocation(variable, readArguments(),
        functionType: readDartType() as FunctionType)
      ..fileOffset = offset;
  }

  Expression _readEqualsNull() {
    int offset = readOffset();
    return new EqualsNull(readExpression())..fileOffset = offset;
  }

  Expression _readEqualsCall() {
    int offset = readOffset();
    return new EqualsCall.byReference(readExpression(), readExpression(),
        functionType: readDartType() as FunctionType,
        interfaceTargetReference: readNonNullInstanceMemberReference())
      ..fileOffset = offset;
  }

  Expression _readSuperMethodInvocation() {
    int offset = readOffset();
    addTransformerFlag(TransformerFlag.superCalls);
    return new SuperMethodInvocation.byReference(
        readName(), readArguments(), readNullableInstanceMemberReference())
      ..fileOffset = offset;
  }

  Expression _readStaticInvocation() {
    int offset = readOffset();
    return new StaticInvocation.byReference(
        readNonNullMemberReference(), readArguments(),
        isConst: false)
      ..fileOffset = offset;
  }

  Expression _readConstStaticInvocation() {
    int offset = readOffset();
    return new StaticInvocation.byReference(
        readNonNullMemberReference(), readArguments(),
        isConst: true)
      ..fileOffset = offset;
  }

  Expression _readConstructorInvocation() {
    int offset = readOffset();
    return new ConstructorInvocation.byReference(
        readNonNullMemberReference(), readArguments(),
        isConst: false)
      ..fileOffset = offset;
  }

  Expression _readConstConstructorInvocation() {
    int offset = readOffset();
    return new ConstructorInvocation.byReference(
        readNonNullMemberReference(), readArguments(),
        isConst: true)
      ..fileOffset = offset;
  }

  Expression _readNot() {
    return new Not(readExpression());
  }

  Expression _readNullCheck() {
    int offset = readOffset();
    return new NullCheck(readExpression())..fileOffset = offset;
  }

  Expression _readLogicalExpression() {
    return new LogicalExpression(
        readExpression(), logicalOperatorToEnum(readByte()), readExpression());
  }

  Expression _readConditionalExpression() {
    return new ConditionalExpression(
        readExpression(),
        readExpression(),
        readExpression(),
        // TODO(johnniwinther): Change this to use `readDartType`.
        readDartTypeOption()!);
  }

  Expression _readStringConcatenation() {
    int offset = readOffset();
    return new StringConcatenation(readExpressionList())..fileOffset = offset;
  }

  Expression _readListConcatenation() {
    int offset = readOffset();
    DartType typeArgument = readDartType();
    return new ListConcatenation(readExpressionList(),
        typeArgument: typeArgument)
      ..fileOffset = offset;
  }

  Expression _readSetConcatenation() {
    int offset = readOffset();
    DartType typeArgument = readDartType();
    return new SetConcatenation(readExpressionList(),
        typeArgument: typeArgument)
      ..fileOffset = offset;
  }

  Expression _readMapConcatenation() {
    int offset = readOffset();
    DartType keyType = readDartType();
    DartType valueType = readDartType();
    return new MapConcatenation(readExpressionList(),
        keyType: keyType, valueType: valueType)
      ..fileOffset = offset;
  }

  Expression _readInstanceCreation() {
    int offset = readOffset();
    Reference classReference = readNonNullClassReference();
    List<DartType> typeArguments = readDartTypeList();
    int fieldValueCount = readUInt30();
    Map<Reference, Expression> fieldValues = <Reference, Expression>{};
    for (int i = 0; i < fieldValueCount; i++) {
      final Reference fieldRef = readNonNullCanonicalNameReference().reference;
      final Expression value = readExpression();
      fieldValues[fieldRef] = value;
    }
    int assertCount = readUInt30();
    List<AssertStatement> asserts;

    if (!useGrowableLists && assertCount == 0) {
      // When lists don't have to be growable anyway, we might as well use an
      // almost constant one for the empty list.
      asserts = emptyListOfAssertStatement;
    } else {
      asserts = new List<AssertStatement>.generate(
          assertCount, (_) => readStatement() as AssertStatement,
          growable: false);
    }
    List<Expression> unusedArguments = readExpressionList();
    return new InstanceCreation(
        classReference, typeArguments, fieldValues, asserts, unusedArguments)
      ..fileOffset = offset;
  }

  Expression _readFileUriExpression() {
    Uri fileUri = readUriReference()!;
    int offset = readOffset();
    return new FileUriExpression(readExpression(), fileUri)
      ..fileOffset = offset;
  }

  Expression _readIsExpression() {
    int offset = readOffset();
    int flags = readByte();
    return new IsExpression(readExpression(), readDartType())
      ..fileOffset = offset
      ..flags = flags;
  }

  Expression _readAsExpression() {
    int offset = readOffset();
    int flags = readByte();
    return new AsExpression(readExpression(), readDartType())
      ..fileOffset = offset
      ..flags = flags;
  }

  Expression _readStringLiteral() {
    return new StringLiteral(readStringReference());
  }

  Expression _readSpecializedIntLiteral(int tagByte) {
    int biasedValue = tagByte & Tag.SpecializedPayloadMask;
    return new IntLiteral(biasedValue - Tag.SpecializedIntLiteralBias);
  }

  Expression _readPositiveIntLiteral() {
    return new IntLiteral(readUInt30());
  }

  Expression _readNegativeIntLiteral() {
    return new IntLiteral(-readUInt30());
  }

  Expression _readBigIntLiteral() {
    return new IntLiteral(int.parse(readStringReference()));
  }

  Expression _readDoubleLiteral() {
    return new DoubleLiteral(readDouble());
  }

  Expression _readTrueLiteral() {
    return new BoolLiteral(true);
  }

  Expression _readFalseLiteral() {
    return new BoolLiteral(false);
  }

  Expression _readNullLiteral() {
    return new NullLiteral();
  }

  Expression _readSymbolLiteral() {
    return new SymbolLiteral(readStringReference());
  }

  Expression _readTypeLiteral() {
    return new TypeLiteral(readDartType());
  }

  Expression _readThisLiteral() {
    return new ThisExpression();
  }

  Expression _readRethrow() {
    int offset = readOffset();
    return new Rethrow()..fileOffset = offset;
  }

  Expression _readThrow() {
    int offset = readOffset();
    return new Throw(readExpression())..fileOffset = offset;
  }

  Expression _readListLiteral() {
    int offset = readOffset();
    DartType typeArgument = readDartType();
    return new ListLiteral(readExpressionList(),
        typeArgument: typeArgument, isConst: false)
      ..fileOffset = offset;
  }

  Expression _readConstListLiteral() {
    int offset = readOffset();
    DartType typeArgument = readDartType();
    return new ListLiteral(readExpressionList(),
        typeArgument: typeArgument, isConst: true)
      ..fileOffset = offset;
  }

  Expression _readSetLiteral() {
    int offset = readOffset();
    DartType typeArgument = readDartType();
    return new SetLiteral(readExpressionList(),
        typeArgument: typeArgument, isConst: false)
      ..fileOffset = offset;
  }

  Expression _readConstSetLiteral() {
    int offset = readOffset();
    DartType typeArgument = readDartType();
    return new SetLiteral(readExpressionList(),
        typeArgument: typeArgument, isConst: true)
      ..fileOffset = offset;
  }

  Expression _readMapLiteral() {
    int offset = readOffset();
    DartType keyType = readDartType();
    DartType valueType = readDartType();
    return new MapLiteral(readMapEntryList(),
        keyType: keyType, valueType: valueType, isConst: false)
      ..fileOffset = offset;
  }

  Expression _readConstMapLiteral() {
    int offset = readOffset();
    DartType keyType = readDartType();
    DartType valueType = readDartType();
    return new MapLiteral(readMapEntryList(),
        keyType: keyType, valueType: valueType, isConst: true)
      ..fileOffset = offset;
  }

  Expression _readAwaitExpression() {
    return new AwaitExpression(readExpression());
  }

  Expression _readFunctionExpression() {
    int offset = readOffset();
    return new FunctionExpression(readFunctionNode())..fileOffset = offset;
  }

  Expression _readLet() {
    int offset = readOffset();
    VariableDeclaration variable = readVariableDeclaration();
    int stackHeight = variableStack.length;
    pushVariableDeclaration(variable);
    Expression body = readExpression();
    variableStack.length = stackHeight;
    return new Let(variable, body)..fileOffset = offset;
  }

  Expression _readBlockExpression() {
    int stackHeight = variableStack.length;
    List<Statement> statements = readStatementListAlwaysGrowable();
    Expression value = readExpression();
    variableStack.length = stackHeight;
    return new BlockExpression(new Block(statements), value);
  }

  Expression _readInstantiation() {
    Expression expression = readExpression();
    List<DartType> typeArguments = readDartTypeList();
    return new Instantiation(expression, typeArguments);
  }

  Expression _readConstantExpression() {
    int offset = readOffset();
    DartType type = readDartType();
    Constant constant = readConstantReference();
    return new ConstantExpression(constant, type)..fileOffset = offset;
  }

  List<MapEntry> readMapEntryList() {
    int length = readUInt30();
    return new List<MapEntry>.generate(length, (_) => readMapEntry(),
        growable: useGrowableLists);
  }

  MapEntry readMapEntry() {
    return new MapEntry(readExpression(), readExpression());
  }

  List<Statement> readStatementList() {
    int length = readUInt30();
    if (!useGrowableLists && length == 0) {
      // When lists don't have to be growable anyway, we might as well use an
      // almost constant one for the empty list.
      return emptyListOfStatement;
    }
    return new List<Statement>.generate(length, (_) => readStatement(),
        growable: useGrowableLists);
  }

  List<Statement> readStatementListAlwaysGrowable() {
    int length = readUInt30();
    return new List<Statement>.generate(length, (_) => readStatement(),
        growable: true);
  }

  Statement? readStatementOrNullIfEmpty() {
    Statement node = readStatement();
    if (node is EmptyStatement) {
      return null;
    } else {
      return node;
    }
  }

  Statement? readStatementOption() {
    return readAndCheckOptionTag() ? readStatement() : null;
  }

  Statement readStatement() {
    int tag = readByte();
    switch (tag) {
      case Tag.ExpressionStatement:
        return _readExpressionStatement();
      case Tag.Block:
        return _readBlock();
      case Tag.AssertBlock:
        return _readAssertBlock();
      case Tag.EmptyStatement:
        return _readEmptyStatement();
      case Tag.AssertStatement:
        return _readAssertStatement();
      case Tag.LabeledStatement:
        return _readLabeledStatement();
      case Tag.BreakStatement:
        return _readBreakStatement();
      case Tag.WhileStatement:
        return _readWhileStatement();
      case Tag.DoStatement:
        return _readDoStatement();
      case Tag.ForStatement:
        return _readForStatement();
      case Tag.ForInStatement:
      case Tag.AsyncForInStatement:
        return _readForInStatement(tag);
      case Tag.SwitchStatement:
        return _readSwitchStatement();
      case Tag.ContinueSwitchStatement:
        return _readContinueSwitchStatement();
      case Tag.IfStatement:
        return _readIfStatement();
      case Tag.ReturnStatement:
        return _readReturnStatement();
      case Tag.TryCatch:
        return _readTryCatch();
      case Tag.TryFinally:
        return _readTryFinally();
      case Tag.YieldStatement:
        return _readYieldStatement();
      case Tag.VariableDeclaration:
        return _readVariableDeclaration();
      case Tag.FunctionDeclaration:
        return _readFunctionDeclaration();
      default:
        throw fail('unexpected statement tag: $tag');
    }
  }

  Statement _readExpressionStatement() {
    return new ExpressionStatement(readExpression());
  }

  Statement _readEmptyStatement() {
    return new EmptyStatement();
  }

  Statement _readAssertStatement() {
    return new AssertStatement(readExpression(),
        conditionStartOffset: readOffset(),
        conditionEndOffset: readOffset(),
        message: readExpressionOption());
  }

  Statement _readLabeledStatement() {
    LabeledStatement label = new LabeledStatement(null);
    labelStack.add(label);
    label.body = readStatement()..parent = label;
    labelStack.removeLast();
    return label;
  }

  Statement _readBreakStatement() {
    int offset = readOffset();
    int index = readUInt30();
    return new BreakStatement(labelStack[labelStackBase + index])
      ..fileOffset = offset;
  }

  Statement _readWhileStatement() {
    int offset = readOffset();
    return new WhileStatement(readExpression(), readStatement())
      ..fileOffset = offset;
  }

  Statement _readDoStatement() {
    int offset = readOffset();
    return new DoStatement(readStatement(), readExpression())
      ..fileOffset = offset;
  }

  Statement _readForStatement() {
    int variableStackHeight = variableStack.length;
    int offset = readOffset();
    List<VariableDeclaration> variables = readAndPushVariableDeclarationList();
    Expression? condition = readExpressionOption();
    List<Expression> updates = readExpressionList();
    Statement body = readStatement();
    variableStack.length = variableStackHeight;
    return new ForStatement(variables, condition, updates, body)
      ..fileOffset = offset;
  }

  Statement _readForInStatement(int tag) {
    bool isAsync = tag == Tag.AsyncForInStatement;
    int variableStackHeight = variableStack.length;
    int offset = readOffset();
    int bodyOffset = readOffset();
    VariableDeclaration variable = readAndPushVariableDeclaration();
    Expression iterable = readExpression();
    Statement body = readStatement();
    variableStack.length = variableStackHeight;
    return new ForInStatement(variable, iterable, body, isAsync: isAsync)
      ..fileOffset = offset
      ..bodyOffset = bodyOffset;
  }

  Statement _readSwitchStatement() {
    int offset = readOffset();
    Expression expression = readExpression();
    int count = readUInt30();
    List<SwitchCase> cases;
    if (!useGrowableLists && count == 0) {
      // When lists don't have to be growable anyway, we might as well use an
      // almost constant one for the empty list.
      cases = emptyListOfSwitchCase;
    } else {
      cases = new List<SwitchCase>.generate(
          count,
          (_) => new SwitchCase(<Expression>[], <int>[], dummyStatement,
              isDefault: false),
          growable: useGrowableLists);
    }
    switchCaseStack.addAll(cases);
    for (int i = 0; i < cases.length; ++i) {
      _readSwitchCaseInto(cases[i]);
    }
    switchCaseStack.length -= count;
    return new SwitchStatement(expression, cases)..fileOffset = offset;
  }

  Statement _readContinueSwitchStatement() {
    int offset = readOffset();
    int index = readUInt30();
    return new ContinueSwitchStatement(
        switchCaseStack[switchCaseStackBase + index])
      ..fileOffset = offset;
  }

  Statement _readIfStatement() {
    int offset = readOffset();
    return new IfStatement(
        readExpression(), readStatement(), readStatementOrNullIfEmpty())
      ..fileOffset = offset;
  }

  Statement _readReturnStatement() {
    int offset = readOffset();
    return new ReturnStatement(readExpressionOption())..fileOffset = offset;
  }

  Statement _readTryCatch() {
    Statement body = readStatement();
    int flags = readByte();
    return new TryCatch(body, readCatchList(), isSynthetic: flags & 2 == 2);
  }

  Statement _readTryFinally() {
    return new TryFinally(readStatement(), readStatement());
  }

  Statement _readYieldStatement() {
    int offset = readOffset();
    int flags = readByte();
    return new YieldStatement(readExpression(),
        isYieldStar: flags & YieldStatement.FlagYieldStar != 0,
        isNative: flags & YieldStatement.FlagNative != 0)
      ..fileOffset = offset;
  }

  Statement _readVariableDeclaration() {
    VariableDeclaration variable = readVariableDeclaration();
    variableStack.add(variable); // Will be popped by the enclosing scope.
    return variable;
  }

  Statement _readFunctionDeclaration() {
    int offset = readOffset();
    VariableDeclaration variable = readVariableDeclaration();
    variableStack.add(variable); // Will be popped by the enclosing scope.
    return new FunctionDeclaration(variable, readFunctionNode())
      ..fileOffset = offset;
  }

  void _readSwitchCaseInto(SwitchCase caseNode) {
    int length = readUInt30();
    caseNode.expressions.length = length;
    caseNode.expressionOffsets.length = length;
    for (int i = 0; i < length; ++i) {
      caseNode.expressionOffsets[i] = readOffset();
      caseNode.expressions[i] = readExpression()..parent = caseNode;
    }
    caseNode.isDefault = readByte() == 1;
    caseNode.body = readStatement()..parent = caseNode;
  }

  List<Catch> readCatchList() {
    int length = readUInt30();
    if (!useGrowableLists && length == 0) {
      // When lists don't have to be growable anyway, we might as well use an
      // almost constant one for the empty list.
      return emptyListOfCatch;
    }
    return new List<Catch>.generate(length, (_) => readCatch(),
        growable: useGrowableLists);
  }

  Catch readCatch() {
    int variableStackHeight = variableStack.length;
    int offset = readOffset();
    DartType guard = readDartType();
    VariableDeclaration? exception = readAndPushVariableDeclarationOption();
    VariableDeclaration? stackTrace = readAndPushVariableDeclarationOption();
    Statement body = readStatement();
    variableStack.length = variableStackHeight;
    return new Catch(exception, body, guard: guard, stackTrace: stackTrace)
      ..fileOffset = offset;
  }

  Block _readBlock() {
    int stackHeight = variableStack.length;
    int offset = readOffset();
    int endOffset = readOffset();
    List<Statement> body = readStatementListAlwaysGrowable();
    variableStack.length = stackHeight;
    return new Block(body)
      ..fileOffset = offset
      ..fileEndOffset = endOffset;
  }

  AssertBlock _readAssertBlock() {
    int stackHeight = variableStack.length;
    List<Statement> body = readStatementListAlwaysGrowable();
    variableStack.length = stackHeight;
    return new AssertBlock(body);
  }

  Supertype readSupertype() {
    InterfaceType type = readDartType(forSupertype: true) as InterfaceType;
    assert(
        type.nullability == _currentLibrary!.nonNullable,
        "In serialized form supertypes should have Nullability.legacy if they "
        "are in a library that is opted out of the NNBD feature.  If they are "
        "in an opted-in library, they should have Nullability.nonNullable.");
    return new Supertype.byReference(type.className, type.typeArguments);
  }

  Supertype? readSupertypeOption() {
    return readAndCheckOptionTag() ? readSupertype() : null;
  }

  List<Supertype> readSupertypeList() {
    int length = readUInt30();
    if (!useGrowableLists && length == 0) {
      // When lists don't have to be growable anyway, we might as well use an
      // almost constant one for the empty list.
      return emptyListOfSupertype;
    }
    return new List<Supertype>.generate(length, (_) => readSupertype(),
        growable: useGrowableLists);
  }

  List<DartType> readDartTypeList() {
    int length = readUInt30();
    if (!useGrowableLists && length == 0) {
      // When lists don't have to be growable anyway, we might as well use an
      // almost constant one for the empty list.
      return emptyListOfDartType;
    }
    return new List<DartType>.generate(length, (_) => readDartType(),
        growable: useGrowableLists);
  }

  List<NamedType> readNamedTypeList() {
    int length = readUInt30();
    if (!useGrowableLists && length == 0) {
      // When lists don't have to be growable anyway, we might as well use a
      // constant one for the empty list.
      return emptyListOfNamedType;
    }
    return new List<NamedType>.generate(length, (_) => readNamedType(),
        growable: useGrowableLists);
  }

  NamedType readNamedType() {
    String name = readStringReference();
    DartType type = readDartType();
    int flags = readByte();
    return new NamedType(name, type,
        isRequired: (flags & NamedType.FlagRequiredNamedType) != 0);
  }

  DartType? readDartTypeOption() {
    return readAndCheckOptionTag() ? readDartType() : null;
  }

  DartType readDartType({bool forSupertype: false}) {
    int tag = readByte();
    switch (tag) {
      case Tag.TypedefType:
        return _readTypedefType();
      case Tag.InvalidType:
        return _readInvalidType();
      case Tag.DynamicType:
        return _readDynamicType();
      case Tag.VoidType:
        return _readVoidType();
      case Tag.NeverType:
        return _readNeverType();
      case Tag.InterfaceType:
        return _readInterfaceType();
      case Tag.SimpleInterfaceType:
        return _readSimpleInterfaceType(forSupertype);
      case Tag.FunctionType:
        return _readFunctionType();
      case Tag.SimpleFunctionType:
        return _readSimpleFunctionType();
      case Tag.TypeParameterType:
        return _readTypeParameterType();
      default:
        throw fail('unexpected dart type tag: $tag');
    }
  }

  DartType _readTypedefType() {
    int nullabilityIndex = readByte();
    return new TypedefType.byReference(readNonNullTypedefReference(),
        Nullability.values[nullabilityIndex], readDartTypeList());
  }

  DartType _readInvalidType() {
    return const InvalidType();
  }

  DartType _readDynamicType() {
    return const DynamicType();
  }

  DartType _readVoidType() {
    return const VoidType();
  }

  DartType _readNeverType() {
    int nullabilityIndex = readByte();
    return NeverType.fromNullability(Nullability.values[nullabilityIndex]);
  }

  DartType _readInterfaceType() {
    int nullabilityIndex = readByte();
    Reference reference = readNonNullClassReference();
    List<DartType> typeArguments = readDartTypeList();
    CanonicalName? canonicalName = reference.canonicalName;
    if (canonicalName != null &&
        canonicalName.name == "FutureOr" &&
        canonicalName.parent!.name == "dart:async" &&
        canonicalName.parent!.parent != null &&
        canonicalName.parent!.parent!.isRoot) {
      return new FutureOrType(
          typeArguments.single, Nullability.values[nullabilityIndex]);
    }
    return new InterfaceType.byReference(
        reference, Nullability.values[nullabilityIndex], typeArguments);
  }

  DartType _readSimpleInterfaceType(bool forSupertype) {
    int nullabilityIndex = readByte();
    Reference classReference = readNonNullClassReference();
    CanonicalName? canonicalName = classReference.canonicalName;
    if (canonicalName != null &&
        !forSupertype &&
        canonicalName.name == "Null" &&
        canonicalName.parent!.name == "dart:core" &&
        canonicalName.parent!.parent!.isRoot) {
      return const NullType();
    }
    return new InterfaceType.byReference(classReference,
        Nullability.values[nullabilityIndex], const <DartType>[]);
  }

  DartType _readFunctionType() {
    int typeParameterStackHeight = typeParameterStack.length;
    int nullabilityIndex = readByte();
    List<TypeParameter> typeParameters = readAndPushTypeParameterList();
    int requiredParameterCount = readUInt30();
    int totalParameterCount = readUInt30();
    List<DartType> positional = readDartTypeList();
    List<NamedType> named = readNamedTypeList();
    TypedefType? typedefType = readDartTypeOption() as TypedefType?;
    assert(positional.length + named.length == totalParameterCount);
    DartType returnType = readDartType();
    typeParameterStack.length = typeParameterStackHeight;
    return new FunctionType(
        positional, returnType, Nullability.values[nullabilityIndex],
        typeParameters: typeParameters,
        requiredParameterCount: requiredParameterCount,
        namedParameters: named,
        typedefType: typedefType);
  }

  DartType _readSimpleFunctionType() {
    int nullabilityIndex = readByte();
    List<DartType> positional = readDartTypeList();
    DartType returnType = readDartType();
    return new FunctionType(
        positional, returnType, Nullability.values[nullabilityIndex]);
  }

  DartType _readTypeParameterType() {
    int declaredNullabilityIndex = readByte();
    int index = readUInt30();
    DartType? bound = readDartTypeOption();
    return new TypeParameterType(typeParameterStack[index],
        Nullability.values[declaredNullabilityIndex], bound);
  }

  List<TypeParameter> readAndPushTypeParameterList(
      [List<TypeParameter>? list, TreeNode? parent]) {
    int length = readUInt30();
    if (length == 0) {
      if (list != null) return list;
      if (useGrowableLists) {
        return <TypeParameter>[];
      } else {
        return emptyListOfTypeParameter;
      }
    }
    if (list == null) {
      list = new List<TypeParameter>.generate(
          length, (_) => new TypeParameter(null, null)..parent = parent,
          growable: useGrowableLists);
    } else if (list.length != length) {
      list.length = length;
      for (int i = 0; i < length; ++i) {
        list[i] = new TypeParameter(null, null)..parent = parent;
      }
    }
    typeParameterStack.addAll(list);
    for (int i = 0; i < list.length; ++i) {
      readTypeParameter(list[i]);
    }
    return list;
  }

  void readTypeParameter(TypeParameter node) {
    node.flags = readByte();
    node.annotations = readAnnotationList(node);
    int variance = readByte();
    if (variance == TypeParameter.legacyCovariantSerializationMarker) {
      node.variance = null;
    } else {
      node.variance = variance;
    }
    node.name = readStringOrNullIfEmpty();
    node.bound = readDartType();
    node.defaultType = readDartTypeOption();
  }

  Arguments readArguments() {
    int numArguments = readUInt30();
    List<DartType> typeArguments = readDartTypeList();
    List<Expression> positional = readExpressionList();
    List<NamedExpression> named = readNamedExpressionList();
    assert(numArguments == positional.length + named.length);
    return new Arguments(positional, types: typeArguments, named: named);
  }

  List<NamedExpression> readNamedExpressionList() {
    int length = readUInt30();
    if (!useGrowableLists && length == 0) {
      // When lists don't have to be growable anyway, we might as well use an
      // almost-constant one for the empty list.
      return emptyListOfNamedExpression;
    }
    return new List<NamedExpression>.generate(
        length, (_) => readNamedExpression(),
        growable: useGrowableLists);
  }

  NamedExpression readNamedExpression() {
    return new NamedExpression(readStringReference(), readExpression());
  }

  List<VariableDeclaration> readAndPushVariableDeclarationList() {
    int length = readUInt30();
    if (!useGrowableLists && length == 0) {
      // When lists don't have to be growable anyway, we might as well use an
      // almost constant one for the empty list.
      return emptyListOfVariableDeclaration;
    }
    return new List<VariableDeclaration>.generate(
        length, (_) => readAndPushVariableDeclaration(),
        growable: useGrowableLists);
  }

  VariableDeclaration? readAndPushVariableDeclarationOption() {
    return readAndCheckOptionTag() ? readAndPushVariableDeclaration() : null;
  }

  VariableDeclaration readAndPushVariableDeclaration() {
    VariableDeclaration variable = readVariableDeclaration();
    variableStack.add(variable);
    return variable;
  }

  VariableDeclaration readVariableDeclaration() {
    int offset = readOffset();
    int fileEqualsOffset = readOffset();
    // The [VariableDeclaration] instance is not created at this point yet,
    // so `null` is temporarily set as the parent of the annotation nodes.
    List<Expression> annotations = readAnnotationList(null);
    int flags = readByte();
    VariableDeclaration node = new VariableDeclaration(
        readStringOrNullIfEmpty(),
        type: readDartType(),
        initializer: readExpressionOption(),
        flags: flags)
      ..fileOffset = offset
      ..fileEqualsOffset = fileEqualsOffset;
    if (annotations.isNotEmpty) {
      for (int i = 0; i < annotations.length; ++i) {
        Expression annotation = annotations[i];
        annotation.parent = node;
      }
      node.annotations = annotations;
    }
    return node;
  }

  int readOffset() {
    // Offset is saved as unsigned,
    // but actually ranges from -1 and up (thus the -1)
    return readUInt30() - 1;
  }
}

class BinaryBuilderWithMetadata extends BinaryBuilder implements BinarySource {
  /// List of metadata subsections that have corresponding [MetadataRepository]
  /// and are awaiting to be parsed and attached to nodes.
  List<_MetadataSubsection>? _subsections;

  BinaryBuilderWithMetadata(List<int> bytes,
      {String? filename,
      bool disableLazyReading = false,
      bool disableLazyClassReading = false,
      bool? alwaysCreateNewNamedNodes})
      : super(bytes,
            filename: filename,
            disableLazyReading: disableLazyReading,
            disableLazyClassReading: disableLazyClassReading,
            alwaysCreateNewNamedNodes: alwaysCreateNewNamedNodes);

  @override
  void _readMetadataMappings(
      Component component, int binaryOffsetForMetadataPayloads) {
    // At the beginning of this function _byteOffset points right past
    // metadataMappings to string table.

    // Read the length of metadataMappings.
    _byteOffset -= 4;
    final int subSectionCount = readUint32();

    int endOffset = _byteOffset - 4; // End offset of the current subsection.
    for (int i = 0; i < subSectionCount; i++) {
      // RList<Pair<UInt32, UInt32>> nodeOffsetToMetadataOffset
      _byteOffset = endOffset - 4;
      final int mappingLength = readUint32();
      final int mappingStart = (endOffset - 4) - 4 * 2 * mappingLength;
      _byteOffset = mappingStart - 4;

      // UInt32 tag (fixed size StringReference)
      final String tag = _stringTable[readUint32()];

      final MetadataRepository<dynamic>? repository = component.metadata[tag];
      if (repository != null) {
        // Read nodeOffsetToMetadataOffset mapping.
        final Map<int, int> mapping = <int, int>{};
        _byteOffset = mappingStart;
        for (int j = 0; j < mappingLength; j++) {
          final int nodeOffset = readUint32();
          final int metadataOffset =
              binaryOffsetForMetadataPayloads + readUint32();
          mapping[nodeOffset] = metadataOffset;
        }

        (_subsections ??= <_MetadataSubsection>[])
            .add(new _MetadataSubsection(repository, mapping));
      }

      // Start of the subsection and the end of the previous one.
      endOffset = mappingStart - 4;
    }
  }

  Object _readMetadata(Node node, MetadataRepository repository, int offset) {
    final int savedOffset = _byteOffset;
    _byteOffset = offset;

    final Object metadata = repository.readFromBinary(node, this);

    _byteOffset = savedOffset;
    return metadata;
  }

  @override
  void enterScope({List<TypeParameter>? typeParameters}) {
    if (typeParameters != null) {
      typeParameterStack.addAll(typeParameters);
    }
  }

  @override
  void leaveScope({List<TypeParameter>? typeParameters}) {
    if (typeParameters != null) {
      typeParameterStack.length -= typeParameters.length;
    }
  }

  @override
  T _associateMetadata<T extends Node>(T node, int nodeOffset) {
    if (_subsections == null) {
      return node;
    }

    for (_MetadataSubsection subsection in _subsections!) {
      // First check if there is any metadata associated with this node.
      final int? metadataOffset = subsection.mapping[nodeOffset];
      if (metadataOffset != null) {
        subsection.repository.mapping[node] =
            _readMetadata(node, subsection.repository, metadataOffset);
      }
    }

    return node;
  }

  @override
  DartType readDartType({bool forSupertype = false}) {
    final int nodeOffset = _byteOffset;
    final DartType result = super.readDartType(forSupertype: forSupertype);
    return _associateMetadata(result, nodeOffset);
  }

  @override
  Library readLibrary(Component component, int endOffset) {
    final int nodeOffset = _byteOffset;
    final Library result = super.readLibrary(component, endOffset);
    return _associateMetadata(result, nodeOffset);
  }

  @override
  Typedef readTypedef() {
    final int nodeOffset = _byteOffset;
    final Typedef result = super.readTypedef();
    return _associateMetadata(result, nodeOffset);
  }

  @override
  Class readClass(int endOffset) {
    final int nodeOffset = _byteOffset;
    final Class result = super.readClass(endOffset);
    return _associateMetadata(result, nodeOffset);
  }

  @override
  Extension readExtension() {
    final int nodeOffset = _byteOffset;
    final Extension result = super.readExtension();
    return _associateMetadata(result, nodeOffset);
  }

  @override
  Field readField() {
    final int nodeOffset = _byteOffset;
    final Field result = super.readField();
    return _associateMetadata(result, nodeOffset);
  }

  @override
  Constructor readConstructor() {
    final int nodeOffset = _byteOffset;
    final Constructor result = super.readConstructor();
    return _associateMetadata(result, nodeOffset);
  }

  @override
  Procedure readProcedure(int endOffset) {
    final int nodeOffset = _byteOffset;
    final Procedure result = super.readProcedure(endOffset);
    return _associateMetadata(result, nodeOffset);
  }

  @override
  RedirectingFactoryConstructor readRedirectingFactoryConstructor() {
    final int nodeOffset = _byteOffset;
    final RedirectingFactoryConstructor result =
        super.readRedirectingFactoryConstructor();
    return _associateMetadata(result, nodeOffset);
  }

  @override
  Initializer readInitializer() {
    final int nodeOffset = _byteOffset;
    final Initializer result = super.readInitializer();
    return _associateMetadata(result, nodeOffset);
  }

  @override
  FunctionNode readFunctionNode(
      {bool lazyLoadBody: false, int outerEndOffset: -1}) {
    final int nodeOffset = _byteOffset;
    final FunctionNode result = super.readFunctionNode(
        lazyLoadBody: lazyLoadBody, outerEndOffset: outerEndOffset);
    return _associateMetadata(result, nodeOffset);
  }

  @override
  Expression readExpression() {
    final int nodeOffset = _byteOffset;
    final Expression result = super.readExpression();
    return _associateMetadata(result, nodeOffset);
  }

  @override
  Arguments readArguments() {
    final int nodeOffset = _byteOffset;
    final Arguments result = super.readArguments();
    return _associateMetadata(result, nodeOffset);
  }

  @override
  NamedExpression readNamedExpression() {
    final int nodeOffset = _byteOffset;
    final NamedExpression result = super.readNamedExpression();
    return _associateMetadata(result, nodeOffset);
  }

  @override
  VariableDeclaration readVariableDeclaration() {
    final int nodeOffset = _byteOffset;
    final VariableDeclaration result = super.readVariableDeclaration();
    return _associateMetadata(result, nodeOffset);
  }

  @override
  Statement readStatement() {
    final int nodeOffset = _byteOffset;
    final Statement result = super.readStatement();
    return _associateMetadata(result, nodeOffset);
  }

  @override
  Combinator readCombinator() {
    final int nodeOffset = _byteOffset;
    final Combinator result = super.readCombinator();
    return _associateMetadata(result, nodeOffset);
  }

  @override
  LibraryDependency readLibraryDependency(Library library) {
    final int nodeOffset = _byteOffset;
    final LibraryDependency result = super.readLibraryDependency(library);
    return _associateMetadata(result, nodeOffset);
  }

  @override
  LibraryPart readLibraryPart(Library library) {
    final int nodeOffset = _byteOffset;
    final LibraryPart result = super.readLibraryPart(library);
    return _associateMetadata(result, nodeOffset);
  }

  @override
  void _readSwitchCaseInto(SwitchCase caseNode) {
    _associateMetadata(caseNode, _byteOffset);
    super._readSwitchCaseInto(caseNode);
  }

  @override
  void readTypeParameter(TypeParameter param) {
    _associateMetadata(param, _byteOffset);
    super.readTypeParameter(param);
  }

  @override
  Supertype readSupertype() {
    final int nodeOffset = _byteOffset;
    InterfaceType type =
        super.readDartType(forSupertype: true) as InterfaceType;
    return _associateMetadata(
        new Supertype.byReference(type.className, type.typeArguments),
        nodeOffset);
  }

  @override
  Name readName() {
    final int nodeOffset = _byteOffset;
    final Name result = super.readName();
    return _associateMetadata(result, nodeOffset);
  }

  @override
  int get currentOffset => _byteOffset;

  @override
  List<int> get bytes => _bytes;
}

/// Deserialized MetadataMapping corresponding to the given metadata repository.
class _MetadataSubsection {
  /// [MetadataRepository] that can read this subsection.
  final MetadataRepository repository;

  /// Deserialized mapping from node offsets to metadata offsets.
  final Map<int, int> mapping;

  _MetadataSubsection(this.repository, this.mapping);
}

/// Merges two compilation modes or throws if they are not compatible.
NonNullableByDefaultCompiledMode mergeCompilationModeOrThrow(
    NonNullableByDefaultCompiledMode? a, NonNullableByDefaultCompiledMode b) {
  if (a == null || a == b) {
    return b;
  }

  // If something is invalid, it should always merge as invalid.
  if (a == NonNullableByDefaultCompiledMode.Invalid) {
    return a;
  }
  if (b == NonNullableByDefaultCompiledMode.Invalid) {
    return b;
  }

  if (a == NonNullableByDefaultCompiledMode.Agnostic) {
    return b;
  }
  if (b == NonNullableByDefaultCompiledMode.Agnostic) {
    // Keep as-is.
    return a;
  }

  // Mixed mode where agnostic isn't involved.
  throw new CompilationModeError("Mixed compilation mode found: $a and $b");
}
