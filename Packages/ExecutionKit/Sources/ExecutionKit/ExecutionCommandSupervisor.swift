import Foundation
#if canImport(Darwin)
import Darwin
#endif

public enum ExecutionCommandSupervisor {
    public static func run(command: String) -> Int32 {
        let processGroupID = getpgrp()
        let supervisorPID = getpid()
        guard let supervisorIdentity = ExecutionProcessIdentity(
            processID: supervisorPID
        ) else {
            return 127
        }
        var blockedSignals = sigset_t()
        sigemptyset(&blockedSignals)
        sigaddset(&blockedSignals, SIGINT)
        sigaddset(&blockedSignals, SIGTERM)
        guard pthread_sigmask(SIG_BLOCK, &blockedSignals, nil) == 0 else {
            return 127
        }
        let lifeline = makeLifelineSource(processGroupID: processGroupID)
        var signalSources: [DispatchSourceSignal] = []
        defer {
            lifeline.cancel()
            signalSources.forEach { $0.cancel() }
        }

        let nullInput = open("/dev/null", O_RDONLY)
        guard nullInput >= 0 else { return 127 }
        defer { close(nullInput) }

        var fileActions: posix_spawn_file_actions_t? = nil
        guard posix_spawn_file_actions_init(&fileActions) == 0 else { return 127 }
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        guard posix_spawn_file_actions_adddup2(
            &fileActions,
            nullInput,
            STDIN_FILENO
        ) == 0 else {
            return 127
        }

        var spawnAttributes: posix_spawnattr_t? = nil
        guard posix_spawnattr_init(&spawnAttributes) == 0 else { return 127 }
        defer { posix_spawnattr_destroy(&spawnAttributes) }
        var defaultSignals = sigset_t()
        var emptyMask = sigset_t()
        sigemptyset(&defaultSignals)
        sigaddset(&defaultSignals, SIGINT)
        sigaddset(&defaultSignals, SIGTERM)
        sigemptyset(&emptyMask)
        guard posix_spawnattr_setsigdefault(
            &spawnAttributes,
            &defaultSignals
        ) == 0,
        posix_spawnattr_setsigmask(&spawnAttributes, &emptyMask) == 0,
        posix_spawnattr_setflags(
            &spawnAttributes,
            Int16(POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK)
        ) == 0 else {
            return 127
        }

        var arguments: [UnsafeMutablePointer<CChar>?] = [
            strdup("/bin/zsh"),
            strdup("-dfc"),
            strdup(command)
        ]
        arguments.append(nil)
        var environment: [UnsafeMutablePointer<CChar>?] = ProcessInfo
            .processInfo.environment.filter { key, _ in
                key != "LLVM_PROFILE_FILE"
            }.map {
                strdup("\($0.key)=\($0.value)")
            }
        environment.append(nil)
        defer {
            for pointer in arguments where pointer != nil { free(pointer) }
            for pointer in environment where pointer != nil { free(pointer) }
        }

        var shellPID: pid_t = 0
        let spawnResult = posix_spawn(
            &shellPID,
            "/bin/zsh",
            &fileActions,
            &spawnAttributes,
            &arguments,
            &environment
        )
        guard spawnResult == 0 else {
            pthread_sigmask(SIG_UNBLOCK, &blockedSignals, nil)
            return 127
        }
        signalSources = makeSignalSources(processGroupID: processGroupID)
        pthread_sigmask(SIG_UNBLOCK, &blockedSignals, nil)

        var information = siginfo_t()
        var waitResult: Int32
        repeat {
            waitResult = waitid(
                P_PID,
                id_t(shellPID),
                &information,
                WEXITED | WNOWAIT
            )
        } while waitResult == -1 && errno == EINTR

        let cleanupError: (any Error)?
        do {
            try ExecutionProcessGroupController.terminate(
                recordedLeader: supervisorIdentity,
                excluding: [supervisorPID, shellPID]
            )
            cleanupError = nil
        } catch {
            cleanupError = error
        }
        var status: Int32 = 0
        while waitpid(shellPID, &status, 0) == -1 && errno == EINTR {}
        if let cleanupError {
            let message = "Execution process cleanup failed: \(cleanupError.localizedDescription)\n"
            try? FileHandle.standardError.write(contentsOf: Data(message.utf8))
            return 125
        }
        return normalizedExitCode(status)
    }

    private static func makeLifelineSource(
        processGroupID: pid_t
    ) -> DispatchSourceRead {
        let source = DispatchSource.makeReadSource(
            fileDescriptor: STDIN_FILENO,
            queue: DispatchQueue(label: "privateai.execution.lifeline")
        )
        source.setEventHandler {
            var byte: UInt8 = 0
            if Darwin.read(STDIN_FILENO, &byte, 1) == 0 {
                kill(-processGroupID, SIGKILL)
            }
        }
        source.resume()
        return source
    }

    private static func makeSignalSources(
        processGroupID: pid_t
    ) -> [DispatchSourceSignal] {
        [SIGINT, SIGTERM].map { signalNumber in
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(
                signal: signalNumber,
                queue: DispatchQueue(label: "privateai.execution.signal.\(signalNumber)")
            )
            source.setEventHandler {
                kill(-processGroupID, SIGKILL)
            }
            source.resume()
            return source
        }
    }

    private static func normalizedExitCode(_ status: Int32) -> Int32 {
        if status & 0x7f == 0 { return (status >> 8) & 0xff }
        return 128 + (status & 0x7f)
    }
}