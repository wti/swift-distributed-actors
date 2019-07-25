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

import NIO
import Logging
import DistributedActorsConcurrencyHelpers

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Shell State

// TODO we hopefully will rather than this, end up with specialized protocols depending on what we need to expose,
// and then types may require those specific capabilities from the shell; e.g. scheduling things or similar.
internal protocol ReadOnlyClusterState {
    var log: Logger { get }
    var allocator: ByteBufferAllocator { get }
    var eventLoopGroup: EventLoopGroup { get } // TODO or expose the MultiThreaded one...?

    /// Base backoff strategy to use in handshake retries // TODO: move it around somewhere so only handshake cares?
    var backoffStrategy: BackoffStrategy { get }

    /// Unique address of the current node.
    var localAddress: UniqueNodeAddress { get }
    var settings: ClusterSettings { get }
}

/// State of the `ClusterShell` state machine.
internal struct ClusterShellState: ReadOnlyClusterState {
    typealias Messages = ClusterShell.Message

    // TODO maybe move log and settings outside of state into the shell?
    public var log: Logger
    public let settings: ClusterSettings

    public let localAddress: UniqueNodeAddress
    public let channel: Channel

    public let eventLoopGroup: EventLoopGroup

    public var backoffStrategy: BackoffStrategy {
        return settings.handshakeBackoffStrategy
    }

    public let allocator: ByteBufferAllocator

    private var _handshakes: [NodeAddress: HandshakeStateMachine.State] = [:]
    private var _associations: [NodeAddress: AssociationStateMachine.State] = [:]

    // TODO somehow protect / sync associations and membership view?
    // TODO this may move... not sure yet who should "own" the membership; we'll see once we do membership provider or however we call it then
    private var membership: Membership = .empty


    init(settings: ClusterSettings, channel: Channel, log: Logger) {
        self.settings = settings
        self.allocator = settings.allocator
        self.eventLoopGroup = settings.eventLoopGroup ?? settings.makeDefaultEventLoopGroup()
        self.localAddress = settings.uniqueBindAddress

        self.channel = channel

        self.log = log
    }

    func association(with address: NodeAddress) -> AssociationStateMachine.State? {
        return self._associations[address]
    }

    func associatedAddresses() -> Set<UniqueNodeAddress> {
        var set: Set<UniqueNodeAddress> = .init(minimumCapacity: self._associations.count)

        for asm in self._associations.values {
            switch asm {
            case .associated(let state): set.insert(state.remoteAddress)
            }
        }

        return set
    }
    func handshakes() -> [HandshakeStateMachine.State] {
        return self._handshakes.values.map { hsm -> HandshakeStateMachine.State in
            return hsm
        }
    }
}

extension ClusterShellState {

    /// This is the entry point for a client initiating a handshake with a remote node.
    ///
    /// This MAY return `inFlight`, in which case it means someone already initiated a handshake with given node,
    /// and we should _do nothing_ and trust that our `whenCompleted` will be notified when the already in-flight handshake completes.
    mutating func registerHandshake(with remoteAddress: NodeAddress, whenCompleted: EventLoopPromise<Wire.HandshakeResponse>) -> HandshakeStateMachine.State {
        if let handshakeState = self.handshakeInProgress(with: remoteAddress) {
            switch handshakeState {
            case .initiated(let state):
                state.whenCompleted?.futureResult.cascade(to: whenCompleted)
            case .completed(let state):
                state.whenCompleted?.futureResult.cascade(to: whenCompleted)
            case .wasOfferedHandshake(let state):
                state.whenCompleted?.futureResult.cascade(to: whenCompleted)
            case .inFlight:
                fatalError("An inFlight may never be stored, yet seemingly was! Offending state: \(self) for node \(remoteAddress)")
            }

            return .inFlight(HandshakeStateMachine.InFlightState(state: self, whenCompleted: whenCompleted))
        }

        if let existingAssociation = self.association(with: remoteAddress) {
            fatalError("Beginning new handshake to [\(reflecting: remoteAddress)], with already existing association: \(existingAssociation). Could this be a bug?")
        }

        let initiated = HandshakeStateMachine.InitiatedState(
            settings: self.settings,
            localAddress: self.localAddress,
            connectTo: remoteAddress,
            whenCompleted: whenCompleted
        )
        let handshakeState = HandshakeStateMachine.State.initiated(initiated)
        self._handshakes[remoteAddress] = handshakeState
        return handshakeState
    }

