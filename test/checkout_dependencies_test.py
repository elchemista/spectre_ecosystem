"""Exercise the workflow helper against a real local Git repository, offline."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


HELPER = Path(__file__).resolve().parents[1] / "scripts/checkout_dependencies.py"


class CheckoutDependenciesTest(unittest.TestCase):
    def test_resolves_selected_branch_and_exports_exact_checkout(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            repository = root / "source"
            subprocess.run(["git", "init", "-b", "feature/stack-tools-0.4", str(repository)],
                           check=True, capture_output=True)
            subprocess.run(["git", "-c", "user.name=Test", "-c", "user.email=test@example.test",
                            "commit", "--allow-empty", "-m", "fixture"],
                           cwd=repository, check=True, capture_output=True)
            expected = subprocess.check_output(["git", "rev-parse", "HEAD"],
                                               cwd=repository, text=True).strip()
            environment = dict(os.environ, GITHUB_ENV=str(root / "env"), RUNNER_TEMP=str(root),
                               GIT_CONFIG_COUNT="1", GIT_CONFIG_KEY_0=
                               "url.file://" + str(repository) + ".insteadOf",
                               GIT_CONFIG_VALUE_0="https://github.com/elchemista/spectre_ledger.git",
                               DEPENDENCY_SOURCES=json.dumps([{
                                   "name": "spectre_ledger", "repository": "elchemista/spectre_ledger",
                                   "default_ref": "feature/stack-tools-0.4"}]))
            subprocess.run(["python3", str(HELPER)], cwd=root, env=environment,
                           check=True, capture_output=True)
            result = json.loads((root / "spectre-dependency-sources.json").read_text())
            self.assertEqual(result[0]["sha"], expected)
            target = root / "checkouts/spectre_ledger"
            self.assertEqual((root / "env").read_text(), "SPECTRE_LEDGER_PATH=" + str(target) + "\n")
            self.assertEqual(subprocess.check_output(["git", "rev-parse", "HEAD"],
                                                    cwd=target, text=True).strip(), expected)

    def test_rejects_coordinates_outside_the_registry_owner(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            environment = dict(os.environ, GITHUB_ENV=str(root / "env"), RUNNER_TEMP=str(root),
                               DEPENDENCY_SOURCES=json.dumps([{
                                   "name": "spectre_ledger", "repository": "other/spectre_ledger",
                                   "default_ref": "main"}]))
            result = subprocess.run(["python3", str(HELPER)], cwd=root, env=environment,
                                    capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("Invalid dependency coordinate", result.stderr)
            self.assertFalse((root / "checkouts").exists())


if __name__ == "__main__":
    unittest.main()
