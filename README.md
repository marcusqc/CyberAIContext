# CyberAIContext 2.0 — mod CET pour Cyberpunk 2077

Tu poses une question à une IA qui voit ce que tu vois dans le jeu. À chaque question :

1. **Télémétrie du jeu** lue directement par CET : position, direction, santé, niveau, combat, arme,
   munitions, véhicule, heure, météo, quartier, quête suivie, cible visée, et les 10 points de voyage
   rapide découverts les plus proches (distance et direction).
2. **Capture d'écran** de la fenêtre du jeu (par le compagnon).
3. **OCR** du texte à l'écran : Tesseract ou RapidOCR (par le compagnon).
4. **Un JSON unique** qui regroupe tout, affiché dans une fenêtre ImGui et écrit dans `ipc/last_context.json`.
5. **L'IA** (OpenRouter ou Gemini) reçoit ta question, le JSON et la capture, puis répond (par le compagnon).
6. **Voix** : la réponse courte est lue à voix haute (voix Windows, par le compagnon).

## Poser une question (touches conseillées)

| Touche | Raccourci CET | Ce qui se passe |
|---|---|---|
| **F1** (maintenir) | Question vocale (maintenir pour parler) | Capture au moment où tu appuies, tu parles, tu relâches : ta voix est transcrite et envoyée. |
| **F2** | Question par boîte de texte | Capture, puis une petite boîte apparaît au-dessus du jeu. Entrée = envoyer, Échap = annuler. Le clavier revient au jeu ensuite. |
| **F3** | Capture seule (question dans la console CET) | Capture, puis ouvre la console CET et écris dans la fenêtre du mod. |

Après une réponse, tu peux poser d'autres questions sur la même capture dans la fenêtre du mod
(console CET ouverte) : l'IA se souvient des échanges précédents.

N'utilise pas **Ctrl + une touche du jeu** : CET réagit aussi à la touche seule, donc le jeu la voit
(Ctrl+F5 = sauvegarde rapide, Ctrl+J = journal).

Rien ne bloque le jeu : le mod envoie des demandes au compagnon et vérifie les réponses quelques fois par seconde.

## Pourquoi un programme compagnon ?

Le Lua de CET ne peut ni prendre de capture d'écran, ni faire d'OCR, ni envoyer de requête HTTP,
et il ne peut écrire que dans son propre dossier. Le compagnon (Python) fait ce travail.
Les deux communiquent par des fichiers dans `ipc/`. Aucun port réseau n'est ouvert.

```
Jeu (CET, Lua)                          ipc/                         Compagnon (Python)
 F1/F2/F3 -> télémétrie          req_<id>.json  ───────────────►  capture / OCR / micro / IA / voix
 fenêtre ImGui      ◄─────────── res_<id>.json                    écrit le résultat
 "compagnon en ligne" ◄───────── heartbeat.json (chaque seconde)
```

## Installation