    mutating func onHandshakeChannelConnected(initiated: HandshakeStateMachine.InitiatedState, channel: Channel) -> ClusterShellState {
        #if DEBUG
        let handshakeInProgress: HandshakeStateMachine.State? = self.handshakeInProgress(with: initiated.remoteAddress)

        if case let .some(.initiated(existingInitiated)) = handshakeInProgress {
            if existingInitiated.remoteAddress != initiated.remoteAddress {
                fatalError("""
                           onHandshakeChannelConnected MUST be called with the existing ongoing initiated
                           handshake! Existing: \(existingInitiated), passed in: \(initiated).
                           """)
            }
            if existingInitiated.channel != nil {
                fatalError("onHandshakeChannelConnected should only be invoked once on an initiated state; yet seems the state already has a channel! Was: \(String(reflecting: handshakeInProgress))")
            }
        }
        #endif

        var initiated = initiated
        initiated.onChannelConnected(channel: channel)

        self._handshakes[initiated.remoteAddress] = .initiated(initiated)
        return self
    }

    func handshakeInProgress(with address: NodeAddress) -> HandshakeStateMachine.State? {
        return self._handshakes[address]
    }

    /// Abort a handshake, clearing any of its state as well as closing the passed in channel
    /// (which should be the one which the handshake to abort was made on).
    ///
    /// - Faults: when called in wrong state of an ongoing handshake
    /// - Returns: if present, the (now removed) handshake state that was aborted, hil otherwise.
    mutating func abortOutgoingHandshake(with address: NodeAddress) -> HandshakeStateMachine.State? {
        guard let state = self._handshakes.removeValue(forKey: address) else {
            return nil
        }

        switch state {
        case .initiated(let initiated):
            assert(initiated.channel != nil, "Channel should always be present after the initial initialization.")
            _ = initiated.channel?.close()
        case .wasOfferedHandshake:
            fatalError("abortOutgoingHandshake was called in a context where the handshake was not an outgoing one! Was: \(state)")
        case .completed:
            fatalError("Attempted to abort an already completed handshake; Completed should never remain stored; Was: \(state)")
        case .inFlight:
            fatalError("Stored state was .inFlight, which should never be stored: \(state)")
        }

        return state
    }

    /// Abort an incoming handshake channel;
    /// As there may be a concurrent negotiation ongoing on another (outgoing) connection, we do NOT remove the handshake
    /// by address from the _handshakes.
    ///
    /// - Returns: if present, the (now removed) handshake state that was aborted, hil otherwise.
    mutating func abortIncomingHandshake(offer: Wire.HandshakeOffer, channel: Channel) {
        _ = channel.close()
    }

    /// This is the entry point for a server receiving a handshake with a remote node.
    /// Inspects and possibly allocates a `HandshakeStateMachine` in the `HandshakeReceivedState` state.
    ///
    /// Scenarios:
    ///   L - local node
    ///   R - remote node
    ///
    ///   L initiates connection to R; R initiates connection to L;
    ///   Both nodes store an `initiated` state for the handshake; both will receive the others offer;
    ///   We need to perform a tie-break to see which one should actually "drive" this connecting: we pick the "lower address".
    ///
    ///   Upon tie-break the nodes follow these two roles:
    ///     Winner: Keeps the outgoing connection, negotiates and replies accept/reject on the "incoming" connection from the remote node.
    ///     Loser: Drops the incoming connection and waits for Winner's decision.
    mutating func onIncomingHandshakeOffer(offer: Wire.HandshakeOffer) -> OnIncomingHandshakeOfferDirective {

        func negotiate(promise: EventLoopPromise<Wire.HandshakeResponse>? = nil) -> OnIncomingHandshakeOfferDirective {
            let promise = promise ?? self.eventLoopGroup.next().makePromise(of: Wire.HandshakeResponse.self)
            let fsm = HandshakeStateMachine.HandshakeReceivedState(state: self, offer: offer, whenCompleted: promise)
            self._handshakes[offer.from.address] = .wasOfferedHandshake(fsm)
            return .negotiate(fsm)
        }

        guard let inProgress = self._handshakes[offer.from.address] else {
            // no other concurrent handshakes in progress; good, this is happy path, so we simply continue our negotiation
            return negotiate()
        }

        switch inProgress {
        case .initiated(let initiated):
            /// order on addresses is somewhat arbitrary, but that is fine, since we only need this for tiebreakers
            let tieBreakWinner = initiated.localAddress < offer.from
            self.log.warning("""
                             Concurrently initiated handshakes from nodes [\(initiated.localAddress)](local) and [\(offer.from)](remote) \
                             detected! Resolving race by address ordering; This node \(tieBreakWinner ? "WON (will negotiate and reply)" : "LOST (will await reply)") tie-break. 
                             """)
            if tieBreakWinner {
                if let abortedHandshake = self.abortOutgoingHandshake(with: offer.from.address) {
                    self.log.info("Aborted handshake, as concurrently negotiating another one with same node already; Aborted handshake: \(abortedHandshake)")
                }

                self.log.debug("Proceed to negotiate handshake offer.")
                return negotiate(promise: initiated.whenCompleted)

            } else {
                // we "lost", the other node will send the accept; when it does, the will complete the future.
                return .abortDueToConcurrentHandshake
            }
        case .wasOfferedHandshake(let offered):
            // suspicious but but not wrong, so we were offered before, and now are being offered again?
            // Situations:
            // - it could be that the remote re-sent their offer before it received our accept?
            // - maybe remote did not receive our accept/reject and is trying again?
            return negotiate()

        // --- these are never stored ----
        case .inFlight(let inFlight):
            fatalError("inFlight state should never have been stored as handshake state; This is likely a bug, please open an issue.")
        case .completed(let completed):
            fatalError("completed state should never have been stored as handshake state; This is likely a bug, please open an issue.")
        }
    }
    enum OnIncomingHandshakeOfferDirective {
        case negotiate(HandshakeStateMachine.HandshakeReceivedState)
        /// An existing handshake with given peer is already in progress,
        /// do not negotiate but rest assured that the association will be handled properly by the already ongoing process.
        case abortDueToConcurrentHandshake
    }

