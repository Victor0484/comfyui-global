# ComfyUI ReActor (ohne NSFW-Filter) + lokaler FLUX-Modell-Cache + Auto-Backup

Experimentelle Testversion fuer Runpod. Basierend auf dem bisherigen `pulid-test`-Image.
Das bereits funktionierende Image `ghcr.io/victor0484/comfyui-global:pulid-test`
wird NICHT ueberschrieben.

## Architektur

- `/opt/comfyui-baked`: ComfyUI + PuLID + ReActor aus Docker-Image
- `/workspace`: Runpod Global Volume (FUSE/geesefs), keine Local/Network Volume Disk
- `/workspace/models`: dauerhafte FLUX/PuLID/ReActor-Modelle
- `/tmp/comfy-model-cache`: lokaler Cache der wichtigsten FLUX/PuLID-Dateien
- `/opt/comfyui-baked/models/insightface`: lokale ReActor-Modelle aus Global Volume
- `/tmp/comfyui`: laufende User/Output/Input-Daten
- `/workspace/comfy-backup`: Auto-Backup, 30-Tage-Papierkorb
- ReActor-NSFW-Klassifikation ist im privaten Docker-Image deaktiviert. PuLID, FLUX und die Sicherung bleiben unveraendert.

**Achtung:** Cache-Dateien muessen nach jedem neuen Pod-Start wieder vom Global Volume
kopiert werden. Der allererste Start kann dadurch spaeter bereit sein. Mehrfache Modellwechsel
innerhalb einer Sitzung profitieren von schnellem lokalem Modellzugriff. Bei nur einer
Generierung pro Pod-Start ist der Gewinn nicht garantiert. Die Kompression/Quantisierung
von FLUX wird durch das Caching nicht veraendert.

## 1. Im noch laufenden PuLID-Pod sichern

Erst den funktionierenden Level-4-Workflow in ComfyUI speichern, dann im SSH-Terminal:

```bash
backup-comfy-data
find /workspace/comfy-backup/user -type f -path '*/workflows/*.json'
```

## 2. ReActor-Gewichte einmalig ins Global Volume laden

Im laufenden PuLID-Pod (noch nicht loeschen!):

```bash
bash prepare-reactor-models.sh
```

Dazu `prepare-reactor-models.sh` zuerst auf den Pod bringen. Am einfachsten
per Mac-SSH-SCP, oder per SSH in einem Editor kopieren. Alternativ ueber
JupyterLab hochladen und dort `bash /tmp/prepare-reactor-models.sh` ausfuehren.
Das Skript laedt die Dateien zunaechst auf die Container Disk und kopiert sie
mit Hashpruefung auf das Global Volume. Bei bestehendem Modell-Hashfehler stoppt es.
Zielpfade:

```
/workspace/models/insightface/inswapper_128.onnx
/workspace/models/insightface/models/buffalo_l/*.onnx
/workspace/models/facerestore_models/GFPGANv1.4.pth
```

Hinweis: InsightFace/inswapper Modelldateien haben Nutzungsbedingungen; offizielle
ReActor-Dokumentation beachten (vortrainierte InsightFace Modelle nur nicht-kommerzielle Forschung).

## 3. Neuen Branch fuer eine Testversion erstellen

In GitHub auf Branch `pulid-test` wechseln und daraus Branch `reactor-cache` erzeugen.
Aus diesem ZIP die sichtbaren Dateien im Hauptverzeichnis ersetzen/hochladen:

- `Dockerfile`
- `start-comfy.sh`
- `extra_model_paths.yaml`
- `patch-pulid.py` (wie bisher)
- `backup-comfy-data.sh` (wie bisher)
- `cache-models.py` (neu)
- `patch-reactor-nsfw.py` (neu: deaktiviert die ReActor-NSFW-Pruefung waehrend des Docker-Builds)
- `auto-backup-comfy.py` (Version mit Papierkorb, neu)

Versteckte `.github`-Datei NICHT per Drag-and-drop benoetigt:
Im Branch `reactor-cache` die vorhandene `.github/workflows/publish.yml`
im Webeditor oeffnen und ihren Inhalt durch die gleichnamige Datei aus dem ZIP ersetzen.
Direkter Pfad: https://github.com/Victor0484/comfyui-global/blob/reactor-cache/.github/workflows/publish.yml

Commit in `reactor-cache`; GitHub Actions baut:

