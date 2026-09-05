import ExecutionKit
import Foundation

@main
struct PrivateAIExecutionWorkerMain {
    static func main() async {
        Foundation.exit(await ExecutionWorkerProcessMain.run())
    }
}