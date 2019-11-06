// ==== ------------------------------------------------------------------ ====
// === DO NOT EDIT: Generated by GenActors                     
// ==== ------------------------------------------------------------------ ====

import DistributedActors

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: DO NOT EDIT: Generated LifecycleActor messages 

/// DO NOT EDIT: Generated LifecycleActor messages
extension LifecycleActor {
    public enum Message { 
        case pleaseStop 
    }

    
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: DO NOT EDIT: Generated LifecycleActor behavior

extension LifecycleActor {

    public static func makeBehavior(instance: LifecycleActor) -> Behavior<Message> {
        return .setup { context in
            var ctx = Actor<LifecycleActor>.Context(underlying: context)
            var instance = instance // TODO only var if any of the methods are mutating

            /* await */ instance.preStart(context: ctx)

            return Behavior<Message>.receiveMessage { message in
                switch message { 
                
                case .pleaseStop:
                    return instance.pleaseStop() 
                
                }
                return .same
            }.receiveSignal { context, signal in 
                if signal is Signals.PostStop {
                    var ctx = Actor<LifecycleActor>.Context(underlying: context)
                    instance.postStop(context: ctx)
                }
                return .same
            }
        }
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Extend Actor for LifecycleActor

extension Actor where A.Message == LifecycleActor.Message {
    
    public func pleaseStop() { 
        self.ref.tell(.pleaseStop)
    } 
    
}
