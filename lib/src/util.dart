// Copyright (c) 2019, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

/// Utility methods used by more than one library in the package.
library package_config.util;

import 'dart:io';
import 'dart:typed_data';

import "errors.dart";

// All ASCII characters that are valid in a package name, with space
// for all the invalid ones (including space).
const String _validPackageNameCharacters =
    r"                                 !  $ &'()*+,-. 0123456789 ; =  "
    r"@ABCDEFGHIJKLMNOPQRSTUVWXYZ    _ abcdefghijklmnopqrstuvwxyz   ~ ";

/// Tests whether something is a valid Dart package name.
bool isValidPackageName(String string) {
  return checkPackageName(string) < 0;
}

/// Check if a string is a valid package name.
///
/// Valid package names contain only characters in [_validPackageNameCharacters]
/// and must contain at least one non-'.' character.
///
/// Returns `-1` if the string is valid.
/// Otherwise returns the index of the first invalid character,
/// or `string.length` if the string contains no non-'.' character.
int checkPackageName(String string) {
  // Becomes non-zero if any non-'.' character is encountered.
  int nonDot = 0;
  for (int i = 0; i < string.length; i++) {
    var c = string.codeUnitAt(i);
    if (c > 0x7f || _validPackageNameCharacters.codeUnitAt(c) <= $space) {
      return i;
    }
    nonDot += c ^ $dot;
  }
  if (nonDot == 0) return string.length;
  return -1;
}

/// Validate that a [Uri] is a valid `package:` URI.
///
/// Used to validate user input.
///
/// Returns the package name extracted from the package URI,
/// which is the path segment between `package:` and the first `/`.
String checkValidPackageUri(Uri packageUri, String name) {
  if (packageUri.scheme != "package") {
    throw PackageConfigArgumentError(packageUri, name, "Not a package: URI");
  }
  if (packageUri.hasAuthority) {
    throw PackageConfigArgumentError(
        packageUri, name, "Package URIs must not have a host part");
  }
  if (packageUri.hasQuery) {
    // A query makes no sense if resolved to a file: URI.
    throw PackageConfigArgumentError(
        packageUri, name, "Package URIs must not have a query part");
  }
  if (packageUri.hasFragment) {
    // We could leave the fragment after the URL when resolving,
    // but it would be odd if "package:foo/foo.dart#1" and
    // "package:foo/foo.dart#2" were considered different libraries.
    // Keep the syntax open in case we ever get multiple libraries in one file.
    throw PackageConfigArgumentError(
        packageUri, name, "Package URIs must not have a fragment part");
  }
  if (packageUri.path.startsWith('/')) {
    throw PackageConfigArgumentError(
        packageUri, name, "Package URIs must not start with a '/'");
  }
  int firstSlash = packageUri.path.indexOf('/');
  if (firstSlash == -1) {
    throw PackageConfigArgumentError(packageUri, name,
        "Package URIs must start with the package name followed by a '/'");
  }
  String packageName = packageUri.path.substring(0, firstSlash);
  int badIndex = checkPackageName(packageName);
  if (badIndex >= 0) {
    if (packageName.isEmpty) {
      throw PackageConfigArgumentError(
          packageUri, name, "Package names mus be non-empty");
    }
    if (badIndex == packageName.length) {
      throw PackageConfigArgumentError(packageUri, name,
          "Package names must contain at least one non-'.' character");
    }
    assert(badIndex < packageName.length);
    int badCharCode = packageName.codeUnitAt(badIndex);
    var badChar = "U+" + badCharCode.toRadixString(16).padLeft(4, '0');
    if (badCharCode >= 0x20 && badCharCode <= 0x7e) {
      // Printable character.
      badChar = "'${packageName[badIndex]}' ($badChar)";
    }
    throw PackageConfigArgumentError(
        packageUri, name, "Package names must not contain $badChar");
  }
  return packageName;
}

/// Checks whether URI is just an absolute directory.
///
/// * It must have a scheme.
/// * It must not have a query or fragment.
/// * The path must end with `/`.
bool isAbsoluteDirectoryUri(Uri uri) {
  if (uri.hasQuery) return false;
  if (uri.hasFragment) return false;
  if (!uri.hasScheme) return false;
  var path = uri.path;
  if (!path.endsWith("/")) return false;
  return true;
}

/// Whether the former URI is a prefix of the latter.
bool isUriPrefix(Uri prefix, Uri path) {
  assert(!prefix.hasFragment);
  assert(!prefix.hasQuery);
  assert(!path.hasQuery);
  assert(!path.hasFragment);
  assert(prefix.path.endsWith('/'));
  return path.toString().startsWith(prefix.toString());
}

/// Finds the first non-JSON-whitespace character in a file.
///
/// Used to heuristically detect whether a file is a JSON file or an .ini file.
int firstNonWhitespaceChar(List<int> bytes) {
  for (int i = 0; i < bytes.length; i++) {
    var char = bytes[i];
    if (char != 0x20 && char != 0x09 && char != 0x0a && char != 0x0d) {
      return char;
    }
  }
  return -1;
}

