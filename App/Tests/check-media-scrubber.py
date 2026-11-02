#!/usr/bin/env python3
"""Compile the actual scrubber with deterministic service/render spies."""
from pathlib import Path
import tempfile,subprocess,platform
root=Path(__file__).resolve().parents[2]
with tempfile.TemporaryDirectory(prefix='openisland-scrubber-') as temp:
 out=Path(temp)
 text=(root/'App/Sources/Panels/MediaPanelView.swift').read_text()
 marker='@MainActor\nfinal class MediaScrubberView:'
 assert text.count(marker)==1
 clock=(root/'Sources/OpenIsland/UI/Components.swift').read_text().split('extension TimeInterval {')[1].split('\n}')[0]
 (out/'ActualScrubber.swift').write_text('import AppKit\nimport IslandCore\n'+marker+text.split(marker)[1]+'\nextension TimeInterval {'+clock+'\n}\n')
 flags=['swiftc','-swift-version','6','-O','-target',platform.machine()+'-apple-macosx14.0','-parse-as-library','-module-cache-path',str(out/'cache')]
 subprocess.run(flags+['-emit-library','-static','-emit-module','-module-name','IslandCore',*map(str,sorted((root/'Sources/IslandCore').glob('*.swift'))),'-o',str(out/'libIslandCore.a'),'-emit-module-path',str(out/'IslandCore.swiftmodule')],check=True)
 source=root/'Sources/OpenIsland/Features/Media/NowPlaying.swift'
 subprocess.run(flags+['-I',str(out),'-L',str(out),'-lIslandCore',str(source),str(out/'ActualScrubber.swift'),str(root/'App/Tests/MediaScrubberStepCheck.swift'),'-o',str(out/'check')],check=True)
 subprocess.run([str(out/'check')],check=True)
