from pathlib import Path
import os
import re
import shutil
import signal
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
MANUAL = ROOT / "documents" / "00-syncthing-manual-gui.sh"
ALWAYS = ROOT / "documents" / "10-syncthing-always-on.sh"


def run(cmd, check=True, **kwargs):
    result = subprocess.run(cmd, text=True, capture_output=True, **kwargs)
    if check and result.returncode != 0:
        raise AssertionError(
            f"command failed: {' '.join(map(str, cmd))}\n"
            f"stdout:\n{result.stdout}\n"
            f"stderr:\n{result.stderr}"
        )
    return result


def shell_syntax():
    for script in (MANUAL, ALWAYS):
        run(["dash", "-n", str(script)])

        busybox = shutil.which("busybox")
        if busybox:
            run([busybox, "sh", "-n", str(script)])


def extract_supervisor():
    text = ALWAYS.read_text()
    match = re.search(
        r"<<'SUPERVISOR_EOF'\n(.*?)\nSUPERVISOR_EOF",
        text,
        re.S,
    )
    if not match:
        raise AssertionError("embedded supervisor not found")
    return match.group(1) + "\n"


def supervisor_syntax(supervisor):
    with tempfile.TemporaryDirectory() as td:
        path = Path(td) / "supervisor.sh"
        path.write_text(supervisor)
        run(["dash", "-n", str(path)])

        busybox = shutil.which("busybox")
        if busybox:
            run([busybox, "sh", "-n", str(path)])


def static_invariants():
    manual = MANUAL.read_text()
    always = ALWAYS.read_text()
    combined = manual + always

    forbidden = (
        "192.168.",
        "LLO5PAE",
        "KDHF5BS",
        "/mnt/us/documents/News",
        "Daily News",
        "syncthing generate",
    )

    for value in forbidden:
        if value in combined:
            raise AssertionError(f"device/workflow-specific value found: {value}")

    assert 'CONF="/mnt/us/filemanagers/settings"' in manual
    assert 'DATA="/var/local/syncthing-filemanagers"' in manual
    assert 'CONF="/mnt/us/filemanagers/settings"' in always
    assert 'DATA="/var/local/syncthing-filemanagers"' in always

    assert '--gui-address="$IP:8384"' in manual
    assert 'GUI username is not configured; LAN GUI exposure was refused' in manual
    assert 'GUI password is not configured; LAN GUI exposure was refused' in manual
    assert 'SCHEME="http"' in manual
    assert '[ "$GUI_TLS" = "true" ] && SCHEME="https"' in manual

    assert "--gui-address=127.0.0.1:8384" in always
    assert 'SERVICE="kindle-syncthing"' in always
    assert 'SERVICE_VERSION="1.0.0"' in always
    assert "pid_is_service_syncthing" in always
    assert "child_is_syncthing" in always
    assert "RECOVERY_TEST=PASS" in always
    assert "current_install" in always

    for script in (MANUAL, ALWAYS):
        data = script.read_bytes()
        assert data.startswith(b"#!/bin/sh\n")
        assert b"\r\n" not in data


def patch_constant(text, name, value, count=1):
    pattern = rf'^{re.escape(name)}="[^"]*"$'
    replacement = f'{name}="{value}"'
    text, replaced = re.subn(pattern, replacement, text, count=count, flags=re.M)
    if replaced != count:
        raise AssertionError(f"unable to patch {name}")
    return text


def make_fake_command(path, body):
    path.write_text("#!/bin/sh\n" + body)
    path.chmod(0o755)


