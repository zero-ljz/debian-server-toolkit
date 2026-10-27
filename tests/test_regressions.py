"""Behavioral regressions at external-command boundaries; Linux, no root required."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[1]
SCRIPT = REPO / "ccc.sh"
FAKES = Path(__file__).with_name("fake_commands.py")


class RegressionTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.crypto = tempfile.TemporaryDirectory(prefix="ccc-crypto-")
        cls.crypto_root = Path(cls.crypto.name)
        for name, days in (("old", 1), ("new", 90)):
            args = ["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
                    "-subj", "/CN=example.com", "-addext", "subjectAltName=DNS:example.com",
                    "-days", str(days), "-keyout", str(cls.crypto_root / (name + ".key")),
                    "-out", str(cls.crypto_root / (name + ".crt"))]
            if name == "new":
                # Renew using the same domain key.
                args = ["openssl", "req", "-x509", "-key", str(cls.crypto_root / "old.key"),
                        "-subj", "/CN=example.com", "-addext", "subjectAltName=DNS:example.com",
                        "-days", str(days), "-out", str(cls.crypto_root / "new.crt")]
            subprocess.run(args, check=True, capture_output=True)

    @classmethod
    def tearDownClass(cls):
        cls.crypto.cleanup()

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="ccc-tests-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.state = {}
        self.save_state()
        self.definitions = self.root / "definitions.sh"
        self.definitions.write_text(SCRIPT.read_text().split("# 获取函数名\n", 1)[0])
        # Use the actual Python interpreter in wrappers even when python3 is mocked.
        wrapper = self.root / "command-wrapper"
        wrapper.write_text("#!" + sys.executable + "\n" + FAKES.read_text())
        wrapper.chmod(0o755)
        for name in ("sudo", "docker", "nginx", "apt", "apt-get", "git", "npm", "python3",
                     "curl", "wget", "systemctl"):
            (self.bin / name).symlink_to(wrapper)
        for directory in ("fs/etc/systemd/system", "fs/usr/local/bin"):
            (self.root / directory).mkdir(parents=True)
        self.env = dict(os.environ, PATH=str(self.bin) + ":" + os.environ["PATH"],
                        CCC_TEST_ROOT=str(self.root), TMPDIR=str(self.root))

    def save_state(self):
        (self.root / "state.json").write_text(json.dumps(self.state))

    def run_function(self, name, *args, success=True):
        self.save_state()
        # Load definitions only. Never execute the script's command dispatcher.
        shell = '''source "$1"
log() { printf '%s\\n' "$*"; }
shift
"$@"
'''
        result = subprocess.run(["bash", "-c", shell, "test", str(self.definitions), name, *args],
                                cwd=self.root, env=self.env, input="y\n", text=True,
                                capture_output=True, timeout=30)
        if success:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def calls(self, command=None):
        path = self.root / "calls.jsonl"
        rows = [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []
        return [row for row in rows if command is None or row["command"] == command]

    def setup_certificate(self, old=True):
        ssl = self.root / "fs/var/ssl"
        ssl.mkdir(parents=True)
        for target in ("example.com.key", "account.key"):
            shutil.copy(self.crypto_root / "old.key", ssl / target)
        if old:
            shutil.copy(self.crypto_root / "old.crt", ssl / "example.com.fullchain.crt")
        shutil.copy(self.crypto_root / "new.crt", self.root / "issued.crt")
        return ssl / "example.com.fullchain.crt"

    def assert_no_acme_temp(self):
        self.assertEqual(list((self.root / "fs/var/ssl").glob(".acme-*")), [])

    def test_existing_database_containers_preserve_password(self):
        self.state["containers"] = ["mysql1", "postgres1"]
        for function, filename in (("deploy_mysql", "MYSQL_ROOT_PASSWORD.txt"),
                                   ("deploy_postgres", "PGSQL_ROOT_PASSWORD.txt")):
            with self.subTest(function=function):
                path = self.root / filename
                path.write_text("original-password\n")
                self.run_function(function, success=False)
                self.assertEqual(path.read_text(), "original-password\n")
        self.assertFalse(any(call["args"][0] == "run" for call in self.calls("docker")))

    def test_run_failure_preserves_existing_password(self):
        self.state["run_failure"] = True
        for function, filename in (("deploy_mysql", "MYSQL_ROOT_PASSWORD.txt"),
                                   ("deploy_postgres", "PGSQL_ROOT_PASSWORD.txt")):
            path = self.root / filename
            path.write_text("original-password\n")
            self.run_function(function, success=False)
            self.assertEqual(path.read_text(), "original-password\n")
        self.assertFalse(any(call["args"][0] == "exec" for call in self.calls("docker")))

    def test_first_run_failure_preserves_new_password_for_retry(self):
        self.state["run_failure"] = True
        self.run_function("deploy_postgres", success=False)
        password = (self.root / "PGSQL_ROOT_PASSWORD.txt").read_text()
        self.assertEqual(list(self.root.glob("*.tmp.*")), [])
        self.state.update(run_failure=False, volumes=["postgre-data"])
        self.run_function("deploy_postgres")
        self.assertEqual((self.root / "PGSQL_ROOT_PASSWORD.txt").read_text(), password)

    def test_existing_volume_requires_saved_password(self):
        self.state["volumes"] = ["mysql-data", "postgre-data"]
        for function in ("deploy_mysql", "deploy_postgres"):
            self.run_function(function, success=False)
        self.assertFalse(any(call["args"][0] == "run" for call in self.calls("docker")))

    def test_new_database_saves_matching_private_password(self):
        self.run_function("deploy_postgres")
        password_file = self.root / "PGSQL_ROOT_PASSWORD.txt"
        self.assertEqual(password_file.stat().st_mode & 0o777, 0o600)
        runs = [call["args"] for call in self.calls("docker") if call["args"][0] == "run"]
        self.assertIn("POSTGRES_PASSWORD=" + password_file.read_text().strip(), runs[0])

    def test_existing_volume_reuses_password(self):
        self.state["volumes"] = ["postgre-data"]
        (self.root / "PGSQL_ROOT_PASSWORD.txt").write_text("original-password\n")
        self.run_function("deploy_postgres")
        run = next(call["args"] for call in self.calls("docker") if call["args"][0] == "run")
        self.assertIn("POSTGRES_PASSWORD=original-password", run)

    def test_gitea_does_not_replace_existing_container(self):
        self.state["containers"] = ["gitea1"]
        self.run_function("deploy_gitea", success=False)
        self.assertEqual(self.calls("install"), [])

    def test_gitea_persists_both_rootless_directories(self):
        self.run_function("deploy_gitea")
        run = next(call["args"] for call in self.calls("docker") if call["args"][0] == "run")
        self.assertIn("/opt/gitea/data:/var/lib/gitea", run)
        self.assertIn("/opt/gitea/config:/etc/gitea", run)
        self.assertTrue((self.root / "fs/opt/gitea/data").is_dir())

    def test_download_failure_never_executes_acme_or_replaces_certificate(self):
        cert = self.setup_certificate()
        before = cert.read_bytes()
        self.state["download_failure"] = True
        self.run_function("create_ssl", "example.com", success=False)
        self.assertFalse((self.root / "acme.executed").exists())
        self.assertEqual(cert.read_bytes(), before)
        self.assertFalse((self.root / "crontab").exists())
        self.assert_no_acme_temp()

    def test_failed_issuance_with_valid_output_preserves_old_certificate(self):
        cert = self.setup_certificate()
        before = cert.read_bytes()
        self.env["CCC_ACME_FAILURE"] = "1"
        self.run_function("create_ssl", "example.com", success=False)
        self.assertTrue((self.root / "acme.executed").exists())
        self.assertEqual(cert.read_bytes(), before)
        self.assert_no_acme_temp()

    def test_bad_certificate_preserves_old_certificate(self):
        cert = self.setup_certificate()
        before = cert.read_bytes()
        (self.root / "issued.crt").write_text("not a certificate\n")
        self.run_function("create_ssl", "example.com", success=False)
        self.assertEqual(cert.read_bytes(), before)
        self.assert_no_acme_temp()

    def test_wrong_certificate_hostname_is_rejected(self):
        cert = self.setup_certificate()
        before = cert.read_bytes()
        subprocess.run(["openssl", "req", "-x509", "-key", str(cert.parent / "example.com.key"),
                        "-subj", "/CN=wrong.example.com", "-days", "90",
                        "-addext", "subjectAltName=DNS:wrong.example.com",
                        "-out", str(self.root / "issued.crt")], check=True, capture_output=True)
        self.run_function("create_ssl", "example.com", success=False)
        self.assertEqual(cert.read_bytes(), before)

    def test_wrong_certificate_key_is_rejected(self):
        cert = self.setup_certificate()
        before = cert.read_bytes()
        subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
                        "-keyout", str(self.root / "other.key"), "-subj", "/CN=example.com",
                        "-addext", "subjectAltName=DNS:example.com", "-days", "90",
                        "-out", str(self.root / "issued.crt")], check=True, capture_output=True)
        self.run_function("create_ssl", "example.com", success=False)
        self.assertEqual(cert.read_bytes(), before)

    def test_reload_failure_restores_old_certificate(self):
        cert = self.setup_certificate()
        before = cert.read_bytes()
        self.state["nginx_reload_failure"] = True
        self.run_function("create_ssl", "example.com", success=False)
        self.assertEqual(cert.read_bytes(), before)
        self.assertFalse((self.root / "crontab").exists())
        self.assert_no_acme_temp()

    def test_first_issue_validation_failure_removes_unloaded_certificate(self):
        cert = self.setup_certificate(old=False)
        self.state["nginx_test_failure"] = True
        self.run_function("create_ssl", "example.com", success=False)
        self.assertFalse(cert.exists())

    def test_successful_renewal_reloads_and_preserves_existing_cron_jobs(self):
        cert = self.setup_certificate()
        (self.root / "crontab").write_text("0 1 * * * existing-backup\n")
        self.run_function("create_ssl", "example.com")
        self.assertEqual(cert.read_bytes(), (self.root / "issued.crt").read_bytes() + b"\n")
        self.assertIn("existing-backup", (self.root / "crontab").read_text())
        self.assertEqual((self.root / "crontab").read_text().count("create_ssl example.com"), 1)
        self.assertTrue(any(call["args"] == ["exec", "nginx1", "nginx", "-s", "reload"]
                            for call in self.calls("docker")))
        self.assertTrue(any(call["args"][0] == "req" for call in self.calls("openssl")))
        self.assert_no_acme_temp()

    def test_first_issue_creates_private_keys_and_only_one_cron_job(self):
        # Keep the domain key to match the local fixture, but exercise account creation.
        cert = self.setup_certificate(old=False)
        (cert.parent / "account.key").unlink()
        self.run_function("create_ssl", "example.com")
        self.assertEqual((cert.parent / "account.key").stat().st_mode & 0o777, 0o600)
        self.run_function("create_ssl", "example.com")
        self.assertEqual((self.root / "crontab").read_text().count("create_ssl example.com"), 1)
        self.assert_no_acme_temp()

    def test_cron_read_error_does_not_replace_existing_jobs(self):
        self.setup_certificate()
        (self.root / "crontab").write_text("existing-job\n")
        self.state["cron_read_failure"] = True
        self.run_function("create_ssl", "example.com", success=False)
        self.assertEqual((self.root / "crontab").read_text(), "existing-job\n")

    def test_valid_certificate_cron_check_is_quiet(self):
        cert = self.setup_certificate()
        shutil.copy(self.root / "issued.crt", cert)
        self.env["CRON_EXECUTION"] = "1"
        result = self.run_function("create_ssl", "example.com")
        self.assertEqual(result.stdout, "")
        self.assertEqual(self.calls("wget"), [])

    def test_host_nginx_renewal(self):
        self.setup_certificate()
        self.state["nginx_backend"] = "host"
        self.run_function("create_ssl", "example.com")
        self.assertEqual([call["args"] for call in self.calls("nginx")], [["-t"], ["-s", "reload"]])

    def test_application_setup_stops_after_dependency_failure(self):
        self.state.update(execute_container=True, fail_stage="apt-get:install")
        command = 'printf started > "$CCC_TEST_ROOT/app.started"'
        for function in ("deploy_python_app", "deploy_node_app"):
            self.run_function(function, "https://example.com/app.git", "8000", command, success=False)
        self.assertFalse((self.root / "app.started").exists())
        self.assertEqual(self.calls("git"), [])

    def test_application_setup_stops_after_clone_failure(self):
        self.state.update(execute_container=True, fail_stage="git:clone")
        command = 'printf started > "$CCC_TEST_ROOT/app.started"'
        for function in ("deploy_python_app", "deploy_node_app"):
            self.run_function(function, "https://example.com/app.git", "8000", command, success=False)
        self.assertFalse((self.root / "app.started").exists())
        self.assertEqual(self.calls("npm"), [])

    def test_application_setup_success_runs_application(self):
        self.state["execute_container"] = True
        command = 'printf started > "$CCC_TEST_ROOT/app.started"'
        for function in ("deploy_python_app", "deploy_node_app"):
            self.run_function(function, "https://example.com/app.git", "8000", command)
            self.assertEqual((self.root / "app.started").read_text(), "started")
            (self.root / "app.started").unlink()

    def test_debian_setup_stops_on_package_index_failure(self):
        self.state.update(execute_container=True, fail_stage="apt-get:update")
        self.run_function("deploy_debian", success=False)
        self.assertEqual([call["args"] for call in self.calls("apt-get")], [["update"]])

    def test_php_installer_executes_inside_container(self):
        self.state["execute_container"] = True
        self.run_function("deploy_php_app", "test-php", "8080")
        self.assertEqual((self.root / "installer.scope").read_text(), "container")

    def test_php_download_failure_does_not_execute_installer(self):
        self.state.update(execute_container=True, download_failure=True)
        self.run_function("deploy_php_app", "test-php", "8080", success=False)
        self.assertFalse((self.root / "installer.scope").exists())

    def test_redis_password_delimiters_remain_one_argument(self):
        password = "pass:with, separators!"
        self.run_function("deploy_redis_commander", "8081", "redis1", "6379", password)
        run = next(call["args"] for call in self.calls("docker") if call["args"][0] == "run")
        self.assertIn("REDIS_PASSWORD=" + password, run)
        self.assertIn("REDIS_HOST=redis1", run)
        self.assertFalse(any(arg.startswith("REDIS_HOSTS=") for arg in run))

    def test_database_domain_rejects_path_and_sql_injection(self):
        (self.root / "MYSQL_ROOT_PASSWORD.txt").write_text("original-password\n")
        for domain in ("../outside", "site'; DROP DATABASE mysql; --", "a" * 62 + ".com"):
            self.run_function("create_database", domain, success=False)
        self.assertEqual(list(self.root.glob("*.sql")), [])

    def test_host_installers_write_configs_and_start_services_via_sudo(self):
        for function, config, service in (
            ("install_aria2", "fs/etc/aria2/aria2.conf", "aria2c"),
            ("install_frps", "fs/usr/local/bin/frp/frps.ini", "frps"),
            ("install_gost", "fs/etc/gost/config.json", "gost"),
        ):
            with self.subTest(function=function):
                self.run_function(function)
                self.assertTrue((self.root / config).is_file())
                self.assertTrue((self.root / ("fs/etc/systemd/system/" + service + ".service")).is_file())
                calls = [call for call in self.calls("systemctl") if service in call["args"]]
                self.assertEqual(len(calls), 2)
                self.assertTrue(all(call["elevated"] for call in calls))

    def test_host_download_failure_does_not_start_services(self):
        self.state["download_failure"] = True
        for function in ("install_aria2", "install_frps", "install_gost"):
            self.run_function(function, success=False)
        self.assertEqual(self.calls("systemctl"), [])

    def test_gost_config_write_failure_stops_service_setup(self):
        self.state["sudo_fail_command"] = "tee"
        self.run_function("install_gost", success=False)
        self.assertEqual(self.calls("systemctl"), [])

    def test_systeminfo_package_install_uses_sudo_and_stops_on_failure(self):
        self.state["sudo_fail_command"] = "apt"
        self.run_function("systeminfo", success=False)
        self.assertTrue(self.calls("apt")[0]["elevated"])
        self.assertEqual(self.calls("curl"), [])

    def prepare_protected_script(self):
        protected = self.root / "protected"
        protected.mkdir()
        script = protected / "ccc.sh"
        self.definitions.rename(script)
        self.definitions = script
        protected.chmod(0o555)
        return script

    def test_upgrade_user_script_preserves_mode_and_ownership(self):
        self.definitions.chmod(0o750)
        original = self.definitions.stat()
        self.run_function("upgrade")
        updated = self.definitions.stat()
        self.assertEqual(self.definitions.read_text(), "#!/bin/bash\nprintf 'updated\\n'\n")
        self.assertEqual((updated.st_uid, updated.st_gid, updated.st_mode & 0o777),
                         (original.st_uid, original.st_gid, 0o750))
        self.assertEqual(list(self.root.glob("*.new.*")), [])

    @unittest.skipIf(os.geteuid() == 0, "Requires an ordinary user's directory permissions")
    def test_upgrade_protected_directory_uses_sudo(self):
        script = self.prepare_protected_script()
        result = self.run_function("upgrade")
        self.assertIn("脚本更新成功", result.stdout)
        self.assertIn("updated", script.read_text())
        self.assertEqual(len(self.calls("mv")), 1)
        self.assertTrue(self.calls("mv")[0]["elevated"])
        self.assertEqual(list(script.parent.glob("*.new.*")), [])

    @unittest.skipIf(os.geteuid() == 0, "Requires an ordinary user's directory permissions")
    def test_upgrade_replace_failure_preserves_original_and_reports_failure(self):
        script = self.prepare_protected_script()
        before = script.read_bytes()
        self.state["sudo_fail_command"] = "mv"
        result = self.run_function("upgrade", success=False)
        self.assertEqual(script.read_bytes(), before)
        self.assertNotIn("脚本更新成功", result.stdout)
        self.assertEqual(list(script.parent.glob("*.new.*")), [])

    def test_upgrade_rejects_invalid_download(self):
        self.state["upgrade_payload"] = "if then\n"
        before = self.definitions.read_bytes()
        result = self.run_function("upgrade", success=False)
        self.assertEqual(self.definitions.read_bytes(), before)
        self.assertNotIn("脚本更新成功", result.stdout)


if __name__ == "__main__":
    unittest.main()
