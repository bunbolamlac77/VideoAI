"""
workers/src/aivideo_workers/wedding_scenes.py — Vietnamese wedding scene taxonomy.

The local VLM (Qwen3-VL 4B) is a general-purpose describer: asked "what happens
in these frames" it says "cô dâu và chú rể đứng cạnh nhau", which is true but
useless for a wedding POV edit. This module gives the pipeline a small, fixed
vocabulary of ceremony moments plus a **conservative** matcher:

  * a label is emitted only when an explicit cue appears in the model text;
  * no cue => no label (Unknown stays Unknown, never guessed);
  * labels are ordered and de-duplicated before they are rendered.

The taxonomy is deliberately tiny (10 moments). Adding a label here is the only
place to change: the prompt guide, the matcher and the rendered sentence all
derive from `WEDDING_SCENES`.
"""

from __future__ import annotations

from dataclasses import dataclass
import unicodedata
from typing import List, Sequence


@dataclass(frozen=True)
class WeddingScene:
    key: str
    label_vi: str
    cues: tuple[str, ...]


# Ordered by the typical flow of a wedding day (lễ -> tiệc), which is also the
# order used when several moments are visible in one window.
WEDDING_SCENES: tuple[WeddingScene, ...] = (
    WeddingScene(
        key="dam_hoi",
        label_vi="đám hỏi",
        cues=("đám hỏi", "ăn hỏi", "lễ vật", "mâm quả", "tráp"),
    ),
    WeddingScene(
        key="chai_toc",
        label_vi="mẹ chải tóc",
        cues=("chải tóc", "mẹ chải", "vuốt tóc", "mẹ vuốt"),
    ),
    WeddingScene(
        key="ruoc_dau",
        label_vi="rước dâu",
        cues=("rước dâu", "đón dâu", "đoàn rước", "cổng hoa"),
    ),
    WeddingScene(
        key="gia_tien",
        label_vi="lạy gia tiên",
        cues=("gia tiên", "bàn thờ", "thắp hương", "lạy ông bà", "lạy bàn thờ"),
    ),
    WeddingScene(
        key="thanh_le",
        label_vi="thánh lễ",
        cues=("thánh lễ", "nhà thờ", "linh mục", "cha xứ", "trao lời thề"),
    ),
    WeddingScene(
        key="trao_nhan",
        label_vi="trao nhẫn",
        cues=("trao nhẫn", "đeo nhẫn", "nhẫn cưới", "hộp nhẫn"),
    ),
    WeddingScene(
        key="li_xi",
        label_vi="lì xì",
        cues=("lì xì", "phong bao", "phong bì", "mừng cưới"),
    ),
    WeddingScene(
        key="chup_hinh",
        label_vi="chụp hình",
        cues=("chụp hình", "chụp ảnh", "tạo dáng", "photoshoo", "pose"),
    ),
    WeddingScene(
        key="tiec_cuoi",
        label_vi="tiệc cưới",
        cues=("tiệc cưới", "bàn tiệc", "nâng ly", "cắt bánh", "khai tiệc", "sân khấu"),
    ),
    WeddingScene(
        key="nhay_mo_man",
        label_vi="nhảy mở màn",
        cues=("nhảy mở màn", "flashmob", "khiêu vũ", "nhảy tập thể"),
    ),
)

_BY_KEY = {scene.key: scene for scene in WEDDING_SCENES}


def _normalize(text: str) -> str:
    return unicodedata.normalize("NFC", text or "").lower()


def detect_wedding_scenes(text: str) -> List[str]:
    """Return the ordered, de-duplicated wedding labels explicitly present in text.

    Conservative by construction: a label needs one of its own cues. Generic
    wedding words ("cô dâu", "chú rể", "đám cưới") are NOT cues — they say the
    footage is a wedding, not which moment it is.
    """
    lowered = _normalize(text)
    if not lowered.strip():
        return []
    found: List[str] = []
    for scene in WEDDING_SCENES:
        if any(_normalize(cue) in lowered for cue in scene.cues):
            found.append(scene.key)
    return found


def wedding_scene_labels(keys: Sequence[str]) -> List[str]:
    return [_BY_KEY[key].label_vi for key in keys if key in _BY_KEY]


def wedding_scene_sentence(keys: Sequence[str]) -> str:
    """Vietnamese sentence appended to the observation text ("" when nothing found)."""
    labels = wedding_scene_labels(keys)
    if not labels:
        return ""
    return "Cảnh cưới nhận diện: " + ", ".join(labels) + "."


def prompt_guide() -> str:
    """Instruction appended to the VLM prompt: name the moment, or stay silent."""
    labels = ", ".join(scene.label_vi for scene in WEDDING_SCENES)
    return (
        "Nếu đây là video cưới và nhìn thấy rõ, nêu tên cảnh cưới theo đúng danh sách sau "
        f"(chỉ nêu khi chắc chắn, không suy đoán): {labels}. "
        "Nếu không thấy rõ thì không nêu cảnh cưới."
    )
