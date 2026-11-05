import tempfile
import unittest
from pathlib import Path

from install_global_window_routing import update


class RoutingBlockTests(unittest.TestCase):
    def test_known_upgrade_and_check_only(self):
        snippet = Path(__file__).with_name('global-window-routing.md').read_text()
        previous = Path(__file__).with_name('global-window-routing-v0.2.0.md').read_text()
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / 'AGENTS.md'
            original = '# 保留规则\n' + previous + '\n# 保留末尾\n'
            target.write_text(original)
            self.assertEqual(update(target, snippet, previous=[previous], check=True), 'would-update')
            self.assertEqual(target.read_text(), original)
            self.assertFalse((target.parent / 'backups').exists())
            update(target, snippet, previous=[previous])
            self.assertTrue(target.read_text().startswith('# 保留规则\n'))
            self.assertTrue(target.read_text().endswith('\n# 保留末尾\n'))
            self.assertIn(snippet.strip(), target.read_text())

    def test_preserve_existing_rules_idempotence_and_remove(self):
        snippet = Path(__file__).with_name('global-window-routing.md').read_text()
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / 'AGENTS.md'
            original = '# 用户规则\n\n保留这句话。\n'
            target.write_text(original)
            backup = Path(update(target, snippet))
            self.assertEqual(backup.read_text(), original)
            installed = target.read_text()
            self.assertTrue(installed.startswith(original))
            self.assertEqual(update(target, snippet), 'unchanged')
            target.write_text(installed + '\n新任务的规则。\n')
            update(target, snippet, remove=True)
            self.assertTrue(target.read_text().startswith(original))
            self.assertIn('新任务的规则。', target.read_text())
            self.assertNotIn('codex-external-window-routing', target.read_text())

    def test_edited_block_is_preserved(self):
        snippet = Path(__file__).with_name('global-window-routing.md').read_text()
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / 'AGENTS.md'
            update(target, snippet)
            edited = target.read_text().replace(
                '<!-- codex-external-window-routing v1 end -->',
                '\n用户另外修改的规则。\n<!-- codex-external-window-routing v1 end -->',
            )
            self.assertNotEqual(edited, target.read_text())
            target.write_text(edited)
            with self.assertRaises(ValueError):
                update(target, snippet, remove=True)
            self.assertEqual(target.read_text(), edited)


if __name__ == '__main__':
    unittest.main()
