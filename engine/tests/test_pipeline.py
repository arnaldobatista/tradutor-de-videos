"""Testes das partes do pipeline que não dependem de rede, GPU nem modelos."""
from __future__ import annotations

import numpy as np
import pytest

from dublador.config import Settings
from dublador.pipeline import fit, punctuate, segment, translate
from dublador.pipeline.segment import Line, Utterance, Word


def asr_event(start_ms: int, words: list[tuple[int, str]], duration_ms: int = 4000) -> dict:
    return {"tStartMs": start_ms, "dDurationMs": duration_ms,
            "segs": [{"utf8": (" " if i else "") + w, "tOffsetMs": off} for i, (off, w) in enumerate(words)]}


def test_parse_json3_ignora_marcacoes_e_extrai_palavras_com_tempo():
    data = {"events": [
        {"tStartMs": 0, "dDurationMs": 9000},                                   # janela sem texto
        {"tStartMs": 100, "dDurationMs": 2000, "segs": [{"utf8": "[Music]"}]},  # não é fala
        asr_event(1000, [(0, "hello"), (500, "world")]),
        {"tStartMs": 2400, "dDurationMs": 1000, "segs": [{"utf8": "\n"}]},      # quebra de linha do ASR
        asr_event(2500, [(0, "again")]),
    ]}
    lines, words = segment.parse_json3(data)
    assert [line.text for line in lines] == ["hello world", "again"]
    assert [(w.start, w.text) for w in words] == [(1.0, "hello"), (1.5, "world"), (2.5, "again")]
    # a janela de exibição do ASR invade a linha seguinte: o fim real é o começo da próxima
    assert lines[0].end == 2.5


def test_words_from_lines_interpola_o_tempo_dentro_da_linha():
    words = segment.words_from_lines([Line(start=10.0, end=14.0, text="aaa bbb")])
    assert [w.text for w in words] == ["aaa", "bbb"]
    assert words[0].start == 10.0 and words[1].start == pytest.approx(12.0)


def test_falas_por_frase_cortam_na_pontuacao_e_nao_no_fim_da_linha():
    # a tradução do YouTube quebra "decidi seguir os | passos" entre duas linhas
    lines = [Line(16.0, 20.0, "Há alguns anos, decidi seguir os"), Line(20.0, 24.0, "passos dele. A ideia é simples.")]
    words = segment.words_from_lines(lines)
    sentence, clause = punctuate.breaks_from_text([w.text for w in words])
    falas = segment.build_sentence_utterances(words, sentence, clause, 30.0, portuguese=True)
    assert falas[0].text == "Há alguns anos, decidi seguir os passos dele."
    assert all(f.source_text == "" for f in falas)
    assert falas[-1].window_end == 30.0
    assert all(a.window_end == b.start for a, b in zip(falas, falas[1:]))


def test_fragmento_adiantado_nao_vira_fala_propria():
    # "Há" caiu na linha anterior, 4 s antes de a pessoa começar a falar
    lines = [Line(12.0, 16.0, "Há"), Line(16.0, 20.0, "alguns anos eu estava parado."), Line(20.0, 23.0, "Então mudei tudo agora.")]
    words = segment.words_from_lines(lines)
    sentence, clause = punctuate.breaks_from_text([w.text for w in words])
    falas = segment.build_sentence_utterances(words, sentence, clause, 30.0, portuguese=True)
    assert falas[0].text.startswith("Há alguns anos")
    assert falas[0].start == pytest.approx(16.0)


def test_frase_longa_quebra_na_virgula():
    words = [Word(start=i * 0.5, text=f"p{i}" + ("," if i == 14 else "")) for i in range(30)]
    words[-1].text += "."
    sentence, clause = punctuate.breaks_from_text([w.text for w in words])
    falas = segment.build_sentence_utterances(words, sentence, clause, 20.0)
    assert len(falas) == 2 and falas[0].source_text.endswith("p14,")


