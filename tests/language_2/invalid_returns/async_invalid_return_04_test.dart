// Copyright (c) 2018, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

// @dart = 2.9

import 'dart:async';

/*
* `return;` is an error if `flatten(T)` is not `void`, `dynamic`, or `Null`
*/
FutureOr<Object> test() async {
  return; //# none: static type warning
}

void main() {
  test();
}
