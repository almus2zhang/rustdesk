import os
import re

content_to_insert = """
### Android Tablet Optimizations (Mod Features)
This project is optimized for high-performance Android tablet usage:
- **Immersive Full-Screen**: A true borderless immersive mode that ensures the remote canvas is never squeezed or deformed by system navigation bars or soft keyboards.
- **High-Resolution Layout**: For tablets with physical width ≥ 2560px, the control bar (left) and shortcut key bar (right) are displayed side-by-side at the bottom for maximum efficiency.
- **Sticky Control Bars**: Controls and shortcut keys remain visible by default and collapse together, providing instant access to essential functions.
- **Intelligent Input Focus**: Enhanced compatibility for third-party IMEs (like Doubao IME). Features include focus locking and automatic focus restoration to prevent typing failures.
- **Productivity-First**: The soft keyboard is intelligently positioned above the control bars to avoid overlapping, keeping your shortcuts accessible while typing.
*Recommended for large-screen tablets. For the best experience, Doubao IME is recommended for voice input.*
"""

screenshots = """
![image](https://raw.githubusercontent.com/almus2zhang/rustdesk/master/res/rustdesk-mod.jpg)
![image](https://raw.githubusercontent.com/almus2zhang/rustdesk/master/res/rustdesk-mod2.jpg)
![image](https://raw.githubusercontent.com/almus2zhang/rustdesk/master/res/rustdesk-mod3.jpg)
"""

headers = [
    "Screenshots", "Images", "截图", "Скриншоты", "Captures", "Capturas", "スクリーンショット",
    "Знімки екрана", "Snímky", "Képernyőképek", "Zdjęcia", "Tangkapan", "Kuvakaappaukset",
    "Schermafbeeldingen", "Schermate", "Знімки", "Снимки", "Capturas de tela", "Zrzuty", "Ekran Görüntüleri", "Resimler",
    "Billeder", "Εικόνες", "Görüntüler", "Bilder", "Imagini", "스크린샷"
]

docs_dir = "docs"
for filename in os.listdir(docs_dir):
    if filename.startswith("README-") and filename.endswith(".md"):
        if filename == "README-ZH.md":
            continue
        
        filepath = os.path.join(docs_dir, filename)
        with open(filepath, 'r', encoding='utf-8') as f:
            content = f.read()
        
        regex = r'^(#+)\s+.*(' + '|'.join(headers) + r').*$'
        match = re.search(regex, content, re.IGNORECASE | re.MULTILINE)
        
        if match:
            header_text = match.group(0)
            start_idx = match.start()
            end_idx = match.end()
            
            new_content = content[:start_idx] + content_to_insert + "\n" + header_text + "\n" + screenshots + "\n" + content[end_idx:]
            
            with open(filepath, 'w', encoding='utf-8') as f:
                f.write(new_content)
            print(f"Updated {filename}")
        else:
            img_matches = list(re.finditer(r'!\[.*\]\(.*\)', content))
            if img_matches:
                first_img = img_matches[0]
                new_content = content[:first_img.start()] + content_to_insert + "\n### Screenshots\n" + screenshots + "\n\n" + content[first_img.start():]
                with open(filepath, 'w', encoding='utf-8') as f:
                    f.write(new_content)
                print(f"Inserted before images in {filename}")
            else:
                new_content = content + "\n\n" + content_to_insert + "\n### Screenshots\n" + screenshots
                with open(filepath, 'w', encoding='utf-8') as f:
                    f.write(new_content)
                print(f"Appended to {filename}")