def test_transcricao_sem_pontuacao_e_detectada():
    assert not punctuate.already_punctuated("rust a memory safe compiled language that delivers".split() * 10)
    assert punctuate.already_punctuated("Isto é uma frase. E outra frase aqui. Mais uma.".split())


def test_pontuacao_do_llm_e_alinhada_mesmo_com_palavra_alterada(monkeypatch):
    original = "rust is fast it has no garbage collector and it is safe".split()
    devolvido = "Rust is fast. It has no garbage-collector, and it is safe".split()  # juntou duas palavras
    monkeypatch.setattr(translate, "pick_model", lambda settings: "fake")
    monkeypatch.setattr(punctuate, "_punctuate_chunk", lambda *args: devolvido)
    sentence, _ = punctuate.find_breaks(original, "en", Settings())
    assert sentence == {2}  # depois de "fast"; o fim do texto nunca conta como quebra


def test_modelo_de_traducao_preferido():
    names = ["qwen3-thinking-uncensored:30b", "whiterabbitneo-v3:7b", "qwen3-coder-uncensored:30b"]
    assert max(names, key=translate._score) == "qwen3-coder-uncensored:30b"


class FakeTTS:
    """Fala a 16 caracteres por segundo e obedece ao speed com o mesmo ganho parcial do Kokoro."""

    sample_rate = 24000

    def synthesize(self, text: str, voice: str, speed: float) -> np.ndarray:
        effective = 1.0 + (speed - 1.0) * fit.SPEED_GAIN
        return np.full(int(len(text) / 16.0 / effective * self.sample_rate), 0.1, dtype=np.float32)


def fala(i: int, start: float, window_end: float, chars: int) -> Utterance:
    return Utterance(id=i, start=start, speech_end=window_end, window_end=window_end, source_text="", text="a" * chars)


def test_fala_que_cabe_nao_e_acelerada(tmp_path):
    placed, report = fit.synthesize_and_fit([fala(0, 0.0, 10.0, 80), fala(1, 10.0, 20.0, 80)], FakeTTS(), Settings(), tmp_path)
    assert report["velocidade_maxima"] == 1.0 and report["falas_atrasadas"] == 0
    assert [p.at for p in placed] == [0.0, 10.0]


def test_fala_longa_acelera_ate_caber(tmp_path):
    placed, report = fit.synthesize_and_fit([fala(0, 0.0, 5.0, 100), fala(1, 5.0, 30.0, 40)], FakeTTS(), Settings(), tmp_path)
    assert placed[0].speed > 1.15
    assert len(placed[0].audio) / 24000 <= 5.0 and report["falas_cortadas"] == 0
    assert placed[1].delay == 0.0


def test_atraso_nunca_passa_do_teto_mesmo_com_texto_absurdo(tmp_path):
    falas = [fala(i, i * 4.0, (i + 1) * 4.0, 400) for i in range(6)]  # 25 s de fala em janelas de 4 s
    placed, report = fit.synthesize_and_fit(falas, FakeTTS(), Settings(), tmp_path)
    assert report["falas_cortadas"] > 0
    for p in placed:
        assert p.at + len(p.audio) / 24000 <= p.utterance.window_end + fit.MAX_DELAY_S + 0.05
    track = fit.render_voice_track(placed, 24000, 24.0)
    assert len(track) / 24000 <= 24.0 + fit.MAX_DELAY_S + 0.1


def test_reticencias_nao_fecham_frase():
    words = "they have really... really long trunks. That is cool…  ok!".split()
    sentence, clause = punctuate.breaks_from_text(words)
    assert sentence == {5, 9} and {2, 8} <= clause


# ---------------------------------------------------------------- mixagem

def _noise(seconds: float, rate: int, level: float, seed: int = 0) -> np.ndarray:
    rng = np.random.default_rng(seed)
    return (rng.standard_normal(int(seconds * rate)) * level).astype(np.float32)


