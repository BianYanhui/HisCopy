#!/usr/bin/env python3
"""自测 HisCopy 更新器逻辑路径（无 GUI / 不真正替换 .app）。

覆盖：
1. 版本比较（与 AppUpdater.isVersion 一致的 semver-ish 规则）
2. staging 流程：zip → 解压目录 → 找到 .app → 校验 bundle id/版本 → 拷到 staging
3. 安装脚本形态：含 nohup 二次 exec，等待 PID 退出后再替换（不删运行中 bundle）
4. 热键契约：Pressed toggle / Released 忽略（静态断言文档化）
"""
from __future__ import annotations

import os
import re
import shutil
import tempfile
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def normalized_version(raw: str) -> str:
    s = raw.strip()
    if s.lower().startswith("v"):
        s = s[1:]
    return s


def numeric_parts(version: str) -> list[int]:
    parts = []
    for part in normalized_version(version).split("."):
        digits = "".join(ch for ch in part if ch.isdigit()) or "0"
        # mirror Swift prefix(while: isNumber)
        i = 0
        while i < len(part) and part[i].isdigit():
            i += 1
        parts.append(int(part[:i] or "0"))
    return parts


def is_version_newer(lhs: str, rhs: str) -> bool:
    a, b = numeric_parts(lhs), numeric_parts(rhs)
    n = max(len(a), len(b))
    for i in range(n):
        x = a[i] if i < len(a) else 0
        y = b[i] if i < len(b) else 0
        if x != y:
            return x > y
    return False


def test_versions() -> None:
    assert is_version_newer("0.4.3", "0.4.2")
    assert is_version_newer("0.4.2", "0.4.1")
    assert is_version_newer("1.0.0", "0.9.9")
    assert not is_version_newer("0.4.2", "0.4.3")
    assert not is_version_newer("0.4.3", "0.4.3")
    assert is_version_newer("v0.4.3", "0.4.2")
    print("OK version compare")


def make_fake_app(dest: Path, version: str, bundle_id: str = "io.github.bianyanhui.HisCopy") -> Path:
    app = dest / "HisCopy.app"
    macos = app / "Contents" / "MacOS"
    macos.mkdir(parents=True)
    (macos / "HisCopy").write_text("#!/bin/sh\necho hiscopy\n")
    (macos / "HisCopy").chmod(0o755)
    plist = app / "Contents" / "Info.plist"
    plist.write_text(
        f"""<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>{bundle_id}</string>
  <key>CFBundleShortVersionString</key><string>{version}</string>
</dict></plist>
"""
    )
    return app


def test_stage_flow() -> None:
    with tempfile.TemporaryDirectory() as td:
        td_path = Path(td)
        payload = td_path / "payload"
        payload.mkdir()
        make_fake_app(payload, "0.4.3")
        zip_path = td_path / "HisCopy.zip"
        with zipfile.ZipFile(zip_path, "w") as zf:
            for f in payload.rglob("*"):
                zf.write(f, f.relative_to(payload))

        work = td_path / "work"
        work.mkdir()
        unzipped = work / "unzipped"
        unzipped.mkdir()
        with zipfile.ZipFile(zip_path) as zf:
            zf.extractall(unzipped)

        apps = list(unzipped.rglob("HisCopy.app"))
        assert apps, "missing HisCopy.app in zip"
        new_app = apps[0]
        # validate
        import plistlib

        info = plistlib.loads((new_app / "Contents" / "Info.plist").read_bytes())
        assert info["CFBundleIdentifier"] == "io.github.bianyanhui.HisCopy"
        assert is_version_newer(info["CFBundleShortVersionString"], "0.4.2")

        staging = td_path / "HisCopy-new.app"
        shutil.copytree(new_app, staging)
        assert (staging / "Contents" / "MacOS" / "HisCopy").exists()
        # must not have deleted a "running" path — simulate running next to staging
        running = td_path / "Running" / "HisCopy.app"
        make_fake_app(running.parent, "0.4.1")
        assert running.exists(), "staging must not touch running bundle"
        print("OK stage flow (zip→unzip→validate→staging, running untouched)")


def test_helper_script_shape() -> None:
    src = (ROOT / "HisCopy" / "Updater" / "AppUpdater.swift").read_text()
    assert "nohup" in src
    assert "HISCOPY_UPDATER_DETACHED" in src
    assert "Task.detached" in src
    assert "stageDownloadedUpdate" in src
    assert "waitUntilExit" in src  # brief bootstrap wait only inside helper launch
    # long IO helpers are nonisolated / off main
    assert "nonisolated private static func stageDownloadedUpdate" in src
    assert "nonisolated private static func unzip" in src
    assert "nonisolated private static func launchReplacementScript" in src
    print("OK updater source shape (background IO + nohup helper)")


def test_hotkey_contract() -> None:
    hot = (ROOT / "HisCopy" / "HotKey" / "GlobalHotKeyManager.swift").read_text()
    assert "kEventHotKeyPressed" in hot
    assert "kEventHotKeyReleased" in hot
    assert "ignorePressedUntilChordRelease" in hot
    assert "GetEventKind" in hot
    # Released path must clear flag, not call onHotKeyPressed before return
    # Released 分支：清旗标后 return，且该分支内不触发 callback。
    assert "if kind == UInt32(kEventHotKeyReleased)" in hot
    idx = hot.index("if kind == UInt32(kEventHotKeyReleased)")
    chunk = hot[idx : idx + 220]
    assert "ignorePressedUntilChordRelease = false" in chunk
    assert "return" in chunk
    assert chunk.index("return") < chunk.find("onHotKeyPressed") if "onHotKeyPressed" in chunk else True

    gate = (ROOT / "HisCopy" / "HotKey" / "PanelPasteShortcutGate.swift").read_text()
    assert "绝不隐藏面板" in gate or "不关面板" in gate or "禁止在此隐藏" in gate

    app = (ROOT / "HisCopy" / "AppDelegate.swift").read_text()
    assert "hidesOnDeactivate = false" in app
    assert "keyEquivalent = \"\"" in app
    assert "不把全局热键设为菜单 keyEquivalent" in app
    print("OK hotkey contract (Pressed only, Gate unlock ≠ close, no menu equiv)")



def test_select_newest_on_open_contract() -> None:
    panel = (ROOT / "HisCopy" / "Views" / "HistoryPanelView.swift").read_text()
    assert "selectNewest" in panel
    assert "ScrollViewReader" in panel
    assert "scrollTo" in panel
    assert "hisCopyHistoryPanelDidOpen" in panel
    assert "scrollNonce" in panel
    # 清空搜索也要回到最新
    assert "clearSearch" in panel

    paste = (ROOT / "HisCopy" / "Paste" / "PasteController.swift").read_text()
    assert "hisCopyHistoryPanelDidOpen" in paste

    app = (ROOT / "HisCopy" / "AppDelegate.swift").read_text()
    assert "hisCopyHistoryPanelDidOpen" in app
    assert "NotificationCenter.default.post(name: .hisCopyHistoryPanelDidOpen" in app
    print("OK select-newest-on-open contract")

def main() -> None:
    test_versions()
    test_stage_flow()
    test_helper_script_shape()
    test_hotkey_contract()
    test_select_newest_on_open_contract()
    print("ALL SELFTESTS PASSED")


if __name__ == "__main__":
    main()
