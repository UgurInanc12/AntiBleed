"""Static integration checks, not a substitute for macOS runtime testing."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def text(path):
    return (ROOT / path).read_text(encoding="utf-8")


def test_logging_ui_and_lifecycle_are_wired():
    ui = text("AntiBleedApp/UI/DiagnosticsView.swift")
    for token in ["loggingEnabled", "exportDiagnosticLogs", "markDiagnosticProblem"]:
        assert token in ui
    app = text("AntiBleedApp/App/AppState.swift")
    for token in ["setupDiagnostics()", "observeDiagnostics()", 'logEvent("start_requested")',
                  'logEvent("stop_requested")', 'logEvent("devices_changed")', 'logEvent("install_requested")']:
        assert token in app
    diagnostics = text("AntiBleedApp/App/AppState+Diagnostics.swift")
    for token in ["session_start", "session_end", "willTerminateNotification", "health_summary",
                  "problem_marker", "exportSnapshot", '"/usr/bin/ditto"']:
        assert token in diagnostics


def test_audio_callbacks_never_write_logs():
    for path in ["AntiBleedApp/Audio/AggregateCapture.swift", "AntiBleedApp/Audio/VirtualMicWriter.swift",
                 "AntiBleedApp/Realtime/abm_ring.c"]:
        source = text(path)
        assert "DiagnosticLog" not in source
        assert "FileHandle" not in source
    pipeline = text("AntiBleedApp/Audio/AntiBleedPipeline.swift")
    assert "onDiagnosticTransition" in pipeline
    assert "lastTransitionReason" in pipeline


def test_export_guard_is_set_before_panel_opens():
    source = text("AntiBleedApp/App/AppState+Diagnostics.swift")
    export = source.split("func exportDiagnosticLogs()", 1)[1]
    assert export.index("isExportingLogs = true") < export.index("panel.begin")
    assert "guard response == .OK" in export


def test_health_poll_does_not_republish_unchanged_status_or_query_login():
    source = text("AntiBleedApp/App/AppState+Diagnostics.swift")
    context = source.split("func diagnosticContext()", 1)[1].split("func logEvent", 1)[0]
    assert "SMAppService.mainApp.status" not in context
    assert "if logStatus != currentStatus" in source


def test_packaging_records_build_identity():
    assert "AntiBleedBuildRevision" in text("Scripts/package.sh")
