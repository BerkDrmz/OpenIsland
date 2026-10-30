#!/usr/bin/env python3
"""Run actual-source visibility and worker-cancellation contracts without the app.

No visible windows, real reminders, camera, audio capture, or user data. The Nook
contract compiles the actual panel's lifecycle/layout with service spies, not its
widgets. Storage checks compile the actual SystemMonitor with injected fake I/O.
An opt-in metadata benchmark compares real read-only volume metadata separately.
"""
from pathlib import Path
import argparse, os, platform, subprocess, tempfile
ROOT = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser()
parser.add_argument('--metadata-bench', action='store_true')
args = parser.parse_args()
def run(command):
    subprocess.run([str(x) for x in command], cwd=ROOT, check=True)
with tempfile.TemporaryDirectory(prefix='openisland-efficiency-') as temp:
    out = Path(temp)
    flags = ['swiftc', '-swift-version', '6', '-O', '-target', platform.machine()+'-apple-macosx14.0', '-parse-as-library']
    run(flags + ['-emit-library', '-static', '-emit-module', '-module-name', 'IslandCore',
                 *sorted((ROOT/'Sources/IslandCore').glob('*.swift')), '-o', out/'libIslandCore.a',
                 '-emit-module-path', out/'IslandCore.swiftmodule'])
    source = (ROOT/'Deney/Sources/Panels/NookPanelView.swift').read_text()
    assert source.count('// MARK: - Medya') == 1
    (out/'NookActual.swift').write_text(source.split('// MARK: - Medya')[0])
    linking = ['-I',out,'-L',out,'-lIslandCore']
    run(flags+linking+[out/'NookActual.swift',ROOT/'Deney/Tests/NookVisibilitySupport.swift','-o',out/'nook-check'])
    run([out/'nook-check'])
    system = ROOT/'Sources/OpenIsland/Features/System'
    run(flags+linking+[system/(n+'.swift') for n in ['PrivateAPIGuard','SystemSensors','PrivateControls','StorageVolumes','SystemMonitor']]
        +[ROOT/'Deney/Tests/StorageLifecycleCheck.swift','-o',out/'storage-check'])
    run([out/'storage-check'])
    kit = (ROOT/'Deney/Sources/Panels/PanelKit.swift').read_text()
    (out/'ObserverActual.swift').write_text('import Foundation\n' + kit[kit.index('@MainActor\nfinal class Observer'):kit.index('/// Tam saniye')])
    run(flags+[out/'ObserverActual.swift',ROOT/'Deney/Tests/ObserverLifecycleCheck.swift','-o',out/'observer-check'])
    run([out/'observer-check'])
    if args.metadata_bench:
        old = subprocess.check_output(['git','show','64f06a933064731e36adeb526ee7fc9296eb47d7:Sources/OpenIsland/Features/System/StorageVolumes.swift'],cwd=ROOT,text=True)
        (out/'StorageBaseline.swift').write_text(old.replace('struct StorageVolume:','struct BaselineStorageVolume:'))
        run(flags+[out/'StorageBaseline.swift',system/'StorageVolumes.swift',ROOT/'Deney/Tests/StorageMetadataBench.swift','-o',out/'metadata-bench'])
        run([out/'metadata-bench'])
