"""Validate the on-device --art-audit output without a rendering dependency."""
import json
import math
from pathlib import Path
import sys

root = Path(sys.argv[1])
catalogue = json.loads((root / "manifest.json").read_text())
models = json.loads((root / "models.json").read_text())
assert len(catalogue) == 34
assert len({entry["hash"] for entry in catalogue}) == 34
assert {(entry["kind"], entry["id"]) for entry in catalogue} == {
    (kind, theme) for kind in ("board", "pieces") for theme in [*range(1,11),101,102,103,104,105,121,122]
}
assert len(models) == 204
assert {(entry["theme"], entry["piece"]) for entry in models} == {
    (theme, symbol) for theme in [*range(1,11),101,102,103,104,105,121,122] for symbol in "PNBRQKpnbrqk"
}
assert len(list(root.glob("set-full-*.png"))) == 17
for kind, count in (("board", 1), ("pieces", 1), ("all-pieces", 2)):
    assert len(list(root.glob(f"{kind}-[0-9]*.png"))) == count

errors, stage_count, shard_count = [], 0, 0
for entry in catalogue:
    slots = 8 if entry["kind"] == "board" else 6
    assert len(entry["shardRevealFractions"]) == slots
    shard_count += slots
    for fractions in [entry["revealFractions"], *entry["shardRevealFractions"]]:
        assert len(fractions) == slots + 1
        assert fractions[0] == 0 and fractions[-1] == 1
        assert all(a <= b for a, b in zip(fractions, fractions[1:]))
        errors.extend(abs(value - index / slots) for index, value in enumerate(fractions))
        stage_count += len(fractions)
assert max(errors) < 0.02, "Visible-area reveal deviates by more than two percentage points"
for entry in models:
    assert entry["asset"].startswith("atelier-"), "No fallback primitive model may ship"
    assert entry["triangles"] > 25000, "Actual exported mesh must load"
    bounds = entry["bounds"]
    assert len(bounds) == 6 and all(math.isfinite(value) for value in bounds)
    assert all(bounds[index + 3] > bounds[index] for index in range(3))
    assert max(abs(value) for value in bounds) < 1.5, entry
    assert bounds[1] > -0.025, (entry, "Sculpture must stay above its foot")
    if entry["piece"].lower() in "kqb":
        assert bounds[4] > 0.80, (entry, "Identity crown must remain above its body")

report = {
    "status": "passed",
    "catalogueItems": len(catalogue),
    "uniquePreviewHashes": len({entry["hash"] for entry in catalogue}),
    "pieceModels": len(models),
    "individualShards": shard_count,
    "revealStages": stage_count,
    "maximumRevealFractionError": max(errors),
    "catalogueAndShardRenderSeconds": sum(entry["seconds"] for entry in catalogue),
    "maxPieceHeight": max(entry["bounds"][4] - entry["bounds"][1] for entry in models),
}
(root / "verification.json").write_text(json.dumps(report, indent=2) + "\n")
print(json.dumps(report, indent=2))
