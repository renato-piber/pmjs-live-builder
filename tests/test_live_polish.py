"""Testes locais: sem ISO build, rede, dconf real ou execucao de aplicativos PMJS."""
import importlib.util
import json
import os
from pathlib import Path
import shlex
import struct
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
INCLUDE = ROOT / "config-live/includes.chroot"
COMPONENT = INCLUDE / "usr/lib/live/config/1195-pmjs-desktop"
spec = importlib.util.spec_from_file_location("microcode", ROOT / "tools/validate-early-microcode.py")
microcode = importlib.util.module_from_spec(spec)
spec.loader.exec_module(microcode)


def entry(name, data=b"", mode=0o100644):
    name = name.encode() + b"\0"
    fields = [1, mode, 0, 0, 1, 0, len(data), 0, 0, 0, 0, len(name), 0]
    header = b"070701" + b"".join(f"{value:08x}".encode() for value in fields)
    return header + name + b"\0" * (-(110 + len(name)) % 4) + data + b"\0" * (-len(data) % 4)


def archive(name, data):
    return entry(name, data) + entry("TRAILER!!!") + b"\0" * 512


def intel_record(revision=0x28, signature=0x306C3):
    fields = [1, revision, 0, signature, 0, 1, 0x32, 0, 2048, 0, 0, 0]
    fields[4] = -sum(fields) & 0xFFFFFFFF
    return struct.pack("<12I", *fields) + b"\0" * (2048 - 48)


INTEL = "kernel/x86/microcode/GenuineIntel.bin"
AMD = "kernel/x86/microcode/AuthenticAMD.bin"


class EarlyMicrocodeTests(unittest.TestCase):
    def check(self, data, error=None):
        with tempfile.TemporaryDirectory(prefix="pmjs-microcode-test-") as directory:
            path = Path(directory) / "initrd"
            path.write_bytes(data)
            if error:
                with self.assertRaisesRegex(microcode.InvalidInitrd, error):
                    microcode.validate(path)
            else:
                microcode.validate(path)

    def test_multiple_early_cpios(self):
        self.check(archive(AMD, b"amd") + archive(INTEL, intel_record()) + b"\x28\xb5\x2f\xfdcompressed")

    def test_missing_amd_matches_previous_artifact(self):
        self.check(archive(INTEL, intel_record()), "AuthenticAMD")

    def test_missing_intel(self):
        self.check(archive(AMD, b"amd"), "GenuineIntel")

    def test_old_haswell(self):
        self.check(archive(INTEL, intel_record(0x17)) + archive(AMD, b"amd"), "Haswell")

    def test_wrong_signature(self):
        self.check(archive(INTEL, intel_record(signature=0x506E3)) + archive(AMD, b"amd"), "Haswell")

    def test_main_initrd_is_not_early(self):
        self.check(b"\x28\xb5\x2f\xfd" + archive(INTEL, intel_record()) + archive(AMD, b"amd"), "Nenhum CPIO")

    def test_truncated_cpio(self):
        self.check(archive(INTEL, intel_record())[:150], "truncado")

    def test_bad_intel_checksum(self):
        data = bytearray(intel_record())
        data[-1] = 1
        self.check(archive(INTEL, data) + archive(AMD, b"amd"), "Checksum")

    def test_empty_payload(self):
        self.check(archive(INTEL, b""), "vazio")

    def test_truncated_intel_record(self):
        self.check(archive(INTEL, intel_record()[:48]) + archive(AMD, b"amd"), "Intel invalida")

    def test_duplicate_payload(self):
        self.check(archive(INTEL, intel_record()) * 2 + archive(AMD, b"amd"), "duplicado")


