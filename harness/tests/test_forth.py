from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

from livingdict.forth import ForthError, ForthVM
from livingdict.host import CapabilityHost


def _host(root: Path) -> CapabilityHost:
    return CapabilityHost(
        workspace=root,
        allowed_effects=("read", "write", "exec"),
        allowed_globs=("app/*.py", "src/*.py"),
        forbidden_globs=("tests/**",),
    )


class ForthVMTests(unittest.TestCase):
    def test_stack_and_colon(self) -> None:
        tmp = tempfile.TemporaryDirectory()
        root = Path(tmp.name)
        try:
            vm = ForthVM(_host(root))
            vm.interpret("3 4 +")
            self.assertEqual(vm.stack, [7])
            vm.stack.clear()
            vm.interpret(": SQUARE DUP * ; 5 SQUARE")
            self.assertEqual(vm.stack, [25])
            vm.stack.clear()
            vm.interpret("0 IF 99 ELSE 42 THEN")
            self.assertEqual(vm.stack, [42])
        finally:
            tmp.cleanup()

    def test_comments_and_strings(self) -> None:
        tmp = tempfile.TemporaryDirectory()
        root = Path(tmp.name)
        try:
            vm = ForthVM(_host(root))
            vm.interpret('S" hello world" \\ ignored\n( also ignored )')
            self.assertEqual(vm.stack, ["hello world"])
        finally:
            tmp.cleanup()

    def test_unknown_and_underflow(self) -> None:
        tmp = tempfile.TemporaryDirectory()
        root = Path(tmp.name)
        try:
            vm = ForthVM(_host(root))
            with self.assertRaises(ForthError) as unknown:
                vm.interpret("MYSTERY")
            self.assertEqual(unknown.exception.code, "unknown")
            with self.assertRaises(ForthError) as under:
                vm.interpret("DROP")
            self.assertEqual(under.exception.code, "underflow")
        finally:
            tmp.cleanup()

    def test_use_artifact_write(self) -> None:
        tmp = tempfile.TemporaryDirectory()
        root = Path(tmp.name)
        (root / "app").mkdir()
        (root / "app" / "config.py").write_text("OLD\n", encoding="utf-8")
        try:
            vm = ForthVM(_host(root), artifacts={"app/config.py": "NEW\n"})
            vm.interpret('S" app/config.py" USE-ARTIFACT S" app/config.py" WRITE-FILE')
            self.assertEqual((root / "app" / "config.py").read_text(encoding="utf-8"), "NEW\n")
            self.assertEqual(vm.stack[0]["path"], "app/config.py")
        finally:
            tmp.cleanup()
