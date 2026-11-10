#!/usr/bin/env python3
"""Guarded, idempotent G3 UI/build installer.

It refuses unknown file layouts instead of silently
overwriting existing G0-G2 code.
"""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def apply(
    path: Path,
    before: str,
    after: str,
) -> bool:
    current = path.read_text(encoding="utf-8")

    if after in current:
        return False

    count = current.count(before)

    if count != 1:
        raise RuntimeError(
            f"Cannot safely patch {path}: "
            f"expected 1 anchor, found {count}"
        )

    path.write_text(
        current.replace(
            before,
            after,
            1,
        ),
        encoding="utf-8",
    )

    print(
        f"UPDATED {path.relative_to(ROOT)}"
    )
    return True


def main() -> None:
    app = (
        ROOT
        / "apps/macos/Sources/AIVideoApp.swift"
    )
    build = (
        ROOT / "tools/build_macos_app.sh"
    )

    apply(
        app,
        "    private var projectStore: ProjectStore?",
        "    var projectStore: ProjectStore? "
        "// actor remains single canonical writer; exposed to G3 UI only",
    )

    apply(
        app,
        "                    G2ReviewSectionView(state: state)",
        "                    G2ReviewSectionView(state: state)\n"
        "                    G3ConsoleView(state: state)",
    )

    apply(
        build,
        "  packages/AIVideoCore/Sources/Storage/ProjectStore.swift \\\n",
        "  packages/AIVideoCore/Sources/Storage/ProjectStore.swift \\\n"
        "  packages/AIVideoCore/Sources/Storage/G3ProjectStore.swift \\\n",
    )

    apply(
        build,
        "  apps/macos/Sources/AIVideoApp.swift \\\n",
        "  apps/macos/Sources/AIVideoApp.swift \\\n"
        "  apps/macos/Sources/G3ConsoleView.swift \\\n",
    )

    print(
        "G3 UI enabled. "
        "Test on Mac with ./tools/build_macos_app.sh"
    )


if __name__ == "__main__":
    main()
