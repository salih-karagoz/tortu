import Foundation
import HelperProtocol
import RulesEngine

/// Accepts connections only from a build of Tortu signed by the expected team.
final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    private let service: HelperService

    init(service: HelperService) {
        self.service = service
    }

    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection connection: NSXPCConnection
    ) -> Bool {
        // Checked by the system before a single message is delivered, and a
        // connection from anything else never reaches the service. The call
        // reports nothing: a requirement that cannot be satisfied invalidates
        // the connection rather than returning an error here, so there is no
        // failure branch to write and none to test.
        connection.setCodeSigningRequirement(HelperIdentity.clientRequirement)

        connection.exportedInterface = NSXPCInterface(with: TortuHelperProtocol.self)
        connection.exportedObject = service
        connection.resume()
        return true
    }
}

guard let store = try? RuleStore.bundled() else {
    NSLog("tortu-helper: no bundled rules, refusing to start")
    exit(1)
}

let listener = NSXPCListener(machServiceName: tortuHelperMachServiceName)
let delegate = ListenerDelegate(service: HelperService(store: store))
listener.delegate = delegate
listener.resume()
NSLog("tortu-helper: listening on %@", tortuHelperMachServiceName)
RunLoop.current.run()