/// Attempts to return a relative path-only URI for [uri].
///
/// First removes any query or fragment part from [uri].
///
/// If [uri] is already relative (has no scheme), it's returned as-is.
/// If that is not desired, the caller can pass `baseUri.resolveUri(uri)`
/// as the [uri] instead.
///
/// If the [uri] has a scheme or authority part which differs from
/// the [baseUri], or if there is no overlap in the paths of the
/// two URIs at all, the [uri] is returned as-is.
///
/// Otherwise the result is a path-only URI which satsifies
/// `baseUri.resolveUri(result) == uri`,
///
/// The `baseUri` must be absolute.
Uri relativizeUri(Uri uri, Uri baseUri) {
  assert(baseUri.isAbsolute);
  if (uri.hasQuery || uri.hasFragment) {
    uri = Uri(
        scheme: uri.scheme,
        userInfo: uri.hasAuthority ? uri.userInfo : null,
        host: uri.hasAuthority ? uri.host : null,
        port: uri.hasAuthority ? uri.port : null,
        path: uri.path);
  }

  // Already relative. We assume the caller knows what they are doing.
  if (!uri.isAbsolute) return uri;

  if (baseUri.scheme != uri.scheme) {
    return uri;
  }

  // If authority differs, we could remove the scheme, but it's not worth it.
  if (uri.hasAuthority != baseUri.hasAuthority) return uri;
  if (uri.hasAuthority) {
    if (uri.userInfo != baseUri.userInfo ||
        uri.host.toLowerCase() != baseUri.host.toLowerCase() ||
        uri.port != baseUri.port) {
      return uri;
    }
  }

  baseUri = baseUri.normalizePath();
  List<String> base = [...baseUri.pathSegments];
  if (base.isNotEmpty) base.removeLast();
  uri = uri.normalizePath();
  List<String> target = [...uri.pathSegments];
  if (target.isNotEmpty && target.last.isEmpty) target.removeLast();
  int index = 0;
  while (index < base.length && index < target.length) {
    if (base[index] != target[index]) {
      break;
    }
    index++;
  }
  if (index == base.length) {
    if (index == target.length) {
      return Uri(path: "./");
    }
    return Uri(path: target.skip(index).join('/'));
  } else if (index > 0) {
    var buffer = StringBuffer();
    for (int n = base.length - index; n > 0; --n) {
      buffer.write("../");
    }
    buffer.writeAll(target.skip(index), "/");
    return Uri(path: buffer.toString());
  } else {
    return uri;
  }
}

Future<Uint8List> defaultLoader(Uri uri) async {
  if (uri.isScheme("file")) {
    var file = File.fromUri(uri);
    try {
      return file.readAsBytes();
    } catch (_) {
      return null;
    }
  }
  if (uri.isScheme("http") || uri.isScheme("https")) {
    return _httpGet(uri);
  }
  throw UnsupportedError("Default URI unsupported scheme: $uri");
}

Future<Uint8List /*?*/ > _httpGet(Uri uri) async {
  assert(uri.isScheme("http") || uri.isScheme("https"));
  HttpClient client = new HttpClient();
  HttpClientRequest request = await client.getUrl(uri);
  HttpClientResponse response = await request.close();
  if (response.statusCode != HttpStatus.ok) {
    return null;
  }
  List<List<int>> splitContent = await response.toList();
  int totalLength = 0;
  if (splitContent.length == 1) {
    var part = splitContent[0];
    if (part is Uint8List) {
      return part;
    }
  }
  for (var list in splitContent) {
    totalLength += list.length;
  }
  Uint8List result = new Uint8List(totalLength);
  int offset = 0;
  for (Uint8List contentPart in splitContent) {
    result.setRange(offset, offset + contentPart.length, contentPart);
    offset += contentPart.length;
  }
  return result;
}

/// The file name of a path.
///
/// The file name is everything after the last occurrence of
/// [Platform.pathSeparator], or the entire string if no
/// path separator occurs in the string.
String fileName(String path) {
  var separator = Platform.pathSeparator;
  int lastSeparator = path.lastIndexOf(separator);
  if (lastSeparator < 0) return path;
  return path.substring(lastSeparator + separator.length);
}

/// The directory name of a path.
///
/// The directory name is everything before the last occurrence of
/// [Platform.pathSeparator], or the empty string if no
/// path separator occurs in the string.
String dirName(String path) {
  var separator = Platform.pathSeparator;
  int lastSeparator = path.lastIndexOf(separator);
  if (lastSeparator < 0) return "";
  return path.substring(0, lastSeparator);
}

/// Join path parts with the [Platform.pathSeparator].
///
/// If a part ends with a path separator, then no extra separator is
/// inserted.
String pathJoin(String part1, String part2, [String part3]) {
  var separator = Platform.pathSeparator;
  String separator1 = part1.endsWith(separator) ? "" : separator;
  if (part3 == null) {
    return "$part1$separator1$part2";
  }
  String separator2 = part2.endsWith(separator) ? "" : separator;
  return "$part1$separator1$part2$separator2$part3";
}

/// Join an unknown number of path parts with [Platform.pathSeparator].
///
/// If a part ends with a path separator, then no extra separator is
/// inserted.
String pathJoinAll(Iterable<String> parts) {
  var buffer = StringBuffer();
  String separator = "";
  for (var part in parts) {
    buffer..write(separator)..write(part);
    separator =
        part.endsWith(Platform.pathSeparator) ? "" : Platform.pathSeparator;
  }
  return buffer.toString();
}

// Character constants used by this package.
/// "Line feed" control character.
const int $lf = 0x0a;

/// "Carriage return" control character.
const int $cr = 0x0d;

/// Space character.
const int $space = 0x20;

/// Character `#`.
const int $hash = 0x23;

/// Character `.`.
const int $dot = 0x2e;

/// Character `:`.
const int $colon = 0x3a;

/// Character `?`.
const int $question = 0x3f;

/// Character `{`.
const int $lbrace = 0x7b;