    mutating func incomingHandshakeAccept(_ accept: Wire.HandshakeAccept) -> HandshakeStateMachine.CompletedState? { // TODO return directives to act on
        if let inProgressHandshake = self._handshakes[accept.from.address] {
            switch inProgressHandshake {
            case .initiated(let hsm):
                let completed = HandshakeStateMachine.CompletedState(fromInitiated: hsm, remoteAddress: accept.from)
                return completed
            case .wasOfferedHandshake:
                // TODO model the states to express this can not happen // there is a client side state machine and a server side one
                self.log.warning("Received accept but state machine is in WAS OFFERED state. This should be impossible.")
                return nil
            case .completed:
                // TODO: validate if it is for the same UID or not, if not, we may be in trouble?
                self.log.warning("Received handshake Accept for already completed handshake. This should not happen.")
                return nil
            case .inFlight:
                fatalError("An in-flight marker state should never be stored, yet was encountered in \(#function)")
            }
        } else {
            fatalError("Accept incoming for handshake which was not in progress!") // TODO model differently
        }
    }

    /// "Upgrades" a connection with a remote node from handshaking state to associated.
    /// Stores an `Association` for the newly established association;
    mutating func associate(_ handshake: HandshakeStateMachine.CompletedState, channel: Channel) -> AssociationStateMachine.AssociatedState {
        guard self._handshakes.removeValue(forKey: handshake.remoteAddress.address) != nil else {
            fatalError("Can not complete a handshake which was not in progress!")
            // TODO perhaps we instead just warn and ignore this; since it should be harmless
        }

        let asm = AssociationStateMachine.AssociatedState(fromCompleted: handshake, log: self.log, over: channel)
        let state: AssociationStateMachine.State = .associated(asm)

        // TODO store and update membership inside here?
        // TODO: this is not so nice, since we now have membership kind of in two places, we should make this somehow nicer...
        // TODO: Membership should drive all decisions about "allowed to join" etc, and the replacement decisions as well.

        func storeAssociation() {
            self._associations[handshake.remoteAddress.address] = state
        }

        let change = self.membership.join(handshake.remoteAddress)
        if change.isReplace {
            switch self.association(with: handshake.remoteAddress.address) {
            case .some(.associated(let associated)):
                // we are fairly certain the old node is dead now, since the new node is taking its place and has same address,
                // thus the channel is most likely pointing to an "already-dead" connection; we close it to cut off clean.
                //
                // we ignore the close-future, as it would not give us much here; could only be used to mark "we are still shutting down"
                _ = associated.channel.close()

            default:
                self.log.warning("Membership change indicated node replacement, yet no 'old' association found, this could happen if failure detection ")
            }
        }
        storeAssociation()

        return asm
    }

}