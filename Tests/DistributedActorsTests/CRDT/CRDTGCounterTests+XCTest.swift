//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2019 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.md for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import XCTest

///
/// NOTE: This file was generated by generate_linux_tests.rb
///
/// Do NOT edit this file directly as it will be regenerated automatically when needed.
///

extension CRDTGCounterTests {
    static var allTests: [(String, (CRDTGCounterTests) -> () throws -> Void)] {
        return [
            ("test_GCounter_increment_shouldUpdateDelta", test_GCounter_increment_shouldUpdateDelta),
            ("test_GCounter_merge_shouldMutate", test_GCounter_merge_shouldMutate),
            ("test_GCounter_merging_shouldNotMutate", test_GCounter_merging_shouldNotMutate),
            ("test_GCounter_mergeDelta_shouldMutate", test_GCounter_mergeDelta_shouldMutate),
            ("test_GCounter_mergingDelta_shouldNotMutate", test_GCounter_mergingDelta_shouldNotMutate),
            ("test_GCounter_reset", test_GCounter_reset),
        ]
    }
}