def manual_gui_mock():
    with tempfile.TemporaryDirectory() as td:
        td = Path(td)
        fakebin = td / "bin"
        fakebin.mkdir()
        conf = td / "conf"
        data = td / "data"
        state = td / "state"
        out = td / "status.txt"
        conf.mkdir()
        data.mkdir()
        state.mkdir()

        (conf / "cert.pem").write_text("cert\n")
        (conf / "key.pem").write_text("key\n")
        (conf / "config.xml").write_text(
            '<configuration>\n'
            '  <gui enabled="true" tls="true">\n'
            '    <address>127.0.0.1:8384</address>\n'
            '    <user>admin</user>\n'
            '    <password>$2a$10$examplehash</password>\n'
            '  </gui>\n'
            '</configuration>\n'
        )

        starts = td / "starts.txt"

        fake_syncthing = td / "syncthing"
        fake_syncthing.write_text(
            "#!/bin/sh\n"
            "case \" $* \" in\n"
            "  *\" device-id \"*) echo TESTDEVICE-ID ; exit 0 ;;\n"
            "esac\n"
            "echo \"$$ $*\" >> \"$TEST_STARTS\"\n"
            "trap 'exit 0' TERM INT HUP\n"
            "while :; do sleep 1; done\n"
        )
        fake_syncthing.chmod(0o755)

        make_fake_command(
            fakebin / "ip",
            'if [ "$1" = "link" ]; then exit 0; fi\n'
            'if [ "$1" = "addr" ]; then echo "2: wlan0"; echo "    inet 10.23.45.67/24"; exit 0; fi\n'
            'if [ "$1" = "route" ]; then echo "default via 10.23.45.1 dev wlan0"; exit 0; fi\n'
            "exit 0\n",
        )
        make_fake_command(
            fakebin / "iptables",
            'if [ "$1" = "-D" ]; then exit 1; fi\nexit 0\n',
        )
        make_fake_command(fakebin / "pidof", "exit 1\n")
        make_fake_command(fakebin / "status", 'echo "$1 stop/waiting"\nexit 0\n')
        make_fake_command(fakebin / "stop", "exit 0\n")
        make_fake_command(
            fakebin / "id",
            'if [ "$1" = "-u" ]; then echo 0; else echo "uid=0(root) gid=0(root)"; fi\n',
        )

        text = MANUAL.read_text()
        text = patch_constant(text, "BIN", str(fake_syncthing))
        text = patch_constant(text, "CONF", str(conf))
        text = patch_constant(text, "DATA", str(data))
        text = patch_constant(text, "STATE", str(state))
        text = patch_constant(text, "OUT", str(out))
        text = re.sub(
            r'^PATH="[^"]*"$',
            f'PATH="{fakebin}:/usr/bin:/bin"',
            text,
            count=1,
            flags=re.M,
        )
        text = text.replace("sleep 8\n", "sleep 1\n", 1)
        text = text.replace("sleep 2\n", "sleep 1\n", 1)

        script = td / "manual.sh"
        script.write_text(text)
        script.chmod(0o755)

        env = os.environ.copy()
        env["TEST_STARTS"] = str(starts)

        result = run(["/bin/sh", str(script)], env=env, check=False, timeout=8)
        if result.returncode != 0:
            raise AssertionError(
                f"manual GUI mock failed\nstdout:\n{result.stdout}\nstderr:\n{result.stderr}\n"
                f"status:\n{out.read_text() if out.exists() else '(missing)'}"
            )

        status = out.read_text()
        assert "GUI=https://10.23.45.67:8384" in status
        assert "RESULT=SUCCESS" in status
        assert starts.exists()

        pidfile = state / "manual-gui.pid"
        if pidfile.exists():
            value = pidfile.read_text().strip()
            if value.isdigit():
                try:
                    os.kill(int(value), signal.SIGTERM)
                except ProcessLookupError:
                    pass


def manual_gui_refuses_no_auth():
    with tempfile.TemporaryDirectory() as td:
        td = Path(td)
        fakebin = td / "bin"
        fakebin.mkdir()
        conf = td / "conf"
        data = td / "data"
        state = td / "state"
        out = td / "status.txt"
        conf.mkdir()
        data.mkdir()
        state.mkdir()

        (conf / "cert.pem").write_text("cert\n")
        (conf / "key.pem").write_text("key\n")
        (conf / "config.xml").write_text(
            '<configuration>\n'
            '  <gui enabled="true" tls="false">\n'
            '    <address>127.0.0.1:8384</address>\n'
            '    <user></user>\n'
            '    <password></password>\n'
            '  </gui>\n'
            '</configuration>\n'
        )

        fake_syncthing = td / "syncthing"
        fake_syncthing.write_text(
            "#!/bin/sh\n"
            "case \" $* \" in\n"
            "  *\" device-id \"*) echo TESTDEVICE-ID ; exit 0 ;;\n"
            "esac\n"
            "exit 0\n"
        )
        fake_syncthing.chmod(0o755)

        for name in ("iptables", "pidof", "status", "stop"):
            make_fake_command(fakebin / name, "exit 0\n")
        make_fake_command(
            fakebin / "ip",
            'if [ "$1" = "link" ]; then exit 0; fi\n'
            'if [ "$1" = "addr" ]; then echo "    inet 10.23.45.67/24"; exit 0; fi\n'
            "exit 0\n",
        )
        make_fake_command(
            fakebin / "id",
            'if [ "$1" = "-u" ]; then echo 0; else echo "uid=0(root)"; fi\n',
        )

        text = MANUAL.read_text()
        text = patch_constant(text, "BIN", str(fake_syncthing))
        text = patch_constant(text, "CONF", str(conf))
        text = patch_constant(text, "DATA", str(data))
        text = patch_constant(text, "STATE", str(state))
        text = patch_constant(text, "OUT", str(out))
        text = re.sub(
            r'^PATH="[^"]*"$',
            f'PATH="{fakebin}:/usr/bin:/bin"',
            text,
            count=1,
            flags=re.M,
        )

        script = td / "manual-no-auth.sh"
        script.write_text(text)
        script.chmod(0o755)

        result = run(["/bin/sh", str(script)], check=False, timeout=5)
        assert result.returncode != 0
        status = out.read_text()
        assert "LAN GUI exposure was refused" in status
        assert "RESULT=FAIL" in status


