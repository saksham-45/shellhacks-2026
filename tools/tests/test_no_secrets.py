import check_no_secrets

# Fake keys assembled at runtime so this file itself never matches.
FAKES = {
    "google.txt": "key = " + "AI" + "za" + "A" * 35,
    "openai.txt": "OPENAI=" + "sk" + "-" + "a1B2" * 8,
    "github.txt": "token " + "gh" + "p_" + "x" * 36,
    "pem.txt": "-----BEGIN " + "RSA PRIVATE KEY-----\nabc\n",
}


def test_clean_tree_passes(tmp_path):
    (tmp_path / "ok.py").write_text('import os\nkey = os.environ["GEMINI_API_KEY"]\n')
    (tmp_path / ".env.example").write_text("GEMINI_API_KEY=\n")
    assert check_no_secrets.main(["--root", str(tmp_path)]) == 0


def test_each_pattern_fails(tmp_path, capsys):
    for name, body in FAKES.items():
        d = tmp_path / name
        d.mkdir()
        (d / name).write_text(body)
        assert check_no_secrets.main(["--root", str(d)]) == 1, name
    assert "possible" in capsys.readouterr().err


def test_env_file_fails(tmp_path):
    (tmp_path / ".env").write_text("X=1\n")
    assert check_no_secrets.main(["--root", str(tmp_path)]) == 1


def test_skips_venv(tmp_path):
    venv = tmp_path / ".venv"
    venv.mkdir()
    (venv / "x.txt").write_text(FAKES["google.txt"])
    assert check_no_secrets.main(["--root", str(tmp_path)]) == 0
