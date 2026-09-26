"""Testes da API local: travas de origem/host e gravação dos cookies. Nenhum job é executado."""
from __future__ import annotations

import stat

import pytest
from fastapi.testclient import TestClient

from dublador import config, server

BASE = f"http://127.0.0.1:{config.PORT}"
EXTENSION = config.ALLOWED_ORIGINS[0]


class FakeManager:
    def snapshot(self) -> dict:
        return {"current": None, "queued": [], "recent": []}


@pytest.fixture
def client(tmp_path, monkeypatch):
    monkeypatch.setattr(server, "COOKIES_FILE", tmp_path / "cookies.txt")
    monkeypatch.setattr(server, "manager", FakeManager())
    return TestClient(server.app, base_url=BASE)


def test_sem_origin_e_aceito(client):
    assert client.get("/health").json()["ok"] is True


def test_origem_de_site_e_recusada(client):
    assert client.get("/health", headers={"Origin": "https://evil.example"}).status_code == 403
    assert client.post("/jobs", json={"video_id": "5C_HPTJg5ek"}, headers={"Origin": "https://www.youtube.com"}).status_code == 403


def test_origem_da_extensao_recebe_cors(client):
    response = client.get("/health", headers={"Origin": EXTENSION})
    assert response.status_code == 200
    assert response.headers["access-control-allow-origin"] == EXTENSION


def test_host_estranho_e_recusado(client):
    # DNS rebinding: o navegador acha que fala com evil.example, mas o IP é 127.0.0.1
    assert client.get("/health", headers={"Host": "evil.example:47811"}).status_code == 403


def test_video_id_invalido(client):
    assert client.post("/jobs", json={"video_id": "../../etc/passwd"}).status_code == 400


def test_audio_recusa_id_fora_do_formato(client):
    assert client.get("/jobs/..%2F..%2Fsegredo/audio").status_code in (400, 404)


def test_cookies_so_do_youtube_e_arquivo_privado(client):
    body = {"cookies": [
        {"domain": ".youtube.com", "name": "SID", "value": "abc", "secure": True, "httpOnly": True, "expirationDate": 1900000000.5},
        {"domain": "www.youtube.com", "name": "PREF", "value": "x=1", "hostOnly": True},
        {"domain": ".google.com", "name": "NID", "value": "nao-deve-entrar"},
        {"domain": ".youtube.com", "name": "RUIM", "value": "a\tb"},
    ]}
    assert client.put("/cookies", json=body).json() == {"ok": True, "count": 2}
    path = server.COOKIES_FILE
    text = path.read_text()
    assert stat.S_IMODE(path.stat().st_mode) == 0o600
    assert text.startswith("# Netscape HTTP Cookie File")
    assert "#HttpOnly_.youtube.com\tTRUE\t/\tTRUE\t1900000000\tSID\tabc" in text
    assert "www.youtube.com\tFALSE\t/\tFALSE\t0\tPREF\tx=1" in text
    assert "google.com" not in text and "RUIM" not in text
    assert client.delete("/cookies").json() == {"ok": True}
    assert not path.exists()


def test_status_nao_expoe_valor_de_cookie(client):
    client.put("/cookies", json={"cookies": [{"domain": ".youtube.com", "name": "SID", "value": "segredo123"}]})
    body = client.get("/status").text
    assert "segredo123" not in body and '"present":true' in body.replace(" ", "")


def test_ajuste_invalido(client, monkeypatch, tmp_path):
    monkeypatch.setattr(config, "SETTINGS_FILE", tmp_path / "settings.json")
    monkeypatch.setattr(config, "APP_SUPPORT", tmp_path)
    assert client.put("/settings", json={"voice": "nao_existe"}).status_code == 400
    assert client.put("/settings", json={"chave_inventada": 1}).status_code == 400


def test_amostra_de_voz_desconhecida(client):
    assert client.get("/voices/nao_existe/sample").status_code == 404


def test_historico_vem_do_cache(tmp_path, monkeypatch):
    import json

    from dublador import jobs

    monkeypatch.setattr(jobs, "CACHE_DIR", tmp_path)
    for index, video in enumerate(["aaaaaaaaaaa", "bbbbbbbbbbb"]):
        folder = tmp_path / video
        folder.mkdir()
        (folder / "report.json").write_text(json.dumps({"titulo": f"Vídeo {index}", "tempo_total_s": 40.0}))
        dub = folder / "dub.pt.pf_dora.m4a"
        dub.write_bytes(b"x")
        import os
        os.utime(dub, (1000 + index, 1000 + index))
    (tmp_path / "incompleto").mkdir()  # sem relatório nem áudio: fica de fora
    entries = jobs.history()
    assert [e["video_id"] for e in entries] == ["bbbbbbbbbbb", "aaaaaaaaaaa"]
    assert entries[0]["id"] == "bbbbbbbbbbb.pt.pf_dora" and entries[0]["title"] == "Vídeo 1"
    assert entries[0]["audio_url"] == "/jobs/bbbbbbbbbbb.pt.pf_dora/audio"


def test_cor_de_destaque_valida(client, monkeypatch, tmp_path):
    monkeypatch.setattr(config, "SETTINGS_FILE", tmp_path / "settings.json")
    monkeypatch.setattr(config, "APP_SUPPORT", tmp_path)
    assert client.put("/settings", json={"ui_accent": "#F7821B"}).json()["ui_accent"] == "#F7821B"
    assert client.put("/settings", json={"ui_accent": "laranja"}).status_code == 400
    assert client.put("/settings", json={"ui_accent": "#fff"}).status_code == 400
    assert client.put("/settings", json={"ui_accent": ""}).status_code == 200