class LiveIntegrationTests(unittest.TestCase):
    def test_proxy_no_credentials_or_homepage_changes(self):
        policy = json.loads((INCLUDE / "etc/firefox/policies/policies.json").read_text())
        self.assertEqual(set(policy), {"policies"})
        self.assertEqual(set(policy["policies"]), {"Proxy", "OfferToSaveLogins"})
        self.assertIs(policy["policies"]["OfferToSaveLogins"], False)
        self.assertEqual(policy["policies"]["Proxy"], {
            "Mode": "manual", "Locked": False,
            "HTTPProxy": "proxy.empresa.local:8080", "SSLProxy": "proxy.empresa.local:8080",
            "UseHTTPProxyForAllProtocols": True, "AutoLogin": False})
        for forbidden in ("logins.json", "key4.db", "signons.sqlite"):
            self.assertEqual(list(INCLUDE.rglob(forbidden)), [])

    def test_early_configuration_is_portable(self):
        intel = (INCLUDE / "etc/default/intel-microcode").read_text()
        amd = (INCLUDE / "etc/default/amd64-microcode").read_text()
        self.assertIn("IUCODE_TOOL_INITRAMFS=early", intel)
        self.assertIn("IUCODE_TOOL_SCANCPUS=no", intel)
        self.assertIn("AMD64UCODE_INITRAMFS=early", amd)
        build = (ROOT / "lib/build.sh").read_text().split("run_build_pipeline()", 1)[1]
        self.assertLess(build.index("validate_early_microcode"), build.index("publish_iso"))

    def install_desktop(self, apps, home, success=True):
        command = (f"source {shlex.quote(str(COMPONENT))}; "
                   f"pmjs_install_desktop {shlex.quote(str(apps))} {shlex.quote(str(home))} "
                   f"{os.getuid()} {os.getgid()}")
        result = subprocess.run(["bash", "-c", command], capture_output=True, text=True)
        self.assertEqual(result.returncode == 0, success, result.stderr)

    def setup_desktop(self, directory):
        apps, home = Path(directory) / "apps", Path(directory) / "home"
        apps.mkdir()
        home.mkdir()
        for name in ("pmjs-deploy", "pmjs-image-builder", "firefox-esr", "gparted"):
            (apps / (name + ".desktop")).write_text(f"[Desktop Entry]\nType=Application\nName={name}\nExec={name}\nIcon={name}\n")
        return apps, home

    def test_four_regular_owned_executable_launchers_each_boot(self):
        with tempfile.TemporaryDirectory(prefix="pmjs-desktop-test-") as directory:
            apps, home = self.setup_desktop(directory)
            desktop = home / "Desktop"
            desktop.mkdir()
            (desktop / "PMJS Deploy.desktop").symlink_to(apps / "pmjs-deploy.desktop")
            original = (apps / "pmjs-deploy.desktop").read_bytes()
            self.install_desktop(apps, home)
            self.install_desktop(apps, home)
            names = {"PMJS Deploy.desktop", "PMJS Image Builder.desktop", "Firefox ESR.desktop", "GParted.desktop"}
            self.assertEqual({path.name for path in desktop.iterdir()}, names)
            for path in desktop.iterdir():
                self.assertFalse(path.is_symlink())
                self.assertEqual((path.stat().st_uid, path.stat().st_gid), (os.getuid(), os.getgid()))
                self.assertEqual(path.stat().st_mode & 0o777, 0o755)
                subprocess.run(["desktop-file-validate", str(path)], check=True)
            self.assertEqual((apps / "pmjs-deploy.desktop").read_bytes(), original)

    def test_refuses_desktop_symlink_without_touching_external_files(self):
        with tempfile.TemporaryDirectory(prefix="pmjs-desktop-test-") as directory:
            apps, home = self.setup_desktop(directory)
            (home / "Desktop").symlink_to(apps, target_is_directory=True)
            self.install_desktop(apps, home, success=False)
            self.assertEqual(len(list(apps.iterdir())), 4)

    def test_detaches_existing_hardlink_without_changing_system_launcher(self):
        with tempfile.TemporaryDirectory(prefix="pmjs-desktop-test-") as directory:
            apps, home = self.setup_desktop(directory)
            (home / "Desktop").mkdir()
            source = apps / "pmjs-deploy.desktop"
            source.chmod(0o644)
            os.link(source, home / "Desktop/PMJS Deploy.desktop")
            self.install_desktop(apps, home)
            self.assertEqual(source.stat().st_mode & 0o777, 0o644)
            self.assertNotEqual(source.stat().st_ino, (home / "Desktop/PMJS Deploy.desktop").stat().st_ino)

    def test_validates_all_sources_before_creating_desktop(self):
        with tempfile.TemporaryDirectory(prefix="pmjs-desktop-test-") as directory:
            apps, home = self.setup_desktop(directory)
            (apps / "gparted.desktop").unlink()
            self.install_desktop(apps, home, success=False)
            self.assertFalse((home / "Desktop").exists())

    def test_refuses_directory_as_launcher(self):
        with tempfile.TemporaryDirectory(prefix="pmjs-desktop-test-") as directory:
            apps, home = self.setup_desktop(directory)
            (home / "Desktop/GParted.desktop").mkdir(parents=True)
            self.install_desktop(apps, home, success=False)
            self.assertEqual(len(list((home / "Desktop").iterdir())), 1)

    def test_mate_shortcut_with_fakes_no_host_dconf(self):
        with tempfile.TemporaryDirectory(prefix="pmjs-keybinding-test-") as directory:
            directory = Path(directory)
            log = directory / "calls"
            (directory / "id").write_text("#!/bin/sh\necho 1000\n")
            (directory / "gsettings").write_text('#!/bin/sh\nprintf "%s\\n" "$*" >> "$PMJS_TEST_CALLS"\n')
            for name in ("id", "gsettings"):
                (directory / name).chmod(0o755)
            env = dict(os.environ, PATH=str(directory) + os.pathsep + os.environ["PATH"], PMJS_TEST_CALLS=str(log))
            subprocess.run(["sh", str(INCLUDE / "usr/local/libexec/pmjs-live-keybindings")], env=env, check=True)
            calls = log.read_text().splitlines()
            self.assertEqual(len(calls), 3)
            self.assertIn(" action flameshot gui", calls[1])
            self.assertIn(" binding <Super><Shift>s", calls[2])
            self.assertTrue(all("org.mate.control-center.keybinding:/org/mate/desktop/keybindings/pmjs-flameshot/" in call for call in calls))

    def test_native_menu_and_shortcut_autostart(self):
        for name in ("pmjs-deploy", "pmjs-image-builder"):
            desktop = INCLUDE / f"usr/share/applications/{name}.desktop"
            self.assertIn("Categories=System;", desktop.read_text())
            self.assertTrue((INCLUDE / f"usr/share/pixmaps/{name}.png").is_file())
        autostart = INCLUDE / "etc/xdg/autostart/pmjs-live-keybindings.desktop"
        subprocess.run(["desktop-file-validate", str(autostart)], check=True)
        self.assertIn("OnlyShowIn=MATE;", autostart.read_text())
        self.assertNotIn("flameshot.desktop", str(list((INCLUDE / "etc/skel").rglob("*.desktop"))))

    def test_snapshot_guards_reject_offline_bundles_and_staging(self):
        with tempfile.TemporaryDirectory(prefix="pmjs-snapshot-guard-") as directory:
            snapshot = Path(directory)
            for name in ("run.sh", "VERSION", "SNAPSHOT"):
                (snapshot / name).write_text("fixture\n")
            (snapshot / "run.sh").chmod(0o755)
            base = f"source {shlex.quote(str(ROOT / 'tools/update-pmjs-snapshots.sh'))}; validate_runtime_snapshot {shlex.quote(directory)} run.sh 2"
            self.assertEqual(subprocess.run(["bash", "-c", base], capture_output=True).returncode, 0)
            for name in ("pmjs-images", "staging", "outputs", ".pmjs-linux-0.2.0.build.XXXX", ".pmjs-linux-0.2.0.sync.XXXX"):
                path = snapshot / name
                path.mkdir()
                self.assertNotEqual(subprocess.run(["bash", "-c", base], capture_output=True).returncode, 0, name)
                path.rmdir()
            with (snapshot / "VERSION").open("wb") as stream:
                stream.truncate(21 * 1024 * 1024)
            self.assertNotEqual(subprocess.run(["bash", "-c", base], capture_output=True).returncode, 0)


