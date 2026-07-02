#!/usr/bin/env python3
"""Nix バイナリキャッシュから Lean 4 toolchain を取得して elan に登録するスクリプト。

通常の環境では不要(elan が公式リリースをダウンロードできるため)。
このスクリプトは、elan.lean-lang.org / release.lean-lang.org / GitHub リリースへの
アクセスが遮断された隔離環境(Claude Code のリモート実行環境など)向けの迂回手段。
cache.nixos.org と hydra.nixos.org に到達できることが前提。

やること:
  1. リポジトリの lean-toolchain が要求する版を特定する
     - PINNED に載っていればその store path(完全に再現的)
     - 無ければ Hydra の nixpkgs unstable 最新を照会し、版が一致する場合のみ採用。
       不一致なら対処法を示して失敗する(黙って別の版を入れない)
  2. narinfo の References を再帰的に辿って closure 全体を列挙
  3. 各 NAR (zstd/xz 圧縮) をダウンロードし、NAR 形式を自前でパースして /nix/store に展開
  4. `elan toolchain link` で公式名 (leanprover/lean4:vX.Y.Z) として登録

**toolchain を更新するとき**: lean-toolchain を書き換えたら、新しい版の
store path を PINNED に追記すること(Hydra の
https://hydra.nixos.org/job/nixpkgs/unstable/lean4.x86_64-linux/latest で確認できる)。

使い方: sudo python3 setup-lean-nix.py
"""

import os
import re
import struct
import subprocess
import sys
import urllib.request

CACHE = "https://cache.nixos.org"
HYDRA = "https://hydra.nixos.org/job/nixpkgs/unstable/lean4.x86_64-linux/latest"
STORE = "/nix/store"

# lean-toolchain の版 → cache.nixos.org 上の store path(検証済みのものを固定)
PINNED = {
    "leanprover/lean4:v4.30.0": "9926168h3f7a2nm5qykd8nc2cvh0f004-lean4-4.30.0",
}


def fetch(url, accept=None):
    req = urllib.request.Request(url, headers={"Accept": accept} if accept else {})
    return urllib.request.urlopen(req, timeout=300)


def wanted_toolchain():
    """リポジトリの lean-toolchain が要求する版(例: leanprover/lean4:v4.30.0)。"""
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "lean-toolchain")
    with open(path) as f:
        return f.read().strip()


def resolve_root(want):
    """要求された版の store path 名を決める。PINNED 優先、無ければ Hydra 照会。"""
    if want in PINNED:
        print(f"PINNED: {want} -> {PINNED[want]}")
        return PINNED[want]
    import json
    with fetch(HYDRA, accept="application/json") as r:
        d = json.load(r)
    name = d["nixname"]  # 例: lean4-4.30.0
    hydra_toolchain = "leanprover/lean4:v" + name.removeprefix("lean4-")
    out = d["buildoutputs"]["out"]["path"]
    print(f"Hydra: {name} -> {out}")
    if hydra_toolchain != want:
        sys.exit(
            f"版の不一致: lean-toolchain は {want} を要求しているが、"
            f"nixpkgs unstable の最新は {hydra_toolchain}。\n"
            f"対処: (a) この版の store path を PINNED に追記する、"
            f"(b) lean-toolchain を {hydra_toolchain} に更新して PINNED にも追記する。\n"
            f"黙って別の版を入れることはしない(lake が解決できなくなるため)。"
        )
    return out.removeprefix("/nix/store/")


def parse_narinfo(store_hash):
    with fetch(f"{CACHE}/{store_hash}.narinfo") as r:
        text = r.read().decode()
    info = {}
    for line in text.splitlines():
        k, _, v = line.partition(": ")
        info[k] = v
    return info


class NarReader:
    """NAR (Nix ARchive) 形式のストリーミング展開。

    形式: 8バイトLEの長さ + データ + 8バイト境界へのパディング、の列。
    先頭マジックは "nix-archive-1"。ノードは regular/symlink/directory の再帰構造。
    """

    def __init__(self, stream):
        self.f = stream

    def read_exact(self, n):
        buf = b""
        while len(buf) < n:
            chunk = self.f.read(n - len(buf))
            if not chunk:
                raise EOFError("NAR ストリームが途中で終了")
            buf += chunk
        return buf

    def read_int(self):
        return struct.unpack("<Q", self.read_exact(8))[0]

    def read_str(self):
        n = self.read_int()
        data = self.read_exact(n)
        pad = (8 - n % 8) % 8
        if pad:
            self.read_exact(pad)
        return data

    def expect(self, s):
        got = self.read_str()
        if got != s:
            raise ValueError(f"NAR 形式エラー: {s!r} を期待したが {got!r}")

    def unpack(self, dest):
        self.expect(b"nix-archive-1")
        self._node(dest)

    def _node(self, path):
        self.expect(b"(")
        self.expect(b"type")
        t = self.read_str()
        if t == b"regular":
            executable = False
            tok = self.read_str()
            if tok == b"executable":
                self.expect(b"")
                executable = True
                tok = self.read_str()
            if tok != b"contents":
                raise ValueError(f"NAR 形式エラー: contents 期待、実際 {tok!r}")
            size = self.read_int()
            with open(path, "wb") as out:
                left = size
                while left > 0:
                    chunk = self.f.read(min(1 << 20, left))
                    if not chunk:
                        raise EOFError("NAR ストリームが途中で終了")
                    out.write(chunk)
                    left -= len(chunk)
            pad = (8 - size % 8) % 8
            if pad:
                self.read_exact(pad)
            if executable:
                os.chmod(path, 0o755)
            self.expect(b")")
        elif t == b"symlink":
            self.expect(b"target")
            target = self.read_str().decode()
            os.symlink(target, path)
            self.expect(b")")
        elif t == b"directory":
            os.makedirs(path, exist_ok=True)
            while True:
                tok = self.read_str()
                if tok == b")":
                    break
                if tok != b"entry":
                    raise ValueError(f"NAR 形式エラー: entry 期待、実際 {tok!r}")
                self.expect(b"(")
                self.expect(b"name")
                name = self.read_str().decode()
                if name in ("", ".", "..") or "/" in name:
                    raise ValueError(f"不正なエントリ名: {name!r}")
                self.expect(b"node")
                self._node(os.path.join(path, name))
                self.expect(b")")
        else:
            raise ValueError(f"未知のノード型: {t!r}")


