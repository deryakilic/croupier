// Copyright 2015 The Vanadium Authors. All rights reserved.
// Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.

class LogWriter {
  final Function updateCallback; // Takes in Map<String, String> data
  LogWriter(this.updateCallback);

  Map<String, String> _data;
  void write(Map<String, String> data) {
    _data = data;
    updateCallback(_data);
  }
}
