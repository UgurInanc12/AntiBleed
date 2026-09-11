"""Source-level wiring checks for the macOS-only layer, not runtime tests."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def source(path):
    return (ROOT / path).read_text(encoding="utf-8")


def test_stop_reports_whether_resources_were_released():
    code = source("AntiBleedApp/Audio/AntiBleedPipeline.swift")
    assert "public func stop() -> Bool" in code
    assert "guard pipeline.stop() else" in source("AntiBleedApp/App/AppState.swift")


def test_route_toggle_applies_without_waiting_for_hardware_event():
    code = source("AntiBleedApp/UI/SettingsView.swift")
    assert ".onChange(of: appState.pauseWhenOutputNotDefault)" in code
    assert "appState.syncOutputRoutePause()" in code


def test_device_loss_coalesces_selection_changes_before_restart():
    code = source("AntiBleedApp/App/AppState.swift")
    handler = code.split("private func handleDevicesChanged()", 1)[1].split("var referenceOutputIsDefault", 1)[0]
    assert handler.count("restart()") <= 1
    assert "guard !isInstallingDriver else" in handler


def test_permission_request_can_be_cancelled_by_stop():
    code = source("AntiBleedApp/App/AppState.swift")
    assert "startTask?.cancel()" in code
    assert "guard !Task.isCancelled" in code


def test_installer_stops_before_restarting_audio_service():
    code = source("AntiBleedApp/App/AppState.swift")
    install = code.split("func installDriver()", 1)[1].split("func stop()", 1)[0]
    assert install.index("guard stop() else") < install.index("DriverInstaller.install()")
    assert "for _ in 0..<20" in install


def test_installer_prepares_replacement_before_removing_old_driver():
    code = source("AntiBleedApp/Audio/DriverInstaller.swift")
    assert "mktemp -d" in code
    assert 'trap ' in code
    assert 'let script = "rm -rf' not in code
    assert 'UUID().uuidString' in code


def test_packaged_zip_is_rebuilt_after_stapling():
    code = source("Scripts/package.sh")
    assert code.rfind("ditto -c -k --keepParent") > code.index('xcrun stapler staple "${APP}"')


def test_audio_retry_clears_stale_errors_before_resolving():
    capture = source("AntiBleedApp/Audio/AggregateCapture.swift")
    create = capture.split("public func create(", 1)[1].split("public func start()", 1)[0]
    assert "lastError = nil" in create
    writer = source("AntiBleedApp/Audio/VirtualMicWriter.swift")
    resolve = writer.split("public func resolve()", 1)[1].split("public var isResolved", 1)[0]
    assert "lastError = nil" in resolve
    assert "deviceID = AudioObjectID(kAudioObjectUnknown)" in resolve


def test_capture_checks_each_buffer_before_reading_samples():
    code = source("AntiBleedApp/Audio/AggregateCapture.swift")
    assert "first.mNumberChannels > 0" in code
    assert "Int(buf.mDataByteSize) >= frames * ch * MemoryLayout<Float>.size" in code


def test_minimum_os_matches_process_tap_requirement():
    assert '.macOS("14.2")' in source("Package.swift")