def test_voz_dublada_sai_no_mesmo_volume_da_original():
    """A voz mono vai para os dois canais: a medição tem que ser em estéreo, senão sobra +3 dB."""
    from dublador.pipeline import mix

    rate = 44100
    voice = _noise(8.0, rate, 0.05)
    silent_background = np.zeros((len(voice), 2), dtype=np.float32)
    mixed, info = mix.mix_arrays(silent_background, target=-20.0, voice=voice, rate=rate, duck_db=0.0)
    assert info["lufs_voz_dublada"] == pytest.approx(-20.0, abs=0.3)
    assert mix._loudness(mixed, rate) == pytest.approx(-20.0, abs=0.3)


def test_fundo_fica_intocado_sem_ducking():
    from dublador.pipeline import mix

    rate = 44100
    background = np.repeat(_noise(6.0, rate, 0.02, seed=1)[:, None], 2, axis=1)
    voice = np.zeros(len(background), dtype=np.float32)
    voice[rate:3 * rate] = _noise(2.0, rate, 0.05)[: 2 * rate]
    mixed, _ = mix.mix_arrays(background.copy(), target=-20.0, voice=voice, rate=rate, duck_db=0.0)
    # fora da fala, a mix é exatamente o fundo (nem escala global: a mix é mais baixa que -14 LUFS)
    assert np.allclose(mixed[4 * rate:], background[4 * rate:], atol=1e-6)


def test_mix_alta_demais_e_abaixada_como_no_youtube():
    from dublador.pipeline import mix

    rate = 44100
    background = np.repeat(_noise(6.0, rate, 0.3, seed=2)[:, None], 2, axis=1)  # bem alto
    voice = _noise(6.0, rate, 0.2, seed=3)
    mixed, info = mix.mix_arrays(background, target=-12.0, voice=voice, rate=rate, duck_db=0.0)
    assert info["lufs_mix"] == pytest.approx(mix.YOUTUBE_LUFS, abs=0.1)
    assert mix._loudness(mixed, rate) <= mix.YOUTUBE_LUFS + 0.3


def test_dinamica_segue_a_voz_original(tmp_path):
    """Fala que era 6 dB mais baixa no original fica 6 dB mais baixa na dublagem; janela absurda é ignorada."""
    from dublador.pipeline import mix

    sr = 24000
    hop = mix.HOP_S
    clip = _noise(1.0, sr, 0.1)
    placed = [
        fit.Placed(utterance=fala(0, 0.0, 2.0, 10), audio=clip, at=0.0, speed=1.0, delay=0.0),
        fit.Placed(utterance=fala(1, 2.0, 4.0, 10), audio=clip, at=2.0, speed=1.0, delay=0.0),
        fit.Placed(utterance=fala(2, 4.0, 6.0, 10), audio=clip, at=4.0, speed=1.0, delay=0.0),
        fit.Placed(utterance=fala(3, 6.0, 8.0, 10), audio=clip, at=6.0, speed=1.0, delay=0.0),
    ]
    envelope = np.full(int(8.0 / hop), -80.0, dtype=np.float32)  # silêncio
    envelope[int(0.2 / hop):int(1.8 / hop)] = -20.0
    envelope[int(2.2 / hop):int(3.8 / hop)] = -26.0   # 6 dB mais baixa
    envelope[int(4.2 / hop):int(5.8 / hop)] = -20.0
    envelope[int(6.2 / hop):int(7.8 / hop)] = -50.0   # legenda desalinhada: só ruído na janela
    gains = fit.utterance_gains(placed, sr, envelope, hop)
    assert gains[0] - gains[1] == pytest.approx(6.0, abs=0.3)
    assert gains[0] == pytest.approx(gains[2], abs=0.1)
    assert gains[3] == 0.0
    track = fit.render_voice_track(placed, sr, 8.0, gains)
    assert len(track) >= 8 * sr
