#!/usr/bin/env python3
"""Supervise the pipeline process group while holding its lock."""

import ctypes
import fcntl
import os
import signal
import subprocess
import sys
import time


PR_SET_PDEATHSIG = 1
PR_SET_CHILD_SUBREAPER = 36


def write_status(path, status):
    temporary_path = f"{path}.{os.getpid()}.tmp"
    try:
        with open(temporary_path, "w", encoding="utf-8") as status_file:
            status_file.write(f"{status}\n")
            status_file.flush()
            os.fsync(status_file.fileno())
        os.replace(temporary_path, path)
    finally:
        try:
            os.unlink(temporary_path)
        except FileNotFoundError:
            pass


def process_is_alive(pid):
    try:
        with open(f"/proc/{pid}/stat", encoding="utf-8") as stat_file:
            stat = stat_file.read()
    except OSError:
        return False

    _, fields = stat.rsplit(")", 1)
    return fields.split()[0] != "Z"


def process_group_id(pid):
    try:
        return os.getpgid(pid)
    except OSError:
        return None


def isolate_owner_process_group(owner_pid):
    """Put the owner and descendants in a group when the kernel permits it."""
    owner_group = process_group_id(owner_pid)
    if owner_group is None:
        raise RuntimeError("lock owner exited before its process group was attached")
    if owner_group == owner_pid:
        return True
    try:
        os.setpgid(owner_pid, owner_pid)
    except (PermissionError, ProcessLookupError):
        return False
    owner_group = process_group_id(owner_pid)
    if owner_group != owner_pid:
        return False
    return True


def set_child_subreaper():
    libc = ctypes.CDLL(None, use_errno=True)
    if libc.prctl(PR_SET_CHILD_SUBREAPER, 1) != 0:
        error_number = ctypes.get_errno()
        raise OSError(error_number, os.strerror(error_number))


def reap_adopted_children():
    while True:
        try:
            pid, _ = os.waitpid(-1, os.WNOHANG)
        except ChildProcessError:
            return
        if pid == 0:
            time.sleep(0.02)


def set_parent_death_signal(parent_pid):
    libc = ctypes.CDLL(None, use_errno=True)
    if libc.prctl(PR_SET_PDEATHSIG, signal.SIGTERM) != 0:
        error_number = ctypes.get_errno()
        raise OSError(error_number, os.strerror(error_number))
    if os.getppid() != parent_pid:
        raise RuntimeError("lock owner exited before the lock helper was attached")


def process_descendants(parent_pid):
    children_by_parent = {}
    try:
        process_names = os.listdir("/proc")
    except OSError:
        return set()

    for process_name in process_names:
        if not process_name.isdigit():
            continue
        pid = int(process_name)
        try:
            with open(f"/proc/{pid}/stat", encoding="utf-8") as stat_file:
                stat = stat_file.read()
            _, fields = stat.rsplit(")", 1)
            values = fields.split()
            children_by_parent.setdefault(int(values[1]), []).append(pid)
        except (OSError, ValueError, IndexError):
            continue

    descendants = set()
    pending = [parent_pid]
    while pending:
        current_pid = pending.pop()
        for child_pid in children_by_parent.get(current_pid, []):
            if child_pid not in descendants:
                descendants.add(child_pid)
                pending.append(child_pid)
    return descendants


def process_group_members(group_id):
    members = []
    try:
        process_names = os.listdir("/proc")
    except OSError:
        return members

    for process_name in process_names:
        if not process_name.isdigit():
            continue
        pid = int(process_name)
        try:
            with open(f"/proc/{pid}/stat", encoding="utf-8") as stat_file:
                stat = stat_file.read()
            _, fields = stat.rsplit(")", 1)
            values = fields.split()
            state = values[0]
            process_group = int(values[2])
        except (OSError, ValueError, IndexError):
            continue
        if process_group == group_id and state != "Z":
            members.append(pid)
    return members


def stop_processes(pids):
    pids = set(pids)
    pids.discard(os.getpid())
    for pid in pids:
        try:
            os.kill(pid, signal.SIGTERM)
        except (ProcessLookupError, PermissionError):
            pass

    deadline = time.monotonic() + 0.5
    while time.monotonic() < deadline:
        if not any(process_is_alive(pid) for pid in pids):
            return
        time.sleep(0.02)

    while True:
        alive_pids = [pid for pid in pids if process_is_alive(pid)]
        if not alive_pids:
            return
        for pid in alive_pids:
            try:
                os.kill(pid, signal.SIGKILL)
            except (ProcessLookupError, PermissionError):
                pass
        time.sleep(0.02)