1. Copie le dossier `CyberAIContext` dans
   `<Cyberpunk 2077>\bin\x64\plugins\cyber_engine_tweaks\mods\`.
   Si le dossier `companion\.venv` a été copié lui aussi, supprime-le : il sera recréé.
2. Lance le `companion\start_companion.bat` **du dossier du jeu** (pas d'une autre copie).
   La première fois, il crée un environnement Python et installe les dépendances
   (Python 3.10 ou plus requis), puis télécharge le modèle de reconnaissance vocale (~460 Mo).
   Il réinstalle tout seul les dépendances quand `requirements.txt` change.
3. **Clé d'IA** (voir la section « IA » plus bas). Par défaut : OpenRouter.
   Mets ta clé dans la variable d'environnement Windows `OPENROUTER_API_KEY`,
   puis relance le compagnon. Sans clé, tout fonctionne sauf l'IA et la voix automatique.
4. Lance le jeu, ouvre la console CET, onglet **Bindings**, section **CyberAIContext** :
   assigne les touches du tableau ci-dessus. CET ne permet pas à un mod de choisir ses touches.
   **Show/Hide AI Context window** affiche ou masque la fenêtre.

Lance le jeu en **plein écran fenêtré (borderless)** : en plein écran exclusif, la capture peut être
noire et la boîte de texte (F2) ne peut pas s'afficher par-dessus le jeu.

## Johnny dans ta tête

Par défaut, c'est **Johnny Silverhand** qui répond (`"persona": "johnny"` dans `companion_config.json`) :
une voix intérieure sarcastique qui t'aide en une ou deux répliques, pas un chatbot.
Tu peux aussi lui parler d'autre chose (« Johnny, t'as envie de manger quoi ? »), il répond en personnage.
`"persona": "assistant"` donne un assistant neutre avec des réponses plus détaillées.
Les personnalités sont dans `PERSONAS` en haut de `cyberai_companion.py`.

## IA

Deux fournisseurs, choisis avec `"ai_provider"` dans `companion/companion_config.json` :

| `ai_provider` | Clé | Modèle par défaut |
|---|---|---|
| `openrouter` (défaut) | `OPENROUTER_API_KEY` | `google/gemma-4-31b-it:free` (gratuit, lit les images) |
| `gemini` (API Google AI Studio) | `GEMINI_API_KEY` | `gemini-2.5-flash` |

OpenRouter :
- Si le modèle principal est saturé, OpenRouter essaie les modèles de `openrouter_fallback_models`,
  qui sont gratuits eux aussi.
- Les modèles gratuits ont une limite de requêtes par jour (voir ton compte OpenRouter).
  Une capture = une seule requête, le texte et l'image partent ensemble.
- Il n'y a pas de Gemini Flash gratuit sur OpenRouter. Pour un Flash payant très bon marché :
  `"openrouter_model": "google/gemini-2.5-flash-lite"` (environ 0,0003 $ par capture).
  Si ta clé Google est liée à OpenRouter (BYOK), ces appels passent par elle.
- La liste des modèles change souvent : https://openrouter.ai/models (filtre « image input » et « free »).

Pour mettre la clé (PowerShell, une seule fois, puis rouvre le compagnon) :

```
[Environment]::SetEnvironmentVariable("OPENROUTER_API_KEY", "ta-cle", "User")
```

Tester la clé sans le jeu (capture l'écran, fait l'OCR, envoie à l'IA et affiche la réponse) :

```
companion\.venv\Scripts\python.exe companion\cyberai_companion.py --ask
```

## OCR

- **Tesseract** (utilisé en priorité s'il est installé) : meilleur pour les accents français.
  Installeur Windows : https://github.com/UB-Mannheim/tesseract/wiki (coche la langue française).
- **RapidOCR** : installé automatiquement, fonctionne sans rien d'autre, moins bon sur les accents.
- Pour forcer un moteur : `"ocr_engine": "tesseract"` ou `"rapidocr"` dans `companion_config.json`.

## Voix

### Réponse lue à voix haute

Le compagnon utilise les voix Windows, y compris les voix récentes (Claude, Caroline en fr-CA).
Pour lister celles qui sont installées :

```
companion\.venv\Scripts\python.exe companion\cyberai_companion.py --list-voices
```

Choisis-la dans `config.lua` : `tts.voice = "Claude"` (une partie du nom suffit).
Si le nom n'est pas trouvé, la première voix française est utilisée (`tts_language` dans `companion_config.json`).

Pour ajouter un autre moteur (ElevenLabs, Kokoro, Piper…) : écris une fonction
`tts_xxx(text, voice, rate, volume, lang)` dans `cyberai_companion.py`, ajoute-la à `TTS_ENGINES`
et mets `"tts_engine": "xxx"` dans `companion_config.json`. Le côté Lua ne change pas.

### Question à la voix (F1)

- Le micro est celui par défaut de Windows (`mic_device` dans `companion_config.json` pour en choisir un autre).
- La reconnaissance se fait sur ton PC avec Whisper (`stt_model` : `base` plus rapide, `small` par défaut,
  `medium` plus précis). Aucune voix n'est envoyée sur Internet, seulement le texte transcrit.
- `stt_hint` contient des noms du jeu (Lizzie's Bar, Jackie, Watson…) pour qu'ils soient bien écrits.
- Elle tourne sur la carte graphique NVIDIA quand il y en a une (`stt_device: "auto"`) :
  le jeu occupe trop le processeur (environ 35 s par question sur un i7-3820, 3 à 5 s sur une GTX 1660 Ti).
  Le compagnon charge le modèle au démarrage. L'enregistrement s'arrête seul après 30 s.

## Réglages

- `config.lua` (côté jeu) : délais d'attente, envoi de l'image à l'IA, voix, fenêtre.
- `companion/companion_config.json` (côté compagnon) : moteur OCR, fournisseur et modèle d'IA, langue des réponses,
  fenêtre à capturer, nombre de captures conservées.

## Tester sans le jeu

```
companion\.venv\Scripts\python.exe companion\cyberai_companion.py --test
companion\.venv\Scripts\python.exe companion\cyberai_companion.py --say "Bonjour V"
```

`--test` capture l'écran, lance l'OCR et affiche le texte trouvé.

## Utilisation depuis un autre mod

```lua
local ai = GetMod("CyberAIContext")
ai.trigger("mon_mod")              -- lance une capture
ai.ask("Où est Jackie ?")          -- question sur la dernière capture
local json = ai.getLastContext()   -- dernier JSON, ou nil
local s = ai.getStatus()           -- état, dernière réponse, erreurs
ai.speak("Texte à lire")
```

## Données manquantes

Si une valeur du jeu ne peut pas être lue (API différente selon la version du jeu ou de CET),
elle est **absente** du JSON et la raison apparaît dans `telemetry.errors`.
Aucune valeur n'est inventée. Seuls les points de voyage rapide ont une position réelle :
pour un autre lieu (bar, fixer…), l'IA le situe par rapport à eux avec sa connaissance du jeu.
Pour une distance exacte, place un marqueur sur la carte : la distance affichée à l'écran est lue par l'OCR.

## Fichiers

```
CyberAIContext/
├── init.lua                 enchaînement des étapes, événements CET, raccourcis
├── config.lua               réglages côté jeu
├── json.lua                 encodeur/décodeur JSON (rxi)
├── modules/
│   ├── IPC.lua              file d'attente des demandes au compagnon (fichiers)
│   ├── MCPManager.lua       télémétrie du jeu (lecture directe via CET)
│   ├── ScreenshotManager.lua
│   ├── OCRManager.lua
│   ├── ContextBuilder.lua   assemble le JSON unique
│   ├── GeminiBridge.lua      envoi à l'IA (OpenRouter ou Gemini)
│   ├── TTSManager.lua       file d'attente de la voix
│   ├── QuestionInput.lua    question à la voix (micro) ou par boîte de texte
│   └── OverlayUI.lua        fenêtre ImGui
├── ipc/                     échanges avec le compagnon (créé vide)
├── captures/                captures d'écran (les 30 dernières sont gardées)
└── companion/
    ├── cyberai_companion.py
    ├── start_companion.bat
    ├── requirements.txt
    └── companion_config.example.json
```
