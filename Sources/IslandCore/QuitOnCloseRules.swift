import Foundation

/// Yalnızca son pencerenin gerçek kırmızı-düğme kapanışından sonra normal quit isteği.
public enum QuitOnCloseRules {
    public static func shouldQuit(enabled: Bool, trusted: Bool, clickedCloseButton: Bool,
                                  windowWasDestroyed: Bool, remainingWindows: Int?, protectedApplication: Bool) -> Bool {
        enabled && trusted && clickedCloseButton && windowWasDestroyed
            && remainingWindows == 0 && !protectedApplication
    }
}
