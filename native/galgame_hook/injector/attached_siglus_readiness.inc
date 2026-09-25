// Included in the PID attach path after resolving the actual process image,
// and in the Steam client launch path after discovering the game process.
// Both inject into an already running process, so neither may skip this gate.
  // Automatic recovery after a launch failure comes through this same entry.
  // It must not bypass the confirmed Siglus child's delayed-attach boundary.
  if (IsSiglusGame(target_exe)) {
    fprintf(stderr, "[attach] waiting for Siglus readiness pid=%lu\n", pid);
    if (!WaitForReadyGameWindow(target, pid, 20000)) {
      fprintf(stderr, "[attach] Siglus did not reach delayed-attach readiness\n");
      ReportFailureReason(fushi_voice_hook::LaunchFailureReason::kInjectionFailed, 1);
      CloseHandle(target);
      return 1;
    }
    fprintf(stderr, "[attach] Siglus ready for delayed attach pid=%lu\n", pid);
  }
