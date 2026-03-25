from pathlib import Path

from PIL import Image


ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'designs' / 'logo.png'
TARGET_DIR = ROOT / 'src' / 'netunnel-desktop-tauri' / 'src-tauri' / 'icons'
WEB_ICON = ROOT / 'src' / 'netunnel-desktop-tauri' / 'public' / 'logo.png'
PADDED = TARGET_DIR / 'logo-square.png'


def make_square_icon(source: Path, destination: Path) -> None:
    with Image.open(source) as image:
        image = image.convert('RGBA')
        width, height = image.size
        size = max(width, height)

        canvas = Image.new('RGBA', (size, size), (0, 0, 0, 0))
        offset = ((size - width) // 2, (size - height) // 2)
        canvas.paste(image, offset, image)
        canvas.save(destination)


def main() -> None:
    TARGET_DIR.mkdir(parents=True, exist_ok=True)
    WEB_ICON.parent.mkdir(parents=True, exist_ok=True)

    make_square_icon(SOURCE, PADDED)

    with Image.open(PADDED) as image:
        image.save(WEB_ICON)


if __name__ == '__main__':
    main()
