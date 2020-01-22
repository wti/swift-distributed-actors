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

@testable import DistributedActors
import DistributedActorsTestKit
import NIO
import XCTest

/// Tests of just the datatype
final class MembershipGossipSeenTableTests: XCTestCase {
    typealias SeenTable = Cluster.Gossip.SeenTable

    var myselfNode: UniqueNode!
    var secondNode: UniqueNode!
    var thirdNode: UniqueNode!

    override func setUp() {
        super.setUp()
        self.myselfNode = UniqueNode(protocol: "sact", systemName: "myself", host: "127.0.0.1", port: 7111, nid: .random())
        self.secondNode = UniqueNode(protocol: "sact", systemName: "second", host: "127.0.0.1", port: 7222, nid: .random())
        self.thirdNode = UniqueNode(protocol: "sact", systemName: "third", host: "127.0.0.1", port: 7333, nid: .random())
    }

    func test_seenTable_compare_concurrent() {
        var table = Cluster.Gossip.SeenTable(myselfNode: self.myselfNode, version: .init())
        table.incrementVersion(owner: self.myselfNode, at: self.myselfNode) // M:1

        var incomingVersion = VersionVector.first(at: .uniqueNode(self.secondNode))
        incomingVersion.increment(at: .uniqueNode(self.secondNode))
        incomingVersion.increment(at: .uniqueNode(self.secondNode)) // S:2

        // neither node knew about each other, so the updates were concurrent;
        // myself receives the table and compares with the incoming:
        let result = table.compareVersion(observedOn: self.myselfNode, to: incomingVersion)
        result.shouldEqual(VersionVector.CausalRelation.concurrent)
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: increments

    func test_incrementVersion() {
        var table = Cluster.Gossip.SeenTable(myselfNode: self.myselfNode, version: .init())
        table.version(at: self.myselfNode).shouldEqual(self.parseVersionVector(""))

        table.incrementVersion(owner: self.myselfNode, at: self.myselfNode)
        table.version(at: self.myselfNode).shouldEqual(self.parseVersionVector("M:1"))

        table.incrementVersion(owner: self.myselfNode, at: self.myselfNode)
        table.version(at: self.myselfNode).shouldEqual(self.parseVersionVector("M:2"))

        table.incrementVersion(owner: self.myselfNode, at: self.secondNode)
        table.version(at: self.myselfNode).shouldEqual(self.parseVersionVector("M:2 S:1"))
        table.version(at: self.secondNode).shouldBeNil()

        table.incrementVersion(owner: self.secondNode, at: self.secondNode)
        table.version(at: self.myselfNode).shouldEqual(self.parseVersionVector("M:2 S:1"))
        table.version(at: self.secondNode).shouldEqual(self.parseVersionVector("S:1"))
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: merge

    func test_seenTable_merge_notYetSeenInformation() {
        var table = Cluster.Gossip.SeenTable(myselfNode: self.myselfNode, version: .init())
        table.incrementVersion(owner: self.myselfNode, at: self.myselfNode) // M observed: M:1

        var incoming = Cluster.Gossip(ownerNode: self.secondNode)
        incoming.incrementOwnerVersion() // S observed: S:1
        incoming.incrementOwnerVersion() // S observed: S:2

        table.merge(owner: self.myselfNode, incoming: incoming)

        table.version(at: self.myselfNode).shouldEqual(VersionVector([
            (.uniqueNode(self.myselfNode), 1), (.uniqueNode(self.secondNode), 2),
        ]))
        table.version(at: self.secondNode).shouldEqual(VersionVector([
            (.uniqueNode(self.secondNode), 2), // as we do not know if the second node has observed OUR information yet
        ]))
    }

    func test_seenTable_merge_sameInformation() {
        // a situation in which the two nodes have converged, so their versions are .same

        var table = Cluster.Gossip.SeenTable(myselfNode: self.myselfNode, version: .init())
        table.incrementVersion(owner: self.myselfNode, at: self.myselfNode) // M observed: M:1
        table.incrementVersion(owner: self.myselfNode, at: self.secondNode) // M observed: M:1 S:1
        table.incrementVersion(owner: self.myselfNode, at: self.secondNode) // M observed: M:1 S:2

        var incoming = Cluster.Gossip(ownerNode: self.secondNode) // S observed:
        incoming.incrementOwnerVersion() // S observed: S:1
        incoming.incrementOwnerVersion() // S observed: S:2
        incoming.seen.incrementVersion(owner: self.secondNode, at: self.myselfNode) // S observed: M:1 S:2

        table.merge(owner: self.myselfNode, incoming: incoming)

        table.version(at: self.myselfNode).shouldEqual(self.parseVersionVector("M:1 S:2"))
        table.version(at: self.secondNode).shouldEqual(self.parseVersionVector("M:1 S:2"))
    }

    func test_seenTable_merge_aheadInformation() {
        // the incoming gossip is "ahead" and has some more information

        var table = Cluster.Gossip.SeenTable(myselfNode: self.myselfNode, version: .init())
        table.incrementVersion(owner: self.myselfNode, at: self.myselfNode) // M observed: M:1

        var incoming = Cluster.Gossip(ownerNode: self.secondNode) // S observed:
        incoming.incrementOwnerVersion() // S observed: S:1
        incoming.incrementOwnerVersion() // S observed: S:2
        incoming.seen.incrementVersion(owner: self.secondNode, at: self.myselfNode) // S observed: M:1 S:2

        table.merge(owner: self.myselfNode, incoming: incoming)

        table.version(at: self.myselfNode).shouldEqual(self.parseVersionVector("M:1 S:2"))
        table.version(at: self.secondNode).shouldEqual(self.parseVersionVector("M:1 S:2"))
    }

    func test_seenTable_merge_behindInformation() {
        // the incoming gossip is "behind"

        var table = Cluster.Gossip.SeenTable(myselfNode: self.myselfNode, version: .init())
        table.incrementVersion(owner: self.myselfNode, at: self.myselfNode) // M observed: M:1
        table.incrementVersion(owner: self.myselfNode, at: self.secondNode) // M observed: M:1 S:1
        table.incrementVersion(owner: self.myselfNode, at: self.secondNode) // M observed: M:1 S:2

        var incoming = Cluster.Gossip(ownerNode: self.secondNode) // S observed:
        incoming.incrementOwnerVersion() // S observed: S:1
        incoming.incrementOwnerVersion() // S observed: S:2

        table.merge(owner: self.myselfNode, incoming: incoming)

        table.version(at: self.myselfNode).shouldEqual(self.parseVersionVector("M:1 S:2"))
        table.version(at: self.secondNode).shouldEqual(self.parseVersionVector("S:2"))
    }

    func test_seenTable_merge_concurrentInformation() {
        // the incoming gossip is "concurrent"

        var table = Cluster.Gossip.SeenTable(myselfNode: self.myselfNode, version: .init())
        table.incrementVersion(owner: self.myselfNode, at: self.myselfNode) // M observed: M:1
        table.incrementVersion(owner: self.myselfNode, at: self.secondNode) // M observed: M:1 S:1
        table.incrementVersion(owner: self.myselfNode, at: self.secondNode) // M observed: M:1 S:2
        table.incrementVersion(owner: self.myselfNode, at: self.thirdNode) // M observed: M:1 S:2 T:1
        // M has seen gossip from S, when it was at t=2
        table.incrementVersion(owner: self.secondNode, at: self.secondNode) // S observed: S:2
        table.incrementVersion(owner: self.secondNode, at: self.secondNode) // S observed: S:3

        // in reality S is quite more far ahead, already at t=4
        var incoming = Cluster.Gossip(ownerNode: self.secondNode) // S observed
        incoming.incrementOwnerVersion() // S observed: S:1
        incoming.incrementOwnerVersion() // S observed: S:2
        incoming.incrementOwnerVersion() // S observed: S:3
        incoming.seen.incrementVersion(owner: self.secondNode, at: self.thirdNode) // S observed: S:3 T:1

        table.merge(owner: self.myselfNode, incoming: incoming)

        table.version(at: self.myselfNode).shouldEqual(self.parseVersionVector("M:1 S:3 T:1"))
        table.version(at: self.secondNode).shouldEqual(incoming.seen.version(at: self.secondNode))
    }

    func test_seenTable_merge_concurrentInformation_unknownMember() {
        // the incoming gossip is "concurrent", and has a table entry for a node we don't know

        var table = Cluster.Gossip.SeenTable(myselfNode: self.myselfNode, version: .init())
        table.incrementVersion(owner: self.myselfNode, at: self.myselfNode) // M observed: M:1

        var incoming = Cluster.Gossip(ownerNode: self.secondNode) // S observed
        incoming.incrementOwnerVersion() // S observed: S:1
        incoming.incrementOwnerVersion() // S observed: S:2
        incoming.seen.incrementVersion(owner: self.secondNode, at: self.thirdNode) // S observed: S:2 T:1
        // also it knows third is at t1
        incoming.seen.incrementVersion(owner: self.thirdNode, at: self.thirdNode) // T observed: T:1

        table.merge(owner: self.myselfNode, incoming: incoming)

        table.version(at: self.myselfNode).shouldEqual(self.parseVersionVector("M:1 S:2 T:1"))
        table.version(at: self.secondNode).shouldEqual(self.parseVersionVector("S:2 T:1"))
        table.version(at: self.thirdNode).shouldEqual(self.parseVersionVector("T:1"))
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Prune

    func test_prune_removeNodeFromSeenTable() {
        var table = Cluster.Gossip.SeenTable(myselfNode: self.myselfNode, version: .init())
        table.incrementVersion(owner: self.myselfNode, at: self.myselfNode)
        table.incrementVersion(owner: self.myselfNode, at: self.thirdNode)

        table.incrementVersion(owner: self.secondNode, at: self.thirdNode)
        table.incrementVersion(owner: self.secondNode, at: self.secondNode)
        table.incrementVersion(owner: self.secondNode, at: self.myselfNode)

        table.incrementVersion(owner: self.thirdNode, at: self.thirdNode)
        table.incrementVersion(owner: self.thirdNode, at: self.myselfNode)

        table.version(at: self.myselfNode).shouldEqual(self.parseVersionVector("M:1 T:1"))
        table.version(at: self.secondNode).shouldEqual(self.parseVersionVector("S:1 M:1 T:1"))
        table.version(at: self.thirdNode).shouldEqual(self.parseVersionVector("T:1 M:1"))

        table.prune(self.thirdNode)

        table.version(at: self.myselfNode).shouldEqual(self.parseVersionVector("M:1"))
        table.version(at: self.secondNode).shouldEqual(self.parseVersionVector("S:1 M:1"))
        table.version(at: self.thirdNode).shouldBeNil()
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Utilities

    func parseVersionVector(_ s: String) -> VersionVector {
        func parseReplicaId(r: Substring) -> ReplicaId {
            switch r {
            case "M": return .uniqueNode(self.myselfNode)
            case "S": return .uniqueNode(self.secondNode)
            case "T": return .uniqueNode(self.thirdNode)
            default: fatalError("Unknown replica id: \(r)")
            }
        }
        let replicaVersions: [VersionVector.ReplicaVersion] = s.split(separator: " ").map { segment in
            let v = segment.split(separator: ":")
            return (parseReplicaId(r: v.first!), Int(v.dropFirst().first!)!)
        }
        return VersionVector(replicaVersions)
    }
}