def stop_owner_process_group(owner_pid, owner_group, isolated, known_descendants):
    if isolated:
        try:
            os.killpg(owner_group, signal.SIGTERM)
        except (ProcessLookupError, PermissionError):
            pass

        # A TERM grace period allows normal cleanup, but the lock is not
        # released until every surviving group member has disappeared.
        deadline = time.monotonic() + 0.5
        while time.monotonic() < deadline:
            if not process_group_members(owner_group):
                return
            time.sleep(0.02)

        while True:
            members = process_group_members(owner_group)
            if not members:
                return
            for pid in members:
                try:
                    os.kill(pid, signal.SIGKILL)
                except (ProcessLookupError, PermissionError):
                    pass
            time.sleep(0.02)

    # acquire_run_lock is also used by sourced shell test/utility code, where
    # the helper is a sibling and cannot move its parent into a new group. Keep
    # a continuously refreshed descendant set for that compatibility path.
    stop_processes(known_descendants | process_descendants(owner_pid))


def supervise_command(lock_path, owner_pid, command):
    lock_fd = None
    owner_died = False
    child = None

    def handle_parent_death(_signum, _frame):
        nonlocal owner_died
        owner_died = True

    try:
        signal.signal(signal.SIGTERM, handle_parent_death)
        set_parent_death_signal(owner_pid)
        set_child_subreaper()
        lock_fd = os.open(lock_path, os.O_RDWR | os.O_CREAT, 0o600)
        current_flags = fcntl.fcntl(lock_fd, fcntl.F_GETFD)
        fcntl.fcntl(lock_fd, fcntl.F_SETFD, current_flags | fcntl.FD_CLOEXEC)
        try:
            fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            existing_pid = ""
            try:
                with open(lock_path, encoding="utf-8") as lock_file:
                    existing_pid = lock_file.readline().strip()
            except OSError:
                pass
            print(f"dj-factory is already running (PID {existing_pid}).", file=sys.stderr)
            return 3

        if not process_is_alive(owner_pid):
            return 143
        child = subprocess.Popen(command, start_new_session=True)
        os.ftruncate(lock_fd, 0)
        os.write(lock_fd, f"{owner_pid}\n".encode())
        os.fsync(lock_fd)

        while child.poll() is None and not owner_died:
            time.sleep(0.02)

        child_group = child.pid
        if owner_died or child.poll() is not None:
            stop_owner_process_group(child.pid, child_group, True, set())
        status = child.wait()
        reap_adopted_children()
        return status
    except Exception as error:  # pragma: no cover - exercised through process exit
        print(f"lock supervisor failed: {error}", file=sys.stderr)
        if child is not None and child.poll() is None:
            stop_owner_process_group(child.pid, child.pid, True, set())
            child.wait()
            reap_adopted_children()
        return 1
    finally:
        if lock_fd is not None:
            os.close(lock_fd)


def main():
    if len(sys.argv) >= 4 and sys.argv[1] == "--supervise":
        if len(sys.argv) < 5:
            print(
                "usage: hold_run_lock.py --supervise LOCK_PATH OWNER_PID COMMAND...",
                file=sys.stderr,
            )
            return 2
        return supervise_command(sys.argv[2], int(sys.argv[3]), sys.argv[4:])

    if len(sys.argv) != 4:
        print(
            "usage: hold_run_lock.py LOCK_PATH STATUS_PATH OWNER_PID",
            file=sys.stderr,
        )
        return 2

    lock_path, status_path, owner_pid_text = sys.argv[1:]
    owner_pid = int(owner_pid_text)
    lock_fd = None
    owner_died = False
    known_descendants = set()

    def handle_parent_death(_signum, _frame):
        nonlocal owner_died
        owner_died = True

    try:
        signal.signal(signal.SIGTERM, handle_parent_death)
        set_parent_death_signal(owner_pid)
        # The helper must not be a member of the owner's group, otherwise it
        # could kill itself before confirming that all descendants are gone.
        os.setpgid(0, 0)
        owner_isolated = isolate_owner_process_group(owner_pid)
        owner_group = process_group_id(owner_pid) or owner_pid
        lock_fd = os.open(lock_path, os.O_RDWR | os.O_CREAT, 0o600)
        current_flags = fcntl.fcntl(lock_fd, fcntl.F_GETFD)
        fcntl.fcntl(lock_fd, fcntl.F_SETFD, current_flags | fcntl.FD_CLOEXEC)
        try:
            fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            write_status(status_path, "busy")
            return 3

        os.ftruncate(lock_fd, 0)
        os.write(lock_fd, f"{owner_pid}\n".encode())
        os.fsync(lock_fd)
        write_status(status_path, "acquired")

        while True:
            known_descendants.update(process_descendants(owner_pid))
            time.sleep(0.02)
            if owner_died:
                if process_is_alive(owner_pid):
                    return 0
                stop_owner_process_group(
                    owner_pid,
                    owner_group,
                    owner_isolated,
                    known_descendants,
                )
                return 143
    except Exception as error:  # pragma: no cover - exercised through process exit
        try:
            write_status(status_path, f"error: {type(error).__name__}: {error}")
        except OSError:
            pass
        return 1
    finally:
        if lock_fd is not None:
            os.close(lock_fd)


if __name__ == "__main__":
    sys.exit(main())
