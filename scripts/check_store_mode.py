#!/usr/bin/env python3
"""Compile and execute the same operator gate source in normal and Store modes."""
import json
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
PROBE = r'''
import Foundation
@main struct Probe {
    static func main() {
        let domain = "ScrollStitch.StoreProbe.\(UUID().uuidString)"
        let prefs = UserDefaults(suiteName: domain)!
        defer { prefs.removePersistentDomain(forName: domain) }
        prefs.set("capture", forKey: "m1OperatorFixture")
        let result = OperatorFixtureContext.resolve(arguments:["--m1-fixture", "collage"], preferences:prefs)
#if SCROLLSTITCH_STORE
        precondition(!BuildMode.operatorToolsEnabled)
        precondition(result == nil)
        precondition(prefs.string(forKey:"m1OperatorFixture") == "capture")
        precondition(OperatorFixtureContext.resolve(arguments:["--m1-production"], preferences:prefs) == nil)
        precondition(prefs.string(forKey:"m1OperatorFixture") == "capture")
#else
        precondition(BuildMode.operatorToolsEnabled)
        precondition(result == "collage")
        precondition(OperatorFixtureContext.resolve(arguments:["--m1-production"], preferences:prefs) == nil)
        precondition(prefs.string(forKey:"m1OperatorFixture") == nil)
#endif
        precondition(BuildMode.captureCreationEnabled)
        print("operator and capture capabilities verified")
    }
}
'''
with tempfile.TemporaryDirectory(prefix='scrollstitch-store-probe-') as directory:
    directory = Path(directory)
    source = directory / 'Probe.swift'
    source.write_text(PROBE)
    modes = {'developer':[], 'app-store':['SCROLLSTITCH_STORE']}
    for mode, flags in modes.items():
        command = ['swiftc', '-parse-as-library', '-o', str(directory / mode), str(source),
                   str(ROOT / 'Sources/ScrollStitchCore/BuildMode.swift'), str(ROOT / 'Sources/ScrollStitchCore/OperatorFixtureContext.swift')]
        for flag in flags:
            command += ['-D', flag]
        subprocess.run(command, check=True, capture_output=True)
        subprocess.run([str(directory / mode)], check=True, capture_output=True)
# Execute the actual storage API in both compiled editions, in disposable stores.
with tempfile.TemporaryDirectory(prefix='scrollstitch-capability-probe-') as directory:
    for mode, flags in {'developer':[], 'app-store':['-Xswiftc','-DSCROLLSTITCH_STORE']}.items():
        scratch=ROOT/'.build'/('capability-'+mode)
        subprocess.run(['swift','build','--scratch-path',str(scratch),'--product','StoreProbe',*flags],
                       cwd=ROOT,check=True,capture_output=True)
        binary=subprocess.check_output(['swift','build','--scratch-path',str(scratch),'--show-bin-path',*flags],
                                       cwd=ROOT,text=True).strip()
        subprocess.run([str(Path(binary)/'StoreProbe'),str(Path(directory)/mode),'capture-capability','-'],
                       cwd=ROOT,check=True,capture_output=True)
model=(ROOT/'App/PrototypeModel.swift').read_text()
for signature in ('func runRequestedInputDiagnosticIfReady() {','func runInputDiagnostics(requireOffline: Bool = true) {'):
    assert signature+'\n        guard BuildMode.operatorToolsEnabled else { return }' in model
assert 'try WorkspaceRecovery.read(store)' in model
print(json.dumps({'status':'passed','native_probe_modes':list(modes),
                  'storage_capability_modes':['developer','app-store'],
                  'boundary':'compiled capability and actual TaskStore API; native Store bundle linkage is verified separately'}))