```
ghcr.io/victor0484/comfyui-global:reactor-cache
```

Das `pulid-test`-Image bleibt unveraendert. CI-Erfolg belegt nur den Build, nicht
die tatsaechliche Kompatibilitaet der ReActor-Nodes zur Laufzeit.

## 4. Runpod-Template fuer neues Image

- Image `ghcr.io/victor0484/comfyui-global:reactor-cache`
- Container Disk 150 GB
- Volume Disk 0 GB, kein Network Volume
- Vorhandenes Global Volume `weekly_lime_impala` unter `/workspace`
- HTTP-Ports 8188 und (optional) 8888
- `Start Command` leer lassen
- Variable `JUPYTER_PASSWORD` setzen, falls Jupyter gewuenscht
- Variable `COMFY_CACHE_MODE=selected` (optional; Standard)

Waehrend des Pod-Starts wird der Cache befuellt. **ComfyUI wird erst danach gestartet.**
Das kann laenger dauern als ohne Cache. Log:

```
/tmp/comfy-model-cache.log
```

Achtung: In diesem Testimage wird der Cache bei jedem Neustart erneut angelegt.
Wenn die Container Disk zu klein ist, kann der Cache Kopien ueberspringen;
FLUX bleibt ueber den Global-Volume-Pfad verfuegbar.

## 5. Nach dem Pod-Start testen

1. ComfyUI ueber die neue Pod-ID und Port 8188 oeffnen.
2. In Node-Suche `PuLID` und `ReActor` pruefen.
3. Level-4-Workflow ausfuehren (Regressionstest).
4. ReActor: `ReActorFaceSwap`-Node ausprobieren, `inswapper_128.onnx`
   als Modell und zunaechst `none` als Face Restore auswaehlen.
5. Logs per SSH:

```
grep -iE 'reactor|failed|error|traceback' /tmp/comfyui/user/comfyui.log | tail -n 50
tail -n 40 /tmp/comfy-model-cache.log
tail -n 40 /tmp/comfy-autobackup.log
```

Beachte: ReActor verarbeitet Gesichter als Postprocessing eines vorhandenen Bildes.
Es ersetzt PuLID nicht, sondern ergaenzt es. Ein GPU-Provider muss zur installierten
CUDA/ONNX-Runtime passen; bei Fehlermeldungen unbedingt die Runpod-Logs nutzen.

## 6. Besondere Hinweise

- Das Projekt wurde syntaktisch und mit Testdateien auf die Cache-Logik geprueft.
  Ein realer Docker-Build mit GPU und ReActor-Praxisworkflow muss bei Runpod erfolgen.
- Die ReActor-Pakete und das Repo werden bei jedem Image-Build neu aus offiziellen
  Quellen geholt. Bei spaeteren Builds koennen Abhaengigkeiten sich aendern.
- GitHub-Zweig `reactor-cache` erstmal nicht mit `pulid-test` zusammenfuehren.
- Das Auto-Backup spiegelt nur Workflows, Input, Output, kleine Settings; es
  loescht NIE `/workspace/models` und hat 30 Tage Papierkorb-Retention.
- Alle Modelldateien bleiben dauerhaft auf dem Global Volume. Das Cache-Skript
  schreibt keine temp/rename-Dateien dorthin.

## NSFW-Filter-Aenderung

Das zusaetzliche `patch-reactor-nsfw.py` ersetzt nach dem Klonen von
`ComfyUI-ReActor` ausschliesslich die Funktion `nsfw_image(...)` durch eine
Pass-through-Pruefung, die immer `False` zurueckgibt. ReActor fuehrt damit
keine NSFW-Klassifikation aus und startet keinen Download eines NSFW-Detektors.
Das ist eine Anpassung dieses eigenen Docker-Images, nicht der offiziellen
ReActor-Erweiterung. Andere ComfyUI-Nodes oder Filter werden nicht veraendert.

Die Docker-Build-Pruefung bricht ab, falls das ReActor-Projekt die relevante
Datei oder den Aufruf umbenennt, statt unbemerkt wieder einen aktiven Filter
zu enthalten.

Nach dem Build in ComfyUI pruefen, ob ReActor-Nodes erscheinen und ein
Face-Swap-Workflow funktioniert. In den ReActor-Logs sollte kein
NSFW-Detektormodell mehr geladen werden.