def supervisor_recovery_mock(supervisor):
    with tempfile.TemporaryDirectory() as td:
        td = Path(td)
        fakebin = td / "bin"
        fakebin.mkdir()
        conf = td / "conf"
        data = td / "data"
        state = td / "state"

        for path in (conf, data, state):
            path.mkdir()

        for name in ("config.xml", "cert.pem", "key.pem"):
            (conf / name).write_text("test\n")

        starts = td / "starts.txt"

        fake_syncthing = td / "syncthing"
        fake_syncthing.write_text(
            "#!/bin/sh\n"
            "echo \"$$\" >> \"$TEST_STARTS\"\n"
            "trap 'exit 0' TERM INT HUP\n"
            "while :; do sleep 1; done\n"
        )
        fake_syncthing.chmod(0o755)

        make_fake_command(
            fakebin / "iptables",
            'if [ "$1" = "-D" ]; then exit 1; fi\nexit 0\n',
        )
        make_fake_command(fakebin / "pidof", "exit 1\n")
        make_fake_command(
            fakebin / "ip",
            'if [ "$1" = "link" ]; then exit 0; fi\n'
            'if [ "$1" = "route" ]; then echo "default via 10.0.0.1 dev wlan0"; exit 0; fi\n'
            "exit 0\n",
        )

        text = supervisor
        text = patch_constant(text, "BIN", str(fake_syncthing))
        text = patch_constant(text, "CONF", str(conf))
        text = patch_constant(text, "DATA", str(data))
        text = patch_constant(text, "STATE", str(state))
        text = re.sub(r'^PIDFILE=.*$', f'PIDFILE="{state / "syncthing.pid"}"', text, count=1, flags=re.M)
        text = re.sub(r'^IFACEFILE=.*$', f'IFACEFILE="{state / "firewall.iface"}"', text, count=1, flags=re.M)
        text = re.sub(r'^LOG=.*$', f'LOG="{state / "supervisor.log"}"', text, count=1, flags=re.M)
        text = re.sub(r'^SYNCTHING_LOG=.*$', f'SYNCTHING_LOG="{data / "syncthing.log"}"', text, count=1, flags=re.M)
        text = re.sub(r'^CHECK_INTERVAL=.*$', "CHECK_INTERVAL=1", text, count=1, flags=re.M)
        text = re.sub(r'^START_GRACE=.*$', "START_GRACE=1", text, count=1, flags=re.M)
        text = re.sub(r'^BACKOFF_INITIAL=.*$', "BACKOFF_INITIAL=1", text, count=1, flags=re.M)
        text = re.sub(r'^BACKOFF_MAX=.*$', "BACKOFF_MAX=2", text, count=1, flags=re.M)
        text = re.sub(r'^FIREWALL_EVERY=.*$', "FIREWALL_EVERY=2", text, count=1, flags=re.M)
        text = re.sub(
            r'^PATH="[^"]*"$',
            f'PATH="{fakebin}:/usr/bin:/bin"',
            text,
            count=1,
            flags=re.M,
        )

        script = td / "supervisor.sh"
        script.write_text(text)
        script.chmod(0o755)

        env = os.environ.copy()
        env["TEST_STARTS"] = str(starts)

        proc = subprocess.Popen(
            ["/bin/sh", str(script)],
            env=env,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )

        pidfile = state / "syncthing.pid"

        try:
            deadline = time.time() + 8
            first = None

            while time.time() < deadline:
                if pidfile.exists():
                    value = pidfile.read_text().strip()
                    if value.isdigit():
                        candidate = int(value)
                        try:
                            os.kill(candidate, 0)
                            first = candidate
                            break
                        except ProcessLookupError:
                            pass
                time.sleep(0.1)

            if not first:
                raise AssertionError("supervisor did not start mock Syncthing")

            os.kill(first, signal.SIGTERM)

            deadline = time.time() + 8
            second = None

            while time.time() < deadline:
                if pidfile.exists():
                    value = pidfile.read_text().strip()
                    if value.isdigit():
                        candidate = int(value)
                        if candidate != first:
                            try:
                                os.kill(candidate, 0)
                                second = candidate
                                break
                            except ProcessLookupError:
                                pass
                time.sleep(0.1)

            if not second:
                raise AssertionError("supervisor did not restart mock Syncthing")

            lines = starts.read_text().splitlines()
            if len(lines) < 2:
                raise AssertionError("mock Syncthing was not launched twice")
        finally:
            proc.send_signal(signal.SIGTERM)
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait(timeout=5)


def main():
    shell_syntax()
    supervisor = extract_supervisor()
    supervisor_syntax(supervisor)
    static_invariants()
    manual_gui_mock()
    manual_gui_refuses_no_auth()
    supervisor_recovery_mock(supervisor)

    print("PASS: shell syntax")
    print("PASS: embedded supervisor syntax")
    print("PASS: generic/device-independent invariants")
    print("PASS: authenticated Manual GUI mock")
    print("PASS: unauthenticated Manual GUI refusal")
    print("PASS: supervisor restart recovery mock")


if __name__ == "__main__":
    main()
