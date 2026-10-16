# /// script
# requires-python = ">=3.11,<3.13"
# dependencies = ["fonttools==4.51.0", "Brotli==1.0.9"]
# ///
"""Re-encode the complete source font; never subset characters or weights."""

from fontTools.ttLib import TTFont

from check_web_fonts import FONT_DIR, METADATA, check_fonts, metadata_text


if __name__ == "__main__":
    with TTFont(FONT_DIR / "NotoSansSC.ttf", recalcTimestamp=False) as font:
        font.flavor = "woff2"
        font.save(FONT_DIR / "NotoSansSC.woff2")
    METADATA.write_text(metadata_text())
    check_fonts()