def install_path(store_hash_name):
    """store path 1つ分を cache からダウンロードして展開。References を返す。"""
    store_hash = store_hash_name.split("-")[0]
    dest = f"{STORE}/{store_hash_name}"
    info = parse_narinfo(store_hash)
    refs = [r for r in info.get("References", "").split() if r and r != store_hash_name]
    if os.path.exists(dest):
        print(f"  済み: {store_hash_name}")
        return refs
    comp = info.get("Compression", "xz")
    decomp = {"zstd": ["zstd", "-dc"], "xz": ["xz", "-dc"], "none": ["cat"]}[comp]
    url = f"{CACHE}/{info['URL']}"
    size = int(info.get("FileSize", 0))
    print(f"  取得: {store_hash_name} ({size / 1e6:.0f}MB, {comp})", flush=True)
    tmp = dest + ".part"
    if os.path.lexists(tmp):
        import shutil
        shutil.rmtree(tmp) if os.path.isdir(tmp) and not os.path.islink(tmp) else os.remove(tmp)
    nar_file = f"/tmp/nar-{store_hash}{'.zst' if comp == 'zstd' else '.xz'}"
    # 長時間ストリームは途中切断され得るので、curl の resume (-C -) で
    # ファイルに落としてから展開する
    # 注意: narinfo の FileSize は CDN 側の再圧縮で実際の配信サイズと
    # ずれることがあるため、サイズ比較ではなく圧縮形式自体の整合性
    # チェック (zstd -t / xz -t) で完全性を検証する
    test_cmd = {"zstd": ["zstd", "-t"], "xz": ["xz", "-t"], "none": None}[comp]
    for attempt in range(8):
        r = subprocess.run(
            ["curl", "-sS", "--fail", "-C", "-", "--max-time", "600",
             "--retry", "3", "-o", nar_file, url],
        )
        if r.returncode == 0:
            if test_cmd is None or subprocess.run(
                test_cmd + [nar_file], capture_output=True
            ).returncode == 0:
                break
            # 壊れたファイルは resume できないので捨ててやり直す
            os.remove(nar_file)
        got = os.path.getsize(nar_file) if os.path.exists(nar_file) else 0
        print(f"    ダウンロード再試行 {attempt + 1} (exit {r.returncode}, "
              f"{got} bytes)", flush=True)
    else:
        raise RuntimeError(f"{url} のダウンロードに失敗")
    p = subprocess.Popen(decomp + [nar_file], stdout=subprocess.PIPE)
    try:
        NarReader(p.stdout).unpack(tmp)
    finally:
        p.stdout.close()
        p.wait()
    if p.returncode != 0:
        raise RuntimeError(f"{decomp[0]} が exit {p.returncode}")
    os.remove(nar_file)
    os.rename(tmp, dest)
    return refs


def main():
    os.makedirs(STORE, exist_ok=True)
    want = wanted_toolchain()
    print(f"lean-toolchain: {want}")
    root_name = resolve_root(want)
    todo, done = [root_name], set()
    while todo:
        name = todo.pop()
        if name in done:
            continue
        done.add(name)
        for ref in install_path(name):
            if ref not in done:
                todo.append(ref)
    lean_dir = f"{STORE}/{root_name}"
    ver = subprocess.run([f"{lean_dir}/bin/lean", "--version"], capture_output=True, text=True)
    print(ver.stdout.strip() or ver.stderr.strip())
    m = re.search(r"version (\d+\.\d+\.\d+)", ver.stdout)
    if not m:
        sys.exit("lean --version の出力からバージョンを特定できませんでした")
    actual = f"leanprover/lean4:v{m.group(1)}"
    if actual != want:
        sys.exit(f"取得したバイナリの版 {actual} が lean-toolchain の {want} と一致しない")
    # 公式名で link しておくと lean-toolchain ファイルがそのまま解決される
    subprocess.run(["elan", "toolchain", "link", actual, lean_dir], check=True)
    print(f"elan に登録完了: {actual} -> {lean_dir}")


if __name__ == "__main__":
    main()
