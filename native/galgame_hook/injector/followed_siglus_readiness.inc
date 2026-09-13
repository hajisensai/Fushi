// Included in RunLaunch after the final child identity is established.
  // A launcher is not the final engine identity. Preserve Siglus's existing
  // delayed-attach boundary after following its original launcher chain too:
  // a discovered process can still be inside LE's pre-kernel32 initialization.
  // No remote LoadLibrary thread may run before the game's own window is ready.
  if (child_process != nullptr && IsSiglusGame(target_exe)) {
    fprintf(stderr, "[launch] waiting for Siglus child readiness pid=%lu\n",
            target_pid);
    if (!WaitForReadyGameWindow(target_process, target_pid, 20000)) {
      fprintf(stderr, "[launch] Siglus child did not reach delayed-attach readiness\n");
      ReportFailureReason(fushi_voice_hook::LaunchFailureReason::kInjectionFailed, 1);
      // The launcher already owns the running child's lifetime. A readiness
      // failure is not permission to inject it, resume the root, or terminate it.
      CloseHandle(child_process);
      CloseHandle(pi.hThread);
      CloseHandle(pi.hProcess);
      return 1;
    }
    fprintf(stderr, "[launch] Siglus child ready for delayed attach pid=%lu\n",
            target_pid);
  }
