"""Legendas json3 -> linhas -> falas (unidades que viram um áudio de TTS cada)."""
from __future__ import annotations

import re
from bisect import bisect_left, bisect_right
from dataclasses import asdict, dataclass

# Marcações que não são fala: [Música], (aplausos), ♪ ...
_NON_SPEECH = re.compile(r"^\s*[\[(（].*[\])）]\s*$|^[\s♪♫]+$")
_INLINE_TAG = re.compile(r"\[[^\]]{1,24}\]|♪|♫")
_SENTENCE_END = re.compile(r"[.!?…][\"')\]]*$")

PAUSE_S = 0.6          # silêncio que fecha uma fala
WORD_TAIL_S = 0.45     # duração presumida da última palavra (json3 só traz o início de cada uma)
TARGET_S = 6.5         # acima disso, a fala fecha na primeira pontuação ou pausa
MAX_S = 10.0
MAX_CHARS = 230
MIN_GROUP_S = 1.2


@dataclass
class Line:
    start: float
    end: float
    text: str


@dataclass
class Word:
    start: float
    text: str


@dataclass
class Utterance:
    id: int
    start: float          # quando a fala original começa
    speech_end: float     # quando a fala original termina (estimado)
    window_end: float     # até onde a fala dublada pode ir sem atropelar a próxima
    source_text: str      # texto de origem (vazio quando o texto final já veio em português)
    text: str = ""        # texto em português que vai para o TTS

    def to_dict(self) -> dict:
        return asdict(self)


def clean_text(text: str) -> str:
    text = _INLINE_TAG.sub(" ", text.replace("\n", " "))
    text = text.replace(">>", " ")
    return re.sub(r"\s+", " ", text).strip(" -–")


def parse_json3(data: dict) -> tuple[list[Line], list[Word]]:
    """Devolve as linhas com texto e as palavras com tempo (só faixas ASR trazem tempo por palavra)."""
    lines: list[Line] = []
    words: list[Word] = []
    for event in data.get("events", []):
        segs = event.get("segs")
        if not segs:
            continue
        raw = "".join(seg.get("utf8", "") for seg in segs)
        if not raw.strip() or _NON_SPEECH.match(raw):
            continue
        text = clean_text(raw)
        if not text:
            continue
        t0 = event.get("tStartMs", 0) / 1000.0
        dur = event.get("dDurationMs", 0) / 1000.0
        timed = [seg for seg in segs if seg.get("utf8", "").strip()]
        if len(timed) > 1 or any("tOffsetMs" in seg for seg in timed):
            for seg in timed:
                token = clean_text(seg["utf8"])
                if token:
                    words.append(Word(start=t0 + seg.get("tOffsetMs", 0) / 1000.0, text=token))
        lines.append(Line(start=t0, end=t0 + dur, text=text))
    lines.sort(key=lambda line: line.start)
    words.sort(key=lambda word: word.start)
    # Em faixas ASR a janela de exibição invade a linha seguinte: o fim real é o começo da próxima.
    for current, following in zip(lines, lines[1:]):
        current.end = min(current.end, following.start) if current.end > current.start else following.start
    return lines, words


def _speech_end(line: Line, next_start: float | None, word_starts: list[float]) -> float:
    limit = next_start if next_start is not None else line.end
    limit = max(limit, line.start + 0.2)
    if word_starts:
        lo = bisect_left(word_starts, line.start - 0.05)
        hi = bisect_right(word_starts, limit - 0.05)
        if hi > lo:
            return min(limit, word_starts[hi - 1] + WORD_TAIL_S)
    return min(limit, line.end) if line.end > line.start else limit


def build_utterances(
    lines: list[Line],
    word_starts: list[float],
    audio_duration: float,
    text_is_portuguese: bool,
) -> list[Utterance]:
    """Agrupa linhas consecutivas em falas por pausa, pontuação e tamanho."""
    groups: list[list[int]] = []
    current: list[int] = []
    ends = [
        _speech_end(line, lines[i + 1].start if i + 1 < len(lines) else None, word_starts)
        for i, line in enumerate(lines)
    ]
    for i, line in enumerate(lines):
        current.append(i)
        if i + 1 == len(lines):
            break
        nxt = lines[i + 1]
        start = lines[current[0]].start
        duration = ends[i] - start
        chars = sum(len(lines[j].text) for j in current)
        pause = nxt.start - ends[i]
        ends_sentence = bool(_SENTENCE_END.search(line.text))
        projected = ends[i + 1] - start
        close = (
            (pause >= PAUSE_S and duration >= MIN_GROUP_S)
            or (ends_sentence and duration >= 2.5)
            or (duration >= TARGET_S and (ends_sentence or pause >= 0.25 or line.text.endswith((",", ";", ":"))))
            or projected > MAX_S
            or chars + len(nxt.text) > MAX_CHARS
        )
        if close:
            groups.append(current)
            current = []
    if current:
        groups.append(current)

    utterances: list[Utterance] = []
    for index, group in enumerate(groups):
        text = clean_text(" ".join(lines[j].text for j in group))
        start = lines[group[0]].start
        if index + 1 < len(groups):
            window_end = lines[groups[index + 1][0]].start
        else:
            window_end = max(audio_duration, ends[group[-1]])
        utterances.append(
            Utterance(
                id=index,
                start=start,
                speech_end=ends[group[-1]],
                window_end=window_end,
                source_text="" if text_is_portuguese else text,
                text=text if text_is_portuguese else "",
            )
        )
    return utterances


