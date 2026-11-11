# Copyright (c) 2026 GitOps Manager, S.L.
# SPDX-License-Identifier: Apache-2.0
"""Run one terraform command apart from the workflow step, for run_terraform_stage.sh.

  setsid --fork python3 terraform_session.py <run dir> <terraform args...>

Started in a session of its own, so it is not in the step's process tree and
a cancelled step can't kill it: Terraform then gets to finish what it's doing,
write its state and release its lock. Writes, in <run dir>:

  session.pid  this process          terraform.pid  Terraform's
  log          Terraform's output     rc        its exit code, when it ends

The output goes to a file, never the step's pipe, which closes when a
cancelled step is killed. Only run_terraform_stage.sh signals Terraform, and only
once (a second interrupt makes it exit at once): this process ignores the
signals itself, and Terraform keeps the default handling.
"""
import os
import signal
import subprocess
import sys


def write(path, text):
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        f.write(text)
    os.replace(tmp, path)


def main():
    run, args = sys.argv[1], sys.argv[2:]
    write(os.path.join(run, "session.pid"), str(os.getpid()))
    # Terraform must get the default handling of the interrupt, whatever this
    # was started with: a step started in the background starts its children
    # with SIGINT ignored, and an ignored interrupt would never reach it.
    for s in (signal.SIGINT, signal.SIGTERM):
        signal.signal(s, signal.SIG_DFL)
    with open(os.path.join(run, "log"), "ab", buffering=0) as log:
        tf = subprocess.Popen(["terraform", *args], stdin=subprocess.DEVNULL,
                                stdout=log, stderr=subprocess.STDOUT)
        # Ignored here only after the start, so Terraform doesn't inherit it.
        for s in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
            signal.signal(s, signal.SIG_IGN)
        write(os.path.join(run, "terraform.pid"), str(terraform.pid))
        rc = tf.wait()
    # Killed by a signal: the shell's convention, 128 + the signal.
    write(os.path.join(run, "rc"), str(rc if rc >= 0 else 128 - rc))


if __name__ == "__main__":
    main()
