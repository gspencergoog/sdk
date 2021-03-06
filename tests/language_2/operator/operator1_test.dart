// Copyright (c) 2019, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

// @dart = 2.9

/// Operator functions cannot be static.

class C {
  static operator +(int index) {
//^^^^^^
// [analyzer] SYNTACTIC_ERROR.STATIC_OPERATOR
// [cfe] Operators can't be static.
    return index;
  }
}

main() {
  C();
}
