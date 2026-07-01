# instagram-auto-post
BASH-Script als Middleware zum Posten der generierten Termin-Kacheln von https://lorenztroll.github.io/wir-festival-kacheln/editor.html

## Voraussetzung:
```
cp .env.example .env
vi .env
```

```
ACCESS_TOKEN=<<USER-ACCESS-TOKEN>>

IG_USER_ID=<<171111100000000000>>
```

## Verwendung:

* Einzelbild als POST
```
  /post.sh --caption "Text" --image "https://lorenztroll.github.io/wir-festival-kacheln/slide-KW27-01.jpg"
```

* Karussell als POST
```
./post.sh --caption "Text" --image "https://lorenztroll.github.io/wir-festival-kacheln/slide-KW27-01.jpg" --image "https://lorenztroll.github.io/wir-festival-kacheln/slide-KW27-02.jpg" --image "https://lorenztroll.github.io/wir-festival-kacheln/slide-KW27-03.jpg"
```
