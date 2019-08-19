//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2018-2019 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.md for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Foundation
import XCTest
@testable import DistributedActors
import DistributedActorsTestKit

final class NodeDeathWatcherTests: ClusteredNodesTestBase {

    func test_nodeDeath_shouldFailAllRefsOnSpecificAddress() throws {
        let first = self.setUpNode("first") { settings in 
            settings.cluster.swim.gossip.probeInterval = .milliseconds(100)
        }
        let second = self.setUpNode("second") { settings in
            settings.cluster.swim.gossip.probeInterval = .milliseconds(100)
        }

        try self.joinNodes(node: first, with: second)

        let refOnRemote1: ActorRef<String> = try second.spawn("remote-1", .ignore)
        let refOnFirstToRemote1 = first._resolve(ref: refOnRemote1, onSystem: second)

        let refOnRemote2: ActorRef<String> = try second.spawn("remote-2", .ignore)
        let refOnFirstToRemote2 = first._resolve(ref: refOnRemote2, onSystem: second)

        let testKit = ActorTestKit(first)
        let p = testKit.spawnTestProbe(expecting: Signals.Terminated.self)

        // --- prepare actor on [first], which watches remote actors ---

        _ = try first.spawn("watcher1", Behavior<String>.setup { context in
            context.watch(refOnFirstToRemote1)
            context.watch(refOnFirstToRemote2)

            let recv: Behavior<String> = .receiveMessage { message in
                return .same
            }

            return recv.receiveSpecificSignal(Signals.Terminated.self) { _, terminated in
                p.ref.tell(terminated)
                return .same
            }
        })

        first.cluster.down(node: second.cluster.node)

        // should cause termination of all remote actors, observed by the local actors on [first]
        let terminations: [Signals.Terminated] = try p.expectMessages(count: 2)
        terminations.shouldContain(where: { terminated in
            (!terminated.existenceConfirmed) && terminated.address.name == "remote-1"
        })
        terminations.shouldContain(where: { terminated in
            (!terminated.existenceConfirmed) && terminated.address.name == "remote-2"
        })

        // should not trigger terminated again for any of the remote refs
        first.cluster.down(node: second.cluster.node)
        try p.expectNoMessage(for: .milliseconds(50))
    }

}