SENTENCE_PAUSE_S = 1.6    # silêncio que fecha a fala mesmo sem pontuação
SHORT_S = 2.5             # frases mais curtas que isso grudam na vizinha
MERGED_MAX_S = 8.0


def _split_long(words: list[Word], first: int, last: int, clause_breaks: set[int]) -> list[tuple[int, int]]:
    duration = words[last].start + WORD_TAIL_S - words[first].start
    chars = sum(len(words[k].text) + 1 for k in range(first, last + 1))
    if (duration <= MAX_S and chars <= MAX_CHARS) or last - first < 6:
        return [(first, last)]
    middle = (words[first].start + words[last].start) / 2
    inner = range(first + 2, last - 2)
    candidates = [k for k in inner if k in clause_breaks]
    if candidates:
        cut = min(candidates, key=lambda k: abs(words[k].start - middle))
    else:  # sem vírgula: corta no maior respiro perto do meio
        cut = max(inner, key=lambda k: (words[k + 1].start - words[k].start) - 0.15 * abs(words[k].start - middle))
    return _split_long(words, first, cut, clause_breaks) + _split_long(words, cut + 1, last, clause_breaks)


def words_from_lines(lines: list[Line]) -> list[Word]:
    """Palavras com tempo interpolado dentro de cada linha, para faixas sem tempo por palavra.

    A tradução do YouTube redistribui as palavras entre as linhas, então a frase em português
    raramente termina onde a linha termina: o corte tem que seguir a pontuação do texto.
    """
    words: list[Word] = []
    for line in lines:
        tokens = line.text.split()
        total = sum(len(token) + 1 for token in tokens)
        span = max(0.0, line.end - line.start)
        offset = 0
        for token in tokens:
            words.append(Word(start=line.start + span * offset / total, text=token))
            offset += len(token) + 1
    return words


def build_sentence_utterances(
    words: list[Word],
    sentence_breaks: set[int],
    clause_breaks: set[int],
    audio_duration: float,
    portuguese: bool = False,
) -> list[Utterance]:
    """Uma fala por frase completa (as curtas grudam, as longas quebram na vírgula)."""
    spans: list[tuple[int, int]] = []
    first = 0
    for i in range(len(words)):
        is_last = i + 1 == len(words)
        # Um silêncio longo fecha a fala, menos quando sobraria um fragmento de uma ou duas palavras:
        # a tradução do YouTube às vezes joga o começo da frase na linha anterior, segundos antes da fala.
        paused = not is_last and words[i + 1].start - words[i].start > SENTENCE_PAUSE_S and i - first >= 2
        if is_last or i in sentence_breaks or paused:
            spans.extend(_split_long(words, first, i, clause_breaks))
            first = i + 1

    merged: list[tuple[int, int]] = []
    for span in spans:
        if merged:
            prev_first, prev_last = merged[-1]
            prev_duration = words[prev_last].start + WORD_TAIL_S - words[prev_first].start
            gap = words[span[0]].start - (words[prev_last].start + WORD_TAIL_S)
            combined = words[span[1]].start + WORD_TAIL_S - words[prev_first].start
            tiny = prev_last - prev_first < 3 or span[1] - span[0] < 3
            if (prev_duration < SHORT_S or tiny) and gap < 0.8 and combined <= MERGED_MAX_S:
                merged[-1] = (prev_first, span[1])
                continue
        merged.append(span)

    def speech_start(a: int, b: int) -> float:
        k = a  # pula o fragmento inicial que ficou adiantado em relação à fala
        while k < b and k - a < 2 and words[k + 1].start - words[k].start > SENTENCE_PAUSE_S:
            k += 1
        return words[k].start

    utterances: list[Utterance] = []
    for index, (a, b) in enumerate(merged):
        nxt = merged[index + 1] if index + 1 < len(merged) else None
        window_end = speech_start(*nxt) if nxt else audio_duration
        speech_end = min(words[b].start + WORD_TAIL_S, window_end)
        text = clean_text(" ".join(words[k].text for k in range(a, b + 1)))
        utterances.append(Utterance(id=index, start=speech_start(a, b), speech_end=speech_end,
                                    window_end=max(window_end, speech_end),
                                    source_text="" if portuguese else text, text=text if portuguese else ""))
    return utterances

