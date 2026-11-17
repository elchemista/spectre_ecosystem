"""Check out only the reviewed dependency coordinates emitted by the CLI matrix."""
import json
import os
from pathlib import Path
import re
import subprocess

sources = json.loads(os.environ.get("DEPENDENCY_SOURCES", "[]"))
root = Path("checkouts").resolve()
resolved = []
for source in sources:
    name, repository, ref = (source[key] for key in ("name", "repository", "default_ref"))
    if not re.fullmatch(r"spectre(?:_[a-z0-9]+)?", name):
        raise ValueError("Invalid dependency name")
    if repository != "elchemista/" + name or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._/-]{0,199}", ref):
        raise ValueError("Invalid dependency coordinate")
    target = root / name
    subprocess.run(["git", "init", str(target)], check=True)
    subprocess.run(["git", "remote", "add", "origin", "https://github.com/" + repository + ".git"], cwd=target, check=True)
    subprocess.run(["git", "fetch", "--depth", "1", "origin", ref], cwd=target, check=True)
    subprocess.run(["git", "checkout", "--detach", "FETCH_HEAD"], cwd=target, check=True)
    sha = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=target, text=True).strip()
    resolved.append({**source, "sha": sha})
    with open(os.environ["GITHUB_ENV"], "a") as output:
        output.write(name.upper() + "_PATH=" + str(target) + "\n")
Path(os.environ["RUNNER_TEMP"], "spectre-dependency-sources.json").write_text(json.dumps(resolved))
