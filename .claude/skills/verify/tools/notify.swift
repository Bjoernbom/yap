// notify <name>: posts a distributed notification (yap's DEBUG hooks).
import Foundation

DistributedNotificationCenter.default().postNotificationName(
	.init(CommandLine.arguments[1]), object: nil, userInfo: nil, deliverImmediately: true)
print("posted \(CommandLine.arguments[1])")
