"""Exercise the install shell transaction in a temp tree, without elevation/HAL.
Only macOS-specific commands are replaced with explicit test commands.
"""
from pathlib import Path
import re
import shutil
import subprocess

import pytest

ROOT = Path(__file__).resolve().parents[1]


@pytest.mark.parametrize("failure", [None, "copy", "verify", "move"])
def test_driver_replacement_preserves_previous_install_on_failure(tmp_path, failure):
    bash = shutil.which("bash")
    if not bash:
        pytest.skip("bash is required for the install transaction test")
    hal = tmp_path / "HAL"
    hal.mkdir()
    installed = hal / "AntiBleed.driver"
    installed.mkdir()
    (installed / "version").write_text("old")
    stage = tmp_path / "stage.driver"
    stage.mkdir()
    (stage / "version").write_text("new")
    code = (ROOT / "AntiBleedApp/Audio/DriverInstaller.swift").read_text()
    match = re.search(r'let script = """\n(.*?)\n        """', code, re.S)
    assert match is not None
    script = match.group(1)
    script = script.replace("\\(installedPath)", installed.as_posix())
    script = script.replace("\\(stage)", stage.as_posix())
    script = script.replace("/Library/Audio/Plug-Ins/HAL", hal.as_posix())
    script = script.replace('/usr/bin/ditto', 'false' if failure == "copy" else '/bin/cp -R')
    script = script.replace('/usr/bin/codesign --verify --strict', 'false' if failure == "verify" else 'true')
    script = script.replace('/usr/sbin/chown -R root:wheel', 'true')
    script = script.replace('/bin/launchctl kickstart -k system/com.apple.audio.coreaudiod || /usr/bin/killall coreaudiod', 'true')
    if failure == "move":
        script = script.replace('/bin/mv "$work/new" "$dst"', 'false')
    result = subprocess.run([bash, "-c", script], capture_output=True, text=True, timeout=10)
    assert (result.returncode == 0) == (failure is None), result.stderr
    assert (installed / "version").read_text() == ("new" if failure is None else "old")
    assert list(hal.iterdir()) == [installed]
