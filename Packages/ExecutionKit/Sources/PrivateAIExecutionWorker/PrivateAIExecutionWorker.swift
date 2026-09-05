import ExecutionKit
import Foundation

@main
struct PrivateAIExecutionWorker {
    static func main() async {
        Foundation.exit(await ExecutionWorkerProcessMain.run())
    }
}