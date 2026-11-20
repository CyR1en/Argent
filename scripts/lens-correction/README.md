# Measure decode routes
Run from the repository root with the three CC0 ARWs in `samples/`.
Use Xcode's toolchain. For release app-test compile failures, use the [targeted runner](../../docs/research/lens-correction.md#decode-routes-with-lens-correction-off).
Export `ARGENT_LENS_FRAMES` as a folder of additional ARWs, or leave it unset to skip them.
Save the log outside the repository. The script writes `routes.csv` beside it:
```sh
ARGENT_MEASURE=1 swift test -c release -Xswiftc -enable-testing --filter LensMeasureTests/routes > /tmp/lens-routes.log 2>&1
/Users/cyr1en/Developer/Argent/.venv/bin/python -I scripts/lens-correction/route_probe.py /tmp/lens-routes.log
/Users/cyr1en/Developer/Argent/.venv/bin/python -I scripts/lens-correction/route_probe.py --self-test
```

# Check the capture session
`capture_check.py` reads the folder of Appendix F captures in `docs/lens-correction-plan.md`. It wants `<lens>/flats/*.ARW`, `<lens>/charts/*.ARW` and `real/*.ARW`, with `<lens>` starting with `viltrox`, `sirui` or `tamron`.
It rejects a flat that is not uncompressed full-frame raw at ISO 100, that is clipped, whose centre is far from half of the range, or whose mirrored halves differ by more than 5%. Then it prints each setting that is short of frames. Exit status 0 means nothing is missing.
```sh
/Users/cyr1en/Developer/Argent/.venv/bin/python -I scripts/lens-correction/capture_check.py CAPTURES
/Users/cyr1en/Developer/Argent/.venv/bin/python -I scripts/lens-correction/capture_check.py --self-test
```