class DeploySnapshotUpdateTests(unittest.TestCase):
    """Checkout simulado: sem rede, ISO build ou execucao do Deploy."""

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="pmjs-deploy-snapshot-")
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.source = self.directory / "source"
        self.staging = self.directory / "staging"
        self.updater = ROOT / "tools/update-pmjs-snapshots.sh"
        result = subprocess.run(
            ["bash", "-c", 'source "$1"; printf "%s\\n" "${DEPLOY_RUNTIME_FILES[@]}"',
             "snapshot-test", str(self.updater)],
            check=True, capture_output=True, text=True,
        )
        self.runtime_files = result.stdout.splitlines()
        for name in self.runtime_files:
            path = self.source / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("1.0.0\n" if name == "VERSION" else "#!/bin/sh\nexit 0\n")
        (self.source / "deploy.sh").chmod(0o755)

    def copy_snapshot(self):
        return subprocess.run(
            ["bash", "-c", '''source "$1"
STAGING_ROOT=$3
copy_runtime_snapshot "$2" deploy DEPLOY_RUNTIME_FILES
validate_runtime_snapshot "$3/deploy" deploy.sh "${#DEPLOY_RUNTIME_FILES[@]}"
''', "snapshot-test", str(self.updater), str(self.source), str(self.staging)],
            capture_output=True, text=True,
        )

    def test_current_deploy_without_retired_projection_helper(self):
        self.assertNotIn("assets/auto-mirror-x11", self.runtime_files)
        self.assertIn("lib/timer.sh", self.runtime_files)
        self.assertIn("lib/image_contract.sh", self.runtime_files)
        result = self.copy_snapshot()
        self.assertEqual(result.returncode, 0, result.stderr)
        snapshot = self.staging / "deploy"
        actual = {str(path.relative_to(snapshot)) for path in snapshot.rglob("*") if path.is_file()}
        self.assertEqual(actual, set(self.runtime_files) | {"SNAPSHOT"})
        self.assertFalse((snapshot / "assets/auto-mirror-x11").exists())

    def test_missing_required_runtime_file_still_rejected(self):
        (self.source / "lib/image_contract.sh").unlink()
        result = self.copy_snapshot()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("lib/image_contract.sh", result.stderr)
        self.assertFalse((self.staging / "deploy").exists())

    def test_symlink_runtime_file_still_rejected(self):
        path = self.source / "lib/timer.sh"
        path.unlink()
        path.symlink_to(self.source / "deploy.sh")
        result = self.copy_snapshot()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("lib/timer.sh", result.stderr)
        self.assertFalse((self.staging / "deploy").exists())

    def test_preflight_and_chroot_hook_do_not_require_retired_helper(self):
        for path in (ROOT / "lib/checks.sh",
                     ROOT / "config-live/hooks/live/010-pmjs-baseline.hook.chroot"):
            self.assertNotIn("assets/auto-mirror-x11", path.read_text())


if __name__ == "__main__":
    unittest.main(verbosity=2)
